locals {
  namespace = "cca-${var.environment}"

  common_labels = {
    "app.kubernetes.io/part-of" = "cca"
    "cca_environment"           = var.environment
    "cca_region"                = var.region
    # cca_version is deliberately NOT a common/stream label - see
    # kubernetes/nginx and terraform/platform/alloy for why: version as a Loki
    # stream label would mint a new log stream on every deploy. It's applied
    # only as a Deployment/Pod annotation-style label where it's useful for
    # `kubectl get -l`, not wired into log routing.
  }

  version_label = {
    "cca_version" = var.deployment_version
  }

  # Names of the Secrets that must already exist (created by
  # scripts/apply-secrets.sh) before this root's Deployments will come up
  # healthy. See preflight.tf - Terraform checks for their *existence* only,
  # never reads their values.
  backend_secret_name  = "cca-backend-secrets"
  firebase_secret_name = "cca-firebase-sa"

  firebase_json_filename = "cca-vijayapura-firebase-adminsdk-ghz2d-1f8e7ad071.json"

  # Pinned so the backend's secretKeyRef target is stable and known without
  # Terraform ever reading the operator-generated Secret's value. See
  # mongodb.tf and backend_api.tf.
  mongo_connection_secret_name = "cca-backend-mongo-conn"

  # Password Secret for the backend's MongoDB user. Created by
  # scripts/apply-secrets.sh from the MONGO_ADMIN_PASSWORD GitHub Environment
  # Secret. Consumed only by name (spec.users[0].passwordSecretRef.name) in
  # mongodb.tf - the operator reads it, generates the real user, and then it
  # is no longer required (per the operator's own docs). Terraform never
  # reads its value.
  mongo_user_password_secret_name = "cca-mongo-user-password"

  mongo_db_name   = "cca"
  mongo_user_name = "cca_backend"
}
