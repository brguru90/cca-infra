# Loki in Monolithic mode with filesystem storage.
#
# Repository note: as of March 16, 2026 the OSS `loki` chart moved from
# grafana.github.io/helm-charts to grafana-community.github.io/helm-charts
# (forked at chart 6.55.0); the chart still published at the old URL is now
# maintained for Grafana Enterprise Logs users only. Verified directly
# against both repos' chart sources rather than assumed - do not revert this
# to grafana.github.io/helm-charts.
#
# `deploymentMode: Monolithic` is the current name for what older chart
# versions (and some of this chart's own stale comments) call "SingleBinary"
# - it targets small installs without HA, which is exactly this one-node
# home server. The chart's defaults target its OTHER two modes
# (SimpleScalable, Distributed) and object storage; every override below
# exists to pull it back to a single filesystem-backed binary.
#
# IMPORTANT: this chart version defaults `singleBinary.replicas` to 0 (a
# deliberate default so an external autoscaler/rollout-operator can own
# replica count without Helm fighting it) - easy to miss, and skipping it
# means Loki deploys with zero pods. Set explicitly to 1.

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_chart_version
  namespace  = data.kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [
    yamlencode({
      deploymentMode = "Monolithic"

      loki = {
        auth_enabled = false
        commonConfig = { replication_factor = 1 }
        storage      = { type = "filesystem" }

        schemaConfig = {
          configs = [
            {
              from         = "2024-01-01"
              store        = "tsdb"
              object_store = "filesystem"
              schema       = "v13"
              index        = { prefix = "index_", period = "24h" }
            }
          ]
        }

        limits_config = {
          retention_period          = var.loki_retention_period
          ingestion_rate_mb         = 8
          allow_structured_metadata = true
        }

        compactor = {
          retention_enabled    = true
          delete_request_store = "filesystem"
        }
      }

      singleBinary = {
        replicas = 1 # chart default is 0 - see note above
        persistence = {
          enabled      = true
          size         = "10Gi"
          storageClass = "local-path" # K3s's bundled default StorageClass
        }
      }

      # Everything below targets the chart's SimpleScalable/Distributed
      # topologies or extra sidecars this project doesn't need - off.
      gateway      = { enabled = false }
      minio        = { enabled = false }
      chunksCache  = { enabled = false }
      resultsCache = { enabled = false }
      lokiCanary   = { enabled = false }
      test         = { enabled = false }

      # `enabled = false` alone is NOT enough for the SimpleScalable targets:
      # the chart's own templates/validate.yaml checks `replicas` directly,
      # independent of `enabled`, and errors ("You have more than zero
      # replicas configured for both the monolithic and simple scalable
      # targets") if these still carry their chart-default replicas (3) while
      # deploymentMode is Monolithic. Learned this the hard way against the
      # real cluster - `enabled: false` was silently insufficient on its own.
      backend = { enabled = false, replicas = 0 }
      read    = { enabled = false, replicas = 0 }
      write   = { enabled = false, replicas = 0 }
    })
  ]

  timeout = 900  # see mongodb-operator.tf's comment - generous headroom for a cold image-pull cache
  replace = true # see mongodb-operator.tf's comment on why this matters for retries after a timeout
}
