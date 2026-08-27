# Requirements
```
implement terraform for below & deploy it to docker container in home machine(Ubuntu 24 & it has docker running),

assume i have it repo, i will merge my changes to main branch, & there will be a github actions will be triggered manually to deploy the changes in main branch to my home server,
my home server is running remotely, it has public ipv6 support & ddns is configured to -> travel-planner.ddns.net. host name,so make sure GitHub Actions uses public ipv6 network to communicate with my server,
make sure it provides following features

- on each manual deploy, tag each build/state/version
- easy revert to any of old tag/state/version
- secret/environment variable management
- configure application logging system, similer to cloaudwatch logging in aws
- demonstrate deployment to different environment like integration,UAT & production
- demonstrate the region based deployment, currently i only have one home server consider it as india/asia region
- assume you will be deploying the applications in https://github.com/users/brguru90/projects/4(https://github.com/brguru90/cca_backend, https://github.com/brguru90/cca_frontend, https://github.com/brguru90/cca_admin_frontend)
- in addition to build & deploy (int,uat & prod from main), rollback(int,uat & prod to tag/version), stop applications in environment, restart applications in environment etc
```


Yes. For your setup, I would build this as a **small private infrastructure/deployment repository** that controls your home Docker host, while the three application repositories remain independent.

There is one important correction to the earlier design:

> **Do not make GitHub Actions talk directly to the Docker API.**
> Let GitHub Actions connect to the home server over SSH/IPv6, and run Terraform **on the home server**. Terraform then talks to the local Docker socket.

That gives you:

```text
                    GitHub
                      │
                  workflow_dispatch
                      │
                      ▼
               GitHub Actions
                      │
                  SSH -6
                      │
                      ▼
        travel-planner.ddns.net
                      │
                      ▼
                Ubuntu 24
                      │
              ┌───────┴───────┐
              │               │
          Terraform          Docker
              │               │
              └──────► Docker socket
                              │
             ┌────────────────┼────────────────┐
             ▼                ▼                ▼
          backend          frontend          admin
```

This also means you don't need to expose Docker's remote API on the Internet.

One caveat: GitHub's standard hosted runners are documented with dynamic IP ranges, but GitHub does **not** document guaranteed IPv6 egress for `ubuntu-latest`. Therefore I would explicitly test IPv6 and **fail the deployment rather than silently falling back to IPv4**. ([GitHub Docs][1])

For a strict guarantee of IPv6-originated deployment traffic, a dedicated dual-stack runner outside the home network is the stronger architecture. A self-hosted runner on the home server would be safer from an inbound-network perspective, but would no longer demonstrate the public-IPv6 SSH path you specifically asked for. GitHub also recommends against self-hosted runners for public repositories because workflow code can compromise the runner. ([GitHub Docs][2])

---

# 1. First: fix a security problem in the current repositories

I inspected the current repositories.

`cca_backend` currently has database credentials, JWT-related secrets, Redis configuration, and a payment secret directly in its public Dockerfile. 

Your backend repository is public. ([GitHub][3])

The admin frontend also has `.env` and `.env_prod` files tracked in the public repository. ([GitHub][4])

So **before deploying this architecture, rotate any credentials that have actually been real credentials** and remove secrets from Dockerfiles/repositories.

Do not merely delete them in a new commit: the old values are already in Git history.

The new architecture should be:

```text
Git repository
    │
    └── no passwords/secrets

GitHub Secrets
    │
    ▼
Deployment workflow
    │
    ▼
/srv/cca/secrets/<environment>/backend.env
    │
    ▼
Docker container
```

The secret file never needs to be part of Terraform state.

---

# 2. The architecture I recommend

Use a fourth repository:

```text
github.com/brguru90/cca-infra
```

Your repositories become:

```text
brguru90/
├── cca_backend
├── cca_frontend
├── cca_admin_frontend
└── cca-infra
```

The responsibilities are:

```text
cca_backend
    → backend source

cca_frontend
    → Flutter frontend source

cca_admin_frontend
    → admin frontend source

cca-infra
    → Dockerfiles/deployment metadata
    → Terraform
    → GitHub Actions
    → environment definitions
    → operational scripts
```

You don't have to move application code into `cca-infra`.

---

# 3. Desired architecture

We'll treat your one physical server as:

```text
Region = asia-india
```

and logically create:

```text
                      Home Server
                   Region: asia-india
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
         ▼                 ▼                 ▼
   integration           UAT             production
         │                 │                 │
    ┌────┼────┐       ┌────┼────┐       ┌────┼────┐
    ▼    ▼    ▼       ▼    ▼    ▼       ▼    ▼    ▼
  API   WEB  ADMIN   API   WEB  ADMIN   API   WEB  ADMIN
```

For now each environment gets different host ports:

```text
                     Backend   Frontend   Admin
integration           8101       3101     3102
uat                   8201       3201     3202
production            8301       3301     3302
```

So initially:

```text
http://travel-planner.ddns.net:3101
http://travel-planner.ddns.net:3201
http://travel-planner.ddns.net:3301
```

and so on.

Later we can put Caddy/Traefik/Nginx in front and move to:

```text
https://travel-planner.ddns.net/
https://travel-planner.ddns.net/uat/
https://travel-planner.ddns.net/admin/
```

or separate subdomains.

---

# 4. Deployment flow

A normal deployment will be:

```text
You merge into main
        │
        │
        ▼
cca-infra → Actions → Run workflow manually
        │
        ▼
choose:
  environment = integration
  region      = asia-india
  action      = deploy
        │
        ▼
checkout:
  cca_backend/main
  cca_frontend/main
  cca_admin_frontend/main
        │
        ▼
build Docker images
        │
        ▼
push images to GHCR
        │
        ▼
create immutable deployment version
        │
        ▼
SSH -6 to home server
        │
        ▼
upload Terraform release code
        │
        ▼
Terraform init
        │
        ▼
Terraform plan
        │
        ▼
Terraform apply
        │
        ▼
Docker containers updated
        │
        ▼
health check
        │
        ▼
deployment recorded
```

For rollback:

```text
GitHub Actions
      │
      ▼
action = rollback
environment = production
version = v2026....
      │
      ▼
checkout deployment tag
      │
      ▼
SSH -6
      │
      ▼
Terraform apply with old image versions
```

No rebuild is necessary.

---

# 5. Versioning model

Every deployment gets something like:

```text
v2026.08.26.143015-production-r184
```

The version contains:

```text
v
2026.08.26
14:30:15 UTC
production
workflow run 184
```

Images:

```text
ghcr.io/brguru90/cca-backend:v2026.08.26.143015-production-r184

ghcr.io/brguru90/cca-frontend:v2026.08.26.143015-production-r184

ghcr.io/brguru90/cca-admin-frontend:v2026.08.26.143015-production-r184
```

And the infrastructure repository gets a Git tag:

```text
v2026.08.26.143015-production-r184
```

That tag points to the exact Terraform configuration used for the deployment.

This is better than a mutable `latest` tag.

