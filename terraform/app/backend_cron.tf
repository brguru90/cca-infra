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
#
# Deliberately singleton: replicas = 1 below, no HPA anywhere in this project
# targets this Deployment. A second replica would double-run every cron.New()
# schedule (ClearExpiredToken, VideoStreamGenerationCron - see
# src/app_cron_jobs/init_cron_jobs.go) and duplicate change-stream handling.
# Only `backend` (backend_api.tf) is ever HPA-scaled.
#
# `-micro_service video_processing` is NOT a Deployment (see backend_video
# CronJob below for why) - it's a one-shot batch job: main.go's switch-case
# calls app_cron_jobs.VideoStreamGeneration(true) directly and returns,
# exiting the process once the queue drains. A Deployment would crash-loop
# it forever for no benefit.
#
# It is reached WITHOUT going through VideoStreamGenerationCron() (the
# function InitCronJobs schedules here, every minute) - that function is
# what branches on APP_ENV to either process inline (development) or call
# my_modules.StartVMInstance() to boot a hardcoded, project-specific Google
# Compute Engine VM (production). This project's home server does not use
# GCE at all (see backend_video below) - VideoStreamGeneration() itself has
# no GCE code, so invoking it directly, on a schedule, sidesteps that branch
# entirely and does real local ffmpeg encoding regardless of APP_ENV.
#
# That means this Deployment's own scheduled VideoStreamGenerationCron tick
# will still occasionally attempt StartVMInstance() in production (whenever
# it observes an unstarted queued video before backend_video's CronJob has
# claimed it) - this fails harmlessly (compute.NewInstancesRESTClient errors
# cleanly with no GCP credentials configured, wrapped and logged, never
# fatal - see src/my_modules/google_cloud.go) and is left as-is rather than
# patched, since suppressing it would require a submodule code change (a new
# env-gated flag) that hasn't been confirmed - see IMPLEMENTATION_PLAN.md.

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

# Real local video encoding, run entirely on this home server - never GCE.
# A CronJob (not a Deployment) is the correct primitive here because
# `-micro_service video_processing` is a one-shot batch process (see the
# comment above `backend_cron`): it does whatever's queued, then exits 0.
#
# concurrency_policy = "Forbid" is what actually satisfies "only one
# instance of video_processing should run" - Kubernetes will skip starting
# a new Job if the previous one from this CronJob is still running, rather
# than stacking overlapping ffmpeg encodes (each already spawns
# runtime.NumCPU()*4 threads per src/my_modules/video_streaming.go - two of
# those running at once on a single home server would thrash badly).
resource "kubernetes_cron_job_v1" "backend_video" {
  count = var.enable_video_worker ? 1 : 0

  metadata {
    name      = "backend-video"
    namespace = local.namespace
    labels    = merge(local.common_labels, local.version_label, { "app.kubernetes.io/name" = "backend-video" })
  }

  spec {
    schedule                      = var.video_worker_schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3

    job_template {
      metadata {
        labels = merge(local.common_labels, local.version_label, { "app.kubernetes.io/name" = "backend-video" })
      }

      spec {
        backoff_limit = 1 # per-video failures are logged and skipped internally, not something a Job retry fixes

        template {
          metadata {
            labels = merge(local.common_labels, local.version_label, { "app.kubernetes.io/name" = "backend-video" })
          }

          spec {
            restart_policy = "Never"

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
    }
  }

  depends_on = [terraform_data.secrets_present]
}
