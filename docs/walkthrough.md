# AVD Academy POC — Walkthrough

End-to-end build, from a fresh subscription to attendees logging in.
For reference docs and the *why* behind each design choice, see
[../readme.md](../readme.md).

---

## 0. Before you start

You need:

- An Azure subscription with **Owner** rights (you'll create
  subscription-scoped role assignments).
- Microsoft Entra: **Cloud Application Administrator** + **Groups
  Administrator** (or Global Admin). Required for Entra Kerberos admin
  consent and the security-group operations.
- Local tooling: **Azure CLI 2.60+**, **Bicep CLI** (`az bicep
  upgrade`), **PowerShell 7+**.

Authenticate **before** running any script. Every script in this repo
is fully non-interactive (no browser pop-ups, no prompts) and reuses
the identity already signed in to `az`. Use whichever auth method fits
your environment:

```powershell
# Option A -- interactive (do this once on your workstation)
az login

# Option B -- service principal (CI/CD)
az login --service-principal -u <appId> -p <secret> --tenant <tenantId>

# Option C -- managed identity (Azure-hosted runner)
az login --identity
```

The signed-in identity needs (a) Owner on the target subscription and
(b) the Microsoft Graph permissions listed in `Configure-EntraKerberos.ps1`.

Then export the inputs every script reads from the environment:

```powershell
$env:AZURE_SUBSCRIPTION_ID  = '<sub-guid>'      # target subscription
$env:AVD_GOLDEN_VM_PASSWORD = '<strong-password>' # local admin pwd, golden VM + every session host
```

---

## 1. One-shot bootstrap (≈ 20 min)

```powershell
./scripts/Bootstrap-Poc.ps1 -FixCAPolicies
```

Fully non-interactive. The script either completes or fails — no
prompts, no browser pop-ups. It reads `$env:AZURE_SUBSCRIPTION_ID` and
`$env:AVD_GOLDEN_VM_PASSWORD` (set in Step 0) and reuses your `az`
login to call Microsoft Graph.

What happens:

1. **Deploy shared infra** (`infra/main.bicep`): RG, VNet, NAT,
   Bastion, Log Analytics, Compute Gallery, the storage account with
   Entra Kerberos enabled, and the (un-customised) golden VM.
2. **Configure Entra Kerberos** (`Configure-EntraKerberos.ps1
   -FixCAPolicies`):
   - Locates the auto-created `[Storage Account]
     <sa>.file.core.windows.net` Entra app.
   - Adds the manifest tag `kdc_enable_cloud_group_sids` (mandatory for
     cloud-only identities).
   - Grants admin consent for delegated Graph permissions
     `openid`, `profile`, `User.Read`.
   - Scans your CA policies; if any enabled MFA-requiring policy
     targets *All cloud apps*, adds the storage app to its
     `excludeApplications`. Without this, mounting the share fails with
     *System error 1327*.

When Bootstrap exits, move on to Step 2 at your own pace.

---

## 2. Customise the golden VM (manual, one-off)

1. Go to **`vm-avdpoc-gold`** in resource group `rg-avdpoc-westeurope`.
2. **Connect → Bastion** → sign in as `azureadmin` + the password you
   chose in Step 1.
3. Install every lab application. Configure Office, browsers, regional
   settings, anything else you want every attendee to see on first
   sign-in.
4. **Don't** configure FSLogix, `cmdkey`, or domain join. The session
   hosts get FSLogix + Cloud Kerberos pushed at deploy time so you can
   change targets later without re-imaging.
5. Sign out cleanly.

Then capture the image — separate command, no waiting:

```powershell
./scripts/Generalize-And-Capture.ps1 -ImageVersion 1.0.0
```

This snapshots the OS disk (safety net), runs sysprep `/generalize
/shutdown`, deallocates + generalises the VM, and publishes image
version `1.0.0` to the gallery.

---

## 3. Create your first meeting (≈ 5 min per VM, parallel)

### 3a. Create the attendee group in Entra (one per cohort / meeting)

