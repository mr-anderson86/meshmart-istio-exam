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
Policies: default deny ([`10-authz-deny-all.yaml`](istio/10-authz-deny-all.yaml)) plus one ALLOW per
receiving workload ([`11`](istio/11-authz-gateway.yaml) to [`16`](istio/16-authz-redis.yaml)). Each
allow names the caller's principal and the port, method and path it may use. The gateway allow has no
principal because the browser has no identity.

Istio's workload identity **is** the ServiceAccount: each sidecar's certificate carries
`spiffe://cluster.local/ns/<ns>/sa/<sa>`, and that is what `source.principals` matches. Because
every workload has its own SA, each caller has a distinct, cryptographically verified identity, so
policies can express the matrix exactly: `sa/orders` may call payments, `sa/gateway` may not.

If every pod used `default`, every caller in `shop` would present the same principal,
`cluster.local/ns/shop/sa/default`. Policies couldn't tell callers apart. Allowing orders → payments
would also allow gateway → payments, catalog → payments and so on, so the direct buttons couldn't be
denied. The best you could do is "anything in `shop` may call anything in `shop`", namespace-level
trust instead of least privilege. It also widens the blast radius: compromising any one pod gives an
attacker the identity, and any Kubernetes RBAC rights, of all of them. (Per-version SAs aren't needed:
catalog v1 and v2 share `sa/catalog` because they play the same role.)

**Q4.3**
In 4.1 the intruder had no sidecar, so it spoke plaintext. Payments' and Redis's sidecars, under
STRICT PeerAuthentication, reset the connection before any HTTP: curl got `HTTP 000` (exit 56), nc
got nothing, and Envoy logged `NR filter_chain_not_found`. That's the **authentication / transport
layer**.

After joining the mesh, the intruder has a valid istiod-issued certificate for
`spiffe://cluster.local/ns/intruder/sa/default`, so the mTLS handshake **succeeds**. It is now
stopped by **authorization**: payments returns **`403 RBAC: access denied`**, logged as
`rbac_access_denied_matched_policy[none]`, because default-deny is in place and no ALLOW rule lists
`ns/intruder/sa/default`. For Redis (TCP) the same RBAC check runs in Envoy's network filter. With no
HTTP there's no 403, so the connection is just closed after the handshake (empty reply, same log
reason).

| | **4.1**: intruder **not** in the mesh | **4.3**: intruder **in** the mesh |
|---|---|---|
| Payments | `HTTP 000`, connection reset | `HTTP 403 RBAC: access denied` |
| Redis | Empty reply (connection reset) | Empty reply (connection closed after mTLS) |
| Envoy reason | `NR filter_chain_not_found` | `rbac_access_denied_matched_policy[none]` |
| Blocking layer | **Authentication, at TLS/L4:** PeerAuthentication STRICT, no client cert | **Authorization, at L7 (HTTP) or L4 (TCP):** AuthorizationPolicy, identity not allowed |

The lesson: mTLS proves identity, but every meshed workload gets one, so authorization policies are
what enforce least privilege.

**Q4.4**
No. Istio only parses HTTP/gRPC. Redis's RESP is treated as opaque TCP, so an AuthorizationPolicy
for Redis can only match L4 attributes: source principal, namespace or IP, and destination port.
HTTP-only fields like `methods` or `paths` don't apply; Istio drops such an ALLOW rule or widens a
DENY rule rather than inspecting commands. `INCR` and `FLUSHALL` are just bytes in the stream.

What Istio *can* enforce is already in place: only `cluster.local/ns/shop/sa/orders` may connect to
Redis on 6379 ([`16-authz-redis.yaml`](istio/16-authz-redis.yaml)). Once connected, orders could
still send any command.

Restricting *commands* must happen in Redis itself, with Redis 6+ ACLs. `app.py` sends no `AUTH`, so
it runs as the built-in `default` user, which can be limited with
`ACL SETUSER default on nopass -@all +incr +ping ~*` (`PING` is kept for the readiness probe).
`FLUSHALL` then fails with `NOPERM`. If the app could send `AUTH`, a dedicated `orders` user with a
password from a Secret would be better.

Verified at runtime (not persisted: this Redis has no ACL file and runs with `--save ""`, so the rule
is lost when the pod restarts):

```console
$ kubectl -n shop exec deploy/redis-v1 -c redis -- redis-cli ACL SETUSER default on nopass -@all +incr +ping '~*'
OK

$ kubectl -n shop exec deploy/orders-v1 -c orders -- sh -c "(printf 'INCR orders-test\r\n'; sleep 2) | nc -w 3 redis 6379"
:1

$ kubectl -n shop exec deploy/orders-v1 -c orders -- sh -c "(printf 'FLUSHALL\r\n'; sleep 2) | nc -w 3 redis 6379"
-NOPERM User default has no permissions to run the 'flushall' command
```

