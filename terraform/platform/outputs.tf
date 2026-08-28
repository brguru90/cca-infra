output "monitoring_namespace" {
  value = data.kubernetes_namespace_v1.monitoring.metadata[0].name
}

output "grafana_url" {
  value = "http://<server-address>:${var.grafana_node_port}/"
}

output "headlamp_url" {
  value = "http://<server-address>:${var.headlamp_node_port}/"
}

output "mongo_operator_release" {
  value = helm_release.mongodb_operator.name
}
