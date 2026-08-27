# syntax=docker/dockerfile:1.7
#
# cca_admin_frontend image — a Create React App (react-scripts 4.0.3) build
# served by nginx. No Dockerfile exists upstream today.
#
# IMPORTANT: there is no build-time API URL variable anywhere in this app's
# source. Every API call is a same-origin relative path (`/api/...`) - grep the
# whole src/ tree, there is not a single `REACT_APP_*` reference. That means
# ONE image built here serves every environment (integration/uat/production);
# the only environment-specific piece is which backend nginx proxies `/api/` to,
# and that is supplied at deploy time via a Kubernetes ConfigMap
# (kubernetes/nginx/admin-default.conf.tpl), never baked into this image.
#
# The app uses `homepage: "."` (relative asset paths) and HashRouter, so it
# also does not care whether it's served from `/` or a subpath, and doesn't
# strictly need SPA history-API fallback - but we include it anyway since it's
# a one-line, zero-cost safety net.

FROM node:16-alpine AS builder

# python3/make/g++ cover any node-gyp native rebuilds among CRA4's transitive
# deps (there's no committed node-sass here, but keeping this avoids surprise
# failures from anything else in the dependency tree that does need to compile).
# Unpinned deliberately - see docker/backend/Dockerfile's identical note.
# hadolint ignore=DL3018
RUN apk add --no-cache git python3 make g++

WORKDIR /app

# yarn.lock only - there is no package-lock.json upstream (.gitignore excludes
# it), so `npm ci` will fail here. Use yarn with a frozen lockfile so the build
# fails loudly on any drift instead of silently resolving new versions.
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile --network-timeout 600000

COPY . .

# CI=false: CRA4 (react-scripts) treats ESLint warnings as build-breaking
# errors when CI=true, which most CI runners (including GitHub Actions) set
# automatically. This codebase's own `lint` script ends `;exit 0`, i.e. lint
# is not meant to be a hard gate here.
# GENERATE_SOURCEMAP=false: don't ship source maps (and thus source) to the
# public internet from a home-lab admin panel.
# NODE_OPTIONS=--max-old-space-size: react-scripts 4 / webpack 4 on Node 16 can
# OOM on constrained hosts (this ends up running on a single home server
# alongside everything else) without a higher heap ceiling.
ENV CI=false \
    GENERATE_SOURCEMAP=false \
    NODE_OPTIONS=--max-old-space-size=3072

RUN yarn build && test -f build/index.html

# ---------------------------------------------------------------------------

FROM nginx:1.27-alpine

# Deliberately remove the stock server block. This image ships with NO nginx
# server config of its own - the real one (with the /api reverse-proxy circuit
# breaker to the backend Service, see IMPLEMENTATION_PLAN.md §9.1) is mounted
# from a Kubernetes ConfigMap at /etc/nginx/conf.d/admin.conf at deploy time
# (see terraform/app/configmap_nginx.tf and
# kubernetes/nginx/admin-default.conf.tpl).
#
# This is an intentional fail-loud choice: a standalone `docker run` of this
# image starts nginx with zero server blocks, so any request gets a connection
# refused / no matching server, rather than silently looking "fine" while
# serving assets with no working /api proxy underneath. Test this image
# together with the ConfigMap, not in isolation.
RUN rm -f /etc/nginx/conf.d/default.conf

COPY --from=builder /app/build /usr/share/nginx/html

EXPOSE 80