Both commands from orders go through the mesh (orders' sidecar → mTLS → Redis's sidecar), so Istio
allows the connection and the Redis ACL alone refuses `FLUSHALL`. The order counter survived and kept
increasing. The same test from the intruder gets an empty reply: Istio closes the connection before
Redis sees any command.

In production I'd make this declarative in the Helm chart instead of a manual `ACL SETUSER`, since
the Redis args are hard-coded in `templates/redis.yaml` today. Two options:
- a value with the ACL rules themselves, e.g. `redis.aclRules: ["on", "nopass", "-@all", "+incr", "+ping", "~*"]`,
  rendered into the Redis args as `--user default ...`;
- a value like `redis.aclConfigMaps` naming ConfigMaps that contain `users.acl` files, mounted into
  the pod and loaded with `--aclfile`. This scales better to several users, and passwords would come
  from a Secret.

Istio controls who connects; Redis controls what they may run.

**Q4.5**
Yes: `curl localhost:9000/charge` returns 200 with `caller_identity: null`, and payments' sidecar
logs nothing for it. Port-forward doesn't go over the pod network: kubectl → API server → kubelet,
which opens the connection **inside the pod's network namespace to 127.0.0.1:8080**. Istio's iptables
only redirect traffic arriving on the pod's interface to Envoy (port 15006), so this connection goes
straight to the app and skips the sidecar entirely: no mTLS, no PeerAuthentication, no
AuthorizationPolicy. (`svc/payments` just picks a pod; no Service routing is involved.)

This is also why Part 4 behaves differently over port-forward: forwarding to the gateway bypasses its
sidecar, so STRICT would not have broken the UI.

The only check is Kubernetes RBAC on `create pods/portforward`. That permission is effectively a
bypass around every mesh policy in the namespace, so it should be treated like admin: only
break-glass or on-call operators, time-limited, audited via API server audit logs, never CI or
application service accounts in production. The same applies to `pods/exec`, `pods/attach` and
`create pods`, since a new pod can run as any ServiceAccount in the namespace and take on its identity.

RBAC is additive (there are no deny rules), and the built-in `edit` and `admin` ClusterRoles grant
`pods/portforward`, `pods/exec` and `pods/attach`. So developers and CI shouldn't get `edit`, but a
custom deploy role without those subresources, and port-forward should be a separate role bound only
to an on-call group. Example implementation (not applied):
[`examples/shop-roles.yaml`](examples/shop-roles.yaml).

## Part 5 - Traffic management

**Q5.1**
Two resources:
- A **DestinationRule** ([`20-catalog-destinationrule.yaml`](istio/20-catalog-destinationrule.yaml))
  defines the subsets `v1` and `v2` of `catalog.shop.svc.cluster.local` by the `version` label. Each
  subset becomes its own Envoy cluster (`outbound|8080|v1|catalog...`). It's also where
  per-destination policy (load balancing, connection pool, outlier detection, TLS) would live. There's
  no `tls` override, so auto-mTLS keeps working under STRICT.
- A **VirtualService** ([`21-catalog-virtualservice.yaml`](istio/21-catalog-virtualservice.yaml))
  holds the routing rule for requests addressed to the catalog host: weight 90 to subset `v1`, 10 to
  `v2`. For each request Envoy does an independent weighted random pick, so the split no longer
  depends on replica counts. 200 requests gave 182 v1 / 18 v2.

The decision is made by the **caller's** sidecar: for UI traffic, the **gateway pod's Envoy**
(outbound). It applies the VirtualService, picks the subset, load-balances to one pod and connects to
that pod IP directly over mTLS. `istioctl proxy-config routes deploy/gateway-v1 --name 8080` shows the
weighted clusters (90/10). Catalog's own sidecar only enforces inbound security and records telemetry.
A caller without a sidecar wouldn't get the split at all; it would go through kube-proxy and get the
~50/50 from Part 1.

**Q5.2**
[`21-catalog-virtualservice.yaml`](istio/21-catalog-virtualservice.yaml) now has two HTTP routes,
checked top to bottom (first match wins): `canary-header` matches `x-canary: exact: always` and sends
100% to subset `v2`; everything else falls through to `weighted-split` (90/10). The header route must
come first, or the catch-all split would take every request. Result: 20/20 v2 with the header, 191 v1 /
9 v2 out of 200 without it. `istioctl proxy-config routes <gateway-pod> --name 8080 -o json` shows both
routes in that order.

