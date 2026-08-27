# requirements(enhancement of ./initial-plan.md)
```
few changes in the requirement,

- Instead of docker i want to try kubernaties locally with autoscaling features
- the flutter repo needs build to generate android apk, so web build & deployment not required
- For your information, i had working github runner before so mostly it proves it works with ipv6 connectivity
- use port in 8700 to 8799 and 3200 to 4000 mostly those are free
```

Yes. With those changes, I would **replace the Docker-only runtime with a local Kubernetes cluster**, preferably **K3s**, and keep Terraform as the infrastructure/deployment control plane.

There are also two important consequences:

1. **Kubernetes HPA can scale Pods on your single physical server**, but it cannot magically create more CPU/RAM. True node autoscaling requires additional nodes. Kubernetes HPA is specifically designed to change replica counts based on metrics. ([Kubernetes][1])
2. Your Flutter repository should become a **CI build artifact pipeline** (`APK`), not a Kubernetes deployment.

Here is the revised architecture I recommend.

---

# 1. Revised architecture

```text
                              GitHub
                                │
                     merge to main
                                │
                                ▼
                    Manual workflow_dispatch
                                │
                                ▼
                       GitHub Actions
                                │
             ┌──────────────────┼──────────────────┐
             │                  │                  │
             ▼                  ▼                  ▼
       Backend build      Admin build       Flutter build
             │                  │                  │
             ▼                  ▼                  ▼
           GHCR               GHCR             APK artifact
             │                  │                  │
             └────────────┬─────┘                  │
                          │                        │
                          ▼                        ▼
                   SSH over IPv6              GitHub Release/
                          │                   Actions Artifact
                          ▼
               Ubuntu 24 Home Server
                          │
                          ▼
                       K3s
                          │
       ┌──────────────────┼──────────────────┐
       │                  │                  │
       ▼                  ▼                  ▼
 integration            UAT             production
 namespace             namespace          namespace
       │                  │                  │
   ┌───┼───┐          ┌───┼───┐          ┌───┼───┐
   ▼   ▼   ▼          ▼   ▼   ▼          ▼   ▼   ▼
 backend web admin  backend web admin  backend web admin
       │                  │                  │
       └──────────────────┼──────────────────┘
                          │
                       HPA
                          │
                   more Pods as load
                       increases
```

The key change is:

```text
Terraform → Kubernetes API
```

instead of:

```text
Terraform → Docker API
```

The Kubernetes provider will manage Kubernetes objects, and the Helm provider can manage Helm charts.

---

# 2. I recommend K3s for your machine

For a single Ubuntu 24 home server, I'd use **K3s** rather than installing a full kubeadm-based Kubernetes cluster.

Conceptually:

```text
Ubuntu 24
   │
   ▼
  K3s
   │
   ├── Kubernetes API server
   ├── scheduler
   ├── controller
   ├── container runtime
   ├── CoreDNS
   └── networking
```

K3s includes CoreDNS and, by default, Traefik as its ingress controller. K3s's packaged Traefik uses ServiceLB and normally occupies ports 80/443, so we'll explicitly decide whether to keep or disable it rather than letting it interfere with your chosen ports. ([K3s][2])

For your first implementation, I would actually **disable the default Traefik** and use NodePort services with your requested port ranges. That makes the architecture easier to understand.

---

# 3. Your physical machine is one Kubernetes node

Currently:

```text
                    HOME SERVER
                 Ubuntu 24 physical
                         │
                         ▼
                       K3s
                         │
                       node-1
                         │
       ┌─────────────────┼─────────────────┐
       ▼                 ▼                 ▼
 integration           UAT            production
```

This is a valid Kubernetes cluster.

But understand the limitation:

```text
HPA:
1 Pod → 2 Pods → 4 Pods → 8 Pods
```

can work.

But:

```text
Node:
1 → 2 → 3
```

cannot happen automatically unless you have somewhere to create those additional nodes.

Kubernetes HPA changes the number of Pods; node autoscaling is a separate problem. ([Kubernetes][1])

