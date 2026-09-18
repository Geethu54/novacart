# Automated Azure deployment (image build -> publish -> deploy to dev)

How a merge to `main` that touches `backend/**` or `frontend/**` ends up
running in Azure DEV, without anyone building an image or editing a tfvars
file by hand. One workflow:

| Workflow | Trigger | Does |
|---|---|---|
| [`image-release.yml`](../.github/workflows/image-release.yml) | Push to `main` touching `backend/**`/`frontend/**`, or manual dispatch | Builds + publishes both images to ACR, tagged by commit; hands that tag to `terraform-apply.yml` |

This is the "separate, not-yet-written image-release workflow" referenced in
[automated-azure-infrastructure.md](automated-azure-infrastructure.md) --
that document covers the infra side (`terraform-plan.yml` /
`terraform-apply.yml`); this one covers the application side. Read both if
you're new to the pipeline; the boundary between them is deliberate (see
"Why this doesn't just call `az containerapp update`" below).

## The flow, end to end

```
PR merges to main (backend/** or frontend/** changed)
        |
        v
image-release.yml
  build-images (matrix: backend, frontend)
    - az acr login (OIDC, AcrPush-only identity)
    - docker build + push   ACR: novacart-<app>:git-<12-char-sha>
        |
        v
  trigger-deploy
    - gh variable set BACKEND_IMAGE_TAG / FRONTEND_IMAGE_TAG = git-<sha>
    - gh workflow run terraform-apply.yml -f backend_image_tag=... -f frontend_image_tag=...
        |
        v
terraform-apply.yml  (already existed -- see automated-azure-infrastructure.md)
  plan  -- plans the dev environment with the new image tags, no gate
  apply -- gated by the `dev-infra` environment's required reviewer;
           once approved, applies the exact saved plan -> Container Apps
           in rg-novacart-dev now run the new image
```

Two workflows, two separate approvals to get past deliberately:

1. **The PR merge itself** -- normal peer review, per
   [git-strategy.md](git-strategy.md). This is what "a merged change can
   trigger delivery" means: nothing downstream runs until a human has
   already approved the code.
2. **The `dev-infra` environment's required reviewer**, inside
   `terraform-apply.yml`, unchanged by this workflow. `image-release.yml`
   *triggers* that gate; it never bypasses it. A published image sitting in
   ACR is not the same thing as a deployed one -- see "What 'triggers
   delivery' does and doesn't mean" below.

## Why this doesn't just call `az containerapp update`

Terraform is the only thing that's supposed to change a Container App's
image (`infra/azure/environments/dev/main.tf` sets `image =
"...novacart-backend:${var.backend_image_tag}"`). If this workflow called
`az containerapp update --image ...` directly, the running app and
Terraform's state would disagree the moment it happened -- and the *next*
`terraform apply` (triggered by literally any other infra change) would
silently revert the image back to whatever tag Terraform still remembers,
undoing this release with no error and no obvious cause.

So `trigger-deploy` does two things instead, both non-destructive:

- Updates the `BACKEND_IMAGE_TAG` / `FRONTEND_IMAGE_TAG` **repo variables**
  -- the durable record of "what dev should currently run" that
  `terraform-apply.yml` and `terraform-plan.yml` already read as their
  default (`vars.BACKEND_IMAGE_TAG` in both).
- Dispatches `terraform-apply.yml` itself, passing the new tag explicitly
  via its `workflow_dispatch` inputs (which already existed for exactly
  this purpose -- see the comment at the top of that workflow). Terraform
  then makes the change, through the same plan/approve/apply path every
  other infra change goes through.

This keeps a hard boundary: image delivery and Container App deployment are
two different concerns with two different blast radii, and this workflow
only ever asks the infra pipeline to act -- it never acts on Azure resources
itself. See `Documents/automated-azure-infrastructure.md` for everything
downstream of the `gh workflow run` call (plan output, the approval gate,
how state and outputs are surfaced).

## What "triggers delivery" does and doesn't mean

`image-release.yml` completing successfully means: both images exist in
ACR, tagged with a commit-traceable tag, and a `terraform-apply.yml` run has
started with that tag as input. It does **not** mean Azure DEV has changed
yet -- that still needs the `dev-infra` reviewer to approve the apply job,
same as any other infra change. This is intentional: an image build should
never be able to skip the same review gate a hand-typed `terraform apply`
would have to go through.

## Image tagging -- immutable, and traceable back to source

Every image is tagged `git-<first 12 chars of the commit SHA>`, e.g.
`novacart-backend:git-4f2a9c1e08b3`. Two properties this guarantees:

- **Immutable**: a given tag is only ever pushed once, from one commit.
  Nothing here ever pushes or deploys a mutable tag like `latest` or
  `dev-1` -- there's no way for "what's in ACR" and "what's actually
  running" to point at different content behind the same name.
- **Traceable**: the tag *is* the commit SHA, so `git show <sha>` from the
  tag alone gets you straight to the source. The same SHA is also baked
  into the image itself as an OCI label
  (`org.opencontainers.image.revision`), so tracing works even if the
  tagging convention ever changes -- `docker inspect` or `skopeo inspect`
  against a running image answers "what commit is this" independent of its
  tag.

