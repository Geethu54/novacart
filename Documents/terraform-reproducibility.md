# Terraform reproducibility (infra/azure/)

How the Terraform under [infra/azure/](../infra/azure/) is organized, which
values are expected to change between runs/environments and which aren't,
how to validate a change before `apply`, and conventions to follow when
extending it. For what the *dev environment itself* looks like once
deployed (architecture, endpoints, verification) — a different question —
see "Where the deployment documentation lives" at the bottom.

## How the Terraform is organized

```
infra/azure/
  modules/                        one reusable module per resource type,
                                   no environment-specific values inside
    resource_group/
    log_analytics/
    container_apps_environment/
    postgresql/
    container_registry/
    container_app/                one shape, shared by both the frontend
                                   and backend apps
  environments/
    dev/                          entry point: run terraform here
      providers.tf                terraform + azurerm/random version pins
      backend.tf                  state config (local for now, see file)
      variables.tf                every input this environment accepts
      locals.tf                   naming convention + merged tags
      main.tf                     wires the modules together, one
                                   environment's worth of values
      outputs.tf
      terraform.tfvars.example    copy to terraform.tfvars (git-ignored)
      terraform.tfvars            your real values -- never committed
```

The rule of thumb, and the thing to preserve when extending this: **modules
define shape** (what arguments a resource type takes — sizes, SKUs, and
environment identity are never hardcoded inside a module), **environments
supply values**. A module never references `var.environment` or a fixed
region; it takes `location`, `resource_group_name`, etc. as plain inputs
from whichever environment calls it. This is what makes it possible to add
`environments/staging/` or `environments/prod/` later that reuse the exact
same modules with different `terraform.tfvars` — not different Terraform
code.

`environments/dev/main.tf` is the one place that actually wires modules
together into a specific shape: resource group → Log Analytics → Container
Apps Environment → (backend + frontend Container Apps) → PostgreSQL, plus
the ACR and the user-assigned identity used for `AcrPull`. Reading that file
top to bottom *is* reading the environment's architecture.

## Which values are environment-specific

These are expected to differ between `dev`, and any `staging`/`prod` added
later — set per-environment in that environment's own `terraform.tfvars`,
never in a module:

| Value | Where | Why it varies |
|---|---|---|
| `environment` | `variables.tf` | Literally what distinguishes environments — feeds the naming prefix and the `environment` tag |
| `location` / `postgres_location` | `variables.tf` | Region choice; also, some subscriptions have specific services restricted in specific regions (see "Validation" below) — this is a real, not hypothetical, source of per-environment difference |
| `postgres_sku_name`, `postgres_storage_mb`, `log_analytics_sku`/`retention_in_days` | `variables.tf` | Dev is deliberately small/cheap (`B_Standard_B1ms`); staging/prod would size up |
| `postgres_allowed_cidr_ranges` | `variables.tf` | Dev is intentionally public/wide-open (`AllowAllPublicDev`); a hardened environment would narrow this |
| `postgres_administrator_login` / `postgres_administrator_password` | `variables.tf` | Credentials must never be shared across environments. The password has no default and is `sensitive = true` — supply it via `TF_VAR_postgres_administrator_password`, never in a tfvars file |
| `backend_image_tag` / `frontend_image_tag` | `variables.tf` | No default, deliberately — every `apply` must name a specific, known image (e.g. a git SHA) rather than silently reusing whatever a moving tag like `latest` currently points to |
| `tags` | `variables.tf` | Free-form extra tags (e.g. `owner`) merged on top of the standard set |

## Which values should remain stable across runs

These are either hardcoded on purpose, or computed in a way that's
deliberately deterministic — don't casually override them per-run, and
think twice before changing them at all, since several drive Azure resource
*names*, which are often immutable (changing them forces a destroy +
recreate, not an in-place update):

- **The naming convention** (`locals.tf`): `<type-abbreviation>-<project>-
  <environment>` (`rg-`, `log-`, `cae-`, `ca-`, `id-`) and the merged tag set
  (`project`, `environment`, `managed_by = "terraform"`, plus `var.tags`).
  Keeping this consistent is what makes a resource's purpose readable
  straight from its name in the Azure Portal — a new resource type should
  follow the same pattern, not invent a new one.
- **Provider version pins** (`providers.tf`): `azurerm ~> 4.81.0`, `random
  ~> 3.6`. Patch-level updates only. Bumping a minor/major version is a
  deliberate, tested decision (schema can change between minor versions —
  see the `terraform validate` note below), not something that should
  drift silently via `terraform init -upgrade`.
