---
title: "Route 3 · Cloud (AKS/EKS/GKE)"
parent: "Setup"
nav_order: 4
---

# Route 3 — Cloud Kubernetes (AKS / EKS / GKE)

<div class="callout callout-success">
<span class="callout-title">Use this route when…</span>
Your Kubernetes cluster lives in the cloud and the VM you run setup on can reach it with
<code>kubectl</code>. <code>scripts/setup.sh --deploy</code> deploys the whole ACE stack (control plane,
MongoDB, Langfuse, LiteLLM, Certifier) <strong>into</strong> that cluster with Helm, and the chaos
experiments run in the same cluster.
</div>

What is different from KinD, and handled by setup when you answer `CLUSTER_MODE=cloud`:

| | KinD (Routes 1–2) | Cloud (this route) |
|---|---|---|
| Images | built on this machine and loaded into the node | **pulled from a registry** (`IMAGE_REGISTRY`, Docker Hub when empty) |
| UI and Langfuse | `localhost` NodePorts | **internal load balancers** (a private IP in the cluster's network) |
| Volumes | local-path directories | cloud disks: Postgres data in a subdirectory, MinIO `fsGroup`, `Recreate` rollouts |
| Deploy method | Helm or kubectl | **Helm only** |

---

## 1. Log in and select the cluster

```bash
# AKS
az login
az aks get-credentials --resource-group <rg> --name <cluster> --admin
# EKS:  aws eks update-kubeconfig --name <cluster> --region <region>
# GKE:  gcloud container clusters get-credentials <cluster> --zone <zone>

kubectl config current-context
kubectl get nodes            # every node Ready
```

`--admin` gives a certificate kubeconfig with no `kubelogin` dependency. Setup needs
cluster-admin: it installs cluster-scoped Litmus/Argo resources.

---

## 2. Make sure the images are in the registry

A cloud node cannot load images built on your VM, so every image comes from the registry.
Use one of these:

- **A published release** (simplest). Ask for the current tag, e.g. `RELEASE-2`, and give it to
  the wizard as `ACE_IMAGE_TAG`. Third-party images (mongo, litmuschaos/*, the demo apps, …)
  must also be mirrored there: `./scripts/mirror-images.sh --push` once per registry.
- **This checkout.** Run setup as `./scripts/setup.sh --deploy --push` and answer `p` at the
  wizard's *Images* question: setup runs `scripts/build-and-push.sh --push`, which builds and
  pushes every ACE image (including the hub bundle and the ITBench runner). You need push
  rights to the registry. Without `--push`, answering `p` stops with
  *"publishing during setup requires --push"*.

Check at any time: `./scripts/check-registry-images.sh` (setup also runs this check before it
deploys and lists anything missing).

---

## 3. Optional `.env` settings

Set these in `.env` before running setup (all are documented in `.env.example`, section
*Cloud clusters*):

| Setting | When |
|---|---|
| `IMAGE_REGISTRY`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` | Private registry (e.g. `infyartifactory.jfrog.io/docker-local`). The wizard asks for these too. |
| `ACE_WEB_LB_IP`, `ACE_LANGFUSE_LB_IP` | Pin the load-balancer IPs to free addresses in the cluster's subnet, so the URLs never change. |
| `ACE_EXPOSE_TYPE` | `LoadBalancer` (default), `NodePort`, or `ClusterIP` (no load balancer; use `kubectl port-forward`). |
| `ACE_EXPOSE_INTERNAL=false` | Only if your cluster allows public load balancers and you want one. |
| `ACE_LB_SOURCE_RANGES` | Restrict which client CIDRs may reach the load balancers. |
| `ACE_EXTRA_ALLOWED_ORIGINS` | Extra hosts you open the UI from (a DNS name in front of the LB, a jump host). Private ranges — 10/8, 172.x, 192.168/16, 100.64/10 — are always allowed. |
| `ACE_EXPOSE_CERTIFIER=true` | Also publish the certifier API on an internal LB. |

---

## 4. Run setup

```bash
./scripts/setup.sh --deploy
```

1. **Where will ACE run?** — setup reads your kube context; for an AKS/EKS/GKE cluster it
   offers `cloud`. Press Enter.
2. **Images** — `n` (use the published images, default) or `p` (publish this checkout first;
   needs `./scripts/setup.sh --deploy --push`), then the `ACE_IMAGE_TAG`.
3. Experiment image sources are set to `registry` for you; give `IMAGE_REGISTRY` and
   credentials, then the LLM keys as usual (Azure OpenAI or another hosted model — Ollama
   runs on the VM and cannot be reached from the cluster).
4. **Deploy** — Helm.

What setup then does on a cloud cluster:

- sets every `*_IMAGE_SOURCE` in `.env` to `registry` and checks the registry has every image;
- creates the registry pull secret in `ace` and `litmus` and starts `registry-secret-sync`
  (copies it into namespaces experiments create later);
- deploys with `helm upgrade --install … -f values-env.yaml -f values-platform.yaml`
  (`values-platform.yaml` holds everything setup derived: registry, exposure, storage);
- waits for the load balancers, then points `ALLOWED_ORIGINS`, `NEXTAUTH_URL` (Langfuse login)
  and `CHAOS_CENTER_PUBLIC_ENDPOINT` at their addresses;
- registers the `ace-local` chaos infrastructure and waits until it is connected;
- prints the UI and Langfuse URLs.

`./scripts/setup.sh --restart` re-applies the same configuration without questions.

| Service | URL | Login |
|---|---|---|
| AgentCert UI | `http://<web LB IP>:2001` | `admin` / `litmus` |
| Langfuse | `http://<langfuse-web LB IP>:3000` | `admin@agentcert.local` / `agentcert-admin` |
| Certifier, LiteLLM, MongoDB | `kubectl port-forward -n ace svc/certifier 18000:8000` (litellm 14000, mongodb 27017) | |

---

## 5. Cluster policies (Azure Policy / Gatekeeper)

- **No public load balancers** — handled: the load balancers are internal by default
  (`service.beta.kubernetes.io/azure-load-balancer-internal`, the EKS and GKE equivalents
  likewise). The bookinfo demo app uses a NodePort for the same reason.
- **Privileged pods / host paths** — many Litmus faults (pod network, CPU/memory/IO hog,
  disk-fill, container-kill, DNS/HTTP chaos) run a privileged helper pod with the node's
  container-runtime socket. If your policy denies privileged pods, ask for the chaos namespace
  (`litmus`) and the experiment namespaces (`sock-shop`, …) to be excluded from that policy.
  `pod-delete`, node drain/taint and the ITBench faults do not need it.
- **Resource limits required** — ACE's own pods do not set limits yet; if your policy enforces
  them (rather than auditing), the pods are denied. `kubectl get constraints` lists what is
  enforced.

---

## 6. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `admission webhook "validation.gatekeeper.sh" denied … Load Balancers should not have public IPs` | `ACE_EXPOSE_INTERNAL=false`, or the provider was not recognised: set `CLUSTER_PROVIDER=aks` in `.env`. |
| Load balancer stays `<pending>` | `kubectl describe svc -n ace web` — a pinned `ACE_*_LB_IP` that is in use or outside the subnet, or a quota. |
| `ImagePullBackOff` | The image is not in the registry (`./scripts/check-registry-images.sh`), or the pull secret is missing in that namespace: `./scripts/apply_cluster_prereqs.sh --deploy`. |
| UI says *Invalid origin* / subscriber logs `websocket: bad handshake` | You open the UI from a host that is not allowed: add it to `ACE_EXTRA_ALLOWED_ORIGINS`, then `./scripts/setup.sh --restart`. |
| Langfuse login loops back to the login page | `NEXTAUTH_URL` is not the URL in your browser — re-run `./scripts/setup.sh --restart` (it re-reads the LB address). |
| `CLUSTER_MODE=cloud, but kubectl cannot reach a cluster` | Log in again (`az aks get-credentials …`). |

---

## 7. Start again from scratch

This deletes ACE's data in the cluster (MongoDB, Langfuse, reports). Check the context first.

```bash
kubectl config current-context                  # must be the cluster you mean to wipe
helm uninstall ace -n ace
kubectl delete namespace ace litmus sock-shop book-info otel-demo --ignore-not-found --wait=false
./scripts/apply_cluster_prereqs.sh --deploy --uninstall  # removes registry-secret-sync from kube-system
kubectl get namespaces                          # wait until those are gone
./scripts/setup.sh --deploy
```

`helm uninstall` keeps PVCs; deleting the `ace` namespace removes them (and their disks).
A namespace stuck in `Terminating` (chaos resources holding finalizers):
`bash scripts/cleanup-litmus-ns.sh <namespace>`.
