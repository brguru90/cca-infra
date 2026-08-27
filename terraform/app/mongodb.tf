# One real MongoDB replica set per environment via the MongoDB Community
# Operator. This is deliberately NOT a standalone/single-node mongod: the
# backend's cron_job worker
# (cca_backend/src/database/triggers - TriggerForUsersModification) uses
# MongoDB change streams, which require a replica set. members=1 still
# satisfies that (a 1-member replica set is a real, if minimal, replica set).
#
# ORDERING DEPENDENCY: this resource requires the MongoDBCommunity CRD to
# already be registered in the cluster, which terraform/platform installs
# (once, cluster-wide) by Helm-installing the MongoDB Community Operator.
# `kubernetes_manifest` validates against the live cluster's CRD schema at
# *plan* time, so `terraform plan` in this root will fail outright if
# terraform/platform hasn't been applied yet. See docs/RUNBOOK.md for the
# required apply order (platform once, then app per environment).
#
# Scaling: var.mongo_members is a plain Terraform variable, bumped manually
# and deliberately - see variables.tf and IMPLEMENTATION_PLAN.md's "MongoDB"
# decision for why this is not HPA-driven autoscaling (no /scale subresource
# on this CRD, and reactive scaling of a quorum-based store on load is a real
# risk, not just an implementation gap).

resource "kubernetes_manifest" "mongodb" {
  manifest = {
    apiVersion = "mongodbcommunity.mongodb.com/v1"
    kind       = "MongoDBCommunity"

    metadata = {
      name      = "cca-mongodb"
      namespace = local.namespace
      labels    = local.common_labels
    }

    spec = {
      members = var.mongo_members
      type    = "ReplicaSet"
      version = var.mongo_version

      security = {
        authentication = {
          modes = ["SCRAM"]
        }
      }

      users = [
        {
          name = local.mongo_user_name
          db   = local.mongo_db_name

          passwordSecretRef = {
            name = local.mongo_user_password_secret_name
          }

          roles = [
            { name = "readWrite", db = local.mongo_db_name },
            # change streams (used by the cron_job worker) require this role
            # in addition to readWrite on the target database.
            { name = "clusterMonitor", db = "admin" },
          ]

          scramCredentialsSecretName = "cca-mongo-scram"

          # Pinned explicitly rather than relying on the operator's default
          # <resource-name>-<db>-<user> naming, so backend_api.tf's
          # secretKeyRef target is stable and doesn't depend on remembering
          # the operator's naming convention.
          connectionStringSecretName = local.mongo_connection_secret_name
        }
      ]

      statefulSet = {
        spec = {
          volumeClaimTemplates = [
            {
              metadata = { name = "data-volume" }
              spec = {
                accessModes = ["ReadWriteOnce"]
                resources = {
                  requests = { storage = var.mongo_storage_size }
                }
              }
            }
          ]
        }
      }
    }
  }
}
