#!/usr/bin/env bash
# Demonstrates HPA autoscaling end-to-end against a running environment -
# not part of any CI workflow, run manually on (or against) the server when
# you actually want to watch Pods scale. Generates sustained load against
# the (cheap, side-effect-free) health endpoint, and prints how to watch the
# HPA/Pod counts change in a second terminal.
#
# Usage: scripts/load-test.sh <environment> [duration_seconds] [concurrency]

set -euo pipefail

environment="${1:?usage: load-test.sh <environment> [duration_seconds] [concurrency]}"
duration="${2:-120}"
concurrency="${3:-20}"

case "$environment" in
  integration) backend_port=3211 ;;
  uat) backend_port=3311 ;;
  production) backend_port=3411 ;;
  *)
    echo "FATAL: invalid environment '${environment}'" >&2
    exit 1
    ;;
esac

url="http://127.0.0.1:${backend_port}/api/health_check"
namespace="cca-${environment}"

echo "load-test: hammering ${url} for ${duration}s at concurrency ${concurrency}" >&2
echo "load-test: in another terminal, watch scaling with:" >&2
echo "    kubectl -n ${namespace} get hpa backend -w" >&2
echo "    kubectl -n ${namespace} get pods -l app.kubernetes.io/name=backend -w" >&2
echo "load-test: note two things worth watching for:" >&2
echo "  - scale-up needs ~15s of sustained metrics above target before it acts" >&2
echo "  - scale-down defaults to a 5 minute stabilization window - Pods won't" >&2
echo "    disappear immediately after you stop this script, that's expected" >&2

if command -v hey >/dev/null 2>&1; then
  hey -z "${duration}s" -c "$concurrency" -H "User-Agent: cca-load-test/1" "$url"
elif command -v ab >/dev/null 2>&1; then
  echo "load-test: 'hey' not found, falling back to 'ab' (fixed request count, not duration-based)" >&2
  ab -t "$duration" -c "$concurrency" -H "User-Agent: cca-load-test/1" "${url}"
else
  echo "load-test: neither 'hey' nor 'ab' found on PATH - falling back to a plain curl loop (much lower throughput, but needs nothing extra installed)." >&2
  end=$((SECONDS + duration))
  while ((SECONDS < end)); do
    for _ in $(seq 1 "$concurrency"); do
      curl --silent --output /dev/null -A "cca-load-test/1" "$url" &
    done
    wait
  done
fi

echo "load-test: done generating load" >&2
