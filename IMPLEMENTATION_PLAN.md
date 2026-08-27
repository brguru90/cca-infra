# cca-infra Implementation Plan

Branch: `initial_implementation`. This document is the working plan for turning `final-plan.md` (see [final-plan.md](final-plan.md), which supersedes [initial-plan.md](initial-plan.md)) into an actual repository: Terraform, Dockerfiles, GitHub Actions workflows, operational scripts, and docs for deploying `cca_backend`, `cca_frontend`, and `cca_admin_frontend` to a home-lab K3s cluster.

It exists so the *why* behind each file is legible without re-reading both planning documents in full. Update it as decisions change — it's a living plan, not a historical record.

## Table of contents

1. [Ground-truth findings that changed the plan](#1-ground-truth-findings-that-changed-the-plan)
2. [Decisions locked in](#2-decisions-locked-in)
3. [Scope & boundary](#3-scope--boundary)
4. [Repository layout](#4-repository-layout)
5. [Implementation order](#5-implementation-order)
6. [Critical files — what goes in each](#6-critical-files--what-goes-in-each)
7. [Port / networking table](#7-port--networking-table)
8. [Secrets inventory](#8-secrets-inventory)
9. [Circuit breakers](#9-circuit-breakers)
10. [Git commit identity](#10-git-commit-identity)
11. [Verification plan](#11-verification-plan)
12. [Explicitly deferred](#12-explicitly-deferred)

---

## 1. Ground-truth findings that changed the plan

Both planning documents were written before anyone read the actual application source. Reading `cca_backend`, `cca_frontend`, and `cca_admin_frontend` directly off GitHub surfaced facts that reshape the Terraform, Dockerfiles, and CI design below.

**`cca_backend` (Go 1.18, Gin):**
- One binary, one flag: `-micro_service {api_server|cron_job|video_processing|all}`. The repo's *current* Dockerfile hardcodes `cron_job` in its ENTRYPOINT — today's image runs the worker, not the API. Our image must leave the role to the Kubernetes `args:` override instead.
- `SERVER_PORT` has no code default — unset means the server binds `:0`. It's effectively mandatory in the ConfigMap.
- Health endpoint exists: `GET /api/health_check` → bare 200. It sits behind a User-Agent–checking middleware; kubelet's `kube-probe/*` UA satisfies it, but every probe/curl pins an explicit `User-Agent` header anyway rather than depending on that.
- **Redis is a hard `log.Panic` on boot failure** — in every mode, even with caching disabled, with no auth support. Probe tuning can't help a slow Redis; the process is already dead by the time a liveness probe would fire. Gate with an initContainer wait-loop instead.
- **Firebase is a hard panic** unless a service-account JSON exists at the WORKDIR-relative path `./env/cca-vijayapura-firebase-adminsdk-ghz2d-1f8e7ad071.json`.
- MongoDB degrades gracefully (only logs on failure) — the opposite risk profile from Redis/Firebase.
- `go.sum` is gitignored upstream, so the Docker build has no reproducible lockfile today.
- Needs `ffmpeg`/`ffprobe`, and `curl` for probes/debugging, in the runtime image.
- **Real secrets are committed today**: DB credentials, JWT secret, Redis address, Razorpay keys in the Dockerfile/`.env` files, plus a live Firebase service-account private key file. None of this is carried into `cca-infra` — real values come from GitHub Environment Secrets. See [docs/SECURITY.md](docs/SECURITY.md) once written.

**`cca_admin_frontend` (React, CRA 4.0.3, yarn only):**
- **No build-time API URL variable exists anywhere in the source.** Every API call is a same-origin relative path (`/api/...`). This means **one image serves all three environments** — the environment-specific piece is nginx's reverse-proxy target, shipped as a Kubernetes ConfigMap mounted at deploy time, not baked into the image.
- Must use `yarn install --frozen-lockfile` (no `package-lock.json` exists — `npm ci` fails) and `CI=false` (CRA4 treats lint warnings as hard errors under `CI=true`).
- Uses `HashRouter` — SPA history-fallback isn't strictly required, harmless to include anyway.

**`cca_frontend` (Flutter):**
- Dart SDK constraint `>=2.16.1 <3.0.0` confirms the plan docs: pin **Flutter 3.7.12**, not latest.
- **Domain change**: the repo's `env-prod.json` points at `ccavijayapura.com`, which is dead. CI overrides this to `http://travel-planner.ddns.net` (per-environment port). Documented explicitly here, not silently patched into the app repo.
- **Load-bearing correction**: on Flutter 3.7.12, CLI `--dart-define` does **not** override a same-named key already set via `--dart-define-from-file` (the override-order fix shipped in Flutter 3.13 — see flutter/flutter#130604 / #131088). Appending `--dart-define=SERVER_HOST=...` after `--dart-define-from-file=env-prod.json` silently loses, shipping an APK pointed at the dead domain while CI stays green. Fix: CI composes a merged `env-ci.json` (via `jq`) with overrides already applied, and builds with only `--dart-define-from-file=env-ci.json`.
- The release keystore and its passwords (`key.properties`, `keystore.jks`) are committed in the repo — `flutter build apk --release` "works" today with a compromised signing key.

## 2. Decisions locked in

| Area | Decision |
|---|---|
| Runner | Self-hosted GitHub Actions runner **on** the home server. No inbound SSH; outbound-only connection to GitHub. A separate IPv6 reachability check still runs to satisfy the original public-IPv6 requirement. |
| Submodules | `cca_backend`, `cca_frontend`, `cca_admin_frontend` are git submodules for local reference/Dockerfile authoring. **CI never uses the pinned submodule SHA** — every build job does its own fresh checkout of each app repo's `main`. |
| Implementation scope | Full scaffolding in one branch: K3s bootstrap scripts, complete Terraform (namespaces/Deployments/Services/HPA/Mongo/Redis/secret-integration), Dockerfiles, full `deploy.yml`/`ops.yml` (deploy/rollback/stop/restart/status/scale), Loki+Alloy+Grafana, docs. Nothing is applied to a live server from this repo alone — see [§3](#3-scope--boundary). |
| Redis | In-cluster, one Deployment+Service per namespace, no auth (matches the app's hardcoded empty-password client), gated by an initContainer wait-loop before backend/worker containers start. |
| MongoDB | **MongoDB Community Operator**, one `MongoDBCommunity` custom resource per environment, `spec.members` driven by a per-env Terraform variable (default `1`). A real replica set (change-stream-dependent `cron_job` mode works) that's "dynamically scalable" by editing one variable — **not** HPA/load-triggered. The operator's CRD exposes only a `status` subresource, not `scale`, so an HPA cannot target it directly; auto-scaling a quorum-based store on load is also a real risk (each new member does a full initial sync; even member counts are a worse voting topology than odd), so true autoscaling is deliberately not attempted. |
| Secrets | Applied via `kubectl` from `scripts/apply-secrets.sh` **before** `terraform apply`, sourced from GitHub Environment Secrets. Terraform only references Secrets by name (`envFrom`/`secretKeyRef`) and never reads their values — not even via a `data` source — so no plaintext secret lands in `terraform.tfstate`. The one near-exception, `MONGO_CUSTOM_URL`, is solved by pinning the operator's generated Secret name and referencing it with `secretKeyRef` directly; Terraform never touches its value. |
| IPv6 | Dual-stack K3s at install time (`--cluster-cidr=...,fd00:42::/56 --service-cidr=...,fd00:43::/112 --flannel-ipv6-masq`), plus `ip_family_policy = RequireDualStack` on every NodePort Service. Chosen over a host-level forwarder because IPv6→IPv4 NAT isn't a native nftables DNAT operation (would need per-port `socat` units) — dual-stack is fewer moving parts and the better learning outcome. |
| NodePort range | **`3200-4000`** only (not the full `3200-8799` originally requested) — the wider range swallows K3s's own apiserver port `6443` and flannel's VXLAN `8472`; an unpinned Service could be handed one of those and break the cluster. Backend renumbered to `3211`/`3311`/`3411` (int/uat/prod); admin frontend keeps `3202`/`3302`/`3402`; Grafana gets `3900`. Every Service pins its `nodePort` explicitly. |
| APK signing | Workflow writes a fresh keystore from `ANDROID_KEYSTORE_BASE64`/`ANDROID_KEY_PROPERTIES` GitHub Secrets when present, overwriting the checked-out (compromised) ones; if unset, it builds with the repo's own key and emits a loud `::warning::` annotation. |
| Domain | All new configuration (Flutter env override, docs, health-check scripts) uses `http://travel-planner.ddns.net`; `ccavijayapura.com` is called out as dead in `docs/SECURITY.md`, not left in any generated config. |

## 3. Scope & boundary

This implementation was produced without shell/SSH access to the actual home server. It therefore:
- **Produces and commits** the complete `cca-infra` repository content (Terraform, Dockerfiles, GitHub Actions workflows, install/ops scripts, K8s-adjacent config, docs) on `initial_implementation`.
- **Does not run** `terraform apply`, `install-k3s.sh`, or anything against a live cluster. The scripts are written to be run *by the server owner, on the server*; [docs/RUNBOOK.md](docs/RUNBOOK.md) documents exactly how.
- **Does not modify** `cca_backend`, `cca_frontend`, or `cca_admin_frontend` (e.g. a `go.sum` companion PR, or rotating leaked credentials) — those are separate repos. Findings and recommendations live in `docs/SECURITY.md` instead.
- Verification here is static: `terraform validate`/`fmt`, `hadolint`, `shellcheck`, YAML sanity checks — not a live deploy.

## 4. Repository layout

```
cca-infra/
├── IMPLEMENTATION_PLAN.md          ← this file
├── README.md
├── CLAUDE.md
├── initial-plan.md / final-plan.md
├── .gitmodules
├── cca_backend/  cca_frontend/  cca_admin_frontend/   ← git submodules (main branch)
├── .github/workflows/
│   ├── deploy.yml                  ← deploy | rollback
│   ├── ops.yml                     ← stop | restart | status | scale
│   ├── platform.yml                ← one-shot: metrics-server check, Mongo operator, Loki/Alloy/Grafana
│   └── verify.yml                  ← PR checks: terraform validate/fmt, hadolint, actionlint
├── docker/
│   ├── backend/Dockerfile
│   └── admin-frontend/Dockerfile
├── kubernetes/nginx/admin-default.conf.tpl
├── terraform/
│   ├── app/            ← applied once per environment, own local state
│   └── platform/       ← applied once, cluster-wide
├── config/
│   ├── integration.tfvars  uat.tfvars  production.tfvars
├── scripts/
│   ├── install-k3s.sh        bootstrap-server.sh
│   ├── apply-secrets.sh      secret-guard.sh
│   ├── backup-state.sh       health-check.sh
│   ├── ops.sh                load-test.sh
└── docs/
    ├── RUNBOOK.md
    ├── SECURITY.md
    └── AWS_MAPPING.md
```

## 5. Implementation order

1. Create branch `initial_implementation`; add the three submodules. ✅
2. Write this plan and commit it alone, before any code. ✅
3. `docker/` Dockerfiles for backend and admin-frontend.
4. `terraform/app` (namespaces, Redis, Mongo CR, backend API/cron Deployments+Services, admin Deployment+Service, HPA, nginx ConfigMap, secret-presence preflight).
5. `terraform/platform` (Mongo Community Operator install, Loki+Alloy+Grafana via Helm provider).
6. `config/*.tfvars` per environment.
7. `scripts/` (install/bootstrap/secrets/backup/health/ops/load-test).
8. `.github/workflows/` (deploy, ops, platform, verify).
9. `kubernetes/nginx/admin-default.conf.tpl`.
10. `docs/` (RUNBOOK, SECURITY, AWS_MAPPING) and `README.md`/`CLAUDE.md` updates.
11. Static verification, fix findings, commit, push branch.

## 6. Critical files — what goes in each

- **`docker/backend/Dockerfile`** — multi-stage `golang:1.19-alpine` builder (falls back to `go mod tidy` since `go.sum` is absent upstream — see [§12](#12-explicitly-deferred)) → `alpine:3.20` runtime with `ffmpeg`+`curl`, non-root user, `mkdir -p ./frontend/build` so Gin's static handling doesn't error, `ENTRYPOINT ["/web_app/server"]` with **no hardcoded `-micro_service`** so Kubernetes `args:` controls the API-vs-worker role, Firebase Secret mounted via `subPath` so it doesn't shadow the rest of `./env`.
- **`docker/admin-frontend/Dockerfile`** — `node:16-alpine` builder (`yarn install --frozen-lockfile`, `CI=false`, `GENERATE_SOURCEMAP=false`) → `nginx:1.27-alpine` runtime that ships **no** default server block (the real one is a ConfigMap mounted at deploy time) — an intentional fail-loud choice for standalone `docker run` testing.
- **`terraform/app/backend_api.tf` / `backend_cron.tf`** — same image, different `args:` (`-micro_service api_server` vs `cron_job`); Redis-wait `init_container` on both; `lifecycle { ignore_changes = [spec[0].replicas] }` on the HPA-managed Deployment so Terraform never fights the HPA or reverts a manual `scale`/`stop`.
- **`terraform/app/mongodb.tf`** — one `MongoDBCommunity` custom resource per namespace, `members = var.mongo_members` (default 1), explicit `connectionStringSecretName` pin so the backend's `secretKeyRef` target is stable and known.
- **`terraform/app/preflight.tf`** — `data "external"` guard checking Secret *existence* (never values) before any Deployment references them; fails `terraform plan` in seconds with a clear message instead of a multi-minute rollout timeout.
- **`scripts/apply-secrets.sh`** — validates every required env var is set, then `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -` for backend secrets and the Firebase JSON (via `/dev/shm` + `shred`, never on disk longer than needed).
- **`scripts/install-k3s.sh`** — dual-stack install flags, `--disable=traefik --disable=servicelb`, `--kube-apiserver-arg=service-node-port-range=3200-4000`, sysctls for IPv6 forwarding, kubeconfig group-readable for the runner user.
- **`.github/workflows/deploy.yml`** — `prepare` (compute version + per-env ports) → parallel `build-backend` / `build-admin` / `build-flutter` → `deploy-terraform` (needs backend+admin only, **not** flutter — a Gradle flake shouldn't block a prod API deploy) → `post-verify`/`record-release`. Least-privilege permissions, environment-scoped concurrency group shared with `ops.yml`.
- **`.github/workflows/ops.yml`** — thin shim over `scripts/ops.sh` for `stop`/`restart`/`status`/`scale`; read-only permissions; same concurrency group as `deploy.yml` so ops and deploys serialize per environment.
- **`docs/SECURITY.md`** — documents (without reproducing secret values) every credential found committed in the three app repos and the compromised Flutter keystore; rotation is the app owner's action, out of scope for this branch.
- **`kubernetes/nginx/admin-default.conf.tpl`** — includes the `upstream backend_upstream { server backend:8700 max_fails=3 fail_timeout=10s; }` circuit breaker ([§9.1](#9-circuit-breakers)).
- **`scripts/health-check.sh`** — trips the deployment circuit breaker: on health-check failure, triggers an automatic `terraform apply` back to the recorded previous version instead of leaving a broken deploy live ([§9.2](#9-circuit-breakers)).

## 7. Port / networking table

| Environment | Namespace | Backend NodePort | Backend containerPort | Admin NodePort |
|---|---|---|---|---|
| integration | `cca-integration` | 3211 | 8700 | 3202 |
| uat | `cca-uat` | 3311 | 8700 | 3302 |
| production | `cca-production` | 3411 | 8700 | 3402 |

Grafana (platform, `cca-monitoring`): NodePort `3900`. K3s `service-node-port-range=3200-4000`. All Services pin `nodePort` explicitly; `ip_family_policy = RequireDualStack` for IPv6 reachability.

## 8. Secrets inventory

**Repo-level (shared):** `GHCR_PAT` (fallback only — `GITHUB_TOKEN` covers the common case), `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEY_PROPERTIES`.

**Per GitHub Environment** (`integration`/`uat`/`production`, same names, different values): `JWT_SECRET_KEY`, `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `FIREBASE_SERVICE_ACCOUNT_JSON`, `MONGO_ADMIN_PASSWORD`. Production only: `GRAFANA_ADMIN_PASSWORD`, plus a required-reviewer approval gate.

Deliberately absent: `MONGO_CUSTOM_URL` (operator-generated, never leaves the cluster), any Redis credential (none exists in the app), any admin-frontend build secret (none exists), `SSH_PRIVATE_KEY` (no inbound SSH in this design).

## 9. Circuit breakers

App-level circuit breakers (around the backend's Mongo/Redis/Firebase/Razorpay calls) would mean editing `cca_backend` source, which is out of scope. Two circuit breakers genuinely belong at the infra layer this repo owns:

1. **nginx upstream circuit breaker (admin-frontend → backend proxy).** The admin ConfigMap's `location /api/` block is an `upstream` with `max_fails=3 fail_timeout=10s` and `proxy_next_upstream error timeout http_502 http_503 http_504;`. If the backend starts failing, nginx stops hammering it for a 10s cooldown window and fails fast instead — implemented entirely in `kubernetes/nginx/admin-default.conf.tpl`.
2. **Deployment circuit breaker (automatic rollback on failed health check).** `scripts/health-check.sh` trips: if the freshly-deployed version fails its post-apply health check, the workflow automatically re-applies Terraform with the previous version recorded in `/srv/cca/releases/<env>.current` (moved to `.previous` before each deploy), instead of leaving a broken version live. This is `initial-plan.md`'s §53 "automatic rollback" made concrete.

## 10. Git commit identity

Every commit in this repository uses the email **`brguru90@gmail.com`**, set via `git config --local user.email`/`user.name` in the clone (not global), so it doesn't affect other projects on the same machine. Anyone (human or agent) working in this repo should set the same local config before committing.

## 11. Verification plan

Since there's no reachable cluster from a plain repo checkout:
1. `terraform -chdir=terraform/app fmt -check` / `validate`, same for `terraform/platform` (both need example `.tfvars` to validate against).
2. `hadolint docker/backend/Dockerfile docker/admin-frontend/Dockerfile`.
3. `actionlint` (or manual YAML review) over `.github/workflows/*.yml`.
4. `shellcheck scripts/*.sh`.
5. Manual cross-check: every port in [§7](#7-port--networking-table) appears consistently across Terraform, workflows, and docs; every secret in [§8](#8-secrets-inventory) appears consistently across `apply-secrets.sh`, workflow `env:` blocks, and `docs/RUNBOOK.md`'s secrets checklist.
6. `docs/RUNBOOK.md` documents the exact commands to go from zero to a working `integration` deploy on the actual home server — the real end-to-end verification, run by the server owner.

## 12. Explicitly deferred

- Opening a PR to `cca_backend` to commit `go.sum` (would make backend builds reproducible; the Dockerfile currently falls back to `go mod tidy` at build time).
- Rotating the credentials hardcoded in `cca_backend` and `cca_admin_frontend`, and replacing the compromised Flutter keystore — documented in `docs/SECURITY.md`, none of it actioned.
- Actually running `install-k3s.sh` / `terraform apply` on the physical server.
