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
  description = "Azure region every resource in this environment is created in, except Postgres if postgres_location overrides it (see below)."
  type        = string
  default     = "eastus"
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
  EOT
  type    = string
  default = null
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

variable "postgres_administrator_password" {
  description = "Administrator password for the PostgreSQL Flexible Server. Do not commit a real value: pass via TF_VAR_postgres_administrator_password or an untracked *.auto.tfvars file."
  type        = string
  sensitive   = true
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
    Firewall rules opened on the dev PostgreSQL server. This environment is
    the public development baseline (no private networking): the default
    below allows every public IP, matching the ticket's scope of "public
    dev configuration now, private networking later." Narrow this list (or
    override it per-operator in a local *.auto.tfvars) if that's too broad
    for your use.
  EOT
  type = list(object({
    name     = string
    start_ip = string
    end_ip   = string
  }))
  default = [
    {
      name     = "AllowAllPublicDev"
      start_ip = "0.0.0.0"
      end_ip   = "255.255.255.255"
    }
  ]
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
  type = string
}

variable "frontend_image_tag" {
  description = <<-EOT
    Tag of the frontend image in ACR to deploy (e.g. a git SHA), pushed ahead
    of `terraform apply` with:
      az acr build --registry <acr-name> --image novacart-frontend:<tag> ./frontend
    No default: every apply must name a specific, known image rather than
    silently reusing whatever "latest" happens to point at.
  EOT
  type = string
}
