# Entry point for the "dev" environment. Run `terraform init`/`plan`/`apply`
# from this directory. This wires together the reusable modules in
# ../../modules/* to stand up the shared Azure foundation described in
# Documents/azure-architecture.md:
#
#   resource group -> log analytics -> networking (VNet + subnets + DNS)
#                                    -> container apps environment
#                                    -> postgresql flexible server + database
#
# Rule of thumb (per the architecture doc): modules define shape, this
# environment supplies values. Sizes, SKUs, and tags belong in
# variables.tf/terraform.tfvars, not inside the modules.
#
# Postgres and the Container Apps Environment share module.networking's
# VNet, so the app-to-database path never touches the public internet --
# see docs/private-database-connectivity.md.

resource "random_string" "postgres_suffix" {
  length  = 6
  special = false
  upper   = false
}

# ACR names are globally unique across Azure and letters/numbers only (no
# hyphens), so this gets the same random-suffix treatment as Postgres.
resource "random_string" "acr_suffix" {
  length  = 6
  special = false
  upper   = false
}

# Key Vault names are globally unique too -- same treatment again. A fresh
# suffix on every from-scratch rebuild also means a soft-deleted vault left
# behind by `terraform destroy` (see module.key_vault's purge_protection
# comment) never collides with the next apply's vault name.
resource "random_string" "keyvault_suffix" {
  length  = 6
  special = false
  upper   = false
}

# Resolves to whichever identity is actually running Terraform (the apply
# SP in CI, a developer's `az login` session locally) -- used to grant that
# identity secret-management access on the Key Vault this module creates,
# without hardcoding an object ID.
data "azurerm_client_config" "current" {}

