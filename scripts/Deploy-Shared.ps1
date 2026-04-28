<#
.SYNOPSIS
  Deploy the AVD Academy POC shared infrastructure (infra/main.bicep).
  Fully non-interactive -- safe for CI/CD pipelines.

.DESCRIPTION
  Wraps `az deployment sub create`. Requires that the caller has
  already authenticated to Azure (`az login`, managed identity, or
  service-principal auth). Reads the golden-VM local-admin password
  from $env:AVD_GOLDEN_VM_PASSWORD and the target subscription from
  -SubscriptionId or $env:AZURE_SUBSCRIPTION_ID. Both are required;
  the script throws if either is missing.

.EXAMPLE
  $env:AVD_GOLDEN_VM_PASSWORD = '<strong-password>'
  $env:AZURE_SUBSCRIPTION_ID  = '<sub-guid>'
  ./Deploy-Shared.ps1

  ./Deploy-Shared.ps1 -SubscriptionId <sub-guid> -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SubscriptionId    = $env:AZURE_SUBSCRIPTION_ID,
    [string] $Location          = 'westeurope',
    [string] $TemplateFile      = "$PSScriptRoot/../infra/main.bicep",
    [string] $ParametersFile    = "$PSScriptRoot/../infra/main.bicepparam",
    [string] $DeploymentName    = "dpl-avdpoc-shared-$(Get-Date -Format 'yyyyMMddHHmm')",
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'

if (-not $env:AVD_GOLDEN_VM_PASSWORD) {
    throw 'Set $env:AVD_GOLDEN_VM_PASSWORD before running this script.'
}

# Pre-flight: must already be authenticated.
& az account show -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'Not authenticated to Azure. Run `az login` (or configure a service principal / managed identity) first.'
}

if ($SubscriptionId) {
    & az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription $SubscriptionId." }
}

$subId = & az account show --query id -o tsv
Write-Host "Subscription : $subId"
Write-Host "Location     : $Location"
Write-Host "Template     : $TemplateFile"
Write-Host "Deployment   : $DeploymentName"
Write-Host ""

if ($WhatIf) {
    Write-Host '== Running what-if ==' -ForegroundColor Cyan
    & az deployment sub what-if `
        --location $Location `
        --template-file $TemplateFile `
        --parameters $ParametersFile
    return
}

Write-Host '== Deploying ==' -ForegroundColor Cyan
& az deployment sub create `
    --name $DeploymentName `
    --location $Location `
    --template-file $TemplateFile `
    --parameters $ParametersFile `
    -o table
if ($LASTEXITCODE -ne 0) { throw "Deployment failed (exit $LASTEXITCODE)" }

Write-Host ''
Write-Host 'Done. Next steps:' -ForegroundColor Green
Write-Host '  1. ./Configure-EntraKerberos.ps1   # one-time Entra config for FSLogix'
Write-Host '  2. Customise the golden VM via Bastion'
Write-Host '  3. ./Generalize-And-Capture.ps1 -ImageVersion 1.0.0'
