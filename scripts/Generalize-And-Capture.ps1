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
Write-Host "== Running sysprep /generalize /shutdown inside $VmName ==" -ForegroundColor Cyan
$sysprepScript = @'
$ErrorActionPreference = "Stop"
$sysprep = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
if (-not (Test-Path $sysprep)) { throw "sysprep.exe not found" }
# Remove any leftover panther logs that can block re-running sysprep
Remove-Item "$env:SystemRoot\System32\Sysprep\Panther" -Recurse -Force -ErrorAction SilentlyContinue
Start-Process -FilePath $sysprep -ArgumentList "/generalize","/oobe","/shutdown","/mode:vm" -Wait
'@

# `az vm run-command invoke` is synchronous and hangs once the VM
# shuts itself down (the agent disconnects mid-call). Run it as a
# background job and abandon it after a short window -- by that time
# sysprep has either started shutting down Windows or never will.
$runJob = Start-Job -ScriptBlock {
    param($rg, $vm, $script)
    & az vm run-command invoke -g $rg -n $vm `
        --command-id RunPowerShellScript --scripts $script -o none 2>&1
} -ArgumentList $ResourceGroup, $VmName, $sysprepScript

if (Wait-Job $runJob -Timeout 180) {
    Receive-Job $runJob -ErrorAction SilentlyContinue | Out-Null
    Write-Host "  run-command returned."
} else {
    Write-Warning "run-command did not return within 3 min (expected: VM is shutting down). Continuing."
    Stop-Job $runJob -ErrorAction SilentlyContinue
}
Remove-Job $runJob -Force -ErrorAction SilentlyContinue

# 2. Force the VM to a deallocated state. `az vm deallocate` is
#    idempotent and waits until the resource is fully deallocated, so
#    we don't need to poll for an intermediate PowerState/stopped (which
#    is unreliable -- a shutting-down VM may go straight from running
#    to deallocating and never report 'stopped').
Write-Host ""
Write-Host "== Deallocating $VmName ==" -ForegroundColor Cyan
Invoke-Az @('vm','deallocate','-g',$ResourceGroup,'-n',$VmName,'-o','none')

# Verify we actually got there before we generalize.
$power = & az vm get-instance-view -g $ResourceGroup -n $VmName `
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" -o tsv
if ($power -ne 'PowerState/deallocated') {
    throw "VM is in state '$power' after deallocate; refusing to generalize."
}
Write-Host "  Power state: $power"

# 3. Generalize
Write-Host ""
Write-Host "== Generalizing $VmName ==" -ForegroundColor Cyan
Invoke-Az @('vm','generalize','-g',$ResourceGroup,'-n',$VmName,'-o','none')

# 4. Capture image version
Write-Host ""
Write-Host "== Capturing image version $ImageVersion ==" -ForegroundColor Cyan
Invoke-Az @(
    'sig','image-version','create',
    '--resource-group', $ResourceGroup,
    '--gallery-name', $GalleryName,
    '--gallery-image-definition', $ImageDefinitionName,
    '--gallery-image-version', $ImageVersion,
    '--managed-image', $vmId,
    '--target-regions', "$TargetRegion=1=premium_lrs",
    '--replica-count', '1',
    '-o','none'
)

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Image: /subscriptions/.../galleries/$GalleryName/images/$ImageDefinitionName/versions/$ImageVersion"
