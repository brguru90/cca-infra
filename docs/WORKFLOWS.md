# Workflows

What each `.github/workflows/*.yml` file does, when it runs, and what its
inputs mean. All except `verify.yml` run on the self-hosted runner on the
home server (`runs-on: [self-hosted, linux]`) - they need the kubeconfig,
Docker socket, and/or `/srv/cca` layout that only exists there.

## `deploy.yml` - CCA Deploy

The main pipeline: builds `cca_backend`/`cca_admin_frontend` images (and
optionally the `cca_frontend` APK), applies Terraform for one environment,
verifies health, and rolls back automatically on failure.

**Triggers:**
- `workflow_dispatch` - manual, from the Actions tab. Every input below is
  only populated on this trigger type.
- `repository_dispatch` (`event_type: app-push`) - fired by
  `notify-cca-infra.yml` in `cca_backend`/`cca_frontend`/`cca_admin_frontend`
  on push to their `main`. Always resolves to `action=deploy`,
  `environment=integration`, `region=asia-india`, regardless of which app
  repo triggered it or what's in the payload - `uat`/`production` are never
  auto-deployed.

**Inputs (`workflow_dispatch` only):**
| Input | Values | Notes |
|---|---|---|
| `action` | `deploy` \| `rollback` | `rollback` skips all three build jobs and redeploys a previously recorded version's image tags instead. |
| `environment` | `integration` \| `uat` \| `production` | |
| `region` | `asia-india` | Only one option today - exists for the day a second region is added. |
| `version` | free text | Required for `action=rollback` (e.g. `v2026.08.26.143015-production-r184`); ignored for `deploy`. |
| `skip_flutter` | boolean | Skips the APK build only - backend/admin-frontend still deploy normally. Useful when iterating on backend/admin changes and the APK build (the slowest job) isn't needed yet. |

**Job graph:** `prepare` → `build-backend` / `build-admin` / `build-flutter`
(parallel) → `deploy-terraform` (needs `prepare` + `build-backend` +
`build-admin` only - a Flutter/Gradle flake must never block an API/admin
deploy) → `record-release`.

**When to use it:** every deploy or rollback for `integration`/`uat`/`production`.

## `platform.yml` - CCA Platform

Applies `terraform/platform` - the MongoDB Community Operator and
Loki/Alloy/Grafana observability stack - once, cluster-wide. Also resyncs
Grafana's live admin password from the `GRAFANA_ADMIN_PASSWORD` secret on
every run (see `docs/RUNBOOK.md` for why a Secret update alone doesn't
change an already-provisioned Grafana password).

**Trigger:** `workflow_dispatch`, no inputs.

**When to use it:**
- Once, before the very first `terraform/app` apply for *any* environment -
  `terraform/app/mongodb.tf`'s `kubernetes_manifest` resource validates
  against the MongoDBCommunity CRD at *plan* time, which only exists once
  this has run.
- Any time you bump a chart version in `terraform/platform/variables.tf`.
- Any time you rotate `GRAFANA_ADMIN_PASSWORD` and want the live password to
  actually match it (see the question this answers in RUNBOOK.md).

## `ops.yml` - CCA Ops

Day-2 operations on an already-deployed environment: `status`, `stop`,
`restart`, `scale`. A thin shim over `scripts/ops.sh` so the same logic also
works by hand on the server if GitHub is unreachable.

**Trigger:** `workflow_dispatch`.

**Inputs:**
| Input | Values | Notes |
|---|---|---|
| `action` | `status` \| `stop` \| `restart` \| `scale` | |
| `environment` | `integration` \| `uat` \| `production` | |
| `region` | `asia-india` | |
| `component` | `all` \| `backend` \| `admin-frontend` | `scale` requires `backend` or `admin-frontend`, not `all`. |
| `replicas` | integer (default `1`) | `scale` only. |

Shares `deploy.yml`'s concurrency group (`cca-<region>-<environment>`) so a
`stop` can never race a `deploy` against the same environment. `production`
gates on the same required-reviewer approval a deploy would.