---

# 6. Why the version tag is enough for rollback

Suppose:

```text
production

current:
v2026.08.26.143015-production-r184

previous:
v2026.08.26.124500-production-r181
```

Rollback means:

```text
Terraform

backend_image =
ghcr.io/brguru90/cca-backend:v2026.08.26.124500-production-r181

frontend_image =
ghcr.io/brguru90/cca-frontend:v2026.08.26.124500-production-r181

admin_image =
ghcr.io/brguru90/cca-admin-frontend:v2026.08.26.124500-production-r181
```

Terraform recreates the containers with the old immutable images.

No source rebuild.

---

# 7. Repository structure

Create:

```text
cca-infra/
│
├── .github/
│   └── workflows/
│       └── deploy.yml
│
├── terraform/
│   ├── versions.tf
│   ├── variables.tf
│   ├── locals.tf
│   ├── main.tf
│   └── outputs.tf
│
├── docker/
│   ├── backend/
│   ├── frontend/
│   └── admin/
│
├── config/
│   └── environments.yaml
│
├── scripts/
│   └── ops.sh
│
└── README.md
```

---

# 8. Install the required software on Ubuntu 24

On the home server:

```bash
sudo apt update

sudo apt install -y \
  curl \
  git \
  openssh-server \
  ca-certificates \
  gnupg \
  unzip
```

You already have Docker.

Check:

```bash
docker version
```

Create a dedicated deployment user:

```bash
sudo adduser --disabled-password --gecos "" deploy
```

Give it access to Docker:

```bash
sudo usermod -aG docker deploy
```

Log in again or run:

```bash
su - deploy
```

Check:

```bash
docker ps
```

---

# 9. Install Terraform on the home server

Install the current Terraform package from HashiCorp's official package repository.

After installation:

```bash
terraform version
```

The important thing is:

```text
GitHub Actions
       │
       ▼
SSH
       │
       ▼
terraform on home server
       │
       ▼
Docker provider
       │
       ▼
Docker socket
```

So Terraform does not need to be installed on the GitHub runner.

---

# 10. Terraform provider

Use the current `kreuzwerker/docker` provider.

The current Registry release is 4.5.0, and it manages Docker resources through the Docker API. ([Terraform Registry][5])

`terraform/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "4.5.0"
    }
  }

  backend "local" {}
}

provider "docker" {
  host = "unix:///var/run/docker.sock"
}
```

The important part is:

```hcl
host = "unix:///var/run/docker.sock"
```

because Terraform is running **on the home server**.

---

# 11. Terraform state

We'll keep separate state per environment:

```text
/srv/cca/state/
├── integration/
│   └── terraform.tfstate
├── uat/
│   └── terraform.tfstate
└── production/
    └── terraform.tfstate
```

Before every apply:

```text
current state
     │
     ▼
backup
     │
     ▼
terraform apply
```

Example:

```text
/srv/cca/state/production/backups/
├── 20260826-121000.tfstate
├── 20260826-124500.tfstate
└── ...
```

This gives you a recovery path if the state itself becomes damaged.

For larger/team deployments I would use a remote backend; Terraform's S3 backend, for example, supports state locking and recommends bucket versioning for recovery. ([HashiCorp Developer][6])

For your one-server hobby environment, local state on that server is perfectly reasonable.

---

# 12. Environment directories on the server

Create:

```bash
sudo mkdir -p /srv/cca/{state,secrets,releases}
sudo mkdir -p /srv/cca/state/{integration,uat,production}/backups
sudo mkdir -p /srv/cca/secrets/{integration,uat,production}
sudo mkdir -p /srv/cca/releases
```

Set ownership:

```bash
sudo chown -R deploy:deploy /srv/cca
```

Protect secrets:

```bash
chmod 700 /srv/cca/secrets
chmod 700 /srv/cca/secrets/*
```

---

# 13. Runtime secret management

Store something like this as a GitHub secret:

```text
BACKEND_ENV_FILE
```

Its content can be:

```dotenv
APP_ENV=production
SERVER_PORT=8000

MONGO_DB_USER=...
MONGO_DB_PASSWORD=...
MONGO_DB_HOST=...
MONGO_DATABASE=cca

REDIS_ADDR=...

JWT_SECRET_KEY=...

RAZORPAY_KEY_ID=...
RAZORPAY_KEY_SECRET=...
```

The workflow sends it to:

```text
/srv/cca/secrets/production/backend.env
```

with:

```text
0600
```

permissions.

Terraform only knows:

```text
/run/cca/backend.env
```

not the actual secret contents.

This is important because passing secret values through `docker_container.env` would put them into Terraform's managed data/state.

---

# 14. GitHub environments

Create:

```text
integration
uat
production
```

GitHub Environments can provide environment-specific secrets and variables, and production can require reviewer approval before the deployment job starts. ([GitHub Docs][7])

Recommended:

### integration

```text
approval:
none
```

### uat

```text
approval:
optional
```

### production

```text
required reviewer
```

Environment secrets are only exposed to jobs referencing the environment, and approvals delay access to those secrets. ([GitHub Docs][7])

One current GitHub limitation is important: on GitHub Free, environment secrets are not available for private repositories. If your deployment repository is private, use repository secrets with names such as `INT_BACKEND_ENV_FILE`, `UAT_BACKEND_ENV_FILE`, `PROD_BACKEND_ENV_FILE`, or use a paid GitHub plan. ([GitHub Docs][7])

For your deployment repository I strongly recommend **private**.

---

# 15. SSH key

On your development machine:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/cca-home-deploy
```

Put the public key on the server:

```bash
mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh

cat cca-home-deploy.pub >> /home/deploy/.ssh/authorized_keys

chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
```

In GitHub, store:

```text
SSH_PRIVATE_KEY
```

as a secret.

Never store it in the repo.

---

# 16. IPv6 configuration

Your DNS must have:

```text
travel-planner.ddns.net
        │
        └── AAAA → your current public IPv6
```

From any machine:

```bash
dig AAAA travel-planner.ddns.net +short
```

You should see an IPv6 address.

On Ubuntu:

```bash
ssh -6 deploy@travel-planner.ddns.net
```

should work.

This is the exact connection GitHub Actions will use:

```text
GitHub Actions
       │
       │ IPv6
       ▼
travel-planner.ddns.net
       │
       ▼
Home server
```

---

# 17. IPv6 firewall

SSH needs:

```text
TCP/22 IPv6
```

Your application ports need:

```text
3101
3102
3201
3202
3301
3302

8101
8201
8301
```

But I strongly recommend eventually exposing only:

```text
22
80
443
```

and putting Caddy/Traefik/Nginx in front of the environments.

For the first implementation, ports keep everything simple.

---

# 18. Backend Dockerfile

Your existing backend Dockerfile should **not** be used as-is because it bakes secrets into image layers. 

Replace it with something closer to:

```dockerfile
FROM golang:1.19-alpine AS builder

WORKDIR /src

COPY go.mod go.sum ./

RUN go mod download

