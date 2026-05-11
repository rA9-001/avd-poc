<#
.SYNOPSIS
  Deploys (or extends) a meeting: AVD host pool + scaling plan + N personal
  session host VMs from the latest gallery image, and grants an existing
  Entra security group (the attendees) access to it.

.DESCRIPTION
  A "meeting" = one academy session. It's identified by the admin's
  initials + the date (and an optional letter suffix if the same admin
  runs two meetings on the same day). Multiple customers can attend a
  single meeting.

  You bring an existing Entra security group; the script reads its
  membership, creates one personal session host per member (override
  with -Count), and grants the group the AVD + VM Login roles.

  Examples:
    -Initials js -AttendeeGroup g-academy-aks-2026-04   # 1 VM per member
    -Initials js -AttendeeGroup <objectId> -Count 0     # roles only, no VMs
    -Initials js -AttendeeGroup g-academy-aks-2026-04 -Count 2  # top-up

  The script:
    1. Tags the AVD service principal with the Power-On role on the RG
       (idempotent; needed once per RG for Start VM on Connect).
    2. Deploys infra/meeting.bicep (host pool / app group / workspace /
       scaling plan + diagnostic settings).
    3. Grants the attendee group:
         - Desktop Virtualization User on the meeting's app group
         - Virtual Machine User Login on each session host VM
    4. Refreshes the host pool registration token.
    5. Creates -Count session host VMs from the latest gallery image,
       Entra-joined and registered with the host pool. Re-runs append.
    6. Pushes FSLogix + Cloud Kerberos registry config to each VM via
       run-command (skip with -SkipClientConfig if you use Intune).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z]{2,4}$')]
    [string] $Initials,

    # Existing Entra security group whose members are the attendees of
    # this meeting. The script grants this group the AVD + VM Login
    # roles, and (unless -Count is given) creates one VM per member.
    [Parameter(Mandatory)]
    [string] $AttendeeGroup,

    [ValidatePattern('^\d{8}$')]
    [string] $Date = (Get-Date -Format 'yyyyMMdd'),

    [ValidatePattern('^[a-z]?$')]
    [string] $Suffix = '',

    # Override the auto-derived VM count (= number of members in
    # -AttendeeGroup). Use 0 to skip VM creation, e.g. to grant the
    # group access without provisioning yet.
    [ValidateRange(-1, 50)]
    [int] $Count = -1,

    # Skip in-VM registry config (Kerberos + FSLogix). Use this if you
    # are pushing those settings via Intune instead.
    [switch] $SkipClientConfig,

    [string] $ResourceGroup       = 'rg-avdpoc-westeurope',
    [string] $Location            = 'westeurope',
    [string] $Prefix              = 'avdpoc',
    [string] $GalleryName         = 'gal_avdpoc',
    [string] $ImageDefinitionName = 'avdpoc-win11-m365',
    [string] $ImageVersion        = 'latest',
    [string] $VnetName            = 'vnet-avdpoc',
    [string] $SubnetName          = 'snet-avd',
    [string] $LogAnalyticsName    = 'law-avdpoc',
    [string] $VmSize              = 'Standard_D4s_v5',
    [string] $AdminUsername       = 'azureadmin',
    [string] $StorageAccountName,             # auto-discovered if empty
    [string] $ProfilesShareName   = 'profiles',

    # Microsoft rotates the versioned Configuration_*.zip artifacts; old ones
    # 404. The unversioned Configuration.zip is the always-current pointer
    # they tell you to use in the portal flow.
    [string] $AvdAgentDscUrl      = 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration.zip'
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    param([Parameter(Mandatory)][string[]] $Args)
    $safe = $Args | ForEach-Object {
        if ($_ -like '--admin-password=*') { '--admin-password=***' } else { $_ }
    }
    Write-Host "az $($safe -join ' ')" -ForegroundColor DarkGray
    $output = & az @Args
    if ($LASTEXITCODE -ne 0) { throw "az failed with exit code $LASTEXITCODE" }
    return $output
}

