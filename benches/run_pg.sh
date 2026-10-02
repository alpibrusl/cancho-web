#!/bin/bash
# The users API on PostgreSQL: lex-sys (examples/users_pg) against FastAPI with SQLAlchemy and with
# asyncpg, on four workloads (docs/benchmarks.md, "On PostgreSQL").
#
#   PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres LEX_SYS=... benches/run_pg.sh [rounds]
#
# PGPORT must be a server the user may create and drop databases on (trust or no password). Each server
# gets a database of its own, created fresh from examples/users_pg/schema.sql before every run -- the same
# table and the same 1,000 preloaded users -- and is pinned to core 0, the load generator to cores 2 and 3,
# and PostgreSQL to core $PG_CORE (default 1), so the server under test, the database and the load do not
# share a core. `taskset`: this wants at least 4. Before any timing, `equivalent.py` sends the same
# requests to all three and refuses to go on unless the statuses and the successful bodies agree.
#
# pgbench is the floor: the same one-row lookup and the same insert, from C, by libpq, no HTTP and no
# framework: what PostgreSQL itself will do on its one core.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
rounds=${1:-3}
secs=${SECS:-5}
create_requests=${CREATE_REQUESTS:-20000}
kload=${KLOAD:-/tmp/kload}
pg_core=${PG_CORE:-1}
export PGHOST=${PGHOST:-127.0.0.1} PGPORT=${PGPORT:-5432} PGUSER=${PGUSER:-postgres}
[ -x "$kload" ] || gcc -O2 -o "$kload" "$here/benches/kload.c" -lpthread
"$here/scripts/build.sh" "$here/examples/users_pg/users_pg.ls" "$here/build/users_pg"

# Pin the postmaster, and so every backend it forks, to one core.
for p in $(pgrep -x postgres); do taskset -a -p -c "$pg_core" "$p" >/dev/null 2>&1 || true; done

NAMES=("lex-sys users_pg (1 connection, blocking)" "FastAPI + SQLAlchemy 2 async + asyncpg (pool 10)" "FastAPI + asyncpg (pool 10, lean)")
FA="python3 -m uvicorn app:app --port \$PORT --loop uvloop --http httptools"
CMDS=("$here/build/users_pg \$PORT $PGHOST $PGPORT $PGUSER \$DB -" "cd $here/benches/fastapi_users_pg && $FA" "cd $here/benches/fastapi_users_pg && LEAN=1 $FA")
LEX=0; ORM=1; LEAN=2
only=${ONLY:-"$LEX $ORM $LEAN"}   # ONLY=2 times one server (no equivalence run)

BODY='{"name":"Ada Lovelace","email":"ada@example.org","age":36,"role":"admin","tags":["math","code"]}'
BAD='{"name":""}'
port=19400
dbs=()