COPY . .

RUN CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64 \
    go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/go_server \
    ./src/main.go


FROM alpine:3.22

RUN addgroup -S app && adduser -S -G app app

WORKDIR /app

COPY --from=builder /out/go_server /app/go_server

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    && chown -R app:app /app

USER app

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
```

Your `go.mod` currently declares Go 1.18, so this preserves the general compatibility direction while avoiding the development dependencies baked into the old image. 

`docker-entrypoint.sh`:

```sh
#!/bin/sh
set -eu

if [ -f /run/cca/backend.env ]; then
    set -a
    . /run/cca/backend.env
    set +a
fi

exec /app/go_server "$@"
```

Then you can run the API with:

```text
./go_server
```

and the cron worker separately with:

```text
./go_server -micro_service cron_job
```

This is cleaner than the current Dockerfile's hardcoded cron-job entrypoint. 

---

# 19. Backend worker

I recommend treating the cron job as another container:

```text
production
│
├── backend
│
└── backend-worker
```

Both use the same image:

```text
cca-backend:v123
```

but different commands.

This gives you:

```text
API failure
≠
worker failure
```

and later allows independent scaling.

---

# 20. Admin frontend Dockerfile

The admin repository is a React application using `react-scripts`. 

Add:

```text
Dockerfile
nginx.conf
```

`Dockerfile`:

```dockerfile
FROM node:18-alpine AS builder

WORKDIR /app

COPY package*.json ./

RUN npm ci --legacy-peer-deps

COPY . .

ARG REACT_APP_API_BASE_URL
ENV REACT_APP_API_BASE_URL=${REACT_APP_API_BASE_URL}

ENV NODE_OPTIONS=--openssl-legacy-provider

RUN npm run build


FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf

COPY --from=builder /app/build /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
```

`nginx.conf`:

```nginx
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

---

# 21. Flutter frontend Dockerfile

Your main frontend is Flutter, not a normal React/Vite application. Its `pubspec.yaml` currently has a Dart SDK constraint below 3.0. 

So don't blindly use the latest Flutter image.

Use a pinned Flutter version compatible with your existing source. Flutter 3.7.12 is one candidate because it uses Dart 2.x. ([GitHub][8])

A starting Dockerfile:

```dockerfile
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    libglu1-mesa \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone \
    --depth 1 \
    --branch 3.7.12 \
    https://github.com/flutter/flutter.git \
    /opt/flutter

ENV PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}"

WORKDIR /src

COPY . .

RUN flutter config --enable-web
RUN flutter pub get

ARG API_BASE_URL

RUN flutter build web \
    --release \
    --dart-define=API_BASE_URL=${API_BASE_URL}


FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf

COPY --from=builder /src/build/web /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
```

The actual Flutter app must read:

```dart
const String apiBaseUrl =
    String.fromEnvironment('API_BASE_URL');
```

or you should adapt the Docker build to your existing `env.json` mechanism. Your repository currently contains environment JSON files, so I would verify how those are consumed before changing the configuration mechanism. ([GitHub][9])

---

# 22. Terraform variables

`terraform/variables.tf`:

```hcl
variable "environment" {
  type = string

  validation {
    condition = contains(
      ["integration", "uat", "production"],
      var.environment
    )

    error_message = "Invalid environment."
  }
}

variable "region" {
  type    = string
  default = "asia-india"

  validation {
    condition     = var.region == "asia-india"
    error_message = "Only asia-india is currently supported."
  }
}

variable "deployment_version" {
  type = string
}

variable "backend_image" {
  type = string
}

variable "frontend_image" {
  type = string
}

variable "admin_image" {
  type = string
}

variable "backend_secret_file" {
  type = string
}
```

---

# 23. Terraform locals

`terraform/locals.tf`:

```hcl
locals {
  deployment_name = "${var.region}-${var.environment}"

  ports = {
    integration = {
      backend  = 8101
      frontend = 3101
      admin    = 3102
    }

    uat = {
      backend  = 8201
      frontend = 3201
      admin    = 3202
    }

    production = {
      backend  = 8301
      frontend = 3301
      admin    = 3302
    }
  }

  current_ports = local.ports[var.environment]

  network_name = "cca-${local.deployment_name}"
}
```

---

# 24. Terraform Docker network

`terraform/main.tf`:

```hcl
resource "docker_network" "app" {
  name = local.network_name
}
```

The current Docker provider supports explicit Docker network resources. ([Terraform Registry][10])

---

# 25. Pull immutable images

Use the registry data source + image resource:

```hcl
data "docker_registry_image" "backend" {
  name = var.backend_image
}

data "docker_registry_image" "frontend" {
  name = var.frontend_image
}

data "docker_registry_image" "admin" {
  name = var.admin_image
}
```

Then:

```hcl
resource "docker_image" "backend" {
  name          = data.docker_registry_image.backend.name
  pull_triggers = [data.docker_registry_image.backend.sha256_digest]
  keep_locally  = true
}

resource "docker_image" "frontend" {
  name          = data.docker_registry_image.frontend.name
  pull_triggers = [data.docker_registry_image.frontend.sha256_digest]
  keep_locally  = true
}

resource "docker_image" "admin" {
  name          = data.docker_registry_image.admin.name
  pull_triggers = [data.docker_registry_image.admin.sha256_digest]
  keep_locally  = true
}
```

Terraform's Docker provider supports registry image metadata and `keep_locally`, which is useful here because old deployment images should remain available for rollback. ([Terraform Registry][11])

---

# 26. Backend container

```hcl
resource "docker_container" "backend" {
  name  = "cca-${var.environment}-backend"
  image = docker_image.backend.image_id

  entrypoint = ["/usr/local/bin/docker-entrypoint.sh"]

  restart      = "unless-stopped"
  must_run     = true
  stop_signal  = "SIGTERM"
  stop_timeout = 30

  ports {
    internal = 8000
    external = local.current_ports.backend
    ip       = "::"
  }

  networks_advanced {
    name    = docker_network.app.name
    aliases = ["backend"]
  }

  mounts {
    type        = "bind"
    source      = var.backend_secret_file
    target      = "/run/cca/backend.env"
    read_only   = true
  }

  labels {
    label = "cca.managed"
    value = "true"
  }

  labels {
    label = "cca.environment"
    value = var.environment
  }

  labels {
    label = "cca.region"
    value = var.region
  }

  labels {
    label = "cca.version"
    value = var.deployment_version
  }

  log_driver = "local"

  log_opts = {
    "max-size" = "20m"
    "max-file" = "5"
  }
}
```

The Docker provider supports `restart`, `must_run`, `labels`, log drivers and bind mounts on `docker_container`. ([Terraform Registry][12])

Docker's `local` log driver is also recommended for preventing unbounded disk growth and performs log rotation by default. ([Docker Documentation][13])

---

# 27. Backend worker

