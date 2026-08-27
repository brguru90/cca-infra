# Runbook

Step-by-step path from a bare Ubuntu 24 home server to a working `integration`
deploy, plus day-2 operations. Everything in this file is meant to be run by
a human (or a future agent with actual server access) on the real hardware -
none of it has been executed against real infrastructure from this
repository's `initial_implementation` branch; see IMPLEMENTATION_PLAN.md §3.

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [One-time server setup](#2-one-time-server-setup)
3. [Self-hosted runner](#3-self-hosted-runner)
4. [GitHub Environments and secrets](#4-github-environments-and-secrets)
5. [First-time platform apply](#5-first-time-platform-apply)
6. [First deploy to an environment](#6-first-deploy-to-an-environment)
7. [Day-2 operations](#7-day-2-operations)
8. [Rollback](#8-rollback)
9. [Demonstrating autoscaling](#9-demonstrating-autoscaling)
10. [Troubleshooting](#10-troubleshooting)
11. [Enabling video processing](#11-enabling-video-processing)

## 1. Prerequisites

- Ubuntu 24 with Docker already installed (used only by the runner's build
  steps, not by the applications themselves - see IMPLEMENTATION_PLAN.md).
- Public IPv6 connectivity, with `travel-planner.ddns.net`'s DDNS updater
  configured to publish an **AAAA** record for this machine (an A record too,
  if you want IPv4 reachability as well - the cluster is dual-stack either
  way).
- `terraform`, `kubectl`, `helm`, `jq`, `curl` installed on the host (verified
  by `scripts/bootstrap-server.sh`).

## 2. One-time server setup

```bash
sudo ./scripts/install-k3s.sh
sudo RUNNER_USER=<the user the GitHub Actions runner will run as> ./scripts/bootstrap-server.sh
```

`install-k3s.sh` installs a dual-stack K3s with Traefik/ServiceLB disabled
and the NodePort range narrowed to `3200-4000` (see IMPLEMENTATION_PLAN.md's
NodePort decision for why the full `3200-8799` originally requested isn't
used). `bootstrap-server.sh` creates `/srv/cca/...` and the `cca` group that
gives the runner read access to `/etc/rancher/k3s/k3s.yaml`.

**Log the runner user out and back in (or reboot)** after this so the new
group membership takes effect.

## 3. Self-hosted runner

In `brguru90/cca-infra` on GitHub: **Settings → Actions → Runners → New
self-hosted runner**, follow the instructions for Linux x64, and install it
as a service so it survives reboots. No inbound firewall changes are needed
for this - the runner only makes outbound connections to GitHub.

## 4. GitHub Environments and secrets

Create four GitHub Environments: `integration`, `uat`, `production`,
`platform`. Add **required reviewers** to `production` (and, ideally, to
`uat`) - both `deploy.yml` and `ops.yml` gate on the target environment, so
this also protects `stop`/`restart`/`scale` against production, not just
deploys.

Per environment (`integration`/`uat`/`production`), add these secrets (see
IMPLEMENTATION_PLAN.md §8 for the full rationale):

| Secret | Notes |
|---|---|
| `JWT_SECRET_KEY` | new value - do not reuse the one committed in `cca_backend`'s Dockerfile |
| `RAZORPAY_KEY_ID` / `RAZORPAY_KEY_SECRET` | from your Razorpay dashboard |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | the full JSON content of a service-account key, not a file path |
| `MONGO_ADMIN_PASSWORD` | password for the `cca_backend` MongoDB user this project creates - a new password, your choice |

On the `platform` environment, add `GRAFANA_ADMIN_PASSWORD`.

Repository-level secrets (not environment-scoped): `ANDROID_KEYSTORE_BASE64`
(a release keystore, base64-encoded) and `ANDROID_KEY_PROPERTIES` (the
contents of an Android `key.properties` file) - see docs/SECURITY.md before
skipping these; without them, the Flutter build uses the keystore already
committed in `cca_frontend`, which is public.

## 5. First-time platform apply

Run the **CCA Platform** workflow (`workflow_dispatch`, no inputs) from the
Actions tab. This installs the MongoDB Community Operator (cluster-wide,
`watchNamespace: "*"`) and the Loki/Alloy/Grafana stack. It must succeed once
before step 6 - `terraform/app/mongodb.tf`'s `MongoDBCommunity` resource
needs that CRD to already be registered, or its `terraform plan` fails
outright.

## 6. First deploy to an environment

Run the **CCA Deploy** workflow: `action=deploy`, `environment=integration`,
`region=asia-india`. This builds the backend and admin-frontend images,
pushes them to GHCR, applies `terraform/app` for that environment, waits for
the rollout, and runs the health check.

Verify:

```bash
kubectl -n cca-integration get pods
curl -4 http://<server-ipv4>:3211/api/health_check
curl -6 http://[<server-ipv6>]:3211/api/health_check
curl -4 http://<server-ipv4>:3202/
```

Repeat with `environment=uat` and `environment=production` when ready.

## 7. Day-2 operations

Run the **CCA Ops** workflow with `action` = `status` / `stop` / `restart` /
`scale`, or run `scripts/ops.sh` directly on the server. `stop` deletes the
environment's HPA before scaling to 0 (otherwise the HPA would just scale it
back up); `restart` (or the next Terraform apply) is what brings the HPA
back.

## 8. Rollback

Run **CCA Deploy** with `action=rollback`, the target `environment`, and
`version` set to an exact previous deployment version string (e.g.
`v2026.08.26.143015-production-r184` - these are also pushed as git tags on
this repo, so `git tag -l` is one place to find them). No images are
rebuilt; the workflow re-applies Terraform with the exact image digests
recorded in that version's `manifest.json`.

## 9. Demonstrating autoscaling

```bash
./scripts/load-test.sh integration 120 20
# in another terminal:
kubectl -n cca-integration get hpa backend -w
kubectl -n cca-integration get pods -l app.kubernetes.io/name=backend -w
```

Scale-up reacts within roughly 15-30 seconds of sustained load above the
HPA's CPU target; scale-down has a default 5-minute stabilization window, so
don't expect Pods to disappear immediately after the load stops.

## 10. Troubleshooting

- **`terraform plan`/`apply` fails at `data.external.secret_guard`**: you
  skipped `scripts/apply-secrets.sh <environment>` (or `platform`) before
  applying. The error message names exactly which Secret is missing.
- **A Deployment sits in `Init:0/1`**: the `wait-redis` initContainer is
  still waiting - check `kubectl -n <namespace> logs deploy/backend -c
  wait-redis` and `kubectl -n <namespace> get pods -l
  app.kubernetes.io/name=redis`.
- **A Deployment sits in `CreateContainerConfigError`**: almost always a
  missing/misnamed Secret key - `kubectl -n <namespace> describe pod <pod>`
  names the exact key.
- **HPA shows `<unknown>` under TARGETS**: `kubectl top pods -n <namespace>`
  should work if Metrics Server is healthy; if it isn't, `kubectl get
  apiservice v1beta1.metrics.k8s.io` shows why.
- **`terraform apply` for `mongodb.tf` fails at plan time**: the MongoDB
  Community Operator CRD isn't installed yet - run the CCA Platform workflow
  first (step 5).
- **Health check trips the circuit breaker and auto-rolls-back**: read the
  `deploy-terraform` job's log for `scripts/health-check.sh` - it prints
  exactly which checks failed and which version it rolled back to.

## 11. Enabling video processing

Off by default (`enable_video_worker = false` in every `config/*.tfvars`) -
ffmpeg encoding spawns `runtime.NumCPU()*4` threads per run
(`src/my_modules/video_streaming.go`), which is heavy for a single shared
home server. To turn it on for an environment, set in that environment's
`config/<env>.tfvars`:

```hcl
enable_video_worker   = true
video_worker_schedule = "*/5 * * * *"   # tune to taste
```

This deploys `backend-video` as a Kubernetes **CronJob** (not a persistent
Deployment - see IMPLEMENTATION_PLAN.md §14 for why), running
`-micro_service video_processing` on that schedule with
`concurrency_policy = Forbid`, so a run never overlaps the previous one.
Real encoding happens on this server; nothing here calls out to Google
Cloud. Check it with:

```bash
kubectl -n cca-<environment> get cronjob backend-video
kubectl -n cca-<environment> get jobs -l app.kubernetes.io/name=backend-video
kubectl -n cca-<environment> logs -l app.kubernetes.io/name=backend-video --tail=100
```

Expect to still occasionally see a logged (harmless) `StartVMInstance
failed` error from `backend-cron`'s own scheduler - see
IMPLEMENTATION_PLAN.md §14 for why that's expected and not a sign of
anything broken.
