# AVD Academy POC

Reproducible Azure Virtual Desktop environment for **academy / lab
sessions where each meeting is owned by one admin and may include
attendees from multiple customer organisations**.

The shared Azure infra is deployed once. Each meeting (= one academy
session run by one admin on a given date) gets its own host pool +
application group + workspace + scaling plan + N personal session host
VMs, where N = members of the Entra access group you pass in.
Meetings can be powered down between sessions to save cost and removed
completely when finished.

> **New here?** Follow the linear walkthrough in [docs/walkthrough.md](docs/walkthrough.md).
> The sections below are reference material.

---

## Concepts

- **Shared infra** ([infra/main.bicep](infra/main.bicep)) – RG, VNet,
  NAT, Bastion, storage account with FSLogix `profiles` share, Compute
  Gallery, golden VM, Log Analytics workspace. Deploy once.
- **Golden image** – Customise the golden VM, then capture an image
  version into the gallery. Every meeting deploys session hosts from this
  image. Refresh monthly via [scripts/Update-GoldenImage.ps1](scripts/Update-GoldenImage.ps1).
- **Meeting** ([infra/meeting.bicep](infra/meeting.bicep) +
  [scripts/New-Meeting.ps1](scripts/New-Meeting.ps1)) – one Personal
  host pool per session, identified by `<admin-initials><yyyymmdd>[suffix]`,
  e.g. `js20260427` or `js20260427b`. Multiple customers can attend a
  single meeting.
- **Access group** – Each meeting has an Entra security group
  `avd-meeting-<initials>-<yyyymmdd>[suffix]`. Add attendees to the group;
  they automatically inherit all required AVD/VM roles. No per-user role
  assignments needed.
- **Scaling plan** – Per-meeting Personal scaling plan auto-deallocates
  VMs after disconnect/logoff during ramp-down/off-peak hours. Combined
  with Start VM on Connect this is the main cost lever during a session.
- **FSLogix profiles** – Stored on the shared `profiles` SMB share so a
  user's desktop, AppData and documents follow them across VM rebuilds
  and across meetings.
- **Bulk power control** – `Set-MeetingPower.ps1` deallocates an entire
  meeting between sessions; `Remove-Meeting.ps1` deletes everything when
  done.

---

## Repository layout

```
infra/
  main.bicep         # shared infra (deploy once)
  main.bicepparam    # the few knobs you actually set
  meeting.bicep      # host pool + app group + workspace + scaling plan, per meeting
scripts/
  Bootstrap-Poc.ps1            # one-shot orchestrator: deploy + Kerberos + capture
  Deploy-Shared.ps1            # az deployment sub create wrapper for main.bicep
  Configure-EntraKerberos.ps1  # one-time Entra config: consent, manifest tag, CA exclusion
  Generalize-And-Capture.ps1   # snapshot + sysprep + capture image version
  Update-GoldenImage.ps1       # monthly refresh wrapper (Win + Office update -> capture)
  New-Meeting.ps1              # create meeting from an Entra group (1 VM per member, FSLogix+Kerberos auto-pushed)
  Set-MeetingPower.ps1         # bulk start / deallocate VMs in a meeting
  Remove-Meeting.ps1           # full teardown of a meeting (incl. Entra group)
readme.md
```

---

## End-to-end workflow

```
[Step 0]  One-shot bootstrap         ->  ./Bootstrap-Poc.ps1 -FixCAPolicies
          (deploy + Kerberos + prompts you to customise golden VM + capture)

[Step 1]  For each new meeting:
            ./New-Meeting.ps1 -Initials js -AttendeeGroup g-academy-2026-04
            -> meeting js<today>, one VM per member of that Entra group,
               group is granted desktop + VM login, FSLogix + Cloud Kerberos
               pushed to each host
[Step 2]  Between sessions (cost):
            ./Set-MeetingPower.ps1 -MeetingId js20260427 -State Stopped
            ./Set-MeetingPower.ps1 -MeetingId js20260427 -State Running
[Step 3]  When the meeting is done:
            ./Remove-Meeting.ps1 -MeetingId js20260427
[Step N]  Monthly:
            ./Update-GoldenImage.ps1 -ImageVersion 1.0.<n>
```

If you'd rather drive each phase yourself (or re-run a single step):
`Deploy-Shared.ps1` → `Configure-EntraKerberos.ps1` → customise golden
VM → `Generalize-And-Capture.ps1` → `New-Meeting.ps1`. The bootstrap
script just chains those.
            ./New-Meeting.ps1 -Initials js -Count 5
            -> meeting js<today>, 5 personal VMs, Entra access group
            -> just add attendees to the group
