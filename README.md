# MeshMart: Istio Practical Exam

> **Role:** Senior DevOps / Platform Engineer
> **Format:** take-home practical, about 3 hours (bonus tasks extra)
> **Environment:** your laptop (Rancher Desktop Kubernetes)

## The scenario

You have just joined the platform team at **MeshMart**, a small online shop running on Kubernetes.
Last week's security audit came back with two findings:

1. *"Any pod in the cluster can call any service, including payments and the datastore."*
2. *"Service-to-service traffic is unencrypted."*

On top of that, the product team wants to release a new **catalog v2** gradually, and on-call is tired of
customers seeing errors from the flaky **payments** service.

Your job is to bring MeshMart into an **Istio service mesh**, lock it down to zero-trust, and use the mesh for
safe releases and resilience. Then explain your decisions, as you would to the team.

---

## Architecture

```mermaid
flowchart LR
  B([Browser]) -->|NodePort 30080| G[gateway<br/>nginx]
  G -->|/api/catalog| C[catalog<br/>v1 + v2]
  G -->|/api/orders| O[orders]
  C --> I[inventory]
  O --> P[payments<br/>~30% HTTP 500]
  O --> R[(redis)]
  X[intruder pod<br/>other namespace]
  X -. should NOT reach .-> P
  X -. should NOT reach .-> R
```

| Workload | Image | ServiceAccount | Port | Notes |
|---|---|---|---|---|
| `gateway-v1` | nginx | `gateway` | 8080 (Service: 80, NodePort 30080) | Serves the UI and proxies `/api/*` |
| `catalog-v1`, `catalog-v2` | python | `catalog` | 8080 | One Service `catalog` selects both versions |
| `inventory-v1` | python | `inventory` | 8080 | Called by catalog |
| `orders-v1` | python | `orders` | 8080 | Calls payments, INCRs a counter in Redis |
| `payments-v1` | python | `payments` | 8080 | Fails ~30% of requests on purpose |
| `redis-v1` | redis | `redis` | 6379 (TCP) | Datastore |

Every backend runs the same tiny Python service (`chart/meshmart/files/app.py`, stdlib only) and answers with
JSON showing its name, version, pod, the result of each downstream call, and the caller's mesh identity
(`caller_identity`) when there is one.

The UI has four buttons. **Browse catalog** and **Place order** are the public API. **Inventory (direct)** and
**Payments (direct)** make the gateway call internal services that it should *not* be allowed to reach. They
exist so you can prove your lockdown works.

---

## Repository layout

```
.
├── README.md                    <- this file (the exam)
├── ANSWERS.md                   <- you fill this in
├── chart/meshmart/              <- Helm chart for the whole app
│   ├── values.yaml
│   ├── files/app.py             <- the backend service (do not modify)
│   ├── files/gateway/           <- nginx config + UI
│   └── templates/
├── istio/                       <- YOUR Istio manifests go here
├── platform/                    <- Helm values: Istio, kube-prometheus-stack, Kiali
└── tools/
    ├── intruder.yaml            <- a rogue pod in another namespace
    ├── load.sh                  <- traffic generator with status/version summary
    └── check.sh                 <- self-check for the final state
```

---

## Prerequisites

| Tool | Notes |
|---|---|
| **Rancher Desktop** | Kubernetes enabled (it runs k3s). In *Preferences → Virtual Machine* give it **4 CPUs and 8 GB RAM** (Part 3 runs kube-prometheus-stack). Either container engine works. |
| `kubectl` | Ships with Rancher Desktop. Check `kubectl config current-context` is `rancher-desktop`. |
| `helm` (3.6+ or 4) | Ships with Rancher Desktop, or `brew install helm`. **Everything is installed with Helm**, as in production. |
| `istioctl` | `brew install istioctl`. Used only as a debugging CLI (`analyze`, `proxy-config`, `describe`), never to install. Keep it on the same minor version as the control plane. |
| `curl`, `bash` | Already on macOS. |

Helm repositories used (added in Parts 2 and 3):

