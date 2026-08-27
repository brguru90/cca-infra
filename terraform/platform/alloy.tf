# Alloy (DaemonSet, the chart's default controller.type) collects logs via
# the Kubernetes API (`loki.source.kubernetes`) rather than tailing
# /var/log/pods on the host - no hostPath mounts, no log-rotation/symlink
# edge cases to handle, and on a single-node home server the extra API load
# this approach costs is negligible.
#
# Label choice is deliberate: `cca_environment` / `cca_region` are Loki
# STREAM labels (low cardinality, one value per environment/region - fine).
# `cca_version` is intentionally NOT promoted to a stream label anywhere in
# this pipeline - every deploy would mint a brand-new log stream and
# fragment Loki's index, which is the exact anti-pattern Loki's own docs
# warn about for immutable per-deploy versioning like this project's. If a
# version-scoped query is ever needed, filter on `allow_structured_metadata`
# (enabled in loki.tf) or `kubectl get pods -l cca_version=...` in tandem
# with a plain namespace/app-scoped Loki query.
#
# Label key note: Alloy turns Kubernetes label `cca_environment` into target
# label `__meta_kubernetes_pod_label_cca_environment` (dots in label keys
# would produce ambiguous meta-label names, so this project's own Deployment/
# Pod labels use underscores throughout - see terraform/app/locals.tf).

locals {
  alloy_config = <<-EOT
    discovery.kubernetes "pods" {
      role = "pod"
    }

    discovery.relabel "cca" {
      targets = discovery.kubernetes.pods.targets

      rule {
        source_labels = ["__meta_kubernetes_namespace"]
        target_label  = "namespace"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_name"]
        target_label  = "pod"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_container_name"]
        target_label  = "container"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
        target_label  = "app"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_label_cca_environment"]
        target_label  = "environment"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_label_cca_region"]
        target_label  = "region"
      }
      rule {
        source_labels = ["__meta_kubernetes_namespace"]
        regex         = "cca-.*|kube-system"
        action        = "keep"
      }
    }

    loki.source.kubernetes "pods" {
      targets    = discovery.relabel.cca.output
      forward_to = [loki.write.default.receiver]
    }

    loki.write "default" {
      endpoint {
        url = "http://loki.${data.kubernetes_namespace_v1.monitoring.metadata[0].name}.svc.cluster.local:3100/loki/api/v1/push"
      }
      external_labels = {
        cluster = "home-lab",
      }
    }
  EOT
}

resource "helm_release" "alloy" {
  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.alloy_chart_version
  namespace  = data.kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [
    yamlencode({
      alloy = {
        configMap = {
          create  = true
          content = local.alloy_config
        }
      }
      controller = {
        type = "daemonset"
      }
    })
  ]

  timeout = 300

  depends_on = [helm_release.loki]
}
