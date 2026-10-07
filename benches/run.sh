#!/bin/bash
# The users API against FastAPI, Go and a hand-written C server, on four workloads
# (docs/benchmarks.md).
#
#   CANCHO=... benches/run.sh [rounds]
#
# Each server is pinned to core 0, alone, and the load generator to cores 2,3 --
# `taskset`, so this wants a machine with at least 4 cores. Before any timing,
# `equivalent.py` sends the same requests to the cancho service and to every other
# implementation and refuses to go on unless the statuses and the successful bodies
# agree, and `edges.py` does the same for the implementations that are not frameworks'
# to get wrong (the Go and C servers): a comparison of speeds is only a comparison if
# the work is the same work. The ceiling (a server that answers one canned reply)
# does no work and is timed on GET one user only.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
rounds=${1:-3}
secs=${SECS:-5}
create_requests=${CREATE_REQUESTS:-40000}
kload=${KLOAD:-/tmp/kload}
[ -x "$kload" ] || gcc -O2 -o "$kload" "$here/benches/kload.c" -lpthread
"$here/scripts/build.sh" "$here/examples/users/users.cho" "$here/build/users"
(cd "$here/benches/go_users" && go build -o "$here/build/go_users" .)
gcc -O2 -Wall -o "$here/build/floor" "$here/benches/c_floor/floor.c"
gcc -O2 -Wall -o "$here/build/ceiling" "$here/benches/c_floor/ceiling.c"

# name | command (given $PORT) | how to stop
declare -a NAMES CMDS
NAMES+=("cancho users");                CMDS+=("$here/build/users \$PORT")
NAMES+=("Go net/http");                  CMDS+=("$here/build/go_users \$PORT")
NAMES+=("C floor (hand-written epoll)"); CMDS+=("$here/build/floor \$PORT")
NAMES+=("C ceiling (canned reply)");     CMDS+=("$here/build/ceiling \$PORT")
NAMES+=("FastAPI, uvicorn (asyncio)");   CMDS+=("cd $here/benches/fastapi_users && python3 -m uvicorn app:app --port \$PORT")
NAMES+=("FastAPI, uvloop + httptools");  CMDS+=("cd $here/benches/fastapi_users && python3 -m uvicorn app:app --port \$PORT --loop uvloop --http httptools")
NAMES+=("FastAPI lean, uvloop + httptools"); CMDS+=("cd $here/benches/fastapi_users && LEAN=1 python3 -m uvicorn app:app --port \$PORT --loop uvloop --http httptools")
LEX=0; GO=1; FLOOR=2; CEILING=3; FASTAPI=4

BODY='{"name":"Ada Lovelace","email":"ada@example.org","age":36,"role":"admin","tags":["math","code"]}'
BAD='{"name":""}'
port=19300

start() { # $1 = index; sets PID
  port=$((port + 1)); export PORT=$port
  bash -c "taskset -c 0 bash -c '${CMDS[$1]//\$PORT/$port}'" >/dev/null 2>&1 &
  PID=$!
  for _ in $(seq 1 100); do (echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null && break; sleep 0.1; done
  sleep 0.5
}
stop() { pkill -P "$PID" 2>/dev/null || true; kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; sleep 0.5; }
preload() { python3 - "$port" <<'PY'
import http.client, json, sys
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
for i in range(1000):
    c.request("POST", "/users", json.dumps({"name": "user %d" % i, "email": "u%d@example.org" % i, "age": i % 100, "role": "user", "tags": ["a", "b"]}), {"Content-Type": "application/json"})
    c.getresponse().read()
PY
}
load() { taskset -c 2,3 "$kload" "$port" 2 16 "$secs" "$@"; }

echo "== equivalence (the 16 requests; cancho users, Go, C floor, FastAPI)"
declare -a PIDS PORTS
for i in $LEX $GO $FLOOR $FASTAPI; do start $i; PIDS+=("$PID"); PORTS+=("$port"); done
set +e
python3 "$here/benches/equivalent.py" "${PORTS[@]}"; eq=$?
for p in "${PIDS[@]}"; do PID=$p; stop; done
[ $eq -eq 0 ] || exit 1
echo "== edge cases (84 more; cancho users, Go, C floor)"
PIDS=(); PORTS=()
for i in $LEX $GO $FLOOR; do start $i; PIDS+=("$PID"); PORTS+=("$port"); done
python3 "$here/benches/edges.py" "${PORTS[@]}"; eq=$?
for p in "${PIDS[@]}"; do PID=$p; stop; done
set -e
[ $eq -eq 0 ] || exit 1

printf '\n%-40s %12s %12s %12s %12s\n' "requests a second (median of $rounds)" "GET user" "GET list 20" "POST invalid" "POST create"
for i in "${!NAMES[@]}"; do
  declare -a r_read r_list r_bad r_create; r_read=(); r_list=(); r_bad=(); r_create=()
  for _ in $(seq 1 "$rounds"); do
    start "$i"; preload
    r_read+=("$(KLOAD_EXPECT=200 load /users/500)")
    if [ "$i" = "$CEILING" ]; then stop; continue; fi
    r_list+=("$(KLOAD_EXPECT=200 load '/users?limit=20')")
    r_bad+=("$(KLOAD_EXPECT=422 load /users - POST "$BAD")")
    stop
    start "$i"   # a fresh store: creating users adds state
    r_create+=("$(KLOAD_EXPECT=201 KLOAD_REQUESTS=$create_requests load /users - POST "$BODY")")
    stop
  done
  med() { printf '%s\n' "$@" | sort -n | sed -n "$(( ($# + 1) / 2 ))p"; }
  if [ "$i" = "$CEILING" ]; then
    printf '%-40s %12s %12s %12s %12s\n' "${NAMES[$i]}" "$(med "${r_read[@]}")" - - -
    continue
  fi
  printf '%-40s %12s %12s %12s %12s\n' "${NAMES[$i]}" "$(med "${r_read[@]}")" "$(med "${r_list[@]}")" "$(med "${r_bad[@]}")" "$(med "${r_create[@]}")"
done

echo
echo "GET one user, latency in microseconds under that load (p50 p90 p99 p99.9 max):"
for i in $LEX $GO $FLOOR $CEILING $FASTAPI; do
  start "$i"; preload
  printf '%-40s %s\n' "${NAMES[$i]}" "$(KLOAD_EXPECT=200 load /users/500 lat | tail -1)"
  stop
done
