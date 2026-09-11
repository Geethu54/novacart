output "id" {
  description = "Resource ID of the registry, for granting AcrPull role assignments."
  value       = azurerm_container_registry.this.id
}

output "name" {
  description = "Name of the registry."
  value       = azurerm_container_registry.this.name
}

output "login_server" {
  description = "Hostname used to build image references, e.g. \"<login_server>/novacart-backend:<tag>\"."
  value       = azurerm_container_registry.this.login_server
}
