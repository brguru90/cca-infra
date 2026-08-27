# terraform/platform is applied ONCE, cluster-wide, before any terraform/app
# environment is ever applied for the first time - it installs the MongoDB
# Community Operator (whose CRD terraform/app/mongodb.tf depends on) and the
# Loki/Alloy/Grafana observability stack. Own local state, separate from
# every environment's terraform/app state.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.2.0"
    }
  }

  backend "local" {}
}
