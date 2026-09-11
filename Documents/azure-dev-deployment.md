
```
resource group (rg-novacart-dev)
  log analytics workspace (log-novacart-dev)
  container registry (acrnovacartdev<random>)              [admin disabled]
  container apps environment (cae-novacart-dev)
    container app: frontend (ca-novacart-dev-frontend)      [external ingress, :80]
    container app: backend  (ca-novacart-dev-backend)       [internal-only ingress, :8000]
  postgresql flexible server (psql-novacart-dev-<random>)
    database: novacart
    firewall rule: public dev access (AllowAllPublicDev)
```

Request flow:

```
Browser --HTTPS--> frontend (nginx)
                      |
                      | /api/* proxied internally, via Container Apps
                      | environment DNS (see "Frontend -> backend" below)
                      v
                    backend (FastAPI)
                      |
                      | DATABASE_URL, TLS required
                      v
                    postgresql flexible server
```

The frontend never exposes the backend or the database directly. A browser
only ever talks to the frontend's public FQDN; `/api/*` requests are
reverse-proxied by nginx to the backend over the Container Apps
Environment's internal network, and the backend is the only thing that ever
opens a connection to Postgres.

Terraform structure (added by this ticket, alongside the DEVOPS-008 modules):

- `infra/azure/modules/container_registry/` — the ACR
- `infra/azure/modules/container_app/` — one shape shared by both the
  frontend and backend apps; the environment supplies what makes each one
  different (image, port, ingress visibility, env vars)
- `infra/azure/environments/dev/main.tf` — wires ACR + both container apps
  into the existing resource group / Container Apps Environment / Postgres
  server from DEVOPS-008

## Azure services involved

| Service | Role |
|---|---|
| Resource Group | Container for everything below |
| Log Analytics workspace | Collects stdout/stderr from both Container Apps |
| Azure Container Registry (Basic SKU) | Holds the `novacart-backend` and `novacart-frontend` images |
| Container Apps Environment | Hosting boundary + internal DNS for the two apps |
| Container App: frontend | nginx serving the static site, external ingress |
| Container App: backend | FastAPI, internal-only ingress |
| PostgreSQL Flexible Server | Application database (`novacart`) |

Image pulls use each Container App's system-assigned managed identity with
an `AcrPull` role assignment scoped to the registry — no admin
username/password credential exists on the registry (`admin_enabled =
false` in the `container_registry` module).

## Frontend -> backend endpoint

The frontend's nginx config ([frontend/nginx.conf.template](../frontend/nginx.conf.template))
proxies `/api/` to `${BACKEND_INTERNAL_URL}`, substituted at container
startup by nginx's built-in `envsubst`-on-templates entrypoint hook. That
variable is set in Terraform on the frontend Container App
([infra/azure/environments/dev/main.tf](../infra/azure/environments/dev/main.tf)):

```hcl
env_vars = {
  BACKEND_INTERNAL_URL = "https://${module.backend_app.fqdn}"
}
```

`module.backend_app.fqdn` is the backend Container App's **internal-only**
ingress FQDN (Azure Container Apps DNS pattern:
`<backend-app-name>.internal.<container-apps-environment-default-domain>`),
resolvable only from other apps inside the same Container Apps Environment
— never from the public internet. Referencing it as a module output (rather
than pre-computing the string) means Terraform creates the backend app
first and wires in its real, Azure-assigned FQDN automatically.

## Backend -> database endpoint

The backend reads a standard libpq connection string from `DATABASE_URL`
(see `_open_connection()` in [backend/app/main.py](../backend/app/main.py)),
set as a **secret-backed** env var on the backend Container App:

```hcl
locals {
  backend_database_url = "postgresql://${var.postgres_administrator_login}:${var.postgres_administrator_password}@${module.postgresql.server_fqdn}:5432/${module.postgresql.database_name}?sslmode=require"
}
```

`module.postgresql.server_fqdn` is the Postgres Flexible Server's public
FQDN from the DEVOPS-008 baseline (`psql-novacart-dev-<random>.postgres.database.azure.com`).
`sslmode=require` is mandatory — Azure Postgres Flexible Server rejects
unencrypted connections. The value is declared as an Azure Container Apps
**secret** and referenced by name from the container's env block, so the
password never appears as a plain env value in the app's spec.

