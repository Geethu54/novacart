# Tearing down the CI bootstrap (state storage + federated identities)

Cleanup commands for everything set up in
[automated-azure-infrastructure.md](automated-azure-infrastructure.md)'s
bootstrap: the two Azure AD app registrations (`novacart-github-plan`,
`novacart-github-apply`) and the Terraform state storage account
(`rg-novacart-tfstate`). Not for the application infrastructure itself
(`rg-novacart-dev`) -- that's just `terraform destroy` from
`infra/azure/environments/dev`, same as always.

**Order matters**: delete the GitHub-side references first, or the pipeline
will fail loudly (rather than silently) the next time it runs after the
Azure objects are gone -- which is the point, but do it in a controlled
order rather than by accident.

Values below are from this session -- replace the storage account name if
you picked something other than `sanovacarttfstate01`.

```
Subscription ID:  2f36d352-db13-4852-af92-8a815ae2d929
Tenant ID:        76477482-52c9-4475-876b-8578b52eddd6
plan app id:      b26ee31b-3422-4d4e-aabd-991fc62f8391  (novacart-github-plan)
apply app id:     4cd0e698-9ad0-4ee7-a29d-56d9b1cbfde9  (novacart-github-apply)
state RG:         rg-novacart-tfstate
state storage:    sanovacarttfstate01
state container:  tfstate
```

## 1. GitHub side

```bash
# Secrets
gh secret delete AZURE_TENANT_ID
gh secret delete AZURE_SUBSCRIPTION_ID
gh secret delete AZURE_CLIENT_ID_PLAN
gh secret delete TF_VAR_POSTGRES_ADMINISTRATOR_PASSWORD
gh secret delete AZURE_CLIENT_ID_APPLY --env dev-infra

# Variables
gh variable delete TF_STATE_RESOURCE_GROUP
gh variable delete TF_STATE_STORAGE_ACCOUNT
gh variable delete TF_STATE_CONTAINER
gh variable delete BACKEND_IMAGE_TAG
gh variable delete FRONTEND_IMAGE_TAG

# Environment itself (also removes its secret/protection rules if the
# delete above is skipped)
gh api -X DELETE repos/:owner/:repo/environments/dev-infra
```

**Console equivalent**: repo → Settings → Secrets and variables → Actions →
delete each secret/variable from the Secrets and Variables tabs; Settings →
Environments → `dev-infra` → **Delete environment** (bottom of the page).

## 2. Azure AD app registrations

Deleting an app registration also deletes its service principal and every
federated credential on it -- one command per app, nothing else to clean up
on that app individually:

```bash
az ad app delete --id b26ee31b-3422-4d4e-aabd-991fc62f8391   # novacart-github-plan
az ad app delete --id 4cd0e698-9ad0-4ee7-a29d-56d9b1cbfde9   # novacart-github-apply
```

Their role assignments (Reader / Contributor on the subscription, Storage
Blob Data Contributor on the `tfstate` container) stop working the instant
the service principal is gone, but the assignment *entries* can linger as
orphaned ("Identity not found") rows under a scope's Access control (IAM) →
Role assignments list. To remove them explicitly instead of leaving stale
entries behind:

```bash
SUB_SCOPE="/subscriptions/2f36d352-db13-4852-af92-8a815ae2d929"
STATE_SCOPE="$SUB_SCOPE/resourceGroups/rg-novacart-tfstate/providers/Microsoft.Storage/storageAccounts/sanovacarttfstate01/blobServices/default/containers/tfstate"

az role assignment delete --assignee b26ee31b-3422-4d4e-aabd-991fc62f8391 --scope "$SUB_SCOPE"
az role assignment delete --assignee 4cd0e698-9ad0-4ee7-a29d-56d9b1cbfde9 --scope "$SUB_SCOPE"
az role assignment delete --assignee b26ee31b-3422-4d4e-aabd-991fc62f8391 --scope "$STATE_SCOPE"
az role assignment delete --assignee 4cd0e698-9ad0-4ee7-a29d-56d9b1cbfde9 --scope "$STATE_SCOPE"
```

(Run these *before* `az ad app delete` if you want the role-assignment
delete calls to succeed cleanly by object ID; after the app is deleted
they'll usually still clear via `az role assignment delete --all` cleanup,
but doing it in this order avoids relying on that.)

**Console equivalent**:
- Azure AD → App registrations → `novacart-github-plan` (or `-apply`) →
  **Delete** (top of the Overview page) -- this removes the app, its
  service principal, and its federated credentials together.
- To clear a lingering role assignment by hand: go to the scope (Subscription
  → Access control (IAM), or the `tfstate` container → Access control (IAM))
  → **Role assignments** tab → find the row for the deleted app (shown as
  "Identity not found" if the app is already gone) → checkbox it → **Remove**.

## 3. State storage account

```bash
az group delete --name rg-novacart-tfstate --yes --no-wait
```

Deletes the storage account and the `tfstate` container (and the state
file inside it) along with the resource group. **This is destructive and
not reversible past the storage account's soft-delete retention window
(30 days, if you set it up as documented)** -- make sure nothing still
needs `infra/azure/environments/dev`'s state before running this; without
it, that environment can no longer be planned/applied/destroyed through
Terraform at all (you'd be left reconciling `rg-novacart-dev` by hand).

**Console equivalent**: Resource groups → `rg-novacart-tfstate` → **Delete
resource group** (top of the page) → type the resource group name to
confirm → **Delete**.

## Verifying it's actually gone

```bash
az ad app list --query "[?starts_with(displayName, 'novacart')].displayName" -o table
az group show --name rg-novacart-tfstate 2>&1   # expect ResourceGroupNotFound
gh secret list; gh variable list
gh api repos/:owner/:repo/environments 2>&1      # dev-infra should be absent
```