Later, you could create:

```text
Physical Ubuntu
      │
      ▼
     KVM
      │
 ┌────┼────┐
 ▼    ▼    ▼
VM1  VM2  VM3
 │    │    │
 └────┼────┘
      ▼
   Kubernetes
```

and then study node autoscaling.

But **don't add KVM yet**. First learn Pod autoscaling.

---

# 4. Port allocation

You asked for:

```text
8700-8799
3200-4000
```

Let's use:

| Environment | Backend | Frontend |  Admin |
| ----------- | ------: | -------: | -----: |
| Integration |  `8701` |   `3201` | `3202` |
| UAT         |  `8702` |   `3301` | `3302` |
| Production  |  `8703` |   `3401` | `3402` |

So:

```text
Integration
  API   → :8701
  Web   → :3201
  Admin → :3202

UAT
  API   → :8702
  Web   → :3301
  Admin → :3302

Production
  API   → :8703
  Web   → :3401
  Admin → :3402
```

These can be Kubernetes `NodePort` services.

Kubernetes normally uses `30000-32767` for NodePort, but the NodePort range is configurable and a specific `nodePort` can be assigned inside the configured range. ([Kubernetes][3])

So for K3s we'll configure:

```text
service-node-port-range=3200-8799
```

Then your requested ports become valid NodePorts.

**Important:** Linux/system services and Docker/Coolify may already be using some ports, so we'll verify before applying.

---

# 5. Kubernetes namespaces = your environments

Instead of maintaining three different clusters:

```text
Cluster
 ├── integration
 ├── UAT
 └── production
```

Use namespaces:

```text
K3s
│
├── cca-integration
│
├── cca-uat
│
└── cca-production
```

This is excellent for learning Kubernetes.

Every environment gets:

```text
Deployment
Service
ConfigMap
Secrets
HPA
```

For example:

```text
cca-production
│
├── backend
├── backend-worker
├── frontend
├── admin
├── backend-service
├── frontend-service
├── admin-service
├── backend-hpa
├── frontend-hpa
├── admin-hpa
└── secrets
```

---

# 6. Backend Deployment

Your backend becomes a Deployment:

```yaml
apiVersion: apps/v1
kind: Deployment

metadata:
  name: backend

spec:
  replicas: 2

  selector:
    matchLabels:
      app: backend

  template:
    metadata:
      labels:
        app: backend

    spec:
      containers:
        - name: backend
          image: ghcr.io/brguru90/cca-backend:VERSION

          ports:
            - containerPort: 8000

          resources:
            requests:
              cpu: "200m"
              memory: "256Mi"

            limits:
              cpu: "1"
              memory: "1Gi"

          envFrom:
            - secretRef:
                name: backend-secrets

          readinessProbe:
            httpGet:
              path: /health
              port: 8000

            initialDelaySeconds: 10
            periodSeconds: 10

          livenessProbe:
            httpGet:
              path: /health
              port: 8000

            initialDelaySeconds: 30
            periodSeconds: 20
```

The important pieces are:

```text
replicas
resources
readinessProbe
livenessProbe
secretRef
```

These become very important when you introduce autoscaling.

---

# 7. Backend Service

The Deployment creates Pods, but users don't connect to Pods directly.

You create a Service:

```yaml
apiVersion: v1
kind: Service

metadata:
  name: backend

spec:
  type: NodePort

  selector:
    app: backend

  ports:
    - port: 8000
      targetPort: 8000
      nodePort: 8701
```

Now:

```text
Internet
   │
   ▼
Ubuntu Server
   │
 :8701
   │
   ▼
Kubernetes Service
   │
   ├── backend Pod 1
   └── backend Pod 2
```

Later HPA might create:

```text
backend Pod 1
backend Pod 2
backend Pod 3
backend Pod 4
```

The Service automatically distributes traffic across ready endpoints.

---

# 8. Frontend

The admin frontend can be packaged as an Nginx container.

For integration:

```text
:3201
```

UAT:

```text
:3301
```

Production:

```text
:3401
```