```hcl
resource "docker_container" "worker" {
  name  = "cca-${var.environment}-worker"
  image = docker_image.backend.image_id

  entrypoint = ["/usr/local/bin/docker-entrypoint.sh"]

  command = [
    "-micro_service",
    "cron_job"
  ]

  restart      = "unless-stopped"
  must_run     = true
  stop_signal  = "SIGTERM"
  stop_timeout = 30

  networks_advanced {
    name    = docker_network.app.name
    aliases = ["worker"]
  }

  mounts {
    type      = "bind"
    source    = var.backend_secret_file
    target    = "/run/cca/backend.env"
    read_only = true
  }

  labels {
    label = "cca.managed"
    value = "true"
  }

  labels {
    label = "cca.environment"
    value = var.environment
  }

  labels {
    label = "cca.region"
    value = var.region
  }

  labels {
    label = "cca.version"
    value = var.deployment_version
  }

  log_driver = "local"

  log_opts = {
    "max-size" = "20m"
    "max-file" = "5"
  }
}
```

No public port is needed.

---

# 28. Frontend container

```hcl
resource "docker_container" "frontend" {
  name  = "cca-${var.environment}-frontend"
  image = docker_image.frontend.image_id

  restart  = "unless-stopped"
  must_run = true

  ports {
    internal = 80
    external = local.current_ports.frontend
    ip       = "::"
  }

  networks_advanced {
    name    = docker_network.app.name
    aliases = ["frontend"]
  }

  labels {
    label = "cca.managed"
    value = "true"
  }

  labels {
    label = "cca.environment"
    value = var.environment
  }

  labels {
    label = "cca.region"
    value = var.region
  }

  labels {
    label = "cca.version"
    value = var.deployment_version
  }

  log_driver = "local"

  log_opts = {
    "max-size" = "20m"
    "max-file" = "5"
  }
}
```

---

# 29. Admin container

```hcl
resource "docker_container" "admin" {
  name  = "cca-${var.environment}-admin"
  image = docker_image.admin.image_id

  restart  = "unless-stopped"
  must_run = true

  ports {
    internal = 80
    external = local.current_ports.admin
    ip       = "::"
  }

  networks_advanced {
    name    = docker_network.app.name
    aliases = ["admin"]
  }

  labels {
    label = "cca.managed"
    value = "true"
  }

  labels {
    label = "cca.environment"
    value = var.environment
  }

  labels {
    label = "cca.region"
    value = var.region
  }

  labels {
    label = "cca.version"
    value = var.deployment_version
  }

  log_driver = "local"

  log_opts = {
    "max-size" = "20m"
    "max-file" = "5"
  }
}
```

---

# 30. Environment-specific Terraform state

The workflow will create:

```text
backend.hcl
```

for integration:

```hcl
path = "/srv/cca/state/integration/terraform.tfstate"
```

For UAT:

```hcl
path = "/srv/cca/state/uat/terraform.tfstate"
```

Production:

```hcl
path = "/srv/cca/state/production/terraform.tfstate"
```

So each environment has completely independent state.

---

# 31. Central environment configuration

`config/environments.yaml`:

```yaml
region: asia-india

integration:
  backend_port: 8101
  frontend_port: 3101
  admin_port: 3102

uat:
  backend_port: 8201
  frontend_port: 3201
  admin_port: 3202

production:
  backend_port: 8301
  frontend_port: 3301
  admin_port: 3302
```

Eventually this could become:

```yaml
asia-india:
  integration:
    ...
  uat:
    ...
  production:
    ...

us:
  integration:
    ...
  uat:
    ...
  production:
    ...
```

Then the same workflow can deploy to multiple physical servers.

---

# 32. GitHub Actions workflow

`.github/workflows/deploy.yml`

```yaml
name: CCA Home Deployment

on:
  workflow_dispatch:
    inputs:
      action:
        description: Action
        required: true
        type: choice
        options:
          - deploy
          - rollback
          - stop
          - restart
          - status

      environment:
        description: Environment
        required: true
        type: choice
        options:
          - integration
          - uat
          - production

      region:
        description: Region
        required: true
        default: asia-india
        type: choice
        options:
          - asia-india

      version:
        description: Deployment version for rollback
        required: false
        type: string

permissions:
  contents: write
  packages: write

concurrency:
  group: cca-${{ inputs.region }}-${{ inputs.environment }}
  cancel-in-progress: false

jobs:
  manage:
    runs-on: ubuntu-latest

    environment: ${{ inputs.environment }}

    steps:
      - name: Install tools
        run: |
          sudo apt-get update
          sudo apt-get install -y dnsutils jq

      - name: Configure SSH
        env:
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
          SERVER_HOST: ${{ vars.SERVER_HOST }}
        run: |
          mkdir -p ~/.ssh
          chmod 700 ~/.ssh

          printf '%s\n' "$SSH_PRIVATE_KEY" > ~/.ssh/cca_home
          chmod 600 ~/.ssh/cca_home

          ssh-keyscan -6 -H "$SERVER_HOST" >> ~/.ssh/known_hosts

      - name: Verify IPv6 path
        env:
          SERVER_HOST: ${{ vars.SERVER_HOST }}
          SERVER_USER: ${{ vars.SERVER_USER }}
        run: |
          echo "Checking IPv6 connectivity from GitHub runner..."

          curl -6 --fail --max-time 10 \
            https://api64.ipify.org \
            -o /tmp/runner-ipv6

          echo "Runner IPv6:"
          cat /tmp/runner-ipv6

          echo "DNS AAAA:"
          dig AAAA "$SERVER_HOST" +short

          test -n "$(dig AAAA "$SERVER_HOST" +short)"

          ssh -6 \
            -i ~/.ssh/cca_home \
            -o BatchMode=yes \
            -o ConnectTimeout=15 \
            "${SERVER_USER}@${SERVER_HOST}" \
            'echo "IPv6 SSH connection successful"'

      - name: Status
        if: inputs.action == 'status'
        env:
          SERVER_HOST: ${{ vars.SERVER_HOST }}
          SERVER_USER: ${{ vars.SERVER_USER }}
        run: |
          ssh -6 \
            -i ~/.ssh/cca_home \
            "${SERVER_USER}@${SERVER_HOST}" \
            "/srv/cca/bin/ops.sh status '${{ inputs.environment }}'"

      - name: Stop
        if: inputs.action == 'stop'
        env:
          SERVER_HOST: ${{ vars.SERVER_HOST }}
          SERVER_USER: ${{ vars.SERVER_USER }}
        run: |
          ssh -6 \
            -i ~/.ssh/cca_home \
            "${SERVER_USER}@${SERVER_HOST}" \
            "/srv/cca/bin/ops.sh stop '${{ inputs.environment }}'"

      - name: Restart
        if: inputs.action == 'restart'
        env:
          SERVER_HOST: ${{ vars.SERVER_HOST }}
          SERVER_USER: ${{ vars.SERVER_USER }}
        run: |
          ssh -6 \
            -i ~/.ssh/cca_home \
            "${SERVER_USER}@${SERVER_HOST}" \
            "/srv/cca/bin/ops.sh restart '${{ inputs.environment }}'"
```

