# Azure Firewall Policy Export and Restore

PowerShell scripts to export an Azure Firewall Policy and all Rule Collection Groups to a timestamped snapshot, then restore from any export with dry-run support. Designed so a customer can capture the current state before making rule changes and restore in minutes if something goes wrong.

## How it works

`Backup-FirewallPolicy.ps1` exports the full policy and each Rule Collection Group as ARM JSON into a timestamped folder. `Restore-FirewallPolicy.ps1` reads that snapshot, verifies file integrity, and PUTs each resource back in priority order — waiting for each ARM operation to complete before moving to the next.

## Files

| File | Purpose |
|---|---|
| `Backup-FirewallPolicy.ps1` | Exports firewall policy + RCGs to a timestamped snapshot |
| `Restore-FirewallPolicy.ps1` | Restores policy + RCGs from a snapshot with dry-run support |
| `main.bicep` / `deploy.ps1` | Hub-spoke lab environment used for testing |

## Getting started

### Option A — Azure Cloud Shell (recommended)

[Azure Cloud Shell](https://shell.azure.com) is the easiest way to run these scripts. It has PowerShell 7.x and the Az module pre-installed, and you're already authenticated — no `Connect-AzAccount` needed.

```powershell
git clone https://github.com/colinweiner111/azure-firewall-policy-export-restore.git
cd azure-firewall-policy-export-restore
```

Snapshots written to `backups/` persist between Cloud Shell sessions because Cloud Shell storage is backed by an Azure file share.

### Option B — local machine

```powershell
git clone https://github.com/colinweiner111/azure-firewall-policy-export-restore.git
cd azure-firewall-policy-export-restore
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

Run this before editing any firewall rules. The snapshot is saved to `backups/<timestamp>/` and is git-ignored by default.

```powershell
.\Backup-FirewallPolicy.ps1 `
    -ResourceGroupName rg-hub-spoke-demo `
    -PolicyName        fw-policy-hub01
```

Each snapshot contains:

| File | Contents |
|---|---|
| `manifest.json` | Metadata, resource IDs, SHA256 hashes for integrity verification |
| `policy.json` | Full ARM export of the firewall policy |
| `rcg-<name>.json` | One file per Rule Collection Group |

## Roll back to a snapshot

**Step 1 — dry-run (no write/mutating API calls, shows exactly what will change):**

```powershell
.\Restore-FirewallPolicy.ps1 `
    -ResourceGroupName rg-hub-spoke-demo `
    -PolicyName        fw-policy-hub01 `
    -SnapshotPath      .\backups\2024-01-15T14-30-00Z `
    -WhatIf
```

**Step 2 — interactive restore (single confirmation prompt):**

```powershell
.\Restore-FirewallPolicy.ps1 `
    -ResourceGroupName rg-hub-spoke-demo `
    -PolicyName        fw-policy-hub01 `
    -SnapshotPath      .\backups\2024-01-15T14-30-00Z
```

**Full rollback — restore snapshot exactly, delete any RCGs added since the snapshot:**

```powershell
.\Restore-FirewallPolicy.ps1 `
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

### Restore-FirewallPolicy.ps1

| Parameter | Required | Default | Description |
|---|---|---|---|
| `ResourceGroupName` | Yes | — | Resource group containing the policy |
| `PolicyName` | Yes | — | Firewall policy name |
| `SnapshotPath` | Yes | — | Path to the timestamped snapshot folder |
| `SubscriptionId` | No | Current Az context | Azure subscription ID |
| `-WhatIf` | No | — | Show planned changes, make no write/mutating API calls |
| `-Force` | No | — | Skip all confirmation prompts (pipeline-safe) |
| `-Strict` | No | — | Also delete RCGs present in live but not in snapshot |

## Known limitations

- The target firewall policy must already exist before restoring. The scripts restore rules, not infrastructure.
- Restore is applied resource-by-resource, not as a single transaction. If it fails partway (e.g. a permissions or API error mid-run), the policy is left partially restored. Restore is **idempotent** — fix the cause and re-run the same command to finish; each step re-applies the snapshot's desired state.
- Restore disrupts in-flight connections through the firewall; plan for a brief traffic interruption.
- `backups/` is git-ignored — snapshots are not committed to source control. Store them in a secure location (e.g. Azure Blob Storage) for production use.
- Snapshot files contain your full rule set. Treat them as sensitive configuration data.

## Lab environment

`main.bicep` and `deploy.ps1` deploy a hub-spoke Azure network topology with Azure Firewall Premium — used to test these backup/restore scripts against a real policy and rule set.

### Additional requirements for deployment

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az login`)
- [Bicep CLI](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install) (`az bicep install`)

### Deploy

```powershell
.\deploy.ps1 -ResourceGroupName rg-hub-spoke-demo
```

The script prompts for a VM admin password. Deployment takes approximately 30–45 minutes, dominated by the VPN gateway provisioning.

| Parameter | Required | Default | Description |
|---|---|---|---|
| `ResourceGroupName` | Yes | — | Resource group to deploy into (created if needed) |
| `SubscriptionId` | No | Current CLI subscription | Azure subscription ID |
| `Location` | No | `centralus` | Azure region |
| `AdminUsername` | No | `azureuser` | VM administrator username |
| `AdminPassword` | No | Prompted | VM administrator password |

## License

This project is open source and available under the [MIT License](LICENSE).
