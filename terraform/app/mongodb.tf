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

# The MongoDB Community Operator (terraform/platform/mongodb-operator.tf)
# runs with operator.watchNamespace = "*", which grants the OPERATOR itself
# cluster-wide permission to watch MongoDBCommunity CRs - it does NOT grant
# the resulting database StatefulSet's own Pods anywhere to run. The
# operator's own chart only templates that Pod's ServiceAccount/Role/
# RoleBinding (name defaults to "mongodb-database" - see
# community-operator/templates/database_roles.yaml in the chart source) into
# its OWN release namespace (cca-monitoring), a single fixed namespace, not
# every namespace it might watch. Hit this for real on the first live apply:
# the operator accepted the CR fine, then failed to create cca-mongodb-0 with
# "serviceaccount \"mongodb-database\" not found" in cca-integration, and the
# backend/backend-cron Deployments sat in CreateContainerConfigError waiting
# on a connection-string Secret that MongoDB was never going to produce.
# These three resources are copied verbatim (same name, same Role rules)
# from that chart template so mongo's own Pod can actually start in THIS
# namespace, applied once per environment alongside the CR itself.
resource "kubernetes_service_account_v1" "mongodb_database" {
  metadata {
    name      = "mongodb-database"
    namespace = local.namespace
  }
}

resource "kubernetes_role_v1" "mongodb_database" {
  metadata {
    name      = "mongodb-database"
    namespace = local.namespace
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["patch", "delete", "get"]
  }
}

resource "kubernetes_role_binding_v1" "mongodb_database" {
  metadata {
    name      = "mongodb-database"
    namespace = local.namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.mongodb_database.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.mongodb_database.metadata[0].name
    namespace = local.namespace
  }
}

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

  depends_on = [
    kubernetes_service_account_v1.mongodb_database,
    kubernetes_role_binding_v1.mongodb_database,
  ]
}

# External access for debugging with MongoDB Compass/mongosh from outside
# the cluster. Deliberately a SEPARATE Service, not a change to the
# operator-generated "cca-mongodb-svc" headless Service (that one is owned
# and reconciled by the MongoDB Community Operator itself, not Terraform -
# editing it here would fight the operator on every reconcile). Kubernetes
# allows multiple Services to target the same Pods via an identical
# selector, so this is additive and doesn't touch the operator's own
# resource at all. Selector value verified directly against the live
# cluster's actual headless Service, not assumed.
#
# SCRAM auth (this file's `security.authentication.modes`) already gates
# every connection - this Service only adds network reachability, not a new
# credential. Still, a database port reachable from the public internet is
# a materially different risk than the app's own HTTP NodePorts: database
# ports are common scan/brute-force targets, and this reuses the same
# single password as backend API access. Accepted trade-off for a
# home-lab/debugging use case - see docs/RUNBOOK.md for the connection
# string (directConnection=true is required - see that doc for why).
resource "kubernetes_service_v1" "mongodb_external" {
  metadata {
    name      = "cca-mongodb-external"
    namespace = local.namespace
    labels    = local.common_labels
  }

  spec {
    selector = { app = "cca-mongodb-svc" }

    ip_family_policy = "RequireDualStack"
    ip_families      = ["IPv4", "IPv6"]

    type = "NodePort"

    port {
      port        = 27017
      target_port = 27017
      node_port   = var.mongo_node_port
    }
  }
}
