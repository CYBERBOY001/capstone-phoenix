# Runbook — Capstone Phoenix

> **Purpose:** A teammate should be able to operate, troubleshoot, recover, and demonstrate the Capstone Phoenix application using this document.
>
> **Environment:** AWS EC2 + k3s + Kubernetes + Docker/OCI images + GHCR + NGINX Ingress + cert-manager + Let's Encrypt + Argo CD + PostgreSQL.
>
> **Important:** Replace placeholders such as `<NODE_NAME>` and `<POD_NAME>` with values from the cluster. Never commit Kubernetes Secrets, private keys, kubeconfig files, or cloud credentials.

---

## 1. Prerequisites & Environment Setup

Verify required CLI tools:

```bash
kubectl version --client
docker --version
git --version
terraform -version
ansible --version
```

Authenticate AWS CLI:

```bash
aws configure
aws sts get-caller-identity
```

Configure Terraform environment:

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```terraform
project_name        = ""
environment         = ""
aws_region          = ""

vpc_cidr            = ""
public_subnet_cidrs = []
availability_zones  = []

ami_id              = ""
instance_type       = ""
worker_count        = 2
key_name            = ""

allowed_ssh_cidrs   = []
```

Provision infrastructure:

```bash
terraform init
terraform fmt
terraform validate
terraform plan -var-file="terraform.tfvars" -out="capstone"
terraform apply capstone
```

Update `tls-san: ip` in `group_vars/all.yml` to the Control Plane public IP.

Verify SSH connectivity to all 3 nodes before proceeding:

```bash
ssh -i ~/.ssh/capstone-key.pem ubuntu@<node-public-ip>
```

Provision cluster with Ansible:

```bash
cd infra/ansible
./scripts/generate_inventory.sh
ansible-playbook -i inventory/hosts.ini playbook/site.yml
```

Export `kubeconfig`:

```bash
export KUBECONFIG=/home/mkaey/capstone-phoenix/infra/ansible/kubeconfig/config
kubectl get nodes -o wide
```

---

## 2. Core Infrastructure Deployment

Install NGINX Ingress, Sealed Secrets, cert-manager, ClusterIssuer, and Argo CD:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml

kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

kubectl apply -f manifests/ingress/clusterissuer.yaml

kubectl create namespace argocd

kubectl apply --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  -n argocd
```

Install `kubeseal` locally and generate encrypted secrets:

```bash
VERSION=$(curl -fsSL https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r .tag_name)

curl -LO https://github.com/bitnami-labs/sealed-secrets/releases/download/${VERSION}/kubeseal-${VERSION#v}-linux-amd64.tar.gz

tar -xzf kubeseal-*.tar.gz

sudo install kubeseal /usr/local/bin/
```

```bash
kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --kubeconfig "$HOME/capstone-phoenix/infra/ansible/kubeconfig/config" \
  -f secret.yaml \
  -w sealed-secret.yaml
```

> **Note:**
>
> 1. Create an `A` record pointing to your Control Plane IP in your DNS management dashboard.
>
> 2. Update your Ingress manifest hostname and Docker image references in the frontend, backend, and Kustomization manifests to reflect your custom domain and container registry.
>
> 3. Push all changes to GitHub for Argo CD reconciliation.

Deploy application via GitOps:

```bash
kubectl apply -f gitops/application.yaml
```

---

## 3. GitOps Verification (Argo CD)

Verify application sync status:

```bash
kubectl get applications -n argocd
```

**Expected output:**

```text
NAME      SYNC STATUS   HEALTH STATUS
taskapp   Synced        Healthy
```

Inspect application details:

```bash
kubectl describe application taskapp -n argocd

# Alternatively, via Argo CD CLI:
argocd app get taskapp
```

### Scaling Workloads (GitOps Workflow)

To scale frontend replicas (e.g., 2 → 3), update the manifest in Git:

```bash
git status
git add .
git commit -m "Update TaskApp frontend replicas to 3"
git push
```

Monitor reconciliation:

```bash
kubectl get applications -n argocd -w
```

*Prefer Git commits over manual* `kubectl edit` *or* `kubectl scale` *commands; Argo CD serves as the single source of truth.*

---

## 4. Workload Topology Inspection

Check frontend pods:

```bash
kubectl get pods -n phoenix -l app=frontend -o wide
```

Check backend pods:

```bash
kubectl get pods -n phoenix -l app=backend -o wide
```

Inspect deployment specifications:

```bash
kubectl describe deployment frontend -n phoenix
kubectl describe deployment backend -n phoenix
```

---

## 5. Backend Troubleshooting

Check pod health and logs:

```bash
kubectl get pods -n phoenix -l app=backend -o wide
kubectl logs -n phoenix <BACKEND_POD>
kubectl logs -n phoenix <BACKEND_POD> --previous
kubectl logs -f -n phoenix <BACKEND_POD>
kubectl describe pod -n phoenix <BACKEND_POD>
```

Test cluster-internal Service connectivity:

```bash
# Root endpoint test
kubectl run backend-debug \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -n phoenix \
  -- curl -v http://backend:5000/

