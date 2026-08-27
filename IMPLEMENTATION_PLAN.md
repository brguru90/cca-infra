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
13. [Post-implementation alignment check](#13-post-implementation-alignment-check)
14. [Video worker correction](#14-video-worker-correction)
15. [Auto-deploy integration on app repo push](#15-auto-deploy-integration-on-app-repo-push)

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
| Submodules | `cca_backend`, `cca_frontend`, `cca_admin_frontend` are git submodules for local reference/Dockerfile authoring. **CI never uses the pinned submodule SHA** — every build job does its own fresh checkout of each app repo's `main`. **No changes to application source in these repos without asking first** — the one standing exception is `.github/workflows/notify-cca-infra.yml`, identical in all three, added with explicit confirmation for push-triggered `integration` auto-deploy (see [§15](#15-auto-deploy-integration-on-app-repo-push)); that precedent doesn't extend to further changes. |
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
- **Does not modify application source** in `cca_backend`, `cca_frontend`, or `cca_admin_frontend` (e.g. a `go.sum` companion PR, or rotating leaked credentials) — those remain out of scope, and findings/recommendations live in `docs/SECURITY.md` instead. The one deliberate exception, made only after explicit confirmation, is a single additive CI file (`.github/workflows/notify-cca-infra.yml`) pushed to all three repos to support push-triggered auto-deploy — see [§15](#15-auto-deploy-integration-on-app-repo-push).
- Verification here is static: `terraform validate`/`fmt`, `hadolint`, `shellcheck`, YAML sanity checks — not a live deploy.

## 4. Repository layout

```
cca-infra/
├── IMPLEMENTATION_PLAN.md          ← this file
├── README.md
├── CLAUDE.md
├── initial-plan.md / final-plan.md
├── .gitmodules
├── cca_backend/  cca_frontend/  cca_admin_frontend/   ← git submodules (main branch); each also carries
│                                                          .github/workflows/notify-cca-infra.yml - see §15
├── .github/workflows/
│   ├── deploy.yml                  ← deploy | rollback | repository_dispatch(app-push) auto-deploy
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
- **`terraform/app/backend_api.tf` / `backend_cron.tf`** — same image, different `args:` (`-micro_service api_server` vs `cron_job`); Redis-wait `init_container` on both; `lifecycle { ignore_changes = [spec[0].replicas] }` on the HPA-managed Deployment so Terraform never fights the HPA or reverts a manual `scale`/`stop`. `backend_cron.tf` also holds `kubernetes_cron_job_v1.backend_video` (`enable_video_worker`-gated, off by default) — a **CronJob**, not a Deployment, since `-micro_service video_processing` is a one-shot batch job; `concurrency_policy = "Forbid"` is what actually enforces "only one instance." See [§14](#14-video-worker-correction).
- **`terraform/app/mongodb.tf`** — one `MongoDBCommunity` custom resource per namespace, `members = var.mongo_members` (default 1), explicit `connectionStringSecretName` pin so the backend's `secretKeyRef` target is stable and known.
- **`terraform/app/preflight.tf`** — `data "external"` guard checking Secret *existence* (never values) before any Deployment references them; fails `terraform plan` in seconds with a clear message instead of a multi-minute rollout timeout.
- **`terraform/app/storage.tf`** — a `local-path` PVC (`ReadWriteOnce`, safe here specifically because K3s is single-node) shared by `backend`/`backend-cron`/`backend-video` at `/web_app/uploads`, so `PROTECTED_UPLOAD_PATH`/`UNPROTECTED_UPLOAD_PATH` survive pod restarts and are visible across HPA-scaled replicas — added during the [§13](#13-post-implementation-alignment-check) alignment check, not part of the original implementation pass.
- **`scripts/apply-secrets.sh`** — validates every required env var is set, then `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -` for backend secrets and the Firebase JSON (via `/dev/shm` + `shred`, never on disk longer than needed).
- **`scripts/install-k3s.sh`** — dual-stack install flags, `--disable=traefik --disable=servicelb`, `--kube-apiserver-arg=service-node-port-range=3200-4000`, sysctls for IPv6 forwarding, kubeconfig group-readable for the runner user.
- **`.github/workflows/deploy.yml`** — triggered by `workflow_dispatch` (manual) or `repository_dispatch` (app-push, always resolves to `action=deploy, environment=integration` — see [§15](#15-auto-deploy-integration-on-app-repo-push)). `prepare` resolves `action`/`environment`/`region` once (with an `inputs.x || 'default'` fallback so both trigger types agree) plus version + per-env ports → parallel `build-backend` / `build-admin` / `build-flutter` → `deploy-terraform` (needs backend+admin only, **not** flutter — a Gradle flake shouldn't block a prod API deploy) → `record-release`. Every job reads `needs.prepare.outputs.*`, never `inputs.*` directly, since `inputs` is empty for `repository_dispatch` runs. Least-privilege permissions, environment-scoped concurrency group shared with `ops.yml`.
- **`.github/workflows/ops.yml`** — thin shim over `scripts/ops.sh` for `stop`/`restart`/`status`/`scale`; read-only permissions; same concurrency group as `deploy.yml` so ops and deploys serialize per environment.
- **`cca_backend|cca_frontend|cca_admin_frontend/.github/workflows/notify-cca-infra.yml`** — identical file in all three app repos; fires `repository_dispatch` at `cca-infra` on push to `main`, using a `CCA_INFRA_DISPATCH_TOKEN` repo secret. See [§15](#15-auto-deploy-integration-on-app-repo-push).
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

## 13. Post-implementation alignment check

After the initial implementation pass, did a line-by-line pass against `final-plan.md` to catch drift between what was designed and what actually got built. Two real findings, both resolved:

- **Fixed: the Flutter APK was never actually published as a GitHub Release.** `final-plan.md` §11 requires this; `deploy.yml`'s own header comment described a `record-release` job doing it, but the job itself didn't exist — `build-flutter` stopped at `actions/upload-artifact`. Added the job: it attaches the APK (when built) and the server-recorded `manifest.json` to the git tag `deploy-terraform` already pushes, and degrades to manifest-only when Flutter was skipped or failed.
- **Fixed: no persistent volume backed the backend's upload paths.** `PROTECTED_UPLOAD_PATH`/`UNPROTECTED_UPLOAD_PATH` wrote to the container's ephemeral layer — lost on restart, invisible across HPA-scaled replicas. Neither plan doc solved this in detail either (both deferred GCS integration), but the minimal fix — a `local-path` PVC, safe as `ReadWriteOnce` on this single-node cluster — was cheap enough to just do. See `terraform/app/storage.tf`.

Everything else checked out as either aligned or an already-documented, session-approved deviation from the plan docs' literal text — listed here so "aligned" doesn't need re-litigating later:

| final-plan.md said | This repo does | Why |
|---|---|---|
| NodePorts `8701`/`8702`/`8703` for backend, range `3200-8799` | Backend `3211`/`3311`/`3411`, range narrowed to `3200-4000` | The wider range swallows K3s's apiserver port `6443` and flannel's `8472` — see [§3 decisions table](#3-decisions-locked-in). |
| Kubernetes Secrets managed directly by Terraform (§30's `kubernetes_secret` example) | Secrets applied via plain `kubectl` in `scripts/apply-secrets.sh`, referenced by name only | Keeps plaintext values out of `terraform.tfstate`. |
| MongoDB/Redis left as external dependencies (inherited from `initial-plan.md` §59) | Both deployed in-cluster (Redis per namespace, MongoDB via the Community Operator) | Reading the actual backend source showed both are hard boot-time dependencies (Redis panics, Mongo change streams need a replica set) — easier to guarantee in-cluster than to depend on external services staying up. |
| A single flat `terraform/` root | Split into `terraform/app` (per environment) and `terraform/platform` (cluster-wide, installs the Mongo operator + observability stack once) | Namespaced state per environment, and a clean place for the one-time cluster-wide installs `terraform/app` depends on. |
| Version as a log label (§25, §31) | `cca_version` deliberately excluded from Loki's stream labels | Would mint a new log stream on every deploy and fragment the index — exposed as structured metadata instead. |
| GitHub-hosted runner + SSH over IPv6 (§16-18's "Case B") | Self-hosted runner only, no SSH path at all | Matches the plan's own stated preference ("Case A") once a working runner was confirmed to exist — never built the SSH fallback. |

## 14. Video worker correction

The original implementation pass added an `enable_video_worker`-gated Kubernetes **Deployment** running `-micro_service video_processing`, off by default. This was wrong, caught in two steps:

1. **Reading `src/app_cron_jobs/video_stream_generation.go` and `src/app_cron_jobs/init_cron_jobs.go` directly** showed `-micro_service video_processing` isn't designed to run as a long-lived server at all — `main.go`'s switch-case calls `VideoStreamGeneration(true)` once and returns, exiting the process after the queue drains. As a Deployment it would just crash-loop. The real trigger path is `InitCronJobs()` (running in `backend-cron`) scheduling `VideoStreamGenerationCron` every minute, which — in anything but `APP_ENV=development` — calls `my_modules.StartVMInstance()` to boot a **dedicated, hardcoded Google Compute Engine VM** and run the encoding there. The first fix was simply to delete the Deployment and the variable, on the assumption GCE was the intended production path.
2. **The user corrected that assumption**: this deployment has no GCE VM — everything runs on the home server, as a container, like everything else. Forcing `APP_ENV=development` to dodge the GCE branch was considered and rejected: `APP_ENV` also gates CSRF enforcement in `LoginStatus` (`src/my_modules/authentication.go`) and the logger level — flipping it would silently weaken production auth.

**Resolution, with no submodule changes**: `VideoStreamGeneration()` (the actual encoding function) has no GCE code at all — only the separate `VideoStreamGenerationCron()` does. Calling `-micro_service video_processing` directly, on a schedule, bypasses that function entirely and does real local ffmpeg encoding regardless of `APP_ENV`. Re-added as `terraform/app/backend_cron.tf`'s `kubernetes_cron_job_v1.backend_video`: a CronJob (not a Deployment — it's genuinely a one-shot batch job) with `concurrency_policy = "Forbid"`, which is what actually satisfies "only one instance of video_processing" — Kubernetes skips a new run if the previous one is still going, rather than stacking overlapping ffmpeg encodes (each already spawns `runtime.NumCPU()*4` threads). Gated behind `enable_video_worker` (default `false`) since ffmpeg encoding is heavy for a single shared home server; `video_worker_schedule` controls the cron cadence (default every 5 minutes).

One accepted side effect, left as-is: `backend-cron`'s own `VideoStreamGenerationCron` tick still runs every minute regardless (hardcoded in `InitCronJobs()`), and will occasionally still attempt `StartVMInstance()` in production if it observes a queued-but-unstarted video before the CronJob claims it. Verified this fails harmlessly — `compute.NewInstancesRESTClient` errors cleanly with no GCP credentials configured, wrapped and logged, never fatal (`src/my_modules/google_cloud.go`) — so it's occasional log noise, not a functional problem. Suppressing it would require a submodule code change (a new env-gated flag to skip the GCE branch entirely), which hasn't been proposed/confirmed — flagging it here rather than doing it silently.

`backend-cron` remains the only true singleton *server* process (real replica-set/change-stream state); `backend-video` is a singleton-by-`concurrency_policy` batch job; `backend` (api_server) remains the only HPA-scaled, multi-replica workload.

## 15. Auto-deploy integration on app repo push

Requirement: merging to `main` in `cca_backend`/`cca_frontend`/`cca_admin_frontend` should automatically deploy `integration`; `uat`/`production` stay manually triggered from the Actions tab, unchanged.

GitHub Actions has no native way for a workflow in `cca-infra` to react to a push in a *different* repository. The standard fix is push-triggered: a small workflow in each app repo fires a `repository_dispatch` event against `cca-infra` on push to `main`. An initial pass avoided this with a polling design specifically to keep the three app repos untouched (see git history) — the user then explicitly asked for push-triggered instead, which is exactly the confirmation needed to edit those repos, so this section describes what's actually implemented now.

**In each of `cca_backend`/`cca_frontend`/`cca_admin_frontend`** (identical file, copy-pasted, differs only by which repo it lives in): `.github/workflows/notify-cca-infra.yml`, triggered on `push: branches: [main]`, calls:

```bash
gh api repos/brguru90/cca-infra/dispatches \
  -f event_type=app-push \
  -f "client_payload[repo]=${{ github.event.repository.name }}" \
  -f "client_payload[sha]=${{ github.sha }}"
```

This needs a **`CCA_INFRA_DISPATCH_TOKEN` repository secret in each of the three app repos** — a Personal Access Token with permission to trigger `repository_dispatch` on `brguru90/cca-infra`. The default `GITHUB_TOKEN` can't be used: it has no access outside the repo the workflow runs in. GitHub's docs confirm a classic PAT needs the `repo` scope for this endpoint; a fine-grained PAT scoped to just `cca-infra` with "Contents: Read and write" is the tighter equivalent (not spelled out as explicitly in GitHub's docs for this specific endpoint, but consistent with its general permission model — verify by testing). See `docs/RUNBOOK.md` for the exact setup steps. Until the secret is set, the workflow fails loudly with a clear error rather than silently doing nothing.

**In `cca-infra`**: `deploy.yml`'s `on:` gained `repository_dispatch: types: [app-push]` alongside `workflow_dispatch`. The whole file previously read `inputs.action`/`inputs.environment`/`inputs.region` directly in nearly every job — but `inputs.*` is only populated for `workflow_dispatch` runs, so every job now reads `needs.prepare.outputs.action`/`.environment`/`.region` instead. `prepare` resolves these once, with a fallback pattern (`inputs.action || 'deploy'`, `inputs.environment || 'integration'`, `inputs.region || 'asia-india'`) that makes a `repository_dispatch` run resolve to exactly the same values as a manual `action=deploy, environment=integration, region=asia-india` run — including the top-level `concurrency.group` expression, which can't reference job outputs (evaluated before any job runs) and uses the same `||` fallback directly. This is also why `repository_dispatch` and a manual `integration` deploy correctly serialize against each other instead of racing: they resolve to the identical concurrency group string.

`action=rollback` is only ever reachable via `workflow_dispatch` — a `repository_dispatch` run always resolves `action=deploy`, so the rollback branch of `prepare`'s resolve script is simply never exercised by an app-repo push.

The earlier polling workflow (`watch-app-repos.yml`) was deleted, not kept as a fallback — running both would risk duplicate/racing dispatches for the same push.

Accepted trade-offs, now much smaller than the polling design's:
- **A GitHub Actions run per app-repo push, even for pushes that don't need a redeploy** (e.g. a docs-only commit) — `notify-cca-infra.yml` doesn't inspect what changed, only that `main` moved. Acceptable for a home-lab integration environment; a path filter (`on.push.paths-ignore`) could be added later if this becomes noisy.
- **The PAT is a standing secret in three separate repos** — if `cca-infra` is ever made private, or its dispatch-triggering surface needs tightening, all three copies need rotating together. Documented in `docs/SECURITY.md` alongside this repo's other credential-adjacent notes.