Then have a second job for deployment/rollback:

```yaml
  deploy:
    needs: manage
    if: inputs.action == 'deploy' || inputs.action == 'rollback'

    runs-on: ubuntu-latest

    environment: ${{ inputs.environment }}

    steps:
      # ...
```

For readability I would actually keep `manage` and `deploy` as separate jobs in your real repository rather than making one massive workflow.

GitHub's `workflow_dispatch` is the correct mechanism for manually-triggered workflows. ([GitHub Docs][14])

The concurrency group prevents two deployments to the same environment from running concurrently. ([GitHub Docs][15])

---

# 33. Build the three images

In the `deploy` job:

```yaml
      - name: Checkout infra repo
        uses: actions/checkout@v4

      - name: Checkout backend
        uses: actions/checkout@v4
        with:
          repository: brguru90/cca_backend
          ref: main
          path: sources/cca_backend

      - name: Checkout frontend
        uses: actions/checkout@v4
        with:
          repository: brguru90/cca_frontend
          ref: main
          path: sources/cca_frontend

      - name: Checkout admin frontend
        uses: actions/checkout@v4
        with:
          repository: brguru90/cca_admin_frontend
          ref: main
          path: sources/cca_admin_frontend
```

Your repositories are public and their current branches are `main`. ([GitHub][3])

---

# 34. Capture exact source versions

```yaml
      - name: Calculate deployment version
        id: version
        env:
          ENVIRONMENT: ${{ inputs.environment }}
        run: |
          BACKEND_SHA=$(git -C sources/cca_backend rev-parse HEAD)
          FRONTEND_SHA=$(git -C sources/cca_frontend rev-parse HEAD)
          ADMIN_SHA=$(git -C sources/cca_admin_frontend rev-parse HEAD)

          VERSION="v$(date -u +'%Y.%m.%d.%H%M%S')-${ENVIRONMENT}-r${GITHUB_RUN_NUMBER}"

          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          echo "backend_sha=$BACKEND_SHA" >> "$GITHUB_OUTPUT"
          echo "frontend_sha=$FRONTEND_SHA" >> "$GITHUB_OUTPUT"
          echo "admin_sha=$ADMIN_SHA" >> "$GITHUB_OUTPUT"
```

Now one deployment has:

```text
deployment version
        +
backend SHA
        +
frontend SHA
        +
admin SHA
```

This is much better than simply saying:

```text
prod = latest
```

---

# 35. Docker login

```yaml
      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
```

Then:

```yaml
      - name: Setup Buildx
        uses: docker/setup-buildx-action@v4.1.0
```

The current Docker Buildx action is v4.1.0, while build-push-action has current v7 releases. ([GitHub][16])

---

# 36. Build backend

```yaml
      - name: Build backend
        run: |
          docker buildx build \
            --platform linux/amd64 \
            --push \
            --tag ghcr.io/brguru90/cca-backend:${{ steps.version.outputs.version }} \
            ./sources/cca_backend
```

---

# 37. Build Flutter frontend

Suppose your environment API URL is:

```text
integration:
  http://travel-planner.ddns.net:8101

uat:
  http://travel-planner.ddns.net:8201

production:
  http://travel-planner.ddns.net:8301
```

You can select it in workflow:

```yaml
      - name: Set frontend API URL
        id: config
        run: |
          case "${{ inputs.environment }}" in
            integration)
              echo "api_url=http://travel-planner.ddns.net:8101" >> "$GITHUB_OUTPUT"
              ;;
            uat)
              echo "api_url=http://travel-planner.ddns.net:8201" >> "$GITHUB_OUTPUT"
              ;;
            production)
              echo "api_url=http://travel-planner.ddns.net:8301" >> "$GITHUB_OUTPUT"
              ;;
          esac
```

Then:

```yaml
      - name: Build Flutter frontend
        run: |
          docker buildx build \
            --platform linux/amd64 \
            --push \
            --build-arg API_BASE_URL="${{ steps.config.outputs.api_url }}" \
            --tag ghcr.io/brguru90/cca-frontend:${{ steps.version.outputs.version }} \
            ./sources/cca_frontend
```

---

# 38. Build admin frontend

```yaml
      - name: Build admin frontend
        run: |
          docker buildx build \
            --platform linux/amd64 \
            --push \
            --build-arg REACT_APP_API_BASE_URL="${{ steps.config.outputs.api_url }}" \
            --tag ghcr.io/brguru90/cca-admin-frontend:${{ steps.version.outputs.version }} \
            ./sources/cca_admin_frontend
```

Remember:

> Frontend variables are not secrets.

Anything embedded in a browser application can be inspected by the user.

---

# 39. Copy Terraform to server

After building:

```yaml
      - name: Package infrastructure
        run: |
          tar \
            --exclude='.git' \
            -czf infra.tar.gz \
            terraform \
            scripts \
            config
```

Then:

```yaml
      - name: Configure SSH
        env:
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
          SERVER_HOST: ${{ vars.SERVER_HOST }}
        run: |
          mkdir -p ~/.ssh
          printf '%s\n' "$SSH_PRIVATE_KEY" > ~/.ssh/cca_home
          chmod 600 ~/.ssh/cca_home
          ssh-keyscan -6 -H "$SERVER_HOST" >> ~/.ssh/known_hosts
```

Upload explicitly using IPv6:

```yaml
      - name: Upload infrastructure
        env:
          SERVER_HOST: ${{ vars.SERVER_HOST }}
          SERVER_USER: ${{ vars.SERVER_USER }}
          VERSION: ${{ steps.version.outputs.version }}
        run: |
          ssh -6 \
            -i ~/.ssh/cca_home \
            "${SERVER_USER}@${SERVER_HOST}" \
            "mkdir -p /srv/cca/releases/${VERSION}"

          scp -6 \
            -i ~/.ssh/cca_home \
            infra.tar.gz \
            "${SERVER_USER}@${SERVER_HOST}:/srv/cca/releases/${VERSION}/infra.tar.gz"
```

---

# 40. Upload runtime environment secrets

Use a GitHub environment secret called:

```text
BACKEND_ENV_FILE
```

Then:

```yaml
      - name: Upload backend environment
        env:
          SERVER_HOST: ${{ vars.SERVER_HOST }}
          SERVER_USER: ${{ vars.SERVER_USER }}
          BACKEND_ENV_FILE: ${{ secrets.BACKEND_ENV_FILE }}
          ENVIRONMENT: ${{ inputs.environment }}
        run: |
          printf '%s' "$BACKEND_ENV_FILE" |
          ssh -6 \
            -i ~/.ssh/cca_home \
            "${SERVER_USER}@${SERVER_HOST}" \
            "umask 077 && cat > /srv/cca/secrets/${ENVIRONMENT}/backend.env"
```

This avoids putting the secrets into the Terraform command line.

---

# 41. Login to GHCR on the home server

Give the home server a **read-only package token**.

GitHub secret:

```text
GHCR_PULL_TOKEN
```

