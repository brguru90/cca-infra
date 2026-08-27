# See config/integration.tfvars for how this file is applied.

environment = "production"
region      = "asia-india"

backend_node_port = 3411
admin_node_port   = 3402

backend_min_replicas = 2
backend_max_replicas = 4
admin_min_replicas   = 1
admin_max_replicas   = 3

# Still 1 by default even in production - bump deliberately via a one-line
# change here (see terraform/app/variables.tf's mongo_members validation and
# IMPLEMENTATION_PLAN.md's MongoDB decision for why this isn't automatic).
mongo_members = 1

enable_video_worker = false
