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

**Q2.2**

**Q2.3**

**Q2.4**

## Part 3 - Observability

**Q3.1**

**Q3.2**

**Q3.3**

## Part 4 - Zero trust

**Q4.1**

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

