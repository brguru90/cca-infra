provider "kubernetes" {
  config_path = "/etc/rancher/k3s/k3s.yaml"
}

# Helm provider v3 changed `kubernetes` from a nested BLOCK to a nested
# ATTRIBUTE (note the `=`). Copying a v2-era example with `kubernetes { ... }`
# is a hard parse error on this provider version.
provider "helm" {
  kubernetes = {
    config_path = "/etc/rancher/k3s/k3s.yaml"
  }
}
