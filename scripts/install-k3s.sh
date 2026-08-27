#!/usr/bin/env bash
# One-time K3s install for the home server. Run manually, once, before the
# very first `terraform/platform apply`. Idempotent: re-running after K3s is
# already installed is a no-op (K3s's own installer already treats a matching
# version as a no-op, but this script also short-circuits before touching
# sysctls again).
#
# Not run by any workflow in this repo - see docs/RUNBOOK.md. This session
# has no access to the actual home server, so this script is written from
# the operator's docs and this project's networking decisions, but has not
# itself been executed against real hardware.

set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.31.5+k3s1}"
NODE_PORT_RANGE="${NODE_PORT_RANGE:-3200-4000}"

if command -v k3s >/dev/null 2>&1; then
  echo "install-k3s: k3s already installed ($(k3s --version | head -1)) - skipping install. Delete/reinstall manually if you need to change flags." >&2
  exit 0
fi

echo "install-k3s: preparing dual-stack sysctls" >&2
cat > /etc/sysctl.d/99-k3s-dualstack.conf <<'EOF'
# Required for dual-stack Kubernetes networking (see IMPLEMENTATION_PLAN.md's
# IPv6 decision): pods/services get IPv6 addresses that must be forwarded,
# and RAs must still be accepted once forwarding is on so the node keeps its
# SLAAC-assigned public IPv6 address.
net.ipv6.conf.all.forwarding = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.accept_ra = 2
EOF
sysctl --system >/dev/null

echo "install-k3s: installing K3s ${K3S_VERSION} (dual-stack, NodePort range ${NODE_PORT_RANGE}, Traefik/ServiceLB disabled)" >&2

# --disable=traefik: this project uses plain NodePort Services (see
#   terraform/app/backend_api.tf etc.), not an Ingress controller - Traefik
#   would otherwise fight for ports 80/443.
# --disable=servicelb: klipper-lb has historically mishandled dual-stack
#   hostPort binding; without any LoadBalancer-type Services in this project,
#   there's nothing for it to do anyway.
# --cluster-cidr / --service-cidr: dual-stack ranges. The IPv6 halves are ULA
#   (fd00::/8) - NOT publicly routable on their own. Public reachability
#   comes from the node's own global IPv6 address plus kube-proxy binding
#   NodePorts on `::` (see every Service's ip_family_policy in terraform/app),
#   not from the pod network being globally routable.
# --flannel-ipv6-masq: required for pod IPv6 egress to work at all, since the
#   pod CIDR isn't routable.
# --write-kubeconfig-group/-mode: lets the `cca` group (the self-hosted
#   runner user must be a member - see bootstrap-server.sh) read the
#   kubeconfig Terraform needs, without making it world-readable.
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server \
  --cluster-cidr=10.42.0.0/16,fd00:42::/56 \
  --service-cidr=10.43.0.0/16,fd00:43::/112 \
  --flannel-ipv6-masq \
  --kube-apiserver-arg="service-node-port-range=${NODE_PORT_RANGE}" \
  --disable=traefik \
  --disable=servicelb \
  --write-kubeconfig-group=cca \
  --write-kubeconfig-mode=0640

echo "install-k3s: waiting for node Ready" >&2
for _ in $(seq 1 30); do
  if k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; then
    break
  fi
  sleep 2
done
k3s kubectl get nodes

echo "install-k3s: verifying NodePort range landed" >&2
if ! pgrep -af kube-apiserver | grep -q "service-node-port-range=${NODE_PORT_RANGE}"; then
  echo "install-k3s: WARNING - could not confirm service-node-port-range=${NODE_PORT_RANGE} on the running apiserver process. Check manually with: pgrep -af kube-apiserver" >&2
fi

echo "install-k3s: resolved node addresses:" >&2
k3s kubectl get nodes -o wide

cat <<'EOF'

install-k3s: done. Next steps (see docs/RUNBOOK.md):
  1. Confirm the DDNS AAAA record for travel-planner.ddns.net matches this
     node's public IPv6 address (your DDNS updater's job, not this script's).
  2. Run scripts/bootstrap-server.sh to create /srv/cca directories and the
     `cca` group/user wiring the self-hosted runner needs.
  3. Apply terraform/platform once (installs the MongoDB Community Operator
     and Loki/Alloy/Grafana) before applying terraform/app for any
     environment.
EOF
