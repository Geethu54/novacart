# Classic access-policy model (enable_rbac_authorization = false), not
# Azure RBAC: RBAC-based Key Vault data access needs
# Microsoft.Authorization/roleAssignments/write, which the CI apply
# identity deliberately does not hold at subscription scope (see
# Documents/secret-and-identity-hardening.md -- granting that broadly was
# considered and explicitly rejected). Access policies are a property of
# the vault resource itself, covered by ordinary Contributor, so this
# module needs no new IAM grant to work.
resource "azurerm_key_vault" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = false

  # This environment is destroyed and rebuilt routinely (see the
  # destroy/rebuild runbook in Documents/automated-azure-infrastructure.md).
  # Purge protection would leave a soft-deleted vault occupying this name
  # for its retention period, blocking the next apply from reusing it. The
  # random-suffixed name at the call site already sidesteps that even
  # without this, but leaving purge protection off keeps a manual
  # `az keyvault purge` out of the rebuild runbook entirely. Fine for a dev
  # environment; reconsider for anything holding data worth protecting from
  # a compromised Contributor.
  purge_protection_enabled = false

  tags = var.tags
}

resource "azurerm_key_vault_access_policy" "terraform" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = var.tenant_id
  object_id    = var.terraform_identity_object_id

  secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
}

resource "azurerm_key_vault_access_policy" "readers" {
  for_each = toset(var.reader_identity_object_ids)

  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = var.tenant_id
  object_id    = each.value

  # Get only -- a reader resolves one secret's current value at runtime,
  # never needs to list what else is in the vault or change anything.
  secret_permissions = ["Get"]
}