| Repo | URL | Charts |
|---|---|---|
| `istio` | https://blob.istio.io/istio-release/charts | `base`, `istiod` (and `gateway` for bonus B3) |
| `prometheus-community` | https://prometheus-community.github.io/helm-charts | `kube-prometheus-stack` |
| `kiali` | https://kiali.org/helm-charts | `kiali-server` |

> **Reaching the UI.** The gateway is a NodePort Service on **30080**, so try **http://localhost:30080** first;
> Rancher Desktop normally forwards NodePorts to localhost. If that doesn't load, fall back to
> `kubectl -n shop port-forward svc/gateway 8080:80` and use http://localhost:8080
> (then pass `BASE_URL=http://localhost:8080` to the scripts in `tools/`).
> Prefer the NodePort if you can: Part 4 behaves differently over port-forward, and question Q4.5 asks you why.

---

## Rules and deliverables

- Work on your own branch: `git checkout -b exam/<your-name>`. Commit at least once per Part.
- **Do not modify `chart/meshmart/files/app.py`.** Changing chart values or templates is allowed only if you
  justify it in `ANSWERS.md`. (None of the required tasks need it.)
- Every Istio resource you create lives in `istio/` as YAML, numbered in apply order. The reviewer will run
  `kubectl apply -f istio/` on a fresh cluster with MeshMart and Istio installed, so it must apply cleanly.
  Experiments that should **not** be part of the final state go in `istio/experiments/` (not applied, since
  `kubectl apply -f` is not recursive).
- Answer every **Q** and **W** question in `ANSWERS.md`. Short and precise beats long.
- Final state must pass `tools/check.sh`.
- Official docs (istio.io, kiali.io, kubernetes.io) are allowed. Hints at the bottom cost 2 points each;
  note in `ANSWERS.md` which ones you opened.

---

## Part 1: Baseline without Istio (10 pts)

Deploy MeshMart:

```bash
helm upgrade --install meshmart ./chart/meshmart -n shop --create-namespace
kubectl -n shop get pods -L app,version -w      # wait for 7 pods Running, 1/1
```

Open the UI, click every button and look at the JSON. Then deploy the intruder and generate some traffic:

```bash
kubectl apply -f tools/intruder.yaml

# Can a random pod in another namespace reach payments and the datastore?
kubectl -n intruder exec intruder -c shell -- curl -s -w '\nHTTP %{http_code}\n' http://payments.shop:8080/charge
# (the sleep keeps the connection open long enough to read Redis's reply)
kubectl -n intruder exec intruder -c shell -- sh -c "(printf 'INCR hacked\r\n'; sleep 2) | nc -w 3 redis.shop 6379"

tools/load.sh /api/catalog 50
tools/load.sh /api/orders 50
```

- **Q1.1** What split do you get between catalog v1 and v2, and what decides it? How would you send only 10% of
  traffic to v2 using plain Kubernetes, and what does that cost you?
- **Q1.2** What did the intruder tests show? Name a Kubernetes-native control that could block the intruder
  without a mesh, and two things it can't do that Istio can.
- **Q1.3** What is the orders failure rate? Without a mesh, where would retries for payments be implemented,
  and what's the downside of that across 50 microservices?

---

## Part 2: Install Istio with Helm and onboard MeshMart (15 pts)

Install Istio the way a platform team runs it in production: the official Helm charts, **one pinned version
for every Istio chart**, and values files kept in Git (`platform/`). In a real company the same values would be
fed to Argo CD or Terraform rather than typed by hand (see bonus B7).

```bash
brew install istioctl            # debugging CLI only
istioctl x precheck              # is the cluster ready for Istio?

helm repo add istio https://blob.istio.io/istio-release/charts
helm repo update
helm search repo istio/istiod --versions | head -5     # pick the latest stable release
export ISTIO_VERSION=1.31.1                            # pin it; use the same version for every Istio chart

# 1. CRDs and cluster-wide resources
helm upgrade --install istio-base istio/base -n istio-system --create-namespace \
  --version "$ISTIO_VERSION" -f platform/istio-base-values.yaml --wait

# 2. Control plane (istiod)
helm upgrade --install istiod istio/istiod -n istio-system \
  --version "$ISTIO_VERSION" -f platform/istiod-values.yaml --wait

helm ls -n istio-system
kubectl -n istio-system get pods
istioctl version                 # client and control plane should match (within one minor)
```

