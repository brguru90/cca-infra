#!/usr/bin/env bash
# Restores an environment's Terraform state from a known-good backup after
# state loss or corruption (e.g. a crashed `terraform apply` writing a
# truncated state file - see IMPLEMENTATION_PLAN.md for the incident this
# was written for). Never deletes the current state file - moves it aside
# with a timestamped suffix first, so a bad restore choice is itself always
# reversible. Companion to scripts/backup-state.sh, which is what populates
# the backups this restores from.
#
# Usage: scripts/restore-state.sh <integration|uat|production> [backup-file|latest]
#   backup-file: a filename under /srv/cca/state/<environment>/backups/ (not
#                a full path). Defaults to the most recent backup.
#
# This only touches the local state file - it does not run `terraform plan`
# or `apply`. Always run `terraform plan` immediately after restoring, before
# ever applying, to confirm the restored state actually matches the live
# cluster with no unexpected drift.

set -euo pipefail

environment="${1:?usage: restore-state.sh <integration|uat|production> [backup-file|latest]}"
backup_choice="${2:-latest}"

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

if [[ "$backup_choice" == "latest" ]]; then
  backup_file="$(ls -1t "${backup_dir}"/tfstate-*.tfstate 2>/dev/null | head -n1)"
else
  backup_file="${backup_dir}/${backup_choice}"
fi

if [[ -z "${backup_file:-}" || ! -f "$backup_file" ]]; then
  echo "FATAL: no backup found (looked for '${backup_choice}' under ${backup_dir})" >&2
  exit 1
fi

if [[ ! -s "$backup_file" ]]; then
  echo "FATAL: backup file '${backup_file}' is empty - refusing to restore from it" >&2
  exit 1
fi

# Same lock file backup-state.sh uses, so a restore can never race a backup
# (or another restore) against the same environment's state directory.
exec 9>"${state_dir}/.backup.lock"
flock 9

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -f "$state_file" ]]; then
  quarantine_file="${state_dir}/terraform.tfstate.corrupted-${timestamp}"
  cp "$state_file" "$quarantine_file"
  echo "restore-state: current state preserved at ${quarantine_file}" >&2
fi

cp "$backup_file" "$state_file"
echo "restore-state: restored ${backup_file} -> ${state_file}" >&2
echo "restore-state: run 'terraform plan' next to confirm no unexpected drift before applying anything" >&2
