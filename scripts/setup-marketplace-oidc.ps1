<#
.SYNOPSIS
    Set up secretless VS Code Marketplace publishing via Microsoft Entra ID and
    GitHub OIDC (workload identity federation).

.DESCRIPTION
    Automates the one-time identity wiring documented in docs/PUBLISHING.md:

      1. Creates (or reuses) an Entra ID app registration + service principal.
      2. Adds a GitHub OIDC federated credential whose subject targets a GitHub
         Environment.
      3. Creates the GitHub Environment and sets the AZURE_CLIENT_ID /
         AZURE_TENANT_ID repo variables.
      4. (Optional) Provisions the service principal into the Azure DevOps org
         that backs the Marketplace publisher, so it can be added as a member.

    The ONE step with no public API -- adding the service principal as a member
    of the Marketplace publisher -- cannot be automated. The script prints the
    exact values to paste at https://marketplace.visualstudio.com/manage.

    Idempotent: re-running reuses existing objects instead of duplicating them.

.PREREQUISITES
    - Azure CLI (az), logged in to the publisher's tenant:  az login
    - GitHub CLI (gh), logged in with repo admin rights:    gh auth login
    - Permission to create app registrations in the tenant.

.PARAMETER GitHubOwner
    GitHub org/user login, exact case as GitHub stores it (e.g. ganksoft).
    Lowercase is strongly recommended to avoid the OIDC subject case trap.

.PARAMETER GitHubRepo
    Repository name (e.g. gearlynx-vscode).

.PARAMETER AppDisplayName
    Display name for the Entra app registration (e.g. gearlynx-vscode-publisher).

.PARAMETER Environment
    GitHub Environment name used in both the workflow job and the federated
    credential subject. Default: release.

.PARAMETER AzureDevOpsOrg
    Optional. The Azure DevOps org backing the Marketplace publisher
    (the <org> in https://dev.azure.com/<org>). If supplied, the script
    provisions the service principal into that org via REST.

.EXAMPLE
    ./setup-marketplace-oidc.ps1 -GitHubOwner ganksoft -GitHubRepo gearlynx-vscode `
        -AppDisplayName gearlynx-vscode-publisher -AzureDevOpsOrg ganksoft
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $GitHubOwner,
    [Parameter(Mandatory)] [string] $GitHubRepo,
    [Parameter(Mandatory)] [string] $AppDisplayName,
    [string] $Environment = 'release',
    [string] $AzureDevOpsOrg
)

$ErrorActionPreference = 'Stop'

# Azure DevOps resource GUID used to request an access token for the org APIs.
$AzureDevOpsResource = '499b84ac-1321-427f-aa17-267ca6975798'
$Issuer   = 'https://token.actions.githubusercontent.com'
$Audience = 'api://AzureADTokenExchange'
$Subject  = "repo:$GitHubOwner/$GitHubRepo:environment:$Environment"

function Require-Cli([string] $name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Required CLI '$name' not found on PATH."
    }
}

function Info([string] $msg)  { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Ok([string]   $msg)  { Write-Host "[+] $msg" -ForegroundColor Green }
function Warn([string] $msg)  { Write-Host "[!] $msg" -ForegroundColor Yellow }

Require-Cli az
Require-Cli gh

if ($GitHubOwner -cne $GitHubOwner.ToLower()) {
    Warn "GitHubOwner '$GitHubOwner' is not lowercase. GitHub presents the OIDC"
    Warn "subject using the real login case; a mismatch causes AADSTS7002138."
}

Info "Subject that GitHub will present (federated credential must match exactly):"
Write-Host "    $Subject"

# --- Tenant ----------------------------------------------------------------
$TenantId = (az account show --query tenantId -o tsv)
if (-not $TenantId) { throw 'Not logged in to Azure. Run: az login' }
Ok "Tenant: $TenantId"

# --- App registration ------------------------------------------------------
Info "Ensuring app registration '$AppDisplayName'..."
$AppId = (az ad app list --display-name $AppDisplayName --query '[0].appId' -o tsv)
if (-not $AppId) {
    $AppId = (az ad app create --display-name $AppDisplayName --query appId -o tsv)
    Ok "Created app registration. appId=$AppId"
} else {
    Ok "Reusing existing app registration. appId=$AppId"
}

# --- Service principal -----------------------------------------------------
$SpObjectId = (az ad sp show --id $AppId --query id -o tsv 2>$null)
if (-not $SpObjectId) {
    $SpObjectId = (az ad sp create --id $AppId --query id -o tsv)
    Ok "Created service principal. objectId=$SpObjectId"
} else {
    Ok "Reusing existing service principal. objectId=$SpObjectId"
}

# --- Federated credential --------------------------------------------------
Info "Ensuring federated credential for subject..."
$existing = (az ad app federated-credential list --id $AppId `
    --query "[?subject=='$Subject'].name" -o tsv)
