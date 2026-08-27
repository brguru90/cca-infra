#!/usr/bin/env bash
# Creates/updates every Kubernetes Secret a `terraform apply` in this project
# depends on, WITHOUT ever putting a value into Terraform state - Terraform
# only ever references these by name (envFrom/secretKeyRef/passwordSecretRef).
# Run this before every `terraform apply`, for both terraform/app (per
# environment) and terraform/platform (once). See
# terraform/app/preflight.tf / terraform/platform/namespace.tf for why the
# namespace itself is also created here rather than by Terraform: this
# script needs it to exist to create Secrets in it, and it runs first.
#
# Usage:
#   scripts/apply-secrets.sh <integration|uat|production|platform>
#
# Required environment variables (see docs/RUNBOOK.md for the full list per
# target and IMPLEMENTATION_PLAN.md §8 for where each one is set as a GitHub
# Secret):
#   integration|uat|production:
#     JWT_SECRET_KEY, RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET,
#     FIREBASE_SERVICE_ACCOUNT_JSON, MONGO_ADMIN_PASSWORD
#   platform:
#     GRAFANA_ADMIN_PASSWORD

set -euo pipefail

target="${1:?usage: apply-secrets.sh <integration|uat|production|platform>}"

req() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "FATAL: required environment variable ${var_name} is not set" >&2
    exit 1
  fi
}

apply_secret() {
  # Thin wrapper so every secret is created the same way: idempotent,
  # server-side-apply-equivalent, never printed.
  local namespace="$1"
  shift
  kubectl create secret generic "$@" \
    --namespace "$namespace" \
    --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
}

ensure_namespace() {
  local namespace="$1"
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "apply-secrets: namespace ${namespace} present" >&2
}

case "$target" in
  integration | uat | production)
    namespace="cca-${target}"

    req JWT_SECRET_KEY
    req RAZORPAY_KEY_ID
    req RAZORPAY_KEY_SECRET
    req FIREBASE_SERVICE_ACCOUNT_JSON
    req MONGO_ADMIN_PASSWORD

    ensure_namespace "$namespace"

    apply_secret "$namespace" cca-backend-secrets \
      --from-literal="JWT_SECRET_KEY=${JWT_SECRET_KEY}" \
      --from-literal="RAZORPAY_KEY_ID=${RAZORPAY_KEY_ID}" \
      --from-literal="RAZORPAY_KEY_SECRET=${RAZORPAY_KEY_SECRET}"
    echo "apply-secrets: ${namespace}/cca-backend-secrets applied" >&2

    # Firebase service-account JSON: written briefly to tmpfs (/dev/shm),
    # never to persistent disk, and shredded immediately after use. The
    # secret's key name must equal the filename cca_backend expects at
    # /web_app/env/<this filename> (see terraform/app/backend_api.tf's
    # sub_path mount and terraform/app/locals.tf's firebase_json_filename).
    firebase_json_filename="cca-vijayapura-firebase-adminsdk-ghz2d-1f8e7ad071.json"

    # /dev/shm (tmpfs) is standard on any Linux host, including the Ubuntu 24
    # target server - this deliberately fails loudly rather than falling back
    # to persistent disk, which would defeat the point of using tmpfs here.
    if [[ ! -d /dev/shm || ! -w /dev/shm ]]; then
      echo "FATAL: /dev/shm is not available/writable on this host - refusing to write the Firebase service-account key to persistent disk instead" >&2
      exit 1
    fi

    firebase_tmp="$(mktemp /dev/shm/cca-firebase-sa.XXXXXX.json)"
    trap 'shred -u "$firebase_tmp" 2>/dev/null || rm -f "$firebase_tmp"' EXIT
    printf '%s' "$FIREBASE_SERVICE_ACCOUNT_JSON" > "$firebase_tmp"

    kubectl create secret generic cca-firebase-sa \
      --namespace "$namespace" \
      "--from-file=${firebase_json_filename}=${firebase_tmp}" \
      --dry-run=client -o yaml \
      | kubectl apply -f - >/dev/null

    shred -u "$firebase_tmp" 2>/dev/null || rm -f "$firebase_tmp"
    trap - EXIT
    echo "apply-secrets: ${namespace}/cca-firebase-sa applied" >&2

    # Consumed once by the MongoDB Community Operator when it creates the
    # user (terraform/app/mongodb.tf's passwordSecretRef); the operator's own
    # docs note the secret is no longer required after that, but we keep
    # reapplying it every run so scripts/secret-guard.sh's existence check
    # (terraform/app/preflight.tf) stays satisfied and a user re-creation
    # (e.g. after deleting the MongoDBCommunity resource) still works. Key
    # name "password" is the operator's hardcoded default - see
    # SecretKeyReference.Key in the operator's API types.
    apply_secret "$namespace" cca-mongo-user-password \
      --from-literal="password=${MONGO_ADMIN_PASSWORD}"
    echo "apply-secrets: ${namespace}/cca-mongo-user-password applied" >&2
    ;;

  platform)
    namespace="cca-monitoring"
    req GRAFANA_ADMIN_PASSWORD

    ensure_namespace "$namespace"

    apply_secret "$namespace" cca-grafana-admin \
      --from-literal="admin-user=admin" \
      --from-literal="admin-password=${GRAFANA_ADMIN_PASSWORD}"
    echo "apply-secrets: ${namespace}/cca-grafana-admin applied" >&2
    ;;

  *)
    echo "FATAL: unknown target '${target}' - expected integration|uat|production|platform" >&2
    exit 1
    ;;
esac

echo "apply-secrets: done (${target})" >&2
