#!/usr/bin/env bash
# Self-check for the FINAL state of the exam (after Parts 4 and 5).
# It is not exhaustive and not the grade - the reviewer also reads your YAML and ANSWERS.md.
#
#   tools/check.sh
#   BASE_URL=http://localhost:8080 tools/check.sh    # when using port-forward
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:30080}"
pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
ko()   { echo "  FAIL  $1"; fail=$((fail + 1)); }
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@" || true; }
version_of() { grep -o '"version": "[^"]*"' | head -1 | cut -d'"' -f4; }

echo "== Edge (browser -> gateway)"
c=$(code "$BASE_URL/");            [ "$c" = 200 ] && ok "UI reachable at $BASE_URL" || ko "UI returned '$c' at $BASE_URL"
c=$(code "$BASE_URL/api/catalog"); [ "$c" = 200 ] && ok "/api/catalog returns 200" || ko "/api/catalog returned $c"

echo "== Least privilege (gateway must not reach internal services)"
c=$(code "$BASE_URL/api/inventory"); [ "$c" = 403 ] && ok "gateway -> inventory denied (403)" || ko "gateway -> inventory returned $c, expected 403"
c=$(code "$BASE_URL/api/payments");  [ "$c" = 403 ] && ok "gateway -> payments denied (403)"  || ko "gateway -> payments returned $c, expected 403"

echo "== Intruder (pod in namespace 'intruder')"
if kubectl -n intruder get pod intruder >/dev/null 2>&1; then
  c=$(kubectl -n intruder exec intruder -c shell -- curl -s -o /dev/null -m 5 -w '%{http_code}' http://payments.shop:8080/charge 2>/dev/null || true)
  case "$c" in
    200|500) ko "intruder reached payments over HTTP (got $c)";;
    *)       ok "intruder blocked from payments (got '${c:-nothing}')";;
  esac
  r=$(kubectl -n intruder exec intruder -c shell -- sh -c "printf 'PING\r\n' | nc -w 2 redis.shop 6379" 2>/dev/null || true)
  if printf '%s' "$r" | grep -q PONG; then ko "intruder talked to redis (got PONG)"; else ok "intruder blocked from redis"; fi
else
  echo "  SKIP  intruder pod not found (kubectl apply -f tools/intruder.yaml)"
fi

echo "== Resilience (40 orders; payments fails ~30% by design)"
good=0
for _ in $(seq 40); do [ "$(code "$BASE_URL/api/orders")" = 200 ] && good=$((good + 1)); done
[ "$good" -ge 38 ] && ok "orders succeeded $good/40" || ko "orders succeeded only $good/40"

echo "== Canary (100 catalog requests, expect roughly 90% v1 / 10% v2)"
v2=0
for _ in $(seq 100); do
  v=$(curl -s -m 10 "$BASE_URL/api/catalog" | version_of)
  [ "$v" = v2 ] && v2=$((v2 + 1))
done
if [ "$v2" -ge 3 ] && [ "$v2" -le 20 ]; then ok "v2 got $v2/100"; else ko "v2 got $v2/100 (expected ~10)"; fi

echo "== Header routing (x-canary: always -> v2)"
hv=0
for _ in $(seq 10); do
  v=$(curl -s -m 10 -H 'x-canary: always' "$BASE_URL/api/catalog" | version_of)
  [ "$v" = v2 ] && hv=$((hv + 1))
done
[ "$hv" = 10 ] && ok "10/10 canary-header requests hit v2" || ko "only $hv/10 canary-header requests hit v2"

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
