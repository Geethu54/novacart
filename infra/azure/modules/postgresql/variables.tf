variable "name" {
  description = "Globally-unique name of the PostgreSQL Flexible Server."
  type        = string
}

variable "location" {
  description = "Azure region for the server."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the server belongs to."
  type        = string
}

variable "administrator_login" {
  description = "Administrator username for the server."
  type        = string
}

variable "administrator_password" {
  description = "Administrator password for the server."
  type        = string
  sensitive   = true
}

variable "postgres_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}

variable "sku_name" {
  description = "Compute/storage tier, e.g. a Burstable SKU for dev (B_Standard_B1ms)."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storage_mb" {
  description = "Provisioned storage in MB."
  type        = number
  default     = 32768
}

variable "zone" {
  description = "Availability zone for the server."
  type        = string
  default     = "1"
}

variable "database_name" {
  description = "Name of the application database created on the server."
  type        = string
}

variable "public_network_access_enabled" {
  description = "Whether the server is reachable over the public internet. This environment intentionally has no private networking, so this stays true here."
  type        = bool
  default     = true
}

variable "allowed_cidr_ranges" {
  description = "Firewall rules to open on the server. Each entry allows the inclusive IP range [start_ip, end_ip]."
  type = list(object({
    name     = string
    start_ip = string
    end_ip   = string
  }))
  default = []
}

variable "tags" {
  description = "Tags applied to the server."
  type        = map(string)
  default     = {}
}
