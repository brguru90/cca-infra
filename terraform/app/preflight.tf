# Fails `terraform plan` in seconds, with a clear message, if
# scripts/apply-secrets.sh hasn't been run for this environment yet - instead
# of every Deployment reaching CreateContainerConfigError and the apply
# timing out on `wait_for_rollout` several minutes later.
#
# This deliberately does NOT use `data "kubernetes_secret_v1"` to check
# existence: that data source reads the Secret's values into Terraform state
# in plaintext, which is exactly what IMPLEMENTATION_PLAN.md's secrets
# decision rules out. `data "external"` runs a script that reports only
# true/false per Secret name - no value ever crosses into Terraform's
# world.

data "external" "secret_guard" {
  program = ["bash", "${path.module}/../../scripts/secret-guard.sh", local.namespace]
}

resource "terraform_data" "secrets_present" {
  input = data.external.secret_guard.result

  lifecycle {
    precondition {
      condition = alltrue([
        for name in [
          local.backend_secret_name,
          local.firebase_secret_name,
          local.mongo_user_password_secret_name,
        ] :
        try(data.external.secret_guard.result[name], "false") == "true"
      ])
      error_message = "One or more required Secrets are missing in namespace ${local.namespace}. Run scripts/apply-secrets.sh ${var.environment} first. Expected: ${local.backend_secret_name}, ${local.firebase_secret_name}, ${local.mongo_user_password_secret_name}."
    }
  }
}
