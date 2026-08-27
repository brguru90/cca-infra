# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is `cca-infra`: Terraform + Kubernetes (K3s) deployment infrastructure for a personal travel-planner app ("cca"), split across `cca_backend` (Go/Gin API), `cca_frontend` (Flutter, built to an APK only), and `cca_admin_frontend` (React admin UI) — all three vendored here as **git submodules**, mainly for local reference (CI never builds from the pinned submodule SHA; every workflow job checks out each app repo's `main` fresh). Each also carries one real, functional file of its own — `.github/workflows/notify-cca-infra.yml` — see "Conventions" below before assuming they're read-only. See [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for the full design and the ground-truth findings (from reading the actual app source) that reshaped it, and [README.md](README.md) for a reader's-guide to the rest of the docs.

- `main` holds only the original planning transcripts (`initial-plan.md`, `final-plan.md` — the latter supersedes the former) plus this file and the README.
- `initial_implementation` holds the actual infrastructure code described below.

## Commands

There's no application build here — this repo *produces* Terraform/Docker/CI config for other repos. The checks that exist:

```bash
# Terraform (run per root: terraform/app, terraform/platform)
terraform -chdir=terraform/app fmt -check -recursive
terraform -chdir=terraform/app init -backend=false   # validate doesn't need a real backend/cluster
terraform -chdir=terraform/app validate

# Dockerfiles
hadolint docker/backend/Dockerfile docker/admin-frontend/Dockerfile

# Shell scripts
shellcheck scripts/*.sh

# GitHub Actions workflows
actionlint .github/workflows/*.yml
```

All four are also wired into `.github/workflows/verify.yml` on pull requests. None of this requires a live cluster — that only exists on the actual home server, which nothing in this repo has direct access to (see "Deployment reality" below).

To smoke-test a script's logic without a real cluster/server, stub `kubectl`/`curl`/`terraform` as executables earlier on `$PATH` and override the env vars scripts read for their target directories (e.g. `RELEASES_DIR` for `scripts/health-check.sh`). `scripts/install-k3s.sh` and `scripts/bootstrap-server.sh` are Ubuntu-server-only and aren't meant to be run or stubbed locally.

## Architecture

**Two Terraform roots, not one.** `terraform/app/` is applied once *per environment* (`integration`/`uat`/`production`), each with independent local state (`/srv/cca/state/<env>/terraform.tfstate`) and its own Kubernetes namespace (`cca-<env>`). `terraform/platform/` is applied once, cluster-wide, before any `terraform/app` environment's first apply — it installs the MongoDB Community Operator (whose CRD `terraform/app/mongodb.tf`'s `kubernetes_manifest` resource depends on existing) and the Loki/Alloy/Grafana observability stack.

**Namespace ownership is split between `kubectl` and Terraform on purpose.** `scripts/apply-secrets.sh` creates each namespace (idempotently, via plain `kubectl apply`) *before* `terraform apply` ever runs, because it needs somewhere to put Secrets first. `terraform/app/namespace.tf` therefore reads the namespace as `data`, not a `resource` — a Terraform-owned resource would 409 on every environment's first apply since the namespace already exists by then. Don't "fix" this back to a resource.

**Secrets never enter Terraform state.** `scripts/apply-secrets.sh` (sourced from GitHub Environment Secrets) applies every Kubernetes Secret via plain `kubectl` before Terraform runs. Terraform only ever references them by name (`envFrom`/`secretKeyRef`), never via a `data "kubernetes_secret_v1"` (which would read plaintext values into state). `terraform/app/preflight.tf`'s `data "external"` guard checks Secret *existence only* (via `scripts/secret-guard.sh`) and fails `plan` in seconds with a clear message if they're missing, instead of every Deployment timing out in `CreateContainerConfigError` minutes later.

**The backend image plays three roles via `args:`, not three images.** `docker/backend/Dockerfile` ships no hardcoded `-micro_service` flag; `terraform/app/backend_api.tf` (`api_server`), `backend_cron.tf` (`cron_job`, no Service/HTTP probes — it has no HTTP listener), and the optional video worker all use the same image with different container `args`. The backend hard-panics on boot if Redis is unreachable (in *every* mode) or if the Firebase service-account JSON is missing — both get an `initContainer` wait-loop and a Secret volume mount respectively, on every Deployment that uses this image.

**HPA, not Terraform, owns replica count after creation.** Every HPA-scaled `kubernetes_deployment_v1` has `lifecycle { ignore_changes = [spec[0].replicas] }`. Without it, every `terraform apply` would read the HPA's live replica count as drift and scale back down — fighting the autoscaler on every single deploy, and reverting anything `scripts/ops.sh scale`/`stop` did.

**The deployment circuit breaker lives in `scripts/health-check.sh`, not just in CI.** On a failed post-apply health check, it automatically re-applies Terraform with the last known-good version recorded in `/srv/cca/releases/<env>.previous`, re-verifies, and *still exits non-zero* either way — a tripped breaker is a failed deploy even though it healed itself. `.github/workflows/deploy.yml` owns the `.current` → `.previous` rotation *before* every apply; `health-check.sh` only ever writes `.current` (to the new version on success, or back to the previous version if it had to roll back).

**One admin-frontend image serves all three environments.** `cca_admin_frontend` has no build-time API URL variable anywhere in its source — every API call is a same-origin relative path. The only environment-specific piece is nginx's reverse-proxy target, shipped as a Kubernetes ConfigMap (`kubernetes/nginx/admin-default.conf.tpl`, rendered by `terraform/app/configmap_nginx.tf`) mounted at deploy time, not baked into the image. That template also carries the nginx-upstream circuit breaker (`max_fails`/`fail_timeout`) in front of the backend.

**MongoDB scaling is a Terraform variable, not an HPA.** The MongoDB Community Operator's CRD exposes no `/scale` subresource, so `mongo_members` (`terraform/app/variables.tf`) is bumped manually and deliberately — see IMPLEMENTATION_PLAN.md for why reactive autoscaling of a quorum-based store was rejected outright rather than left as a TODO.

**Third-party GitHub Actions are pinned to commit SHAs and kept to a minimum**, deliberately more paranoid than a typical repo: the self-hosted runner they execute on holds a cluster-admin kubeconfig and the Docker socket.

## Deployment reality

This repository was built without shell/SSH access to the actual home server. `docs/RUNBOOK.md` is the execution path for a human (or a future agent) with real server access; nothing here has been applied to a live cluster. If you're asked to "deploy" or "apply" something from a session like this one, that almost certainly means: write/update the Terraform or workflow code, run the static checks above, and stop there — not attempt to reach the actual server.

## Conventions

- Git identity for every commit in this repo: `brguru90@gmail.com` / `brguru90`, set via `git config --local` (not global).
- `cca_backend`, `cca_frontend`, `cca_admin_frontend` source findings that inform this repo's design are documented in IMPLEMENTATION_PLAN.md and `docs/SECURITY.md` — this repo does not modify application source in those three repos. The one exception is `.github/workflows/notify-cca-infra.yml`, an identical additive CI file pushed to all three (with explicit confirmation) to support push-triggered `integration` auto-deploy — see IMPLEMENTATION_PLAN.md §15. Don't treat that as license to make further submodule changes without asking first.
