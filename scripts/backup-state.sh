#!/usr/bin/env bash
# Snapshots an environment's Terraform state before every `terraform apply` -
# run by .github/workflows/deploy.yml immediately before the apply step.
# Keeps the last 20 backups per environment so a bad apply always has a
# recent, known-good state to fall back to.
#
# Usage: scripts/backup-state.sh <integration|uat|production>

set -euo pipefail

environment="${1:?usage: backup-state.sh <integration|uat|production>}"

case "$environment" in
  integration | uat | production) ;;
  *)
    echo "FATAL: invalid environment '${environment}'" >&2
    exit 1
    ;;
esac

state_dir="/srv/cca/state/${environment}"
backup_dir="${state_dir}/backups"
state_file="${state_dir}/terraform.tfstate"

mkdir -p "$backup_dir"

if [[ ! -f "$state_file" ]]; then
  echo "backup-state: no existing state for ${environment} yet (first-ever apply) - nothing to back up" >&2
  exit 0
fi

# flock serializes concurrent runs against the same environment's state dir -
# belt-and-suspenders alongside deploy.yml's own concurrency group, in case
# this script is ever invoked outside that workflow (e.g. manually).
exec 9>"${state_dir}/.backup.lock"
flock 9

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_file="${backup_dir}/tfstate-${timestamp}.tfstate"
cp "$state_file" "$backup_file"
echo "backup-state: ${state_file} -> ${backup_file}" >&2

# Prune to the last 20 backups.
mapfile -t old_backups < <(ls -1t "${backup_dir}"/tfstate-*.tfstate 2>/dev/null | tail -n +21)
if ((${#old_backups[@]} > 0)); then
  rm -f "${old_backups[@]}"
  echo "backup-state: pruned ${#old_backups[@]} backup(s) older than the most recent 20" >&2
fi
