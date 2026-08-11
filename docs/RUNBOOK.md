# Runbook — Capstone Phoenix

> **Purpose:** A teammate should be able to operate, troubleshoot, recover, and demonstrate the Capstone Phoenix application using this document.
>
> **Environment:** AWS EC2 + k3s + Kubernetes + Docker/OCI images + GHCR + NGINX Ingress + cert-manager + Let's Encrypt + Argo CD + PostgreSQL.
>
> **Important:** Replace placeholders such as `<NODE_NAME>` and `<POD_NAME>` with values from the cluster. Never commit Kubernetes Secrets, private keys, kubeconfig files, or cloud credentials.



# 2. Prerequisites

Verify the tools:

```bash
kubectl version --client
docker --version
git --version
terraform -version
ansible --version
```
```bash
aws configure          # Authenticate and set default region/output
aws sts get-caller-identity # Confirm active account, IAM user/role, and ARN


```
``` bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
```

 Edit the terraform.tfvar

``` bash
project_name        = 
environment         = 
aws_region          = 

vpc_cidr            = 
public_subnet_cidrs = 
availability_zones  = 

ami_id              = 
instance_type       = 
worker_count        = 
key_name            = 

allowed_ssh_cidrs   = 
```

```bash
terraform init
terraform fmt 
terraform validate
terraform plan -var-file="terraform.tfvar" -out="capstone"
terraform apply capstone
```

Edit the tls-san: ip in group_vars/all.yml to control plane public ip

Test all 3 nodes before proceeding:
```bash
ssh -i /.ssh/capstone-key.pem ubuntu@<node-public-ip>
```

Copy terraform outputs to hosts.ini
```bash
 cd  infra/ansible
./scripts/generate_inventory.sh
ansible-playbook -i inventory/hosts.ini playbook/site.yml

```
Export kubeconfig
```bash
export KUBECONFIG=/home/mkaey/capstone-phoenix/infra/ansible/kubeconfig/config
kubectl get node -o
```
Install nginx-ingress,sealed-secrets,cert-manager, clusterissuer and Agrocd on your cluster
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
 
kubectl apply \
-f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl apply -f manifests/ingress/clusterissuer.yaml

kubectl create namespace agrocd
kubectl apply --server-side \
-f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
-n argocd
```

install kubeseal locally
```bash
VERSION=$(curl -fsSL https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r .tag_name)

curl -LO https://github.com/bitnami-labs/sealed-secrets/releases/download/${VERSION}/kubeseal-${VERSION#v}-linux-amd64.tar.gz

tar -xzf kubeseal-*.tar.gz

sudo install kubeseal /usr/local/bin/

kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --kubeconfig "$HOME/capstone-phoenix/infra/ansible/kubeconfig/config" \
  -f secret.yaml \
  -w sealed-secret.yaml
```  
NOTE: create a dns record with your control plane ip
in dns management dashboard of domain name provider. edit your ingress manifest host name to match your own domain and also docker images in the
frontend,backend amd kustomization mainfest. if you have your own docker image to use.
Then push changes to github for agrocd to use update manifest aslo

```bash 
kubectl apply -f gitops/application.yaml
```



Check Argo CD applications:

```bash
kubectl get applications -n argocd
```

Expected:

```text
NAME      SYNC STATUS   HEALTH STATUS
taskapp   Synced        Healthy
```

Detailed:

```bash
kubectl describe application taskapp -n argocd
```

If the Argo CD CLI is available:

```bash
argocd app get taskapp
```

Expected:

```text
Synced
Healthy
```
bump frontend replicas 2→3
After changing manifests:

```bash
git status
git add .
git commit -m "Update TaskApp deployment"
git push
```

Then:

```bash
kubectl get applications -n argocd -w
```

Prefer Git commits over manual `kubectl edit` or `kubectl scale` changes because Argo CD is the GitOps source of truth.

---







For frontend:

```bash
kubectl get pods -n phoenix -l app=frontend -o wide
```

For backend:

```bash
kubectl get pods -n phoenix -l app=backend -o wide
```

Look at the `NODE` column.

Useful deployment inspection:

```bash
kubectl describe deployment frontend -n phoenix
kubectl describe deployment backend -n phoenix
```

---

# 6. Backend Troubleshooting

## Check backend pods

```bash
kubectl get pods -n phoenix -l app=backend -o wide
```

## View current logs

```bash
kubectl logs -n phoenix <BACKEND_POD>
```

## View logs from the previous crashed container

```bash
kubectl logs -n phoenix <BACKEND_POD> --previous
```

## Follow logs

```bash
kubectl logs -f -n phoenix <BACKEND_POD>
```

## Describe backend pod

```bash
kubectl describe pod -n phoenix <BACKEND_POD>
```

## Test backend Service from inside the cluster

```bash
kubectl run backend-debug \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -n phoenix \
  -- curl -v http://backend:5000/
