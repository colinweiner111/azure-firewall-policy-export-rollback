#Requires -Version 5.1   # minimum; PowerShell 7.x is recommended (see README)
<#
.SYNOPSIS
    Restores an Azure Firewall Policy and Rule Collection Groups from a snapshot.

.DESCRIPTION
    Loads a snapshot produced by Backup-FirewallPolicy.ps1, verifies file integrity, then
    restores policy settings and each Rule Collection Group via the ARM API. Each PUT waits
    for the operation to reach Succeeded before proceeding to the next resource.

    Default behavior (safe): restores items in the snapshot, leaves any extra RCGs in the
    live policy untouched.

    -Strict behavior (full rollback): also deletes RCGs present in live but absent from
    the snapshot, making the live policy an exact match of the snapshot.

.PARAMETER ResourceGroupName
    Resource group containing the firewall policy.

.PARAMETER PolicyName
    Name of the Azure Firewall Policy to restore.

.PARAMETER SnapshotPath
    Path to the timestamped snapshot folder (e.g. .\backups\2024-01-15T14-30-00Z).

.PARAMETER SubscriptionId
    Azure subscription ID. Defaults to the current Az context subscription.

.PARAMETER WhatIf
    Show the restore plan without making any write/mutating API calls. Read-only calls
    (login check, integrity verification, fetching live state) still run so the plan is accurate.

.PARAMETER Force
    Skip all confirmation prompts. Safe for unattended / pipeline use.

.PARAMETER Strict
    Delete Rule Collection Groups present in live but absent from the snapshot.
    Prompts before each deletion unless -Force is also set.

.EXAMPLE
    # Dry-run: see what would change without touching anything
    .\Restore-FirewallPolicy.ps1 -ResourceGroupName rg-hub-spoke-demo -PolicyName fw-policy-hub01 `
        -SnapshotPath .\backups\2024-01-15T14-30-00Z -WhatIf

.EXAMPLE
    # Interactive restore with a single confirmation prompt
    .\Restore-FirewallPolicy.ps1 -ResourceGroupName rg-hub-spoke-demo -PolicyName fw-policy-hub01 `
        -SnapshotPath .\backups\2024-01-15T14-30-00Z

