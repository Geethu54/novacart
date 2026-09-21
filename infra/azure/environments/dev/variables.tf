# --- Naming & tagging ------------------------------------------------------

variable "project" {
  description = "Short project name used as the prefix for every resource name (see locals.tf for the naming convention)."
  type        = string
  default     = "novacart"
}

variable "environment" {
  description = "Environment name (dev/staging/prod). Also used as a name-prefix segment and a tag."
  type        = string
  default     = "dev"
}

variable "location" {
  description = <<-EOT
    Azure region every resource in this environment is created in, except
    Postgres if postgres_location overrides it (see below).

    `eastus` is restricted for PostgreSQL Flexible Server on this
    subscription (see postgres_location's description) -- but Postgres is
    VNet-integrated here (delegated subnet + private DNS zone, see
    Documents/private-database-connectivity.md), and Azure requires a
    VNet-integrated Flexible Server to be in the *same region as its VNet*.
    So the fix isn't overriding postgres_location alone -- confirmed the
    hard way with `The virtual network ... coming from a different
    location eastus is currently not supported, expected location
    eastus2.` -- it's moving the whole environment. `eastus2` has no
    Postgres restriction and works for everything else here too.
  EOT
  type        = string
  default     = "eastus2"
}

variable "postgres_location" {
  description = <<-EOT
    Azure region for the PostgreSQL Flexible Server, if different from
    `location`. Some subscriptions (seen on a trial/PAYG subscription) have
    Flexible Server provisioning restricted in specific regions -- e.g.
    eastus can return `ParameterOutOfRange: The value of the 'Version'
    should be in: []` even though every other service in this environment
    works fine there. Check with:
      az postgres flexible-server list-skus --location <region>
    and look for a `"reason": "Provisioning is restricted in this
    region..."` on the top-level capability. Defaults to `location` so this
    only needs setting when that restriction actually applies.

    In this environment specifically, don't use this to work around a
    Postgres-only regional restriction -- Postgres is VNet-integrated here,
    which requires its region to match the VNet's (i.e. `location`). Fix a
    Postgres-region restriction by changing `location` itself instead (see
    its description). This variable stays available for a *non*
    VNet-integrated Postgres setup, or a future environment that splits
    Postgres into its own region deliberately.
  EOT
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags merged into the standard tag set (project/environment/managed_by) applied to every resource."
  type        = map(string)
  default     = {}
}

# --- Log Analytics ----------------------------------------------------------

variable "log_analytics_sku" {
  description = "SKU for the Log Analytics workspace."
  type        = string
  default     = "PerGB2018"
}

variable "log_analytics_retention_days" {
  description = "Number of days to retain log data."
  type        = number
  default     = 30
}

# --- PostgreSQL --------------------------------------------------------------

variable "postgres_administrator_login" {
  description = "Administrator username for the PostgreSQL Flexible Server."
  type        = string
  default     = "novacartadmin"
}

variable "postgres_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}

variable "postgres_sku_name" {
  description = "Compute/storage tier for the dev server. Burstable is the tier suited to a non-production workload."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "Provisioned storage in MB."
  type        = number
  default     = 32768
}

variable "postgres_database_name" {
  description = "Name of the application database created on the server."
  type        = string
  default     = "novacart"
}

variable "postgres_allowed_cidr_ranges" {
  description = <<-EOT
    Firewall rules to open on the dev PostgreSQL server. Ignored: this
    environment's server is VNet-integrated (see module.networking /
    docs/private-database-connectivity.md), and Flexible Server firewall
    rules only apply to servers with a public endpoint. Kept only so the
    postgresql module still works standalone (e.g. in tests) against a
    public server.
  EOT
  type = list(object({
    name     = string
    start_ip = string
    end_ip   = string
  }))
  default = []
}

# --- Application containers --------------------------------------------------

variable "backend_image_tag" {
  description = <<-EOT
    Tag of the backend image in ACR to deploy (e.g. a git SHA), pushed ahead
    of `terraform apply` with:
      az acr build --registry <acr-name> --image novacart-backend:<tag> ./backend
    No default: every apply must name a specific, known image rather than
    silently reusing whatever "latest" happens to point at.
  EOT
  type        = string
}

variable "frontend_image_tag" {
  description = <<-EOT
    Tag of the frontend image in ACR to deploy (e.g. a git SHA), pushed ahead
    of `terraform apply` with:
      az acr build --registry <acr-name> --image novacart-frontend:<tag> ./frontend
    No default: every apply must name a specific, known image rather than
    silently reusing whatever "latest" happens to point at.
  EOT
  type        = string
}

# --- Identity -----------------------------------------------------------

variable "terraform_apply_identity_object_id" {
  description = <<-EOT
    Object ID of the identity that will actually run `terraform apply` and
    make the real Key Vault Get/Set calls -- novacart-github-apply
    (AZURE_APPLY_SP_OBJECT_ID repo variable) in CI, a developer's own `az
    login` object ID locally.

    Must be passed explicitly (as a `-var`) in this repo's CI: terraform-
    apply.yml plans as AZURE_CLIENT_ID_PLAN and applies the *saved plan
    file* as AZURE_CLIENT_ID_APPLY in a separate job, and
    data.azurerm_client_config.current is resolved once, when the plan is
    computed -- so left to its own devices it always bakes in the plan
    identity, never the identity that will actually execute the apply. See
    module.key_vault's terraform_identity_object_id (this environment's
    main.tf) for where this feeds in, and "How the pipeline authenticates"
    in Documents/automated-azure-infrastructure.md for the plan/apply
    identity split itself.

    Defaults to null so a local single-identity `terraform apply` (where
    the current CLI session already is the identity that will apply) keeps
    working without setting this.
  EOT
  type        = string
  default     = null
}
