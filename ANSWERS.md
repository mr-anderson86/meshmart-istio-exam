# Answers

Candidate: mr-anderson86
Date:
Time spent:

## Part 1 - Baseline

**Q1.1**
Roughly 50/50, and it moves randomly between runs (4 runs of 50: 25/25, 22/28, 28/22, 22/28).
The `catalog` Service selects only `app=catalog`, so both versions' pods are endpoints. kube-proxy
(iptables mode on k3s) picks a random endpoint per new connection, so the split follows the
number of ready pods, not the version. nginx has no upstream keepalive, so every request opens a
new connection and gets a fresh random pick.

For 10% to v2 with plain Kubernetes, scale replicas 9:1 (9 × v1, 1 × v2). The cost:
- traffic weight is coupled to replica count (1% needs 100 pods);
- capacity is wasted just to get the ratio;
- an HPA on either Deployment changes the ratio;
- the split is per connection and approximate;
- there is no header-based routing.

**Q1.2**
The intruder, in another namespace with no credentials, got full access:
- `curl payments.shop:8080/charge` → **HTTP 200**, with `"caller_identity": null` (the caller is unknown);
- Redis `INCR hacked` → `:9`, an integer reply, meaning the write succeeded (the key is at 9 after repeated runs).

The network is flat and nothing is authenticated or encrypted.

The Kubernetes-native control is a **NetworkPolicy** (default-deny ingress in `shop` plus allows by
pod and namespace selector; k3s enforces it with kube-router). Two things it can't do that Istio can:
1. **Cryptographic workload identity.** NetworkPolicy matches IPs and labels, and anyone who can
   create a pod can set any label. Istio authorizes on the ServiceAccount's SPIFFE identity, proven by mTLS.
