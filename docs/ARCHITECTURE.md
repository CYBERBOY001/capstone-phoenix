
---

# Architecture

## 1. Topology diagram

```text
                              INTERNET
                                  │
                                  │ HTTPS :443
                                  ▼
                         ┌─────────────────┐
                         │ taskapp.com.ng  │
                         │      DNS        │
                         └────────┬────────┘
                                  │
                                  ▼
                         ┌─────────────────┐
                         │ AWS Security    │
                         │     Group       │
                         │ 80 / 443 / 22   │
                         └────────┬────────┘
                                  │
                                  ▼
                    ┌──────────────────────────┐
                    │   NGINX Ingress          │
                    │   Controller              │
                    │   ingressClass: nginx     │
                    │                           │
                    │ TLS → Let's Encrypt       │
                    └────────────┬─────────────┘
                                 │
                   ┌─────────────┴─────────────┐
                   │                           │
                "/"                          "/api"
                   │                           │
                   ▼                           ▼
          ┌────────────────┐          ┌────────────────┐
          │ Frontend       │          │ Backend        │
          │ Service :80    │          │ Service :5000  │
          └───────┬────────┘          └───────┬────────┘
                  │                           │
                  ▼                           ▼
          ┌───────────────┐           ┌───────────────┐
          │ Frontend Pods │           │ Backend Pods   │
          │   2 replicas  │           │   2 replicas   │
          └───────────────┘           └───────┬────────┘
                                              │
                                              │ :5432
                                              ▼
                                      ┌─────────────────┐
                                      │ PostgreSQL      │
                                      │ StatefulSet     │
                                      │ 1 replica       │
                                      └────────┬────────┘
                                               │
                                               ▼
                                      ┌─────────────────┐
                                      │ PVC             │
                                      │ K3s local-path  │
                                      │ storage         │
                                      └─────────────────┘


                 ┌────────────────────────────────────┐
                 │           K3s CLUSTER              │
                 │                                    │
                 │  EC2 #1                            │
                 │  Control Plane                     │
                 │  K3s Server                       │
                 │                                    │
                 │  EC2 #2              EC2 #3        │
                 │  Worker 1            Worker 2      │
                 │                                    │
                 │  TaskApp pods scheduled across     │
                 │  the worker nodes                  │
                 └────────────────────────────────────┘


        GitHub
           │
           ▼
       Argo CD
           │
           ▼
     K3s desired state
           │
     ┌─────┴───────────────┐
     │                     │
     ▼                     ▼
Sealed Secrets          cert-manager
     │                     │
     ▼                     ▼
phoenix-secret       Let's Encrypt TLS
```

---

## 2. Node & network

### Nodes

The cluster consists of three EC2 instances:

| Node  | Role              | Workload                                                   |
| ----- | ----------------- | ---------------------------------------------------------- |
| EC2 1 | K3s control plane | Kubernetes control-plane components and cluster management |
| EC2 2 | K3s worker/agent  | TaskApp frontend/backend workloads                         |
| EC2 3 | K3s worker/agent  | TaskApp frontend/backend workloads                         |

The two worker nodes allow the TaskApp frontend and backend replicas to be distributed across separate machines.

The cluster is deployed in AWS using Terraform, with Ansible responsible for configuring the machines and forming the K3s cluster.

### CIDR / subnet choices

The EC2 nodes are placed in the private/internal addressing space of the VPC. The nodes communicate using their private IP addresses for Kubernetes and application traffic.

The Kubernetes API is therefore not exposed directly to the Internet.

The important distinction is:

```text
Internet
   │
   ├── 80/443 ──► Application ingress
   │
   └── 22 ──────► SSH from administrator's IP
```

while cluster-internal traffic uses the private network:

```text
Worker 1 ──────────► Control Plane
Worker 2 ──────────► Control Plane
Worker 1 ◄─────────► Worker 2
```

### Firewall

The AWS Security Group follows least privilege.

