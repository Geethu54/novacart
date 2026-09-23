# Observability foundation

The question this answers: **when something goes wrong, can we see it, and does someone find out without a customer telling us first?** Not "can we deploy" (that's covered — see `Documents/automated-azure-deployment.md` and `pipeline .md`) — this is about what happens *after* a deploy, once real traffic hits the platform.

Everything here is implemented in `infra/azure/modules/observability/` (new), plus small additions to `infra/azure/modules/container_app/` (health probes) and `frontend/nginx.conf.template` (a `/healthz` endpoint). Nothing in this doc is aspirational — it describes what's actually wired up after `terraform apply`.

## Where logs go

One destination for everything: the existing Log Analytics workspace (`module.log_analytics`, already created for the Container Apps Environment — see `infra/azure/environments/dev/main.tf`). No new logging backend, no separate tool to learn.

| Source | How it gets there | Table |
|---|---|---|
| Backend container stdout/stderr | Automatic — the Container Apps Environment was created with `log_analytics_workspace_id` set, so every app in it streams console output there with zero extra config | `ContainerAppConsoleLogs` |
| Frontend container stdout/stderr (nginx access/error log) | Same mechanism | `ContainerAppConsoleLogs` |
| Container Apps platform events (revision changes, scale events, provisioning) | Same mechanism | `ContainerAppSystemLogs` |
| ACR push/pull/delete events, login attempts | New: `azurerm_monitor_diagnostic_setting` in the `observability` module — ACR does **not** send logs anywhere by default, this had to be added explicitly | `ContainerRegistryRepositoryEvents`, `ContainerRegistryLoginEvents` |
| Postgres server logs (connection events, errors, slow statements) | New: same module, another diagnostic setting — Postgres also sends nothing anywhere by default | `PostgreSQLLogs` |
| All platform metrics (CPU, memory, requests, replica count, etc.) for ACR and Postgres | Same diagnostic settings, `AllMetrics` category | `AzureMetrics` |

**Why this had to be built, not just documented:** before this change, ACR and Postgres emitted zero logs anywhere queryable — Azure keeps some platform metrics for ~93 days regardless, but nothing in Log Analytics, nothing alertable, nothing joinable against the application's own logs. Only the two Container Apps had logging "for free," and only because the Container Apps Environment happened to be created pointing at the workspace already.

**Retention:** whatever `module.log_analytics`'s `retention_in_days` is set to (see `infra/azure/environments/dev/variables.tf` / `terraform.tfvars`) — one workspace, one retention policy, applies to everything above.

## What telemetry the application/platform emits

**Application (backend, `backend/app/main.py`):**

- A request-logging middleware (`log_requests`) wraps every HTTP request and logs one structured line per request on completion:
  `event=request_completed method=<verb> path=<path> status_code=<code> duration_ms=<float>`
  — and one on an unhandled exception:
  `event=request_failed method=<verb> path=<path> duration_ms=<float>` (plus the full traceback, via `logger.exception`).
- Explicit business-event log lines: `event=order_created` (with order ref, item count, promo code, totals), `event=order_rejected` (with a `reason=` — empty cart, unknown promo, unknown product), `event=startup_begin` / `event=startup_complete` / `event=startup_failed`, `event=readiness_failed`.
- All of it is `key=value` formatted specifically so it's greppable/parseable from Log Analytics via `Log_s contains "event=..."` or a `parse` KQL operator, without needing a structured-JSON logging library. This was a deliberate existing choice in the codebase (not something added for this deliverable) — it's what makes the log-based alerts below possible without new instrumentation.

**Application (frontend):** nginx's own access and error logs, unmodified — no application-level events, since the frontend has no business logic (static files + a reverse proxy).

**Platform (Azure Container Apps):** CPU/memory usage, request count, restart count, replica count, network bytes in/out — emitted automatically per container app, queryable as Azure Monitor metrics with no code involved. See the table in "what metrics matter" below.

**What's deliberately *not* emitted (yet):** no distributed tracing (no correlation ID propagated from frontend → backend → DB), no application-level custom metrics (e.g. "orders per minute" exists only as something you'd derive from log lines via KQL, not as a first-class metric), no APM tool (Application Insights, Datadog, etc.). See "future upgrade path" at the bottom for when that becomes worth the cost.

## What metrics matter for this workload

