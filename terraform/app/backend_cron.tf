# The cron worker (-micro_service cron_job) runs a MongoDB change-stream
# trigger (src/database/triggers) plus scheduled jobs (InitCronJobs) and never
# starts an HTTP listener - so it has no readiness probe (nothing selects it
# on a Service; there's nothing to gate) and no HTTP liveness probe.
#
# What it DOES still need: the same Redis-panic and Firebase-panic hazards as
# the API (src/main.go runs configs.InitEnv/database.InitDataBases/
# my_modules.InitFirebase for every -micro_service value, including
# cron_job), so it gets the same initContainer and Firebase Secret mount.
#
# Change streams require a real replica set, which is why mongodb.tf runs the
# MongoDB Community Operator rather than a standalone mongod even at
# members=1 - a standalone instance would make this Deployment silently never
# fire.

resource "kubernetes_deployment_v1" "backend_cron" {
  metadata {
    name      = "backend-cron"
    namespace = local.namespace
    labels    = merge(local.common_labels, local.version_label, { "app.kubernetes.io/name" = "backend-cron" })
  }

  spec {
    replicas = 1 # never autoscaled - a second replica would double-run cron jobs and duplicate change-stream handling

    selector {
      match_labels = { "app.kubernetes.io/name" = "backend-cron" }
    }

    template {
      metadata {
        labels = merge(local.common_labels, local.version_label, { "app.kubernetes.io/name" = "backend-cron" })
      }

      spec {
        init_container {
          name    = local.wait_for_redis_init_container.name
          image   = local.wait_for_redis_init_container.image
          command = local.wait_for_redis_init_container.command
        }

        container {
          name  = "backend-cron"
          image = var.backend_image
          args  = ["-micro_service", "cron_job"]

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.backend_env.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = local.backend_secret_name
            }
          }

          env {
            name = "MONGO_CUSTOM_URL"
            value_from {
              secret_key_ref {
                name = local.mongo_connection_secret_name
                key  = "connectionString.standard"
              }
            }
          }

          volume_mount {
            name       = "firebase-sa"
            mount_path = "/web_app/env/${local.firebase_json_filename}"
            sub_path   = local.firebase_json_filename
            read_only  = true
          }

          # Shared with the API Deployment - see backend_api.tf and storage.tf.
          volume_mount {
            name       = "uploads"
            mount_path = "/web_app/uploads"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "384Mi"
            }
          }

          # There is no HTTP listener to probe in this mode. A `pgrep`-style
          # exec probe would only confirm the process hasn't exited, which is
          # already what Kubernetes' default restartPolicy: Always covers -
          # it wouldn't detect an actually-hung worker, just add a second
          # restart trigger for the same failure mode. Instead this is
          # honestly framed as a DEPENDENCY probe, not a health probe: if
          # Redis becomes unreachable after startup, the app's own
          # log.Panic will already have crashed the process, so in practice
          # this rarely fires - it exists as a second line of defense with a
          # generous period so it doesn't mask a real crash loop behind
          # constant restarts.
          liveness_probe {
            exec {
              command = ["sh", "-c", "redis-cli -h redis -p 6379 ping | grep -q PONG"]
            }
            initial_delay_seconds = 30
            period_seconds        = 60
            failure_threshold     = 3
          }
        }

        volume {
          name = "firebase-sa"
          secret {
            secret_name  = local.firebase_secret_name
            default_mode = "0444"
          }
        }

        volume {
          name = "uploads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.backend_uploads.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [terraform_data.secrets_present]
}

# Optional -micro_service video_processing worker. Off by default
# (var.enable_video_worker) - most environments don't need it, and it's the
# same image/config shape as the cron worker with a different `args`.
resource "kubernetes_deployment_v1" "backend_video" {
  count = var.enable_video_worker ? 1 : 0

  metadata {
    name      = "backend-video"
    namespace = local.namespace
    labels    = merge(local.common_labels, local.version_label, { "app.kubernetes.io/name" = "backend-video" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = { "app.kubernetes.io/name" = "backend-video" }
    }

    template {
      metadata {
        labels = merge(local.common_labels, local.version_label, { "app.kubernetes.io/name" = "backend-video" })
      }

      spec {
        init_container {
          name    = local.wait_for_redis_init_container.name
          image   = local.wait_for_redis_init_container.image
          command = local.wait_for_redis_init_container.command
        }

        container {
          name  = "backend-video"
          image = var.backend_image
          args  = ["-micro_service", "video_processing"]

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.backend_env.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = local.backend_secret_name
            }
          }

          env {
            name = "MONGO_CUSTOM_URL"
            value_from {
              secret_key_ref {
                name = local.mongo_connection_secret_name
                key  = "connectionString.standard"
              }
            }
          }

          volume_mount {
            name       = "firebase-sa"
            mount_path = "/web_app/env/${local.firebase_json_filename}"
            sub_path   = local.firebase_json_filename
            read_only  = true
          }

          # Shared with the API Deployment - see backend_api.tf and storage.tf.
          # Load-bearing for this worker specifically: video processing reads
          # and writes under the same upload paths.
          volume_mount {
            name       = "uploads"
            mount_path = "/web_app/uploads"
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1500m"
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "firebase-sa"
          secret {
            secret_name  = local.firebase_secret_name
            default_mode = "0444"
          }
        }

        volume {
          name = "uploads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.backend_uploads.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [terraform_data.secrets_present]
}
