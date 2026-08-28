# cca-infra

Terraform + Kubernetes (K3s) deployment infrastructure for the "cca"
travel-planner app: `cca_backend` (Go API), `cca_frontend` (Flutter, built to
an APK), and `cca_admin_frontend` (React admin UI). Deploys to a single home
Ubuntu 24 server over three environments (`integration`/`uat`/`production`),
each a Kubernetes namespace, driven by GitHub Actions workflows running on a
self-hosted runner on that same server. `integration` auto-deploys on every
push to any app repo's `main`; `uat`/`production` are always manually
triggered from the Actions tab.

## Start here

- **[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)** - what's built, why,
  and the ground-truth findings (from reading the actual app repos) that
  changed the original design. Read this first.
- **[docs/RUNBOOK.md](docs/RUNBOOK.md)** - step-by-step: bare server to a
  working deploy, plus day-2 operations, rollback, and troubleshooting.
- **[docs/WORKFLOWS.md](docs/WORKFLOWS.md)** - what each GitHub Actions
  workflow does, when it triggers, and what its inputs mean.
- **[docs/SECURITY.md](docs/SECURITY.md)** - credential findings in the app
  repos and their rotation checklists (not fixed by this repo - see below).
- **[docs/AWS_MAPPING.md](docs/AWS_MAPPING.md)** - what each piece here
  stands in for in AWS terms, if that's a useful frame.
- **[final-plan.md](final-plan.md)** / **[initial-plan.md](initial-plan.md)**
  - the original AI-assisted design conversations this implementation is
    based on. `final-plan.md` supersedes `initial-plan.md`.

## Branches

- `main` - planning documents only (no infrastructure code yet).
- `initial_implementation` - the first full implementation: Terraform,
  Dockerfiles, GitHub Actions workflows, and operational scripts. Produced
  and committed without access to the actual home server - see
  IMPLEMENTATION_PLAN.md §3 for exactly what that does and doesn't mean.

## Ports

Every Service is a K3s `NodePort` (range narrowed to `3200-4000` by
`install-k3s.sh`, clear of the apiserver's `6443` and flannel's `8472`) -
reachable at `http://<server-address>:<port>` once deployed. Each Service
pins its `nodePort` explicitly; none are left to the allocator.

| Service | integration | uat | production |
|---|---|---|---|
| Backend API (`GET /api/health_check`) | 3211 | 3311 | 3411 |
| Admin frontend | 3202 | 3302 | 3402 |
| MongoDB (Compass/mongosh debugging - see [docs/RUNBOOK.md §12](docs/RUNBOOK.md#12-connecting-to-mongodb-directly-compassmongosh)) | 3213 | 3313 | 3413 |

| Platform service (cluster-wide, one instance) | Port |
|---|---|
| Grafana | 3900 |

`backend-cron`/`backend-video` have no NodePort - they're internal
workers with no HTTP traffic routed to them (see `terraform/app/backend_cron.tf`).

## Microservices

Every backend workload runs from the **same** `cca-backend` image
(`docker/backend/Dockerfile`) - the role is selected entirely by
Kubernetes `args:`, not by separate images. See `terraform/app/backend_api.tf`
/ `backend_cron.tf` for the exact `args:` and probe config behind each row.

| Workload | Image role (`args:`) | Kind | Scaling | Notes |
|---|---|---|---|---|
| `backend` | `-micro_service api_server` | Deployment + Service (NodePort) | HPA, CPU-based (see `hpa.tf`) | The only backend workload with a Service/NodePort - serves `GET /api/health_check`, `/api/swagger`, and every `/api/...` route. |
| `backend-cron` | *(no flag - falls through to `main.go`'s `default` case)* | Deployment, `replicas = 1`, never HPA'd | Fixed at 1 | Runs the MongoDB change-stream trigger and all scheduled jobs (token cleanup, `VideoStreamGenerationCron`). **Not** run via `-micro_service cron_job` - that dedicated code path has a real bug (starts its background work, then returns from `main()` immediately, killing it before anything fires) - see `backend_cron.tf`'s header comment. A second replica would double-run every scheduled job and duplicate change-stream handling, so this is deliberately never autoscaled. |
| `backend-video` *(optional, `enable_video_worker`)* | `-micro_service video_processing` | CronJob, `concurrency_policy = Forbid` | N/A - one-shot per schedule tick | Off by default (`docs/RUNBOOK.md §11`). Real local `ffmpeg` encoding, never GCE - see IMPLEMENTATION_PLAN.md §14. |
| `admin-frontend` | *(separate `cca-admin-frontend` image)* | Deployment + Service (NodePort) | HPA | nginx + a static React build; the ConfigMap-mounted nginx config (`kubernetes/nginx/admin-default.conf.tpl`) proxies `/api/` to `backend` - the image itself has no build-time API URL, so one image serves every environment. |
| `redis` | `redis:7-alpine` (upstream image) | Deployment + Service (ClusterIP) | Fixed at 1 | In-cluster cache, no auth (the app's client hardcodes an empty password). Every backend workload has an `initContainer` that blocks until this is reachable, since the app hard-panics on boot if Redis isn't up. |
| `cca-mongodb` | MongoDB Community Operator-managed | StatefulSet (via `MongoDBCommunity` CR) | `mongo_members` var, manual (not HPA - see IMPLEMENTATION_PLAN.md's MongoDB decision) | A real replica set even at `members=1` (a 1-member set), required for `backend-cron`'s change-stream watching to work at all - a standalone `mongod` would silently never fire it. |

## Repository layout

```
terraform/app/       Terraform applied once PER environment
terraform/platform/  Terraform applied once, cluster-wide (MongoDB operator, observability)
docker/               Dockerfiles for cca_backend and cca_admin_frontend
kubernetes/nginx/     nginx config template for the admin-frontend ConfigMap
config/               Per-environment .tfvars
scripts/              Server-side install/ops scripts, run by CI or by hand
.github/workflows/    bootstrap-host | deploy (also repository_dispatch-triggered) | ops | platform | verify
docs/                 RUNBOOK, SECURITY, AWS_MAPPING
cca_backend/ cca_frontend/ cca_admin_frontend/   git submodules, reference only - CI always builds their `main`, never
                                                  the pinned SHA. Each also carries its own
                                                  .github/workflows/notify-cca-infra.yml (see Conventions below)
```

## Conventions

- Every commit in this repository uses git identity `brguru90@gmail.com` /
  `brguru90`, set locally (`git config --local`), not globally.
- Secrets never enter Terraform state - they're applied via `kubectl` from
  `scripts/apply-secrets.sh` before every `terraform apply`, and Terraform
  only ever references them by name.
- No changes to application source in `cca_backend`/`cca_frontend`/
  `cca_admin_frontend` without asking first. The one standing exception is
  `.github/workflows/notify-cca-infra.yml`, an identical additive CI file in
  all three (added with explicit confirmation - see
  [IMPLEMENTATION_PLAN.md §15](IMPLEMENTATION_PLAN.md#15-auto-deploy-integration-on-app-repo-push))
  that triggers `integration` auto-deploy on push to `main`. That precedent
  doesn't extend to further submodule changes.
