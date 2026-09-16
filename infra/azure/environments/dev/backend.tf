# Remote state, required now that this environment is applied from GitHub
# Actions (see docs/automated-azure-infrastructure.md) and not just from one
# operator's machine. A CI runner is ephemeral -- state can't live on its
# disk -- and multiple runs (or a runner + a local operator) touching the
# same environment need Terraform's built-in locking to avoid stomping on
# each other.
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
#     -backend-config="subscription_id=<subscription-id>" \
#     -backend-config="tenant_id=<tenant-id>" \
#     -backend-config="client_id=<client-id-with-Storage-Blob-Data-Contributor-on-the-tfstate-container>"
#
# `use_oidc = true` (rather than `use_azuread_auth` + a user's `az login`
# session, or an account key) is what lets CI read/write/lock state without
# a stored credential -- see "How the pipeline authenticates" in
# docs/automated-azure-infrastructure.md. A local operator can keep using
# their own `az login` session instead by omitting the four auth-related
# `-backend-config` lines; the azurerm backend falls back to Azure CLI auth
# when they're absent.
#
# The storage account + container themselves are created out-of-band (see
# the "Bootstrapping remote state" section of
# docs/automated-azure-infrastructure.md), not by this environment's own
# `terraform apply` -- Terraform can't create the backend it's about to
# read its state from.
terraform {
  backend "azurerm" {}
}