Onboard the `shop` namespace:

```bash
kubectl label namespace shop istio-injection=enabled
kubectl -n shop rollout restart deployment
kubectl -n shop get pods            # each pod should now report 2/2
```

Click through the UI again and repeat the intruder tests from Part 1.

- **Q2.1** List the containers *and* init containers of a catalog pod. What was added, by what mechanism, and
  without you changing the Helm chart? (If `istio-proxy` appears under init containers, explain why.)
- **Q2.2** Can the intruder still reach payments and Redis? Why? Is traffic between gateway and catalog
  encrypted right now? How can you tell?
- **Q2.3** Compare the `caller_identity` field in a catalog response now vs. Part 1. Where does that value come
  from, and what is its format?
- **Q2.4** Why is Istio split into separate `base` and `istiod` charts, installed in that order? Why must they
  share one version? In production, how would you upgrade to the next Istio minor version without moving every
  workload at once? (Hint: look up istiod *revisions* and *revision tags*.)

---

## Part 3: Observability (10 pts)

Production-style monitoring: **kube-prometheus-stack** scrapes istiod and every Envoy sidecar (the
ServiceMonitor and PodMonitor are defined in its values file), and **Kiali** runs as its own Helm release
pointed at that Prometheus.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add kiali https://kiali.org/helm-charts
helm repo update

helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f platform/kube-prometheus-stack-values.yaml --wait
kubectl -n monitoring get svc kps-prometheus        # Kiali points at this Service

helm upgrade --install kiali-server kiali/kiali-server \
  -n istio-system -f platform/kiali-values.yaml --wait

# keep some traffic flowing in another terminal
tools/load.sh /api/catalog 500 3 & tools/load.sh /api/orders 500 3 &