Hop by hop:
1. **Browser → gateway pod.** The UI's JavaScript adds `x-canary: always` to its request. The gateway's
   inbound Envoy (port 8080, PERMISSIVE) passes the request to nginx unchanged; inbound sidecars don't
   route between versions.
2. **nginx → catalog.** nginx is a reverse proxy and by default copies the client's request headers
   onto the upstream request (only `Host` and, in this config, `Connection` are rewritten), so its new
   request to `catalog:8080/products` still carries `x-canary`.
3. **Gateway's outbound Envoy.** iptables sends nginx's outgoing request through the gateway pod's own
   sidecar. **This is where routing happens**: that Envoy evaluates the catalog VirtualService, sees the
   header, and picks a v2 pod. Catalog's sidecar only receives the result.

**catalog → inventory.** This hop is a brand-new HTTP request that the catalog *application* builds.
Envoy can't carry headers over from the inbound request: it sees two separate connections and doesn't
know which outgoing call was triggered by which incoming request. Only the app knows, which is why
`app.py` copies the `PROPAGATE` list (`x-canary`, `x-request-id`, `traceparent`, `b3` ...) onto its
downstream calls. If it didn't:
- Catalog's outbound Envoy would see an inventory request **without** `x-canary`. Today nothing breaks,
  because inventory has only v1 and no VirtualService. But once inventory gets its own canary with the
  same header rule, a tester would get catalog v2 with inventory **v1** (from the default split). That's
  a mixed version path, so the test isn't really exercising v2 end to end.
- For the same reason, distributed tracing would break: without `traceparent`/`b3`/`x-request-id` each
  hop would start a new trace, instead of one trace across gateway → catalog → inventory.

Header-based routing (and tracing) in a mesh only works end to end if every service in the chain
propagates the headers. The sidecar does the routing, but it relies on the app to pass the context on.

**Q5.3**
**Where:** in a VirtualService for the payments host,
[`30-payments-virtualservice.yaml`](istio/30-payments-virtualservice.yaml). Like all VirtualService
rules, it is executed by the **caller's** sidecar: the **orders pod's outbound Envoy** retries, and
neither the orders app nor payments is changed. The orders app only sees the final response.

**Conditions:**
- `retryOn: 5xx,reset,connect-failure`: retry on any 5xx response, on a connection reset, or when the
  connection can't be opened.
  - `5xx` is the one that matters here. Istio's default retry policy doesn't cover a plain HTTP 500,
    which is what payments returns, so without it the baseline stays at ~70%.
- `attempts: 3`: up to 4 tries in total. An order fails only if all 4 fail: 0.3⁴ ≈ 0.8%.
- `perTryTimeout: 1s`: a hung attempt is abandoned after 1s and retried, so a stuck call can't use up
  the app's own 3s timeout.

**Result:** before, `tools/load.sh /api/orders 100 5` gave 70 × 200 / 30 × 502. After: 100/100, and
297/300 in a longer run (1%, as expected). Orders' Envoy counters
(`kubectl exec deploy/orders-v1 -c istio-proxy -- pilot-agent request GET clusters`, payments cluster)
show the hidden work: over 100 orders, `rq_total` went up by **140** and `rq_error` by **40**. Payments
failed 40 attempts, Envoy retried each one, and all 100 orders succeeded.

**The danger:** a retry is safe only if doing the operation twice has the same effect as doing it once
(idempotent). A charge isn't, by default:
- A 500 or a timeout doesn't mean "nothing happened". Payments may have charged the card and then
  failed while writing the response, or answered after `perTryTimeout` expired. Envoy can't tell the
  difference and retries, so the customer is **charged twice** (or up to 4 times here).
- Retries also multiply load. If payments is failing because it's overloaded, up to 4× the requests
  make it worse (a retry storm). Retries at several layers multiply each other.

**What payments must guarantee:** **idempotency**. The client sends a unique **idempotency key** per
logical payment (for example the order ID, in a header such as `Idempotency-Key`), and payments stores
the key with the result. A repeated request with the same key returns the stored result instead of
charging again. That also requires the key to be propagated on every hop, like `x-canary`. Without
that guarantee, retries on a charge should be limited to failures where the request certainly never
reached the service (`connect-failure`, `refused-stream`), not `5xx`. Here, `5xx` retries are
acceptable only because the demo's failures are simulated before any "charge" happens.

**Q5.4**

## Written questions

**W1**

**W2**

**W3**

**W4**

**W5**

## Bonus (list what you did and where it lives)

