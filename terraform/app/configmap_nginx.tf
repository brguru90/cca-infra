resource "kubernetes_config_map_v1" "admin_nginx" {
  metadata {
    name      = "admin-nginx"
    namespace = local.namespace
    labels    = local.common_labels
  }

  data = {
    "admin.conf" = templatefile("${path.module}/../../kubernetes/nginx/admin-default.conf.tpl", {
      backend_service = "backend"
      backend_port    = var.backend_container_port
    })
  }
}
