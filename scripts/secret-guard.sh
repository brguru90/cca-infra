#!/usr/bin/env bash
# Called by terraform/app/preflight.tf's `data "external"` block as:
#   bash scripts/secret-guard.sh <namespace>
#
# Contract (do not break this - it's a Terraform external data source):
#   - stdout MUST be exactly one flat JSON object with string values, and
#     NOTHING else. Any stray echo/log line on stdout breaks Terraform's
#     `data "external"` parsing.
#   - all diagnostics go to stderr.
#   - exit 0 whenever the check itself ran successfully, REGARDLESS of
#     whether the secrets it checked for exist - "false" is a valid,
#     successful result. Only exit non-zero if the check couldn't run at all
#     (e.g. kubectl/kubeconfig broken), since Terraform surfaces a non-zero
#     exit as a hard error rather than a value it can precondition on.
#
# This intentionally never reads a Secret's data, only whether it exists
# (`kubectl get secret <name> -n <namespace>` exit code) - see
# IMPLEMENTATION_PLAN.md's secrets decision for why: a `data
# "kubernetes_secret_v1"` here would read plaintext values into Terraform
# state, which is exactly what this project avoids.

set -euo pipefail

namespace="${1:?usage: secret-guard.sh <namespace>}"

# Fail loudly and distinctly if kubectl can't reach the cluster at all,
# rather than letting every secret below read back as a misleading "false"
# (missing) when the real problem is connectivity/auth.
if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
  echo "secret-guard: FATAL - cannot read namespace '${namespace}' (cluster unreachable, or the namespace genuinely doesn't exist yet - run apply-secrets.sh first)" >&2
  exit 1
fi

required_secrets=(
  "cca-backend-secrets"
  "cca-firebase-sa"
  "cca-mongo-user-password"
)

json_parts=()
for name in "${required_secrets[@]}"; do
  if kubectl get secret "$name" -n "$namespace" >/dev/null 2>&1; then
    present="true"
  else
    present="false"
  fi
  echo "secret-guard: ${namespace}/${name} present=${present}" >&2
  json_parts+=("\"${name}\":\"${present}\"")
done

IFS=,
echo "{${json_parts[*]}}"