# Generated instead of accepted as an input: removes an entire
# human-managed plaintext secret (the old postgres_administrator_password
# variable / TF_VAR_POSTGRES_ADMINISTRATOR_PASSWORD GitHub secret) from the
# picture. See "Secret rotation" in Documents/secret-and-identity-hardening.md
# for how this gets rotated later without touching Terraform state or code.
resource "random_password" "postgres_admin" {
  length      = 24
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
  # Flexible Server rejects some special characters in the admin password
  # (quotes, '@', '/', backslash among them) -- restrict to a set known to
  # be accepted rather than discovering a rejection at apply time.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

module "resource_group" {
  source = "../../modules/resource_group"

  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.tags
}

module "log_analytics" {
  source = "../../modules/log_analytics"

  name                = "log-${local.name_prefix}"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  sku                 = var.log_analytics_sku
  retention_in_days   = var.log_analytics_retention_days
  tags                = local.tags
}

# Private app-to-database path (see docs/private-database-connectivity.md):
# one VNet, a subnet the Container Apps Environment integrates into, a
# subnet delegated to PostgreSQL Flexible Server, and the private DNS zone
# that resolves the server's FQDN to its private IP inside the VNet.
module "networking" {
  source = "../../modules/networking"

  name_prefix         = local.name_prefix
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  tags                = local.tags
}

module "container_apps_environment" {
  source = "../../modules/container_apps_environment"

  name                       = "cae-${local.name_prefix}"
  location                   = module.resource_group.location
  resource_group_name        = module.resource_group.name
  log_analytics_workspace_id = module.log_analytics.id

  # Gives the frontend and backend Container Apps a private address in the
  # VNet, so the backend can reach Postgres's private endpoint. Each app's
  # own external_ingress setting still controls public reachability.
  infrastructure_subnet_id = module.networking.container_apps_subnet_id

  tags = local.tags
}

module "postgresql" {
  source = "../../modules/postgresql"

  name                = "psql-${local.name_prefix}-${random_string.postgres_suffix.result}"
  location            = local.postgres_location
  resource_group_name = module.resource_group.name

  administrator_login    = var.postgres_administrator_login
  administrator_password = random_password.postgres_admin.result

  postgres_version = var.postgres_version
  sku_name         = var.postgres_sku_name
  storage_mb       = var.postgres_storage_mb

  database_name       = var.postgres_database_name
  allowed_cidr_ranges = var.postgres_allowed_cidr_ranges

  # VNet-integrated: no public endpoint. Reachable only from
  # module.networking's postgres subnet (and anything else routed into that
  # VNet), resolved via the private DNS zone linked to it.
  public_network_access_enabled = false
  delegated_subnet_id           = module.networking.postgres_subnet_id
  private_dns_zone_id           = module.networking.postgres_private_dns_zone_id

  tags = local.tags

  # The private DNS zone must already be linked to the VNet before the
  # server is created, or server creation fails looking up the zone link.
  # That link is a sibling resource inside module.networking, invisible to
  # Terraform's automatic graph from the ID references above alone, so it's
  # spelled out explicitly.
  depends_on = [module.networking]
}

module "container_registry" {
  source = "../../modules/container_registry"

  name                = "acr${var.project}${var.environment}${random_string.acr_suffix.result}"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  tags                = local.tags
}

locals {
  # Postgres requires TLS for public connections; psycopg (used by the
  # backend, see backend/app/main.py) reads a standard libpq connection URL.
  backend_database_url = "postgresql://${var.postgres_administrator_login}:${random_password.postgres_admin.result}@${module.postgresql.server_fqdn}:5432/${module.postgresql.database_name}?sslmode=require"
}

# One identity, Get-only, used solely to resolve the backend's DATABASE_URL
# Key Vault reference at runtime -- kept separate from acr_pull's identity
# so a compromise of one grants nothing on the other (least privilege).
resource "azurerm_user_assigned_identity" "keyvault_reader" {
  name                = "id-${local.name_prefix}-kv-reader"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  tags                = local.tags
}

module "key_vault" {
  source = "../../modules/key_vault"

  name                = "kv${var.project}${var.environment}${random_string.keyvault_suffix.result}"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  tenant_id           = data.azurerm_client_config.current.tenant_id

  # See terraform_apply_identity_object_id's description (variables.tf) for
  # why this can't just be data.azurerm_client_config.current.object_id.
  terraform_identity_object_id = coalesce(var.terraform_apply_identity_object_id, data.azurerm_client_config.current.object_id)

  # keyvault_reader: the Container App's runtime identity, resolving the
  # DATABASE_URL secret reference. plan_identity: see
  # terraform_plan_identity_object_id's description (variables.tf) -- a
  # read-only `terraform plan` still reads this secret's live value during
  # refresh. Omitted (not just null-valued) when unset, since for_each
  # rejects a null value even for a key that'd otherwise be unused.
  reader_identity_object_ids = merge(
    { keyvault_reader = azurerm_user_assigned_identity.keyvault_reader.principal_id },
    var.terraform_plan_identity_object_id != null ? { plan_identity = var.terraform_plan_identity_object_id } : {}
  )

  tags = local.tags
}

resource "azurerm_key_vault_secret" "postgres_connection_string" {
  name         = "postgres-connection-string"
  value        = local.backend_database_url
  key_vault_id = module.key_vault.id

  # Set once from Terraform's generated password at creation; ignored on
  # every apply after that, so an out-of-band rotation (new Postgres
  # password + a matching `az keyvault secret set`) isn't reverted by the
  # next unrelated apply. See "Secret rotation" in
  # Documents/secret-and-identity-hardening.md.
  lifecycle {
    ignore_changes = [value]
  }

  # module.key_vault: key_vault_id above only proves the *vault* exists
  # (azurerm_key_vault.this, the resource that produces module.key_vault.id)
  # -- it does not depend on the sibling azurerm_key_vault_access_policy.terraform
  # resource inside that module, which is what actually grants this apply
  # identity Get/Set on secrets. Without this, Terraform can create/check
  # this secret before that access policy exists, failing with 403. Same
  # class of invisible-sibling-resource issue as backend_app's depends_on
  # on module.key_vault, below.
  depends_on = [module.key_vault]
}

# Created (and granted AcrPull) before either Container App exists, and
# handed to both. A system-assigned identity per app can't work here: Azure
# tries to pull the image as part of *creating* the Container App, but a
# system-assigned identity's principal ID -- and therefore its role
# assignment -- can only be created after the app already exists. That
# ordering always loses the race (first revision fails to pull, "Operation
# expired"). A pre-existing, pre-authorized identity sidesteps it entirely.
resource "azurerm_user_assigned_identity" "acr_pull" {
  name                = "id-${local.name_prefix}-acr-pull"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = module.container_registry.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.acr_pull.principal_id
}

module "backend_app" {
  source = "../../modules/container_app"

  name                         = "ca-${local.name_prefix}-backend"
  location                     = module.resource_group.location
  resource_group_name          = module.resource_group.name
  container_app_environment_id = module.container_apps_environment.id
  registry_server              = module.container_registry.login_server
  acr_pull_identity_id         = azurerm_user_assigned_identity.acr_pull.id
  key_vault_identity_id        = azurerm_user_assigned_identity.keyvault_reader.id

  image       = "${module.container_registry.login_server}/novacart-backend:${var.backend_image_tag}"
  target_port = 8000

  # Internal-only: per Documents/azure-architecture.md, the backend is never
  # reached directly from the browser -- only the frontend's nginx proxy
  # reaches it, over the Container Apps Environment's internal DNS.
  external_ingress = false

  env_vars = {
    APP_ENV = var.environment
  }

  # Resolved from Key Vault at runtime rather than passed as a flat value --
  # see azurerm_key_vault_secret.postgres_connection_string's comment for
  # why, and "Secret rotation" in Documents/secret-and-identity-hardening.md.
  key_vault_secret_env_vars = {
    DATABASE_URL = azurerm_key_vault_secret.postgres_connection_string.versionless_id
  }

  tags = local.tags

  # acr_pull: the pull-identity role assignment (see its own comment above).
  # module.key_vault: the keyvault_reader identity's access policy is a
  # sibling resource inside this module, invisible to Terraform's automatic
  # graph from the key_vault_secret_env_vars reference alone (that reference
  # only proves the *secret* exists, not that keyvault_reader can read it).
  depends_on = [azurerm_role_assignment.acr_pull, module.key_vault]
}

module "frontend_app" {
  source = "../../modules/container_app"

  name                         = "ca-${local.name_prefix}-frontend"
  location                     = module.resource_group.location
  resource_group_name          = module.resource_group.name
  container_app_environment_id = module.container_apps_environment.id
  registry_server              = module.container_registry.login_server
  acr_pull_identity_id         = azurerm_user_assigned_identity.acr_pull.id

  image       = "${module.container_registry.login_server}/novacart-frontend:${var.frontend_image_tag}"
  target_port = 80

  # Public dev endpoint: this is the app a browser hits.
  external_ingress = true

  env_vars = {
    # Read by frontend/nginx.conf.template's envsubst at container start.
    # Referencing module.backend_app.fqdn (rather than pre-computing it)
    # makes Terraform create the backend app first and use its real,
    # Azure-assigned FQDN -- no guessing, no manual two-step apply.
    BACKEND_INTERNAL_URL = "https://${module.backend_app.fqdn}"
  }

  tags = local.tags

  depends_on = [azurerm_role_assignment.acr_pull]
}