| Port                       | Source                   | Purpose                          |
| -------------------------- | ------------------------ | -------------------------------- |
| `80`                       | Internet                 | HTTP / ACME HTTP-01 challenge    |
| `443`                      | Internet                 | HTTPS application traffic        |
| `22`                       | Administrator IP only    | SSH administration               |
| `6443`                     | Internal/private network | Kubernetes API                   |
| Application/internal ports | Internal cluster/VPC     | Service-to-service communication |

**Port `6443` is deliberately not open to the world.**

Users do not need direct access to the Kubernetes API. Public traffic enters through NGINX Ingress instead.

This reduces the attack surface because:

```text
Internet ──X──► Kubernetes API :6443

Internet ─────► NGINX :443 ─────► TaskApp
```

---

# 3. Request flow

A user resolves `taskapp.com.ng` through DNS to the public entry point for the cluster. The request reaches the AWS security group on TCP port `443` and is forwarded to the **NGINX Ingress Controller**. NGINX handles HTTPS using the TLS certificate issued by **cert-manager/Let's Encrypt**. Requests for `/` are routed to the `frontend` Kubernetes Service on port `80`, which distributes traffic to the frontend replicas. API requests under `/api` are routed to the `backend` Service on port `5000`, which distributes requests between the Flask/Gunicorn backend replicas. The backend connects to the PostgreSQL Service on port `5432`, which targets the PostgreSQL StatefulSet. PostgreSQL stores its data through the Kubernetes PVC backed by K3s local-path storage.

```text
taskapp.com.ng
      │
      ▼
    :443
      │
      ▼
NGINX Ingress
      │
      ├── / ──────► frontend:80
      │
      └── /api ───► backend:5000
                         │
                         └──► postgres:5432
```

---

# 4. The single-server assumptions you fixed

This is an important section for your project because it demonstrates **why Kubernetes is being used instead of simply running everything with Docker Compose on one EC2 instance.**

| Single-server assumption                       | Why it breaks at scale                                                                                                   | How you fixed it                                                                                                                  |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| Migrate-on-boot in the entrypoint              | With 2+ backend replicas, multiple containers can simultaneously execute `alembic upgrade head`, causing migration races | Moved database migration into a dedicated Kubernetes **Job**: `migration/migration-job.yaml`                                      |
| Named volume on the host                       | A container can be restarted on another node and the host's local volume may not exist there                             | PostgreSQL uses a **PersistentVolumeClaim** and StatefulSet. In this project the PVC uses K3s local-path storage                  |
| `ports:` published on the host                 | Multiple Pods can exist on different nodes and host ports are not an appropriate application front door                  | Kubernetes **Services** provide stable virtual endpoints; NGINX Ingress provides the external front door                          |
| One application process                        | A single process/container failure takes the application offline                                                         | **Deployments with 2 replicas**, Kubernetes scheduling and self-healing recreate failed Pods                                      |
| Manually restarting containers                 | Containers must be monitored and recreated when unhealthy                                                                | Kubernetes **liveness, readiness and startup probes** allow Kubernetes to detect unhealthy containers                             |
| One frontend/backend instance                  | A single instance becomes a single point of failure                                                                      | Frontend and backend use **2 replicas** with topology spreading across worker nodes                                               |
| Manual traffic routing                         | A single NGINX configuration tied to a host becomes difficult to manage as Pods move                                     | **Kubernetes Services + NGINX Ingress** dynamically route traffic to available Pods                                               |
| Direct HTTP exposure of application containers | Each application would need its own externally exposed port                                                              | Only NGINX is externally exposed; frontend/backend remain **ClusterIP Services**                                                  |
| Deployment by manually replacing containers    | Replacing all containers at once causes downtime                                                                         | Deployment uses **RollingUpdate**, with `maxUnavailable: 0`                                                                       |
| Secrets stored in `.env` or Git                | Credentials can leak through source control                                                                              | **Bitnami Sealed Secrets** stores encrypted `SealedSecret` resources in Git while the controller decrypts them inside the cluster |
| TLS manually configured on NGINX               | Certificate renewal becomes a manual operational task                                                                    | **cert-manager + Let's Encrypt + ClusterIssuer** automate certificate issuance and renewal                                        |
| Fixed number of backend processes              | Traffic/load can change over time                                                                                        | **Horizontal Pod Autoscaler** scales the backend based on CPU/memory metrics                                                      |
| Single application deployment                  | A node failure can take all application containers down                                                                  | Pods are distributed between the two worker nodes using **topologySpreadConstraints**                                             |
| Application manually deployed from workstation | Local machine becomes part of the deployment process                                                                     | **Argo CD** continuously reconciles the Kubernetes manifests from GitHub                                                          |

