# Azure Firewall Policy Export and Rollback

PowerShell scripts to export an Azure Firewall Policy and all Rule Collection Groups to a timestamped snapshot, then roll back from any snapshot with dry-run support. Designed so a customer can capture the current state before making rule changes and roll back in minutes if something goes wrong.

> **Not Azure Backup:** These scripts export ARM JSON and PUT it back through the ARM API. This is not the same as Azure Backup or Recovery Services Vault — there is no native Azure Firewall backup service. Think of it as a configuration snapshot and rollback tool.

> **Note:** This is an operational safety net for environments where firewall rules are still managed manually. It is not a replacement for Infrastructure as Code (IaC). If you are moving towards Bicep or Terraform, the JSON exports produced by these scripts can serve as a starting point for building your IaC definitions.

## When to use this

| Situation | Use it? |
|---|---|
| About to make manual rule changes in the portal or via CLI | **Yes** — snapshot first |
| Handing off a firewall to another team — document its current state | **Yes** |
| A rule change caused a connectivity issue and you need to roll back | **Yes** |
| Testing new rules in a dev/test firewall before promoting to prod | **Yes** |
| Primary backup / disaster recovery strategy | **No** — this is a safety net, not a DR tool |
| Backing up the firewall infrastructure itself (VNet, public IP, etc.) | **No** — rules only |
| Environments where rules are already managed by Bicep or Terraform | **No** — use source control and your IaC pipeline instead |
| You need transactional consistency across all rules | **No** — rollback applies one RCG at a time; the firewall stays live throughout |

## How it works

`Backup-FirewallPolicy.ps1` exports the full policy and each Rule Collection Group as ARM JSON into a timestamped folder. `Rollback-FirewallPolicy.ps1` reads that snapshot, verifies file integrity, and PUTs each resource back in priority order — waiting for each ARM operation to complete before moving to the next.

## Files

| File | Purpose |
|---|---|
| `Backup-FirewallPolicy.ps1` | Exports firewall policy + RCGs to a timestamped snapshot |
| `Rollback-FirewallPolicy.ps1` | Rolls back policy + RCGs from a snapshot with dry-run support |
| `main.bicep` / `deploy.ps1` | Hub-spoke lab environment used for testing |

## Getting started

### Option A — Azure Cloud Shell (recommended)