Pick whatever naming convention works for you. Examples:
- `g-academy-2026-04-aks` for a single April cohort
- `g-customer-acme-2026q2` for a customer-specific run
- Mailbox-enabled M365 group or pure security group; both work.
  Guests (B2B) work too.

```powershell
az ad group create `
  --display-name g-academy-2026-04-aks `
  --mail-nickname g-academy-2026-04-aks `
  --description 'AKS academy cohort, April 2026'

# Add attendees -- UPN or object ID
az ad group member add --group g-academy-2026-04-aks --member-id alice@contoso.com
az ad group member add --group g-academy-2026-04-aks --member-id bob@contoso.com
```

Or do it in the Entra portal. Anything that ends up in the group counts
as "an attendee".

### 3b. Spin up the meeting

```powershell
./scripts/New-Meeting.ps1 -Initials js -AttendeeGroup g-academy-2026-04-aks
```

`-Initials js` + today's date gives the meeting ID `js20260427` and
host-pool name `vdpool-avdpoc-js20260427`. The script:

1. Reads `g-academy-2026-04-aks`. Counts members → that's the VM count.
2. Deploys the host pool, app group, workspace, scaling plan,
   diagnostic settings.
3. Grants the **attendee group**:
   - `Desktop Virtualization User` on the app group
   - `Virtual Machine User Login` on each session host VM
4. Creates one personal session host per group member, Entra-joined,
   registered with the host pool.
5. Pushes FSLogix + Cloud Kerberos config to each VM via run-command.

### 3c. Attendees connect

They open <https://client.wvd.microsoft.com> (or the Windows App), sign
in with their Entra credentials, and the meeting's desktop appears.
First sign-in creates their FSLogix profile container under
`\\<sa>.file.core.windows.net\profiles\<sid>_<upn>`.

---

## 4. Day-to-day

| Goal | Command |
|---|---|
| Add an attendee | Add to the Entra group. Done. |
| Add an attendee **and** their VM | `./scripts/New-Meeting.ps1 -Initials js -AttendeeGroup g-academy-2026-04-aks` (idempotent — provisions the missing VMs only) |
| Stop everything between sessions | `./scripts/Set-MeetingPower.ps1 -MeetingId js20260427 -State Stopped` |
| Start before the next session | `./scripts/Set-MeetingPower.ps1 -MeetingId js20260427 -State Running` (Start VM on Connect also works) |
| Cohort over | `./scripts/Remove-Meeting.ps1 -MeetingId js20260427` |
| New month | `./scripts/Update-GoldenImage.ps1 -Stage Start` then `-Stage Update` then `-Stage Capture -ImageVersion 1.0.<n>` |

---

## 5. Quick verification checklist

After Step 1 (bootstrap):

```bash
az resource list -g rg-avdpoc-westeurope -o table
# expect: vnet, nat, bastion, storage account, gallery, golden VM, LAW
az storage account show -g rg-avdpoc-westeurope --name <sa> \
  --query azureFilesIdentityBasedAuthentication
# expect: directoryServiceOptions = AADKERB
```

After Step 3 (first meeting):

```bash
M=js20260427
az desktopvirtualization session-host list \
  -g rg-avdpoc-westeurope --host-pool-name vdpool-avdpoc-$M -o table
# expect: every host Status=Available

az role assignment list --assignee <attendeeGroupObjectId> -o table
# expect: Desktop Virtualization User on app group, VM User Login on each VM
```

After an attendee signs in:

```bash
az storage file list --share-name profiles \
  --account-name <sa> --auth-mode login -o table
# expect: a folder per signed-in user containing Profile.vhdx
```

If a sign-in fails with *System error 1327* → re-run
`Configure-EntraKerberos.ps1 -FixCAPolicies` and check there's no MFA
CA policy still scoping the storage app.

---

## 6. Tear-down (optional)

```powershell
# Per meeting -- profiles on the share are kept
./scripts/Remove-Meeting.ps1 -MeetingId js20260427

# Whole POC -- nukes the RG. The Entra Kerberos app + your CA exclusion
# stay behind; remove them manually if you want a fully clean tenant.
az group delete -n rg-avdpoc-westeurope --yes --no-wait
```
