# Shared shape for both the frontend and backend Container Apps -- the
# environment (environments/dev/main.tf) supplies the values that make each
# one different (image, port, ingress visibility, env vars).

locals {
  # Azure Container Apps secret names must be lowercase letters, numbers and
  # dashes. Env var names (DATABASE_URL) don't have that restriction, only
  # the secret they point at does, so derive one from the other instead of
  # asking the caller to supply both.
  secret_names = { for k in keys(var.secret_env_vars) : k => replace(lower(k), "_", "-") }
}

resource "azurerm_container_app" "this" {
  name                         = var.name
  resource_group_name          = var.resource_group_name
  container_app_environment_id = var.container_app_environment_id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.acr_pull_identity_id]
  }

  registry {
    server   = var.registry_server
    identity = var.acr_pull_identity_id
  }

  dynamic "secret" {
    for_each = var.secret_env_vars
    content {
      name  = local.secret_names[secret.key]
      value = secret.value
    }
  }

  ingress {
    external_enabled = var.external_ingress
    target_port      = var.target_port

    # Left at its default ("auto"), Azure sometimes probes the container
    # with an HTTP/2-cleartext upgrade handshake. Neither app here speaks
    # HTTP/2 (plain nginx, plain uvicorn) -- nginx in particular rejects
    # that probe outright with "426 Upgrade Required" instead of falling
    # back to HTTP/1.1. Pinning this avoids the negotiation entirely.
    transport = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = var.name
      image  = var.image
      cpu    = var.cpu
      memory = var.memory

      dynamic "env" {
        for_each = var.env_vars
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env_vars
        content {
          name        = env.key
          secret_name = local.secret_names[env.key]
        }
      }
    }
  }
}
