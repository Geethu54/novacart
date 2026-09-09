output "id" {
  description = "Resource ID of the Container Apps Environment. Container Apps created in a later ticket (frontend/backend) will reference this."
  value       = azurerm_container_app_environment.this.id
}

output "name" {
  description = "Name of the Container Apps Environment."
  value       = azurerm_container_app_environment.this.name
}

output "default_domain" {
  description = "Default domain suffix for apps deployed into this environment (e.g. used to build the frontend's public FQDN)."
  value       = azurerm_container_app_environment.this.default_domain
}

output "static_ip_address" {
  description = "Static (outbound) IP address of the environment."
  value       = azurerm_container_app_environment.this.static_ip_address
}
