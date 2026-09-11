output "resource_group_name" {
  description = "Name of the shared resource group. Later tickets (frontend/backend Container Apps, ACR) deploy into this."
  value       = module.resource_group.name
}

output "location" {
  description = "Azure region this environment was deployed to."
  value       = module.resource_group.location
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the shared Log Analytics workspace, for wiring up additional diagnostic settings later."
  value       = module.log_analytics.id
}

output "container_apps_environment_id" {
  description = "Resource ID of the Container Apps Environment. The frontend/backend Container Apps (next ticket) are created inside this."
  value       = module.container_apps_environment.id
}

output "container_apps_environment_default_domain" {
  description = "Default domain suffix apps in this environment get, e.g. used to predict the frontend's public FQDN."
  value       = module.container_apps_environment.default_domain
}

output "container_apps_environment_static_ip" {
  description = "Static outbound IP of the Container Apps Environment."
  value       = module.container_apps_environment.static_ip_address
}

output "postgres_server_fqdn" {
  description = "Fully-qualified domain name of the dev PostgreSQL server, e.g. for building DATABASE_URL in the backend Container App."
  value       = module.postgresql.server_fqdn
}

output "postgres_database_name" {
  description = "Name of the application database on the dev PostgreSQL server."
  value       = module.postgresql.database_name
}

output "postgres_administrator_login" {
  description = "Administrator username for the dev PostgreSQL server (the password is never emitted as an output)."
  value       = module.postgresql.administrator_login
}

output "container_registry_login_server" {
  description = "ACR login server. Build/push images here before applying, e.g. `az acr build --registry <name> --image novacart-backend:<tag> ./backend`."
  value       = module.container_registry.login_server
}

output "frontend_fqdn" {
  description = "Public FQDN of the frontend Container App -- the development environment's browser-facing endpoint."
  value       = module.frontend_app.fqdn
}

output "backend_internal_fqdn" {
  description = "Internal-only FQDN of the backend Container App. Reachable from other apps in the same Container Apps Environment (the frontend's nginx proxy) but not from the public internet."
  value       = module.backend_app.fqdn
}
