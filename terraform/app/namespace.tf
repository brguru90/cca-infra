# Namespace ownership note (read this before "fixing" it back to a resource):
#
# scripts/apply-secrets.sh runs BEFORE every `terraform apply` (see
# .github/workflows/deploy.yml and terraform/app/preflight.tf), and it must
# create the namespace itself, idempotently
# (`kubectl create namespace ... --dry-run=client -o yaml | kubectl apply -f -`)
# because it needs somewhere to put the backend/Firebase Secrets before
# Terraform ever runs. That means the namespace already exists by the time
# Terraform starts on every single run, including the very first one for a
# brand-new environment.
#
# A `resource "kubernetes_namespace_v1"` here would therefore try to CREATE a
# namespace that already exists and fail with 409 Conflict on every first
# apply for a new environment - Terraform resources create-or-fail, they don't
# adopt. Rather than juggle a manual `terraform import` step on every new
# environment, this root reads the namespace as data instead: it fails `plan`
# with a clear message if apply-secrets.sh wasn't run, and never fights over
# ownership of an object something else legitimately has to create first.

data "kubernetes_namespace_v1" "this" {
  metadata {
    name = local.namespace
  }
}