# each port-forward blocks, so run them in separate terminals
kubectl -n istio-system port-forward svc/kiali 20001:20001     # http://localhost:20001
kubectl -n monitoring port-forward svc/kps-grafana 3000:80     # http://localhost:3000 (admin / admin)
kubectl -n monitoring port-forward svc/kps-prometheus 9090     # http://localhost:9090 (optional)
```

In Grafana, import the official Istio dashboards (*Dashboards → New → Import*, choose the Prometheus data
source): **7639** (Mesh), **7636** (Service), **7630** (Workload) and **7645** (Control Plane).

In Kiali, open **Traffic Graph** for namespace `shop` (enable the *Security* display option), then
**Istio Config**. You'll come back to Istio Config after Parts 4 and 5 to see your own rules there and fix any
validation warnings it shows.

- **Q3.1** Which edges in the graph show a padlock and which don't? Why is the traffic *entering* the gateway
  different from the rest?
- **Q3.2** What is the error rate of `payments` according to Kiali or Grafana? The app exports no metrics at all,
  so where do these numbers come from?
- **Q3.3** In Prometheus *Status → Targets*, find the Envoy targets. Why does the PodMonitor in
  `platform/kube-prometheus-stack-values.yaml` rewrite `__address__` instead of scraping the pod's declared
  container port?

---

## Part 4: Zero trust (30 pts)

Required access matrix. Anything not listed must be denied.

| Source | May call |
|---|---|
| Browser (outside the mesh) | `gateway` on port 8080 |
| `gateway` | `catalog`, `orders` |
| `catalog` | `inventory` |
| `orders` | `payments`, `redis` |
| anything else (including the gateway's "direct" buttons and the intruder) | nothing |

### 4.1 Strict mTLS (8 pts)
Enforce **STRICT** mTLS for the `shop` namespace. The UI must keep working through the NodePort, and nothing
else in `shop` may accept plaintext. Prove that the un-meshed intruder can no longer reach payments or Redis.

- **Q4.1** What broke (if anything) when you first applied STRICT, why, and how did you fix it without
  weakening the rest of the namespace?

### 4.2 Least privilege with AuthorizationPolicies (12 pts)
Implement the matrix above with **default deny** plus explicit allows. Policies must be based on
**workload identity** (ServiceAccount principals), not IPs or labels of the caller. After this, the UI's
*Inventory (direct)* and *Payments (direct)* buttons must return **403**, while *Browse catalog* and
*Place order* still work.

- **Q4.2** Each workload in the chart has its own ServiceAccount. Why does that matter here, and what would
  happen if they all used `default`?

### 4.3 The intruder joins the mesh (5 pts)
```bash
kubectl label namespace intruder istio-injection=enabled
kubectl -n intruder delete pod intruder && kubectl apply -f tools/intruder.yaml
```
Repeat the intruder tests.

- **Q4.3** The intruder now has a valid mesh certificate. What error does it get now compared to 4.1, and
  which layer is blocking it in each case?

### 4.4 The datastore (5 pts)
The product team asks: *"orders should only be able to run `INCR` on Redis, never `FLUSHALL`."*

- **Q4.4** Can you enforce that with an Istio AuthorizationPolicy? Explain why or why not, and how you would
  meet the requirement instead.
- **Q4.5** Run `kubectl -n shop port-forward svc/payments 9000:8080` and `curl localhost:9000/charge`.
  Does it work despite your policies? Why? What does that tell you about who should get `pods/portforward`
  in RBAC?

---

## Part 5: Traffic management (25 pts)

### 5.1 Canary (8 pts)
Send **90%** of catalog traffic to v1 and **10%** to v2, without changing replica counts.

- **Q5.1** Which two Istio resources did you need, and what does each one do? Which pod's Envoy makes the
  routing decision for a request coming from the gateway?

### 5.2 Testers always get v2 (5 pts)
Requests with header `x-canary: always` must **always** hit catalog v2 (the UI has a checkbox for this),
while everyone else keeps the 90/10 split.

- **Q5.2** The header is set by the browser. Follow it hop by hop: why does it reach the place where routing
  happens, and what would happen to it on the *catalog → inventory* hop if `app.py` didn't propagate it?

### 5.3 Retries (6 pts)
Make **Place order** succeed at least 95% of the time **without touching payments**.

```bash
tools/load.sh /api/orders 100 5     # before and after
```

- **Q5.3** Where exactly did you configure retries, and on what conditions? Payments is a *charge* endpoint.
  What is the real-world danger of retrying it, and what must the service guarantee to make retries safe?

### 5.4 Timeouts and fault injection (6 pts)
1. Inject a fixed **4 second** delay into **100%** of requests to inventory. Click *Browse catalog* and note
   what happens.
2. Add a **1 second** timeout on calls to inventory so catalog fails fast.
3. Keep the timeout in `istio/` but move the fault injection to `istio/experiments/` (the final state must be
   healthy).

- **Q5.4** With both applied, what status does catalog report for its inventory call and how long does it
  take? Which Envoy applied the delay and which applied the timeout?

---

## Written questions (10 pts, 2 each)

- **W1** What are the roles of `istiod` and Envoy? If `istiod` is down for 10 minutes, what happens to
  existing traffic, to new pods, and to certificate rotation?
- **W2** You have 50 microservices in production in PERMISSIVE mode. Describe how you would migrate to STRICT
  without an outage, and what you'd watch while doing it.
- **W3** The gateway's nginx config sets `proxy_http_version 1.1`. Why does that matter once an Envoy sidecar
  sits next to nginx?
- **W4** What does the sidecar cost you (resources, latency, operations)? When would you advise **not**
  adopting a service mesh?
- **W5** In what order does Istio evaluate CUSTOM, DENY and ALLOW policies? If a workload has one ALLOW policy,
  what happens to a request that matches no rule?

---

## Bonus (up to +25)

Put bonus manifests and values in `istio/experiments/`, `platform/` or a new `gitops/` folder, and describe
them in `ANSWERS.md`.

- **B1 Circuit breaking (+4).** Add connection-pool limits and outlier detection for payments. Trigger them with
  `tools/load.sh /api/orders 200 20` and find the evidence in the `istio-proxy` access log of the orders pod
  (look at the response flags). How do retries and circuit breaking interact?
- **B2 Dashboards as code (+5).** Replace the manual Grafana import with declarative provisioning in
  `platform/kube-prometheus-stack-values.yaml`, so a fresh cluster comes up with the four Istio dashboards.
  Then enable Grafana in `platform/kiali-values.yaml` so Kiali links to them. How would you keep the dashboard
  revisions in step with Istio upgrades?
- **B3 Istio ingress gateway (+4).** Replace the NodePort-on-nginx edge with an Istio ingress gateway installed
  from the `istio/gateway` chart (same `$ISTIO_VERSION`), plus a `Gateway` and `VirtualService` in front of
  nginx. Rancher Desktop's Traefik already holds ports 80/443, so plan for that. What do you gain at the edge
  compared to Q4.1's fix?
- **B4 Distributed tracing (+4).** Install Jaeger with its Helm chart, point Istio at it through
  `platform/istiod-values.yaml`, and show one trace that spans gateway → orders → payments. Why does the app
  have to forward trace headers itself?
- **B5 Mirroring (+2).** Mirror 100% of catalog v1 traffic to v2 without users seeing v2 responses.
- **B6 Ambient mode (+1).** In a few sentences: how would your Part 4 and Part 5 config change in Istio
  ambient mode? Which extra Helm charts would you install, and which of your policies would need a waypoint
  proxy?
- **B7 GitOps (+5).** Manage everything with Argo CD instead of `helm` by hand: Applications for `istio-base`,
  `istiod`, `kps`, `kiali-server`, `meshmart` and the `istio/` folder, ordered with sync waves. Argo will keep
  showing one istiod resource as *OutOfSync* even though nothing is wrong. Which one, why, and how do you fix
  it properly?

---

## Scoring

| Part | Points |
|---|---|
| 1. Baseline | 10 |
| 2. Onboarding | 15 |
| 3. Observability | 10 |
| 4. Zero trust | 30 |
| 5. Traffic management | 25 |
| Written | 10 |
| **Total** | **100** (+25 bonus) |

Reviewers look at: correctness (does `tools/check.sh` pass on a fresh cluster), least privilege (no
over-broad allows, no `*` principals where a specific one works), clarity of explanations, and clean,
reviewable YAML and commits.

---

## Useful commands

```bash
helm ls -A                                                # every release and its chart version
istioctl analyze -n shop                                  # config mistakes
istioctl x describe pod <pod> -n shop                     # which rules apply to a pod
istioctl proxy-config routes deploy/gateway-v1 -n shop    # what the gateway's Envoy will route
istioctl proxy-config cluster deploy/orders-v1 -n shop
kubectl -n shop logs deploy/orders-v1 -c istio-proxy --tail=20   # access log with response flags
kubectl get peerauthentication,authorizationpolicy,virtualservice,destinationrule -A
tools/check.sh                                            # self-check for the final state
```

## Cleanup

Uninstall in reverse order:

```bash
helm -n shop uninstall meshmart
kubectl delete namespace shop intruder
helm -n istio-system uninstall kiali-server
helm -n monitoring uninstall kps
helm -n istio-system uninstall istiod
helm -n istio-system uninstall istio-base
kubectl delete namespace istio-system monitoring

