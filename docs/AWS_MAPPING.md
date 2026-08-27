# AWS concept mapping

Carried over from `final-plan.md` §36 as a learning aid - this project's
stated goal includes learning system design/AWS concepts, and this home-lab
setup deliberately makes the mechanics visible instead of hiding them behind
a managed service. Not exhaustive, and some rows are aspirational (not built
in this branch) - marked accordingly.

| AWS concept | This project's equivalent | Where |
|---|---|---|
| ECS/EKS | K3s | `scripts/install-k3s.sh` |
| ECS Service | Kubernetes Deployment | `terraform/app/backend_api.tf`, `admin_frontend.tf` |
| ALB / target group health checks | Kubernetes Service + readiness probes | `terraform/app/backend_api.tf` |
| Auto Scaling Group | HorizontalPodAutoscaler | `terraform/app/hpa.tf` |
| EC2 instance | The physical home server (future: a KVM VM) | - |
| ECR | GHCR (`ghcr.io/brguru90/...`) | `.github/workflows/deploy.yml` |
| Secrets Manager | Kubernetes Secrets, applied outside Terraform state | `scripts/apply-secrets.sh` |
| CloudWatch Logs | Loki | `terraform/platform/loki.tf` |
| CloudWatch Metrics | Metrics Server (bundled with K3s; Prometheus would be the fuller equivalent - not built here) | `terraform/platform/mongodb-operator.tf`'s neighbor, `.github/workflows/platform.yml`'s verify step |
| CloudWatch dashboards | Grafana | `terraform/platform/grafana.tf` |
| CloudWatch Alarms / auto-remediation | The deployment circuit breaker (health-check-triggered auto-rollback) | `scripts/health-check.sh` |
| S3 | *(not built)* - MinIO or local storage would be the equivalent if the backend's upload paths ever move off local disk | - |
| RDS | *(not built)* - MongoDB via the MongoDB Community Operator plays the managed-database role here | `terraform/app/mongodb.tf` |
| Multi-AZ | *(not built)* - MongoDB's replica-set member count (`mongo_members`) is the closest analog, scaled manually | `terraform/app/variables.tf` |
| Region | `region = "asia-india"` - a label today, since there's only one physical server | `terraform/app/variables.tf` |
| Availability Zone / multi-node cluster | *(deferred)* - would require KVM + multiple VMs running additional K3s nodes; explicitly out of scope until single-node Pod autoscaling is proven out first | - |
| CloudFront / WAF | *(not built)* - a reverse proxy (Caddy/Traefik/Cloudflare) in front of the NodePorts would be the next step if this ever needs to leave `http://` | - |
| Terraform (AWS or otherwise) | Terraform, targeting the Kubernetes + Helm providers instead of an AWS provider | `terraform/app/`, `terraform/platform/` |
| CodePipeline/CodeDeploy | GitHub Actions (`workflow_dispatch`) | `.github/workflows/deploy.yml` |
