output "id" {
  description = "Resource ID of the Container App."
  value       = azurerm_container_app.this.id
}

output "name" {
  description = "Name of the Container App."
  value       = azurerm_container_app.this.name
}

output "fqdn" {
  description = "FQDN Azure assigned to this app's ingress. External ingress -> reachable from the public internet; internal ingress -> reachable only from other apps in the same Container Apps Environment."
  value       = azurerm_container_app.this.ingress[0].fqdn
}
