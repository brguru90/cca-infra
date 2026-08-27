# cca_backend's Redis client hardcodes an empty password and DB index 0
# (src/database/database_connections/connect.redis.go), and calls log.Panic on
# any connection failure - in every -micro_service mode, even when
# ENABLE_REDIS_CACHE=false. There is no way to disable this dependency from
# configuration. One unauthenticated Redis per namespace (not shared across
# environments - the app doesn't support per-env DB indexes either) is the
# simplest thing that actually boots the app.
#
# No persistence: this is purely a cache in front of Mongo, per
# ENABLE_REDIS_CACHE/RESPONSE_CACHE_TTL_IN_SECS - losing it on pod restart is
# fine, so `--save "" --appendonly no` and an emptyDir, not a PVC.

resource "kubernetes_deployment_v1" "redis" {
  metadata {
    name      = "redis"
    namespace = local.namespace
    labels    = merge(local.common_labels, { "app.kubernetes.io/name" = "redis" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = { "app.kubernetes.io/name" = "redis" }
    }

    template {
      metadata {
        labels = merge(local.common_labels, { "app.kubernetes.io/name" = "redis" })
      }

      spec {
        container {
          name  = "redis"
          image = "redis:7-alpine"

          args = [
            "--save", "",
            "--appendonly", "no",
            "--maxmemory", "128mb",
            "--maxmemory-policy", "allkeys-lru",
          ]

          port {
            container_port = 6379
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "160Mi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          readiness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "data"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "redis" {
  metadata {
    name      = "redis"
    namespace = local.namespace
    labels    = local.common_labels
  }

  spec {
    selector = { "app.kubernetes.io/name" = "redis" }

    port {
      port        = 6379
      target_port = 6379
    }
  }
}
