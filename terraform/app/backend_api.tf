# Non-secret backend configuration. Real secret values (JWT_SECRET_KEY,
# RAZORPAY_KEY_ID/SECRET) live in the Secret named local.backend_secret_name,
# created by scripts/apply-secrets.sh - never in this ConfigMap, never in
# Terraform state. Shared by the API Deployment (this file), the cron worker,
# and the optional video worker (backend_cron.tf).
resource "kubernetes_config_map_v1" "backend_env" {
  metadata {
    name      = "backend-env"
    namespace = local.namespace
    labels    = local.common_labels
  }

  data = {
    # No code default exists for SERVER_PORT (configs.EnvConfigs.SERVER_PORT
    # is parsed from os.Getenv with strconv.ParseInt; unset/invalid becomes 0,
    # binding :0). Must be set, and must match backend_container_port below,
    # the container's EXPOSE, and every probe.
    SERVER_PORT = tostring(var.backend_container_port)

    GIN_MODE      = var.environment == "production" ? "release" : "debug"
    DISABLE_COLOR = "true"
    APP_ENV       = var.environment == "production" ? "production" : "development"
    NODE_ENV      = var.environment == "production" ? "production" : "development"

    ENABLE_REDIS_CACHE         = "true"
    RESPONSE_CACHE_TTL_IN_SECS = "300"
    JWT_TOKEN_EXPIRE_IN_MINS   = "60"

    PROTECTED_UPLOAD_PATH         = "uploads/private/"
    PROTECTED_UPLOAD_PATH_ROUTE   = "private"
    UNPROTECTED_UPLOAD_PATH       = "uploads/public/"
    UNPROTECTED_UPLOAD_PATH_ROUTE = "cdn"

    # In-cluster, unauthenticated Redis (redis.tf) - the app's client hardcodes
    # an empty password, so REDIS_ADDR is the only lever available.
    REDIS_ADDR = "redis:6379"

    # connect_mongo.go calls MONGO_DB_CONNECTION.Database(DATABASE)
    # UNCONDITIONALLY using configs.EnvConfigs.MONGO_DATABASE, regardless of
    # whether MONGO_CUSTOM_URL (mongodb.tf) was used for the connection
    # itself - the URL's own "/cca" path segment is never consulted for this.
    # Leaving this unset (empty string) makes every single collection
    # operation fail with "the Database field must be set on Operation" -
    # hit for real on the first live deploy, verified against the actual
    # cca_backend source rather than assumed. Must match mongodb.tf's
    # local.mongo_db_name (the CR's spec.users[].db).
    MONGO_DATABASE = local.mongo_db_name
  }
}

# Reused by both the API and cron Deployments (and the optional video
# worker): the app panics at boot if Redis isn't reachable yet, in every
# mode, so an initContainer wait-loop turns a startup race into a clean
# Init:0/1 wait instead of a CrashLoopBackOff with growing backoff delay.
locals {
  wait_for_redis_init_container = {
    name    = "wait-redis"
    image   = "redis:7-alpine"
    command = ["sh", "-c", "until redis-cli -h redis -p 6379 ping | grep -q PONG; do echo waiting for redis; sleep 2; done"]
  }
}