[Step 5]  Between sessions (cost):
            ./Set-MeetingPower.ps1 -MeetingId js20260427 -State Stopped
            ./Set-MeetingPower.ps1 -MeetingId js20260427 -State Running
[Step 6]  When the meeting is done:
            ./Remove-Meeting.ps1 -MeetingId js20260427
[Step N]  Monthly:
            ./Update-GoldenImage.ps1 -ImageVersion 1.0.<n>
```

---

## Prerequisites

- Azure subscription, permission to create RGs + role assignments at
  subscription scope.
- Azure CLI 2.60+ and Bicep CLI (`az bicep upgrade`).
- PowerShell 7+.
- Permission to create Entra security groups (Groups Administrator role
  in Entra is the minimum, or a custom role with
  `microsoft.directory/groups/create`). Attendees do not need to be
  Entra admins.

---

## Step 0 — One-shot bootstrap (recommended)

```powershell
az login                       # if not already
./scripts/Bootstrap-Poc.ps1 -FixCAPolicies
```

What it does, in order:

1. Picks a subscription (if you have more than one) and prompts for the
   golden VM local-admin password.
2. Runs `Deploy-Shared.ps1` → deploys `infra/main.bicep`.
3. Runs `Configure-EntraKerberos.ps1 -FixCAPolicies` → admin consent,
   manifest tag, CA exclusion (will prompt for Microsoft Graph sign-in).
4. Pauses and tells you to RDP into `vm-avdpoc-gold` via Bastion,
   install lab apps, sign out, then type `done` in the terminal.
5. Runs `Generalize-And-Capture.ps1 -ImageVersion 1.0.0` → snapshot,
   sysprep, publish image v1.0.0 to the gallery.

After that, every new meeting is a single command (Step 1 below).

The sub-sections below explain each phase if you'd rather run them
individually.

---

## Step 1 — Deploy the shared infrastructure (once)

```powershell
az login                       # subscription picker is built into the script
$env:AVD_GOLDEN_VM_PASSWORD = '<StrongPassword!>'   # optional; will prompt otherwise
./scripts/Deploy-Shared.ps1
./scripts/Deploy-Shared.ps1 -WhatIf                 # preview
```

The script wraps `az deployment sub create` against `infra/main.bicep`
+ `infra/main.bicepparam`. If you have multiple subscriptions it lists
them and lets you pick.

You get: `rg-avdpoc-westeurope`, VNet, NAT, Bastion, storage account
(with **Entra Kerberos enabled** for the `profiles` share), Log
Analytics workspace, Compute Gallery (image definition only — no
version yet), and the golden VM `vm-avdpoc-gold` (private IP only).

---

## Step 1b — Configure Entra Kerberos (one-off per tenant + storage account)

Azure auto-creates an Entra application registration the first time the
storage account is saved with `directoryServiceOptions = AADKERB`,
called `[Storage Account] <sa>.file.core.windows.net`. Three things
must still happen in the tenant before users can mount the share:

1. Grant admin consent for the app's three delegated Microsoft Graph
   permissions (`openid`, `profile`, `User.Read`).
2. Add the manifest tag `kdc_enable_cloud_group_sids` (mandatory for
   cloud-only identities — without it, Entra Kerberos won't include
   cloud group SIDs in the ticket and authentication fails).
3. **Exclude the storage app from any Conditional Access policy that
   requires MFA.** Entra Kerberos can't satisfy MFA — without the
   exclusion users get `System error 1327: Account restrictions are
   preventing this user from signing in` when mounting the share.

All three are automated by:

```powershell
./scripts/Configure-EntraKerberos.ps1                 # dry-run for CA
./scripts/Configure-EntraKerberos.ps1 -FixCAPolicies  # also patch CA policies
```

The script connects to Microsoft Graph (you'll be prompted) and:
- Finds the auto-created storage app and service principal.
- Adds the `kdc_enable_cloud_group_sids` tag if missing.
- Grants admin consent for the three Graph permissions.
- Scans Conditional Access; if any enabled MFA-requiring policy targets
  *All cloud apps*, lists it (and with `-FixCAPolicies` adds the
  storage app to its `excludeApplications`).

> **Service principal password rotation.** The auto-created storage app's
> password expires every six months. Symptom: users suddenly can't get
> Kerberos tickets. Re-run `Configure-EntraKerberos.ps1` (or rotate via
> portal) to regenerate the key. Calendar this.

---

## Step 2 — Customise the golden VM (manual, one-off)

1. Portal → `vm-avdpoc-gold` → **Connect → Bastion**.
2. Sign in as the local admin (`azureadmin` / your password).
3. Install **all** lab applications and configure them. Whatever ends up
   in the image is what every user starts with on every fresh VM.
4. **Do NOT** configure FSLogix or Cloud Kerberos here. `New-Meeting.ps1`
   pushes those settings per-VM via `az vm run-command` after each
   session host is created — so you can repoint to a different storage
   account or share later without rebuilding the image.
5. Sign out. **Do not** join the VM to a domain or to Entra ID.
---

## Step 3 — Capture the image (automated)

```powershell
./scripts/Generalize-And-Capture.ps1 -ImageVersion 1.0.0
```

What it does:
- Snapshots the OS disk first (safety net — sysprep is one-way).
- Runs sysprep `/generalize /shutdown` inside the VM via `az vm run-command`.
- Waits for the VM to stop.
- Deallocates + generalises the VM.
- Publishes a new image version into the gallery (Premium_LRS, 1 replica).

Bump `-ImageVersion` each time you re-capture; the script refuses to
overwrite an existing version. Delete old snapshots manually once you've
verified the new image works.

---

## Step 4 — Spin up a meeting

```powershell
# Default Date = today (yyyyMMdd) -> MeetingId = "js20260427"
./scripts/New-Meeting.ps1 -Initials js -AttendeeGroup g-academy-2026-04
```

The attendee group must already exist in Entra (you create one per
meeting / per cohort and add the participants to it; mailbox-enabled
M365 groups or pure security groups both work, including B2B guests).
The script reads the group's membership and provisions one personal
session host per member.

What it does:
1. Grants the AVD service principal **Desktop Virtualization Power On
   Off Contributor** on the resource group (idempotent — needed once for
   Start VM on Connect).
2. Deploys [infra/meeting.bicep](infra/meeting.bicep) →
   - `vdpool-avdpoc-js20260427` (Personal, Automatic, persistent LB,
     Start VM on Connect)
   - `vdag-avdpoc-js20260427`
   - `vdws-avdpoc-js20260427`
   - `vdsp-avdpoc-js20260427` (Personal scaling plan; see schedule below)
   - Diagnostic settings on host pool / app group / workspace → Log
     Analytics
3. Grants the **attendee group** you passed:
   - `Desktop Virtualization User` on the meeting's app group
   - `Virtual Machine User Login` on each session host VM
4. Refreshes the host pool registration token (8 h validity).
5. Creates `<group-member-count>` session host VMs (override with
   `-Count`) from the latest gallery image, each with: Trusted Launch,
   Premium SSD, system-assigned identity, no public IP, AAD join + AVD
   DSC extensions, tag `meeting=js20260427`.
6. **Pushes FSLogix + Cloud Kerberos config into each VM** via
   `az vm run-command` (no Intune required):
   - FSLogix Profiles: `Enabled`, `VHDLocations`, `FlipFlopProfileDirectoryName`,
     `VolumeType=VHDX`, `DeleteLocalProfileWhenVHDShouldApply`
   - `HKLM\...\Lsa\Kerberos\Parameters\CloudKerberosTicketRetrievalEnabled = 1`
   Pass `-SkipClientConfig` if you'd rather push these via Intune (see
   appendix "Optional: Intune-managed client config" below).

**Adding more attendees later** — just add them to the Entra group; they
inherit access immediately. To grow the VM pool to match a grown
group, re-run the same command — `Count` auto-derives from membership
and the script tops up the difference.

```powershell
./scripts/New-Meeting.ps1 -Initials js -AttendeeGroup g-academy-2026-04   # idempotent top-up
./scripts/New-Meeting.ps1 -Initials js -AttendeeGroup g-academy-2026-04 -Count 0   # roles only
```

Users open <https://client.wvd.microsoft.com> or the Windows App, sign
in with Entra, and the meeting's desktop appears.

**Naming examples**

| Command | Meeting ID |
|---|---|
| `-Initials js` (today = 20260427) | `js20260427` |
| `-Initials js -Date 20260601` | `js20260601` |
| `-Initials js -Suffix b` (2nd of the day) | `js20260427b` |
| `-Initials mk` | `mk20260427` |

---

## Step 5 — Bulk power management (cost control)

```powershell
# Two weeks idle: deallocate every VM
./scripts/Set-MeetingPower.ps1 -MeetingId js20260427 -State Stopped