```

Test the API:

```bash
kubectl run backend-debug \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -n phoenix \
  -- curl -v http://backend:5000/api/
```

A `404` is not necessarily a networking failure. It can simply mean that `/api/` is not an implemented backend route. Test an endpoint that actually exists in the Flask application.

---

# 7. Frontend Troubleshooting

## Check frontend pods

```bash
kubectl get pods -n phoenix -l app=frontend -o wide
```

## Logs

```bash
kubectl logs -n phoenix <FRONTEND_POD>
```

Previous crash:

```bash
kubectl logs -n phoenix <FRONTEND_POD> --previous
```

## NGINX configuration test

```bash
kubectl exec -n phoenix deploy/frontend -- nginx -t
```

Expected:

```text
syntax is ok
test is successful
```

## Check NGINX configuration

```bash
kubectl exec -n phoenix deploy/frontend -- \
  cat /etc/nginx/conf.d/default.conf
```

Check the main NGINX configuration:

```bash
kubectl exec -n phoenix deploy/frontend -- \
  cat /etc/nginx/nginx.conf
```

## Test DNS from the frontend pod

```bash
kubectl exec -n phoenix deploy/frontend -- \
  nslookup backend.phoenix.svc.cluster.local
```

Expected:

```text
Name: backend.phoenix.svc.cluster.local
Address: <backend-service-cluster-ip>
```

## Test backend connectivity from frontend

```bash
kubectl exec -n phoenix deploy/frontend -- \
  wget -S -O- http://backend.phoenix.svc.cluster.local:5000/
```

If `/` returns `404`, test a real API endpoint.

---

# 8. NGINX Frontend Configuration

The frontend container is a multi-stage image:

1. Node builds the React/Vite application.
2. NGINX serves only `/dist`.
3. NGINX proxies `/api/` to the Kubernetes backend Service.

The important API proxy pattern is:

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

Do not put Markdown fences or literal text such as  nginx  inside the actual NGINX configuration.

---

# 9. NGINX Non-Root Container Troubleshooting

The frontend container runs as:

```text
uid=101(nginx)
gid=101(nginx)
```

If NGINX reports:

```text
open() "/run/nginx.pid" failed (13: Permission denied)
```

the NGINX PID path needs to be writable by the non-root user.

Inspect:

```bash
kubectl exec -n phoenix deploy/frontend -- \
  cat /etc/nginx/nginx.conf
```

A non-root configuration should use a writable PID location, for example:

```nginx
pid /tmp/nginx.pid;
```

Temporary runtime test:

```bash
kubectl exec -n phoenix deploy/frontend -- nginx -t
```

---

# 10. Kubernetes Service Discovery / DNS

Check CoreDNS:

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

Check the DNS Service:

```bash
kubectl get svc -n kube-system kube-dns
```

Check CoreDNS logs:

```bash
kubectl logs -n kube-system -l k8s-app=kube-dns
```

Test Kubernetes DNS:

```bash
kubectl run dns-test \
  --rm -it \
  --restart=Never \
  --image=busybox:1.36 \
  -n phoenix \
  -- nslookup kubernetes.default.svc.cluster.local
