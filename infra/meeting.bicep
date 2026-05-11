targetScope = 'resourceGroup'

// =============================================================================
// AVD per-meeting resources: host pool + app group + workspace + scaling plan
// + diagnostic settings on all three control-plane objects.
//
// Session host VMs are NOT created here -- they're created by
// scripts/New-Meeting.ps1 which needs a fresh registration token + DSC
// extension at deploy time.
// =============================================================================

@description('Azure region.')
param location string

@description('Shared prefix for the whole environment (matches main.bicepparam).')
@maxLength(8)
@minLength(3)
param prefix string

@description('Meeting identifier: <admin-initials><yyyymmdd>[suffix]. Example: "js20260427" or "js20260427b".')
@maxLength(13)
@minLength(10)
param meetingId string

@description('Friendly description shown in the Workspace.')
param friendlyDescription string = 'AVD Academy lab session ${meetingId}'

@description('IANA-ish time zone name for the scaling plan, e.g. "W. Europe Standard Time".')
param scalingPlanTimeZone string = 'W. Europe Standard Time'

@description('Resource ID of the shared Log Analytics workspace.')
param logAnalyticsWorkspaceId string

@description('Tags merged onto every meeting resource.')
param tags object = {}

// ---------------- naming ----------------

var hostPoolName    = 'vdpool-${prefix}-${meetingId}'
var appGroupName    = 'vdag-${prefix}-${meetingId}'
var workspaceName   = 'vdws-${prefix}-${meetingId}'
var scalingPlanName = 'vdsp-${prefix}-${meetingId}'

var meetingTags = union(tags, {
  meeting: meetingId
})

// ---------------- Personal host pool ----------------

module hostPool 'br/public:avm/res/desktop-virtualization/host-pool:0.6.0' = {
  name: 'dpl-hp-${meetingId}'
  params: {
    name: hostPoolName
    location: location
    tags: meetingTags
    hostPoolType: 'Personal'
    personalDesktopAssignmentType: 'Automatic'
    loadBalancerType: 'Persistent'
    preferredAppGroupType: 'Desktop'
    startVMOnConnect: true
    validationEnvironment: false
    // Entra-joined session hosts: use `enablerdsaadauth:i:1` only.
    // `targetisaadjoined:i:1` is the deprecated predecessor and Microsoft
    // explicitly says not to set both -- combining them brokers the
    // session OK (user gets assigned to a VM) but the connection then
    // fails with a generic "Internal server error" on the client.
    customRdpProperty: 'enablerdsaadauth:i:1;audiocapturemode:i:1;audiomode:i:0;'
    diagnosticSettings: [
      {
        name: 'to-law'
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

module appGroup 'br/public:avm/res/desktop-virtualization/application-group:0.4.2' = {
  name: 'dpl-ag-${meetingId}'
  params: {
    name: appGroupName
    location: location
    tags: meetingTags
    applicationGroupType: 'Desktop'
    hostpoolName: hostPool.outputs.name
    description: friendlyDescription
    diagnosticSettings: [
      {
        name: 'to-law'
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

module workspace 'br/public:avm/res/desktop-virtualization/workspace:0.5.0' = {
  name: 'dpl-ws-${meetingId}'
  params: {
    name: workspaceName
    location: location
    tags: meetingTags
    applicationGroupReferences: [
      appGroup.outputs.resourceId
    ]
    diagnosticSettings: [
      {
        name: 'to-law'
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

// ---------------- Personal scaling plan ----------------
//
// Personal scaling plans control auto-start / auto-deallocate of personal
// session hosts based on user activity and time-of-day. We use one schedule
// covering all 7 days; tweak per customer needs.
//
//   Ramp-up   (07:00) - peak hours start: VMs allowed to start on connect,
//                       no deallocate on disconnect (warm-up window)
//   Peak      (09:00) - business hours: keep VMs on while users connect,
//                       no deallocate on disconnect/logoff
//   Ramp-down (18:00) - end of day: deallocate 30 min after disconnect /
//                       5 min after logoff to free compute
//   Off-peak  (22:00) - overnight: deallocate aggressively on any
//                       disconnect/logoff; Start VM on Connect still
//                       enabled so a stray user can still get in.

resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2024-04-03' = {
  name: scalingPlanName
  location: location
  tags: meetingTags
  properties: {
    timeZone: scalingPlanTimeZone
    hostPoolType: 'Personal'
    hostPoolReferences: [
      {
        hostPoolArmPath:    hostPool.outputs.resourceId
        scalingPlanEnabled: true
      }
    ]
  }
}

resource personalSchedule 'Microsoft.DesktopVirtualization/scalingPlans/personalSchedules@2024-04-03' = {
  parent: scalingPlan
  name: 'weekly'
  properties: {
    daysOfWeek: [
      'Monday'
      'Tuesday'
      'Wednesday'
      'Thursday'
      'Friday'
      'Saturday'
      'Sunday'
    ]
    rampUpStartTime:                  { hour: 7,  minute: 0 }
    rampUpAutoStartHosts:             'WithAssignedUser'
    rampUpStartVMOnConnect:           'Enable'
    rampUpActionOnDisconnect:         'None'
    rampUpMinutesToWaitOnDisconnect:  0
    rampUpActionOnLogoff:             'None'
    rampUpMinutesToWaitOnLogoff:      0

    peakStartTime:                    { hour: 9,  minute: 0 }
    peakStartVMOnConnect:             'Enable'
    peakActionOnDisconnect:           'None'
    peakMinutesToWaitOnDisconnect:    0
    peakActionOnLogoff:               'None'
    peakMinutesToWaitOnLogoff:        0

    rampDownStartTime:                { hour: 18, minute: 0 }
    rampDownStartVMOnConnect:         'Enable'
    rampDownActionOnDisconnect:       'Deallocate'
    rampDownMinutesToWaitOnDisconnect: 30
    rampDownActionOnLogoff:           'Deallocate'
    rampDownMinutesToWaitOnLogoff:    5

    offPeakStartTime:                 { hour: 22, minute: 0 }
    offPeakStartVMOnConnect:          'Enable'
    offPeakActionOnDisconnect:        'Deallocate'
    offPeakMinutesToWaitOnDisconnect: 5
    offPeakActionOnLogoff:            'Deallocate'
    offPeakMinutesToWaitOnLogoff:     5
  }
}

// ---------------- outputs ----------------

output hostPoolName       string = hostPoolName
output appGroupName       string = appGroupName
output workspaceName      string = workspaceName
output scalingPlanName    string = scalingPlanName
output appGroupResourceId string = appGroup.outputs.resourceId
