# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this directory is

This is **not a source code repository** — it's not a git repo and contains no buildable code, no package manager files, and no tests. It holds two long-form architecture/design planning documents (AI-assisted Q&A transcripts) for a personal home-lab CI/CD and deployment project. There is nothing to build, lint, or test here.

- `initial-plan.md` — the original design: Terraform + Docker on a home server.
- `final-plan.md` — **supersedes `initial-plan.md`**. Its header states it's "requirements (enhancement of ./initial-plan.md)". It revises the design to use Kubernetes (K3s) instead of plain Docker, and changes how the Flutter app is handled.

When asked about "the plan" or "the architecture," treat `final-plan.md` as authoritative; only fall back to `initial-plan.md` for sections final-plan.md doesn't override (e.g. secrets rotation findings, logging stack, Terraform state layout — these carry forward unchanged).

## The system being designed

A deployment pipeline for a personal travel-planner app ("cca") spread across repos:
- `cca_backend` (Go API)
- `cca_frontend` (Flutter mobile app)
- `cca_admin_frontend` (React admin UI)
- `cca-infra` (new, private repo to be created — holds Terraform, Kubernetes manifests, and GitHub Actions workflows)

Target: merge to `main` in an app repo → manually trigger a GitHub Actions workflow in `cca-infra` → build & push Docker images to GHCR → deploy to a single Ubuntu 24 home server (public IPv6 DDNS host `travel-planner.ddns.net`) running K3s, with separate `integration`/`uat`/`production` environments (each a K8s namespace) and a single "region" (`asia-india`, since there's only one physical server).

### Key architecture facts (final-plan.md)

- **Runtime**: K3s (single-node Kubernetes) on the Ubuntu 24 host, not raw Docker. Bundled Traefik is disabled in favor of NodePort services. Terraform runs *on the home server* (talking to the local K3s API / Docker socket), not from the GitHub runner — the runner only reaches the server over SSH/IPv6 (or a self-hosted runner, if available, to avoid inbound SSH entirely).
- **Environments = namespaces**: `cca-integration`, `cca-uat`, `cca-production`, each with its own Deployment/Service/Secret/HPA per app component.
- **NodePorts** (K3s `service-node-port-range` widened to `3200-8799` to fit the user's requested range):
  | Environment | Backend | Frontend | Admin |
  |---|---|---|---|
  | integration | 8701 | 3201 | 3202 |
  | uat | 8702 | 3301 | 3302 |
  | production | 8703 | 3401 | 3402 |
- **Flutter app is not deployed to Kubernetes.** CI only runs `flutter build apk --release` and publishes the APK as a GitHub Actions artifact / GitHub Release asset, alongside a `source-version.json` recording which backend/admin/flutter commits it was built from.
- **Versioning/rollback**: every deploy is tagged `v<UTC timestamp>-<environment>-r<workflow run number>` (e.g. `v2026.08.26.143015-production-r184`). This tags the GHCR images and the `cca-infra` git commit. Rollback re-applies Terraform with the old image tag — no rebuild. Prefer this explicit tagging over relying on `kubectl rollout undo`.
- **Terraform state**: local state per environment on the home server (`/srv/cca/state/<env>/terraform.tfstate`), with timestamped backups taken before every apply.
- **Secrets**: live in GitHub (Environment) Secrets, materialized as Kubernetes Secrets via Terraform at deploy time — never committed to git or baked into images. Note the known caveat that Terraform-managed K8s Secrets land in Terraform state, which is acceptable for this hobby setup but would need Vault/SOPS+age for anything more sensitive.
- **Logging**: container/Pod logs → Grafana Alloy → Loki → Grafana, as a self-hosted CloudWatch Logs equivalent, labeled by region/environment/service/version.
- **Autoscaling caveat**: HPA only scales Pod replica counts on the existing single node — it cannot add nodes/CPU/RAM. True node autoscaling would require a later phase (KVM + multiple VMs), explicitly deferred.
- **Security findings carried over from initial-plan.md**: `cca_backend`'s Dockerfile has hardcoded DB/JWT/Redis/payment secrets, and `cca_admin_frontend` has `.env`/`.env_prod` files tracked in its (public) repo. Both need real credential rotation and removal from git history, not just a follow-up commit deleting them.

## Working in this directory

Since there's no code, typical "build/test/lint" workflows don't apply. Most useful tasks here are:
- Reading/updating the plan documents to reflect new decisions.
- Drafting the actual `cca-infra` repo contents (Terraform, K8s manifests, GitHub Actions workflows) described in `final-plan.md`, when asked — that work will happen in a new repository, not in this directory.
