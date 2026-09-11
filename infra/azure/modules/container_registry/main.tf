resource "azurerm_container_registry" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku

  # No admin username/password credential: Container Apps pull images using
  # their own system-assigned managed identity plus an AcrPull role
  # assignment (see environments/dev/main.tf), so there's no registry
  # credential to leak or rotate.
  admin_enabled = false

  tags = var.tags
}
