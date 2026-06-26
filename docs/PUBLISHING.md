# Marketplace publishing setup (Entra ID via GitHub OIDC)

How the automated release pipeline authenticates to the VS Code Marketplace
without a Personal Access Token (PAT). This documents the exact, working
one-time setup so it can be replicated.

Background: the VS Code Marketplace runs on Azure DevOps, so "publish a VSIX"
requires the full Azure Entra ID + Azure DevOps identity stack. PAT-based
publishing is being retired (Azure DevOps PAT retirement: December 1, 2026),
which is why this uses Microsoft Entra ID with GitHub OIDC (workload identity
federation) instead. After setup, releasing is just `git tag vX.Y.Z && git push`.

There is a helper script that automates everything with a CLI:
`scripts/setup-marketplace-oidc.ps1`. The only step it cannot do is adding the
service principal as a Marketplace publisher member (no public API) -- it prints
the exact values to paste.

## End state (what the pipeline does)

On a `v*` tag push, `.github/workflows/release.yml`:

1. Runs in the GitHub Environment named `release`.
2. Requests a GitHub OIDC token (`permissions: id-token: write`).
3. `azure/login@v3` exchanges that token at Entra ID for an access token, using
   the repo variables `AZURE_CLIENT_ID` and `AZURE_TENANT_ID`
   (`allow-no-subscriptions: true` -- no Azure subscription/RBAC needed).
4. `vsce publish --azure-credential` uses that credential to publish to the
   Marketplace. No PAT is involved.

## One-time setup

### 1. Entra ID -- App registration

- Azure portal -> Entra ID -> App registrations -> New registration.
- Name: anything (e.g. `gearlynx-vscode-publisher`).
- Supported account types: single tenant.
- Redirect URI: leave blank.
- Do NOT create a client secret or certificate (OIDC is secretless).
- From the Overview page, record:
  - Application (client) ID  -> GitHub repo variable `AZURE_CLIENT_ID`
  - Directory (tenant) ID    -> GitHub repo variable `AZURE_TENANT_ID`

### 2. Entra ID -- Federated credential

App registration -> Certificates & secrets -> Federated credentials -> Add.
Either use the "GitHub Actions deploying Azure resources" scenario, or "Other
issuer" to type the values directly. The stored values must be exactly:

- Issuer:   `https://token.actions.githubusercontent.com`
- Subject:  `repo:ganksoft/gearlynx-vscode:environment:release`
- Audience: `api://AzureADTokenExchange`

The Subject is the single most error-prone value -- see Gotchas below.

### 3. Azure DevOps org -- provision the service principal

The Marketplace member picker only resolves identities the backing Azure DevOps
organization already knows. A brand-new service principal is not known yet, so
add it first:

- Sign in to `https://dev.azure.com` with the account that owns the publisher;
  note the org name (`https://dev.azure.com/<org>`).
- `https://dev.azure.com/<org>/_settings/users` -> Add users.
- Enter the app registration's display name or Application (client) ID, select
  the resolved entry, set Access level = Basic, add to any project, save.
- If the picker will not resolve it, add it via the REST API
  (`POST https://vsaex.dev.azure.com/<org>/_apis/userentitlements`,
  `subjectKind: servicePrincipal`, `originId` = the service principal Object ID
  from Entra -> Enterprise applications). The helper script does exactly this.

### 4. Marketplace -- add the service principal to the publisher

- `https://marketplace.visualstudio.com/manage` -> publisher `ganksoft` ->
  Members -> add the service principal -> role Contributor.
- If you hit `TF14045: The identity could not be found`, the service principal
  is not provisioned in the Azure DevOps org yet -- redo step 3.

### 5. GitHub repo config

- Settings -> Environments -> create environment named exactly `release`
  (must match the federated credential Subject). Approval gates optional.
- Settings -> Secrets and variables -> Actions -> Variables:
  - `AZURE_CLIENT_ID` = Application (client) ID from step 1
  - `AZURE_TENANT_ID` = Directory (tenant) ID from step 1
- No `VSCE_PAT` or other publishing secret is needed.

### 6. Workflow

`.github/workflows/release.yml` already contains the working configuration:

- `permissions: { contents: write, id-token: write }`
- job `environment: release`
- `azure/login@v3` with `client-id`/`tenant-id` from `vars.*` and
  `allow-no-subscriptions: true`
- `npx @vscode/vsce publish --azure-credential --packagePath <vsix>`

Use action versions that run on Node 24 (`azure/login@v3`,
`softprops/action-gh-release@v3`) to avoid the Node 20 deprecation warning.

## Gotchas (these cost the most time)

- Subject case sensitivity: Entra matches the OIDC subject case-sensitively.
  The subject GitHub presents uses the real owner/repo login case and the real
  environment name. Error `AADSTS7002138 ... matches with case-insensitive
  comparison, but not with case-sensitive comparison` means a case mismatch.
  We renamed the GitHub org to lowercase `ganksoft` so the presented subject is
  `repo:ganksoft/gearlynx-vscode:environment:release`; the federated credential
  must match byte-for-byte.
- The "GitHub Actions" federated-credential scenario form may lowercase the
  Organization field on save. If the case is wrong, recreate with the "Other
  issuer" scenario and type the subject manually.
- Stable subject via Environment: tags vary per release, but a GitHub Environment
  gives a constant subject (`...:environment:release`), so one federated
  credential covers every release. Hence the job uses `environment: release`.
- `TF14045` when adding the publisher member = service principal not yet in the
  Azure DevOps org (step 3).
- `allow-no-subscriptions: true` is required; the publisher identity needs no
  Azure subscription or RBAC role.

## Replicating for a different repo/publisher

Run the helper script (see its `-?` help), or substitute throughout: the
org/repo in the Subject, the publisher name in step 4, and the
`AZURE_CLIENT_ID`/`AZURE_TENANT_ID` values. Keep the Environment name and the
federated Subject in sync, and keep everything lowercase to avoid the
case-sensitivity trap.
