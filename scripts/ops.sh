#!/usr/bin/env bash
# Day-2 operations: stop, restart, status, scale - called by
# .github/workflows/ops.yml, but plain enough to run by hand on the server if
# GitHub Actions is unavailable. Deliberately never calls `terraform destroy`
# or `terraform apply` - these are live operational actions on resources
# Terraform already created, not infrastructure changes.
#
# Usage:
#   scripts/ops.sh status  <environment> [component]
#   scripts/ops.sh stop    <environment> [component]
#   scripts/ops.sh restart <environment> [component]
#   scripts/ops.sh scale   <environment> [component] <replicas>
#
# component defaults to "all" (backend + admin-frontend). backend-cron is
# intentionally excluded from stop/restart/scale here - see
# terraform/app/backend_cron.tf for why a second cron replica is unsafe, and
# stopping it silently disables the change-stream worker without an obvious
# signal. Use `kubectl scale deploy/backend-cron` directly if you really mean
# to do that.

set -euo pipefail

action="${1:?usage: ops.sh {status|stop|restart|scale} <environment> [component] [replicas]}"
environment="${2:?usage: ops.sh {status|stop|restart|scale} <environment> [component] [replicas]}"
component="${3:-all}"

case "$environment" in
  integration | uat | production) ;;
  *)
    echo "FATAL: invalid environment '${environment}'" >&2
    exit 1
    ;;
esac

namespace="cca-${environment}"

case "$component" in
  all) deployments=(backend admin-frontend) ;;
  backend) deployments=(backend) ;;
  admin-frontend) deployments=(admin-frontend) ;;
  *)
    echo "FATAL: invalid component '${component}' - expected all|backend|admin-frontend" >&2
    exit 1
    ;;
esac

case "$action" in
  status)
    echo "=== ${namespace} deployments ==="
    kubectl -n "$namespace" get deployments -o wide
    echo "=== ${namespace} pods ==="
    kubectl -n "$namespace" get pods -o wide
    echo "=== ${namespace} hpa ==="
    kubectl -n "$namespace" get hpa
    ;;

  stop)
    # A plain `kubectl scale --replicas=0` would just get fought back up to
    # the HPA's minReplicas on its next reconcile (every ~15s) as long as the
    # HPA object still exists - HPAScaleToZero isn't enabled by default in
    # most clusters, and even where it is, the HPA still owns the replica
    # count once it's the scaleTargetRef's controller. Delete the HPA first,
    # THEN scale to zero; `scripts/ops.sh restart` (or the next
    # `terraform apply`, which recreates the HPA) restores autoscaling.
    for d in "${deployments[@]}"; do
      echo "ops: deleting hpa/${d} in ${namespace} (if present) before scaling to 0" >&2
      kubectl -n "$namespace" delete hpa "$d" --ignore-not-found
      kubectl -n "$namespace" scale "deployment/${d}" --replicas=0
    done
    ;;

  restart)
    for d in "${deployments[@]}"; do
      current_replicas="$(kubectl -n "$namespace" get "deployment/${d}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
      if [[ "$current_replicas" == "0" ]]; then
        echo "ops: ${namespace}/${d} is at 0 replicas (stopped) - scaling to 1 before restarting. Re-apply Terraform afterwards to restore the HPA and its real minReplicas." >&2
        kubectl -n "$namespace" scale "deployment/${d}" --replicas=1
      fi
      kubectl -n "$namespace" rollout restart "deployment/${d}"
      kubectl -n "$namespace" rollout status "deployment/${d}" --timeout=5m
    done
    ;;

  scale)
    replicas="${4:?usage: ops.sh scale <environment> <component> <replicas>}"
    if [[ "$component" == "all" ]]; then
      echo "FATAL: 'scale' requires an explicit component (backend|admin-frontend), not 'all'" >&2
      exit 1
    fi
    echo "ops: scaling ${namespace}/${component} to ${replicas} replicas. This is a manual override - the HPA may scale it again on its next sync unless you also adjust minReplicas via Terraform." >&2
    kubectl -n "$namespace" scale "deployment/${component}" --replicas="$replicas"
    ;;

  *)
    echo "FATAL: unknown action '${action}' - expected status|stop|restart|scale" >&2
    exit 1
    ;;
esac
