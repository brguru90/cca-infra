variable "region" {
  type    = string
  default = "asia-india"
}

variable "monitoring_namespace" {
  type    = string
  default = "cca-monitoring"
}

variable "grafana_node_port" {
  type        = number
  description = "Grafana NodePort. 3900 - inside the 3200-4000 range, clear of every app port (3202/3211/3302/3311/3402/3411) and of K3s/flannel's own ports (6443, 8472, which sit outside this narrowed range entirely)."
  default     = 3900
}

variable "mongo_operator_chart_version" {
  type        = string
  description = "mongodb/community-operator Helm chart version. Check https://github.com/mongodb/helm-charts/releases for newer releases before bumping - this is a real upgrade rollout, not just a metadata change."
  default     = "0.13.0"
}

variable "loki_chart_version" {
  type        = string
  description = "grafana-community/helm-charts 'loki' chart version. As of March 2026 the OSS Loki chart moved from grafana.github.io/helm-charts (now GEL-only) to grafana-community.github.io/helm-charts - see loki.tf for the repository URL and why it matters."
  default     = "18.11.3"
}

variable "alloy_chart_version" {
  type        = string
  description = "grafana/helm-charts 'alloy' chart version - this one did NOT migrate, still published from grafana.github.io/helm-charts (sourced from the grafana/alloy repo directly)."
  default     = "1.12.0"
}

variable "grafana_chart_version" {
  type        = string
  description = "grafana-community/helm-charts 'grafana' chart version - also migrated off grafana.github.io/helm-charts, see grafana.tf."
  default     = "13.0.0"
}

variable "headlamp_node_port" {
  type        = number
  description = "Headlamp NodePort. 3901 - right next to Grafana's 3900, inside the 3200-4000 range, clear of every app/Grafana port and K3s/flannel's own ports."
  default     = 3901
}

variable "headlamp_chart_version" {
  type        = string
  description = "kubernetes-sigs/headlamp Helm chart version. Check https://github.com/kubernetes-sigs/headlamp/releases (charts/headlamp) for newer releases before bumping - the project moved from headlamp-k8s/headlamp to kubernetes-sigs/headlamp; verify the repo URL in headlamp.tf still resolves before assuming this is still current."
  default     = "0.45.0"
}

variable "loki_retention_period" {
  type        = string
  description = "How long Loki keeps logs. Home-lab sizing - keep this short so a single small disk doesn't fill up."
  default     = "168h" # 7 days
}
