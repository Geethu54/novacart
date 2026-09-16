# Remote state, required now that this environment is applied from GitHub
# Actions (see Documents/automated-azure-infrastructure.md) and not just
# from one operator's machine. A CI runner is ephemeral -- state can't live
# on its disk -- and multiple runs (or a runner + a local operator) touching
# the same environment need Terraform's built-in locking to avoid stomping
# on each other.
#
# The block is intentionally left empty here ("partial configuration"):
# naming the storage account/container inline would either hardcode an
# environment-specific value into version control or require a different
# backend.tf per environment. Instead, every `terraform init` -- local or
# in CI -- must supply the backend config via `-backend-config`, e.g.:
#
#   terraform init \
#     -backend-config="resource_group_name=rg-novacart-tfstate" \
#     -backend-config="storage_account_name=<globally-unique-storage-account>" \
#     -backend-config="container_name=tfstate" \
#     -backend-config="key=novacart-dev.tfstate" \
#     -backend-config="use_oidc=true" \
#     -backend-config="use_azuread_auth=true" \
#     -backend-config="subscription_id=<subscription-id>" \
#     -backend-config="tenant_id=<tenant-id>" \
#     -backend-config="client_id=<client-id-with-Storage-Blob-Data-Contributor-on-the-tfstate-container>"
#
# `use_oidc` and `use_azuread_auth` are two different settings and CI needs
# both, not either/or: `use_oidc = true` controls how Terraform authenticates
# *to Azure AD itself* (via the GitHub OIDC token, no stored credential);
# `use_azuread_auth = true` controls how it then talks to the storage
# account -- without it, the azurerm backend defaults to fetching a storage
# account *access key* (an `az storage account keys list`-equivalent call)
# and using that instead, which needs the management-plane
# `Microsoft.Storage/storageAccounts/listKeys/action` permission. Our CI
# identities only have data-plane `Storage Blob Data Contributor` on the
# `tfstate` container specifically (see "How the pipeline authenticates" in
# Documents/automated-azure-infrastructure.md), so a `listKeys` call 403s --
# `use_azuread_auth = true` is what makes the backend use the OIDC-derived
# AAD token directly against blob storage instead, matching the RBAC scope
# we actually granted. A local operator can skip all five auth-related
# `-backend-config` lines and keep using their own `az login` session
# instead; the azurerm backend falls back to Azure CLI auth when they're
# absent.
#
# The storage account + container themselves are created out-of-band (see
# the "Bootstrapping remote state" section of
# Documents/automated-azure-infrastructure.md), not by this environment's
# own `terraform apply` -- Terraform can't create the backend it's about to
# read its state from.
terraform {
  backend "azurerm" {}
}
