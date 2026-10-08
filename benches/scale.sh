#!/bin/bash
# Does a request cost more in a bigger API? (docs/benchmarks.md, "Does the size of the API matter?")
#
#   CANCHO=... benches/scale.sh [rounds]
#
# `users <port> - <n>` declares `n` operations more than the six the API has (`GET /filler/<i>/:id`, each with a path parameter; nothing
# answers them). The six real ones keep their ids, so the workloads are the ones of `run.sh`: the same requests to the same routes, in an
# API of 6, 206 and 2,006 operations. The rounds alternate the sizes, so a drift of the machine lands on all of them. Server on core 0,
# `kload` on cores 2 and 3 (`taskset`).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
rounds=${1:-5}
secs=${SECS:-5}
kload=${KLOAD:-/tmp/kload}
[ -x "$kload" ] || gcc -O2 -o "$kload" "$here/benches/kload.c" -lpthread
"$here/scripts/build.sh" "$here/examples/users/users.cho" "$here/build/users"
sizes=(0 200 2000)
port=19800
start() { port=$((port + 1)); taskset -c 0 "$here/build/users" "$port" - "$1" >/dev/null 2>&1 & PID=$!
  for _ in $(seq 1 600); do curl -s -o /dev/null --max-time 1 "localhost:$port/health" && break; sleep 0.1; done; sleep 0.3; }
stop() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; sleep 0.3; }
preload() { python3 - "$port" <<'PY'
import http.client, json, sys
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
for i in range(1000):
    c.request("POST", "/users", json.dumps({"name": "user %d" % i, "email": "u%d@example.org" % i, "age": i % 100, "role": "user", "tags": ["a", "b"]}), {"Content-Type": "application/json"})
    c.getresponse().read()
PY
}
load() { taskset -c 2,3 "$kload" "$port" 2 16 "$secs" "$@"; }
declare -A R
for _ in $(seq 1 "$rounds"); do
  for n in "${sizes[@]}"; do
    start "$n"; preload
    R[$n,read]+="$(KLOAD_EXPECT=200 load /users/500) "
    R[$n,page]+="$(KLOAD_EXPECT=200 load '/users?limit=20') "
    R[$n,refused]+="$(KLOAD_EXPECT=422 load '/users?limit=0') "
    stop
  done
done
med() { printf '%s\n' "$@" | sort -n | sed -n "$(( ($# + 1) / 2 ))p"; }
printf '%-26s %12s %12s %12s\n' "requests a second (median of $rounds)" "GET one" "page of 20" "?limit=0"
for n in "${sizes[@]}"; do
  set -- ${R[$n,read]};    a=$(med "$@")
  set -- ${R[$n,page]};    b=$(med "$@")
  set -- ${R[$n,refused]}; c=$(med "$@")
  printf '%-26s %12s %12s %12s\n' "$((n + 6)) operations" "$a" "$b" "$c"
done