2. **Encryption in transit and L7 rules.** NetworkPolicy encrypts nothing (audit finding #2) and only
   works at L3/L4. Istio adds mTLS and can allow or deny by HTTP method, path or header.

**Q1.3**
16/50 = **32%** of orders failed with **502**, which matches payments' `failRate: 0.3`. Orders returns
502 (Bad Gateway) whenever any downstream call fails.

Without a mesh, retries live in the application code of every caller (here `orders`), around its
HTTP client or in a shared client library. Across 50 microservices:
- the same logic is reimplemented in every language and framework, and the copies drift;
- tuning retries or timeouts needs a code change and a redeploy;
- there is no central view or retry budget, so retries stacked across layers can cause retry storms;
- every team must know which endpoints are safe to retry (`/charge` is not idempotent).

## Part 2 - Onboarding

**Q2.1**
`catalog-v1` now has:
- init containers: `istio-init`, and `istio-proxy` with `restartPolicy: Always`;
- containers: `catalog` only.

`istio-init` runs once and writes iptables rules so all pod traffic goes through Envoy (ports
15001 outbound and 15006 inbound). `istio-proxy` is the Envoy sidecar, run by `pilot-agent`.

The mechanism is a mutating admission webhook. istiod registers `istio-sidecar-injector`, whose
`namespace.sidecar-injector.istio.io` webhook matches namespaces labelled `istio-injection=enabled`.
The API server sends each new pod spec to istiod, which adds the containers before the pod is stored.
That's why the chart is unchanged, and why a `rollout restart` was needed: existing pods are never
changed.

`istio-proxy` is an init container because it is a Kubernetes **native sidecar**. It starts and
must be ready before the app container, so the app's first outbound calls work. It runs for the
pod's whole life and is stopped after the app on shutdown, so Jobs can complete. This avoids the
startup and shutdown races of the old two-regular-containers setup. It still counts in READY (2/2).

**Q2.2**
Yes. The intruder still gets HTTP 200 from payments (`caller_identity: null`) and can still
`INCR` Redis. Istio's default mTLS mode is **PERMISSIVE**: each sidecar accepts both mTLS and
plaintext. `istioctl x describe pod` shows "Workload mTLS mode: PERMISSIVE", and no
PeerAuthentication or AuthorizationPolicy exists yet. Onboarding adds encryption where both sides
support it but enforces nothing.

(Test artifact: `printf ... | nc -w 2` now returns nothing, because the sidecar drops a connection
whose client closes the moment it has sent. With stdin held open, `(printf 'INCR hacked\r\n'; sleep 3) | nc ...`
still returns `:1`. The counter restarted because Redis was restarted and keeps no data on disk.)

Gateway → catalog **is encrypted**. Both pods have sidecars, so the gateway's Envoy uses
**auto-mTLS** and opens an Istio mTLS connection. Evidence:
- `caller_identity` is now filled in; it comes from the client certificate, which only exists over mTLS;
- catalog's sidecar access log shows the requested server name `outbound_.8080_._.catalog.shop.svc.cluster.local`
  (Istio mTLS SNI), while the intruder's plaintext request in payments' log shows `-`;
- `istioctl proxy-config cluster deploy/gateway-v1 --fqdn catalog.shop.svc.cluster.local -o json`
  shows the transport socket matched on `tlsMode: istio`;
- Kiali shows a padlock on the edge (Part 3).

**Q2.3**
- Part 1: `null`.
- Now: catalog sees `spiffe://cluster.local/ns/shop/sa/gateway`, and inventory sees `spiffe://cluster.local/ns/shop/sa/catalog`.

The server-side Envoy completes the mTLS handshake. It then adds an `X-Forwarded-Client-Cert` header
with the client certificate's URI SAN to the request it passes to the app, and `app.py` reads the
`URI=` field. The certificate is issued by istiod's CA to each sidecar over SDS, based on the pod's
ServiceAccount token, and rotated automatically (24h TTL).

The format is a SPIFFE ID, `spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>`. The
identity belongs to the **ServiceAccount**, not to the pod, its IP or its labels.

**Q2.4**
`base` holds the cluster-wide pieces: the Istio CRDs, cluster roles and the default validating
webhook (`defaultRevision`). `istiod` is the control plane. It watches those CRDs, so they must
exist first. Their lifecycles also differ: CRDs are cluster-scoped and installed once, and they
are shared by every istiod revision, while control planes can run side by side and come and go.

They must share one version because CRD schemas, istiod and the proxies are released and tested
together. If base is older, istiod may write fields the CRDs don't know, and the validation webhook
may reject valid config. Mixed versions are unsupported. On upgrade, `base` goes first, since newer
CRDs are backward compatible.

Canary upgrade to the next minor version:
1. Upgrade `istio-base`.
2. Install a second control plane, e.g. `helm install istiod-1-32 istio/istiod --set revision=1-32`, next to the current one.
3. Use **revision tags**: `prod-stable` → old revision, `prod-canary` → new revision. Namespaces are
   labelled `istio.io/rev=prod-stable` instead of `istio-injection=enabled`.
4. Move a few namespaces to `prod-canary` and restart them, then watch errors and latency.
5. Point `prod-stable` at the new revision and restart the remaining namespaces gradually.
6. Remove the old istiod once no proxy uses it. To roll back, point the tag back and restart.

Proxies only change version when pods restart, so the pace is controlled one namespace at a time,
and namespace labels never need editing.

## Part 3 - Observability

**Q3.1**
Every edge between workloads in `shop` has a padlock: gateway → catalog/orders, catalog → inventory,
orders → payments, and orders → redis (TCP). Both ends have a sidecar, so the client Envoy uses
auto-mTLS with istiod-issued certificates.

The only edge without one is `unknown → gateway`: the browser or `load.sh` coming in through the
NodePort. The caller is outside the mesh, with no sidecar and no certificate, so it can only send
plaintext. The gateway's sidecar accepts it because the namespace is still PERMISSIVE. Kiali shows
the source as `unknown` because no sidecar on the client side reports its identity.

**Q3.2**
About **30%** (Kiali: 29.97% inbound 5xx; Prometheus: 30.0% over 5m), matching `failRate: 0.3`.

The numbers come from the **Envoy sidecars**, not the app. Every sidecar records Istio's standard
metrics (`istio_requests_total`, `istio_request_duration_milliseconds`, `istio_tcp_*`) for each
request it handles, labelled with source and destination workload, identity and response code. Both
the client (`reporter="source"`) and server (`reporter="destination"`) proxies report.

Envoy exposes them on `:15020/stats/prometheus`, Prometheus scrapes them through the PodMonitor, and
Kiali and Grafana query Prometheus. Payments' sidecar shows `response_code="500"` 1518 vs `"200"`
3485 from `orders-v1`. No code changes were needed.

**Q3.3**
Target health shows one `envoy-stats-monitor` target per meshed pod, all `UP`, scraped at
`http://<podIP>:15020/stats/prometheus`. The discovered `__address__` is `<podIP>:15090`, the only
port `istio-proxy` declares (`http-envoy-prom`). It serves Envoy's stats only.

15020 is pilot-agent's **merged** endpoint: Envoy stats plus `istio_agent_*` plus the application's
own metrics. With Istio's metrics merging (`enablePrometheusMerge`, default on), the injector sets
`prometheus.io/scrape|port|path=true|15020|/stats/prometheus` on the pod, moves any app annotations
into `ISTIO_PROMETHEUS_ANNOTATIONS`, and pilot-agent scrapes and merges the app. That gives one target
per pod, and it still works under STRICT mTLS, where Prometheus can't reach the app port directly.

15020 is never a declared container port, so a port-name endpoint can't select it. The relabeling
keeps only the `istio-proxy` container and pods with `prometheus.io/scrape`, then builds
`__address__` from pod IP + `prometheus.io/port`, with an IPv6 variant using `[ip]:port`.

## Part 4 - Zero trust

**Q4.1**
With namespace-wide STRICT ([`00-peerauthentication.yaml`](istio/00-peerauthentication.yaml)), the UI
broke: the browser and curl got an empty response (`HTTP 000`, `ERR_EMPTY_RESPONSE`). The browser is
outside the mesh and can't present a mesh certificate, so it reaches the gateway over plaintext
through the NodePort. The gateway's sidecar now accepts only mTLS and resets the connection: its
access log shows `NR filter_chain_not_found`. The intruder gets the same result against payments,
Redis and every other service, which is the point.

Fix: a workload-scoped PeerAuthentication
([`01-peerauthentication-gateway.yaml`](istio/01-peerauthentication-gateway.yaml)) selects
`app=gateway`, keeps `mode: STRICT`, and sets `portLevelMtls` to `PERMISSIVE` for **container port
8080 only** (the targetPort the sidecar sees, not Service port 80 or NodePort 30080). The most
specific policy wins per workload, so only that one port on the gateway accepts plaintext. Every
other workload keeps the namespace STRICT policy, which `istioctl x describe pod` confirms.
PERMISSIVE rather than DISABLE keeps mTLS working for any future in-mesh caller, such as an ingress
gateway.

Trade-off: gateway:8080 accepts plaintext from any pod in the cluster, so the gateway can act on
behalf of an un-meshed caller. Part 4.2's AuthorizationPolicies limit what the gateway itself may
call. The clean fix is an Istio ingress gateway that ends TLS at the edge (B3), so the nginx gateway
can go back to fully STRICT.

**Q4.2**

**Q4.3**

**Q4.4**

## Part 5 - Traffic management

**Q5.1**

**Q5.2**

**Q5.3**

## Written questions

**W1**

**W2**

**W3**

**W4**

**W5**

## Bonus (list what you did and where it lives)

