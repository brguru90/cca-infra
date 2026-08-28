# Rendered into a ConfigMap by terraform/app/configmap_nginx.tf (via
# templatefile()) and mounted into the admin-frontend container at
# /etc/nginx/conf.d/admin.conf. The admin-frontend image itself ships NO
# server block (see docker/admin-frontend/Dockerfile) - this file is the only
# thing that makes it serve anything.
#
# Because cca_admin_frontend has no build-time API URL variable at all (every
# API call is a same-origin relative path, see IMPLEMENTATION_PLAN.md §1),
# this same template - with only ${backend_service} substituted - works for
# every environment. The environment-specific piece lives entirely here, not
# in the image.

upstream backend_upstream {
  # Circuit breaker (IMPLEMENTATION_PLAN.md §9.1): after 3 failed attempts to
  # this upstream, nginx marks it unavailable for 10s and fails fast instead
  # of continuing to hammer a struggling/restarting backend.
  server ${backend_service}:${backend_port} max_fails=3 fail_timeout=10s;
}

server {
  # Real bug, caught live: a bare `listen 80;` only binds nginx's IPv4
  # wildcard socket - unlike Go's net/http (backend_api.tf's server), nginx
  # does NOT implicitly dual-stack a plain port directive. The Service/
  # EndpointSlice/ip6tables DNAT for this Pod's IPv6 address were all
  # correctly wired (verified directly against the live cluster), but
  # nginx itself was never listening on it - external IPv6 clients got a
  # real kernel-level "Connection refused" on the Pod's own IPv6 address,
  # not a network/routing failure. `ipv6only=off` in the SAME `[::]:80`
  # listener would create one dual-stack socket, but K3s's dual-stack
  # design here already gives each Pod distinct IPv4 and IPv6 addresses
  # via separate EndpointSlices - two explicit listeners (one per address
  # family) matches that model directly, rather than fighting it.
  listen 80;
  listen [::]:80;
  server_name _;

  root /usr/share/nginx/html;
  index index.html;

  location / {
    try_files $uri $uri/ /index.html;
  }

  location /api/ {
    # No trailing slash on proxy_pass's target - this preserves the /api
    # prefix on the upstream request (nginx only strips the matched location
    # prefix when proxy_pass's URI part is non-empty, i.e. ends in "/services/"
    # style). cca_admin_frontend's setupProxy.js comments out pathRewrite,
    # meaning the backend expects /api/... intact - stripping it here would
    # 404 every request.
    proxy_pass http://backend_upstream;

    proxy_next_upstream error timeout http_502 http_503 http_504;
    proxy_connect_timeout 3s;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
