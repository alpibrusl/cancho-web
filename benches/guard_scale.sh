#!/bin/bash
# Does the size of the API matter to `web.guard`? examples/guarded with 0, 200 and 2,000 more operations (each needing `admin`),
# the same two requests every time: GET /report with a valid admin token (a gated read) and GET /health (open). Rounds alternate the sizes so a
# drift of the machine lands on all of them. Server on core 0, `kload` on cores 2 and 3 (`taskset`: a machine with at least 4 cores).
#
#   CANCHO=... CANCHO_DIR=... SCHEMA_DIR=... benches/guard_scale.sh [rounds]
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
rounds=${1:-5}
secs=${SECS:-4}
sizes=${SIZES:-"0 200 2000"}
kload=${KLOAD:-/tmp/kload}
gcc -O2 -o "$kload" "$here/benches/kload.c" -lpthread
"$here/scripts/build.sh" "$here/examples/guarded/guarded.cho" "$here/build/guarded"
port=19700
declare -A R
for round in $(seq 1 "$rounds"); do
  for n in $sizes; do
    port=$((port + 1))
    taskset -c 0 "$here/build/guarded" "$port" adm1n-secret ingest-secret "$n" >/dev/null 2>&1 & pid=$!
    for _ in $(seq 1 100); do (echo > /dev/tcp/127.0.0.1/"$port") 2>/dev/null && break; sleep 0.1; done
    sleep 0.3
    g=$(KLOAD_EXPECT=200 KLOAD_HEADER="Authorization: Bearer adm1n-secret" taskset -c 2,3 "$kload" "$port" 2 16 "$secs" /report)
    o=$(KLOAD_EXPECT=200 taskset -c 2,3 "$kload" "$port" 2 16 "$secs" /health)
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; sleep 0.3
    R[g$n]="${R[g$n]:-} $g"; R[o$n]="${R[o$n]:-} $o"
  done
done
med() { printf '%s\n' "$@" | sort -n | sed -n "$(( ($# + 1) / 2 ))p"; }
printf '%-12s %14s %14s\n' "more ops" "gated read/s" "open read/s"
for n in $sizes; do
  printf '%-12s %14s %14s   (all: gated%s | open%s)\n' "$n" "$(med ${R[g$n]})" "$(med ${R[o$n]})" "${R[g$n]}" "${R[o$n]}"
done