# Pre-warm before a session (or rely on Start VM on Connect / scaling plan)
./scripts/Set-MeetingPower.ps1 -MeetingId js20260427 -State Running
```

`Stopped` deallocates → no compute cost, only OS-disk storage (~few EUR
per VM per month for 128 GiB Premium SSD). `Running` starts them in
parallel.

You have **three independent cost-saving mechanisms** working together:

| Mechanism | Granularity | Trigger | Cost saved |
|---|---|---|---|
| **Start VM on Connect** | per VM | First user connection | Most per-VM idle time |
| **Personal scaling plan** | per meeting, time-based | Disconnect/logoff during ramp-down or off-peak hours | Forgotten sessions, end-of-day |
| **`Set-MeetingPower -State Stopped`** | whole meeting, manual | You run it | Long gaps between sessions |

Default scaling plan schedule (in [infra/meeting.bicep](infra/meeting.bicep),
W. Europe time):

| Phase | Start | Behaviour |
|---|---|---|
| Ramp-up | 07:00 | VMs allowed to start on connect |
| Peak | 09:00 | Stay on while users connected; no auto-stop |
| Ramp-down | 18:00 | Deallocate 30 min after disconnect, 5 min after logoff |
| Off-peak | 22:00 | Deallocate 5 min after disconnect/logoff; Start VM on Connect still on |

Tweak the times / actions in `meeting.bicep` if your sessions run on a
different rhythm.

### Even cheaper: switch idle disks to Standard SSD

When a meeting is going to be idle for weeks, also drop the disks down
to Standard SSD to cut disk cost roughly in half. Flip back to Premium
before the next session.

```bash
M=js20260427
RG=rg-avdpoc-westeurope
for D in $(az vm list -g $RG --query "[?tags.meeting=='$M'].storageProfile.osDisk.managedDisk.id" -o tsv); do
  az disk update --ids $D --sku StandardSSD_LRS -o none