if (-not $existing) {
    $fic = @{
        name      = "github-$Environment"
        issuer    = $Issuer
        subject   = $Subject
        audiences = @($Audience)
    } | ConvertTo-Json -Compress
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $fic -Encoding ascii
    try {
        az ad app federated-credential create --id $AppId --parameters "@$tmp" | Out-Null
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    Ok "Created federated credential 'github-$Environment'."
} else {
    Ok "Federated credential already present ('$existing')."
}

# --- GitHub: environment + variables --------------------------------------
Info "Ensuring GitHub Environment '$Environment'..."
gh api --method PUT "repos/$GitHubOwner/$GitHubRepo/environments/$Environment" `
    -H 'Accept: application/vnd.github+json' | Out-Null
Ok "Environment '$Environment' present."

Info 'Setting repo variables AZURE_CLIENT_ID and AZURE_TENANT_ID...'
gh variable set AZURE_CLIENT_ID --repo "$GitHubOwner/$GitHubRepo" --body $AppId  | Out-Null
gh variable set AZURE_TENANT_ID --repo "$GitHubOwner/$GitHubRepo" --body $TenantId | Out-Null
Ok 'Repo variables set.'

# --- Azure DevOps org provisioning (optional) ------------------------------
if ($AzureDevOpsOrg) {
    Info "Provisioning service principal into Azure DevOps org '$AzureDevOpsOrg'..."
    $token = (az account get-access-token --resource $AzureDevOpsResource --query accessToken -o tsv)
    $body = @{
        accessLevel = @{ accountLicenseType = 'express' }
        user = @{
            origin      = 'aad'
            originId    = $SpObjectId
            subjectKind = 'servicePrincipal'
        }
    } | ConvertTo-Json -Depth 5
    $uri = "https://vsaex.dev.azure.com/$AzureDevOpsOrg/_apis/userentitlements?api-version=7.1-preview.3"
    try {
        Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $token" } -Body $body | Out-Null
        Ok "Service principal provisioned into '$AzureDevOpsOrg'."
    } catch {
        Warn "Could not provision via REST (it may already exist, or you lack rights):"
        Warn "  $($_.Exception.Message)"
        Warn 'Add it manually at https://dev.azure.com/'"$AzureDevOpsOrg"'/_settings/users'
    }
} else {
    Warn 'AzureDevOpsOrg not supplied; skipping Azure DevOps provisioning.'
    Warn 'The service principal must exist in the org backing the publisher'
    Warn 'before the Marketplace member add will resolve (otherwise TF14045).'
}

# --- Manual step (no API) --------------------------------------------------
Write-Host ''
Write-Host '=== MANUAL STEP (no public API) ============================' -ForegroundColor Magenta
Write-Host 'Add the service principal as a member of your Marketplace publisher:'
Write-Host '  1. Go to https://marketplace.visualstudio.com/manage'
Write-Host '  2. Open your publisher -> Members -> Add'
Write-Host '  3. Search by this Application (client) ID, assign role Contributor:'
Write-Host "        $AppId"
Write-Host "     (or the service principal object ID: $SpObjectId)"
Write-Host '============================================================' -ForegroundColor Magenta
Write-Host ''
Ok 'Done. After the manual step, push a vX.Y.Z tag to publish.'
