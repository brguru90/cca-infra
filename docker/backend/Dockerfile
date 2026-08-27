# syntax=docker/dockerfile:1.7
#
# cca_backend image — replaces the upstream single-stage Dockerfile, which:
#   - never copies ./env, so the Firebase service-account file is missing at runtime
#   - hardcodes `ENTRYPOINT ["./go_server","-micro_service","cron_job"]`, i.e. the
#     image as shipped runs the WORKER, not the API
#   - bakes real secrets in as ENV instructions
#
# This image instead leaves the role (api_server | cron_job | video_processing) to
# the container `args:` set by Kubernetes (see terraform/app/backend_api.tf and
# backend_cron.tf), and takes all configuration from env vars supplied by a
# ConfigMap + Secret at deploy time. See IMPLEMENTATION_PLAN.md and
# docs/SECURITY.md for why no secret is baked into this file.
#
# go.sum is gitignored upstream (see cca_backend/.gitignore), so there is no
# committed lockfile to `go mod download` against. We fall back to `go mod tidy`
# at build time, which requires network access during the build and is NOT
# reproducible byte-for-byte across builds if a dependency publishes a new patch
# release in between. The durable fix is a companion PR to cca_backend committing
# go.sum — see IMPLEMENTATION_PLAN.md §12 (explicitly deferred, not this repo's
# call to make unilaterally). Once that lands, delete the `go mod tidy` fallback
# below and use `go mod download` only.

FROM golang:1.19-alpine AS builder

RUN apk add --no-cache git ca-certificates

WORKDIR /src

COPY go.mod ./
# go.sum may not exist upstream (see note above) - COPY with a glob so the build
# doesn't fail when it's absent, then branch on its presence.
COPY go.sum* ./

RUN --mount=type=cache,target=/go/pkg/mod \
    if [ -f go.sum ]; then \
      echo ">>> go.sum present: go mod download (reproducible)"; \
      go mod download; \
    else \
      echo ">>> go.sum absent upstream: falling back to go mod tidy (non-reproducible, network required)"; \
      go mod tidy; \
    fi

COPY . .

ARG APP_VERSION=dev

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -trimpath \
      -ldflags="-s -w -X main.buildVersion=${APP_VERSION}" \
      -o /out/server ./src/main.go

# ---------------------------------------------------------------------------

FROM alpine:3.20

# ffmpeg on Alpine ships ffprobe in the same package. Both are required at
# runtime: init_cron_jobs.go and video_streaming.go shell out to them whenever
# APP_ENV != "development". curl is required for the health-check workflow
# steps (scripts/health-check.sh execs into the pod) and is convenient for
# in-cluster debugging. The `ffprobe -version` line is a build-time assertion,
# not decoration - it fails the image build if the package didn't actually
# provide ffprobe.
RUN apk add --no-cache ffmpeg curl ca-certificates tzdata \
    && ffprobe -version >/dev/null \
    && addgroup -S -g 10001 app \
    && adduser -S -D -u 10001 -G app -h /web_app app

WORKDIR /web_app

COPY --from=builder /out/server /web_app/server

# The current source COPYs nothing else into the image; ./env/ (which holds the
# Firebase service-account JSON, plus dev-only .env/.env_prod files) is supplied
# at deploy time as a Kubernetes Secret volume mount at
# /web_app/env/cca-vijayapura-firebase-adminsdk-ghz2d-1f8e7ad071.json (see
# terraform/app/backend_api.tf - mounted with `sub_path` so it doesn't shadow
# anything else placed under ./env). We still create the directory here so a
# `docker run` without the mount fails with a clear "no such file" from the
# Firebase SDK instead of a directory-not-found surprise.
RUN mkdir -p /web_app/env \
    && mkdir -p /web_app/frontend/build \
    && mkdir -p /web_app/uploads/private /web_app/uploads/public \
    && chown -R app:app /web_app

USER app:app

# SERVER_PORT has no code default (configs.EnvConfigs.SERVER_PORT is parsed from
# os.Getenv("SERVER_PORT") with strconv.ParseInt; an unset/invalid value becomes
# 0, and the server binds :0, a random port). It is set explicitly in the
# ConfigMap and MUST match this EXPOSE and the container's readiness/liveness
# probe port. 8700 is this project's convention (see IMPLEMENTATION_PLAN.md §7).
EXPOSE 8700

# No hardcoded -micro_service flag: Kubernetes `args:` selects the role.
#   backend      Deployment -> args: ["-micro_service", "api_server"]
#   backend-cron Deployment -> args: ["-micro_service", "cron_job"]
# Running with no args at all defaults to "all" (API + cron in one process),
# per src/main.go's `flag.String("micro_service", "all", ...)` - fine for local
# `docker run` smoke testing, never used by the Kubernetes manifests.
ENTRYPOINT ["/web_app/server"]