```

Test backend DNS:

```bash
kubectl run dns-test \
  --rm -it \
  --restart=Never \
  --image=busybox:1.36 \
  -n phoenix \
  -- nslookup backend.phoenix.svc.cluster.local
```

---

# 11. Ingress

## Check ingress

```bash
kubectl get ingress -n phoenix
```

## Detailed ingress

```bash
kubectl describe ingress phoenix-ingress -n phoenix
```

## YAML

```bash
kubectl get ingress phoenix-ingress -n phoenix -o yaml
```

Expected host:

```text
taskapp.com.ng
```

Expected routes:

```text
/       -> frontend:80
/api    -> backend:5000
```

## Check ingress controller

```bash
kubectl get pods -n ingress-nginx -o wide
kubectl get svc -n ingress-nginx -o wide
kubectl get ingressclass
```

Ingress controller logs:

```bash
kubectl logs -n ingress-nginx \
  deployment/ingress-nginx-controller
```

---

# 12. DNS Verification

The public DNS record for:

```text
taskapp.com.ng
```

must resolve to the current public ingress/load-balancer IP.

Check authoritative nameservers:

```bash
dig +short taskapp.com.ng @nsa.whogohost.com
dig +short taskapp.com.ng @nsb.whogohost.com
```

Check public resolvers:

```bash
dig +short taskapp.com.ng @8.8.8.8
dig +short taskapp.com.ng @1.1.1.1
```

Check local resolution:

```bash
resolvectl query taskapp.com.ng
```

If different public IPs appear, investigate DNS propagation/caching and the authoritative DNS records.

---

# 13. TLS / cert-manager

## ClusterIssuer

```bash
kubectl get clusterissuer
```

Expected:

```text
letsencrypt-prod   True
```

## Certificate

```bash
kubectl get certificate -n phoenix
```

Detailed:

```bash
kubectl describe certificate phoenix-tls -n phoenix
```

## CertificateRequest

```bash
kubectl get certificaterequest -n phoenix
```

## ACME Orders

```bash
kubectl get order -n phoenix
```

## ACME Challenges

```bash
kubectl get challenge -n phoenix
```

Detailed challenge:

```bash
kubectl describe challenge -n phoenix
```

## cert-manager logs

```bash
kubectl logs -n cert-manager \
  deployment/cert-manager
```

## Verify the certificate externally

```bash
curl -vI https://taskapp.com.ng
```

Look for:

```text
subject: CN=taskapp.com.ng
issuer: Let's Encrypt
SSL certificate verify ok
```

Check the application:

```bash
curl -I https://taskapp.com.ng
```

Health endpoint:

```bash
curl -I https://taskapp.com.ng/healthz
```

---

# 14. HTTP-01 ACME Troubleshooting

The HTTP-01 challenge requires external access to:

```text
http://taskapp.com.ng/.well-known/acme-challenge/<TOKEN>
```

Check the temporary solver:

```bash
kubectl get ingress -n phoenix | grep acme
kubectl get pods -n phoenix | grep acme
```

Check challenge:

```bash
kubectl describe challenge -n phoenix
```

Test from outside the cluster:

```bash
curl -v --max-time 10 \
  http://taskapp.com.ng/.well-known/acme-challenge/<TOKEN>
```

The response should be HTTP `200` and contain the expected challenge value.

Test directly against the ingress public IP:

```bash
curl -v --max-time 10 \
  -H "Host: taskapp.com.ng" \
  http://<PUBLIC_IP>/.well-known/acme-challenge/<TOKEN>
```

Do not confuse an old/stale DNS IP with the current EC2/load-balancer IP.

---



# 16. Deploy a New Frontend Image

Build:

```bash
docker build -t ghcr.io/cyberboy001/taskapp-frontend:<VERSION> .
```

Test locally:

```bash
docker run --rm \
  ghcr.io/cyberboy001/taskapp-frontend:<VERSION> \
  nginx -t
```

Login to GHCR:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <GITHUB_USERNAME> --password-stdin
```

Push:

```bash
docker push ghcr.io/cyberboy001/taskapp-frontend:<VERSION>
```

Update the Kubernetes manifest/Kustomize image tag in Git, then commit and push.

