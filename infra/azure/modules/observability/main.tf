# Observability foundation: routes logs from resources that don't already
# write to the shared Log Analytics workspace by default, and defines the
# alert rules that turn those logs/metrics into something that pages a
# human. See Documents/observability-foundation.md for the reasoning behind
# every threshold and category chosen here -- this file is deliberately
# comment-light because that doc is the source of truth for "why."
#
# Both Container Apps already stream stdout/stderr (ContainerAppConsoleLogs)
# and platform events (ContainerAppSystemLogs) to the workspace automatically
# -- that's what passing log_analytics_workspace_id to the Container Apps
# Environment does (see environments/dev/main.tf). Nothing here duplicates
# that; this module only adds diagnostic settings for the two resources that
# don't get that treatment for free (ACR, Postgres), plus every alert rule.

resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "diag-acr-to-log-analytics"
  target_resource_id         = var.container_registry_id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ContainerRegistryRepositoryEvents" # push/pull/delete
  }

  enabled_log {
    category = "ContainerRegistryLoginEvents" # auth successes/failures -- security-relevant
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "postgres" {
  name                       = "diag-postgres-to-log-analytics"
  target_resource_id         = var.postgres_server_id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "PostgreSQLLogs" # server-side errors, slow queries, connection events
  }

  enabled_metric {
    category = "AllMetrics"
  }

  # Deliberately not enabling PostgreSQLFlexSessions / QueryStore* /
  # PGBouncer / TableStats categories here -- they're query-performance
  # tuning data, not the kind of signal this foundation is about (an
  # incident responder needs "is the database reachable and erroring,"
  # not per-query statistics). Add them later if/when query performance
  # tuning becomes a real workstream.
}

locals {
  apps = {
    backend  = { id = var.backend_app_id, name = var.backend_app_name }
    frontend = { id = var.frontend_app_id, name = var.frontend_app_name }
  }
}

# -- Metric alerts: platform-level health, identical shape for both apps --
#
# Thresholds below are a starting point, not a measured baseline -- there's
# no production traffic history for this workload yet. Revisit after real
# usage data exists; see "what would create alert noise" in
# Documents/observability-foundation.md.

resource "azurerm_monitor_metric_alert" "cpu_high" {
  for_each            = local.apps
  name                = "alert-${var.name_prefix}-${each.key}-cpu-high"
  resource_group_name = var.resource_group_name
  scopes              = [each.value.id]
  description         = "${each.key} container CPU sustained above 85% -- may be under-provisioned or serving abnormal load."
  severity            = 2 # Warning
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "CpuPercentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 85
  }

  tags = var.tags
}

resource "azurerm_monitor_metric_alert" "memory_high" {
  for_each            = local.apps
  name                = "alert-${var.name_prefix}-${each.key}-memory-high"
  resource_group_name = var.resource_group_name
  scopes              = [each.value.id]
  description         = "${each.key} container memory sustained above 85% -- risks an OOM kill."
  severity            = 2 # Warning
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "MemoryPercentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 85
  }

  tags = var.tags
}

resource "azurerm_monitor_metric_alert" "restarted" {
  for_each            = local.apps
  name                = "alert-${var.name_prefix}-${each.key}-restarted"
  resource_group_name = var.resource_group_name
  scopes              = [each.value.id]
  description         = "${each.key} container restarted. With min_replicas=max_replicas=1 (no redundancy today), every restart is a brief real outage, not just a data point."
  severity            = 2 # Warning
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "RestartCount"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  tags = var.tags
}

resource "azurerm_monitor_metric_alert" "no_replicas" {
  for_each            = local.apps
  name                = "alert-${var.name_prefix}-${each.key}-no-replicas"
  resource_group_name = var.resource_group_name
  scopes              = [each.value.id]
  description         = "${each.key} has zero running replicas -- full outage for this app, since there is no redundancy to fail over to."
  severity            = 0 # Critical
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "Replicas"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1
  }

  tags = var.tags
}

# -- Log-based alerts: backend application behavior --
#
# Scoped to the backend only. The frontend is a static-file server plus a
# reverse proxy -- it has no application-level failure modes beyond what
# the metric alerts above already cover (CPU/memory/restarts/replica
# count). The backend's structured request logs (see the log_requests
# middleware and the explicit event=... log lines in backend/app/main.py)
# are the only place in this system that carries request-level meaning.

# Table is ContainerAppConsoleLogs_CL, not ContainerAppConsoleLogs -- despite
# what Log Analytics' schema browser shows for the latter (a valid-looking
# but always-empty built-in schema definition), Container Apps actually
# lands data in the custom-log variant, with the classic _CL/_s column
# suffixes. Confirmed against real ingested rows, not just the schema:
#   az monitor log-analytics query -w <workspace-customer-id> --timespan P7D \
#     --analytics-query 'search * | summarize count() by Type'
# If this ever needs re-verifying (e.g. Azure changes the ingestion path),
# that command is the fastest way to see which table name is actually live.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "backend_elevated_5xx" {
  name                 = "alert-${var.name_prefix}-backend-elevated-5xx"
  resource_group_name  = var.resource_group_name
  location             = var.location
  scopes               = [var.log_analytics_workspace_id]
  severity             = 1 # Error
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  description          = "More than 5 backend responses with a 5xx status code in a 5-minute window -- real user-facing failures, not the normal 400s from bad promo codes or unknown products."

  criteria {
    query = <<-KQL
      ContainerAppConsoleLogs_CL
      | where ContainerAppName_s == "${var.backend_app_name}"
      | where Log_s matches regex @"status_code=5\d\d"
    KQL
    time_aggregation_method = "Count"
    threshold               = 5
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods              = 1
    }
  }

  tags = var.tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "backend_unhealthy" {
  name                 = "alert-${var.name_prefix}-backend-unhealthy"
  resource_group_name  = var.resource_group_name
  location             = var.location
  scopes               = [var.log_analytics_workspace_id]
  severity             = 0 # Critical
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  description          = "Backend logged a readiness or startup failure -- the database is unreachable, or the app couldn't boot at all. Page immediately; this is not a degraded-performance signal, it's down-or-about-to-be-down."

  criteria {
    query = <<-KQL
      ContainerAppConsoleLogs_CL
      | where ContainerAppName_s == "${var.backend_app_name}"
      | where Log_s contains "event=readiness_failed" or Log_s contains "event=startup_failed"
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods              = 1
    }
  }

  tags = var.tags
}

# No action group is wired to any alert above -- they fire and are visible
# in Azure Monitor > Alerts, but notify no one yet. Attach one later with:
#
#   resource "azurerm_monitor_action_group" "this" {
#     name                = "ag-${var.name_prefix}"
#     resource_group_name = var.resource_group_name
#     short_name          = "novacart"
#     email_receiver {
#       name          = "primary"
#       email_address = "<team-email>"
#     }
#   }
#
# ...then add `action { action_group_id = azurerm_monitor_action_group.this.id }`
# to each alert resource above.
