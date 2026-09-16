# Automated Azure infrastructure (GitHub Actions + Terraform)

How `infra/azure/environments/dev` gets applied by CI instead of from an
operator's laptop. Three workflows, all in `.github/workflows/`:

| Workflow | Trigger | Does |
|---|---|---|
| [`terraform-plan.yml`](../.github/workflows/terraform-plan.yml) | PR touching `infra/azure/**` | `fmt -check`, `validate`, `plan`; posts the plan on the PR. Never applies. |
| [`terraform-apply.yml`](../.github/workflows/terraform-apply.yml) | Push to `main` touching `infra/azure/**`, or manual dispatch | Plans, then applies that exact plan after a required-reviewer approval. |
| [`terraform-drift-check.yml`](../.github/workflows/terraform-drift-check.yml) | Weekly schedule (Mondays), or manual dispatch | Plan-only; fails the run (red X) if it finds drift. Never applies. |

## What infrastructure the pipeline manages

Everything under `infra/azure/environments/dev` (one Terraform state, one
`terraform apply`): resource group, Log Analytics workspace, the VNet and
its two delegated subnets, the private DNS zone for Postgres, the
PostgreSQL Flexible Server + database, the Container Apps Environment, the
Container Registry, and the frontend/backend Container Apps themselves —
see [infra/azure/README.md](../infra/azure/README.md) for the resource-by-
resource layout.

It does **not** manage: the images those Container Apps run (`backend_image_tag`
/ `frontend_image_tag` are Terraform *inputs* — built and pushed to ACR by a
separate, not-yet-written image-release workflow; this pipeline only points
existing Container Apps at a tag someone else already pushed) or the
Terraform state storage account itself (see "Bootstrapping remote state"
below — that has to exist before this pipeline can run at all).

## When the infrastructure workflow runs

Three distinct triggers, three distinct purposes:

- **On every PR that touches `infra/azure/**`** — plan-only, automatic, no
  approval needed. This is fast feedback for the author and the reviewer:
  is the change syntactically valid, and what would it actually do.
- **On merge to `main`** (same path filter) — apply, gated by a required
  reviewer (see below). This is the only path that changes real Azure
  resources.
- **Weekly, on a schedule** — plan-only drift check. Terraform only knows
  about changes made through it; anyone who edits a resource by hand in the
  Azure portal, or runs `az` directly against `rg-novacart-dev`, creates
  drift that silently sits there until the next apply notices it as an
  unexpected diff. The scheduled check surfaces that within a week instead
  of at the next real change.

All three also accept `workflow_dispatch` for an on-demand run.

## How infrastructure changes are reviewed before they're applied

Two gates, not one:

1. **The PR itself.** Per [git-strategy.md](git-strategy.md), nothing
   reaches `main` without a PR and a peer review — that's true for
   `infra/azure/**` the same as application code. `terraform-plan.yml`
   makes that review meaningful for Terraform specifically: the reviewer
   sees the actual resource-level diff (in a PR comment, kept up to date
   as the branch is pushed to) instead of just reading `.tf` file changes
   and imagining what they'd do.
2. **The apply gate.** `terraform-apply.yml` splits into a `plan` job (runs
   immediately, no gate) and an `apply` job that targets the `dev-infra`
   GitHub Environment. That environment has a required-reviewer protection
   rule, so the `apply` job pauses until someone approves it — and because
   both jobs are in the same workflow run, the approver is looking at the
   plan job's finished output, not a hypothetical. Approval isn't a rubber
   stamp on "trust the pipeline"; it's a second look at the literal plan
   that's about to run.

The `apply` job never re-plans. It downloads the exact `tfplan` file the
`plan` job produced and runs `terraform apply tfplan` — what gets reviewed
is what gets applied, with nothing able to change in between (including
someone else merging a second PR in the gap while the first sits waiting
for approval).

## How Terraform state is stored and protected

State lives in an Azure Storage account (`backend "azurerm"` in
[backend.tf](../infra/azure/environments/dev/backend.tf)), not on a runner's
disk — a GitHub-hosted runner is thrown away after every job, so local
state would mean every run starts from zero and nothing would ever
reconcile.

- **Locking**: the azurerm backend takes a blob lease on the state file for
  the duration of `plan`/`apply`, so a concurrent run (or a local operator
  applying at the same time) fails fast with a lock error instead of
  corrupting state. `terraform-apply.yml` additionally serializes itself
  (`concurrency: group: terraform-dev-apply, cancel-in-progress: false`) so
  a second push queues behind the first rather than racing it.