# API endpoint test
kubectl run backend-debug \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -n phoenix \
  -- curl -v http://backend:5000/api/
```

> **Note:** A `404` status code indicates network reachability. Ensure you test endpoints actually defined in the application routing (e.g., Flask routes).

---

## 6. Frontend Troubleshooting

Inspect pods and logs:

```bash
kubectl get pods -n phoenix -l app=frontend -o wide
kubectl logs -n phoenix <FRONTEND_POD>
kubectl logs -n phoenix <FRONTEND_POD> --previous
```

Test NGINX configurations:

```bash
# Validate syntax
kubectl exec -n phoenix deploy/frontend -- nginx -t

# Inspect active configurations
kubectl exec -n phoenix deploy/frontend -- cat /etc/nginx/conf.d/default.conf
kubectl exec -n phoenix deploy/frontend -- cat /etc/nginx/nginx.conf
```

Test internal DNS resolution and service routing:

```bash
kubectl exec -n phoenix deploy/frontend -- \
  nslookup backend.phoenix.svc.cluster.local

kubectl exec -n phoenix deploy/frontend -- \
  wget -S -O- http://backend.phoenix.svc.cluster.local:5000/
```

---

## 7. NGINX Frontend Architecture

The frontend uses a multi-stage Docker file:

1. **Build:** Node compiles the React/Vite application.

2. **Serving:** NGINX serves static files from `/dist`.

3. **Proxy:** NGINX proxies `/api/` calls to the backend Service.

Proxy configuration snippet:

```nginx
location /api/ {
    resolver 10.43.0.10 valid=10s ipv6=off;
    proxy_pass http://backend.phoenix.svc.cluster.local:5000/api/;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

---

## 8. Non-Root Container Security

The frontend container executes under non-privileged credentials:

```text
uid=101(nginx)
gid=101(nginx)
```

If NGINX outputs the following error:

```text
open() "/run/nginx.pid" failed (13: Permission denied)
```

Ensure the PID path points to a directory writable by non-root users inside `nginx.conf`:

```nginx
pid /tmp/nginx.pid;
```

---

## 9. Kubernetes Service Discovery & DNS

Verify CoreDNS operational status:

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl get svc -n kube-system kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
```

Execute DNS lookup tests:

```bash
# External cluster test
kubectl run dns-test \
  --rm -it \
  --restart=Never \
  --image=busybox:1.36 \
  -n phoenix \
  -- nslookup kubernetes.default.svc.cluster.local

# Service resolution test
kubectl run dns-test \
  --rm -it \
  --restart=Never \
  --image=busybox:1.36 \
  -n phoenix \
  -- nslookup backend.phoenix.svc.cluster.local
```

---

## 10. Ingress Configuration & Diagnostics

Inspect Ingress resource state:

```bash
kubectl get ingress -n phoenix
kubectl describe ingress phoenix-ingress -n phoenix
kubectl get ingress phoenix-ingress -n phoenix -o yaml
```

**Expected routing setup:**

* **Host:** `taskapp.com.ng`
* **Paths:** `/` → `frontend:80`, `/api` → `backend:5000`

Inspect Ingress Controller status and logs:

```bash
kubectl get pods -n ingress-nginx -o wide
kubectl get svc -n ingress-nginx -o wide
kubectl get ingressclass
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller
```

---

## 11. External DNS Verification

Verify domain resolution against authoritative and public resolvers:

```bash
# Authoritative resolvers
dig +short taskapp.com.ng @nsa.whogohost.com
dig +short taskapp.com.ng @nsb.whogohost.com

# Public resolvers
dig +short taskapp.com.ng @8.8.8.8
dig +short taskapp.com.ng @1.1.1.1

# Local system resolver
resolvectl query taskapp.com.ng
```

---

## 12. TLS Certificate Management (cert-manager)

Inspect issuers, certificates, and ACME challenge states:

```bash
kubectl get clusterissuer
kubectl get certificate -n phoenix
kubectl describe certificate phoenix-tls -n phoenix

kubectl get certificaterequest -n phoenix
kubectl get order -n phoenix
kubectl get challenge -n phoenix
kubectl describe challenge -n phoenix
kubectl logs -n cert-manager deployment/cert-manager
```

Verify TLS handshakes externally:

```bash
curl -vI https://taskapp.com.ng
curl -I https://taskapp.com.ng/healthz
```

---

## 13. HTTP-01 ACME Challenge Diagnostics

The HTTP-01 challenge expects accessibility at:

```text
http://taskapp.com.ng/.well-known/acme-challenge/<TOKEN>
```

Inspect transient solver resources:

```bash
kubectl get ingress -n phoenix | grep acme
kubectl get pods -n phoenix | grep acme
kubectl describe challenge -n phoenix
```

Test challenge resolution externally:

```bash
# Via Domain
curl -v --max-time 10 http://taskapp.com.ng/.well-known/acme-challenge/<TOKEN>

# Direct via Ingress IP
curl -v --max-time 10 \
  -H "Host: taskapp.com.ng" \
  http://<PUBLIC_IP>/.well-known/acme-challenge/<TOKEN>
```

---

## 14. Image Release Workflows

### Frontend Image Build & Deploy

```bash
docker build -t ghcr.io/cyberboy001/taskapp-frontend:<VERSION> .

# Validate locally
docker run --rm ghcr.io/cyberboy001/taskapp-frontend:<VERSION> nginx -t

# Publish to Registry
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <GITHUB_USERNAME> --password-stdin
docker push ghcr.io/cyberboy001/taskapp-frontend:<VERSION>
```

Update tag in Git repository, then verify rollout:

```bash
kubectl get pods -n phoenix
kubectl rollout status deployment/frontend -n phoenix
```

### Backend Image Build & Deploy

```bash
docker build -t ghcr.io/cyberboy001/taskapp-backend:<VERSION> .
docker push ghcr.io/cyberboy001/taskapp-backend:<VERSION>
```

Update tag in Git repository, then verify rollout:

```bash
kubectl rollout status deployment/backend -n phoenix
kubectl get pods -n phoenix -l app=backend -o wide
```

---

## 15. Persistence & Failover Testing (PostgreSQL)

Inspect state and storage bindings:

```bash
kubectl get pods -n phoenix -l app=postgres -o wide
kubectl get pvc -n phoenix
```

Execute stateful data modification test:

```bash
# Insert record
kubectl exec -it postgres-0 -n phoenix -- \
  psql -U <DATABASE_USER> -d <DATABASE_NAME> \
  -c "INSERT INTO tasks (title) VALUES ('pvc-persistence-test');"

# Simulate Pod failure
kubectl delete pod postgres-0 -n phoenix

# Monitor recovery
kubectl get pods -n phoenix -o wide -w

# Validate persistence
kubectl exec -it postgres-0 -n phoenix -- \
  psql -U <DATABASE_USER> -d <DATABASE_NAME> \
  -c "SELECT * FROM tasks WHERE title='pvc-persistence-test';"
```

---

## 16. Common Failure Scenarios

### Frontend CrashLoopBackOff

* Check error with `kubectl logs -n phoenix <FRONTEND_POD> --previous`.

* **`unknown directive "nginx"`:** Text/Markdown rendering error in configuration files.

* **`Permission denied`** on PID file: Running as non-root user. Update configuration to write to a non-privileged location (e.g., `pid /tmp/nginx.pid;`).

### NGINX Service Resolution Failures

* Error: `host not found in upstream "backend.phoenix.svc.cluster.local"`

* Verify Kubernetes backend Service status (`kubectl get svc backend -n phoenix`).

* Verify intra-cluster DNS configuration via `busybox` or `curl` test pods.

### Route 404 Exceptions

* A `404` response confirms reachability via Ingress/Service routing; verify application-level endpoints and backend route handling explicitly.

---

## 17. Operational Checklists

### Safe Maintenance Workflow

```bash
# Pre-maintenance assessment
kubectl get nodes
kubectl get pods -n phoenix -o wide
kubectl get deployment -n phoenix
kubectl get certificate -n phoenix
kubectl get hpa -n phoenix
kubectl get applications -n argocd

# Post-maintenance validation
kubectl get nodes
kubectl get pods -n phoenix -o wide
kubectl get pvc -n phoenix
kubectl get certificate -n phoenix
kubectl get hpa -n phoenix
kubectl get applications -n argocd
curl -I https://taskapp.com.ng
```

### Final Acceptance Checklist

| **Component**         | **Verification Command**                            | **Expected Result**                    |
| --------------------- | --------------------------------------------------- | -------------------------------------- |
| **Nodes & Workloads** | `kubectl get nodes` / `kubectl get pods -n phoenix` | All nodes `Ready`; Workloads `Running` |
| **HTTP/HTTPS**        | `curl -I https://taskapp.com.ng`                    | `HTTP/2 200`                           |
| **Certificates**      | `kubectl get certificate -n phoenix`                | `READY: True`                          |
| **Ingress**           | `kubectl get ingress -n phoenix`                    | Domain routed correctly                |
| **GitOps Engine**     | `kubectl get applications -n argocd`                | `Synced` / `Healthy`                   |

---

## 18. Quick Reference Commands

```bash
# Cluster Overview
kubectl get nodes -o wide
kubectl get all -n phoenix
kubectl get events -n phoenix --sort-by='.lastTimestamp'

# Ingress & Security
kubectl get ingress -n phoenix
kubectl get certificate -n phoenix

# GitOps Status
kubectl get applications -n argocd

# Resource Metrics
kubectl top nodes
kubectl top pods -n phoenix

# Pod Debugging
kubectl exec -n phoenix deploy/frontend -- nginx -t
```

---

## 19. Submission Evidence Structure

Store submission artifacts under the following schema:

```text
evidence/
├── nodes-ready.png
├── pods-spread.png
├── tls-valid.png
├── pvc-persist.log
├── zero-downtime.log
├── hpa-scale.png
├── argocd-synced.png
└── failover.png
```

---

## 20. Operational Principles

**Git is the single source of truth.**



Use direct `kubectl` operations strictly for diagnostics, temporary troubleshooting, or emergency interventions. All permanent state and configuration updates must be committed directly to Git.