.EXAMPLE
    # Full rollback: restore snapshot exactly, delete any extra RCGs, no prompts
    .\Restore-FirewallPolicy.ps1 -ResourceGroupName rg-hub-spoke-demo -PolicyName fw-policy-hub01 `
        -SnapshotPath .\backups\2024-01-15T14-30-00Z -Strict -Force
#>
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$PolicyName,

    [Parameter(Mandatory)]
    [string]$SnapshotPath,

    [string]$SubscriptionId,
    [switch]$WhatIf,
    [switch]$Force,
    [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Set once mutation begins, so Fail can warn that the policy may be partially restored.
$script:mutationStarted = $false

function Fail([string]$msg) {
    Write-Error $msg
    if ($script:mutationStarted) {
        Write-Host "The policy may be partially restored. Restore is idempotent — fix the cause above and re-run the same command to finish it." -ForegroundColor Yellow
    }
    exit 1
}

# Returns all items from a paged ARM list endpoint, following nextLink so large policies aren't truncated.
function Get-AllArmItems([string]$FirstPath) {
    $items = @()
    $resp  = Invoke-AzRestMethod -Path $FirstPath -Method GET
    while ($true) {
        if ($resp.StatusCode -ne 200) { Fail "ARM list failed (HTTP $($resp.StatusCode)) for $FirstPath." }
        $page = $resp.Content | ConvertFrom-Json
        if ($page.value) { $items += $page.value }
        $nextLink = if ($page.PSObject.Properties['nextLink']) { $page.nextLink } else { $null }
        if (-not $nextLink) { break }
        $resp = Invoke-AzRestMethod -Uri $nextLink -Method GET
    }
    return ,$items
}

# Removes named properties from a PSCustomObject in-place (read-only fields that ARM rejects on PUT).
function Remove-Fields {
    param([PSCustomObject]$Obj, [string[]]$Fields)
    foreach ($f in $Fields) { $Obj.PSObject.Properties.Remove($f) }
}

# Polls provisioningState until Succeeded or terminal failure. ARM PUTs are async (201/202).
function Wait-Provisioned {
    param([string]$Path, [string]$Label, [int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r     = Invoke-AzRestMethod -Path $Path -Method GET
        $state = ($r.Content | ConvertFrom-Json).properties.provisioningState
        if ($state -eq 'Succeeded') { return }
        if ($state -in @('Failed', 'Canceled')) { Fail "$Label provisioning entered '$state'." }
        Write-Host "    [$state] Waiting for $Label..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 10
    }
    Fail "Timed out (${TimeoutSec}s) waiting for $Label."
}

# Polls until the resource returns 404 — needed after async DELETE (202) to avoid stale post-restore output.
function Wait-Deleted {
    param([string]$Path, [string]$Label, [int]$TimeoutSec = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-AzRestMethod -Path $Path -Method GET
        if ($r.StatusCode -eq 404) { return }
        Write-Host "    [Deleting] Waiting for '$Label' to be removed..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 10
    }
    Fail "Timed out (${TimeoutSec}s) waiting for '$Label' deletion to complete."
}

# ── Prerequisite: Az module and login ────────────────────────────────────────
# Login is checked first so blob download (if requested) can use the same auth context.
if (-not (Get-Module -Name Az.Accounts -ListAvailable)) {
    Fail "Az PowerShell module not found. Install it with: Install-Module Az -Scope CurrentUser -Repository PSGallery"
}

Write-Host 'Checking Azure login...' -ForegroundColor Cyan
$context = Get-AzContext
if (-not $context) { Fail "Not logged in. Run 'Connect-AzAccount' first." }

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    $context = Get-AzContext
}
Write-Host "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -ForegroundColor Cyan

# ── Validate snapshot path and files ─────────────────────────────────────────
if (-not (Test-Path $SnapshotPath)) { Fail "Snapshot path not found: $SnapshotPath" }
$SnapshotPath = (Resolve-Path $SnapshotPath).Path

$manifestFile = Join-Path $SnapshotPath 'manifest.json'
if (-not (Test-Path $manifestFile)) { Fail "manifest.json not found in '$SnapshotPath'. Is this a valid snapshot folder?" }

Write-Host 'Loading snapshot manifest...' -ForegroundColor Cyan
$manifest = Get-Content $manifestFile -Encoding UTF8 | ConvertFrom-Json
Write-Host "  Snapshot : $($manifest.snapshotId)" -ForegroundColor DarkCyan
Write-Host "  Captured : $($manifest.capturedAt)" -ForegroundColor DarkCyan

Write-Host 'Verifying snapshot integrity...' -ForegroundColor Cyan
$policyBackupFile = Join-Path $SnapshotPath $manifest.policyFile
if (-not (Test-Path $policyBackupFile)) { Fail "Policy backup file not found: $policyBackupFile" }
if ($manifest.policySha256) {
    $h = (Get-FileHash -Path $policyBackupFile -Algorithm SHA256).Hash
    if ($h -ne $manifest.policySha256) { Fail "policy.json SHA256 mismatch — file may be corrupted or tampered with." }
}
foreach ($rcgEntry in $manifest.ruleCollectionGroups) {
    $f = Join-Path $SnapshotPath $rcgEntry.file
    if (-not (Test-Path $f)) { Fail "RCG backup file not found: $f" }
    if ($rcgEntry.sha256) {
        $h = (Get-FileHash -Path $f -Algorithm SHA256).Hash
        if ($h -ne $rcgEntry.sha256) { Fail "$($rcgEntry.file) SHA256 mismatch — file may be corrupted or tampered with." }
    }
}
Write-Host '  All files verified.' -ForegroundColor DarkGreen

# Warn if restoring into a different subscription than the snapshot was captured from.
if ($manifest.subscriptionId -and ($context.Subscription.Id -ne $manifest.subscriptionId) -and -not $Force -and -not $WhatIf) {
    Write-Warning "Snapshot was captured from subscription '$($manifest.subscriptionId)' ($($manifest.subscriptionName))."
    Write-Warning "Current subscription is '$($context.Subscription.Id)' ($($context.Subscription.Name))."
    $confirm = Read-Host 'Restore to a different subscription? (yes/no)'
    if ($confirm -ne 'yes') { Write-Host 'Aborted.' -ForegroundColor Yellow; exit 0 }
}

$subId   = $context.Subscription.Id
$apiVer  = if ($manifest.apiVersion) { $manifest.apiVersion } else { '2024-01-01' }
$base    = "/subscriptions/$subId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/firewallPolicies/$PolicyName"

# ── Fetch live state for comparison ──────────────────────────────────────────
Write-Host 'Fetching live state...' -ForegroundColor Cyan
$livePolicyResp = Invoke-AzRestMethod -Path "${base}?api-version=${apiVer}" -Method GET
if ($livePolicyResp.StatusCode -ne 200) {
    Fail "Policy '$PolicyName' not found in '$ResourceGroupName' (HTTP $($livePolicyResp.StatusCode)). Deploy the infrastructure before restoring."
}

$liveRcgList  = @(Get-AllArmItems "${base}/ruleCollectionGroups?api-version=${apiVer}")
$liveRcgNames = @($liveRcgList | ForEach-Object { $_.name })
$snapRcgNames = @($manifest.ruleCollectionGroups | ForEach-Object { $_.name })
$rcgsToDelete = @($liveRcgNames | Where-Object { $_ -notin $snapRcgNames })

# ── Show restore plan ─────────────────────────────────────────────────────────
$dryTag = if ($WhatIf) { '  [WhatIf — no changes will be made]' } else { '' }
Write-Host "`nRestore plan$dryTag" -ForegroundColor Yellow
Write-Host "  Snapshot  : $($manifest.snapshotId)"
Write-Host "  Source    : $($manifest.subscriptionName) / $($manifest.resourceGroup)"
Write-Host "  Target    : $($context.Subscription.Name) / $ResourceGroupName / $PolicyName"
Write-Host ''
Write-Host '  Policy settings will be overwritten from snapshot.'
Write-Host ''
Write-Host '  Rule Collection Groups:'
foreach ($e in ($manifest.ruleCollectionGroups | Sort-Object { $_.priority })) {
    $action = if ($e.name -in $liveRcgNames) { 'UPDATE' } else { 'CREATE' }
    Write-Host "    [$action]  $($e.name)  |  priority $($e.priority)  |  $($e.ruleCollections) collection(s)  |  $($e.totalRules) rule(s)"
}