Example:

```yaml
apiVersion: v1
kind: Service

metadata:
  name: frontend

spec:
  type: NodePort

  selector:
    app: frontend

  ports:
    - port: 80
      targetPort: 80
      nodePort: 3201
```

Because each namespace has its own Service, the same service name can safely exist in:

```text
cca-integration/frontend
cca-uat/frontend
cca-production/frontend
```

---

# 9. Admin frontend

Same idea:

```text
Integration → 3202
UAT         → 3302
Production  → 3402
```

---

# 10. Flutter is different

Your `cca_frontend` repository should **not be deployed to Kubernetes**.

The workflow should do:

```text
cca_frontend
     │
     ▼
Flutter build
     │
     ▼
flutter build apk --release
     │
     ▼
app-release.apk
     │
     ├── GitHub Actions artifact
     │
     └── GitHub Release asset
```

So:

```text
Backend
   → Docker image → GHCR → Kubernetes

Admin frontend
   → Docker image → GHCR → Kubernetes

Flutter frontend
   → APK → GitHub Release
```

This is much cleaner.

---

# 11. APK versioning

Suppose deployment version:

```text
v2026.08.26.1400-production-r42
```

Then:

```text
cca-frontend-v2026.08.26.1400-production-r42.apk
```

The GitHub Release could contain:

```text
v2026.08.26.1400-production-r42

Assets:
├── cca-frontend.apk
├── deployment-manifest.json
└── source-version.json
```

`source-version.json`:

```json
{
  "deployment": "v2026.08.26.1400-production-r42",
  "region": "asia-india",
  "environment": "production",
  "backend": "abc123...",
  "admin": "def456...",
  "flutter": "789abc..."
}
```

Now you can always determine exactly which source generated that APK.

---

# 12. APK signing

For a real release APK:

```text
Flutter
   │
   ▼
Android signing
   │
   ├── keystore
   ├── key alias
   └── passwords
```

The keystore/passwords should be GitHub Secrets, not Git.

For the first implementation I'd build an unsigned/release APK or a debug APK to prove the pipeline, then add Play Store-grade signing afterward.

---

# 13. Terraform changes

You now need three Terraform providers:

```text
Terraform
│
├── Kubernetes Provider
│       ↓
│   Kubernetes API
│
├── Helm Provider
│       ↓
│   Helm/Kubernetes
│
└── optional Docker Provider
```

The Docker provider is no longer necessary for application deployment.

Your Terraform repository becomes:

```text
cca-infra/
│
├── terraform/
│   ├── providers.tf
│   ├── variables.tf
│   ├── main.tf
│   ├── namespaces.tf
│   ├── backend.tf
│   ├── frontend.tf
│   ├── admin.tf
│   ├── hpa.tf
│   ├── secrets.tf
│   └── outputs.tf
│
├── kubernetes/
│   ├── base/
│   └── environments/
│
└── .github/
    └── workflows/
        └── deploy.yml
```

---

# 14. Terraform → Kubernetes

The architecture is now:

```text
GitHub Actions
       │
       ▼
Terraform
       │
       ▼
Kubernetes Provider
       │
       ▼
K3s API Server
       │
       ▼
Kubernetes
       │
       ├── Deployment
       ├── Service
       ├── Secret
       ├── ConfigMap
       └── HPA
```

This is exactly what I recommend for learning Terraform + Kubernetes together.

---

# 15. Terraform provider configuration

Conceptually:

```hcl
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

provider "kubernetes" {
  config_path = "/etc/rancher/k3s/k3s.yaml"
}

provider "helm" {
  kubernetes {
    config_path = "/etc/rancher/k3s/k3s.yaml"
  }
}
```

Because Terraform will run on the home server:

```text
Terraform
    │
    ▼
/etc/rancher/k3s/k3s.yaml
    │
    ▼
local K3s API
```

There is no need to expose the Kubernetes API publicly.

This is actually much safer.

---

# 16. Your GitHub runner becomes very important here

You said:

> I had a working GitHub runner before.

