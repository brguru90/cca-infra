#!/usr/bin/env bash
# Post-apply health verification AND the deployment circuit breaker
# (IMPLEMENTATION_PLAN.md §9.2): if the just-deployed version fails its
# health check, this script automatically re-applies Terraform with the
# last known-good version recorded in /srv/cca/releases/<env>.previous,
# instead of leaving a broken deployment live. It still exits non-zero in
# that case - a tripped breaker is a failed deploy, even though it healed
# itself, and the workflow/human needs to see that clearly.
#
# Ownership split for /srv/cca/releases/<env>.current / .previous:
#   - .github/workflows/deploy.yml copies .current -> .previous BEFORE
#     calling `terraform apply` for a new version, capturing "what was live
#     before this deploy" as the rollback target.
#   - THIS script only ever writes .current: to the new version on success,
#     or back to the previous version if it had to roll back. It never
#     touches .previous - that file always reflects the last version this
#     script confirmed healthy at some point in the past.
#
# Run from the repository root (so terraform/app and config/*.tfvars
# resolve as relative paths), after `terraform apply` and after
# `kubectl rollout status` has already confirmed the Deployments are Ready -
# this script checks that the application is actually SERVING correctly,
# which rollout status alone doesn't guarantee.
#
# Usage:
#   scripts/health-check.sh <environment> <backend_node_port> <admin_node_port> <deployment_version>

set -euo pipefail

environment="${1:?usage: health-check.sh <environment> <backend_node_port> <admin_node_port> <deployment_version>}"
backend_port="${2:?missing backend_node_port}"
admin_port="${3:?missing admin_node_port}"
new_version="${4:?missing deployment_version}"

case "$environment" in
  integration | uat | production) ;;
  *)
    echo "FATAL: invalid environment '${environment}'" >&2
    exit 1
    ;;
esac

releases_dir="${RELEASES_DIR:-/srv/cca/releases}"
# 10 attempts * 5s (50s total) was not enough in practice: right after a
# host reboot, `kubectl rollout status` (which already ran before this
# script) confirms Pod readiness via the pod IP directly, but kube-proxy's
# NodePort iptables DNAT rules can take noticeably longer than that to
# finish rebuilding from scratch - curl got a flat "Couldn't connect to
# server" against the NodePort for the full 50s even though the app was
# actually healthy underneath (confirmed manually seconds after this
# script gave up). 24 * 5s = 120s gives real cold-start headroom without
# meaningfully slowing down the normal case, where it exits the moment the
# first check passes.
attempts="${HEALTH_CHECK_ATTEMPTS:-24}"
delay_seconds="${HEALTH_CHECK_DELAY:-5}"

# curl -4 always; -6 only attempted if the host actually has IPv6 configured,
# so this script behaves the same in CI dry-runs (no IPv6) as it does on the
# real dual-stack server.
curl_families() {
  local families=(-4)
  if command -v ip >/dev/null 2>&1 && ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    families+=(-6)
  fi
  printf '%s\n' "${families[@]}"
}

check_once() {
  local family="$1"
  # User-Agent is sent for log clarity, not because anything currently
  # requires it - see terraform/app/backend_api.tf's probe comments.
  curl "$family" --fail --silent --show-error --max-time 5 \
    -A "cca-health-check/1 (${environment})" \
    "http://127.0.0.1:${backend_port}/api/health_check" >/dev/null \
    && curl "$family" --fail --silent --show-error --max-time 5 \
    -A "cca-health-check/1 (${environment})" \
    "http://127.0.0.1:${admin_port}/" >/dev/null
}

run_health_checks() {
  local ok=0
  for attempt in $(seq 1 "$attempts"); do
    local all_families_ok=1
    while read -r family; do
      if ! check_once "$family"; then
        all_families_ok=0
        break
      fi
    done < <(curl_families)

    if ((all_families_ok)); then
      ok=1
      break
    fi

    echo "health-check: attempt ${attempt}/${attempts} failed, retrying in ${delay_seconds}s" >&2
    sleep "$delay_seconds"
  done
  return $((1 - ok))
}

echo "health-check: verifying ${environment} (version ${new_version}) on backend:${backend_port} admin:${admin_port}" >&2

mkdir -p "$releases_dir"

if run_health_checks; then
  echo "health-check: PASS - ${environment} ${new_version} is healthy" >&2
  echo "$new_version" > "${releases_dir}/${environment}.current"
  exit 0
fi

echo "health-check: FAIL - ${environment} ${new_version} did not become healthy after ${attempts} attempts" >&2

previous_file="${releases_dir}/${environment}.previous"
if [[ ! -f "$previous_file" ]]; then
  echo "health-check: FATAL - no previous known-good version recorded for ${environment} (${previous_file} missing) - nothing to roll back to. This is likely the first-ever deploy to this environment; investigate manually." >&2
  exit 1
fi

previous_version="$(cat "$previous_file")"
manifest="${releases_dir}/${previous_version}/manifest.json"
if [[ ! -f "$manifest" ]]; then
  echo "health-check: FATAL - previous version ${previous_version} has no manifest at ${manifest} - cannot auto-rollback. Investigate manually." >&2
  exit 1
fi

backend_image="$(jq -r .backend_image "$manifest")"
admin_image="$(jq -r .admin_image "$manifest")"

echo "health-check: CIRCUIT BREAKER TRIPPED - rolling ${environment} back to ${previous_version} (${backend_image}, ${admin_image})" >&2

export TF_DATA_DIR="/srv/cca/tfdata/${environment}"
terraform -chdir=terraform/app apply -auto-approve -lock-timeout=5m \
  -var-file="../../config/${environment}.tfvars" \
  -var="deployment_version=${previous_version}" \
  -var="backend_image=${backend_image}" \
  -var="admin_image=${admin_image}"

kubectl -n "cca-${environment}" rollout status deploy/backend deploy/backend-cron deploy/admin-frontend --timeout=5m

if run_health_checks; then
  echo "$previous_version" > "${releases_dir}/${environment}.current"
  echo "health-check: rollback to ${previous_version} succeeded and is healthy. ${new_version} was NOT deployed successfully - this run still fails." >&2
else
  echo "health-check: FATAL - rollback to ${previous_version} ALSO failed health checks. ${environment} may be down. Investigate manually immediately." >&2
fi

# Always non-zero past this point: the requested deploy (new_version) failed,
# regardless of whether the automatic rollback itself succeeded.
exit 1