- **Module input/output contracts**: e.g. `container_app`'s `fqdn` output,
  or the fact that `postgresql` always takes `administrator_password` as a
  plain input and never generates one itself. Other code (and
  `Documents/azure-dev-deployment.md`) depends on these shapes.
- **The two `random_string` suffixes** (`acr_suffix`, `postgres_suffix` in
  `main.tf`) are the one deliberate exception worth calling out explicitly,
  because it surprises people: they are **not** meant to be stable. ACR and
  PostgreSQL server names must be globally unique across *all* of Azure, so
  a fresh random suffix is generated every time that resource is created.
  Destroying and recreating the environment *will* change the ACR login
  server and Postgres FQDN — that's expected, not a bug. Anything that
  needs a stable identifier across recreates (this doesn't currently apply
  to anything in this environment) would need a fixed name instead of this
  pattern.

## How validation should be performed before `apply`

In order, cheapest/fastest first:

```bash
cd infra/azure
terraform fmt -check -recursive -diff   # formatting -- fix with `terraform fmt -recursive`

cd environments/dev
terraform init                          # or -backend=false for a syntax-only check
terraform validate                      # schema-checks against the pinned provider version
terraform plan                          # or plan with -target for a partial/bootstrap step
```

`validate` catches real problems, not just style: it will fail if a
resource argument doesn't match what the pinned `azurerm` provider version
actually supports (this caught a real mistake during development — see the
git history around the `container_app` module's `registry`/`secret`/`env`
blocks). It also does **not** require Azure credentials, so it's safe to
run before `az login`, in CI, or with no subscription access at all —
`plan`/`apply` are the ones that need real credentials.

Two validation steps that `terraform validate`/`plan` **cannot** catch,
because they're facts about the target Azure subscription rather than
about the Terraform code, and both bit this environment for real on first
deploy:

```bash
# Is the resource provider this environment needs actually registered on
# the subscription? (Fresh/PAYG subscriptions don't always have every
# provider pre-registered.)
az provider show --namespace Microsoft.App --query registrationState -o tsv

# Is the service actually available in this region for this subscription?
# (Azure can restrict specific services in specific regions per-subscription
# -- this is not the same question as "does the region exist".)
az postgres flexible-server list-skus --location <region>
# look for "reason": "Provisioning is restricted in this region..."
```

Skipping these two isn't a style issue — it's exactly how a `plan` that
looks completely clean turned into a failed `apply` partway through, twice,
on the same subscription (full account in
`Documents/azure-dev-deployment.md`).

## Conventions to follow when extending this code

- **New Azure resource type → new module under `modules/`.** It should take
  its identity (`name`, `location`, `resource_group_name`, `tags`) as plain
  inputs and contain no reference to `dev`, a specific region, or any other
  environment-specific value. If you catch yourself hardcoding something
  environment-specific inside a module, that value belongs in the calling
  environment's `variables.tf`/`main.tf` instead.
- **Follow the existing naming and tagging convention** (see above) for
  anything new rather than inventing a parallel scheme.
- **Never commit a secret.** Real values live in `terraform.tfvars`
  (git-ignored) or `TF_VAR_*` environment variables — check
  `.gitignore` before assuming a new file pattern is covered, and mark any
  new sensitive variable `sensitive = true`.
- **Run `terraform fmt -recursive` before committing.** CI/reviewers
  shouldn't be the ones catching formatting drift.
- **Prefer a module output over a hardcoded/guessed value** when one
  resource's config depends on another's Azure-assigned property (e.g. an
  FQDN, a resource ID). Referencing the actual output — not a
  string you predicted — is also what makes Terraform infer the correct
  creation order automatically. Where the dependency isn't expressed
  through any attribute reference (this environment's `container_app`
  modules only consume the shared ACR-pull identity's `.id`, not anything
  produced by its role assignment), add an explicit `depends_on` rather
  than assume Terraform will infer an ordering it has no way to see.
- **Adding `environments/staging/` or `environments/prod/`**: copy the
  `environments/dev/` directory structure, write a new `terraform.tfvars`
  with that environment's values, and reuse the modules unchanged. If a
  module needs a new capability to support the new environment (e.g. private
  networking for Postgres, out of scope for `dev` today), extend the module
  with a new input that defaults to the `dev` behavior, rather than forking
  it.

## Where the deployment documentation lives

This document is about the Terraform *code*: its structure and the
conventions for working with it, independent of any one environment. For
what the **dev environment** built from this code actually looks like once
deployed — which Azure services are involved, the frontend→backend and
backend→database endpoint chains, the expected public URL, the real issues
hit deploying it (region restrictions, identity/`AcrPull` ordering, nginx
proxy config) and what was verified afterward — see
[Documents/azure-dev-deployment.md](azure-dev-deployment.md).
