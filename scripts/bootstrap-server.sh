#!/usr/bin/env bash
# One-time host prep, run after install-k3s.sh and before the self-hosted
# GitHub Actions runner does its first deploy. Creates the directory
# structure Terraform's local state/backups live in, and the `cca` group
# that gives the runner user read access to K3s's kubeconfig without making
# it world-readable. Idempotent.
#
# Not run by any workflow in this repo - see docs/RUNBOOK.md. Run manually,
# once, on the actual home server.

set -euo pipefail

RUNNER_USER="${RUNNER_USER:?set RUNNER_USER to the account the self-hosted GitHub Actions runner runs as}"

echo "bootstrap-server: creating /srv/cca layout" >&2
mkdir -p /srv/cca/state/{integration,uat,production}/backups
mkdir -p /srv/cca/tfdata/{integration,uat,production,platform}
mkdir -p /srv/cca/releases

echo "bootstrap-server: creating cca group and adding ${RUNNER_USER}" >&2
getent group cca >/dev/null 2>&1 || groupadd cca
usermod -aG cca "$RUNNER_USER"

echo "bootstrap-server: ownership" >&2
chown -R "${RUNNER_USER}:cca" /srv/cca
chmod -R 750 /srv/cca

echo "bootstrap-server: verifying required tools are on PATH" >&2
missing=()
for tool in docker terraform kubectl helm curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  else
    echo "  - $tool: $(command -v "$tool")" >&2
  fi
done

if ((${#missing[@]} > 0)); then
  echo "bootstrap-server: FATAL - missing required tools: ${missing[*]}" >&2
  echo "Install them before registering the self-hosted runner - see docs/RUNBOOK.md." >&2
  exit 1
fi

cat <<'EOF'

bootstrap-server: done. Next steps (see docs/RUNBOOK.md):
  1. Log the runner user out/in (or reboot) so the new `cca` group
     membership takes effect for its GitHub Actions runner process.
  2. Register the self-hosted runner against brguru90/cca-infra if you
     haven't already (Settings > Actions > Runners > New self-hosted runner).
  3. Run scripts/apply-secrets.sh platform, then apply terraform/platform.
  4. For each environment: run scripts/apply-secrets.sh <env>, then apply
     terraform/app with that environment's config/<env>.tfvars.
EOF
