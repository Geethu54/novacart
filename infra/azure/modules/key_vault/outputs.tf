output "id" {
  description = "Resource ID of the vault, for granting access policies or creating secrets in it."
  value       = azurerm_key_vault.this.id
}

output "name" {
  description = "Name of the vault."
  value       = azurerm_key_vault.this.name
}

output "uri" {
  description = "Vault URI, e.g. for constructing secret URIs by hand."
  value       = azurerm_key_vault.this.vault_uri
}