- **Protection**: the storage account should have blob **versioning** and
  **soft delete** turned on (set at bootstrap time, see below) — Terraform
  state is the single source of truth for what exists; being able to
  recover the previous version after a bad apply or an accidental delete
  matters more here than almost anywhere else in the repo.
- **Access control**: nothing authenticates to the storage account with an
  account key. Both the CI identities and any local operator authenticate
  as themselves (OIDC / `az login` respectively) and are authorized via
  Azure RBAC (`Storage Blob Data Contributor`, scoped to just the `tfstate`
  container) — see the next section.
- **`backend.tf` is deliberately empty** (a "partial configuration"). The
  storage account name isn't hardcoded into version control; it's supplied
  via `-backend-config` at `terraform init` time, from GitHub Actions
  variables in CI and from a git-ignored `backend.hcl` locally (see
  [infra/azure/README.md](../infra/azure/README.md#usage)).

### Bootstrapping remote state

Terraform can't create the backend it's about to store its state in, so the
storage account is a one-time, out-of-band setup, not part of any
`terraform apply` this pipeline runs:

```bash
az group create --name rg-novacart-tfstate --location eastus
az storage account create \
  --name <globally-unique-name> --resource-group rg-novacart-tfstate \
  --sku Standard_LRS --min-tls-version TLS1_2 \
  --allow-blob-public-access false
az storage account blob-service-properties update \
  --account-name <name> --enable-versioning true --enable-delete-retention true --delete-retention-days 30
az storage container create --name tfstate --account-name <name> --auth-mode login
```

Grant `Storage Blob Data Contributor` on that container (not the whole
storage account, and not `Owner`/`Contributor`) to whichever identities need
to read/write state — the two federated app registrations below, and any
individual operator who applies locally.

## How the pipeline authenticates

OpenID Connect (OIDC) federated credentials — no client secret, no stored
Azure credential of any kind, nothing that can leak from a log or sit in a
secrets store waiting to expire or be rotated. `azure/login@v2` exchanges a
short-lived GitHub Actions OIDC token (requires `permissions: id-token:
write`, set on every workflow here) for an Azure AD access token, scoped to
exactly the workflow run that requested it.

Two Azure AD app registrations, not one, on purpose — least privilege
between *reading* infrastructure state and *changing* it:

| Identity | Federated credential subject | Azure role | Used by |
|---|---|---|---|
| "plan" (`AZURE_CLIENT_ID_PLAN`) | `repo:<org>/novacart:pull_request` | `Reader` on the dev subscription/RG | `terraform-plan.yml`, the `plan` job in `terraform-apply.yml`, `terraform-drift-check.yml` |
| "apply" (`AZURE_CLIENT_ID_APPLY`) | `repo:<org>/novacart:environment:dev-infra` | `Contributor` on `rg-novacart-dev` (or a narrower custom role) | only the `apply` job in `terraform-apply.yml` |

The subject claim is what makes this safe rather than cosmetic: the
"apply" credential's federated trust is scoped to the `dev-infra`
**environment**, so an Azure AD token that can create/modify/delete
resources is only ever mintable for a job that (a) explicitly declares
`environment: dev-infra` and (b) has therefore already passed that
environment's required-reviewer gate. A PR-triggered run — including one
from a branch in the same repo — has no path to that credential at all; it
can only ever obtain the read-only "plan" token. `AZURE_CLIENT_ID_APPLY` is
stored as an **environment secret** on `dev-infra`, not a repository
secret, for the same reason: repository secrets are visible to every
workflow run, environment secrets only to jobs targeting that environment.

`postgres_administrator_password` is a separate concern — a Terraform
*variable* value, not an Azure credential — and is still a plain GitHub
Actions secret (`TF_VAR_POSTGRES_ADMINISTRATOR_PASSWORD`) injected as an
env var, the same way it's handled for a local operator
(`TF_VAR_postgres_administrator_password`, per
[infra/azure/README.md](../infra/azure/README.md) and the variable's own
description in `variables.tf`). OIDC removes the need for a stored *Azure*
credential; it doesn't remove the need to store this one.

## Where workflow results and failures are visible

- **GitHub Actions tab** — every run, every job, full logs. This is the
  primary source of truth; a red X here means look here first.
- **Job summaries** (`$GITHUB_STEP_SUMMARY`) — each workflow writes the
  plan (or, on apply, the resulting `terraform output`) to the run's
  Summary page, so the headline result doesn't require scrolling through
  raw step logs.
- **PR comments** — `terraform-plan.yml` posts the plan directly on the PR
  (updating the same comment on repushes rather than piling up new ones),
  so a reviewer sees it without leaving the PR.
- **The `dev-infra` environment's deployment history** — every apply
  (approved or still pending) shows up against that environment on the
  repo's Environments page, with a link back to the run and who approved
  it.
- **Drift check failures** show up as a normal failed scheduled workflow
  run (red X in the Actions tab, and in the repo's Insights → Actions
  view). Nothing pages anyone automatically yet — see the production-risk
  note on that below.

## What the pipeline assumes about the Azure dev environment

- The state storage account + container already exist (see
  "Bootstrapping remote state") and both federated app registrations have
  already been created and granted the roles in the table above — none of
  that is itself Terraform-managed by this environment, deliberately, to
  avoid a circular dependency on its own state/credentials.
- One environment, one state file, one set of credentials. There's no
  per-branch or per-PR ephemeral environment — every PR plans against the
  same `rg-novacart-dev` state everyone else's PRs plan against, so two PRs
  changing overlapping resources will show each other's in-flight changes
  in their plan output (accurate, if occasionally confusing) rather than
  each getting an isolated sandbox.
- `backend_image_tag` / `frontend_image_tag` (via the `BACKEND_IMAGE_TAG` /
  `FRONTEND_IMAGE_TAG` repo variables, or `workflow_dispatch` inputs)
  reflect an image that's *already been pushed to ACR*. The pipeline
  doesn't check that; if a variable points at a tag that was never built,
  `terraform apply` will succeed (it only sets the image reference — see
  [azure-dev-deployment.md](azure-dev-deployment.md)) and the Container App
  revision will fail to pull, which will look like an application problem,
  not an infrastructure one, when it's investigated.
- Runners are GitHub-hosted (`ubuntu-latest`) with outbound internet
  access to `management.azure.com` and the Terraform Registry — nothing
  here assumes a self-hosted runner, a private network, or firewalled
  egress.
- Pull requests come from branches in this repository. `pull_request`
  workflow runs from a fork don't receive repository secrets from GitHub
  by default, so a fork PR's `terraform-plan.yml` run would fail at the
  Azure login step — treated here as acceptable (there are no external
  fork contributors), not as a solved problem. See below.

## What would be risky to rely on in production

- **The fork-PR gap above stops being cosmetic.** If this repo ever
  accepts external contributions, `pull_request` (rather than
  `pull_request_target`) is the *correct* choice specifically because it
  denies forks secrets and OIDC access — switching it to get fork plans
  working would hand a read-only Azure credential to arbitrary PR authors.
  Don't switch it without a real design for that.
- **One environment, one reviewer gate, one set of credentials** is a dev-
  appropriate shape, not a production one. Production needs its own state
  file, its own storage container, its own scoped "apply" identity, and
  its own environment protection rule (very likely more than one required
  reviewer, and probably a wait timer) — none of that exists here, and
  copying `dev-infra`'s settings onto a `prod-infra` environment by
  reflex would under-protect production.
- **`Contributor` on the apply identity is broader than it should be
  long-term.** It's the pragmatic starting point for a small, fast-moving
  dev resource group; production should scope this down to a custom role
  with only the specific `Microsoft.*/write|delete` actions the modules in
  `infra/azure/modules/` actually use, so a compromised or buggy workflow
  can't do more than the pipeline is supposed to.
- **No approval timeout, no forced second reviewer, no break-glass audit
  trail beyond GitHub's own environment history.** Fine for a small team on
  a dev environment; a production change process typically wants more than
  "one person clicked approve" as its record, especially for anything
  touching customer data (the Postgres server here).
- **The scheduled drift check only turns the run red.** Nobody is paged.
  In production, unexplained drift on a database or network resource is
  the kind of thing that wants an actual notification (Slack/Teams/on-call
  paging), not a GitHub Actions tab that someone happens to check.
- **`terraform apply -auto-approve tfplan` inside the `apply` job** is safe
  *only* because the plan file was produced minutes earlier in the same
  run against the same state lock. If this pattern is ever copied into a
  workflow with a longer gap between plan and apply (e.g. an approval that
  can sit for days), the saved plan can go stale relative to the real
  infrastructure and apply something other than what was actually
  reviewed — re-plan immediately before apply in that case instead of
  trusting an old plan file.
- **Secrets stored as `TF_VAR_*` still means the Postgres admin password
  passes through GitHub Actions' secret masking, not a real secrets
  manager.** Fine for a dev database; production should pull this from Key
  Vault at apply time (see the "before going to production" list in
  [azure-architecture.md](azure-architecture.md)) rather than from a
  GitHub secret, so rotation doesn't require a repo-admin round-trip.
