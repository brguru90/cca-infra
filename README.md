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

## Repository layout

```
terraform/app/       Terraform applied once PER environment
terraform/platform/  Terraform applied once, cluster-wide (MongoDB operator, observability)
docker/               Dockerfiles for cca_backend and cca_admin_frontend
kubernetes/nginx/     nginx config template for the admin-frontend ConfigMap
config/               Per-environment .tfvars
scripts/              Server-side install/ops scripts, run by CI or by hand
.github/workflows/    deploy (also repository_dispatch-triggered) | ops | platform | verify
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
