<#
.SYNOPSIS
  Recurring monthly refresh of the golden image. Stage-based; never
  pauses. Each invocation runs exactly one stage and exits.

.DESCRIPTION
  Stages (run in order, separately):

    -Stage Start    Start the deallocated golden VM. Exits immediately.
                    Complete OOBE manually via Bastion (sign in once,
                    create the local admin) before moving on.

    -Stage Update   Submit Windows Update + Office click-to-run update
                    via run-command, then exit. Updates install
                    asynchronously inside the VM. Reboot it manually
                    via Bastion if needed; re-run this stage until
                    Get-WindowsUpdate inside the VM is clean.

    -Stage Capture  Hand off to Generalize-And-Capture.ps1 (snapshot ->
                    sysprep -> image version). Requires -ImageVersion.

  There is intentionally no orchestrator that chains these -- each
  stage either succeeds or fails on its own.

.EXAMPLE
  ./Update-GoldenImage.ps1 -Stage Start
  ./Update-GoldenImage.ps1 -Stage Update
  ./Update-GoldenImage.ps1 -Stage Capture -ImageVersion 1.0.5
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Start','Update','Capture')]
    [string] $Stage,

    [string] $ResourceGroup       = 'rg-avdpoc-westeurope',
    [string] $VmName              = 'vm-avdpoc-gold',
    [string] $GalleryName         = 'gal_avdpoc',
    [string] $ImageDefinitionName = 'avdpoc-win11-m365',

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $ImageVersion
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    param([Parameter(Mandatory)][string[]] $Args)
    Write-Host "az $($Args -join ' ')" -ForegroundColor DarkGray
    $output = & az @Args
    if ($LASTEXITCODE -ne 0) { throw "az failed with exit code $LASTEXITCODE" }
    return $output
}

switch ($Stage) {

    'Start' {
        Write-Host "== Starting golden VM ==" -ForegroundColor Cyan
        Invoke-Az @('vm','start','-g',$ResourceGroup,'-n',$VmName,'-o','none')
        Write-Host ''
        Write-Host 'VM started.' -ForegroundColor Green
        Write-Host 'If it was generalized, Windows is now in OOBE.'
        Write-Host 'Open Bastion, complete OOBE (re-create your local admin),'
        Write-Host 'then run:  ./Update-GoldenImage.ps1 -Stage Update'
    }

    'Update' {
        $updateScript = @'
$ErrorActionPreference = "Stop"
if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
    Install-PackageProvider NuGet -Force -Confirm:$false | Out-Null
    Install-Module PSWindowsUpdate -Force -Confirm:$false -Scope AllUsers
}
Import-Module PSWindowsUpdate
Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot -Verbose | Out-File C:\windows-update.log -Append

$c2r = "$env:ProgramFiles\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
if (Test-Path $c2r) {
    & $c2r /update user displaylevel=false forceappshutdown=true
}
'@

        Write-Host "== Submitting Windows + Office updates to $VmName ==" -ForegroundColor Cyan
        Invoke-Az @(
            'vm','run-command','invoke',
            '-g', $ResourceGroup,
            '-n', $VmName,
            '--command-id', 'RunPowerShellScript',
            '--scripts', $updateScript,
            '-o','none'
        )
        Write-Host ''
        Write-Host 'Update job submitted.' -ForegroundColor Green
        Write-Host 'Updates install asynchronously (and may need a reboot).'
        Write-Host 'Verify inside the VM (Bastion):  Get-WURebootStatus / Get-WindowsUpdate'
        Write-Host 'Re-run -Stage Update until clean. Then run:'
        Write-Host '       ./Update-GoldenImage.ps1 -Stage Capture -ImageVersion <x.y.z>'
    }

    'Capture' {
        if (-not $ImageVersion) {
            throw '-ImageVersion is required for -Stage Capture (e.g. 1.0.5).'
        }
        & "$PSScriptRoot/Generalize-And-Capture.ps1" `
            -ResourceGroup $ResourceGroup `
            -VmName $VmName `
            -GalleryName $GalleryName `
            -ImageDefinitionName $ImageDefinitionName `
            -ImageVersion $ImageVersion
    }
}
