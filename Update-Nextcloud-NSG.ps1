<#
.SYNOPSIS
    Updates the Nextcloud NSG to allow SSH + AIO admin from your current public IP.

.DESCRIPTION
    Detects your current home/office public IP and updates two NSG rules:
      - AllowSSH       (port 22)
      - AllowAIOAdmin  (port 8080)
    so you can connect from your new location.

    Use this whenever your ISP changes your IP, or when you move (coffee shop,
    hotel, etc.). Only your IP changes - everything else in the NSG stays put.

.EXAMPLE
    .\Update-Nextcloud-NSG.ps1
    # Auto-detects IP, updates the default NSG (nextcloud-nsg in nextcloud-rg)

.EXAMPLE
    .\Update-Nextcloud-NSG.ps1 -SourceCidr 203.0.113.4/32
    # Force a specific CIDR (useful for a VPN range or office subnet)

.EXAMPLE
    .\Update-Nextcloud-NSG.ps1 -ResourceGroup my-rg -NsgName my-nsg

.EXAMPLE
    .\Update-Nextcloud-NSG.ps1 -AddIp
    # ADD your current IP alongside any IPs already on the rule
    # (instead of replacing - handy if you want both home + office allowed)
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = "nextcloud-rg",
    [string]$NsgName       = "nextcloud-nsg",
    [string]$SourceCidr,
    [switch]$AddIp,
    [string[]]$RuleNames   = @("AllowSSH", "AllowAIOAdmin")
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    $msg" -ForegroundColor Red }

# -----------------------------------------------------------------------------
# Prereqs
# -----------------------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err "Azure CLI not found. Install from https://aka.ms/installazurecliwindows"
    exit 1
}

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Step "Logging in to Azure"
    az login | Out-Null
    $account = az account show | ConvertFrom-Json
}
Write-Ok "Subscription: $($account.name)"

# -----------------------------------------------------------------------------
# Resolve source CIDR
# -----------------------------------------------------------------------------
if (-not $SourceCidr) {
    Write-Step "Detecting your public IP"
    try {
        $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).Trim()
        $SourceCidr = "$myIp/32"
        Write-Ok "Detected: $SourceCidr"
    } catch {
        Write-Err "Could not detect public IP. Pass -SourceCidr explicitly."
        exit 2
    }
}

# Basic CIDR validation
if ($SourceCidr -ne '*' -and $SourceCidr -notmatch '^\d{1,3}(\.\d{1,3}){3}(\/\d{1,2})?$') {
    Write-Err "Invalid CIDR: $SourceCidr (expected e.g. 203.0.113.4/32 or '*')"
    exit 3
}

# -----------------------------------------------------------------------------
# Verify NSG exists
# -----------------------------------------------------------------------------
Write-Step "Verifying NSG $NsgName in $ResourceGroup"
$nsg = az network nsg show -g $ResourceGroup -n $NsgName 2>$null | ConvertFrom-Json
if (-not $nsg) {
    Write-Err "NSG '$NsgName' not found in resource group '$ResourceGroup'."
    Write-Warn2 "List your NSGs with: az network nsg list -o table"
    exit 4
}
Write-Ok "Found NSG (location: $($nsg.location))"

# -----------------------------------------------------------------------------
# Update each rule
# -----------------------------------------------------------------------------
foreach ($ruleName in $RuleNames) {
    Write-Step "Updating rule '$ruleName'"

    $rule = az network nsg rule show -g $ResourceGroup --nsg-name $NsgName -n $ruleName 2>$null | ConvertFrom-Json
    if (-not $rule) {
        Write-Warn2 "Rule '$ruleName' not found - skipping."
        continue
    }

    # Build new list of allowed source prefixes
    $existing = @()
    if ($rule.sourceAddressPrefix -and $rule.sourceAddressPrefix -ne '') {
        $existing += $rule.sourceAddressPrefix
    }
    if ($rule.sourceAddressPrefixes) {
        $existing += $rule.sourceAddressPrefixes
    }
    $existing = $existing | Where-Object { $_ -and $_ -ne '' } | Sort-Object -Unique

    if ($AddIp) {
        $newSet = ($existing + $SourceCidr) | Sort-Object -Unique
        $action = "ADD"
    } else {
        $newSet = @($SourceCidr)
        $action = "REPLACE"
    }

    Write-Host "      old: $($existing -join ', ')"
    Write-Host "      new: $($newSet  -join ', ')  ($action)"

    az network nsg rule update `
        -g $ResourceGroup `
        --nsg-name $NsgName `
        -n $ruleName `
        --source-address-prefixes $newSet `
        -o none

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Updated."
    } else {
        Write-Err "az returned non-zero for rule $ruleName"
    }
}

# -----------------------------------------------------------------------------
# Quick connectivity check
# -----------------------------------------------------------------------------
Write-Step "Looking up the public IP of the Nextcloud VM for a quick test"
$pip = az network public-ip list -g $ResourceGroup --query "[?contains(name,'nextcloud')].ipAddress" -o tsv 2>$null
if ($pip) {
    Write-Ok "Nextcloud VM IP: $pip"
    Write-Host ""
    Write-Host "Try it now:" -ForegroundColor Yellow
    Write-Host "  Test-NetConnection $pip -Port 22"
    Write-Host "  ssh azureuser@$pip"
} else {
    Write-Warn2 "Could not find a public IP named *nextcloud* in $ResourceGroup. Skipping test hint."
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