Then:

```yaml
      - name: Login server to GHCR
        env:
          SERVER_HOST: ${{ vars.SERVER_HOST }}
          SERVER_USER: ${{ vars.SERVER_USER }}
          GHCR_PULL_USER: ${{ vars.GHCR_PULL_USER }}
          GHCR_PULL_TOKEN: ${{ secrets.GHCR_PULL_TOKEN }}
        run: |
          printf '%s' "$GHCR_PULL_TOKEN" |
          ssh -6 \
            -i ~/.ssh/cca_home \
            "${SERVER_USER}@${SERVER_HOST}" \
            "docker login ghcr.io -u '${GHCR_PULL_USER}' --password-stdin"
```

The server can then pull any immutable release image.

---

# 42. Execute Terraform

On the server:

```yaml
      - name: Deploy with Terraform
        env:
          SERVER_HOST: ${{ vars.SERVER_HOST }}
          SERVER_USER: ${{ vars.SERVER_USER }}
          ENVIRONMENT: ${{ inputs.environment }}
          REGION: ${{ inputs.region }}
          VERSION: ${{ steps.version.outputs.version }}
        run: |
          ssh -6 \
            -i ~/.ssh/cca_home \
            "${SERVER_USER}@${SERVER_HOST}" \
            "bash -s" <<EOF
          set -euo pipefail

          VERSION="${VERSION}"
          ENVIRONMENT="${ENVIRONMENT}"
          REGION="${REGION}"

          RELEASE_DIR="/srv/cca/releases/\${VERSION}"
          STATE_DIR="/srv/cca/state/\${ENVIRONMENT}"

          mkdir -p "\${STATE_DIR}/backups"

          tar -xzf "\${RELEASE_DIR}/infra.tar.gz" \
            -C "\${RELEASE_DIR}"

          cp -a \
            "\${RELEASE_DIR}/terraform" \
            "/srv/cca/terraform-\${VERSION}"

          rm -rf /srv/cca/terraform
          ln -s \
            "/srv/cca/terraform-\${VERSION}" \
            /srv/cca/terraform

          cd /srv/cca/terraform

          cat > backend.hcl <<BACKEND
          path = "\${STATE_DIR}/terraform.tfstate"
          BACKEND

          terraform init \
            -reconfigure \
            -backend-config=backend.hcl

          if [ -f "\${STATE_DIR}/terraform.tfstate" ]; then
            cp \
              "\${STATE_DIR}/terraform.tfstate" \
              "\${STATE_DIR}/backups/\$(date -u +%Y%m%d-%H%M%S).tfstate"
          fi

          terraform plan \
            -out=tfplan \
            -var="environment=\${ENVIRONMENT}" \
            -var="region=\${REGION}" \
            -var="deployment_version=\${VERSION}" \
            -var="backend_image=ghcr.io/brguru90/cca-backend:\${VERSION}" \
            -var="frontend_image=ghcr.io/brguru90/cca-frontend:\${VERSION}" \
            -var="admin_image=ghcr.io/brguru90/cca-admin-frontend:\${VERSION}" \
            -var="backend_secret_file=/srv/cca/secrets/\${ENVIRONMENT}/backend.env"

          terraform apply -auto-approve tfplan

          printf '%s\n' "\${VERSION}" \
            > "/srv/cca/releases/\${ENVIRONMENT}.current"

          EOF
```

This is the critical part:

```text
GitHub Actions
   │
   │ SSH -6
   ▼
Ubuntu
   │
   ▼
Terraform
   │
   ▼
local Docker API
```

---

# 43. Create the deployment tag

After Terraform succeeds:

```yaml
      - name: Tag deployment
        env:
          VERSION: ${{ steps.version.outputs.version }}
          BACKEND_SHA: ${{ steps.version.outputs.backend_sha }}
          FRONTEND_SHA: ${{ steps.version.outputs.frontend_sha }}
          ADMIN_SHA: ${{ steps.version.outputs.admin_sha }}
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

          git tag \
            -a "$VERSION" \
            -m "Deployment $VERSION

          region: ${{ inputs.region }}
          environment: ${{ inputs.environment }}

          backend:  $BACKEND_SHA
          frontend: $FRONTEND_SHA
          admin:    $ADMIN_SHA"

          git push origin "$VERSION"
```

The tag is now the deployment record.

---

# 44. Rollback workflow

User selects:

```text
Action:
rollback

Environment:
production

Version:
v2026.08.25.213500-production-r177
```

The job:

```text
fetch Git tag
     │
     ▼
checkout that tag
     │
     ▼
get corresponding Terraform version
     │
     ▼
SSH -6
     │
     ▼
terraform apply
     │
     ▼
old images
```

No rebuild.

Pseudo-command:

```bash
terraform apply \
  -auto-approve \
  -var="deployment_version=$VERSION" \
  -var="backend_image=ghcr.io/brguru90/cca-backend:$VERSION" \
  -var="frontend_image=ghcr.io/brguru90/cca-frontend:$VERSION" \
  -var="admin_image=ghcr.io/brguru90/cca-admin-frontend:$VERSION"
```

That is your rollback mechanism.

---

# 45. Stop applications

Don't use:

```bash
terraform destroy
```

because that destroys the infrastructure definition.

Instead operate the existing containers.

Create:

```text
/srv/cca/bin/ops.sh
```

```bash
#!/usr/bin/env bash

set -euo pipefail

ACTION="${1:-}"
ENVIRONMENT="${2:-}"

if [[ -z "$ACTION" || -z "$ENVIRONMENT" ]]; then
    echo "Usage: $0 {stop|restart|status} <environment>"
    exit 1
fi

case "$ENVIRONMENT" in
  integration|uat|production)
    ;;
  *)
    echo "Invalid environment"
    exit 1
    ;;
esac

FILTER=(--filter "label=cca.managed=true" --filter "label=cca.environment=${ENVIRONMENT}")

case "$ACTION" in

  stop)
    docker ps -q "${FILTER[@]}" |
      xargs -r docker stop
    ;;

  restart)
    docker ps -aq "${FILTER[@]}" |
      xargs -r docker restart
    ;;

  status)
    docker ps -a "${FILTER[@]}" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'
    ;;

  *)
    echo "Unknown action"
    exit 1
    ;;
esac
```

Make executable:

```bash
chmod +x /srv/cca/bin/ops.sh
```

Now:

```bash
./ops.sh status production
./ops.sh stop production
./ops.sh restart production
```

GitHub Actions simply calls those commands over IPv6.

---

# 46. Your GitHub Actions operations

You'll end up with:

```text
Manual workflow

Action
├── deploy
├── rollback
├── stop
├── restart
└── status

Environment
├── integration
├── uat
└── production

Region
└── asia-india

Version
└── existing version for rollback
```

So the operational UI becomes:

```text
Run workflow
─────────────────────────────

Action:
[ deploy ▼ ]

Environment:
[ production ▼ ]

Region:
[ asia-india ▼ ]

Version:
[                       ]
```

