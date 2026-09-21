variable "name" {
  description = "Name of the Key Vault. Globally unique across Azure -- pair with a random suffix at the call site, the same way container_registry and postgresql are."
  type        = string
}

variable "location" {
  description = "Azure region to create the vault in."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the vault is created in."
  type        = string
}

variable "tenant_id" {
  description = "Azure AD tenant ID the vault trusts (data.azurerm_client_config.current.tenant_id at the call site)."
  type        = string
}

variable "terraform_identity_object_id" {
  description = "Object ID of the identity running Terraform (data.azurerm_client_config.current.object_id at the call site). Granted full secret management so this module's own azurerm_key_vault_secret resources can be created and updated."
  type        = string
}

variable "reader_identity_object_ids" {
  description = "Object IDs of managed identities granted read-only (Get) access to secrets -- e.g. a Container App's identity resolving a Key Vault-backed secret reference at runtime."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to the vault."
  type        = map(string)
  default     = {}
}
