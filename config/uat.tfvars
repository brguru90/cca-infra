# See config/integration.tfvars for how this file is applied.

environment = "uat"
region      = "asia-india"

backend_node_port = 3311
admin_node_port   = 3302

backend_min_replicas = 1
backend_max_replicas = 3
admin_min_replicas   = 1
admin_max_replicas   = 2

mongo_members = 1
