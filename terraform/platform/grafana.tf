# Repository note: like `loki`, the `grafana` chart also migrated from
# grafana.github.io/helm-charts to grafana-community.github.io/helm-charts -
# verified directly against both repos rather than assumed.
#
# Admin password: `admin.existingSecret` points at a Secret created by
# scripts/apply-secrets.sh (from the GRAFANA_ADMIN_PASSWORD GitHub Secret,
# production environment only per IMPLEMENTATION_PLAN.md §8) - Terraform
# never sees the password value, same pattern as every other secret in this
# project.

resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "grafana"
  version    = var.grafana_chart_version
  namespace  = data.kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [
    yamlencode({
      admin = {
        existingSecret = "cca-grafana-admin"
        userKey        = "admin-user"
        passwordKey    = "admin-password"
      }

      service = {
        type     = "NodePort"
        nodePort = var.grafana_node_port
        # Dual-stack for the same reason every app NodePort is dual-stack -
        # see terraform/app/backend_api.tf.
        ipFamilyPolicy = "RequireDualStack"
        ipFamilies     = ["IPv4", "IPv6"]
      }

      persistence = {
        enabled          = true
        size             = "2Gi"
        storageClassName = "local-path"
      }

      "datasources" = {
        "datasources.yaml" = {
          apiVersion = 1
          datasources = [
            {
              name      = "Loki"
              type      = "loki"
              access    = "proxy"
              url       = "http://loki.${data.kubernetes_namespace_v1.monitoring.metadata[0].name}.svc.cluster.local:3100"
              isDefault = true
            }
          ]
        }
      }
    })
  ]

  # 900s (15min), not the default 300s: verified against the real cluster -
  # this home connection took 5m18s just to pull the 458MB
  # grafana/grafana:*-distroless image on a cold cache, which alone blew
  # through the 300s default (see mongodb-operator.tf's comment).
  timeout = 900
  replace = true # see mongodb-operator.tf's comment on why this matters for retries after a timeout

  depends_on = [helm_release.loki]
}
