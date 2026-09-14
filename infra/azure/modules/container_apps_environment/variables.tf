variable "name" {
  description = "Name of the Container Apps Environment."
  type        = string
}

variable "location" {
  description = "Azure region for the environment."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the environment belongs to."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace that container app logs are shipped to."
  type        = string
}

variable "infrastructure_subnet_id" {
  description = <<-EOT
    Resource ID of a subnet the environment VNet-integrates into, giving
    every Container App in it a private address in that subnet. Leave null
    to keep the environment un-integrated (no route to VNet-only
    resources).
  EOT
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the environment."
  type        = map(string)
  default     = {}
}