# Ensure required CLI extension
& az extension show --name desktopvirtualization 1>$null 2>$null
if ($LASTEXITCODE -ne 0) {
    Invoke-Az @('extension','add','--name','desktopvirtualization','-y','-o','none')
}

$MeetingId    = "$Initials$Date$Suffix"
$HostPoolName = "vdpool-$Prefix-$MeetingId"
$AppGroupName = "vdag-$Prefix-$MeetingId"

# ---------- Resolve the attendee group + member count ----------
if ($AttendeeGroup -match '^[0-9a-f-]{36}$') {
    $groupId = $AttendeeGroup
    $groupDisplay = & az ad group show --group $groupId --query displayName -o tsv 2>$null
} else {
    $groupId = & az ad group show --group $AttendeeGroup --query id -o tsv 2>$null
    $groupDisplay = $AttendeeGroup
}
if (-not $groupId) {
    throw "Entra group '$AttendeeGroup' not found. Create it first (in Entra portal, az ad group create, ...)."
}
$members = & az ad group member list --group $groupId `
    --query '[].{Id:id,Upn:userPrincipalName}' | ConvertFrom-Json
$memberCount = @($members).Count
if ($Count -lt 0) {
    $Count = $memberCount
}

# Auto-discover the shared storage account if not passed.
if (-not $SkipClientConfig -and -not $StorageAccountName) {
    $StorageAccountName = & az storage account list -g $ResourceGroup `
        --query "[0].name" -o tsv 2>$null
    if (-not $StorageAccountName) {
        Write-Warning "No storage account found in $ResourceGroup; FSLogix config will be skipped."
        $SkipClientConfig = $true
    }
}

# Computer name = NetBIOS, max 15 chars. Use the meeting id padded by index.
$cnBase = $MeetingId.Substring(0, [Math]::Min(12, $MeetingId.Length))

Write-Host "Meeting:        $MeetingId"
Write-Host "Host pool:      $HostPoolName"
Write-Host "Attendee group: $groupDisplay ($groupId)"
Write-Host "Members:        $memberCount"
Write-Host "VMs to create:  $Count"
Write-Host ""

# ---------- 1. Grant AVD SP the Power-On role (idempotent) ----------
Write-Host "== Ensuring AVD service principal can power VMs on/off in the RG ==" -ForegroundColor Cyan
$avdAppId = '9cdead84-a844-4324-93f2-b2e6bb768d07'   # Azure Virtual Desktop
$avdSpId  = & az ad sp show --id $avdAppId --query id -o tsv 2>$null
if (-not $avdSpId) {
    Invoke-Az @('ad','sp','create','--id', $avdAppId, '-o', 'none')
    $avdSpId = Invoke-Az @('ad','sp','show','--id', $avdAppId, '--query', 'id', '-o', 'tsv')
}
$rgId = Invoke-Az @('group','show','-n', $ResourceGroup, '--query','id','-o','tsv')
$existing = & az role assignment list --assignee $avdSpId --scope $rgId `
    --role 'Desktop Virtualization Power On Off Contributor' --query '[0].id' -o tsv 2>$null
if (-not $existing) {
    Invoke-Az @(
        'role','assignment','create',
        '--assignee-object-id', $avdSpId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', 'Desktop Virtualization Power On Off Contributor',
        '--scope', $rgId,
        '-o','none'
    )
}

# ---------- 2. Deploy meeting.bicep ----------
Write-Host ""
Write-Host "== Deploying meeting control plane ==" -ForegroundColor Cyan
$lawId = Invoke-Az @('monitor','log-analytics','workspace','show',
    '-g', $ResourceGroup, '-n', $LogAnalyticsName, '--query','id','-o','tsv')

Invoke-Az @(
    'deployment','group','create',
    '--resource-group', $ResourceGroup,
    '--name', "dpl-meeting-$MeetingId",
    '--template-file', "$PSScriptRoot/../infra/meeting.bicep",
    '--parameters',
        "location=$Location",
        "prefix=$Prefix",
        "meetingId=$MeetingId",
        "logAnalyticsWorkspaceId=$lawId",
    '-o','none'
)

# ---------- 3. Grant attendee group access to the meeting (idempotent) ----------
Write-Host ""
Write-Host "== Granting '$groupDisplay' access to meeting resources ==" -ForegroundColor Cyan

# Grant the group "Desktop Virtualization User" on the app group
$appGroupId = Invoke-Az @(
    'desktopvirtualization','applicationgroup','show',
    '-g', $ResourceGroup, '-n', $AppGroupName, '--query','id','-o','tsv'
)
$exists = & az role assignment list --assignee $groupId --scope $appGroupId `
    --role 'Desktop Virtualization User' --query '[0].id' -o tsv 2>$null
