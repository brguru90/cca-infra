# cca_admin_frontend needs zero secrets and zero build-time configuration
# (see IMPLEMENTATION_PLAN.md §1) - the only environment-specific piece is
# the nginx config mounted from configmap_nginx.tf, which points /api/ at
# this namespace's own `backend` Service.

resource "kubernetes_deployment_v1" "admin_frontend" {
  metadata {
    name      = "admin-frontend"
    namespace = local.namespace
    labels    = merge(local.common_labels, local.version_label, { "app.kubernetes.io/name" = "admin-frontend" })
  }

  spec {
    replicas = var.admin_min_replicas

    selector {
      match_labels = { "app.kubernetes.io/name" = "admin-frontend" }
    }

    template {
      metadata {
        labels = merge(local.common_labels, local.version_label, { "app.kubernetes.io/name" = "admin-frontend" })
      }

      spec {
        container {
          name  = "admin-frontend"
          image = var.admin_image
          # See backend_api.tf's identical note: this image is imported
          # straight into K3s's containerd store on this same host right
          # after being built, and a brand-new GHCR tag's anonymous-pull ACL
          # can 403 for a long time right after first push.
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 80
          }

          volume_mount {
            name       = "nginx-conf"
            mount_path = "/etc/nginx/conf.d/admin.conf"
            sub_path   = "admin.conf"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "300m"
              memory = "128Mi"
            }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            period_seconds    = 5
            failure_threshold = 3
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 20
          }
        }

        volume {
          name = "nginx-conf"
          config_map {
            name = kubernetes_config_map_v1.admin_nginx.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].replicas]
  }
}

resource "kubernetes_service_v1" "admin_frontend" {
  metadata {
    name      = "admin-frontend"
    namespace = local.namespace
    labels    = local.common_labels
  }

  spec {
    selector = { "app.kubernetes.io/name" = "admin-frontend" }

    ip_family_policy = "RequireDualStack"
    ip_families      = ["IPv4", "IPv6"]

    type = "NodePort"

    port {
      port        = 80
      target_port = 80
      node_port   = var.admin_node_port
    }
  }
}