Verify:

```bash
kubectl get pods -n phoenix
kubectl rollout status deployment/frontend -n phoenix
```

---

# 17. Deploy a New Backend Image

Build:

```bash
docker build -t ghcr.io/cyberboy001/taskapp-backend:<VERSION> .
```

Push:

```bash
docker push ghcr.io/cyberboy001/taskapp-backend:<VERSION>
```

Update the image tag in Git.

Verify:

```bash
kubectl rollout status deployment/backend -n phoenix
kubectl get pods -n phoenix -l app=backend -o wide
```

---



# 19. PostgreSQL / PVC Persistence Test

Find the PostgreSQL pod:

```bash
kubectl get pods -n phoenix -l app=postgres -o wide
```

Check PVC:

```bash
kubectl get pvc -n phoenix
```

Write test data using the application's database credentials:

```bash
kubectl exec -it postgres-0 -n phoenix -- \
  psql -U <DATABASE_USER> -d <DATABASE_NAME> \
  -c "INSERT INTO tasks (title) VALUES ('pvc-persistence-test');"
```

Delete the PostgreSQL pod:

```bash
kubectl delete pod postgres-0 -n phoenix
```

Watch recovery:

```bash
kubectl get pods -n phoenix -o wide -w
```

Verify the data:

```bash
kubectl exec -it postgres-0 -n phoenix -- \
  psql -U <DATABASE_USER> -d <DATABASE_NAME> \
  -c "SELECT * FROM tasks WHERE title='pvc-persistence-test';"
```

Verify PVC:

```bash
kubectl get pvc -n phoenix
```

The PVC should remain `Bound`.

---



# 27. Common Failure: Frontend CrashLoopBackOff

Check:

```bash
kubectl get pods -n phoenix
kubectl logs -n phoenix <FRONTEND_POD> --previous
```

If you see:

```text
unknown directive "nginx"
```

inspect:

```bash
kubectl exec -n phoenix <FRONTEND_POD> -- \
  cat /etc/nginx/nginx.conf
```

Check for accidental Markdown/code-fence text in the NGINX file.

If you see:

```text
open() "/run/nginx.pid" failed (13: Permission denied)
```

the container is running as non-root and NGINX is trying to write its PID file somewhere not writable.

Use a writable PID path such as:

```nginx
pid /tmp/nginx.pid;
```

Then rebuild and push the image.

---

# 28. Common Failure: NGINX Cannot Resolve Backend

Error:

```text
host not found in upstream "backend.phoenix.svc.cluster.local"
```

Check Service:

```bash
kubectl get svc backend -n phoenix
```

Check DNS:

```bash
kubectl run dns-debug \
  --rm -it \
  --restart=Never \
  --image=busybox:1.36 \
  -n phoenix \
  -- nslookup backend.phoenix.svc.cluster.local
```

Check CoreDNS:

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
```

If DNS works inside the cluster but `docker run ... nginx -t` fails on the local machine, that is expected: the local Docker container is outside the Kubernetes DNS domain.

Validate Kubernetes NGINX configuration from inside the cluster:

```bash
kubectl exec -n phoenix deploy/frontend -- nginx -t
```

---

# 29. Common Failure: API Returns 404

Test the backend directly:

```bash
kubectl run api-debug \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -n phoenix \
  -- curl -v http://backend:5000/
```

Test the exact API endpoint:

```bash
kubectl run api-debug \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -n phoenix \
  -- curl -v http://backend:5000/<REAL_API_ENDPOINT>