[Azure Cloud Shell](https://shell.azure.com) is the easiest way to run these scripts. It has PowerShell 7.x and the Az module pre-installed, and you're already authenticated — no `Connect-AzAccount` needed.

```powershell
git clone https://github.com/colinweiner111/azure-firewall-policy-export-rollback.git
cd azure-firewall-policy-export-rollback
```

The previous repository URL still redirects:
https://github.com/colinweiner111/azure-firewall-policy-export-restore

Snapshots written to `backups/` persist between Cloud Shell sessions because Cloud Shell storage is backed by an Azure file share.

### Option B — local machine

```powershell
git clone https://github.com/colinweiner111/azure-firewall-policy-export-rollback.git
cd azure-firewall-policy-export-rollback
```

Then ensure the following are in place:

- PowerShell 5.1+ (Windows PowerShell). **PowerShell 7.x is recommended** — it's the actively supported, cross-platform version. The scripts work on both.
- [Az PowerShell module](https://learn.microsoft.com/en-us/powershell/azure/install-az-ps):
  ```powershell
  Install-Module Az -Scope CurrentUser -Repository PSGallery
  ```
- Logged in to Azure:
  ```powershell
  Connect-AzAccount
  ```

## Requirements

- **Contributor** or **Network Contributor** on the resource group containing the firewall policy

## Snapshot before a change

Run this before editing any firewall rules. If something goes wrong, you can roll back to this snapshot in minutes.

```powershell
.\Backup-FirewallPolicy.ps1 `
    -ResourceGroupName rg-hub-spoke-demo `
    -PolicyName        fw-policy-hub01
```

Sample output:

```
Checking Azure login...
Subscription: Contoso Production (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
Fetching firewall policy 'fw-policy-hub01'...
Snapshot directory: .\backups\2024-01-15T14-30-00Z
Exporting rule collection groups...
  -> contosoWeb-rcg01 (priority 500)
  -> contosoOps-rcg01 (priority 600)
  -> contosoOps-test-rcg02 (priority 700)
  -> platform-all-wrkls-rcg01 (priority 800)

Snapshot complete.
  Location : .\backups\2024-01-15T14-30-00Z
  Policy   : fw-policy-hub01 (Premium tier)
  RCGs     : 4
    - contosoWeb-rcg01        | priority 500 | 3 collection(s) | 10 rule(s)
    - contosoOps-rcg01        | priority 600 | 2 collection(s) |  5 rule(s)
    - contosoOps-test-rcg02   | priority 700 | 1 collection(s) |  3 rule(s)
    - platform-all-wrkls-rcg01| priority 800 | 3 collection(s) | 14 rule(s)

To roll back using this snapshot:
  .\Rollback-FirewallPolicy.ps1 -ResourceGroupName rg-fw-lab -PolicyName fw-policy-hub01 -SnapshotPath '.\backups\2024-01-15T14-30-00Z'
```

Each snapshot contains:

| File | Contents |
|---|---|
| `manifest.json` | Metadata, resource IDs, SHA256 hashes for integrity verification |
| `policy.json` | Full ARM export of the firewall policy |
| `rcg-<name>.json` | One file per Rule Collection Group |

## Policy layout in this lab

The lab policy creates these Rule Collection Groups (lower priority number is evaluated first):

| RCG | Priority |
|---|---|
| `RCG-Platform` | 500 |
| `RCG-Identity` | 600 |
| `RCG-Management` | 700 |
| `RCG-SharedServices` | 800 |
| `RCG-AVD` | 900 |
| `RCG-AKS` | 1000 |
| `RCG-App1` | 1100 |
| `RCG-App2` | 1200 |
| `RCG-Temporary` | 60000 |

`RCG-SharedServices` contains sample allow rules at rule collection priorities `801` (network) and `802` (application). The other RCGs are created as placeholders for future workload rules.

## Roll back from a snapshot

**Step 1 — dry-run (shows exactly which rules would be rolled back, removed, or modified):**

```powershell
.\Rollback-FirewallPolicy.ps1 `
    -ResourceGroupName rg-hub-spoke-demo `
    -PolicyName        fw-policy-hub01 `
    -SnapshotPath      .\backups\2024-01-15T14-30-00Z `
    -WhatIf -Diff
```

Sample output:

```
Checking Azure login...
Subscription: Contoso Production (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
Loading snapshot manifest...
  Snapshot : 2024-01-15T14-30-00Z
  Captured : 2024-01-15T14:30:00.0000000Z
Verifying snapshot integrity...
  All files verified.
Fetching live state...

Rollback plan  [WhatIf — no changes will be made]
  Snapshot  : 2024-01-15T14-30-00Z
  Source    : Contoso Production / rg-fw-lab
  Target    : Contoso Production / rg-fw-lab / fw-policy-hub01

  Policy settings will be rolled back from snapshot.

  Rule Collection Groups:
    [UPDATE]  contosoWeb-rcg01         |  priority 500  |  3 collection(s)  |  10 rule(s)
    [UPDATE]  contosoOps-rcg01         |  priority 600  |  2 collection(s)  |   5 rule(s)
    [UPDATE]  contosoOps-test-rcg02    |  priority 700  |  1 collection(s)  |   3 rule(s)
    [UPDATE]  platform-all-wrkls-rcg01 |  priority 800  |  3 collection(s)  |  14 rule(s)

Rule-level diff  ([+] in snapshot / will be restored   [-] in live only / will be removed   [~] modified):

    [UPDATE]  contosoWeb-rcg01
      Collection: contosoWeb-net-rc01
        [-] Allow-AdminSSH-ContosoWeb
        [~] Allow-App-to-SQL
      Collection: contosoWeb-app-rc01
        [+] Allow-PaymentGateway

    [UPDATE]  contosoOps-rcg01
      (no rule changes detected)

    [UPDATE]  contosoOps-test-rcg02
      (no rule changes detected)

    [UPDATE]  platform-all-wrkls-rcg01
      (no rule changes detected)

[WhatIf] Dry run complete — the plan above shows what would be applied. Re-run without -WhatIf to execute rollback.
```

**Step 2 — roll back (single confirmation prompt):**

```powershell
.\Rollback-FirewallPolicy.ps1 `
    -ResourceGroupName rg-hub-spoke-demo `
    -PolicyName        fw-policy-hub01 `
    -SnapshotPath      .\backups\2024-01-15T14-30-00Z
```

Sample output:

```
Rollback plan
  Snapshot  : 2024-01-15T14-30-00Z
  Source    : Contoso Production / rg-fw-lab
  Target    : Contoso Production / rg-fw-lab / fw-policy-hub01

  Policy settings will be rolled back from snapshot.

  Rule Collection Groups:
    [UPDATE]  contosoWeb-rcg01         |  priority 500  |  3 collection(s)  |  10 rule(s)
    [UPDATE]  contosoOps-rcg01         |  priority 600  |  2 collection(s)  |   5 rule(s)
    [UPDATE]  contosoOps-test-rcg02    |  priority 700  |  1 collection(s)  |   3 rule(s)
    [UPDATE]  platform-all-wrkls-rcg01 |  priority 800  |  3 collection(s)  |  14 rule(s)

Proceed with rollback? (yes/no): yes

Rolling back policy settings...
  Policy settings restored.

Restoring rule collection groups...
  Updating 'contosoWeb-rcg01' (priority 500)...
    Done.
  Updating 'contosoOps-rcg01' (priority 600)...
    Done.
  Updating 'contosoOps-test-rcg02' (priority 700)...
    Done.
  Updating 'platform-all-wrkls-rcg01' (priority 800)...
    Done.

Post-restore verification...

Restore complete.
  Snapshot : 2024-01-15T14-30-00Z
  Policy   : fw-policy-hub01

  Live Rule Collection Groups after restore:
    - contosoWeb-rcg01         | priority 500 | 3 collection(s) | 10 rule(s)
    - contosoOps-rcg01         | priority 600 | 2 collection(s) |  5 rule(s)
    - contosoOps-test-rcg02    | priority 700 | 1 collection(s) |  3 rule(s)
    - platform-all-wrkls-rcg01 | priority 800 | 3 collection(s) | 14 rule(s)
```

**Full rollback — match snapshot exactly, delete any RCGs added since the export:**

```powershell
.\Rollback-FirewallPolicy.ps1 `
    -ResourceGroupName rg-hub-spoke-demo `
    -PolicyName        fw-policy-hub01 `
    -SnapshotPath      .\backups\2024-01-15T14-30-00Z `
    -Strict -Force
```

## Parameters

### Backup-FirewallPolicy.ps1

| Parameter | Required | Default | Description |
|---|---|---|---|
| `ResourceGroupName` | Yes | — | Resource group containing the policy |
| `PolicyName` | Yes | — | Firewall policy name |
| `SubscriptionId` | No | Current Az context | Azure subscription ID |
| `BackupDir` | No | `.\backups` | Root folder for snapshot storage |

### Rollback-FirewallPolicy.ps1

| Parameter | Required | Default | Description |
|---|---|---|---|
| `ResourceGroupName` | Yes | — | Resource group containing the policy |
| `PolicyName` | Yes | — | Firewall policy name |
| `SnapshotPath` | Yes | — | Path to the timestamped snapshot folder |
| `SubscriptionId` | No | Current Az context | Azure subscription ID |
| `-WhatIf` | No | — | Dry run — shows what would be applied without executing any changes |
| `-Diff` | No | — | With `-WhatIf`: fetches live RCGs and shows per-rule changes (`[+]` restored, `[-]` removed, `[~]` modified) |
| `-Force` | No | — | Skip all confirmation prompts (pipeline-safe) |
| `-Strict` | No | — | Also delete RCGs present in live but not in snapshot |

## Relation to Infrastructure as Code

These scripts are a safety net and a stepping stone — not a replacement for IaC.

| Stage | Approach |
|---|---|
| 1 | Manual changes in the portal, no safety net |
| 2 | Manual changes + snapshot/rollback ← **this repo** |
| 3 | Changes via Bicep or Terraform, policy defined in source control |
| 4 | IaC + CI/CD pipeline, every change is a reviewed PR |

The export/rollback scripts remain useful even at stage 3 and 4 — IaC defines what *should* be deployed, but if someone makes an out-of-band change in the portal the export captures what's *actually* running so you can compare and reconcile.

The JSON files produced by `Backup-FirewallPolicy.ps1` are valid ARM format and can serve as a starting point for writing Bicep or Terraform — useful if you're building IaC from an existing live policy rather than from scratch.

## Known limitations

- The target firewall policy must already exist before rollback. The scripts roll back rules, not infrastructure.
- Rollback is applied resource-by-resource, not as a single transaction. If it fails partway (e.g. a permissions or API error mid-run), the policy is left partially rolled back. The script is **idempotent** — fix the cause and re-run the same command to finish; each step re-applies the snapshot's desired state.
- Rollback disrupts in-flight connections through the firewall; plan for a brief traffic interruption.
- `backups/` is git-ignored — snapshots are not committed to source control. Store them in a secure location (e.g. Azure Blob Storage) for production use.
- Snapshot files contain your full rule set. Treat them as sensitive configuration data.

## Lab environment

`main.bicep` and `deploy.ps1` deploy a minimal Azure Firewall Premium environment with a sample policy and rule set — enough to test the backup/rollback scripts without the cost and wait time of a full hub-spoke topology.

Deploys: one VNet, one Azure Firewall Premium, one Firewall Policy with network and application rule collections. No VMs, no VPN gateways, no Bastion. Takes approximately 5–10 minutes.

### Additional requirements for deployment

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az login`)
- [Bicep CLI](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install) (`az bicep install`)

### Deploy

```powershell
.\deploy.ps1 -ResourceGroupName rg-fw-lab
```

| Parameter | Required | Default | Description |
|---|---|---|---|
| `ResourceGroupName` | Yes | — | Resource group to deploy into (created if needed) |
| `SubscriptionId` | No | Current CLI subscription | Azure subscription ID |
| `Location` | No | `centralus` | Azure region |

## License

This project is open source and available under the [MIT License](LICENSE).

