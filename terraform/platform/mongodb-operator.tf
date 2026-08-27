# Installs the MongoDB Community Operator ONCE, cluster-wide, and registers
# the MongoDBCommunity CRD that every terraform/app root's mongodb.tf depends
# on. `operator.watchNamespace = "*"` is load-bearing: without it, the
# chart's own RBAC templates (operator_roles.yaml) create a namespaced
# Role/RoleBinding scoped only to var.monitoring_namespace, and the operator
# would never see MongoDBCommunity resources created in cca-integration/
# cca-uat/cca-production. Setting it to "*" makes the same templates emit a
# ClusterRole/ClusterRoleBinding instead - verified against the chart source
# (mongodb/helm-charts, charts/community-operator/templates/operator_roles.yaml)
# rather than assumed.
#
# CRDs are installed automatically by this chart's community-operator-crds
# subchart dependency - no separate `kubectl apply` step needed.

resource "helm_release" "mongodb_operator" {
  name       = "community-operator"
  repository = "https://mongodb.github.io/helm-charts"
  chart      = "community-operator"
  version    = var.mongo_operator_chart_version
  namespace  = data.kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [
    yamlencode({
      operator = {
        watchNamespace = "*"
      }
    })
  ]

  timeout = 300
}
