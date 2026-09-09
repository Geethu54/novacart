Request flow: Browser → frontend (nginx, HTTPS, public) → backend (FastAPI, internal HTTP only, /api/*) → PostgreSQL (TLS required). Database is never reachable from frontend/browser directly.

Resources to create on Azure: resource group, Log Analytics workspace, Container Apps Environment, two Container Apps (frontend + backend), Azure Container Registry (ACR), PostgreSQL Flexible Server, and a place to Terraform remote state allows locking .

Frontend container app: external ingress, port 80, serves static files and proxies /api/* to backend. Backend container app: internal-only ingress, port 8000, with liveness (/health) and readiness (/ready) probes.

Image handling: one ACR (acrnovacartdev) holds both images; CI pushes with git-SHA + dev tags; authentication is identity-based (managed identity + AcrPull role) — no stored credentials.

Key config dependency: nginx currently hardcodes backend as a hostname (Docker-only trick), but Azure has no such alias. Fix: template nginx.conf with envsubst, and inject the backend's internal FQDN via a BACKEND_INTERNAL_URL env var — this value must come from a Terraform output.

Logging: both apps auto-ship stdout/stderr to Log Analytics; diagnostic settings also route ACR and Postgres logs to the same workspace for unified troubleshooting.

Terraform structure (proposed):

infra/modules/ — one reusable module per resource type (resource_group, log_analytics, container_apps_environment, container_app [shared by frontend & backend], container_registry, postgresql_flexible_server)
infra/environments/dev/ — main.tf, variables.tf, terraform.tfvars, backend.tf (remote state)
Rule of thumb: modules define shape, environments define values (sizes, tags, replica counts live only in tfvars).
Output values needed when creating containers: the backend Container App module must output its internal FQDN (latest_revision_fqdn). This output is wired in environments/dev/main.tf and passed as an environment variable into the frontend Container App module's config — this is what makes nginx's envsubst templating work.



Before going to production, must address: private networking for Postgres, real CORS origin, Key Vault for secrets, WAF/edge layer decision, backup/DR policy, and moving CI's ACR push credential to federated OIDC.