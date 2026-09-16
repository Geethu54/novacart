# NovaCart Azure infrastructure

Terraform for the Azure platform NovaCart runs on. This ticket builds the
shared foundation only — see "Scope" below.

## Layout

```
infra/azure/
  modules/                        one reusable module per resource type
    resource_group/
    log_analytics/
    container_apps_environment/
    postgresql/
  environments/
    dev/                          entry point: run terraform here
      providers.tf                terraform + azurerm/random version pins
      backend.tf                  remote state (azurerm backend, partial config -- see file)
      variables.tf                every input this environment accepts
      locals.tf                   naming convention + merged tags
      main.tf                     wires the modules together
      outputs.tf
      terraform.tfvars.example    copy to terraform.tfvars (git-ignored)
```

Rule of thumb: modules define *shape* (what arguments a resource type takes),
environments supply *values* (sizes, SKUs, replica counts, tags). A future
`environments/staging/` or `environments/prod/` would reuse the same modules
with different tfvars, not different Terraform.

## What this deploys

```
resource group (rg-novacart-dev)
  └─ log analytics workspace (log-novacart-dev)
       └─ container apps environment (cae-novacart-dev)   [empty — see Scope]
  └─ postgresql flexible server (psql-novacart-dev-xxxxxx)
       └─ database "novacart"
       └─ firewall rule: public dev access (see Scope)
```

## Naming & tagging

Resource names follow `<type-abbreviation>-<project>-<environment>`
(`rg-`, `log-`, `cae-`, `psql-`), so a resource's purpose and environment are
readable straight from its name in the Azure portal. The PostgreSQL server
name additionally gets a random suffix because server names must be
globally unique across all of Azure.

Every resource gets the tags `project`, `environment`, `managed_by =
"terraform"`, merged with whatever is passed in `var.tags` (see
`environments/dev/locals.tf`).

## Scope of this ticket

Included: resource group, Log Analytics, Container Apps Environment,
PostgreSQL Flexible Server + database, and the firewall rule needed to reach
Postgres from a developer machine or CI.

Deliberately **not** included, as later work:
- The frontend/backend Container Apps themselves, and the Azure Container
  Registry they'd pull from — a separate app-deployment ticket.
- Private networking for Postgres (delegated subnet / private endpoint) —
  this environment is the public development baseline; production hardening
  is out of scope here.
- Remote state backend, Key Vault, WAF/edge — see
  `Documents/azure-architecture.md` for the full list of pre-production
  follow-ups.

`postgres_allowed_cidr_ranges` (in `environments/dev/variables.tf`) defaults
to allowing every public IP, matching that public-dev scope. Narrow it later
per-operator via a git-ignored `*.auto.tfvars` if that's ever too broad for
your use, without needing to touch the module.

## Usage

State is remote (see `backend.tf`), so `terraform init` needs the backend
config supplied explicitly -- either flags every time, or once via a
git-ignored `backend.hcl`:

```bash
cd infra/azure/environments/dev
cp terraform.tfvars.example terraform.tfvars   # then fill in real values
export TF_VAR_postgres_administrator_password="..."   # don't put this in tfvars

cat > backend.hcl <<'EOF'   # git-ignored -- see backend.tf for what each key does
resource_group_name  = "rg-novacart-tfstate"
storage_account_name = "<the bootstrap storage account -- ask in #novacart-devops>"
container_name       = "tfstate"
key                  = "novacart-dev.tfstate"
use_azuread_auth     = true   # RBAC via your `az login` identity, not a storage account key
EOF

terraform init -backend-config=backend.hcl   # uses your `az login` session
terraform plan
terraform apply
```

CI applies this same environment on merge to `main` instead of from an
operator's machine -- see
[Documents/automated-azure-infrastructure.md](../../Documents/automated-azure-infrastructure.md)
for the pipeline, how it authenticates, and how state is protected.

## Provider version

`azurerm` is pinned to `~> 4.81.0` (patch-level updates only) in
`environments/dev/providers.tf`. Bump the modules together with the
environment if you ever need a newer line.
