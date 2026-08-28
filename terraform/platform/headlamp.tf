# Headlamp - a pure Kubernetes state VIEWER, added specifically to avoid the
# problem ArgoCD would introduce here: ArgoCD's whole value is git-driven
# reconciliation (it diffs live state against git-declared manifests and can
# auto-correct drift), but this project's app layer is 100% Terraform-owned
# HCL, not raw manifests/Helm for ArgoCD to sync against - adopting it would
# mean either rewriting terraform/app as Helm charts, or running a second
# reconciler that can fight Terraform the exact same way this project already
# had to solve once for the HPA (see backend_api.tf's lifecycle.ignore_changes
# comment). Headlamp has no reconciliation loop at all - it only reads and
# (if you choose to use its edit UI) writes on direct user action, so it can
# never independently "correct" something Terraform just set. See
# IMPLEMENTATION_PLAN.md for the fuller ArgoCD-vs-alternatives writeup this
# addition came out of.
#
# Repository note: the project moved from headlamp-k8s/headlamp to
# kubernetes-sigs/headlamp (verified directly - the old headlamp-k8s.github.io
# Pages site is gone entirely) - matches this file's own comment on
# var.headlamp_chart_version. Don't revert to the old URL.

resource "helm_release" "headlamp" {
  name       = "headlamp"
  repository = "https://kubernetes-sigs.github.io/headlamp/"
  chart      = "headlamp"
  version    = var.headlamp_chart_version
  namespace  = data.kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [
    yamlencode({
      serviceAccount = {
        create = true
        # Pinned explicitly rather than relying on the chart's templated
        # default name, so platform.yml's token-generation step
        # (kubectl create token) has a fixed, documented target instead of
        # having to reverse-engineer the chart's naming convention.
        name = "headlamp"
      }

      # The chart's own default is cluster-admin - deliberately downgraded
      # to the builtin read-only "view" ClusterRole. This is meant purely
      # for looking at cluster state (see the header comment) - it doesn't
      # need, and shouldn't have, write access to anything.
      clusterRoleBinding = {
        create          = true
        clusterRoleName = "view"
      }

      service = {
        type = "NodePort"
        port = 80
        # IPv4 only - the chart's Service template has no ipFamilyPolicy/
        # ipFamilies field to set (unlike this project's own Services), and
        # dual-stack reachability isn't worth extra complexity for a
        # debugging-only dashboard. Accepted trade-off, not an oversight.
        nodePort = var.headlamp_node_port
      }
    })
  ]

  timeout = 900  # see mongodb-operator.tf's comment - generous headroom for a cold image-pull cache
  replace = true # see mongodb-operator.tf's comment on why this matters for retries after a timeout
}
