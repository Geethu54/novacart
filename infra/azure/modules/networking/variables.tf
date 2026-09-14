variable "name_prefix" {
  description = "Naming prefix, e.g. novacart-dev. Matches the convention used by every other module."
  type        = string
}

variable "location" {
  description = "Azure region for the VNet and subnets."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the VNet, subnets, and private DNS zone belong to."
  type        = string
}

variable "address_space" {
  description = "Address space of the VNet."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "container_apps_subnet_address_prefix" {
  description = <<-EOT
    Address prefix for the subnet the Container Apps Environment integrates
    into. Azure's minimum for environment VNet integration is /27; /23 is
    used here to match Microsoft's recommended headroom so the environment
    can scale without running out of IPs.
  EOT
  type        = string
  default     = "10.0.0.0/23"
}

variable "postgres_subnet_address_prefix" {
  description = <<-EOT
    Address prefix for the subnet delegated to PostgreSQL Flexible Server.
    /28 is Azure's minimum size for a delegated Flexible Server subnet and
    is enough for a single server.
  EOT
  type        = string
  default     = "10.0.2.0/28"
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
