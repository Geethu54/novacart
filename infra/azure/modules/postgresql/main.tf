resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  version    = var.postgres_version
  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  # VNet-integrated (private) access: server gets a private IP in
  # delegated_subnet_id instead of a public endpoint, and registers its
  # FQDN in private_dns_zone_id instead of public DNS. Azure requires
  # public_network_access_enabled to be explicitly false in this case --
  # *omitting* it (or sending null/true) makes the API reject the request
  # with ConflictingPublicNetworkAccessAndVirtualNetworkConfiguration, even
  # though that reads like the opposite would be true. See
  # https://github.com/hashicorp/terraform-provider-azurerm/issues/26098.
  delegated_subnet_id           = var.delegated_subnet_id
  private_dns_zone_id           = var.private_dns_zone_id
  public_network_access_enabled = var.delegated_subnet_id == null ? var.public_network_access_enabled : false

  zone = var.zone

  tags = var.tags

  lifecycle {
    # administrator_password: lets a password rotated directly against the
    # live server (`az postgres flexible-server update --admin-password`,
    # paired with updating the matching Key Vault secret -- see "Secret
    # rotation" in Documents/secret-and-identity-hardening.md) stick,
    # instead of the next unrelated apply silently resetting it back to
    # whatever value is still in Terraform state.
    ignore_changes = [zone, administrator_password]
  }
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

# Public access only: firewall rules are meaningless (and rejected by the
# API) once the server is VNet-integrated. Callers going private are
# expected to pass allowed_cidr_ranges = [] (the dev environment's default)
# rather than relying on a guard here -- for_each's key set must be known
# at plan time, and delegated_subnet_id (a subnet ID created alongside this
# server) generally isn't, so it can't be part of this condition.
resource "azurerm_postgresql_flexible_server_firewall_rule" "this" {
  for_each = { for rule in var.allowed_cidr_ranges : rule.name => rule }

  name             = each.value.name
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = each.value.start_ip
  end_ip_address   = each.value.end_ip
}
