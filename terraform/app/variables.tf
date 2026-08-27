variable "environment" {
  type        = string
  description = "Deployment environment. Also determines the namespace (cca-<environment>)."

  validation {
    condition     = contains(["integration", "uat", "production"], var.environment)
    error_message = "environment must be one of: integration, uat, production."
  }
}

variable "region" {
  type        = string
  description = "Physical deployment region label. Only one region exists today (a single home server); this is a label/output for now, not a lever."
  default     = "asia-india"

  validation {
    condition     = var.region == "asia-india"
    error_message = "Only asia-india is currently supported - there is one physical server."
  }
}

variable "deployment_version" {
  type        = string
  description = "Immutable deployment version, e.g. v2026.08.26.143015-production-r184. Applied as a label on every resource this root creates."
}

variable "backend_image" {
  type        = string
  description = "Full backend image reference, e.g. ghcr.io/brguru90/cca-backend:v2026.08.26.143015-production-r184"
}

variable "admin_image" {
  type        = string
  description = "Full admin-frontend image reference, e.g. ghcr.io/brguru90/cca-admin-frontend:v2026.08.26.143015-production-r184"
}

# --- Networking ---------------------------------------------------------
# NodePorts are pinned per environment (never left to the Kubernetes
# allocator - see IMPLEMENTATION_PLAN.md's "NodePort range" decision for why:
# the cluster's service-node-port-range is 3200-4000, and an unpinned Service
# could otherwise be handed a port that collides with something else in that
# range).

variable "backend_node_port" {
  type        = number
  description = "NodePort for the backend API Service. integration=3211, uat=3311, production=3411."
}

variable "admin_node_port" {
  type        = number
  description = "NodePort for the admin-frontend Service. integration=3202, uat=3302, production=3402."
}

variable "backend_container_port" {
  type        = number
  description = "Port the backend process listens on inside the container (SERVER_PORT). Same across all environments; only the NodePort differs."
  default     = 8700
}

# --- Autoscaling ----------------------------------------------------------

variable "backend_min_replicas" {
  type        = number
  description = "Backend HPA minReplicas, and the Deployment's initial replica count (Terraform ignores drift on this field after creation - see backend_api.tf lifecycle block)."
  default     = 1
}

variable "backend_max_replicas" {
  type        = number
  description = "Backend HPA maxReplicas."
  default     = 4
}

variable "backend_cpu_target_percent" {
  type        = number
  description = "Backend HPA target average CPU utilization."
  default     = 60
}

variable "admin_min_replicas" {
  type    = number
  default = 1
}

variable "admin_max_replicas" {
  type    = number
  default = 3
}

variable "admin_cpu_target_percent" {
  type    = number
  default = 70
}

# --- MongoDB ----------------------------------------------------------------

variable "mongo_members" {
  type        = number
  description = "Replica set member count for this environment's MongoDBCommunity resource. A real replica set (so change-stream-dependent cron_job mode works), scaled manually by bumping this variable - NOT autoscaled. See IMPLEMENTATION_PLAN.md 'MongoDB' decision for why: the operator's CRD has no /scale subresource, and reactive scaling of a quorum-based store on load is a real risk (full resync per added member; even member counts are a worse voting topology than odd)."
  default     = 1

  validation {
    condition     = var.mongo_members >= 1 && var.mongo_members % 2 == 1
    error_message = "mongo_members must be an odd number >= 1 (replica set voting requires an odd member count once above 1)."
  }
}

variable "mongo_storage_size" {
  type        = string
  description = "Per-member PVC size for MongoDB data."
  default     = "5Gi"
}

variable "mongo_version" {
  type        = string
  description = "MongoDB server version the MongoDBCommunity resource runs. Pin explicitly and bump deliberately - the operator performs a real upgrade rollout on change."
  default     = "7.0.14"
}

# --- Worker (backend-cron) ---------------------------------------------------

variable "enable_video_worker" {
  type        = bool
  description = "Whether to also deploy the -micro_service video_processing Deployment. Off by default; the cron worker (backend-cron) always deploys."
  default     = false
}
