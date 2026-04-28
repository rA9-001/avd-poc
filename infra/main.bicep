targetScope = 'subscription'

// =============================================================================
// AVD Academy POC – SHARED infrastructure (deployed once)
//
// Per-meeting resources (host pool, app group, workspace, scaling plan,
// session host VMs, Entra access group) are created separately by
// infra/meeting.bicep + scripts/New-Meeting.ps1.
// =============================================================================

// ---------------- parameters ----------------

@description('Azure region for all resources.')
param location string

@description('Short prefix for all shared resources. Lowercase, 3-8 chars.')
@maxLength(8)
@minLength(3)
param prefix string

@description('Local admin username for the golden image VM.')
param goldenVmAdminUsername string

@description('Local admin password for the golden image VM.')
@secure()
param goldenVmAdminPassword string

@description('VM size for the golden image VM.')
param goldenVmSize string = 'Standard_D4s_v5'

@description('Tags applied to every resource.')
param tags object = {
  workload: 'AVD-Academy-POC'
  environment: 'poc'
}

// ---------------- naming ----------------

var resourceGroupName    = 'rg-${prefix}-${location}'
var vnetName             = 'vnet-${prefix}'
var avdSubnetName        = 'snet-avd'
var bastionSubnetName    = 'AzureBastionSubnet'
var natGwName            = 'natgw-${prefix}'
var natPipName           = 'pip-${natGwName}'
var bastionName          = 'bas-${prefix}'
var bastionPipName       = 'pip-${bastionName}'
var galleryName          = 'gal_${replace(prefix, '-', '_')}'
var imageDefinitionName  = '${prefix}-win11-m365'
var goldenVmName         = 'vm-${prefix}-gold'
var goldenVmNicName      = 'nic-${goldenVmName}'
var storageAccountName   = toLower('st${prefix}${uniqueString(subscription().id, prefix)}')
var profilesShareName    = 'profiles'
var lawName              = 'law-${prefix}'

// ---------------- resource group ----------------

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ---------------- Log Analytics workspace ----------------
//
// Sink for AVD control-plane diagnostics (host pool, app group, workspace).
// In a non-POC also feed VM Insights, Defender, etc.

module law 'br/public:avm/res/operational-insights/workspace:0.7.0' = {
  scope: rg
  name: 'dpl-law'
  params: {
    name: lawName
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dataRetention: 30
  }
}

// ---------------- NAT gateway ----------------

module natPip 'br/public:avm/res/network/public-ip-address:0.7.1' = {
  scope: rg
  name: 'dpl-natpip'
  params: {
    name: natPipName
    location: location
    tags: tags
    skuName: 'Standard'
    publicIPAllocationMethod: 'Static'
    zones: []
  }
}

module natGw 'br/public:avm/res/network/nat-gateway:1.2.2' = {
  scope: rg
  name: 'dpl-natgw'
  params: {
    name: natGwName
    location: location
    tags: tags
    publicIpResourceIds: [
      natPip.outputs.resourceId
    ]
    zone: 0
  }
}

// ---------------- VNet ----------------

module vnet 'br/public:avm/res/network/virtual-network:0.5.1' = {
  scope: rg
  name: 'dpl-vnet'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefixes: [ '10.50.0.0/16' ]
    subnets: [
      {
        name: avdSubnetName
        addressPrefix: '10.50.1.0/24'
        natGatewayResourceId: natGw.outputs.resourceId
      }
      {
        name: bastionSubnetName
        addressPrefix: '10.50.2.0/26'
      }
    ]
  }
}

var avdSubnetResourceId = vnet.outputs.subnetResourceIds[0]

// ---------------- Bastion ----------------

module bastionPip 'br/public:avm/res/network/public-ip-address:0.7.1' = {
  scope: rg
  name: 'dpl-baspip'
  params: {
    name: bastionPipName
    location: location
    tags: tags
    skuName: 'Standard'
    publicIPAllocationMethod: 'Static'
    zones: []
  }
}

