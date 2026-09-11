# Entry point for the "dev" environment. Run `terraform init`/`plan`/`apply`
# from this directory. This wires together the reusable modules in
# ../../modules/* to stand up the shared Azure foundation described in
# Documents/azure-architecture.md:
#
#   resource group -> log analytics -> container apps environment
#                                    -> postgresql flexible server + database
#
# Rule of thumb (per the architecture doc): modules define shape, this
# environment supplies values. Sizes, SKUs, and tags belong in
# variables.tf/terraform.tfvars, not inside the modules.
#
# Out of scope here (see ticket): private networking for Postgres. That's
# follow-up, production-hardening work.

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

module "container_apps_environment" {
  source = "../../modules/container_apps_environment"

  name                       = "cae-${local.name_prefix}"
  location                   = module.resource_group.location
  resource_group_name        = module.resource_group.name
  log_analytics_workspace_id = module.log_analytics.id
  tags                       = local.tags
}

module "postgresql" {
  source = "../../modules/postgresql"

  name                = "psql-${local.name_prefix}-${random_string.postgres_suffix.result}"
  location            = local.postgres_location
  resource_group_name = module.resource_group.name

  administrator_login    = var.postgres_administrator_login
  administrator_password = var.postgres_administrator_password

  postgres_version = var.postgres_version
  sku_name         = var.postgres_sku_name
  storage_mb       = var.postgres_storage_mb

  database_name       = var.postgres_database_name
  allowed_cidr_ranges = var.postgres_allowed_cidr_ranges

  # Ticket scope: public dev baseline, no private networking.
  public_network_access_enabled = true

  tags = local.tags
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
  backend_database_url = "postgresql://${var.postgres_administrator_login}:${var.postgres_administrator_password}@${module.postgresql.server_fqdn}:5432/${module.postgresql.database_name}?sslmode=require"
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

  image       = "${module.container_registry.login_server}/novacart-backend:${var.backend_image_tag}"
  target_port = 8000

  # Internal-only: per Documents/azure-architecture.md, the backend is never
  # reached directly from the browser -- only the frontend's nginx proxy
  # reaches it, over the Container Apps Environment's internal DNS.
  external_ingress = false

  env_vars = {
    APP_ENV = var.environment
  }

  secret_env_vars = {
    DATABASE_URL = local.backend_database_url
  }

  tags = local.tags

  depends_on = [azurerm_role_assignment.acr_pull]
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
