#!/bin/bash
# The users API against FastAPI on four workloads (docs/benchmarks.md).
#
#   LEX_SYS=... benches/run.sh [rounds]
#
# Each server is pinned to core 0, alone, and the load generator to cores 2,3 --
# `taskset`, so this wants a machine with at least 4 cores. Before any timing,
# `equivalent.py` sends the same requests to the lex-sys service and to the FastAPI
# app and refuses to go on unless the statuses and the successful bodies agree: a
# comparison of speeds is only a comparison if the work is the same work.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
rounds=${1:-3}
secs=${SECS:-5}
create_requests=${CREATE_REQUESTS:-40000}
kload=${KLOAD:-/tmp/kload}
[ -x "$kload" ] || gcc -O2 -o "$kload" "$here/benches/kload.c" -lpthread
"$here/scripts/build.sh" "$here/examples/users/users.ls" "$here/build/users"

# name | command (given $PORT) | how to stop
declare -a NAMES CMDS
NAMES+=("lex-sys users");                CMDS+=("$here/build/users \$PORT")
NAMES+=("FastAPI, uvicorn (asyncio)");   CMDS+=("cd $here/benches/fastapi_users && python3 -m uvicorn app:app --port \$PORT")
NAMES+=("FastAPI, uvloop + httptools");  CMDS+=("cd $here/benches/fastapi_users && python3 -m uvicorn app:app --port \$PORT --loop uvloop --http httptools")
NAMES+=("FastAPI lean, uvloop + httptools"); CMDS+=("cd $here/benches/fastapi_users && LEAN=1 python3 -m uvicorn app:app --port \$PORT --loop uvloop --http httptools")

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

echo "== equivalence"
start 0; A=$PID; PA=$port
start 1; B=$PID; PB=$port
python3 "$here/benches/equivalent.py" "$PA" "$PB"
PID=$A; stop; PID=$B; stop

printf '\n%-40s %12s %12s %12s %12s\n' "requests a second (median of $rounds)" "GET user" "GET list 20" "POST invalid" "POST create"
for i in "${!NAMES[@]}"; do
  declare -a r_read r_list r_bad r_create; r_read=(); r_list=(); r_bad=(); r_create=()
  for _ in $(seq 1 "$rounds"); do
    start "$i"; preload
    r_read+=("$(KLOAD_EXPECT=200 load /users/500)")
    r_list+=("$(KLOAD_EXPECT=200 load '/users?limit=20')")
    r_bad+=("$(KLOAD_EXPECT=422 load /users - POST "$BAD")")
    stop
    start "$i"   # a fresh store: creating users adds state
    r_create+=("$(KLOAD_EXPECT=201 KLOAD_REQUESTS=$create_requests load /users - POST "$BODY")")
    stop
  done
  med() { printf '%s\n' "$@" | sort -n | sed -n "$(( ($# + 1) / 2 ))p"; }
  printf '%-40s %12s %12s %12s %12s\n' "${NAMES[$i]}" "$(med "${r_read[@]}")" "$(med "${r_list[@]}")" "$(med "${r_bad[@]}")" "$(med "${r_create[@]}")"
done
