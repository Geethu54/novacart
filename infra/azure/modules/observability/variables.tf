variable "name_prefix" {
  description = "Matches the environment's own name_prefix (e.g. \"novacart-dev\"), reused here so alert rule names follow the same convention as every other resource."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace everything in this module reads from or writes to."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "container_registry_id" {
  description = "Resource ID of the ACR to attach a diagnostic setting to (push/pull/login events aren't captured anywhere by default)."
  type        = string
}

variable "postgres_server_id" {
  description = "Resource ID of the PostgreSQL Flexible Server to attach a diagnostic setting to (server logs aren't captured anywhere by default)."
  type        = string
}

variable "backend_app_id" {
  type = string
}

variable "backend_app_name" {
  description = "Container App name as it appears in ContainerAppConsoleLogs' ContainerAppName_s column -- used to scope the log-based alert queries to just the backend."
  type        = string
}

variable "frontend_app_id" {
  type = string
}

variable "frontend_app_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
