<#
.SYNOPSIS
  Power on or deallocate every session host in a meeting.

.DESCRIPTION
  Use Stopped (deallocated) when a meeting won't be used for a while -- you
  keep paying for the OS disk (~few EUR/month per VM) but not for compute.
  Use Running to bring the meeting back online before users connect.
  (Start VM on Connect + the meeting's scaling plan also handle this
  automatically. Use this script for explicit bulk warm/cool.)

.EXAMPLE
  ./Set-MeetingPower.ps1 -MeetingId js20260427 -State Stopped
  ./Set-MeetingPower.ps1 -MeetingId js20260427 -State Running
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $MeetingId,

    [Parameter(Mandatory)]
    [ValidateSet('Stopped','Running')]
    [string] $State,

    [string] $ResourceGroup = 'rg-avdpoc-westeurope'
)

$ErrorActionPreference = 'Stop'

$names = & az vm list -g $ResourceGroup `
    --query "[?tags.meeting=='$MeetingId'].name" -o tsv
if (-not $names) {
    Write-Warning "No VMs found with tag meeting=$MeetingId in $ResourceGroup."
    return
}

$vmNames = ($names -split "`n") | Where-Object { $_ }
Write-Host "Meeting '$MeetingId' -> $($vmNames.Count) VM(s) -> target state: $State" -ForegroundColor Cyan

$action = if ($State -eq 'Stopped') { 'deallocate' } else { 'start' }

$jobs = foreach ($n in $vmNames) {
    Write-Host "  $action $n"
    Start-Job -ScriptBlock {
        param($rg, $name, $verb)
        & az vm $verb -g $rg -n $name --no-wait -o none
    } -ArgumentList $ResourceGroup, $n, $action
}

$jobs | Wait-Job | Receive-Job
$jobs | Remove-Job

Write-Host "Issued '$action' for all VMs (running async on Azure side)." -ForegroundColor Green
Write-Host "Check status with:"
Write-Host "  az vm list -g $ResourceGroup --query ""[?tags.meeting=='$MeetingId'].{name:name,power:powerState}"" -d -o table"
