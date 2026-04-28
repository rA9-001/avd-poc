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

# Run-command will return as soon as sysprep is launched; the VM then shuts down.
# We tolerate the connection drop.
try {
    Invoke-Az @(
        'vm','run-command','invoke',
        '-g', $ResourceGroup,
        '-n', $VmName,
        '--command-id', 'RunPowerShellScript',
        '--scripts', $sysprepScript,
        '-o','none'
    )
} catch {
    Write-Warning "run-command returned non-zero (expected when VM shuts down mid-call). Continuing."
}

# 2. Give sysprep a moment to actually start shutting Windows down, then
#    just deallocate. `az vm deallocate` is idempotent: it works whether
#    the VM is running, stopping, stopped, or already deallocated, and
#    leaves it in PowerState/deallocated either way. Polling for a
#    specific intermediate state (e.g. PowerState/stopped) is unreliable
#    -- depending on how sysprep exits and what the host does, the VM
#    may go straight from running -> deallocating -> deallocated and
#    never report 'stopped'.
Write-Host ""
Write-Host "== Letting sysprep run, then deallocating ==" -ForegroundColor Cyan
Start-Sleep -Seconds 60

# 3. Deallocate + generalize (both idempotent)
Write-Host ""
Write-Host "== Deallocating and generalizing $VmName ==" -ForegroundColor Cyan
Invoke-Az @('vm','deallocate','-g',$ResourceGroup,'-n',$VmName,'-o','none')
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
