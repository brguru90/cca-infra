# Applied via:
#   terraform -chdir=terraform/app apply -var-file="../../config/integration.tfvars" \
#     -var="deployment_version=..." -var="backend_image=..." -var="admin_image=..."
# (deployment_version/backend_image/admin_image are supplied per-run by
# .github/workflows/deploy.yml, not hardcoded here - see IMPLEMENTATION_PLAN.md.)

environment = "integration"
region      = "asia-india"

backend_node_port = 3211
admin_node_port   = 3202
mongo_node_port   = 3213

backend_min_replicas = 1
backend_max_replicas = 3
admin_min_replicas   = 1
admin_max_replicas   = 2

mongo_members = 1
