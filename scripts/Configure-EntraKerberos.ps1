<#
.SYNOPSIS
  One-time Entra ID configuration after enabling Entra Kerberos on the
  shared FSLogix storage account.

.DESCRIPTION
  When the storage account is created with
  azureFilesIdentityBasedAuthentication.directoryServiceOptions = 'AADKERB',
  Azure auto-creates an Entra application + service principal called
  "[Storage Account] <sa>.file.core.windows.net".

  Three things still have to happen in the tenant before users can mount
  the share:

    1. Grant admin consent for the three delegated Microsoft Graph
       permissions on that app (openid, profile, User.Read).

    2. For cloud-only identities (no on-prem AD), set the manifest tag
       'kdc_enable_cloud_group_sids' so the Entra Kerberos KDC includes
       cloud group SIDs in the ticket. Mandatory for Entra-only users.

    3. The storage app must be EXCLUDED from any Conditional Access
       policy that requires MFA. Entra Kerberos cannot satisfy MFA --
       users would get System error 1327 ("Account restrictions") when
       mounting the share.

  This script automates 1 and 2. For step 3 it scans your CA policies,
  reports which ones would block the storage app, and (with -FixCAPolicies)
  adds the storage app to each policy's excludeApplications list.

.PARAMETER StorageAccountName
  Name of the storage account hosting the FSLogix profiles share.
  Defaults to the convention used by main.bicep.

.PARAMETER FixCAPolicies
  Also patch any CA policies that target "All" cloud apps to exclude the
  storage app. Off by default -- start with a dry run.

.EXAMPLE
  ./Configure-EntraKerberos.ps1
  ./Configure-EntraKerberos.ps1 -FixCAPolicies
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ResourceGroup       = 'rg-avdpoc-westeurope',
    [string] $StorageAccountName,
    [switch] $FixCAPolicies
)

$ErrorActionPreference = 'Stop'

