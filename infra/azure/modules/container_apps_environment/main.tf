resource "azurerm_container_app_environment" "this" {
  name                       = var.name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # VNet integration: gives every Container App in this environment a
  # private address in infrastructure_subnet_id, so they can reach
  # VNet-only resources (e.g. a private PostgreSQL Flexible Server) without
  # a public endpoint on either side. Each app's own ingress setting
  # (external_ingress in the container_app module) still controls whether
  # it additionally gets a public FQDN -- this is not an internal load
  # balancer and doesn't change that.
  infrastructure_subnet_id = var.infrastructure_subnet_id

  # Once VNet-integrated, Azure always provisions a baseline "Consumption"
  # workload profile whether or not one is declared here, and won't let it
  # be removed. Declaring it explicitly matches what the API actually
  # returns, avoiding a perpetual plan diff that tries (and fails) to
  # delete it.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = var.tags
}