```

Then test through Ingress:

```bash
curl -v https://taskapp.com.ng/<API_ENDPOINT>
```

A backend `404` proves that traffic reached the backend but the requested route does not exist.

---

# 30. Common Failure: Certificate Not Ready

```bash
kubectl get certificate -n phoenix
kubectl get order -n phoenix
kubectl get challenge -n phoenix
kubectl describe challenge -n phoenix
```

Check DNS:

```bash
dig +short taskapp.com.ng @8.8.8.8
dig +short taskapp.com.ng @1.1.1.1
```

Check HTTP-01:

```bash
curl -v http://taskapp.com.ng/.well-known/acme-challenge/<TOKEN>
```

Check ingress:

```bash
kubectl get ingress -n phoenix
kubectl get svc -n ingress-nginx -o wide
```

When fixed, certificate should eventually show:

```text
READY   True
```

Verify:

```bash
kubectl get certificate -n phoenix
curl -vI https://taskapp.com.ng
```



# 34. Useful Cluster Commands

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get svc -A
kubectl get ingress -A
kubectl get pvc -A
kubectl get certificate -A
kubectl get hpa -A
kubectl get jobs -A
```

Events:

```bash
kubectl get events -n phoenix --sort-by='.lastTimestamp'
```

Resource usage:

```bash
kubectl top nodes
kubectl top pods -n phoenix
```

---

# 35. Safe Maintenance Checklist

Before maintenance:

```bash
kubectl get nodes
kubectl get pods -n phoenix -o wide
kubectl get deployment -n phoenix
kubectl get certificate -n phoenix
kubectl get hpa -n phoenix
kubectl get applications -n argocd
```

Confirm:

- All required nodes are Ready.
- Backend replicas are healthy.
- Frontend replicas are healthy.
- PostgreSQL is Running.
- PVC is Bound.
- Certificate is Ready.
- Argo CD is Synced and Healthy.

After maintenance:

```bash
kubectl get nodes
kubectl get pods -n phoenix -o wide
kubectl get pvc -n phoenix
kubectl get certificate -n phoenix
kubectl get hpa -n phoenix
kubectl get applications -n argocd
curl -I https://taskapp.com.ng
```

---

# 36. Final Acceptance Checklist

## Kubernetes

```bash
kubectl get nodes
kubectl get pods -n phoenix
kubectl get pods -n phoenix -o wide
```

All required workloads should be healthy.

## Application

```bash
curl -I https://taskapp.com.ng
curl -I https://taskapp.com.ng/healthz
```

Expected:

```text
HTTP/2 200
```

## TLS

```bash
kubectl get certificate -n phoenix
```

Expected:

```text
READY   True
```

## Ingress

```bash
kubectl get ingress -n phoenix
```

Expected host:

```text
taskapp.com.ng
```

## GitOps

```bash
kubectl get applications -n argocd
```

Expected:

```text
taskapp   Synced   Healthy
```


# 37. Quick Reference

```bash
# Nodes
kubectl get nodes -o wide

# Phoenix workloads
kubectl get all -n phoenix

# Pods
kubectl get pods -n phoenix -o wide

# Logs
kubectl logs -n phoenix <POD>
kubectl logs -n phoenix <POD> --previous

# Events
kubectl get events -n phoenix --sort-by='.lastTimestamp'

# Services
kubectl get svc -n phoenix

# Ingress
kubectl get ingress -n phoenix

# TLS
kubectl get certificate -n phoenix
kubectl get order -n phoenix
kubectl get challenge -n phoenix

# Argo CD
kubectl get applications -n argocd

# HPA
kubectl get hpa -n phoenix
kubectl top pods -n phoenix

# Storage
kubectl get pvc -n phoenix

# NGINX
kubectl exec -n phoenix deploy/frontend -- nginx -t

# DNS
kubectl run dns-debug --rm -it --restart=Never \
  --image=busybox:1.36 -n phoenix -- \
  nslookup backend.phoenix.svc.cluster.local

# Public application
curl -I https://taskapp.com.ng
curl -I https://taskapp.com.ng/healthz
```

---

## 38. Evidence Directory

For the final project submission, keep evidence under:

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

The evidence should be generated from the live cluster rather than manually edited.

---

## 39. Operational Principle

**Git is the source of truth.**

Use:

```text
Git commit
    ↓
GitHub
    ↓
Argo CD
    ↓
Kubernetes
    ↓
TaskApp
```

Use direct `kubectl` changes for diagnostics, emergency recovery, or demonstrations. Permanent application configuration changes should be committed to Git so Argo CD can reconcile the desired state.
