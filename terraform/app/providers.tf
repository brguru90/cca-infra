# Terraform runs ON the home server, next to K3s, so it talks to the local
# API server via the kubeconfig K3s writes out - never over the network, never
# exposed publicly. scripts/install-k3s.sh installs K3s with
# --write-kubeconfig-group=cca --write-kubeconfig-mode=0640 so the runner user
# (a member of the `cca` group) can read it without the file being
# world-readable.

provider "kubernetes" {
  config_path = "/etc/rancher/k3s/k3s.yaml"
}
