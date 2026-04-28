<#
.SYNOPSIS
  Runs every fully-automated one-off step in order. Never pauses
  mid-flow.

.DESCRIPTION
  Order:
    1. Deploy-Shared.ps1            (shared infra, golden VM)
    2. Configure-EntraKerberos.ps1  (admin consent, manifest tag, CA exclusion)

  After this exits successfully, customise the golden VM via Bastion at
  your own pace, then run Generalize-And-Capture.ps1 separately. There
  is intentionally no "wait for human" step inside this script -- it
  either completes or fails.

.EXAMPLE
  ./Bootstrap-Poc.ps1
  ./Bootstrap-Poc.ps1 -FixCAPolicies
#>

[CmdletBinding()]
param(
    [string] $Location = 'westeurope',
    [switch] $FixCAPolicies
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Step([string]$title) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
}

# ---------------- 1. Shared infra ----------------
Step '1/2  Deploy shared infrastructure'
& "$root/Deploy-Shared.ps1" -Location $Location

# ---------------- 2. Entra Kerberos ----------------
Step '2/2  Configure Entra Kerberos (consent, manifest tag, CA exclusion)'
$caArgs = @{}
if ($FixCAPolicies) { $caArgs.FixCAPolicies = $true }
& "$root/Configure-EntraKerberos.ps1" @caArgs

Write-Host ''
Write-Host 'Bootstrap complete.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next (separate, manual steps -- run when you are ready):'
Write-Host '  1. Customise vm-avdpoc-gold via Bastion (install lab apps, configure'
Write-Host '     settings). Sign out cleanly. Do NOT join a domain.'
Write-Host '  2. Capture the image:'
Write-Host '       ./Generalize-And-Capture.ps1 -ImageVersion 1.0.0'
Write-Host '  3. Spin up your first meeting:'
Write-Host '       ./New-Meeting.ps1 -Initials js -AttendeeGroup g-academy-2026-04'