Great.

There are two possibilities.

### Case A — Your runner is installed on the home server

Then use:

```text
GitHub
  │
  ▼
GitHub Actions
  │
  ▼
Self-hosted runner
  │
  ▼
Terraform
  │
  ▼
K3s
```

This is my preferred architecture.

You don't need:

```text
GitHub Actions
    │
    ▼
SSH
    │
    ▼
Home server
```

at all.

And you don't need to expose:

```text
SSH 22
Kubernetes API 6443
Docker API
```

to GitHub.

The runner establishes an **outbound** connection to GitHub.

---

# 17. Case B — GitHub-hosted runner

Then keep the original model:

```text
GitHub-hosted runner
        │
        │ IPv6
        ▼
travel-planner.ddns.net
        │
        ▼
SSH
        │
        ▼
Terraform
        │
        ▼
K3s
```

Since you've already had this working, we can use:

```bash
ssh -6 deploy@travel-planner.ddns.net
```

and explicitly test:

```bash
curl -6 ...
```

before deployment.

But I would **prefer the existing self-hosted runner** if it is on the home machine.

---

# 18. Public IPv6 is still useful

Even with a self-hosted runner, we can add an explicit public-IPv6 verification job:

```text
Self-hosted runner
     │
     ▼
resolve AAAA
     │
     ▼
travel-planner.ddns.net
     │
     ▼
public IPv6
     │
     ▼
home server
```

This is useful for verifying your external accessibility.

---

# 19. HPA

This is where Kubernetes becomes much more interesting than our previous Docker design.

Example:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler

metadata:
  name: backend

spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: backend

  minReplicas: 2
  maxReplicas: 10

  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
```

This means:

```text
CPU < 60%
     ↓
2 Pods

CPU > 60%
     ↓
3 Pods

more load
     ↓
4 Pods
     ↓
5 Pods
...
max 10
```

Kubernetes HPA supports CPU/memory resource metrics and custom/external metrics through `autoscaling/v2`. ([Kubernetes][1])

---

# 20. Metrics Server

For CPU/memory HPA you need the resource metrics API, normally supplied by Metrics Server. Kubernetes documentation explicitly identifies Metrics Server as the usual provider of `metrics.k8s.io`. ([Kubernetes][1])

Architecture:

```text
Pods
 │
 ▼
Metrics Server
 │
 ▼
metrics.k8s.io
 │
 ▼
HPA Controller
 │
 ▼
Deployment replicas
```

Then:

```bash
kubectl top pods
```

should work.

And:

```bash
kubectl get hpa
```

should show current/desired replicas.

---

# 21. Autoscaling demonstration

This should become one of your first exercises.

Start:

```text
backend
replicas = 2
```

Generate load:

```text
100 requests/sec
```

watch:

```bash
kubectl get hpa -w
```

and:

```bash
kubectl get pods -w
```

You'll see:

```text
2 pods
 ↓
3 pods
 ↓
4 pods
 ↓
...
```

Then stop the load:

```text
4
 ↓
3
 ↓
2
```

This is real system-design learning, not just memorizing HPA.

---

# 22. But your one server has a hard limit

Suppose your server has:

```text
16 CPU
32 GB RAM
```

You configure:

```text
maxReplicas: 50
```

Kubernetes may attempt to create 50 Pods, but eventually:

```text
CPU unavailable
memory unavailable
```

and Pods become:

```text
Pending
```

So:

```text
HPA
≠
unlimited scaling
```

Instead:

```text
HPA
→ Pod-level elasticity

Node autoscaler
→ infrastructure-level elasticity
```

---

# 23. Later: turn your home server into a mini cluster

After the first stage:

```text
Physical machine
     │
     ▼
K3s
     │
     └── node-1
```

you can eventually add KVM:

```text
Physical server
       │
       ▼
      KVM
       │
 ┌─────┼─────┐
 ▼     ▼     ▼
VM1   VM2   VM3
 │     │     │
 └─────┼─────┘
       ▼
      K3s
       │
 ┌─────┼─────┐
 ▼     ▼     ▼
