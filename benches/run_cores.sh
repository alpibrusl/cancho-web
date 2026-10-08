#!/bin/bash
# Two cores each: cancho (two processes, and two threads of one) against FastAPI (two workers) and Go (two cores)
# (docs/benchmarks.md, "Two cores each").
#
#   CANCHO=... benches/run_cores.sh [rounds]
#
# `run.sh` is one core against one core, which is not how FastAPI is deployed. Here every server gets cores 0 and 1 (`taskset`),
# and the load generator `kload` cores 2 and 3, so this wants a machine with 4 cores. The workloads are the ones that share no
# state, because every process keeps its own store: `GET /health`, `POST /users` with a body that is refused, and
# `GET /users?limit=0`, a parameter that is refused. (A read of a stored user would find it on one worker and not on the other.)
# Each contestant also runs on one core (core 0) as the reference, so that the second core's worth is a number and not a claim.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
rounds=${1:-3}
secs=${SECS:-5}
kload=${KLOAD:-/tmp/kload}
[ -x "$kload" ] || gcc -O2 -o "$kload" "$here/benches/kload.c" -lpthread
"$here/scripts/build.sh" "$here/examples/users/users.cho" "$here/build/users"
"$here/scripts/build.sh" "$here/examples/users_threads/users_threads.cho" "$here/build/users_threads"
(cd "$here/benches/go_users" && go build -o "$here/build/go_users" .)

BAD='{"name":""}'
declare -a NAMES CMDS CORES
add() { NAMES+=("$1"); CORES+=("$2"); CMDS+=("$3"); }
add "cancho, 1 process"                       0   "$here/build/users \$PORT"
add "cancho, 2 processes (reuseport)"         0,1 "$here/build/users \$PORT reuseport & $here/build/users \$PORT reuseport & wait"
add "cancho, 2 threads of 1 process"          0,1 "$here/build/users_threads \$PORT"
add "Go net/http, 1 core"                     0   "$here/build/go_users \$PORT"
add "Go net/http, 2 cores"                    0,1 "$here/build/go_users \$PORT"
add "FastAPI lean, 1 worker"                  0   "cd $here/benches/fastapi_users && LEAN=1 python3 -m uvicorn app:app --port \$PORT --loop uvloop --http httptools"
add "FastAPI lean, 2 workers"                 0,1 "cd $here/benches/fastapi_users && LEAN=1 python3 -m uvicorn app:app --port \$PORT --loop uvloop --http httptools --workers 2"

port=19700
start() { # $1 = index; sets PID
  port=$((port + 1)); export PORT=$port
  # Its own process group, so that `stop` ends every process it started (two copies, a master and its workers).
  setsid bash -c "taskset -c ${CORES[$1]} bash -c '${CMDS[$1]//\$PORT/$port}'" >/dev/null 2>&1 &
  PID=$!
  for _ in $(seq 1 100); do (echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null && break; sleep 0.1; done
  sleep 0.7
}
stop() { kill -TERM -- "-$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; sleep 0.7; }
load() { taskset -c 2,3 "$kload" "$port" 2 16 "$secs" "$@"; }
med() { printf '%s\n' "$@" | sort -n | sed -n "$(( ($# + 1) / 2 ))p"; }

printf '%-36s %12s %14s %14s\n' "requests a second (median of $rounds)" "GET /health" "POST invalid" "GET ?limit=0"
for i in "${!NAMES[@]}"; do
  r_h=(); r_b=(); r_q=()
  for _ in $(seq 1 "$rounds"); do
    start "$i"
    r_h+=("$(KLOAD_EXPECT=200 load /health)")
    r_b+=("$(KLOAD_EXPECT=422 load /users - POST "$BAD")")
    r_q+=("$(KLOAD_EXPECT=422 load '/users?limit=0')")
    stop
  done
  printf '%-36s %12s %14s %14s\n' "${NAMES[$i]}" "$(med "${r_h[@]}")" "$(med "${r_b[@]}")" "$(med "${r_q[@]}")"
done
