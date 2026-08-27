output "namespace" {
  value = local.namespace
}

output "deployment_version" {
  value = var.deployment_version
}

output "backend_url" {
  description = "Reachable over the home server's public IPv6 GUA or its LAN IPv4 address, on this NodePort."
  value       = "http://<server-address>:${var.backend_node_port}/api/health_check"
}

output "admin_frontend_url" {
  value = "http://<server-address>:${var.admin_node_port}/"
}

output "backend_image" {
  value = var.backend_image
}

output "admin_image" {
  value = var.admin_image
}

output "mongo_members" {
  value = var.mongo_members
}