This is a two-container, single-replica-each, low-traffic dev workload sitting in front of one Postgres server. The metrics worth watching reflect that shape — not a generic "watch everything" list.

| Metric | Why it matters here | Source |
|---|---|---|
| `Replicas` (per app) | With `min_replicas = max_replicas = 1` (no autoscaling, no redundancy configured today), this dropping to 0 means the app is **fully down**, not degraded | Container Apps platform metric |
| `RestartCount` (per app) | Same reasoning — one replica means a restart is a real, brief outage window, not absorbed by a sibling instance | Container Apps platform metric |
| `CpuPercentage` / `MemoryPercentage` (per app) | Early warning before a restart/OOM happens; also the first thing to check when latency complaints come in | Container Apps platform metric |
| Backend 5xx rate | The only direct signal of "requests are failing," as opposed to infrastructure metrics that only imply it | Derived from `ContainerAppConsoleLogs` (`event=request_completed status_code=5xx`) |
| Backend readiness failures | Directly answers "is the database reachable from the app" — the one external dependency this system has | `event=readiness_failed` log lines |
| Postgres connection/error events | The database has no application-level health signal of its own; its own logs are the only way to see e.g. connection exhaustion or auth failures that wouldn't necessarily show up as a backend readiness failure first | `PostgreSQLLogs` |
| ACR login failures | Security-relevant: an unexpected login failure on the registry is either a broken pipeline or a credential-scoped identity being misused | `ContainerRegistryLoginEvents` |

**Deliberately not tracked as a "metric that matters" here:** request latency percentiles (p50/p95/p99). The app logs `duration_ms` per request, so it's *derivable* via KQL (`ContainerAppConsoleLogs | parse ...`), but there's no dedicated metric or alert on it yet — at current traffic volumes there isn't enough data for percentiles to mean anything, and a percentile alert tuned on near-zero traffic is pure noise. Worth adding once there's real request volume to baseline against.

## How health is checked

Every container now has both a liveness and a readiness probe (previously: neither — Azure was falling back to a bare TCP-connect check on the listening port, which confirms a process is listening, not that it can serve a real request).

| App | Liveness probe | Readiness probe | Why they differ |
|---|---|---|---|
| Backend | `GET /health` — returns 200 immediately, touches nothing external | `GET /ready` — runs `SELECT 1` against Postgres, returns 503 if it fails | Liveness answers "should Azure restart this container" (must be cheap and dependency-free, or a slow database would cause Azure to kill and restart a perfectly healthy process); readiness answers "should Azure route traffic here" (must check the real dependency, or a dead DB connection would keep receiving — and failing — requests) |
| Frontend | `GET /healthz` — static 200, no disk read | `GET /healthz` — same | nginx has no external dependency of its own; the same cheap check serves both purposes |

Probe tuning (`infra/azure/modules/container_app/main.tf`): liveness checked every 30s (3 failures → restart), readiness every 10s (3 failures → pulled from routing, 1 success → restored). Readiness polls faster and recovers on a single success because routing decisions should react quickly in both directions; liveness is slower and requires 3 consecutive failures because restarting a container is a much more disruptive action than briefly pulling it from rotation.

## What signals would help during an incident

In rough order of "check this first":

