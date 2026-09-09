output "id" {
  description = "Resource ID of the workspace (used to wire up diagnostic settings and the Container Apps Environment)."
  value       = azurerm_log_analytics_workspace.this.id
}

output "name" {
  description = "Name of the workspace."
  value       = azurerm_log_analytics_workspace.this.name
}

output "workspace_id" {
  description = "Log Analytics customer/workspace ID (GUID), distinct from the resource ID."
  value       = azurerm_log_analytics_workspace.this.workspace_id
}

output "primary_shared_key" {
  description = "Primary shared key for the workspace."
  value       = azurerm_log_analytics_workspace.this.primary_shared_key
  sensitive   = true
}
