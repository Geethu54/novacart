output "vnet_id" {
  description = "Resource ID of the VNet."
  value       = azurerm_virtual_network.this.id
}

output "container_apps_subnet_id" {
  description = "Resource ID of the subnet the Container Apps Environment VNet-integrates into."
  value       = azurerm_subnet.container_apps.id
}

output "postgres_subnet_id" {
  description = "Resource ID of the subnet delegated to PostgreSQL Flexible Server."
  value       = azurerm_subnet.postgres.id
}

output "postgres_private_dns_zone_id" {
  description = "Resource ID of the private DNS zone PostgreSQL Flexible Server registers its FQDN in."
  value       = azurerm_private_dns_zone.postgres.id
}

output "postgres_private_dns_zone_name" {
  description = "Name of the private DNS zone (privatelink.postgres.database.azure.com)."
  value       = azurerm_private_dns_zone.postgres.name
}
