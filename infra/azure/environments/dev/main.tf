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
# Out of scope here (see ticket): the frontend/backend Container Apps
# themselves, and private networking for Postgres. Both are follow-up work
# that will build on the outputs below.

resource "random_string" "postgres_suffix" {
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
  location            = module.resource_group.location
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
