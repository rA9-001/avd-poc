using 'main.bicep'

// ---- Important knobs ----
param location              = 'westeurope'
param prefix                = 'avdpoc'
param goldenVmAdminUsername = 'azureadmin'
param goldenVmSize          = 'Standard_D4s_v5'

// Secret comes from environment variable, not source control.
//   export AVD_GOLDEN_VM_PASSWORD='<StrongPassword!>'
param goldenVmAdminPassword = readEnvironmentVariable('AVD_GOLDEN_VM_PASSWORD', '')
