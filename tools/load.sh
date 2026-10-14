#!/usr/bin/env bash
# Fire N requests at a MeshMart path and summarise status codes and versions.
#
#   tools/load.sh /api/catalog            # 50 requests, sequential
#   tools/load.sh /api/orders 100 10      # 100 requests, 10 in parallel
#   HEADER='x-canary: always' tools/load.sh /api/catalog 20
#   BASE_URL=http://localhost:8080 tools/load.sh /api/catalog   # when using port-forward
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:30080}"
TARGET="${1:-/api/catalog}"
COUNT="${2:-50}"
CONC="${3:-1}"
HEADER="${HEADER:-}"
export BASE_URL TARGET HEADER

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

start=$(date +%s)
seq "$COUNT" | xargs -P "$CONC" -I{} bash -c '
  args=(-s -m 10 -w "\n%{http_code} %{time_total}")
  [ -n "$HEADER" ] && args+=(-H "$HEADER")
  out=$(curl "${args[@]}" "$BASE_URL$TARGET" || true)
  meta=$(printf "%s" "$out" | tail -n1)
  ver=$(printf "%s" "$out" | sed "\$d" | grep -o "\"version\": \"[^\"]*\"" | head -1 | cut -d\" -f4 || true)
  echo "$meta ${ver:--}"
' > "$tmp"
end=$(date +%s)

echo "== $COUNT x GET $BASE_URL$TARGET (concurrency $CONC, $((end - start))s)"
echo "-- status codes"
awk '{print "   " $1}' "$tmp" | sort | uniq -c
echo "-- versions (top-level service)"
awk '{print "   " $3}' "$tmp" | sort | uniq -c
echo "-- latency (s)"
awk '{print $2}' "$tmp" | sort -n | awk '{a[NR]=$1} END {if (NR) printf "   min %.3f  p50 %.3f  p90 %.3f  max %.3f\n", a[1], a[int((NR+1)*0.5)], a[int(NR*0.9) ? int(NR*0.9) : 1], a[NR]}'
