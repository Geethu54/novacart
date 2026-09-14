# Private connectivity for the app-to-database path (see
# docs/private-database-connectivity.md). One VNet with two purpose-built
# subnets:
#
#   snet-*-container-apps -- the Container Apps Environment VNet-integrates
#     into this subnet, giving every Container App (frontend + backend) a
#     private address in this VNet, in addition to whatever public ingress
#     each app still exposes individually.
#
#   snet-*-postgres -- delegated to PostgreSQL Flexible Server. The server
#     is created *inside* this subnet instead of behind a public endpoint,
#     so it only has a private IP, reachable only from this VNet.
#
# Both subnets live in the same VNet, so traffic between them is routed
# privately by Azure -- no peering, gateway, or NAT required.

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = var.address_space
  tags                = var.tags
}

resource "azurerm_subnet" "container_apps" {
  name                 = "snet-${var.name_prefix}-container-apps"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.container_apps_subnet_address_prefix]

  delegation {
    name = "container-apps-environment"

    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  name                 = "snet-${var.name_prefix}-postgres"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.postgres_subnet_address_prefix]

  # Postgres Flexible Server provisioning adds this itself; declaring it
  # here matches what the API actually returns and avoids a perpetual plan
  # diff trying to remove it.
  service_endpoints = ["Microsoft.Storage"]

  delegation {
    name = "postgres-flexible-server"

    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Name-resolution side of private access: PostgreSQL Flexible Server's
# VNet-integration mode requires a private DNS zone matching the
# *.postgres.database.azure.com suffix. The server's FQDN gets an A record
# here (its private IP) instead of in public DNS, so only clients that can
# resolve *and* route into this VNet can find it.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Without this link, nothing in the VNet -- including the Container Apps
# Environment -- can resolve the private zone above.
resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "vnl-${var.name_prefix}-postgres"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.this.id
  tags                  = var.tags
}
