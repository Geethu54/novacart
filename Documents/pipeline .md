# Novacart CI/CD Pipeline

## Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              INFRA PIPELINE                             │
└─────────────────────────────────────────────────────────────────────────┘

  PR touches infra/azure/**
        │
        ▼
  terraform-plan.yml  ──────────────▶  posts plan as PR comment (CI, no gate)
        │
        ▼
  merge to main
        │
        ▼
  terraform-apply.yml
    ├─ plan   (no gate)
    └─ apply  ──gated by── dev-infra (required reviewer)
        │
        ▼
  rg-novacart-dev created/updated
  (VNet, Postgres, ACR, Container Apps Environment,
   Key Vault, both Container Apps)


┌─────────────────────────────────────────────────────────────────────────┐
│                             IMAGE PIPELINE                              │
└─────────────────────────────────────────────────────────────────────────┘

  manual dispatch (push trigger disabled for testing)
        │
        ▼
  image-release.yml
    ├─ build-images (matrix: backend, frontend)
    │     az acr login → docker build+push → ACR
    │     tag: git-<12-char-sha>
    │
    └─ trigger-deploy
          gh variable set BACKEND_IMAGE_TAG / FRONTEND_IMAGE_TAG
          (terraform-apply.yml dispatch: commented out)
        │
        │  workflow_run (on success)
        ▼
  image-deploy-cli.yml
    └─ deploy  ──gated by── dev-deploy (required reviewer)
          az containerapp update --image ... (backend)
          az containerapp update --image ... (frontend)
        │
        ▼
  ca-novacart-dev-backend / -frontend now running the new tag
```

### Why the two are decoupled

`infra/azure/modules/container_app/main.tf` has:

```hcl
lifecycle {
  ignore_changes = [template[0].container[0].image]
}
```

- `terraform-apply.yml` can never revert what `image-deploy-cli.yml` deploys.
- Cost: `terraform plan`/`show` never reflects the real running image again, and a **brand-new** environment's first apply still needs a real image already sitting in ACR (Container Apps can't be created pointing at a tag that doesn't exist yet) — that's why infra had to come first, then one `image-release.yml` run, before the very first apply could succeed.

## Identities

Each is a separate Azure AD app registration / service principal (Azure's version of an AWS IAM role / GCP service account) — a non-human account each pipeline authenticates as via OIDC. No stored password or secret; GitHub's OIDC token proves "this workflow run, this branch/environment" and Azure hands back a short-lived token. The repo secret holds only the identity's **Client ID**.

| Identity (secret) | Object ID | Role assigned | Scope | Used by |
|---|---|---|---|---|
| `AZURE_CLIENT_ID_PLAN` | `AZURE_PLAN_SP_OBJECT_ID` = `0513f904-...` | Reader | subscription | `terraform-plan.yml`, plan job of `terraform-apply.yml` |
| `AZURE_CLIENT_ID_APPLY` | `AZURE_APPLY_SP_OBJECT_ID` = `e5ef4a67-...` | Contributor + **User Access Administrator** | subscription / `rg-novacart-dev` | apply job of `terraform-apply.yml` |
| `AZURE_CLIENT_ID_IMAGES` | `AZURE_IMAGES_SP_OBJECT_ID` = `738c3fa0-...` | AcrPush | the ACR only | `image-release.yml` |
| `AZURE_CLIENT_ID_DEPLOY` | App ID `6200acb1-...` | Container Apps Contributor | the two container apps only | `image-deploy-cli.yml` |

Least privilege by design: a compromised CI token in one pipeline can't touch what the others manage (e.g. `IMAGES` can push to the registry but can't read/write any Container App; `DEPLOY` can update the two container apps but can't touch the registry, Postgres, or Key Vault).

### Federated credentials (separate from roles)

A federated credential is the trust rule saying *which GitHub OIDC subject* may claim an identity — independent of what that identity is allowed to do once logged in (the role, above).

- `PLAN`, `APPLY`, `IMAGES` trust: `repo:Geethu54/novacart:ref:refs/heads/main`
- `DEPLOY` additionally trusts: `repo:Geethu54@38241414/novacart@1354333450:environment:dev-deploy`
  (jobs gated by a GitHub Environment present a different OIDC subject format — this account uses the immutable owner/repo-ID form for environment-scoped claims)

## Endpoints (dev)

| Resource | Endpoint |
|---|---|
| Frontend (public) | https://ca-novacart-dev-frontend.greensky-55544bdb.eastus2.azurecontainerapps.io |
| Backend (internal only) | `ca-novacart-dev-backend.internal.greensky-55544bdb.eastus2.azurecontainerapps.io` |
| Container Registry | `acrnovacartdev6qblbi.azurecr.io` |
| Postgres (private, VNet-only) | `psql-novacart-dev-uhhpha.postgres.database.azure.com` |