if (-not $exists) {
    Invoke-Az @(
        'role','assignment','create',
        '--assignee-object-id', $groupId,
        '--assignee-principal-type', 'Group',
        '--role', 'Desktop Virtualization User',
        '--scope', $appGroupId,
        '-o','none'
    )
}

# ---------- 4. Refresh registration token ----------
Write-Host ""
Write-Host "== Refreshing host pool registration token ==" -ForegroundColor Cyan
$expiry = (Get-Date).ToUniversalTime().AddHours(8).ToString('yyyy-MM-ddTHH:mm:ssZ')
Invoke-Az @(
    'desktopvirtualization','hostpool','update',
    '--resource-group', $ResourceGroup,
    '--name', $HostPoolName,
    '--registration-info', 'registration-token-operation=Update', "expiration-time=$expiry",
    '-o','none'
)
# `hostpool show` does NOT include registrationInfo.token (it's a
# write-only secret on that resource). Use the dedicated
# retrieve-registration-token endpoint instead.
$token = & az desktopvirtualization hostpool retrieve-registration-token `
    --resource-group $ResourceGroup --name $HostPoolName --query token -o tsv 2>$null
if (-not $token) {
    # Older CLI fallback: list-registration-tokens returns an array.
    $token = & az desktopvirtualization hostpool list-registration-tokens `
        --resource-group $ResourceGroup --name $HostPoolName --query '[0].token' -o tsv 2>$null
}
if (-not $token) { throw 'Failed to retrieve registration token.' }

# ---------- 5. Resolve image + subnet ----------
if ($ImageVersion -eq 'latest') {
    $imageId = Invoke-Az @(
        'sig','image-definition','show',
        '--resource-group', $ResourceGroup,
        '--gallery-name', $GalleryName,
        '--gallery-image-definition', $ImageDefinitionName,
        '--query','id','-o','tsv'
    )
} else {
    $imageId = Invoke-Az @(
        'sig','image-version','show',
        '--resource-group', $ResourceGroup,
        '--gallery-name', $GalleryName,
        '--gallery-image-definition', $ImageDefinitionName,
        '--gallery-image-version', $ImageVersion,
        '--query','id','-o','tsv'
    )
}
$subnetId = Invoke-Az @(
    'network','vnet','subnet','show',
    '--resource-group', $ResourceGroup,
    '--vnet-name', $VnetName,
    '--name', $SubnetName,
    '--query','id','-o','tsv'
)

# ---------- 6. Get admin password ----------
$pwdPlain = $env:AVD_GOLDEN_VM_PASSWORD
if ([string]::IsNullOrWhiteSpace($pwdPlain)) {
    throw 'Set $env:AVD_GOLDEN_VM_PASSWORD before running this script.'
}
# Defensive trim of accidental wrapping quotes (common when copy-pasted).
$pwdPlain = $pwdPlain.Trim().Trim('"').Trim("'")