module bastion 'br/public:avm/res/network/bastion-host:0.8.2' = {
  scope: rg
  name: 'dpl-bastion'
  params: {
    name: bastionName
    location: location
    tags: tags
    virtualNetworkResourceId: vnet.outputs.resourceId
    bastionSubnetPublicIpResourceId: bastionPip.outputs.resourceId
    skuName: 'Basic'
  }
}

// ---------------- Storage account + FSLogix profiles share ----------------
//
// One shared SA, one shared 'profiles' share for ALL meetings.
// Why not per-meeting SAs? See readme -> Design notes -> Storage isolation.
//
// Identity-based auth: Microsoft Entra Kerberos (cloud-only, no DC).
// `defaultSharePermission` grants every authenticated identity the
// "Storage File Data SMB Share Contributor" role on every share -- this
// is the only share-level permission model supported by the cloud-only
// preview (per-user/group share-level RBAC requires hybrid identities).
// File/folder NTFS ACLs still apply on top, set by FSLogix per profile.

module storage 'br/public:avm/res/storage/storage-account:0.32.0' = {
  scope: rg
  name: 'dpl-storage'
  params: {
    name: storageAccountName
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
      defaultSharePermission:  'StorageFileDataSmbShareContributor'
    }
    fileServices: {
      shares: [
        {
          name: profilesShareName
          accessTier: 'TransactionOptimized'
          shareQuota: 100
        }
      ]
    }
  }
}

// ---------------- Compute Gallery + image definition ----------------

module gallery 'br/public:avm/res/compute/gallery:0.8.2' = {
  scope: rg
  name: 'dpl-gallery'
  params: {
    name: galleryName
    location: location
    tags: tags
    description: 'AVD Academy POC shared image gallery'
    images: [
      {
        name: imageDefinitionName
        osType: 'Windows'
        osState: 'Generalized'
        hyperVGeneration: 'V2'
        securityType: 'TrustedLaunch'
        identifier: {
          publisher: 'contoso'
          offer: 'win11-avd-academy'
          sku: '24h2-m365'
        }
      }
    ]
  }
}

// ---------------- Golden image VM (private IP only, reach via Bastion) ----------------

module vm 'br/public:avm/res/compute/virtual-machine:0.12.2' = {
  scope: rg
  name: 'dpl-goldenvm'
  params: {
    name: goldenVmName
    location: location
    tags: tags
    vmSize: goldenVmSize
    osType: 'Windows'
    zone: 0
    adminUsername: goldenVmAdminUsername
    adminPassword: goldenVmAdminPassword
    encryptionAtHost: false
    securityType: 'TrustedLaunch'
    imageReference: {
      publisher: 'microsoftwindowsdesktop'
      offer: 'office-365'
      sku: 'win11-24h2-avd-m365'
      version: 'latest'
    }
    osDisk: {
      caching: 'ReadWrite'
      diskSizeGB: 128
      managedDisk: {
        storageAccountType: 'Premium_LRS'
      }
    }
    nicConfigurations: [
      {
        name: goldenVmNicName
        ipConfigurations: [
          {
            name: 'ipconfig1'
            subnetResourceId: avdSubnetResourceId
          }
        ]
      }
    ]
  }
}

// ---------------- outputs ----------------

output resourceGroupName     string = rg.name
output goldenVmName          string = goldenVmName
output galleryName           string = galleryName
output imageDefinitionName   string = imageDefinitionName
output bastionName           string = bastionName
output vnetName              string = vnetName
output avdSubnetName         string = avdSubnetName
output avdSubnetResourceId   string = avdSubnetResourceId
output storageAccountName    string = storageAccountName
output profilesShareName     string = profilesShareName
output logAnalyticsWorkspaceName string = lawName
output logAnalyticsWorkspaceId   string = law.outputs.resourceId