This is a public-endpoint connection (no private networking, no delegated
subnet/private endpoint) — matching this ticket's explicit scope boundary
("do not introduce private database networking here") and the existing
`postgres_allowed_cidr_ranges` firewall default from DEVOPS-008
(`AllowAllPublicDev`, 0.0.0.0-255.255.255.255), which already covers
whatever outbound IP the Container Apps Environment uses since it has no
custom VNet integration.

## Expected development endpoint(s)

- **Public**: the frontend's FQDN — `terraform output frontend_fqdn`
  (pattern: `ca-novacart-dev-frontend.<environment-id>.<region>.azurecontainerapps.io`).
  This is the one URL a developer or browser is expected to open.
- **Internal only, not publicly reachable**: the backend's FQDN —
  `terraform output backend_internal_fqdn`. Reachable only from other apps
  in the same Container Apps Environment (i.e. the frontend's nginx proxy).
  Directly curling it from outside Azure will fail to resolve/connect by
  design — that's expected, not a bug. It's still counted as a "configured
  development endpoint" in the sense the ticket means: the backend is
  addressable and running inside the environment, not implied/external.
- **Not publicly reachable, and not meant to be**: the Postgres server FQDN
  — `terraform output postgres_server_fqdn`. The firewall being open is a
  dev-scope convenience for operator/CI access to the database directly
  (e.g. `psql`), not an endpoint the application itself is meant to be
  reached through.

## Deploying

Prerequisites: `az login` with access to the target subscription, Terraform
CLI, `terraform.tfvars` created from `terraform.tfvars.example`, and
`TF_VAR_postgres_administrator_password` exported (never committed).

The registry has to exist before an image can be pushed into it, and the
Container Apps need a real image to exist before they'll come up healthy —
so a brand-new environment is a three-step bootstrap, not a single `apply`:

```bash
cd infra/azure/environments/dev
cp terraform.tfvars.example terraform.tfvars   # fill in real values
export TF_VAR_postgres_administrator_password="..."
terraform init

# 1. Create just the registry first (placeholder image tags -- unused by
#    this targeted apply, but Terraform validates all variables regardless
#    of -target).
terraform apply -target=module.container_registry \
  -var="backend_image_tag=pending" -var="frontend_image_tag=pending"

# 2. Build and push the real images now that the registry exists.
ACR_NAME=$(terraform output -raw container_registry_login_server | cut -d. -f1)
az acr build --registry "$ACR_NAME" --image novacart-backend:dev-1 ../../../../backend
az acr build --registry "$ACR_NAME" --image novacart-frontend:dev-1 ../../../../frontend

# 3. Put the real tags in terraform.tfvars (backend_image_tag = "dev-1",
#    frontend_image_tag = "dev-1"), then apply everything else.
terraform apply
```




terraform plan -target=module.container_registry \                
  -var="backend_image_tag=pending" -var="frontend_image_tag=pending" \
  -var="postgres_administrator_password=Geethu12054$"
-----initial terrafrom Plan -----
Terraform used the selected providers to generate the following execution plan. Resource actions are indicated with the following symbols:
  + create

Terraform will perform the following actions:

  # random_string.acr_suffix will be created
  + resource "random_string" "acr_suffix" {
      + id          = (known after apply)
      + length      = 6
      + lower       = true
      + min_lower   = 0
      + min_numeric = 0
      + min_special = 0
      + min_upper   = 0
      + number      = true
      + numeric     = true
      + result      = (known after apply)
      + special     = false
      + upper       = false
    }

  # module.container_registry.azurerm_container_registry.this will be created
  + resource "azurerm_container_registry" "this" {
      + admin_enabled                                = false
      + admin_password                               = (sensitive value)
      + admin_username                               = (known after apply)
      + azuread_authentication_as_arm_policy_enabled = true
      + data_endpoint_host_names                     = (known after apply)
      + encryption                                   = (known after apply)
      + export_policy_enabled                        = true
      + id                                           = (known after apply)
      + location                                     = "eastus"
      + login_server                                 = (known after apply)
      + name                                         = (known after apply)
      + network_rule_bypass_for_tasks_enabled        = false
      + network_rule_bypass_option                   = "AzureServices"
      + network_rule_set                             = (known after apply)
      + public_network_access_enabled                = true
      + resource_group_name                          = "rg-novacart-dev"
      + role_assignment_mode                         = "LegacyRegistryPermissions"
      + sku                                          = "Basic"
      + tags                                         = {
          + "environment" = "dev"
          + "managed_by"  = "terraform"
          + "project"     = "novacart"
        }
      + trust_policy_enabled                         = false
      + zone_redundancy_enabled                      = false
    }

  # module.resource_group.azurerm_resource_group.this will be created
  + resource "azurerm_resource_group" "this" {
      + id       = (known after apply)
      + location = "eastus"
      + name     = "rg-novacart-dev"
      + tags     = {
          + "environment" = "dev"
          + "managed_by"  = "terraform"
          + "project"     = "novacart"
        }
    }

Plan: 3 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + container_registry_login_server = (known after apply)
  + location                        = "eastus"
  + resource_group_name             = "rg-novacart-dev"
╷
│ Warning: Resource targeting is in effect
│ 
│ You are creating a plan with the -target option, which means that the result of this plan may not represent all of the changes requested by the current configuration.
│ 
│ The -target option is not for routine use, and is provided only for exceptional situations such as recovering from errors or mistakes, or when Terraform specifically
│ suggests to use it as part of an error message.
╵

Teeraform apply - creation of containers

│ 
│ You are creating a plan with the -target option, which means that the result of this plan may not represent all of the changes requested by the current configuration.
│ 
│ The -target option is not for routine use, and is provided only for exceptional situations such as recovering from errors or mistakes, or when Terraform specifically
│ suggests to use it as part of an error message.
╵

Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes

random_string.acr_suffix: Creating...
random_string.acr_suffix: Creation complete after 0s [id=qz5aa0]
module.resource_group.azurerm_resource_group.this: Creating...
module.resource_group.azurerm_resource_group.this: Still creating... [00m10s elapsed]
module.resource_group.azurerm_resource_group.this: Still creating... [00m20s elapsed]
module.resource_group.azurerm_resource_group.this: Creation complete after 24s [id=/subscriptions/2f36d352-db13-4852-af92-8a815ae2d929/resourceGroups/rg-novacart-dev]
module.container_registry.azurerm_container_registry.this: Creating...
module.container_registry.azurerm_container_registry.this: Still creating... [00m10s elapsed]
module.container_registry.azurerm_container_registry.this: Still creating... [00m20s elapsed]
module.container_registry.azurerm_container_registry.this: Creation complete after 29s [id=/subscriptions/2f36d352-db13-4852-af92-8a815ae2d929/resourceGroups/rg-novacart-dev/providers/Microsoft.ContainerRegistry/registries/acrnovacartdevqz5aa0]
╷
│ Warning: Applied changes may be incomplete
│ 
│ The plan was created with the -target option in effect, so some changes requested in the configuration may have been ignored and the output values may not be fully
│ updated. Run the following command to verify that no other changes are pending:
│     terraform plan
│ 
│ Note that the -target option is not suitable for routine use, and is provided only for exceptional situations such as recovering from errors or mistakes, or when Terraform
│ specifically suggests to use it as part of an error message.
╵

Apply complete! Resources: 3 added, 0 changed, 0 destroyed.

Outputs:

container_registry_login_server = "acrnovacartdevqz5aa0.azurecr.io"
location = "eastus"
resource_group_name = "rg-novacart-dev"




---------------
export TF_VAR_postgres_administrator_password='<same-or-new-strong-password>'

creating registry 
terraform apply -target=module.container_registry \
  -var="backend_image_tag=pending" -var="frontend_image_tag=pending"

build and push both images 
ACR_NAME=$(terraform output -raw container_registry_login_server | cut -d. -f1)
az acr build --registry "$ACR_NAME" --image novacart-backend:dev-1 ../../../../backend
az acr build --registry "$ACR_NAME" --image novacart-frontend:dev-1 ../../../../frontend

apply

terraform apply 

terraform output frontend_fqdn
curl -s "https://$(terraform output -raw frontend_fqdn)/api/products"