# Helm leaves CRDs behind on purpose. Deleting them removes every Istio /
# Prometheus Operator resource in the cluster, so only do this on a lab cluster.
kubectl get crd -oname | grep -E 'istio.io|monitoring.coreos.com' | xargs kubectl delete
```

---

## Hints (2 points each, note which ones you opened)

<details><summary>H1: Part 4.1, the UI stopped working</summary>

The browser is not part of the mesh, so it can't present a client certificate. A `PeerAuthentication` can
target a single workload with a `selector`, and it can override the mode per port with `portLevelMtls`.
</details>

<details><summary>H2: Part 4.2, default deny</summary>

An `AuthorizationPolicy` with an empty `spec: {}` in a namespace denies all requests to workloads in that
namespace. Principals look like `cluster.local/ns/<namespace>/sa/<serviceaccount>` and only exist when the
caller connected over mTLS.
</details>

<details><summary>H3: Part 4.4, Redis</summary>

Istio only parses protocols it understands. For plain TCP, which fields of an AuthorizationPolicy rule can
it actually evaluate?
</details>

<details><summary>H4: Part 5, routing</summary>

Subsets are defined in a `DestinationRule` and select pods by label (the chart already sets `version`).
VirtualService routes are evaluated top to bottom, first match wins.
</details>
