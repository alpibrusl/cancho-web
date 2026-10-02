#!/bin/bash
# N copies of the blocking users_pg service on core 0, sharing one port (`reuseport`, its eighth argument):
# while one waits for PostgreSQL another can use the core. PostgreSQL on core 1, the load generator on
# cores 2 and 3, as in run_pg.sh (docs/benchmarks.md, "Copies of the blocking service").
#
#   PGHOST=... PGPORT=... PGUSER=... [COPIES="1 2 3 4"] [ROUNDS=3] [SECS=5] [SKIPREAD=1] benches/run_pg_copies.sh
#
# SKIPREAD=1 times only creates, one line per run: writes are noisy (a single copy ranged from 2.1k to 4.2k
# creates a second across ten runs), so look at the runs, not one median.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-127.0.0.1} PGPORT=${PGPORT:-5432} PGUSER=${PGUSER:-postgres}
secs=${SECS:-5}; rounds=${ROUNDS:-3}; creates=${CREATES:-20000}
"$here/scripts/build.sh" "$here/examples/users_pg/users_pg.ls" "$here/build/users_pg"
BIN=$here/build/users_pg
kload=${KLOAD:-/tmp/kload}
[ -x "$kload" ] || gcc -O2 -o "$kload" "$here/benches/kload.c" -lpthread
for p in $(pgrep -x postgres); do taskset -a -p -c 1 "$p" >/dev/null 2>&1 || true; done
port=19700
dbs=()
newdb() { psql -q -d postgres -c "drop database if exists $1" -c "create database $1" >/dev/null 2>&1; psql -q -d "$1" -v ON_ERROR_STOP=1 -f $here/examples/users_pg/schema.sql >/dev/null 2>&1; }
declare -a PIDS
start() { # $1 = copies
  port=$((port+1)); DB=lexreuse_$port; newdb $DB; PIDS=()
  for i in $(seq 1 $1); do taskset -c 0 $BIN $port $PGHOST $PGPORT $PGUSER $DB - reuseport >/dev/null 2>&1 & PIDS+=($!); sleep 0.3; done
  for _ in $(seq 1 100); do (echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null && break; sleep 0.1; done
  sleep 0.5
}
stop() { for p in "${PIDS[@]}"; do kill $p 2>/dev/null; wait $p 2>/dev/null; done; psql -q -d postgres -c "drop database if exists $DB" >/dev/null 2>&1; sleep 0.5; }
preload() { python3 - $port <<'PY'
import http.client, json, sys
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
for i in range(1000):
    c.request("POST", "/users", json.dumps({"name": "user %d" % i, "email": "u%d@example.org" % i, "age": i % 100, "role": "user", "tags": ["a", "b"]}), {"Content-Type": "application/json"})
    c.getresponse().read()
PY
}
med() { printf '%s\n' "$@" | sort -n | sed -n "$(( ($# + 1) / 2 ))p"; }
BODY='{"name":"Ada Lovelace","email":"ada@example.org","age":36,"role":"admin","tags":["math","code"]}'
printf '%-8s %12s %12s %12s\n' "copies" "GET user" "GET list 20" "POST create"
for n in ${COPIES:-1 2 3 4}; do
  rd=(); ls=(); cr=()
  for _ in $(seq 1 $rounds); do
    if [ -z "${SKIPREAD:-}" ]; then
    start $n; preload
    rd+=("$(KLOAD_EXPECT=200 taskset -c 2,3 $kload $port 2 16 $secs /users/500)")
    ls+=("$(KLOAD_EXPECT=200 taskset -c 2,3 $kload $port 2 16 $secs '/users?limit=20')")
    stop
    fi
    start $n
    cr+=("$(KLOAD_EXPECT=201 KLOAD_REQUESTS=$creates taskset -c 2,3 $kload $port 2 16 $secs /users - POST "$BODY")")
    [ -n "${SKIPREAD:-}" ] && echo "  copies=$n create run: ${cr[-1]}"
    stop
  done
  if [ -n "${SKIPREAD:-}" ]; then printf '%-8s create median %s\n' $n "$(med "${cr[@]}")"; else printf '%-8s %12s %12s %12s\n' $n "$(med "${rd[@]}")" "$(med "${ls[@]}")" "$(med "${cr[@]}")"; fi
done
