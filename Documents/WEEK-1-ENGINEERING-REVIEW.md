Scope: this review covers only what exists in the `novacart` repo and its connected GitHub configuration today. Every claim below is tied to a file, workflow run, or API check performed as part of this review. Anything not yet built is explicitly labeled "planned / recommended," not "in place."

---

## 1. Source Control
Git workflow:
Single long-lived branch, `main`. Short-lived branches per change: `feat-<ticket>` for features, `hfix-<incident>` for hotfixes (`Documents/git-strategy.md`). All work merges back into `main` via pull request.

How Main is protected ?
- A ruleset on `main` blocks branch deletion and non-fast-forward pushes (no force-push, no deletion).
- Direct pushes to `main` are rejected — confirmed by a real
- Merging requires a pull request with **1 approving review**, stale reviews are dismissed on new pushes, and all review threads must be resolved before merge.


How changes are reviewd and validated :
One human approval (peer review) + the four automated CI jobs described in Section 3, which currently run for visibility but do not gate the merge button.

Emergency fix handling -
The hfix-<incident> naming convention exists, but there is no documented or configured break-glass path — a hotfix goes through the identical PR + 1-review + resolved-threads process as any other change. There is no expedited/emergency merge mechanism today; this is a real gap if a production incident needs a same-minute fix.

Separately, `main` auto-tags itself on every push .

---

## 2. Runtime & Application

Packaging -
Three containers, orchestrated by `compose.yaml`:
- `postgres:16-alpine` — the database.
- `backend` — built from `backend/Dockerfile` (`python:3.12-slim`, installs `requirements.txt`, runs `uvicorn app.main:app`).
- `frontend` — built from `frontend/Dockerfile` (`nginx:1.27-alpine`, serves static JS/HTML/CSS and reverse-proxies API calls).

Startup order
Enforced with Compose depends_on: condition: service_healthy, not just start order: frontend won't start until backend reports healthy, and backend won't start until postgres reports healthy. Each service has a real healthcheck: block (pg_isready for Postgres, an HTTP call to /ready for the backend, a wget spider check for nginx).

Service discovery / communication.
Docker Compose's built-in DNS by service name — no external service registry.
- frontend's nginx.conf proxies location /api/ to http://backend:8000/api/.
- backend connects to the database via DATABASE_URL=postgresql://...@postgres:5432/..., resolving postgres as the Compose service name.
- Two networks isolate blast radius: backend-net (postgres + backend) and frontend-net (backend + frontend). Postgres is not on frontend-net, so the frontend container has no network path to the database — only the backend can reach it.

Runtime configuration
Supplied via a git-ignored `.env` file (confirmed: `.env` and `backend/.env` are in `.gitignore`; no `.env` is committed to the repo). Compose reads `env_file: ./.env` for the backend and injects `POSTGRES_USER/PASSWORD/DB` into both the `postgres` and `backend` service definitions. The application code (`backend/app/main.py`) reads `DATABASE_URL`, `APP_ENV`, `API_VERSION`, `LOG_LEVEL` from the environment, defaulting to a local SQLite file when unset — this lets the backend run standalone (no containers, no Postgres) for pure local development.

Persistent data.
A named Docker volume, postgres_data, mounted at Postgres's data directory — survives container restarts and rebuilds. It does not survive docker compose down -v, which is the exact command documented as the standard "stop everything" instruction in `Documents/local-environment.md`. There is no backup or restore procedure defined anywhere in the repo.

Health and readiness. 
Real, working endpoints, not placeholders:
- `GET /health` — liveness only, no dependency checks, always returns 200 with environment info.
- `GET /ready` — actually opens a DB connection and runs `SELECT 1`; returns HTTP 503 with an error detail if the database is unreachable.
- These are wired into both the Compose healthchecks (gating container startup order) and CI (see below, the `compose-healthcheck` job actually curls these endpoints against a live stack).

---

## 3. CI

**Trigger.** 
`.github/workflows/pr-validation.yaml` runs `on: pull_request: branches: [main]` — every PR opened or updated against `main` triggers it. (A second workflow, `auto-tag-main.yml`, runs on push to `main` and only tags — it does not validate anything.)

**What CI validates**,
 across four independent jobs:
1. **build-validate** — runs `gitleaks` to scan the repo for committed secrets, installs backend dependencies to confirm they resolve cleanly, `python -m py_compile` on the backend for syntax errors, and `node --check` on the frontend JS for syntax errors.
2. **test** — installs `backend/tests/test-requirements.txt` and runs `pytest`. Currently this is **one test file** (`test_api.py`) covering: `/health` and `/ready` return 200, `/api/products` returns seeded products, placing an order with a promo code persists correctly and the total reflects the discount.
3. **docker-build** — runs `docker build` for both the backend and frontend images to confirm they build successfully. This does not push or scan the images.
4. **compose-healthcheck** — the most substantive job: it generates a `.env`, runs `docker compose up -d --build`, then polls `/health` and `/ready` on the live backend container for up to ~150 seconds, dumps `docker compose ps`/`logs` on failure, and tears the stack down with `docker compose down -v`. This is a genuine end-to-end smoke test of the full stack as it would actually be deployed, not a synthetic check.

**What happens when validation fails.** 
Any failing job shows a red status on the PR. Nothing in the repo auto-remediates — a person has to read the job logs and push a fixing commit. Because there is no required-status-check rule (Section 1), a red CI run does **not** by itself block the merge button; it only blocks it if the human reviewer chooses not to approve/merge.

**Which checks are required before merge, today:** none, in the branch-protection sense. Merge requires 1 approval and resolved review threads. CI results are advisory, verified against the live GitHub ruleset, not assumed.