That is already a useful lightweight deployment platform.

---

# 47. Application logging — AWS CloudWatch equivalent

For your home server, I recommend:

```text
Docker
   │
   │ container logs
   ▼
Grafana Alloy
   │
   ▼
Loki
   │
   ▼
Grafana
```

Architecture:

```text
backend ─────┐
frontend ────┤
admin ───────┤
worker ──────┘
      │
      ▼
Docker Engine
      │
      ▼
Grafana Alloy
      │
      ▼
Loki
      │
      ▼
Grafana
```

Grafana currently recommends Alloy as the primary collector for sending logs to Loki, and Alloy has a Docker source specifically designed for Docker container logs. ([Grafana Labs][17])

This gives you the equivalent of:

```text
CloudWatch Logs
```

but self-hosted.

You can filter:

```text
environment=production
region=asia-india
service=backend
version=v2026...
```

---

# 48. Add labels for observability

We've already added:

```text
cca.managed=true
cca.environment=production
cca.region=asia-india
cca.version=v2026...
```

You can also add:

```text
cca.service=backend
```

Then Grafana can answer questions such as:

```text
Show production backend errors
from the last 30 minutes
for version v2026...
```

This is much closer to real production observability.

---

# 49. Grafana Alloy

Conceptually:

```text
Alloy
 │
 ├── discover Docker containers
 │
 ├── attach labels
 │
 └── send logs → Loki
```

A minimal Alloy pipeline looks like:

```hcl
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

discovery.relabel "docker_logs" {
  targets = discovery.docker.containers.targets

  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }
}

loki.source.docker "containers" {
  host          = "unix:///var/run/docker.sock"
  targets       = discovery.docker.containers.targets
  relabel_rules = discovery.relabel.docker_logs.rules

  forward_to = [loki.write.local.receiver]
}

loki.write "local" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
```

This follows the current Alloy/Loki Docker collection model. ([Grafana Labs][18])

---

# 50. Why keep Docker `local` logging as well?

Because Loki isn't your only safety net.

Use:

```text
Docker local logging
        +
Loki
```

So:

```text
container
   │
   ├── local rotated logs
   │
   └── Alloy → Loki
```

Docker recommends the `local` driver for efficient local storage and rotation. ([Docker Documentation][13])

If Loki stops, your application shouldn't become unavailable just because logging is down.

That's a small example of **fail-safe architecture**.

---

# 51. Health checks

Add an application health endpoint such as:

```text
GET /health
```

Backend:

```text
200 OK
```

Frontend:

```text
HTTP 200
```

Then after deployment:

```bash
curl -6 \
  --fail \
  http://travel-planner.ddns.net:8101/health
```

and:

```bash
curl -6 \
  --fail \
  http://travel-planner.ddns.net:3101
```

The workflow should fail if health checks don't pass.

---

# 52. Deployment sequence with health verification

Don't do:

```text
terraform apply
DONE
```

Do:

```text
terraform apply
       │
       ▼
containers start
       │
       ▼
wait 10 seconds
       │
       ▼
health checks
       │
   ┌───┴────┐
   ▼        ▼
success    failure
   │        │
   ▼        ▼
record    rollback
release
```

Eventually:

```text
new version
    │
    ▼
deploy
    │
    ▼
health check
    │
 ┌──┴──┐
 │     │
OK    FAIL
 │     │
 ▼     ▼
keep  rollback
```

That is a primitive but useful **deployment controller**.

---

# 53. Automatic rollback

Once manual rollback works, add:

```bash
if ! health_check; then
    rollback_to_previous_version
    exit 1
fi
```

Store:

```text
/srv/cca/releases/integration.current
/srv/cca/releases/uat.current
/srv/cca/releases/production.current
```

and:

```text
/srv/cca/releases/integration.previous
/srv/cca/releases/uat.previous
/srv/cca/releases/production.previous
```

Then a failed deployment can automatically revert.

---

# 54. Region-based deployment

Right now:

```text
asia-india
    │
    ├── integration
    ├── uat
    └── production
```

Later:

```text
asia-india
    ├── integration
    ├── uat
    └── production

us-east
    ├── integration
    ├── uat
    └── production
```

Then:

```text
Terraform
    │
    ├── region=asia-india
    │        └── server A
    │
    └── region=us-east
             └── server B
```

And GitHub Actions can use a matrix:

```yaml
strategy:
  matrix:
    region:
      - asia-india
      - us-east
```

For now we deliberately don't pretend your single physical server is multiple regions.

It is:

```text
one physical deployment region
=
asia-india
```

That distinction matters.

---

# 55. What your final architecture looks like

```text
                              GITHUB
                                │
                         workflow_dispatch
                                │
                                ▼
                     ┌────────────────────┐
                     │   GitHub Actions   │
                     └──────────┬─────────┘
                                │
                          IPv6 / SSH -6
                                │
                                ▼
                travel-planner.ddns.net
                                │
                        ┌───────▼───────┐
                        │   Ubuntu 24   │
                        └───────┬───────┘
                                │
                       ┌────────▼────────┐
                       │    Terraform    │
                       └────────┬────────┘
                                │
                         Docker Provider
                                │
                                ▼
                        Docker Engine
                                │
        ┌───────────────────────┼────────────────────────┐
        │                       │                        │
        ▼                       ▼                        ▼
  Integration                 UAT                   Production
        │                       │                        │
   ┌────┼────┐             ┌────┼────┐              ┌────┼────┐
   ▼    ▼    ▼             ▼    ▼    ▼              ▼    ▼    ▼
 API   WEB ADMIN          API   WEB ADMIN           API   WEB ADMIN
   │    │    │             │    │    │              │    │    │
   └────┴────┘             └────┴────┘              └────┴────┘
        │                       │                        │
        └───────────────────────┼────────────────────────┘
                                │
                                ▼
                       Docker Local Logs
                                │
                                ▼
                         Grafana Alloy
                                │
                                ▼
                              Loki
                                │
                                ▼
                             Grafana
```

---

# 56. What each technology is responsible for

This is worth memorizing:

```text
GitHub
  → source control

GitHub Actions
  → automation/orchestration

GitHub Environment/Secrets
  → deployment configuration and credentials

GHCR
  → immutable Docker artifacts

Terraform
  → desired infrastructure state

Docker provider
  → Terraform → Docker API

Docker
  → container runtime

Ubuntu
  → physical host

Grafana Alloy
  → log collection

Loki
  → log storage/query

Grafana
  → log visualization
```

---

# 57. Your requested operations map directly

| Operation                    | Mechanism                          |
| ---------------------------- | ---------------------------------- |
| Deploy main                  | Build images + Terraform apply     |
| Tag build                    | Git deployment tag + GHCR tag      |
| Tag state                    | Terraform release code is tagged   |
| Rollback                     | Reapply previous immutable version |
| Secret management            | GitHub secret → server env file    |
| Environment config           | integration/UAT/prod               |
| Region                       | `asia-india`                       |
| Stop                         | SSH → Docker stop                  |
| Restart                      | SSH → Docker restart               |
| Status                       | SSH → Docker status                |
| Logs                         | Docker → Alloy → Loki              |
| Health                       | HTTP/IPv6 checks                   |
| Concurrent deploy prevention | GitHub Actions concurrency         |
| Production approval          | GitHub Environment protection      |
| Old image retention          | `keep_locally=true`                |
| Terraform state backup       | per-environment state backups      |