node1 node2 node3
```

Then you can study:

```text
Pod autoscaling
+
Node scheduling
+
Node failure
+
Cluster capacity
```

That should be **Phase 2**, not now.

---

# 24. Environment + region model

We'll represent everything explicitly:

```yaml
regions:
  asia-india:
    server: travel-planner.ddns.net

environments:
  integration:
    namespace: cca-integration

  uat:
    namespace: cca-uat

  production:
    namespace: cca-production
```

The current physical deployment is:

```text
Region: asia-india

             K3s
              │
      ┌───────┼────────┐
      ▼       ▼        ▼
    INT      UAT      PROD
```

Later:

```text
Region: asia-india
        │
        ▼
      K3s A

Region: us-east
        │
        ▼
      K3s B
```

and Terraform can use the same module for both.

---

# 25. Versioning becomes even better with Kubernetes

Every deployment gets:

```text
v2026.08.26.1430-production-r42
```

And the Deployment has:

```yaml
metadata:
  labels:
    cca.version: v2026.08.26.1430-production-r42
```

Pods inherit that label.

So Grafana/Loki/Kubernetes can answer:

```text
Which version is running?

Which version produced this error?

Which version had 80% CPU?

```

This is extremely useful.

---

# 26. Rollback becomes native Kubernetes functionality

This is another big advantage.

Kubernetes Deployments maintain rollout history.

Normal deployment:

```text
v1
 ↓
v2
 ↓
v3
```

Rollback:

```bash
kubectl rollout undo deployment/backend
```

But for your requirements I would **not rely solely on Kubernetes's internal revision number**.

Instead use immutable application versions:

```text
v2026.08.26.1430-production-r42
```

and explicitly set:

```yaml
image:
  ghcr.io/brguru90/cca-backend:v2026.08.26.1430-production-r42
```

Then your GitHub Actions rollback workflow can say:

```text
rollback production
→ version v2026.08.24.2045-production-r31
```

Terraform applies exactly that version.

This gives you deterministic rollback.

---

# 27. Stop and restart

Kubernetes gives you much better semantics here.

### Stop environment

```bash
kubectl scale deployment/backend \
  --replicas=0 \
  -n cca-production
```

Same for frontend/admin.

### Restart

```bash
kubectl rollout restart deployment/backend \
  -n cca-production
```

### Status

```bash
kubectl get pods -n cca-production
kubectl get deployments -n cca-production
kubectl get hpa -n cca-production
```

These become GitHub Actions operations.

---

# 28. GitHub Actions interface

Your manual workflow can now look like:

```text
┌──────────────────────────────────────────────┐
│ CCA Deployment                              │
├──────────────────────────────────────────────┤
│ Action                                      │
│ [ deploy ▼ ]                                │
│                                              │
│ Environment                                 │
│ [ integration ▼ ]                           │
│                                              │
│ Region                                      │
│ [ asia-india ▼ ]                            │
│                                              │
│ Version                                     │
│ [ optional ]                                │
│                                              │
│ Auto rollback                               │
│ [ true ]                                     │
└──────────────────────────────────────────────┘
```

Actions:

```text
deploy
rollback
stop
restart
status
scale
```

And perhaps later:

```text
logs
```

---

# 29. Deployment workflow

The final deployment process becomes:

```text
              MERGE TO MAIN
                    │
                    ▼
             Manual workflow
                    │
         ┌──────────┼───────────┐
         ▼          ▼           ▼
      backend     admin       Flutter
         │          │           │
         ▼          ▼           ▼
       Docker     Docker        APK
       build      build        build
         │          │           │
         ▼          ▼           ▼
        GHCR       GHCR      Artifact/Release
         │          │
         └─────┬────┘
               ▼
       deployment version
               │
               ▼
         Terraform Apply
               │
               ▼
               K3s
               │
     ┌─────────┼─────────┐
     ▼         ▼         ▼
    INT       UAT       PROD
               │
               ▼
             HPA
               │
               ▼
          more Pods