Combined with `terraform-apply.yml`'s job summary (`terraform output` after
apply, including `frontend_fqdn`) and the `dev-infra` environment's
deployment history, the full chain -- source commit -> image -> Azure
Container App revision -- is reconstructable from GitHub alone, no separate
release tracker needed.

## How this authenticates

Same OIDC pattern as the infra pipeline (see "How the pipeline
authenticates" in `automated-azure-infrastructure.md`), with its own,
narrower identity:

| Identity | Federated credential subject | Azure role | Used for |
|---|---|---|---|
| "images" (`AZURE_CLIENT_ID_IMAGES`) | `ref:refs/heads/main` only | `AcrPush`, scoped to the container registry resource only | `az acr login` in `build-images`, nothing else |

No client secret, no stored ACR admin credential (the registry has
`admin_enabled = false` -- see
`infra/azure/modules/container_registry/main.tf`), nothing that can leak
from a log. The federated credential trusts `ref:refs/heads/main`
specifically, not `pull_request` and not any other branch -- a PR run (see
`pr-validation.yml`, which builds images only to validate the `Dockerfile`s
and never authenticates to Azure at all) has no path to this credential,
and neither does a manual dispatch from a non-`main` branch. It's scoped to
`AcrPush` on the registry alone: this identity cannot read or write
anything else in the subscription, including the Container Apps themselves
-- that capability stays exclusively with the infra pipeline's "apply"
identity, gated behind `dev-infra`'s required reviewer.

`trigger-deploy` needs no Azure credential at all -- `gh variable set` and
`gh workflow run` are GitHub API calls, authenticated with the workflow's
own `GITHUB_TOKEN` (`permissions: actions: write`, scoped to this repo,
expires at the end of the job).

This identity, its federated credential, and its role assignment are
created out-of-band (matching how the "plan"/"apply" identities are
bootstrapped -- see automated-azure-infrastructure.md), not by Terraform:

```bash
# Federated app registration, trusting only pushes to main
az ad app create --display-name novacart-images-ci
APP_ID=$(az ad app list --display-name novacart-images-ci --query '[0].appId' -o tsv)
az ad sp create --id "$APP_ID"
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "novacart-main-push",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<org>/novacart:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'

# AcrPush, scoped to the registry only -- not the resource group
ACR_ID=$(az acr show --name <acr-name> --query id -o tsv)
az role assignment create --assignee "$APP_ID" --role AcrPush --scope "$ACR_ID"
```

Then, as repo secrets: `AZURE_CLIENT_ID_IMAGES` (this app's client ID) --
`AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` are already set for the infra
pipeline and are reused as-is. As a repo **variable**: `ACR_LOGIN_SERVER`
(e.g. `acrnovacartdevqz5aa0.azurecr.io`, from `terraform output -raw
container_registry_login_server`) -- not Terraform-sourced at workflow
runtime, deliberately, to keep this workflow independent of the infra
pipeline's own state/auth (same reasoning as `TF_STATE_*` being plain repo
variables rather than looked up dynamically).

## Where results and failures are visible

- **GitHub Actions tab** -- `image-release.yml`'s own run; a failed
  `docker build`, a failed push (bad credential, registry unreachable), or
  a failed `gh workflow run` call all fail the job and show as a red X,
  same convention as every other workflow in this repo.
- **Job summaries** -- `build-images` reports the tag it built per app;
  `trigger-deploy` reports both final tags and links directly to the
  `terraform-apply.yml` run it started (best-effort: it polls for the run
  for ~25s; if GitHub's API hasn't listed it yet, the summary says to check
  the Actions tab instead of failing the workflow over a cosmetic miss).
- **The triggered `terraform-apply.yml` run** -- its own plan output, its
  `terraform output` summary after apply, and (per
  automated-azure-infrastructure.md) the `dev-infra` environment's
  deployment history showing who approved it.
- **Azure DEV itself** -- once approved and applied,
  `terraform output frontend_fqdn` (or the frontend URL from the apply
  job's summary) is the running result. `az containerapp revision list
  --name ca-novacart-dev-backend -g rg-novacart-dev` shows the image each
  revision is actually running, for a direct check against the tag this
  workflow published.

## What this deliberately does not do

- **No production path.** This only ever targets `terraform-apply.yml`
  against the `dev` environment / `dev-infra` gate. A `prod` release
  pipeline is future work, and per automated-azure-infrastructure.md's own
  "what would be risky to rely on in production" section, would need its
  own identity, its own environment protection rule, and almost certainly
  more than one required reviewer -- none of that is implied by anything
  here.
- **No image scanning / SBOM / provenance attestation.** Worth adding
  before a production path exists; out of scope for closing the dev
  delivery gap this workflow addresses.
- **No automatic rollback.** A bad image still needs a human to either
  re-dispatch `terraform-apply.yml` with a previous `git-<sha>` tag (every
  past tag is still sitting in ACR -- immutability means old versions are
  never overwritten) or revert the merge and let this pipeline publish the
  reverted code as a new tag.
- **Doesn't touch `postgres_administrator_password` or any other Terraform
  variable.** Only the two image tag inputs are ever set by this workflow;
  everything else about the dev environment is exactly what
  `terraform-apply.yml` would have applied anyway.