if ($rcgsToDelete.Count -gt 0) {
    Write-Host ''
    if ($Strict) {
        Write-Host '  Extra RCGs (-Strict: will DELETE):' -ForegroundColor Red
        $rcgsToDelete | ForEach-Object { Write-Host "    [DELETE]  $_" -ForegroundColor Red }
    } else {
        Write-Host '  Extra RCGs in live policy (use -Strict to remove):' -ForegroundColor DarkYellow
        $rcgsToDelete | ForEach-Object { Write-Host "    [KEEP]    $_" -ForegroundColor DarkYellow }
    }
}

if ($WhatIf) {
    Write-Host "`n[WhatIf] No changes made.`n" -ForegroundColor Cyan
    exit 0
}

# ── Confirm ───────────────────────────────────────────────────────────────────
if (-not $Force) {
    if ($Strict -and $rcgsToDelete.Count -gt 0) {
        Write-Warning "$($rcgsToDelete.Count) Rule Collection Group(s) will be permanently DELETED."
    }
    $confirm = Read-Host "`nProceed with restore? (yes/no)"
    if ($confirm -ne 'yes') { Write-Host 'Aborted.' -ForegroundColor Yellow; exit 0 }
}

# ── Restore policy settings ───────────────────────────────────────────────────
# Past this point a failure can leave the policy partially restored; Fail will say so.
$script:mutationStarted = $true
Write-Host "`nRestoring policy settings..." -ForegroundColor Cyan
$policyBackup = Get-Content $policyBackupFile -Encoding UTF8 | ConvertFrom-Json

# Strip fields ARM rejects in PUT body.
Remove-Fields $policyBackup @('etag')
if ($policyBackup.properties) {
    Remove-Fields $policyBackup.properties @('provisioningState', 'firewalls', 'childPolicies', 'ruleCollectionGroups')
}