```

---

# 30. Secrets now become Kubernetes Secrets

Instead of:

```text
Docker environment file
```

we'll have:

```text
GitHub Environment Secret
          │
          ▼
GitHub Actions
          │
          ▼
Kubernetes Secret
          │
          ▼
Pod
```

For example:

```yaml
apiVersion: v1
kind: Secret

metadata:
  name: backend-secrets

type: Opaque

stringData:
  MONGO_DB_USER: ...
  MONGO_DB_PASSWORD: ...
  JWT_SECRET_KEY: ...
  REDIS_ADDR: ...
```

But there's a subtle Terraform issue:

> Kubernetes Secret values managed directly by Terraform can end up in Terraform state.

For a hobby system this may be acceptable with a protected local state, but for a production-grade design I'd separate secret storage from Terraform state using something such as SOPS + age, an external secret manager, or Vault.

For your first implementation, we can use GitHub Environment Secrets → Kubernetes Secret and keep the state securely on your server.

---

# 31. Logging architecture

Instead of:

```text
Docker → local logs
```

now:

```text
                  Kubernetes
                      │
              ┌───────┼────────┐
              ▼       ▼        ▼
            Pod     Pod      Pod
              │       │        │
              └───────┼────────┘
                      ▼
                 Grafana Alloy
                      │
                      ▼
                     Loki
                      │
                      ▼
                   Grafana
```

We can label logs:

```text
region=asia-india
environment=production
app=backend
version=v2026...
pod=backend-xxxxx
```

That gives you an AWS CloudWatch-like experience using open-source components.

---

# 32. Observability later

Eventually your home server becomes:

```text
Kubernetes
   │
   ├── Metrics Server
   │
   ├── Prometheus
   │
   ├── Grafana Alloy
   │
   ├── Loki
   │
   └── Grafana
```

Then:

```text
HPA
 ↓
Prometheus/metrics
 ↓
Grafana
```

and:

```text
Application logs
 ↓
Alloy
 ↓
Loki
 ↓
Grafana
```

This gets very close to the AWS:

```text
CloudWatch Metrics
CloudWatch Logs
CloudWatch Alarms
X-Ray
```

model.

---

# 33. The Terraform repository now

I would structure it like this:

```text
cca-infra/
│
├── terraform/
│   │
│   ├── providers.tf
│   ├── variables.tf
│   ├── locals.tf
│   ├── namespaces.tf
│   ├── backend.tf
│   ├── frontend.tf
│   ├── admin.tf
│   ├── worker.tf
│   ├── services.tf
│   ├── hpa.tf
│   ├── secrets.tf
│   └── outputs.tf
│
├── k8s/
│   │
│   ├── monitoring/
│   ├── metrics-server/
│   └── storage/
│
├── scripts/
│   ├── install-k3s.sh
│   ├── health-check.sh
│   └── backup-state.sh
│
└── .github/
    └── workflows/
        └── deploy.yml
