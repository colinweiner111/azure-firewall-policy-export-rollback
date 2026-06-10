#Requires -Version 5.1   # minimum; PowerShell 7.x is recommended (see README)
<#
.SYNOPSIS
    Backs up an Azure Firewall Policy and all Rule Collection Groups to a timestamped snapshot.

.DESCRIPTION
    Exports the full firewall policy resource and each Rule Collection Group into separate JSON
    files under a timestamped folder. A manifest.json with SHA256 integrity hashes and snapshot
    metadata is written alongside the exports. Use Rollback-FirewallPolicy.ps1 to roll back.

.PARAMETER ResourceGroupName
    Resource group containing the firewall policy.

.PARAMETER PolicyName
    Name of the Azure Firewall Policy to back up.

.PARAMETER SubscriptionId
    Azure subscription ID. Defaults to the current Az context subscription.

.PARAMETER BackupDir
    Root directory for snapshot storage. Defaults to a 'backups' folder next to this script.

.EXAMPLE
    .\Backup-FirewallPolicy.ps1 -ResourceGroupName rg-hub-spoke-demo -PolicyName fw-policy-hub01

.EXAMPLE
    .\Backup-FirewallPolicy.ps1 -ResourceGroupName rg-hub-spoke-demo -PolicyName fw-policy-hub01 -BackupDir D:\fw-backups
#>
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$PolicyName,

    [string]$SubscriptionId,

    [string]$BackupDir = (Join-Path $PSScriptRoot 'backups')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$msg) { Write-Error $msg; exit 1 }

# Writes text as UTF-8 without a BOM (portable across PowerShell 5.1 and 7.x).
# Requires an absolute path — relative paths resolve against the process directory, not the PS location.
function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
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

# ── Prerequisite: Az module ───────────────────────────────────────────────────
if (-not (Get-Module -Name Az.Accounts -ListAvailable)) {
    Fail "Az PowerShell module not found. Install it with: Install-Module Az -Scope CurrentUser -Repository PSGallery"
}

# ── Login check ───────────────────────────────────────────────────────────────
Write-Host 'Checking Azure login...' -ForegroundColor Cyan
$context = Get-AzContext
if (-not $context) { Fail "Not logged in. Run 'Connect-AzAccount' first." }

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    $context = Get-AzContext
}

$subId   = $context.Subscription.Id
$subName = $context.Subscription.Name
Write-Host "Subscription: $subName ($subId)" -ForegroundColor Cyan

$apiVer  = '2024-01-01'
$base    = "/subscriptions/$subId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/firewallPolicies/$PolicyName"

# ── Verify the policy exists ──────────────────────────────────────────────────
Write-Host "Fetching firewall policy '$PolicyName'..." -ForegroundColor Cyan
$policyResp = Invoke-AzRestMethod -Path "${base}?api-version=${apiVer}" -Method GET
if ($policyResp.StatusCode -ne 200) {
    Fail "Policy '$PolicyName' not found in '$ResourceGroupName' (HTTP $($policyResp.StatusCode)). Verify the name and subscription."
}
$policy = $policyResp.Content | ConvertFrom-Json

# ── Create snapshot directory ─────────────────────────────────────────────────
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

$timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ssZ')
$snapshotDir = Join-Path $BackupDir $timestamp
New-Item -ItemType Directory -Path $snapshotDir | Out-Null
$snapshotDir = (Resolve-Path $snapshotDir).Path   # absolute path for Write-Utf8NoBom
Write-Host "Snapshot directory: $snapshotDir" -ForegroundColor Cyan

# ── Save policy.json ──────────────────────────────────────────────────────────
# Store the raw ARM response so the restore script can PUT it back with full fidelity.
$policyFile = Join-Path $snapshotDir 'policy.json'
Write-Utf8NoBom $policyFile $policyResp.Content
$policySha  = (Get-FileHash -Path $policyFile -Algorithm SHA256).Hash

# ── Save Rule Collection Groups ───────────────────────────────────────────────
Write-Host 'Exporting rule collection groups...' -ForegroundColor Cyan

$rcgList = @(Get-AllArmItems "${base}/ruleCollectionGroups?api-version=${apiVer}")

$rcgEntries = @()

foreach ($rcgSummary in ($rcgList | Sort-Object { $_.properties.priority })) {
    $rcgName  = $rcgSummary.name
    $priority = $rcgSummary.properties.priority
    Write-Host "  -> $rcgName (priority $priority)" -ForegroundColor DarkCyan

    $rcgResp = Invoke-AzRestMethod -Path "${base}/ruleCollectionGroups/${rcgName}?api-version=${apiVer}" -Method GET
    if ($rcgResp.StatusCode -ne 200) {
        Fail "Failed to export RCG '$rcgName' (HTTP $($rcgResp.StatusCode))."
    }

    $fileName = "rcg-${rcgName}.json"
    Write-Utf8NoBom (Join-Path $snapshotDir $fileName) $rcgResp.Content
    $sha = (Get-FileHash -Path (Join-Path $snapshotDir $fileName) -Algorithm SHA256).Hash

    $rcg       = $rcgResp.Content | ConvertFrom-Json
    $rcCount   = ($rcg.properties.ruleCollections | Measure-Object).Count
    $ruleCount = 0
    if ($rcg.properties.ruleCollections) {
        foreach ($rc in $rcg.properties.ruleCollections) {
            $ruleCount += ($rc.rules | Measure-Object).Count
        }
    }

    $rcgEntries += [ordered]@{
        name            = $rcgName
        priority        = $priority
        etag            = $rcg.etag
        file            = $fileName
        sha256          = $sha
        ruleCollections = $rcCount
        totalRules      = $ruleCount
    }
}

# ── Write manifest.json ───────────────────────────────────────────────────────
$policyTier = if ($policy.properties.sku) { $policy.properties.sku.tier } else { 'Unknown' }

$manifest = [ordered]@{
    schemaVersion        = '1.0'
    snapshotId           = $timestamp
    capturedAt           = (Get-Date).ToUniversalTime().ToString('o')
    capturedBy           = $context.Account.Id
    tenantId             = $context.Tenant.Id
    subscriptionId       = $subId
    subscriptionName     = $subName
    resourceGroup        = $ResourceGroupName
    policyName           = $PolicyName
    policyId             = $policy.id
    policyEtag           = $policy.etag
    policyLocation       = $policy.location
    policyTier           = $policyTier
    policyFile           = 'policy.json'
    policySha256         = $policySha
    apiVersion           = $apiVer
    ruleCollectionGroups = $rcgEntries
}

Write-Utf8NoBom (Join-Path $snapshotDir 'manifest.json') ($manifest | ConvertTo-Json -Depth 5)

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`nSnapshot complete." -ForegroundColor Green
Write-Host "  Location : $snapshotDir"
Write-Host "  Policy   : $PolicyName ($policyTier tier)"
Write-Host "  RCGs     : $($rcgEntries.Count)"
foreach ($e in $rcgEntries) {
    Write-Host "    - $($e.name) | priority $($e.priority) | $($e.ruleCollections) collection(s) | $($e.totalRules) rule(s)"
}
Write-Host ''
Write-Host 'To roll back using this snapshot:' -ForegroundColor Yellow
Write-Host "  .\Rollback-FirewallPolicy.ps1 -ResourceGroupName $ResourceGroupName -PolicyName $PolicyName -SnapshotPath '$snapshotDir'" -ForegroundColor Yellow
