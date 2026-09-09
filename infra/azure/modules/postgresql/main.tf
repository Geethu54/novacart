resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  version    = var.postgres_version
  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  # Ticket scope: public development baseline only. Private networking
  # (delegated subnet / private endpoint) is an explicit non-goal here and
  # is left for a future, production-hardening ticket.
  public_network_access_enabled = var.public_network_access_enabled

  zone = var.zone

  tags = var.tags

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

# Public development access: opens the firewall per the ranges the caller
# supplies. The dev default (see environments/dev/variables.tf) allows all
# Azure services plus every public IP, matching the "public dev baseline,
# no private networking" scope for this environment.
resource "azurerm_postgresql_flexible_server_firewall_rule" "this" {
  for_each = { for rule in var.allowed_cidr_ranges : rule.name => rule }

  name             = each.value.name
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = each.value.start_ip
  end_ip_address   = each.value.end_ip
}