resource "kubernetes_deployment_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = local.namespace
    labels    = merge(local.common_labels, local.version_label, { "app.kubernetes.io/name" = "backend" })
  }

  spec {
    # Seed value only. The HPA (hpa.tf) is the real owner of replica count
    # from here on - see the lifecycle block below.
    replicas = var.backend_min_replicas

    selector {
      match_labels = { "app.kubernetes.io/name" = "backend" }
    }

    template {
      metadata {
        labels = merge(local.common_labels, local.version_label, { "app.kubernetes.io/name" = "backend" })
      }

      spec {
        init_container {
          name    = local.wait_for_redis_init_container.name
          image   = local.wait_for_redis_init_container.image
          command = local.wait_for_redis_init_container.command
        }

        container {
          name  = "backend"
          image = var.backend_image
          # IfNotPresent, not the default-for-explicit-tags behavior alone:
          # deploy.yml's build-backend job imports this exact image straight
          # into K3s's containerd store on this same host right after
          # building it (see that step's comment) - the Pod should never hit
          # the network for an image that's already sitting right here, and
          # anonymous pulls from a brand-new GHCR tag can 403 for 10-20+
          # minutes right after first push (hit for real on this project's
          # first live deploys) before that ACL propagates.
          image_pull_policy = "IfNotPresent"

          # No hardcoded -micro_service in the image (see
          # docker/backend/Dockerfile) - this is what makes this Deployment
          # the API server rather than the cron worker.
          args = ["-micro_service", "api_server"]

          port {
            container_port = var.backend_container_port
          }

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

          # The MongoDB Community Operator generates this Secret (mongodb.tf
          # pins its name via connectionStringSecretName) with keys
          # `connectionString.standard` / `connectionString.standardSrv`.
          # Referenced here by secretKeyRef so Terraform never reads its
          # value - kubelet resolves the reference at pod start, which also
          # means this Deployment can be planned before the operator has
          # actually created the Secret; the pod simply won't become Ready
          # until it exists. .standard (not .standardSrv) is used
          # deliberately: SRV records need working DNS resolution against a
          # headless Service, which is one more moving part than a 1-member
          # replica set needs.
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

          # Persistent, shared across every backend/backend-cron/backend-video
          # replica (see storage.tf for why ReadWriteOnce is safe here).
          # Without this, PROTECTED_UPLOAD_PATH/UNPROTECTED_UPLOAD_PATH write
          # to the container's ephemeral layer.
          volume_mount {
            name       = "uploads"
            mount_path = "/web_app/uploads"
          }

          resources {
            # Explicit requests are required for the HPA's CPU-utilization
            # target to resolve at all - a Deployment with no cpu request
            # shows HPA TARGETS as <unknown> forever (see hpa.tf).
            requests = {
              cpu    = "150m"
              memory = "192Mi"
            }
            limits = {
              cpu    = "1"
              memory = "512Mi"
            }
          }

          # The health_check route (GET /api/health_check) has no active
          # gating middleware today - the User-Agent check some earlier notes
          # assumed exists is actually commented-out dead code in
          # src/middlewares/middlewares.go. We still send an explicit
          # User-Agent for clarity in nginx/app logs, not because it's
          # required.
          startup_probe {
            http_get {
              path = "/api/health_check"
              port = var.backend_container_port
              http_header {
                name  = "User-Agent"
                value = "kube-probe/cca"
              }
            }
            period_seconds    = 3
            failure_threshold = 20 # ~60s boot budget on top of the Redis wait
          }

          readiness_probe {
            http_get {
              path = "/api/health_check"
              port = var.backend_container_port
              http_header {
                name  = "User-Agent"
                value = "kube-probe/cca"
              }
            }
            period_seconds    = 5
            timeout_seconds   = 3
            failure_threshold = 3
          }

          liveness_probe {
            http_get {
              path = "/api/health_check"
              port = var.backend_container_port
              http_header {
                name  = "User-Agent"
                value = "kube-probe/cca"
              }
            }
            period_seconds        = 20
            timeout_seconds       = 3
            failure_threshold     = 3
            initial_delay_seconds = 10
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

  # HPA (hpa.tf) is the sole owner of replica count once the Deployment
  # exists. Without this, every `terraform apply` would read the HPA's live
  # replica count as drift and scale back down to backend_min_replicas,
  # fighting the autoscaler on every deploy. Same reasoning applies to
  # scripts/ops.sh's `scale`/`stop` actions - Terraform must never revert
  # them either.
  lifecycle {
    ignore_changes = [spec[0].replicas]
  }

  depends_on = [terraform_data.secrets_present]
}

resource "kubernetes_service_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = local.namespace
    labels    = local.common_labels
  }

  spec {
    selector = { "app.kubernetes.io/name" = "backend" }

    # Dual-stack so the NodePort binds on both 0.0.0.0 and :: - required for
    # the cluster to actually be reachable over the public IPv6 the DDNS
    # record advertises (see scripts/install-k3s.sh).
    ip_family_policy = "RequireDualStack"
    ip_families      = ["IPv4", "IPv6"]

    type = "NodePort"

    port {
      port        = var.backend_container_port
      target_port = var.backend_container_port
      node_port   = var.backend_node_port
    }
  }
}