done
# ... and back to Premium_LRS before the next session
```

---

## Step 6 — Tear down a meeting

```powershell
./scripts/Remove-Meeting.ps1 -MeetingId js20260427
```

Deletes every VM tagged with that meeting (plus their NICs and OS
disks), then the scaling plan, workspace, application group, host pool,
Entra access group, and deployment record.

Pass `-KeepGroup` if you want to retain the Entra group (e.g. for an
audit trail or because you'll re-run the same meeting later).
**FSLogix profiles on the `profiles` SMB share are deliberately NOT
deleted** — keep them if a returning attendee might want their old data,
otherwise clean up the share manually.

---

## Step N — Refresh the golden image (monthly)

```powershell
./scripts/Update-GoldenImage.ps1 -ImageVersion 1.0.5
```

Starts the (generalised) golden VM, prompts you to complete OOBE once
via Bastion, runs Windows Update + Office click-to-run update, then
hands off to `Generalize-And-Capture.ps1` to publish the new version.
New meetings created after this immediately pick up the new image (the
script defaults `-ImageVersion latest`).

---

## Design notes

### Why one storage account for all meetings (not one per meeting)

Considered per-meeting SAs. Rejected for the POC because:
- The Entra Kerberos enablement (manifest tag, admin consent, CA
  exclusion) is per-storage-account and per-tenant — multiplying SAs
  multiplies the one-off setup, the rotating SP password risk, and the
  CA exclusion list.
- Quota: 250 storage accounts per subscription per region (raisable but
  real); academies running 50+ sessions a year would burn through it.
- Idle SAs cost a few EUR/month each — meaningful at scale.
- Returning attendees keep their profile automatically with one shared SA.

If meeting-level data isolation ever becomes a hard requirement, the
right next step is **one share per meeting on the shared SA**
(`profiles-js20260427`), pushed via a per-meeting Intune FSLogix profile
that overrides `VHDLocations`. Per-SA only makes sense for hard tenant
isolation (separate keys, PE, RBAC) — out of scope here.

### Personal vs Pooled host pool

Personal — every attendee gets their own VM, permanently bound on first
sign-in, and Start VM on Connect handles cost. Pooled is for shared
desktops (knowledge workers logging into any spare VM). Academy use case
maps to Personal.

### Why an Entra group instead of per-user role assignments

You bring an existing security group (one per cohort/meeting) and pass
it to `New-Meeting.ps1`. The script grants the **group** the
`Desktop Virtualization User` role on the meeting's app group and the
`Virtual Machine User Login` role on each VM — not each user. That
means:

- Two role assignments total per meeting (one on the app group, one per
  VM but to the group, not to each user).
- Adding/removing an attendee is a single action in Entra; access is
  effective immediately, no script re-run needed.
- Membership count is also the source of truth for VM count, so the
  whole "how many machines do we need?" question collapses to "how big
  is the group?".
- Attendees from multiple customer tenants can be added (B2B guests in
  the host tenant work with Entra-joined VMs).

### Scaling plan caveats

Scaling plans need the AVD service principal to have
`Desktop Virtualization Power On Off Contributor` on the RG —
`New-Meeting.ps1` grants this idempotently. The plan only acts on
**deallocation** (Personal pools); it never deletes / removes session
hosts.

---

## What's intentionally NOT in this POC

- No private endpoint on the storage account. SMB authentication uses
  Entra Kerberos (no storage account key in clients), but traffic
  reaches the public storage endpoint via the host's outbound NAT.
- No Defender for Cloud, Azure Policy, Azure Backup, Update Manager.
- No prescriptive Conditional Access policy. Recommended: require MFA
  on the AVD client app `9cdead84-a844-4324-93f2-b2e6bb768d07`, and
  ensure that policy (or any other MFA policy) **excludes** the
  `[Storage Account] <sa>.file.core.windows.net` app — handled by
  `Configure-EntraKerberos.ps1 -FixCAPolicies`.
- Bastion **Basic** SKU — no native client, no file copy. Standard SKU
  pays for itself if admins have to drop installers onto the golden VM.
- AVM module versions are pinned in the Bicep files. If you hit
  *"artifact does not exist"*, browse
  <https://github.com/Azure/bicep-registry-modules/tree/main/avm/res>
  and bump.
- DSC artifact URL in `New-Meeting.ps1` is pinned. Bump it as needed
  (<https://learn.microsoft.com/azure/virtual-desktop/whats-new-agent>).
- `Remove-Meeting.ps1` does irreversible deletes of disks and groups.
  Always confirm the `-MeetingId`. The script prompts unless you pass
  `-Force`.

---

## Useful queries

```bash
# All resources for a meeting
az resource list -g rg-avdpoc-westeurope --tag meeting=js20260427 -o table