## `bootstrap-host.yml` - CCA Bootstrap Host

One-time (idempotent) host setup, run through the runner instead of SSH'ing
in by hand: installs Terraform/Helm/`gh`/the Android SDK if missing, then
runs `scripts/install-k3s.sh` and `scripts/bootstrap-server.sh`.

**Trigger:** `workflow_dispatch`.

**Inputs:**
| Input | Values | Notes |
|---|---|---|
| `runner_user` | free text | OS user the runner service runs as - passed through to `bootstrap-server.sh` as `RUNNER_USER` so it can add that user to the `cca` group. |

**When to use it:** first-time server setup, or to re-verify/repair host
state later (both scripts and the tool-install step are safe to re-run).
**Read the workflow's own header comment before running it** - depending on
whether the runner service runs as root or a scoped non-root user, you may
need to restart the runner service afterward before `CCA Platform`/`CCA
Deploy` will work (they read the kubeconfig directly, and a running
process's group memberships don't update until it restarts).

## `restore-state.yml` - CCA Restore State

Recovers an environment's Terraform state from a known-good backup after
state loss or corruption (e.g. a crashed `terraform apply` leaving a
truncated state file - a real incident this was built for, see
IMPLEMENTATION_PLAN.md). A thin shim over `scripts/restore-state.sh`.

**Trigger:** `workflow_dispatch`.

**Inputs:**
| Input | Values | Notes |
|---|---|---|
| `environment` | `integration` \| `uat` \| `production` | |
| `region` | `asia-india` | |
| `backup_file` | filename (default `latest`) | A filename under `/srv/cca/state/<environment>/backups/` - not a full path. `scripts/backup-state.sh` keeps the last 20, taken before every apply. |

This only restores the local state *file* - it deliberately does not run
`terraform plan`/`apply` itself. Always run `CCA Deploy` (or `terraform
plan` directly) right after, to confirm the restored state actually matches
the live cluster before applying anything. Never deletes the current state
file - quarantines it with a timestamped suffix first, so a bad restore
choice is itself reversible.

## `debug.yml` - CCA Debug

Ad-hoc, read-only cluster introspection for a given namespace - not part of
the deploy/rollback/platform pipelines. Exists so a stuck rollout, a
crash-looping pod, or a NodePort connectivity problem can be diagnosed
without re-running an entire build+deploy cycle just to see what's wrong.

**Trigger:** `workflow_dispatch`.

**Inputs:**
| Input | Values | Notes |
|---|---|---|
| `namespace` | free text (default `cca-integration`) | e.g. `cca-uat`, `cca-production`. |

**Dumps:** pods/deployments/PVCs/PVs/StorageClasses/ConfigMaps/events;
Terraform state list for that environment's app root (read-only, no
init/apply mutation beyond a local `-reconfigure`); NodePort connectivity
over IPv4 loopback and the node's real global IPv6 address, plus the
matching `iptables`/`ip6tables` `KUBE-NODEPORTS` chains; each Service's live
`ipFamilies`/`clusterIPs` and each pod's `status.podIPs`/EndpointSlices;
`k3s` systemd status; and a `describe`/`logs`/`logs --previous` dump for
every pod that is either not Ready *or* has ever restarted (catches a pod
that's crash-looping but happens to be `Running` at the exact moment this
runs).

**When to use it:** first thing to reach for when something in `CCA Deploy`
or `CCA Platform` fails and the reason isn't obvious from that run's own
logs.

## `verify.yml` - CCA Verify

Static checks only - `terraform fmt`/`validate`, `hadolint`, `shellcheck`,
`actionlint`. No cluster access, no secrets, runs on GitHub-hosted runners
(`ubuntu-latest`) deliberately, since none of the self-hosted runner's
privileged access (cluster-admin kubeconfig, Docker socket) is needed or
wanted here.

**Triggers:** `pull_request` (against `main`) and `workflow_dispatch`.

**When to use it:** automatic on every PR; manually if you want to re-check
the current branch without opening one.