**Important checks still missing:**
- No `required_status_checks` tying CI green to the merge button (the single biggest CI gap).
- No container/dependency vulnerability scanning (only secret scanning via gitleaks — nothing checks CVEs in `python:3.12-slim`, `nginx:1.27-alpine`, `postgres:16-alpine`, or the pip packages).
- No linting or type-checking — only a bare syntax compile (`py_compile`, `node --check`).
- No CD/deploy step — CI stops at validation; nothing pushes a built image to a registry.
- No frontend tests beyond a syntax check.
- No code coverage tracking, and only one backend test file covering the happy path.

---

## 4. Production Readiness — Top 5 Risks

These are risks in the environment actually built this week, evidenced against the files above — not a generic production checklist.

### 1. CI is not enforced as a merge gate
- **Problem:** The GitHub ruleset on `main` (verified via API) requires a PR and 1 approval, but has no required status check. A PR with failing tests, a failed Docker build, or a gitleaks secret-leak hit can still be merged if a human approves it.
- **Potential impact:** A broken build or a leaked credential reaches `main` — and gets auto-tagged as a `Prod-*` release — without CI ever actually having to pass.
- **Recommended improvement:** Add `build-validate`, `test`, `docker-build`, and `compose-healthcheck` as required status checks on the `main` ruleset.
- **Priority:** High.

### 2. Wide-open CORS on the API
- **Problem:** `backend/app/main.py` configures `CORSMiddleware` with `allow_origins=["*"]` and `allow_methods=["*"]`. There is no environment-driven allowlist.
- **Potential impact:** Any website can call the NovaCart API from a browser (credentials are at least disabled, `allow_credentials=False`, which limits cookie-based abuse, but the API itself has no origin boundary). This is exactly the kind of setting that's easy to forget to tighten before going live.
- **Recommended improvement:** Restrict `allow_origins` to the known frontend origin(s), driven by an environment variable so it can differ per environment.
- **Priority:** High.

### 3. No TLS anywhere in the stack
- **Problem:** nginx listens on plain HTTP :80, the backend on plain HTTP :8000. Nothing in `compose.yaml`, the Dockerfiles, or the nginx config handles certificates. `Documents/apllication-discovery.md` itself flags this as open: "missing info - how are we planned to deploy this prod."
- **Potential impact:** If this stack were pointed at the internet as-is, all traffic — including order data — would be plaintext.
- **Recommended improvement:** Terminate TLS in front of the stack (load balancer or reverse proxy) as part of cloud infrastructure design; this is explicitly a cloud-infra-phase concern, not something to retrofit into the current containers.
- **Priority:** High.

### 4. No image or dependency vulnerability scanning
- **Problem:** CI's `docker-build` job only confirms the images build; nothing scans `python:3.12-slim`, `nginx:1.27-alpine`, `postgres:16-alpine`, or the Python dependencies for known CVEs. Secret scanning (gitleaks) exists, but that's a different concern.
- **Potential impact:** A vulnerable base image or dependency ships silently, with no visibility until an incident.
- **Recommended improvement:** Add a container/dependency scan (e.g., Trivy or Grype) as a CI job, and consider making it a required check alongside item #1.
- **Priority:** Medium.

### 5. No backup story for the one Postgres volume
- **Problem:** `compose.yaml` persists all order data in a single named volume, `postgres_data`, on a single Postgres container. `Documents/local-environment.md` documents `docker compose down -v` as the standard "stop everything" command — which deletes that volume. No backup, restore, or replication process exists anywhere in the repo.
- **Potential impact:** Any operator running the documented teardown command against a deployment with real data in it permanently loses all orders and products. There is currently no way to recover from that.
- **Recommended improvement:** Before any real data exists, define a backup/restore procedure and remove `-v` from any non-development teardown instructions; in cloud infrastructure design, move persistence to a managed database with automated backups.
- **Priority:** Medium.

---

## 5. Recommendation

**READY TO PROCEED TO CLOUD INFRASTRUCTURE DESIGN**

This is *not* a statement that NovaCart is safe to expose to real customers — the five risks above are real and unresolved. The recommendation is narrower: the Week 1 foundation is solid enough that cloud infrastructure design can begin on top of it, because the things design needs to build against are demonstrably real and working:

- Branch protection on `main` is live and tested (a real rejected push proves it), not just documented.
- The three-service topology (frontend/backend/postgres), network segmentation (frontend cannot reach the database), and startup ordering (`depends_on: service_healthy`) are implemented and enforceable, giving cloud design a concrete container/network boundary to map onto (e.g., VPC subnets, security groups) rather than a blank page.
- Health (`/health`) and readiness (`/ready`) endpoints are real, dependency-aware, and already exercised end-to-end by a CI job that stands up the full Compose stack and polls them — this is exactly the signal a load balancer or orchestrator needs for target-group health checks.
- Runtime configuration is already externalized to environment variables with no secrets committed to git, which maps cleanly onto a cloud secrets manager / parameter store without code changes.

The five risks identified are the right inputs *for* that design phase, not blockers to starting it — TLS termination, CORS policy, image scanning, and managed/backed-up persistence are exactly the decisions cloud infrastructure design is supposed to make (e.g., ALB with ACM certs, RDS with automated snapshots, ECR image scanning). The CI-merge-gate gap (#1) should be closed in parallel, independent of cloud work, since it's a process fix in GitHub settings, not an infrastructure one.

### What should happen next
1. Add required status checks to the `main` ruleset (independent of cloud work, should happen immediately).
2. Carry the five risks above into cloud infrastructure design as explicit design inputs (TLS at the edge, managed Postgres with backups, image scanning in the pipeline, a real CORS allowlist per environment).
3. Define an actual emergency-fix path before this matters in practice — today a hotfix has no faster route to `main` than a normal change.