```

---

# 34. Terraform should manage these things

```text
Terraform
│
├── namespaces
├── Deployments
├── Services
├── ConfigMaps
├── Secrets
├── HPA
├── resource limits
├── environment configuration
├── Helm charts
├── monitoring infrastructure
└── storage definitions
```

K3s itself can initially be installed separately.

Once everything works, Terraform can automate its installation/configuration too.

---

# 35. What Terraform should NOT manage

I would avoid having Terraform directly manage:

```text
Pod replica count during autoscaling
```

because HPA is supposed to control that.

For example:

```hcl
replicas = 2
```

and HPA:

```text
min=2
max=10
```

If Terraform continuously insists:

```text
replicas = 2
```

while HPA says:

```text
replicas = 7
```

you've created a fight between controllers.

So Terraform manages the **HPA policy**, not the dynamically calculated replica count.

This is an important Kubernetes/IaC principle.

---

# 36. The revised AWS-to-homelab mapping

You originally wanted to learn AWS system design. This setup maps very nicely:

| AWS concept           | Your home Kubernetes equivalent      |
| --------------------- | ------------------------------------ |
| ECS/EKS               | K3s                                  |
| ECS Service           | Kubernetes Deployment                |
| ALB                   | Kubernetes Service/Ingress           |
| Auto Scaling          | HPA                                  |
| EC2                   | Physical server / future VM          |
| ECR                   | GHCR                                 |
| Secrets Manager       | Kubernetes Secret / later Vault      |
| CloudWatch Logs       | Loki                                 |
| CloudWatch Metrics    | Prometheus                           |
| CloudWatch dashboards | Grafana                              |
| S3                    | MinIO / local storage later          |
| SQS                   | RabbitMQ/NATS later                  |
| SNS/EventBridge       | NATS/Kafka later                     |
| CloudFront            | Cloudflare/CDN later                 |
| WAF                   | Cloudflare WAF / local reverse proxy |
| RDS                   | PostgreSQL/Mongo cluster             |
| Multi-AZ              | Multi-node K3s                       |
| Region                | Physical deployment location         |
| Terraform             | Terraform                            |
| GitHub Actions        | GitHub Actions                       |

This is actually a **much better learning environment** than jumping directly into AWS because you can see the mechanics rather than paying a cloud provider to hide them.

---

# 37. Revised phases

### Phase 1 — Kubernetes

```text
Ubuntu 24
 ↓
K3s
 ↓
kubectl
 ↓
Namespace
 ↓
Deployment
 ↓
Service
```

### Phase 2 — Your applications

```text
backend
admin frontend
```

Flutter:

```text
APK only
```

### Phase 3 — Terraform

```text
Terraform
 ↓
Kubernetes Provider
 ↓
K3s
```

### Phase 4 — Environments

```text
integration
uat
production
```

### Phase 5 — HPA

```text
Metrics Server
 ↓
HPA
 ↓
Pods scale
```

### Phase 6 — GitHub Actions

```text
manual dispatch
 ↓
build
 ↓
GHCR
 ↓
Terraform
 ↓
Kubernetes
```

### Phase 7 — Versioning/rollback

```text
immutable image
+
Git tag
+
deployment manifest
```

### Phase 8 — Operations

```text
deploy
rollback
stop
restart
status
scale
```

### Phase 9 — Observability

```text
Alloy
 ↓
Loki
 ↓
Grafana
```

### Phase 10 — Multi-node Kubernetes

Only after everything above works:

```text
KVM
 ↓
multiple VMs
 ↓
K3s nodes
 ↓
scheduling
 ↓
node failures
 ↓
node autoscaling concepts
```

---

## One change I'd make to the earlier plan

Because you already had a working GitHub runner, **I would first determine whether that runner is installed on the home server**.

If it is, the cleanest final architecture is:

```text
GitHub
   │
   ▼
workflow_dispatch
   │
   ▼
Self-hosted GitHub Runner
   │
   ├── Docker Buildx
   ├── Flutter SDK
   ├── Terraform
   ├── kubectl
   └── Helm
          │
          ▼
        K3s
          │
       Home Server
```

That removes the entire inbound SSH deployment path.

Your public IPv6/DDNS remains useful for exposing the applications and for testing IPv6 externally, but GitHub doesn't need to connect inbound to your server. The runner maintains the outbound GitHub connection.

If your existing runner is instead a **GitHub-hosted runner**, we'll retain the IPv6 SSH design from the previous plan.

The next implementation should therefore start with **K3s + Metrics Server + Terraform Kubernetes provider**, then deploy only the backend and admin frontend first, while the Flutter pipeline builds and publishes the APK. This gives you a working Kubernetes/HPA deployment before we add monitoring, rollback, and the multi-environment automation.

[1]: https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/?utm_source=chatgpt.com "Horizontal Pod Autoscaling | Kubernetes"
[2]: https://docs.k3s.io/networking/networking-services?utm_source=chatgpt.com "Networking Services | K3s"
[3]: https://kubernetes.io/docs/concepts/services-networking/service/?utm_source=chatgpt.com "Service | Kubernetes"
