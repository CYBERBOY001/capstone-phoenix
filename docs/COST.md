# Cost

This TaskApp deployment is designed to run within the **AWS Free Tier**, so the infrastructure cost is approximately **$0/month**, assuming the AWS account remains eligible for the applicable Free Tier allowances and usage stays within those limits.

## Monthly itemized cost

| Item                            | Spec                                       | Qty |            $/mo |
| ------------------------------- | ------------------------------------------ | --: |----------------:|
| Control-plane VM                | AWS EC2 Free Tier eligible instance        |   1 |          **$0** |
| Worker VMs                      | AWS EC2 Free Tier eligible instances       |   2 |         **$0*** |
| Load balancer / Elastic IP      | NGINX Ingress on EC2; no AWS Load Balancer |   0 |          **$0** |
| Block storage (PVC)             | K3s local-path PVC                         |   1 |         **$0*** |
| Object storage (state, backups) | S3 for Terraform remote state              |   1 |         **$0*** |
| DNS / domain                    | `taskapp.com.ng`                           |   1 |   **$3/yearly** |
| **Total AWS infrastructure**    |                                            |     | **≈ $0/month*** |

* Subject to the account's Free Tier eligibility, included usage limits, and current AWS pricing. Your PostgreSQL PVC is **K3s local-path storage**, not an EBS-backed PVC, so there is no separate EBS volume for the PostgreSQL data in this architecture.

### Important clarification about the three EC2 instances

Your cluster uses:

```text
EC2 1 → K3s Control Plane
EC2 2 → K3s Worker
EC2 3 → K3s Worker
```

The main cost advantage is that you are **not using an AWS managed Kubernetes service or AWS Load Balancer**. K3s and NGINX run directly on your EC2 instances.

However, don't claim that three EC2 instances are *always* free. AWS Free Tier eligibility depends on the account, instance types, usage hours, and the current Free Tier terms. If your account only has a limited number of free eligible instance-hours, running three instances continuously can exceed the allowance.

---

# Compared to the single-server Compose + Portainer deployment

### Single-server deployment

The original architecture could run:

```text
1 EC2
 │
 ├── Docker
 ├── Portainer
 ├── Frontend
 ├── Backend
 └── PostgreSQL
```

Its AWS infrastructure cost would also be approximately:

**$0/month while within the applicable Free Tier allowance.**

### Current K3s cluster

```text
3 EC2
 │
 ├── Control Plane
 │
 ├── Worker 1
 │    ├── Frontend
 │    └── Backend
 │
 └── Worker 2
      ├── Frontend
      └── Backend
```

**AWS infrastructure cost: ≈ $0/month while within Free Tier allowances.**

Therefore, for this particular project, the monetary difference can be **$0 while both designs remain inside the applicable Free Tier allowances**, but the cluster consumes substantially more EC2 resources.

## What the extra infrastructure buys

The additional nodes are primarily justified for the **DevOps/Kubernetes learning objectives**, rather than because the application needs three servers.

The three-node architecture demonstrates:

* **Multi-node scheduling**
* **Pod distribution**
* **Self-healing**
* **Rolling updates**
* **Horizontal scaling**
* **Kubernetes Services**
* **Ingress routing**
* **NetworkPolicies**
* **GitOps with Argo CD**
* **Sealed Secrets**
* **TLS automation with cert-manager**
* Separation of control plane and application workloads

For a small production application with low traffic, the additional infrastructure is **not necessarily worth the operational complexity or additional resource consumption**.

---

# How I'd halve this

For this capstone, the easiest way to reduce the infrastructure footprint would be to run a **smaller K3s cluster with one control-plane node and one worker node**, while keeping NGINX Ingress, Argo CD, cert-manager and Sealed Secrets. The frontend and backend could still use multiple replicas where resources permit, but this would reduce the number of EC2 instances from three to two. For a real production environment, I would not make this reduction if high availability were a requirement, because losing the single control-plane or worker node would have a much larger impact. The three-node design is therefore a reasonable compromise for demonstrating Kubernetes concepts while keeping the project within the AWS Free Tier target.