# ---------- 7. Decide next index (continue numbering for re-runs) ----------
$existingNames = & az vm list -g $ResourceGroup `
    --query "[?tags.meeting=='$MeetingId'].name" -o tsv 2>$null
$existingNumbers = @()
if ($existingNames) {
    foreach ($n in ($existingNames -split "`n")) {
        if ($n -match "-sh-(\d+)$") { $existingNumbers += [int]$Matches[1] }
    }
}
$startIndex = if ($existingNumbers.Count -gt 0) {
    ($existingNumbers | Measure-Object -Maximum).Maximum + 1
} else { 0 }
$existingCount = $existingNumbers.Count

# When -Count is auto-derived from group membership it's a TARGET total
# (group has 7 members => want 7 VMs). When -Count is explicit it's an
# INCREMENT (legacy behaviour: "add N more").
if (-not $PSBoundParameters.ContainsKey('Count')) {
    $vmsToCreate = [Math]::Max(0, $Count - $existingCount)
    if ($vmsToCreate -eq 0 -and $existingCount -gt 0) {
        Write-Host "Group has $memberCount member(s); $existingCount session host(s) already exist. Nothing to provision." -ForegroundColor Yellow
    }
} else {
    $vmsToCreate = $Count
}

# ---------- 8. Create VMs + grant the access group VM Login ----------
for ($i = 0; $i -lt $vmsToCreate; $i++) {
    $idx          = $startIndex + $i
    $vmName       = "vm-$Prefix-$MeetingId-sh-{0:D2}" -f $idx
    $computerName = ('{0}{1:D2}' -f $cnBase, $idx)
    if ($computerName.Length -gt 15) { $computerName = $computerName.Substring(0,15) }

    Write-Host ""
    Write-Host "== Creating session host $vmName (computer name $computerName) ==" -ForegroundColor Cyan

    Invoke-Az @(
        'vm','create',
        '--resource-group', $ResourceGroup,
        '--name', $vmName,
        '--computer-name', $computerName,
        '--location', $Location,
        '--size', $VmSize,
        '--image', $imageId,
        '--admin-username', $AdminUsername,
        # Use --flag=value form: az's argparse treats values starting
        # with '-' as another option otherwise.
        "--admin-password=$pwdPlain",
        '--subnet', $subnetId,
        '--public-ip-address', '""',
        '--nsg', '""',
        '--security-type', 'TrustedLaunch',
        '--enable-secure-boot', 'true',
        '--enable-vtpm', 'true',
        '--os-disk-size-gb', '128',
        '--storage-sku', 'Premium_LRS',
        '--license-type', 'Windows_Client',
        '--assign-identity', '[system]',
        '--tags', "meeting=$MeetingId", "workload=AVD-Academy-POC", "environment=poc",
        '-o','none'
    )

    Write-Host '  -> Installing AADLoginForWindows extension'
    Invoke-Az @(
        'vm','extension','set',
        '--resource-group', $ResourceGroup,
        '--vm-name', $vmName,
        '--name', 'AADLoginForWindows',
        '--publisher', 'Microsoft.Azure.ActiveDirectory',
        '-o','none'
    )

    Write-Host '  -> Installing AVD agent (DSC)'
    # Configuration.ps1 in the current Configuration.zip only accepts
    # HostPoolName + RegistrationInfoToken. Entra-join is handled by
    # the AADLoginForWindows extension above, NOT by a DSC parameter
    # (older docs showed an `aadJoin` property -- it no longer exists
    # and DSC throws "A parameter cannot be found that matches ...").
    $dscSettings = @{
        modulesUrl            = $AvdAgentDscUrl
        configurationFunction = 'Configuration.ps1\AddSessionHost'
        properties            = @{
            hostPoolName          = $HostPoolName
            registrationInfoToken = $token
        }
    } | ConvertTo-Json -Depth 6 -Compress

    # az on Linux/fish mangles inline JSON (the '{' gets parsed by the
    # shell, the '"' get stripped). Write to a temp file and pass via
    # @path -- az treats a leading @ as "read from this file".
    $dscFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), "dsc-$vmName.json")
    Set-Content -LiteralPath $dscFile -Value $dscSettings -Encoding utf8
    try {
        Invoke-Az @(
            'vm','extension','set',
            '--resource-group', $ResourceGroup,
            '--vm-name', $vmName,
            '--name', 'DSC',
            '--publisher', 'Microsoft.Powershell',
            '--version', '2.83',
            '--settings', "@$dscFile",
            '-o','none'
        )
    }
    finally {
        Remove-Item -LiteralPath $dscFile -Force -ErrorAction SilentlyContinue
    }

    $vmId = Invoke-Az @('vm','show','-g',$ResourceGroup,'-n',$vmName,'--query','id','-o','tsv')

    Write-Host '  -> Granting access group "Virtual Machine User Login" on the VM'
    $exists = & az role assignment list --assignee $groupId --scope $vmId `
        --role 'Virtual Machine User Login' --query '[0].id' -o tsv 2>$null
    if (-not $exists) {
        Invoke-Az @(
            'role','assignment','create',
            '--assignee-object-id', $groupId,
            '--assignee-principal-type', 'Group',
            '--role', 'Virtual Machine User Login',
            '--scope', $vmId,
            '-o','none'
        )
    }

    if (-not $SkipClientConfig) {
        Write-Host '  -> Configuring FSLogix + Cloud Kerberos via run-command'
        $vhd = "\\$StorageAccountName.file.core.windows.net\$ProfilesShareName"
        $clientScript = @"
`$ErrorActionPreference = 'Stop'
New-Item -Path 'HKLM:\SOFTWARE\FSLogix\Profiles' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\FSLogix\Profiles' -Name 'Enabled'                      -PropertyType DWord     -Value 1                -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\FSLogix\Profiles' -Name 'VHDLocations'                 -PropertyType MultiString -Value @('$vhd')      -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\FSLogix\Profiles' -Name 'FlipFlopProfileDirectoryName' -PropertyType DWord     -Value 1                -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\FSLogix\Profiles' -Name 'VolumeType'                   -PropertyType String    -Value 'VHDX'           -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\FSLogix\Profiles' -Name 'DeleteLocalProfileWhenVHDShouldApply' -PropertyType DWord -Value 1            -Force | Out-Null
New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' -Name 'CloudKerberosTicketRetrievalEnabled' -PropertyType DWord -Value 1 -Force | Out-Null
Write-Output 'FSLogix + Kerberos configured'
"@
        Invoke-Az @(
            'vm','run-command','invoke',
            '--resource-group', $ResourceGroup,
            '--name', $vmName,
            '--command-id', 'RunPowerShellScript',
            '--scripts', $clientScript,
            '-o','none'
        )
    }

    # The AVD agent runs DomainJoinedCheck once at service start. With
    # Entra-join, AADLoginForWindows is async -- by the time DSC installs
    # the agent the join often hasn't completed yet, so the check is
    # cached as failed and the session host stays Unavailable forever
    # even though dsregcmd later reports AzureAdJoined: YES. Rebooting
    # forces RDAgentBootLoader to re-run the health checks against the
    # now-completed join state. Also makes sure the FSLogix + Cloud
    # Kerberos registry settings are picked up on first user logon.
    Write-Host '  -> Restarting VM so AVD agent re-runs health checks against the completed Entra join'
    Invoke-Az @('vm','restart','-g',$ResourceGroup,'-n',$vmName,'-o','none')
}

Write-Host ""
Write-Host "Done. Meeting '$MeetingId' has $($startIndex + $vmsToCreate) session host(s) for a group of $memberCount." -ForegroundColor Green
Write-Host ""
Write-Host "To add more attendees: add them to '$groupDisplay' in Entra. They"
Write-Host "inherit access immediately. To deploy more VMs to match a grown"
Write-Host "group, just re-run this script -- Count auto-derives from membership."
Write-Host ""
Write-Host "Verify:"
Write-Host "  az desktopvirtualization session-host list -g $ResourceGroup --host-pool-name $HostPoolName -o table"