# Power state of every VM in a meeting
az vm list -g rg-avdpoc-westeurope -d \
  --query "[?tags.meeting=='js20260427'].{name:name,power:powerState}" -o table

# Connection events for a meeting (Log Analytics)
az monitor log-analytics query -w <law-guid> --analytics-query '
  WVDConnections
  | where _ResourceId has "js20260427"
  | summarize Connections=count() by UserName=tostring(UserName), bin(TimeGenerated, 1d)
  | order by TimeGenerated desc
'
```

---

## Appendix — Optional: Intune-managed client config

The default flow pushes FSLogix + Cloud Kerberos config per-VM via
`az vm run-command` from `New-Meeting.ps1` — no Intune required. If
you'd prefer a centrally-managed approach (so changing
`VHDLocations` is a one-place edit instead of per-VM), pass
`-SkipClientConfig` to `New-Meeting.ps1` and create the two profiles
below in **Intune → Devices → Configuration → Settings catalog** once,
assigned to a dynamic group of your AVD devices.

### Profile A — Allow retrieving the cloud kerberos ticket during the logon
- Category: *Administrative Templates → System → Kerberos*
- Setting: **Allow retrieving the cloud kerberos ticket during the logon** = Enabled
- (Use Settings Catalog, not OMA-URI — OMA-URI doesn't apply on AVD multi-session.)

### Profile B — FSLogix Profile Containers
- *Administrative Templates → FSLogix → Profile Containers*
  - **Enabled** = Enabled
  - **VHD Locations** = `\\<storageAccount>.file.core.windows.net\profiles`
  - **Flip Flop Profile Directory Name** = Enabled
  - **Volume Type (VHD or VHDX)** = VHDX

The default share permission `StorageFileDataSmbShareContributor` (set
on the storage account in Bicep) gives every authenticated user
read/write/delete on the share, so FSLogix can create and own its own
profile folder.

