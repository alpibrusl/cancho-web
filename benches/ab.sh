#!/bin/bash
# Two builds of examples/users, alternated, on the same workloads as `run.sh` (docs/benchmarks.md): is a change free?
#
#   benches/ab.sh <binary A> <binary B> [rounds]
#
# Each round times A then B, so a drift of the machine lands on both; the medians are printed side by side with the
# spread. Server on core 0, `kload` on cores 2 and 3 (`taskset`: a machine with at least 4 cores), as in `run.sh`.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
a=$1; b=$2; rounds=${3:-5}
secs=${SECS:-5}
create_requests=${CREATE_REQUESTS:-40000}
kload=${KLOAD:-/tmp/kload}
[ -x "$kload" ] || gcc -O2 -o "$kload" "$here/benches/kload.c" -lpthread
BODY='{"name":"Ada Lovelace","email":"ada@example.org","age":36,"role":"admin","tags":["math","code"]}'
BAD='{"name":""}'
port=19500
start() { port=$((port + 1)); taskset -c 0 "$1" "$port" >/dev/null 2>&1 & PID=$!
  for _ in $(seq 1 100); do (echo > /dev/tcp/127.0.0.1/"$port") 2>/dev/null && break; sleep 0.1; done; sleep 0.3; }
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
  for who in A B; do
    bin=$a; [ $who = B ] && bin=$b
    start "$bin"; preload
    R[$who,read]+="$(KLOAD_EXPECT=200 load /users/500) "
    R[$who,page]+="$(KLOAD_EXPECT=200 load '/users?limit=20') "
    R[$who,bad]+="$(KLOAD_EXPECT=422 load /users - POST "$BAD") "
    R[$who,badq]+="$(KLOAD_EXPECT=422 load '/users?limit=0') "
    stop
    start "$bin"
    R[$who,create]+="$(KLOAD_EXPECT=201 KLOAD_REQUESTS=$create_requests load /users - POST "$BODY") "
    stop
  done
done
med() { printf '%s\n' "$@" | sort -n | sed -n "$(( ($# + 1) / 2 ))p"; }
lo() { printf '%s\n' "$@" | sort -n | head -1; }
hi() { printf '%s\n' "$@" | sort -n | tail -1; }
printf '%-16s %28s %28s %8s\n' "requests a second" "A (median, range)" "B (median, range)" "B / A"
for w in read page bad badq create; do
  set -- ${R[A,$w]}; ma=$(med "$@"); la=$(lo "$@"); ha=$(hi "$@")
  set -- ${R[B,$w]}; mb=$(med "$@"); lb=$(lo "$@"); hb=$(hi "$@")
  printf '%-16s %10s (%6s-%6s) %10s (%6s-%6s) %8s\n' "$w" "$ma" "$la" "$ha" "$mb" "$lb" "$hb" "$(python3 -c "print('%.3f' % ($mb / $ma))")"
done
