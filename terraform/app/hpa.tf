# CPU-utilization HPAs for the two Deployments that can safely run more than
# one replica (backend API, admin-frontend). backend-cron and backend-video
# are deliberately excluded - see backend_cron.tf for why a second cron
# replica would double-run jobs.
#
# Metrics Server ships with K3s by default and is unaffected by
# `--disable=traefik`/`--disable=servicelb` (independent components) - no
# separate install is needed. Verify with:
#   kubectl get apiservice v1beta1.metrics.k8s.io
#   kubectl top pods -n <namespace>
# If TARGETS shows <unknown> in `kubectl get hpa`, the usual cause is a
# container missing `resources.requests.cpu` - both Deployments below set it.

resource "kubernetes_horizontal_pod_autoscaler_v2" "backend" {
  metadata {
    name      = "backend"
    namespace = local.namespace
    labels    = local.common_labels
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.backend.metadata[0].name
    }

    min_replicas = var.backend_min_replicas
    max_replicas = var.backend_max_replicas

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.backend_cpu_target_percent
        }
      }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "admin_frontend" {
  metadata {
    name      = "admin-frontend"
    namespace = local.namespace
    labels    = local.common_labels
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.admin_frontend.metadata[0].name
    }

    min_replicas = var.admin_min_replicas
    max_replicas = var.admin_max_replicas

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.admin_cpu_target_percent
        }
      }
    }
  }
}
