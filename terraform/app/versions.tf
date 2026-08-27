# terraform/app is applied once PER ENVIRONMENT (integration, uat, production),
# each with its own local state file and its own namespace. See
# scripts/apply-secrets.sh and .github/workflows/deploy.yml for how this root
# is invoked: TF_DATA_DIR is set per environment, and `init -backend-config`
# points at /srv/cca/state/<env>/terraform.tfstate.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.1"
    }
    # Used by preflight.tf's secret-existence guard (data "external").
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }

  # Partial backend config - the actual path is supplied at `terraform init`
  # time via -backend-config="path=/srv/cca/state/<env>/terraform.tfstate" so
  # this root works identically for all three environments.
  backend "local" {}
}
