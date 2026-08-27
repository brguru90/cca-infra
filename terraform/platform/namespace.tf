# Same ownership rule as terraform/app/namespace.tf: the Grafana admin
# password Secret must exist in this namespace before the Grafana
# helm_release installs (Grafana reads it via admin.existingSecret), which
# means whatever creates that Secret must also create the namespace first,
# before Terraform ever runs. scripts/apply-secrets.sh platform handles this
# (see docs/RUNBOOK.md). Terraform reads the namespace as data rather than
# owning it as a resource, for the identical reason given there.

data "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = var.monitoring_namespace
  }
}