newdb() { # $1 = database name: dropped if it exists, created, the table made
  psql -q -d postgres -c "drop database if exists $1" -c "create database $1" >/dev/null
  psql -q -d "$1" -v ON_ERROR_STOP=1 -f "$here/examples/users_pg/schema.sql" >/dev/null 2>&1
  dbs+=("$1")
}
start() { # $1 = index; sets PID, DB and port
  port=$((port + 1)); export PORT=$port DB="lexbench_$port"
  newdb "$DB"
  export PGDATABASE=$DB
  bash -c "taskset -c 0 bash -c '${CMDS[$1]//\$DB/$DB}'" >/dev/null 2>&1 &
  PID=$!
  for _ in $(seq 1 100); do (echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null && break; sleep 0.1; done
  sleep 0.5
}
stop() { pkill -P "$PID" 2>/dev/null || true; kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; sleep 0.5; }
cleanup() { for d in "${dbs[@]}"; do psql -q -d postgres -c "drop database if exists $d" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT
preload() { python3 - "$port" <<'PY'
import http.client, json, sys
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
for i in range(1000):
    c.request("POST", "/users", json.dumps({"name": "user %d" % i, "email": "u%d@example.org" % i, "age": i % 100, "role": "user", "tags": ["a", "b"]}), {"Content-Type": "application/json"})
    c.getresponse().read()
PY
}
settle() { sleep "${SETTLE:-0}"; }
load() { settle; taskset -c 2,3 "$kload" "$port" 2 16 "$secs" "$@"; }

if [ -z "${ONLY:-}" ]; then
  echo "== equivalence (the 16 requests; lex-sys users_pg, FastAPI + SQLAlchemy, FastAPI + asyncpg)"
  declare -a PIDS PORTS
  for i in $LEX $ORM $LEAN; do start $i; PIDS+=("$PID"); PORTS+=("$port"); done
  set +e
  python3 "$here/benches/equivalent.py" "${PORTS[@]}"; eq=$?
  for p in "${PIDS[@]}"; do PID=$p; stop; done
  set -e
  [ $eq -eq 0 ] || exit 1
fi

printf '\n%-52s %12s %12s %12s %12s\n' "requests a second (median of $rounds)" "GET user" "GET list 20" "POST invalid" "POST create"
for i in $only; do
  declare -a r_read r_list r_bad r_create; r_read=(); r_list=(); r_bad=(); r_create=()
  for _ in $(seq 1 "$rounds"); do
    start "$i"; preload
    r_read+=("$(KLOAD_EXPECT=200 load /users/500)")
    r_list+=("$(KLOAD_EXPECT=200 load '/users?limit=20')")
    r_bad+=("$(KLOAD_EXPECT=422 load /users - POST "$BAD")")
    stop
    start "$i"   # a fresh table: creating users adds state
    r_create+=("$(KLOAD_EXPECT=201 KLOAD_REQUESTS=$create_requests load /users - POST "$BODY")")
    stop
  done
  med() { printf '%s\n' "$@" | sort -n | sed -n "$(( ($# + 1) / 2 ))p"; }
  printf '%-52s %12s %12s %12s %12s\n' "${NAMES[$i]}" "$(med "${r_read[@]}")" "$(med "${r_list[@]}")" "$(med "${r_bad[@]}")" "$(med "${r_create[@]}")"
done

echo
echo "GET one user, latency in microseconds under that load (p50 p90 p99 p99.9 max):"
for i in $only; do
  start "$i"; preload
  printf '%-52s %s\n' "${NAMES[$i]}" "$(KLOAD_EXPECT=200 load /users/500 lat | tail -1)"
  stop
done

echo
echo "PostgreSQL alone (pgbench, libpq, 16 clients, core $pg_core for the server and 2,3 for the client), transactions a second:"
newdb lexbench_floor
psql -q -d lexbench_floor -c "insert into users (name, email, age, role, tags) select 'user ' || i, 'u' || i || '@example.org', i % 100, 'user', '[\"a\",\"b\"]' from generate_series(0, 999) i" >/dev/null
printf '\\set id 500\nselect id, name, email, age, role, tags from users where id = :id;\n' > /tmp/pg_get.sql
printf 'insert into users (name, email, age, role, tags) values (%s, %s, 36, %s, %s) returning id;\n' "'Ada Lovelace'" "'ada@example.org'" "'admin'" "'[\"math\",\"code\"]'" > /tmp/pg_create.sql
for mode in simple extended prepared; do
  g=$(taskset -c 2,3 pgbench -n -M $mode -f /tmp/pg_get.sql -c 16 -j 2 -T "$secs" lexbench_floor | sed -n 's/^tps = \([0-9.]*\).*/\1/p')
  c=$(taskset -c 2,3 pgbench -n -M $mode -f /tmp/pg_create.sql -c 16 -j 2 -T "$secs" lexbench_floor | sed -n 's/^tps = \([0-9.]*\).*/\1/p')
  printf '  %-10s get one row %10.0f    insert %10.0f\n' "$mode" "$g" "$c"
done
