<#
.SYNOPSIS
    Deploys Nextcloud 33 (AIO on ARM) to Azure using template-aio-arm.json.

.DESCRIPTION
    Interactive wrapper that:
      - Verifies az CLI is installed and logged in
      - Generates an SSH key pair if you don't already have one
      - Detects your current public IP and locks SSH + AIO admin to it
      - Creates the resource group
      - Deploys the ARM template
      - Prints the URLs and SSH command you need to finish setup

.EXAMPLE
    .\Deploy-Nextcloud.ps1

.EXAMPLE
    .\Deploy-Nextcloud.ps1 -ResourceGroup my-rg -Location westus2 -DnsLabel my-nc -Email me@example.com

.NOTES
    Requires Azure CLI: https://aka.ms/installazurecliwindows
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = "nextcloud-rg",
    [string]$Location      = "eastus",
    [string]$DnsLabel,
    [string]$CustomDomain,           # optional, e.g. cloud.example.com
    [string]$Email,
    [string]$AdminUsername = "azureuser",
    [string]$VmSize        = "Standard_B2pls_v2",
    [string]$SshKeyPath    = "$env:USERPROFILE\.ssh\id_ed25519",
    [string]$TemplateFile  = (Join-Path $PSScriptRoot 'template-aio-arm.json')
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    $msg" -ForegroundColor Red }

# -----------------------------------------------------------------------------
# 1. Prereqs
# -----------------------------------------------------------------------------
Write-Step "Checking prerequisites"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err "Azure CLI not found. Install from https://aka.ms/installazurecliwindows then re-run."
    exit 1
}
Write-Ok "Azure CLI found."

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Step "Logging in to Azure"
    az login | Out-Null
    $account = az account show | ConvertFrom-Json
}
Write-Ok "Subscription: $($account.name) ($($account.id))"

if (-not (Test-Path $TemplateFile)) {
    Write-Err "Template file not found: $TemplateFile"
    exit 1
}
Write-Ok "Template:     $TemplateFile"

# -----------------------------------------------------------------------------
# 2. SSH key pair
# -----------------------------------------------------------------------------
Write-Step "Checking SSH key pair"

$sshDir = Split-Path $SshKeyPath -Parent
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }

if (-not (Test-Path "$SshKeyPath.pub")) {
    Write-Warn2 "No SSH key found at $SshKeyPath"
    Write-Step "Generating a new ed25519 key pair (no passphrase by default)"
    ssh-keygen -t ed25519 -f $SshKeyPath -N '""' -C "nextcloud-azure" | Out-Null
    Write-Ok "Created $SshKeyPath and $SshKeyPath.pub"
} else {
    Write-Ok "Reusing existing key: $SshKeyPath.pub"
}

$sshPublicKey = (Get-Content "$SshKeyPath.pub" -Raw).Trim()

# -----------------------------------------------------------------------------
# 3. Collect missing parameters interactively
# -----------------------------------------------------------------------------
Write-Step "Gathering deployment parameters"

if (-not $DnsLabel) {
    $DnsLabel = Read-Host "DNS label (becomes <label>.$Location.cloudapp.azure.com, lowercase, 3-63 chars)"
}
$DnsLabel = $DnsLabel.ToLower().Trim()

$autoFqdn = "$DnsLabel.$Location.cloudapp.azure.com"
if (-not $CustomDomain) {
    $useCustom = Read-Host "Use a custom domain like cloud.example.com? (y/N)"
    if ($useCustom -match '^[yY]') {
        $CustomDomain = Read-Host "  Custom FQDN"
    }
}
$nextcloudFqdn = if ($CustomDomain) { $CustomDomain.Trim() } else { $autoFqdn }

if (-not $Email) {
    $Email = Read-Host "Email for Let's Encrypt certificate"
}

# -----------------------------------------------------------------------------
# 4. Detect home IP and confirm
# -----------------------------------------------------------------------------
Write-Step "Detecting your public IP"
try {
    $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).Trim()
    Write-Ok "Detected: $myIp"
} catch {
    Write-Warn2 "Could not auto-detect IP; defaulting to open SSH (NOT RECOMMENDED)."
    $myIp = $null
}