---

# 58. One architectural choice I strongly recommend

Don't let **Coolify and Terraform manage the same containers**.

Use either:

```text
Terraform → Docker containers
```

or:

```text
Terraform → Coolify infrastructure
Coolify → application containers
```

but not:

```text
Terraform ──┐
            ├── same containers
Coolify  ───┘
```

because then you have two competing sources of truth.

For this exercise, since your goal is specifically to **learn Terraform**, I'd initially leave Coolify out of these three applications and let Terraform manage the Docker containers directly.

You can keep Coolify for your other hobby applications.

---

# 59. One more important limitation of this first version

Your current application stack is not yet completely production-ready from a container perspective.

For example, your backend currently depends on:

```text
MongoDB
Redis
GCP storage
Firebase
Razorpay
```

and the repository README explicitly lists MongoDB and Redis as prerequisites. ([GitHub][3])

So the complete architecture is actually:

```text
                       Backend
                          │
              ┌───────────┼───────────┐
              ▼           ▼           ▼
           MongoDB      Redis      GCP Storage
```

For your first deployment, I'd leave those as **external dependencies**, with their configuration managed per environment.

Then later we can move Redis/Mongo into your home server if you want:

```text
production
   │
   ├── API
   ├── Worker
   ├── Redis
   └── MongoDB
```

and then implement backups and disaster recovery.

---

# 60. The implementation order I recommend

Don't build all of this in one shot.

### Phase 1 — Basic Terraform

```text
Terraform
  ↓
Docker
  ↓
one nginx container
```

Verify that:

```bash
terraform plan
terraform apply
```

works on the home server.

### Phase 2 — Your actual backend

```text
Terraform
  ↓
backend container
```

Fix the backend Dockerfile and remove secrets.

### Phase 3 — Frontends

```text
backend
frontend
admin
```

### Phase 4 — Environments

```text
integration
uat
production
```

### Phase 5 — GHCR

```text
Actions
  ↓
build
  ↓
GHCR
  ↓
home server
```

### Phase 6 — IPv6 deployment

```text
Actions
  ↓
ssh -6
  ↓
home server
```

### Phase 7 — Versioning

```text
v2026....
```

### Phase 8 — Rollback

```text
old version
   ↓
terraform apply
```

### Phase 9 — Operations

```text
stop
restart
status
```

### Phase 10 — Observability

```text
Alloy
  ↓
Loki
  ↓
Grafana
```

### Phase 11 — Automatic failure rollback

```text
deploy
  ↓
health check
  ↓
failure?
  ↓
rollback
```

---

## The most important improvement I would make to your requirement

There are really **two distinct deployment channels** here:

```text
             GitHub Actions
                  │
                  ├── artifact channel
                  │      ↓
                  │    GHCR
                  │
                  └── control channel
                         ↓
                      SSH -6
                         ↓
                     Home Server
```

That is much better than:

```text
GitHub Actions
      │
      ▼
Remote Docker API
```

because your Docker daemon remains local-only, your SSH key is the only inbound administrative interface, and Terraform runs next to the infrastructure it manages.

And the IPv6 requirement is explicit: the workflow runs an IPv6 connectivity test and every SSH/SCP operation uses `-6`; it will fail rather than quietly switching to IPv4. GitHub does not guarantee IPv6 connectivity on standard hosted runners, so that preflight is important. ([GitHub Docs][1])

The next practical step should be to create the **`cca-infra` repository with the exact file tree and complete `deploy.yml`, `main.tf`, the three production Dockerfiles, `ops.sh`, and the GitHub Environment/Secret names**, then test the pipeline first against `integration`.

[1]: https://docs.github.com/en/actions/reference/runners/github-hosted-runners?utm_source=chatgpt.com "GitHub-hosted runners reference - GitHub Docs"
[2]: https://docs.github.com/en/actions/reference/security/secure-use?utm_source=chatgpt.com "Secure use reference - GitHub Docs"
[3]: https://github.com/brguru90/cca_backend "GitHub - brguru90/cca_backend · GitHub"
[4]: https://github.com/brguru90/cca_admin_frontend "GitHub - brguru90/cca_admin_frontend · GitHub"
[5]: https://registry.terraform.io/providers/kreuzwerker/docker/latest/docs?utm_source=chatgpt.com "Docs overview | kreuzwerker/docker | Terraform | Terraform Registry"
[6]: https://developer.hashicorp.com/terraform/language/backend/s3?utm_source=chatgpt.com "Backend Type: s3 | Terraform | HashiCorp Developer"
[7]: https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments?utm_source=chatgpt.com "Deployments and environments - GitHub Docs"
[8]: https://github.com/flutter/flutter/blob/master/CHANGELOG.md?utm_source=chatgpt.com "flutter/CHANGELOG.md at master · flutter/flutter · GitHub"
[9]: https://github.com/brguru90/cca_frontend "GitHub - brguru90/cca_frontend · GitHub"
[10]: https://registry.terraform.io/providers/kreuzwerker/docker/latest/docs/resources/network?utm_source=chatgpt.com "docker_network | Resources | kreuzwerker/docker | Terraform | Terraform Registry"
[11]: https://registry.terraform.io/providers/kreuzwerker/docker/latest/docs/data-sources/registry_image.html?utm_source=chatgpt.com "docker_registry_image | Data Sources | kreuzwerker/docker | Terraform | Terraform Registry"
[12]: https://registry.terraform.io/providers/kreuzwerker/docker/latest/docs/resources/container.html?utm_source=chatgpt.com "docker_container | Resources | kreuzwerker/docker | Terraform | Terraform Registry"
[13]: https://docs.docker.com/engine/logging/configure/?utm_source=chatgpt.com "Configure logging drivers | Docker Docs"
[14]: https://docs.github.com/en/rest/actions/workflows?utm_source=chatgpt.com "REST API endpoints for workflows - GitHub Docs"
[15]: https://docs.github.com/en/actions/concepts/workflows-and-actions/concurrency?utm_source=chatgpt.com "Concurrency - GitHub Docs"
[16]: https://github.com/docker/setup-buildx-action/releases?utm_source=chatgpt.com "Releases · docker/setup-buildx-action · GitHub"
[17]: https://grafana.com/docs/loki/latest/send-data/alloy/?utm_source=chatgpt.com "Ingesting logs to Loki using Alloy | Grafana Loki documentation"
[18]: https://grafana.com/docs/alloy/latest/monitor/monitor-docker-containers/?utm_source=chatgpt.com "Monitor Docker containers with Grafana Alloy | Grafana Alloy documentation"
