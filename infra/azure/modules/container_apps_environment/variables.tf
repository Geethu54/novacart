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

variable "tags" {
  description = "Tags applied to the environment."
  type        = map(string)
  default     = {}
}
