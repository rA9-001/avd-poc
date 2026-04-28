<#
.SYNOPSIS
  Permanently deletes a meeting: VMs (+ NICs + OS disks), AVD control
  plane, and scaling plan.

.DESCRIPTION
  Use this when an academy session is fully done and the FSLogix profiles
  are no longer needed. Profiles on the storage account share are NOT
  removed automatically -- delete them manually if you want to fully
  forget the attendees.

  The Entra access group passed to New-Meeting.ps1 is **never** deleted
  here -- it's owned by you / the customer. Remove it manually if you
  don't need it any more.

.EXAMPLE
  ./Remove-Meeting.ps1 -MeetingId js20260427
  ./Remove-Meeting.ps1 -MeetingId js20260427 -Force
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)]
    [string] $MeetingId,

    [string] $ResourceGroup = 'rg-avdpoc-westeurope',
    [string] $Prefix        = 'avdpoc',

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$HostPoolName    = "vdpool-$Prefix-$MeetingId"
$AppGroupName    = "vdag-$Prefix-$MeetingId"
$WorkspaceName   = "vdws-$Prefix-$MeetingId"
$ScalingPlanName = "vdsp-$Prefix-$MeetingId"

Write-Host "Meeting to remove : $MeetingId" -ForegroundColor Yellow
Write-Host "Host pool         : $HostPoolName"
Write-Host "App group         : $AppGroupName"
Write-Host "Workspace         : $WorkspaceName"
Write-Host "Scaling plan      : $ScalingPlanName"
Write-Host "Entra access group: (preserved -- owned externally)"

if (-not $Force -and -not $PSCmdlet.ShouldProcess($MeetingId, 'Remove meeting and all its session hosts')) {
    return
}

# 1. Delete VMs and their disks/NICs
$vmJson = & az vm list -g $ResourceGroup `
    --query "[?tags.meeting=='$MeetingId']" -o json | ConvertFrom-Json

if ($vmJson.Count -gt 0) {
    Write-Host ""
    Write-Host "== Deleting $($vmJson.Count) VM(s) ==" -ForegroundColor Cyan
    $diskIds = @($vmJson | ForEach-Object { $_.storageProfile.osDisk.managedDisk.id })
    $nicIds  = @($vmJson | ForEach-Object { $_.networkProfile.networkInterfaces.id })

    & az vm delete --ids @($vmJson.id) --yes -o none
    if ($nicIds)  { & az network nic delete --ids $nicIds  -o none }
    if ($diskIds) { & az disk delete        --ids $diskIds --yes -o none }
}

# 2. Delete scaling plan + AVD control plane (order matters: scaling plan
#    references the host pool, workspace references the app group, ...)
Write-Host ""
Write-Host "== Deleting scaling plan + AVD control plane ==" -ForegroundColor Cyan

& az desktopvirtualization scaling-plan delete `
    --resource-group $ResourceGroup --name $ScalingPlanName --yes -o none 2>$null

foreach ($pair in @(
    @{ kind = 'workspace';        name = $WorkspaceName },
    @{ kind = 'applicationgroup'; name = $AppGroupName  },
    @{ kind = 'hostpool';         name = $HostPoolName  }
)) {
    Write-Host "Deleting $($pair.kind) $($pair.name)"
    & az desktopvirtualization $($pair.kind) delete `
        --resource-group $ResourceGroup `
        --name $($pair.name) --yes -o none 2>$null
}

# 3. Delete the deployment record (cosmetic)
& az deployment group delete -g $ResourceGroup -n "dpl-meeting-$MeetingId" 2>$null

Write-Host ""
Write-Host "Meeting '$MeetingId' removed." -ForegroundColor Green
Write-Host "Note: FSLogix profiles on the 'profiles' SMB share are NOT deleted."
Write-Host "Note: the Entra attendee group is preserved."