1. **`Replicas` and `RestartCount` for both apps** — is anything actually down right now, or still running but unhealthy underneath. Answers the very first triage question.
2. **The `alert-*-backend-unhealthy` firing state** (readiness/startup failures) — if this is what triggered the page, the database is the suspect, not the application code. Jump straight to Postgres logs/metrics instead of reading backend code.
3. **Backend 5xx rate over the last 30–60 min** (`ContainerAppConsoleLogs | where ContainerAppName_s == "ca-novacart-dev-backend" and Log_s matches regex @"status_code=5\d\d"`) — is this a spike tied to a specific deploy (correlate against the `git-<sha>` tag from `image-deploy-cli.yml`'s run history) or a slow climb (resource exhaustion, DB connection pool).
4. **`CpuPercentage`/`MemoryPercentage` trend, not just current value** — a slow climb over hours points at a leak or an unbounded cache; a sudden jump points at a traffic spike or a specific bad request pattern.
5. **`PostgreSQLLogs`** — connection count, auth failures, slow queries. Only the database's own logs show this; nothing on the app side surfaces it directly except readiness failures after the fact.
6. **`event=order_rejected` volume and `reason=`** — distinguishes "users are hitting a real bug" from "this is normal traffic with typos in promo codes." Useful for ruling *out* an incident as much as confirming one.
7. **The image tag currently running** (`az containerapp revision list --name ca-novacart-dev-backend -g rg-novacart-dev --query "[].{active:properties.active,image:properties.template.containers[0].image}"`) — first question for "did a deploy cause this."

## What alert conditions are meaningful

Implemented in `infra/azure/modules/observability/main.tf`, six rules total:

| Alert | Condition | Severity | Why it's meaningful |
|---|---|---|---|
| `*-no-replicas` (backend, frontend) | `Replicas` average < 1 over 5 min | Critical | Zero redundancy today — this *is* an outage, not a warning of one |
| `backend-unhealthy` | Any `event=readiness_failed` or `event=startup_failed` log line in 5 min | Critical | The database is unreachable or the app can't boot — page immediately, don't wait for a trend |
| `backend-elevated-5xx` | More than 5 backend 5xx responses in 5 min | Error | Real user-facing failures, aggregated so a single blip doesn't page anyone |
| `*-restarted` (backend, frontend) | `RestartCount` total > 0 over 5 min | Warning | With one replica, every restart is a brief real gap in availability, worth knowing even if it self-heals |
| `*-cpu-high` (backend, frontend) | `CpuPercentage` average > 85% over 15 min | Warning | Sustained (not instantaneous) — early warning before it becomes a restart/latency problem |
| `*-memory-high` (backend, frontend) | `MemoryPercentage` average > 85% over 15 min | Warning | Same reasoning; also the leading indicator before an OOM kill |

**No action group is attached yet** — these alerts fire and are visible under Azure Monitor → Alerts, but notify no one until a receiver (email, webhook, etc.) is wired up. That was a deliberate scope decision for this pass (see the comment at the bottom of `observability/main.tf` for the exact Terraform to add one) — the team should decide who gets paged before that's turned on, rather than it defaulting to some placeholder address nobody watches.

## What would create alert noise

Explicitly *not* implemented, and why each would hurt more than help:

- **Alerting on individual 4xx responses.** `event=order_rejected` (empty cart, unknown promo code, unknown product) is expected user behavior, not a platform problem — these happen constantly in normal use (someone fat-fingers a promo code) and would drown out real signal within a day.
- **Alerting on CPU/memory with a short window or low threshold.** A 1-minute spike to 60% CPU during a cold start or a traffic burst is normal for a `min_replicas=1` app with no headroom; alerting on it teaches everyone to ignore alerts. That's why the thresholds above use 15-minute *sustained average* windows, not instantaneous peaks.
- **Alerting on `RestartCount` without an action-worthy threshold.** Container Apps can restart a revision as part of a normal deploy or scale event, not only a crash — a single restart alert is informational, not urgent (severity 2, not 0), specifically so it doesn't compete for attention with the Critical-severity alerts above.
- **A latency percentile alert right now.** As noted above, there isn't enough traffic volume yet for p95/p99 to be statistically meaningful — an alert on it today would fire on noise, not signal.
- **Enabling every Postgres diagnostic category** (query store, PGBouncer, per-table stats — all available, see the module's `azurerm_monitor_diagnostic_setting.postgres`). These are query-tuning data, not incident-response data; piping them in now would inflate the Log Analytics bill and bury the two categories (`PostgreSQLLogs`, `AllMetrics`) that actually matter for "is the database up."
- **A single combined "something is wrong" alert instead of the six specific ones above.** A catch-all alert tells you to go look, but not where — the whole point of scoping each alert to one specific condition (no replicas vs. high error rate vs. resource pressure) is that the alert *name itself* is the first diagnostic step.

## Future upgrade path (not implemented, noted for when it becomes worth it)

- **Application Insights / distributed tracing** — once there's a real reason to trace a request across frontend → backend → Postgres (multiple services, or debugging cross-service latency), not before. Right now there are only two hops and the backend's own request log already captures the one that matters.
- **An action group + on-call routing** — the natural next step once the team knows who should be paged for what.
- **A production environment's own alert set** — everything here targets `dev` only, matching every other pipeline in this repo (see `automated-azure-deployment.md`'s "What this deliberately does not do"). A `prod` environment would likely want tighter thresholds, an action group from day one, and probably PagerDuty/Opsgenie integration instead of bare email.