$cidr = if ($myIp) { "$myIp/32" } else { "*" }
$confirm = Read-Host "Restrict SSH + AIO admin (port 8080) to source CIDR '$cidr'? [Y/n]"
if ($confirm -match '^[nN]') {
    $cidr = Read-Host "  Enter source CIDR (e.g. 203.0.113.4/32, or * for any)"
}

# -----------------------------------------------------------------------------
# 5. Show summary, confirm
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host " Deployment plan" -ForegroundColor White
Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Subscription      : $($account.name)"
Write-Host "  Resource group    : $ResourceGroup ($Location)"
Write-Host "  VM size           : $VmSize"
Write-Host "  Admin user        : $AdminUsername (SSH key only)"
Write-Host "  Public DNS label  : $DnsLabel"
Write-Host "  Auto FQDN         : $autoFqdn"
Write-Host "  Nextcloud FQDN    : $nextcloudFqdn"
Write-Host "  Let's Encrypt to  : $Email"
Write-Host "  SSH source CIDR   : $cidr"
Write-Host "  SSH private key   : $SshKeyPath"
Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
$go = Read-Host "Proceed with deployment? [Y/n]"
if ($go -match '^[nN]') { Write-Host "Aborted."; exit 0 }

# -----------------------------------------------------------------------------
# 6. Deploy
# -----------------------------------------------------------------------------
Write-Step "Creating resource group $ResourceGroup in $Location"
az group create -n $ResourceGroup -l $Location -o none

Write-Step "Submitting deployment (this takes ~5 minutes for ARM resources)"
$deploymentName = "nextcloud-aio-$(Get-Date -Format 'yyyyMMddHHmmss')"

$result = az deployment group create `
    --resource-group $ResourceGroup `
    --name $deploymentName `
    --template-file $TemplateFile `
    --parameters `
        adminUsername=$AdminUsername `
        sshPublicKey="$sshPublicKey" `
        sslEmail=$Email `
        dnsNameForPublicIP=$DnsLabel `
        nextcloudFqdn=$nextcloudFqdn `
        allowedSshSourceCidr=$cidr `
        vmSize=$VmSize `
    -o json | ConvertFrom-Json

if (-not $result) {
    Write-Err "Deployment failed. Check Azure Portal -> Resource group -> Deployments for details."
    exit 1
}

$out = $result.properties.outputs
$publicFqdn       = $out.publicFqdn.value
$publicIp         = $out.publicIp.value
$aioAdminUrl      = $out.aioAdminUrl.value
$storageAccount   = $out.storageAccountName.value
$blobContainer    = $out.blobContainerName.value
$sshCommand       = $out.sshCommand.value

# -----------------------------------------------------------------------------
# 7. Fetch storage account key for the user (needed for External Storage step)
# -----------------------------------------------------------------------------
Write-Step "Fetching storage account key for External Storage configuration"
$storageKey = az storage account keys list -g $ResourceGroup -n $storageAccount --query "[0].value" -o tsv

# -----------------------------------------------------------------------------
# 8. Done — print everything the user needs
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Deployment complete!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Public IP        : $publicIp"
Write-Host "  Public FQDN      : $publicFqdn"
Write-Host ""
Write-Host "  AIO admin URL    : $aioAdminUrl" -ForegroundColor Yellow
Write-Host "    (open in ~5-10 min once CustomScript finishes - accept the self-signed cert)"
Write-Host ""
Write-Host "  Nextcloud URL    : https://$nextcloudFqdn"
Write-Host "    (live after you complete the AIO first-run wizard)"
Write-Host ""
Write-Host "  SSH login        : $sshCommand"
Write-Host "    (uses $SshKeyPath automatically)"
Write-Host ""
Write-Host "  Storage account  : $storageAccount"
Write-Host "  Blob container   : $blobContainer"
Write-Host "  Storage key      : $storageKey"
Write-Host "    (paste this into Nextcloud's External Storage settings - see guide)"
Write-Host ""
Write-Host "  Watch bootstrap progress over SSH with:"
Write-Host "    ssh -i $SshKeyPath $AdminUsername@$publicFqdn 'sudo tail -f /var/log/azure/custom-script/handler.log'"
Write-Host ""
Write-Host "  Next steps: see Nextcloud_AIO_Setup.md sections 3-5"
Write-Host "================================================================" -ForegroundColor Green
