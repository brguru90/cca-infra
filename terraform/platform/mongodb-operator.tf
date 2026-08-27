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

  # 900s (15min), not the default 300s: this home connection took over
  # 5 minutes just to pull Grafana's 458MB image on a cold cache (see
  # grafana.tf) - generous headroom for any chart's first-ever image pull.
  timeout = 900

  # A `helm_release` whose create times out still leaves a real release
  # record in the cluster (Helm creates it before waiting for readiness) -
  # Terraform's own state doesn't know that, since the errored apply never
  # got to write it. The next apply then tries a fresh create and fails with
  # "cannot re-use a name that is still in use", even though the release is
  # often actually healthy underneath by then. Hit this for real against
  # this cluster - `replace = true` (~ `helm install --replace`) makes a
  # retry self-healing instead of requiring a manual `helm uninstall` first.
  # The provider's own schema flags this "unsafe in production" (it force-
  # replaces a release even if genuinely still active elsewhere) - acceptable
  # here: single apply path, one operator, a one-time cluster bootstrap.
  replace = true
}
