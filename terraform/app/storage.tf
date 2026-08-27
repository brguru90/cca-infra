# Persistent storage for cca_backend's upload paths (PROTECTED_UPLOAD_PATH /
# UNPROTECTED_UPLOAD_PATH, both under ./uploads/ relative to the container's
# WORKDIR - see docker/backend/Dockerfile). Without this, uploaded files live
# on the container's ephemeral writable layer: lost on every pod restart, and
# invisible to any OTHER replica once the backend HPA scales past 1.
#
# ReadWriteOnce is fine here specifically BECAUSE this is a single-node K3s
# cluster (see IMPLEMENTATION_PLAN.md) - RWO constrains a PVC to being mounted
# by pods on one node at a time, not to one pod at a time. Every backend/
# backend-cron/backend-video Pod is scheduled on the same (only) node, so they
# can all mount this PVC concurrently. This assumption breaks the moment a
# second node joins the cluster (see final-plan.md's later-phase KVM/
# multi-node notes) - revisit to an RWX-capable storage class (e.g. NFS) or
# real object storage (S3-compatible/GCS, per both plan docs' original "leave
# GCS external" recommendation) before that happens.
#
# K3s's bundled `local-path` provisioner backs this with a hostPath directory
# on the node - fine for a home-lab, but note it is NOT backed up by
# scripts/backup-state.sh (that only covers Terraform state). Back up
# /var/lib/rancher/k3s/storage/ separately if these uploads matter.

resource "kubernetes_persistent_volume_claim_v1" "backend_uploads" {
  metadata {
    name      = "backend-uploads"
    namespace = local.namespace
    labels    = local.common_labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"

    resources {
      requests = {
        storage = var.backend_uploads_storage_size
      }
    }
  }

  # local-path does not support volume expansion - growing
  # backend_uploads_storage_size later requires manually deleting and
  # recreating this PVC (and its data), not a plain `terraform apply`.

  # MUST be false: K3s's bundled local-path StorageClass uses
  # volumeBindingMode: WaitForFirstConsumer - it won't provision/bind a
  # volume until a Pod that actually mounts this PVC gets scheduled. The
  # provider's default (wait_until_bound = true) makes Terraform block this
  # resource's own create on reaching Bound, which deadlocks: the backend/
  # backend-cron Deployments that would supply that consuming Pod are
  # themselves ordered after this PVC (they reference its name), so nothing
  # ever gets scheduled to unblock it. Hit this for real - the PVC create sat
  # for 10 minutes before erroring, and backend/backend-cron never even
  # started. Skipping the wait here is safe: Kubernetes itself still handles
  # the real binding once the Deployment's Pod is scheduled - Terraform just
  # doesn't need to sit and watch it happen.
  wait_until_bound = false
}
