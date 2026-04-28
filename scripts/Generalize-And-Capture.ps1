<#
.SYNOPSIS
  End-to-end automation for the AVD Academy POC golden image lifecycle.

.DESCRIPTION
  After you have manually installed your applications on the golden VM, run
  this script. It will:

    1. Snapshot the OS disk (safety net -- sysprep is one-way).
    2. Run sysprep /generalize /shutdown inside the VM (via Run Command).
    3. Deallocate and generalize the VM at the Azure level.
    4. Capture a new image version into the Compute Gallery.

  After this script finishes you have a reusable, versioned image you can
  point new session host VMs at.

.PARAMETER ResourceGroup
  Name of the resource group created by the Bicep deployment.
  Default matches main.bicepparam (rg-<prefix>-<location>).

.PARAMETER VmName
  Name of the golden VM. Default matches the Bicep naming.

.PARAMETER GalleryName
  Compute Gallery name. Default matches the Bicep naming.

.PARAMETER ImageDefinitionName
  Image definition name inside the gallery. Default matches the Bicep naming.

.PARAMETER ImageVersion
  Semantic version (e.g. 1.0.0) for the new image version. Required.
  Bump this every time you re-capture.

.PARAMETER TargetRegion
  Region the image version is replicated to. Defaults to the VM's region.

.EXAMPLE
  ./Generalize-And-Capture.ps1 -ImageVersion 1.0.0
#>

[CmdletBinding()]
param(
    [string] $ResourceGroup       = 'rg-avdpoc-westeurope',
    [string] $VmName              = 'vm-avdpoc-gold',
    [string] $GalleryName         = 'gal_avdpoc',
    [string] $ImageDefinitionName = 'avdpoc-win11-m365',

    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $ImageVersion,

    [string] $TargetRegion
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    param([Parameter(Mandatory)][string[]] $Args)
    Write-Host "az $($Args -join ' ')" -ForegroundColor DarkGray
    $output = & az @Args
    if ($LASTEXITCODE -ne 0) {
        throw "az command failed with exit code $LASTEXITCODE"
    }
    return $output
}

# 0. Pre-flight
Write-Host "== Pre-flight checks ==" -ForegroundColor Cyan
Invoke-Az @('account','show','--only-show-errors','-o','none')

$vmJson = Invoke-Az @('vm','show','-g',$ResourceGroup,'-n',$VmName,'-o','json') | ConvertFrom-Json
if (-not $TargetRegion) { $TargetRegion = $vmJson.location }
$vmId = $vmJson.id
Write-Host "VM:      $vmId"
Write-Host "Region:  $TargetRegion"
Write-Host "Image:   $GalleryName / $ImageDefinitionName : $ImageVersion"

# Verify image version doesn't already exist
$existing = & az sig image-version show `
    --resource-group $ResourceGroup `
    --gallery-name $GalleryName `
    --gallery-image-definition $ImageDefinitionName `
    --gallery-image-version $ImageVersion `
    -o json 2>$null
if ($LASTEXITCODE -eq 0 -and $existing) {
    throw "Image version $ImageVersion already exists. Pick a higher version."
}

# 0b. Snapshot the OS disk before sysprep (sysprep is one-way; if anything
#     fails you can recreate the VM from this snapshot and try again).
Write-Host ""
Write-Host "== Snapshotting OS disk (safety net before sysprep) ==" -ForegroundColor Cyan
$osDiskId   = $vmJson.storageProfile.osDisk.managedDisk.id
$snapshotName = "snap-$VmName-pre-$ImageVersion-$(Get-Date -Format 'yyyyMMddHHmm')"
Invoke-Az @(
    'snapshot','create',
    '-g', $ResourceGroup,
    '-n', $snapshotName,
    '--source', $osDiskId,
    '--sku', 'Standard_LRS',
    '-o','none'
)
Write-Host "  Snapshot: $snapshotName  (delete manually once you've verified the new image works)"

# 1. Sysprep inside the VM
Write-Host ""
Write-Host "== Running sysprep /generalize /oobe (synchronous) inside $VmName ==" -ForegroundColor Cyan
# Run sysprep WITHOUT /shutdown and WITH -Wait so run-command blocks
# until sysprep actually exits. That way we get sysprep's real exit
# code back -- if anything went wrong (Store/AppX packages, leftover
# panther logs, etc.) the script throws here instead of silently
# capturing a non-generalized OS disk.
$sysprepScript = @'
$ErrorActionPreference = "Stop"
$sysprep = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
if (-not (Test-Path $sysprep)) { throw "sysprep.exe not found" }
Remove-Item "$env:SystemRoot\System32\Sysprep\Panther" -Recurse -Force -ErrorAction SilentlyContinue
$p = Start-Process -FilePath $sysprep `
    -ArgumentList "/generalize","/oobe","/quiet","/mode:vm" -Wait -PassThru
if ($p.ExitCode -ne 0) {
    $log = (Get-Content "$env:SystemRoot\System32\Sysprep\Panther\setupact.log" -Tail 80 -ErrorAction SilentlyContinue) -join "`n"
    throw "sysprep failed (exit $($p.ExitCode)). Tail of setupact.log:`n$log"
}
"sysprep OK"
'@

# Run-command can be slow; sysprep on a Win11 + M365 image takes ~10 min.
# Bump the run-command timeout (default is 90 min so this is fine).
Invoke-Az @(
    'vm','run-command','invoke',
    '-g', $ResourceGroup,
    '-n', $VmName,
    '--command-id', 'RunPowerShellScript',
    '--scripts', $sysprepScript,
    '-o','none'
)
Write-Host "  Sysprep completed successfully inside the VM."

# 2. Stop + deallocate the running, generalized VM. We don't need the
#    in-OS shutdown because sysprep didn't include /shutdown -- the VM
#    is still running but is now generalized. `vm deallocate` is fine
#    on a running VM and waits until PowerState/deallocated.
Write-Host ""
Write-Host "== Deallocating $VmName ==" -ForegroundColor Cyan
Invoke-Az @('vm','deallocate','-g',$ResourceGroup,'-n',$VmName,'-o','none')

$power = & az vm get-instance-view -g $ResourceGroup -n $VmName `
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" -o tsv
if ($power -ne 'PowerState/deallocated') {
    throw "VM is in state '$power' after deallocate; refusing to generalize."
}
Write-Host "  Power state: $power"

# 3. Mark generalized at the ARM level (this is just a flag flip --
#    it does NOT run sysprep; sysprep already ran above).
Write-Host ""
Write-Host "== Marking $VmName generalized at the ARM level ==" -ForegroundColor Cyan
Invoke-Az @('vm','generalize','-g',$ResourceGroup,'-n',$VmName,'-o','none')

# 4. Capture image version
Write-Host ""
Write-Host "== Capturing image version $ImageVersion ==" -ForegroundColor Cyan
# Source is a generalized VM, not a captured managed image, so we use
# --virtual-machine (not --managed-image, which expects a separate
# Microsoft.Compute/images resource).
Invoke-Az @(
    'sig','image-version','create',
    '--resource-group', $ResourceGroup,
    '--gallery-name', $GalleryName,
    '--gallery-image-definition', $ImageDefinitionName,
    '--gallery-image-version', $ImageVersion,
    '--virtual-machine', $vmId,
    '--target-regions', "$TargetRegion=1=premium_lrs",
    '--replica-count', '1',
    '-o','none'
)

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Image: /subscriptions/.../galleries/$GalleryName/images/$ImageDefinitionName/versions/$ImageVersion"
