variable "name" {
  description = "Name of the Container App."
  type        = string
}

variable "location" {
  description = "Azure region to create the app in. Must match the Container Apps Environment's region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the app is created in."
  type        = string
}

variable "container_app_environment_id" {
  description = "Resource ID of the Container Apps Environment this app runs in."
  type        = string
}

variable "image" {
  description = "Full container image reference, e.g. \"<acr-login-server>/novacart-backend:<tag>\"."
  type        = string
}

variable "target_port" {
  description = "Port the container listens on."
  type        = number
}

variable "external_ingress" {
  description = "true = internet-facing (e.g. the frontend); false = reachable only from other apps in the same Container Apps Environment (e.g. the backend)."
  type        = bool
  default     = false
}

variable "cpu" {
  description = "CPU cores allocated to the container. Must be a value Azure Container Apps accepts for the paired memory value (e.g. 0.25 CPU pairs with 0.5Gi)."
  type        = number
  default     = 0.25
}

variable "memory" {
  description = "Memory allocated to the container, e.g. \"0.5Gi\"."
  type        = string
  default     = "0.5Gi"
}

variable "min_replicas" {
  type    = number
  default = 1
}

variable "max_replicas" {
  type    = number
  default = 1
}

variable "env_vars" {
  description = "Plain (non-secret) environment variables, name => value."
  type        = map(string)
  default     = {}
}

variable "secret_env_vars" {
  description = "Secret-backed environment variables, name => value (e.g. DATABASE_URL). Stored as Container App secrets and referenced by name from the container's env block, so values never show up as plain env values in the app's spec. Prefer key_vault_secret_env_vars when a Key Vault is available -- unlike this map, a Key Vault reference lets the value be rotated without a Terraform apply."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "key_vault_secret_env_vars" {
  description = <<-EOT
    Env vars backed by a Key Vault secret reference, name => the secret's
    versionless Key Vault URI (e.g. azurerm_key_vault_secret.foo.versionless_id).
    Azure resolves these at runtime via key_vault_identity_id, always
    fetching the current value -- so rotating the underlying Key Vault
    secret takes effect on the app's next revision restart, with no
    Terraform apply or source change involved. Requires key_vault_identity_id.
  EOT
  type        = map(string)
  default     = {}
}

variable "key_vault_identity_id" {
  description = "Resource ID of a user-assigned identity already granted Get access on the Key Vault secrets referenced by key_vault_secret_env_vars. Required (non-null) if key_vault_secret_env_vars is non-empty."
  type        = string
  default     = null
}

variable "registry_server" {
  description = "ACR login server this app pulls its image from, e.g. \"acrnovacartdev123.azurecr.io\"."
  type        = string
}

variable "acr_pull_identity_id" {
  description = <<-EOT
    Resource ID of a user-assigned managed identity already granted AcrPull
    on the registry (see environments/dev/main.tf). Deliberately not a
    system-assigned identity: Azure Container Apps attempts to pull the
    image as part of *creating* the app, so a system-assigned identity's
    role assignment (which can only be created after the app exists, since
    it needs the app's principal ID) always loses that race -- the first
    revision fails to pull and the create errors out with "Operation
    expired". A pre-existing, pre-authorized identity avoids the ordering
    problem entirely.
  EOT
  type        = string
}

variable "tags" {
  description = "Tags applied to the app."
  type        = map(string)
  default     = {}
}