### Important PostgreSQL limitation

Your current PostgreSQL design is:

```text
PostgreSQL StatefulSet
        │
        ▼
       PVC
        │
        ▼
K3s local-path storage
```

This gives PostgreSQL **persistent storage across Pod restarts**, but it is **not equivalent to highly available replicated database storage**.

Because the PVC is backed by K3s local-path storage, the PostgreSQL data is tied to the node where that volume exists. If that worker node permanently fails, PostgreSQL does not automatically become a fully replicated database on another node.

For this capstone architecture, this is an acceptable simplification, but you should be transparent about it in your documentation.

---

# 5. Choices & trade-offs

### Raw YAML vs Helm vs Kustomize — why

**Kustomize** was chosen because the project already uses a `kustomization.yaml` and consists of relatively small, application-specific Kubernetes manifests.

The structure is:

```text
manifests/
├── namespace.yaml
├── configmap.yaml
├── sealed-secret.yaml
├── backend/
├── frontend/
├── postgres/
├── migration/
├── pdb/
└── ingress/
    ├── clusterissuer.yaml
    └── ingress.yaml
```

Kustomize allows these resources to be managed as one application without introducing the additional complexity of a Helm chart.

Argo CD then watches the Git repository and applies the desired state to the K3s cluster.

---

### ingress-nginx vs K3s Traefik — why

The project uses **ingress-nginx** instead of the Traefik controller bundled with K3s.

The reason is consistency with the project's NGINX-based HTTP configuration and the requirement to use NGINX as the Kubernetes ingress layer.

The traffic path is therefore:

```text
Internet
   │
   ▼
NGINX Ingress Controller
   │
   ├── /
   │    └── frontend:80
   │
   └── /api
        └── backend:5000
```

---



### Secrets approach — Sealed Secrets

The project uses **Bitnami Sealed Secrets**.

Instead of committing:

```text
Secret
   ↓
plaintext password
   ↓
GitHub
```

the workflow is:

```text
Local Secret
     │
     │ kubeseal
     ▼
SealedSecret
     │
     ▼
GitHub
     │
     ▼
Argo CD
     │
     ▼
K3s
     │
     ▼
Sealed Secrets Controller
     │
     ▼
Kubernetes Secret
     │
     ▼
Backend / PostgreSQL
```

This allows the encrypted secret manifest to be stored in the GitOps repository without exposing the plaintext database password, Flask `SECRET_KEY`, or JWT secret.

---

## Final architecture summary

Your project can therefore be summarized as:

```text
                    GitHub
                       │
                       ▼
                    Argo CD
                       │
                       ▼
                  ┌─────────┐
                  │   K3s   │
                  │ Cluster │
                  └────┬────┘
                       │
       ┌───────────────┼────────────────┐
       │               │                │
       ▼               ▼                ▼
   Worker 1        Worker 2       Control Plane
       │               │                │
       ├─ Frontend     ├─ Frontend      ├─ Argo CD
       └─ Backend      └─ Backend       ├─ cert-manager
                                        ├─ Sealed Secrets
                                        ├─ Metrics Server
                                        └─ NGINX
                                             │
Internet ──► DNS ──► AWS SG ──► NGINX ─────┤
                                             │
                           ┌─────────────────┴──────┐
                           │                        │
                      Frontend                  Backend
                       :80                       :5000
                                                    │
                                                    ▼
                                               PostgreSQL
                                                  :5432
                                                    │
                                                    ▼
                                                  PVC
                                           K3s local-path
```