# Resolve storage account name if not given (single SA in the RG)
if (-not $StorageAccountName) {
    $StorageAccountName = & az storage account list -g $ResourceGroup `
        --query "[0].name" -o tsv
    if (-not $StorageAccountName) {
        throw "No storage account found in $ResourceGroup. Pass -StorageAccountName."
    }
}

$appDisplayName = "[Storage Account] $StorageAccountName.file.core.windows.net"
Write-Host "Storage account : $StorageAccountName"
Write-Host "Entra app name  : $appDisplayName"
Write-Host ''

# Ensure Microsoft.Graph PowerShell module
foreach ($m in 'Microsoft.Graph.Authentication','Microsoft.Graph.Applications','Microsoft.Graph.Identity.SignIns') {
    if (-not (Get-Module -ListAvailable $m)) {
        Write-Host "Installing module $m ..." -ForegroundColor DarkGray
        Install-Module $m -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $m -ErrorAction Stop
}

Write-Host '== Connecting to Microsoft Graph ==' -ForegroundColor Cyan
# Re-use the token from `az` so this script is fully non-interactive --
# no browser, no device-code flow. The signed-in az identity (user, SP,
# or managed identity) needs the equivalent of the scopes below:
#   Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All,
#   DelegatedPermissionGrant.ReadWrite.All, Policy.ReadWrite.ConditionalAccess
$graphTokenJson = & az account get-access-token --resource-type ms-graph -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $graphTokenJson) {
    throw 'Failed to acquire a Microsoft Graph token via `az`. Run `az login` (or configure SP/MI auth) with sufficient Graph permissions.'
}
$graphToken = ($graphTokenJson | ConvertFrom-Json).accessToken
Connect-MgGraph -NoWelcome -AccessToken (ConvertTo-SecureString $graphToken -AsPlainText -Force)

# ---------------- 1. Locate the storage app ----------------
$app = Get-MgApplication -Filter "displayName eq '$appDisplayName'" -ConsistencyLevel eventual `
        -CountVariable c -ErrorAction Stop | Select-Object -First 1
if (-not $app) {
    throw @"
App '$appDisplayName' not found. Re-check the storage account is created with
directoryServiceOptions=AADKERB. Azure creates the app on save, but it can
take a minute. Wait and retry.
"@
}
$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" | Select-Object -First 1
Write-Host "  AppId          : $($app.AppId)"
Write-Host "  App ObjectId   : $($app.Id)"
Write-Host "  SP ObjectId    : $($sp.Id)"

# ---------------- 2. Manifest tag for cloud-only group SIDs ----------------
Write-Host ''
Write-Host '== Ensuring manifest tag kdc_enable_cloud_group_sids ==' -ForegroundColor Cyan
$tag = 'kdc_enable_cloud_group_sids'
if ($app.Tags -contains $tag) {
    Write-Host '  Tag already present.'
} else {
    $newTags = @($app.Tags) + $tag
    if ($PSCmdlet.ShouldProcess($appDisplayName, "Add tag $tag")) {
        Update-MgApplication -ApplicationId $app.Id -Tags $newTags
        Write-Host '  Tag added.'
    }
}

# ---------------- 3. Grant admin consent on Graph delegated perms ----------------
Write-Host ''
Write-Host '== Granting admin consent (openid, profile, User.Read on Microsoft Graph) ==' -ForegroundColor Cyan
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$existingGrant = Get-MgOauth2PermissionGrant `
    -Filter "clientId eq '$($sp.Id)' and resourceId eq '$($graphSp.Id)' and consentType eq 'AllPrincipals'" `
    -ErrorAction SilentlyContinue
$desiredScope = 'openid profile User.Read'
if ($existingGrant) {
    $haveAll = ($desiredScope -split ' ' | ForEach-Object {
        $_ -in ($existingGrant.Scope -split ' ')
    }) -notcontains $false
    if ($haveAll) {
        Write-Host '  Consent already granted.'
    } else {
        if ($PSCmdlet.ShouldProcess($appDisplayName, 'Update Graph consent')) {
            Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId $existingGrant.Id `
                -Scope $desiredScope
            Write-Host '  Consent updated.'
        }
    }
} else {
    if ($PSCmdlet.ShouldProcess($appDisplayName, 'Grant Graph consent')) {
        New-MgOauth2PermissionGrant -BodyParameter @{
            clientId    = $sp.Id
            consentType = 'AllPrincipals'
            resourceId  = $graphSp.Id
            scope       = $desiredScope
        } | Out-Null
        Write-Host '  Consent granted.'
    }
}

# ---------------- 4. Conditional Access scan ----------------
Write-Host ''
Write-Host '== Scanning Conditional Access policies for MFA conflicts ==' -ForegroundColor Cyan
try {
    $policies = Get-MgIdentityConditionalAccessPolicy -All
} catch {
    Write-Warning "Cannot read CA policies (need Policy.Read.All). Skipping."
    Write-Warning "Manually exclude '$appDisplayName' from any MFA-required policies."
    Disconnect-MgGraph | Out-Null
    return
}

$conflicts = foreach ($p in $policies) {
    $requiresMfa = $p.GrantControls.BuiltInControls -contains 'mfa' `
                -or $p.GrantControls.AuthenticationStrength
    $targetsAll  = $p.Conditions.Applications.IncludeApplications -contains 'All'
    $targetsApp  = $p.Conditions.Applications.IncludeApplications -contains $app.AppId
    $alreadyExcluded = $p.Conditions.Applications.ExcludeApplications -contains $app.AppId
    if ($p.State -eq 'enabled' -and $requiresMfa -and ($targetsAll -or $targetsApp) -and -not $alreadyExcluded) {
        $p
    }
}

if (-not $conflicts) {
    Write-Host '  No conflicting CA policies found.' -ForegroundColor Green
} else {
    Write-Warning "Found $($conflicts.Count) CA policy/policies that would block Entra Kerberos:"
    $conflicts | ForEach-Object { Write-Host "    - $($_.DisplayName)  ($($_.Id))" }

    if ($FixCAPolicies) {
        foreach ($p in $conflicts) {
            $newExcludes = @($p.Conditions.Applications.ExcludeApplications) + $app.AppId
            if ($PSCmdlet.ShouldProcess($p.DisplayName, "Add storage app to excludeApplications")) {
                Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id `
                    -BodyParameter @{
                        conditions = @{
                            applications = @{
                                excludeApplications = $newExcludes
                            }
                        }
                    }
                Write-Host "    -> patched $($p.DisplayName)" -ForegroundColor Green
            }
        }
    } else {
        Write-Host ''
        Write-Host 'Re-run with -FixCAPolicies to add the storage app to each policy''s excludeApplications.' -ForegroundColor Yellow
    }
}

Disconnect-MgGraph | Out-Null

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host 'Next: configure clients (Intune) -- see readme step "Client-side configuration".'