$putResp = Invoke-AzRestMethod -Path "${base}?api-version=${apiVer}" -Method PUT -Payload ($policyBackup | ConvertTo-Json -Depth 30)
if ($putResp.StatusCode -notin @(200, 201, 202)) {
    Fail "Failed to restore policy settings (HTTP $($putResp.StatusCode)): $($putResp.Content)"
}
Wait-Provisioned "${base}?api-version=${apiVer}" "policy '$PolicyName'"
Write-Host '  Policy settings restored.' -ForegroundColor DarkGreen

# ── Restore RCGs in priority order ────────────────────────────────────────────
Write-Host "`nRestoring rule collection groups..." -ForegroundColor Cyan
foreach ($rcgEntry in ($manifest.ruleCollectionGroups | Sort-Object { $_.priority })) {
    $rcgName = $rcgEntry.name
    $action  = if ($rcgName -in $liveRcgNames) { 'Updating' } else { 'Creating' }
    Write-Host "  $action '$rcgName' (priority $($rcgEntry.priority))..." -ForegroundColor DarkCyan

    $rcgBackup = Get-Content (Join-Path $SnapshotPath $rcgEntry.file) -Encoding UTF8 | ConvertFrom-Json
    Remove-Fields $rcgBackup @('etag')
    if ($rcgBackup.properties) {
        Remove-Fields $rcgBackup.properties @('provisioningState')
    }

    $rcgPath = "${base}/ruleCollectionGroups/${rcgName}?api-version=${apiVer}"
    $putResp = Invoke-AzRestMethod -Path $rcgPath -Method PUT -Payload ($rcgBackup | ConvertTo-Json -Depth 30)
    if ($putResp.StatusCode -notin @(200, 201, 202)) {
        Fail "Failed to restore RCG '$rcgName' (HTTP $($putResp.StatusCode)): $($putResp.Content)"
    }
    Wait-Provisioned $rcgPath "RCG '$rcgName'"
    Write-Host "    Done." -ForegroundColor DarkGreen
}

# ── Delete extra RCGs if -Strict ──────────────────────────────────────────────
if ($Strict -and $rcgsToDelete.Count -gt 0) {
    Write-Host "`nStrict mode: removing RCGs not in snapshot..." -ForegroundColor Yellow
    foreach ($rcgName in $rcgsToDelete) {
        if (-not $Force) {
            $confirm = Read-Host "  Delete '$rcgName' (not in snapshot)? (yes/no)"
            if ($confirm -ne 'yes') { Write-Host "  Skipped '$rcgName'." -ForegroundColor DarkYellow; continue }
        }
        Write-Host "  Deleting '$rcgName'..." -ForegroundColor Red
        $rcgDeletePath = "${base}/ruleCollectionGroups/${rcgName}?api-version=${apiVer}"
        $delResp = Invoke-AzRestMethod -Path $rcgDeletePath -Method DELETE
        if ($delResp.StatusCode -notin @(200, 202, 204)) {
            Fail "Failed to delete RCG '$rcgName' (HTTP $($delResp.StatusCode))."
        }
        Wait-Deleted $rcgDeletePath $rcgName
        Write-Host "  Deleted." -ForegroundColor DarkGreen
    }
}

# ── Post-restore summary ──────────────────────────────────────────────────────
Write-Host "`nPost-restore verification..." -ForegroundColor Cyan
$finalRcgList = @(Get-AllArmItems "${base}/ruleCollectionGroups?api-version=${apiVer}")

Write-Host "`nRestore complete." -ForegroundColor Green
Write-Host "  Snapshot : $($manifest.snapshotId)"
Write-Host "  Policy   : $PolicyName"
Write-Host ''
Write-Host '  Live Rule Collection Groups after restore:'
foreach ($rcg in ($finalRcgList | Sort-Object { $_.properties.priority })) {
    $rcCount   = ($rcg.properties.ruleCollections | Measure-Object).Count
    $ruleCount = 0
    if ($rcg.properties.ruleCollections) {
        foreach ($rc in $rcg.properties.ruleCollections) { $ruleCount += ($rc.rules | Measure-Object).Count }
    }
    $tag = if ($rcg.name -notin $snapRcgNames) { '  [not in snapshot]' } else { '' }
    Write-Host "    - $($rcg.name) | priority $($rcg.properties.priority) | $rcCount collection(s) | $ruleCount rule(s)$tag"
}

