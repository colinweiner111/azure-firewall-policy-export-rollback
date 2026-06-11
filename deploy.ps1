#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys the minimal lab environment (VNet + Azure Firewall Premium + Policy).

.PARAMETER ResourceGroupName
    Name of the resource group to deploy into. Created if it doesn't exist.

.PARAMETER SubscriptionId
    Azure subscription ID. Defaults to the current az CLI subscription.

.PARAMETER Location
    Azure region for deployed resources. If the resource group does not exist and this is omitted,
    the script prompts for a region before creating the resource group.

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName rg-fw-lab

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName rg-fw-lab -SubscriptionId 00000000-0000-0000-0000-000000000000

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName rg-fw-lab -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location eastus
#>
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [string]$SubscriptionId,
    [string]$Location
)

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

$azSubArgs = @()
if ($SubscriptionId) {
    $azSubArgs = @('--subscription', $SubscriptionId)
    Write-Host "Using explicit subscription '$SubscriptionId' for all az commands..." -ForegroundColor Cyan
}

$sub = az account show @azSubArgs --query "{name:name, id:id}" -o json | ConvertFrom-Json
if (-not $sub) {
    Fail 'Unable to resolve Azure subscription context. Run az login and retry.'
}
Write-Host "Deploying into subscription: $($sub.name) ($($sub.id))" -ForegroundColor Cyan

$rgExists = (az group exists @azSubArgs --name $ResourceGroupName -o tsv)
if ($rgExists -eq 'true') {
    $rg = az group show @azSubArgs --name $ResourceGroupName --query "{name:name, location:location}" -o json | ConvertFrom-Json
    if (-not $rg) {
        Fail "Failed to query existing resource group '$ResourceGroupName'."
    }

    if (-not $Location) {
        $Location = $rg.location
        Write-Host "Resource group '$ResourceGroupName' already exists in '$Location'. Using that location for deployment." -ForegroundColor Cyan
    } else {
        Write-Host "Resource group '$ResourceGroupName' already exists. Deploying resources with location parameter '$Location'." -ForegroundColor Cyan
    }
} else {
    if (-not $Location) {
        $Location = Read-Host "Resource group '$ResourceGroupName' does not exist. Enter Azure region (for example: centralus)"
        if ([string]::IsNullOrWhiteSpace($Location)) {
            Fail 'Location is required when creating a new resource group.'
        }
    }

    Write-Host "Creating resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Cyan
    az group create @azSubArgs --name $ResourceGroupName --location $Location --output none
}

Write-Host "Deploying Bicep template (Azure Firewall takes ~5-10 min)..." -ForegroundColor Cyan
az deployment group create `
    @azSubArgs `
    --resource-group $ResourceGroupName `
    --template-file "$PSScriptRoot/main.bicep" `
    --parameters location=$Location `
    --name fw-lab-deploy

Write-Host "`nDeployment outputs:" -ForegroundColor Cyan
az deployment group show `
    @azSubArgs `
    --resource-group $ResourceGroupName `
    --name fw-lab-deploy `
    --query properties.outputs `
    --output table

Write-Host "`nLab ready. Run the backup script to take a snapshot:" -ForegroundColor Green
Write-Host "  .\Backup-FirewallPolicy.ps1 -ResourceGroupName $ResourceGroupName -PolicyName fw-policy-hub01" -ForegroundColor Yellow
