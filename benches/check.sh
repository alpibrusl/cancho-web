#!/bin/bash
# Do the Go and C implementations still do the same work as examples/users?
#
#   LEX_SYS=... benches/check.sh
#
# Builds the lex-sys service, the Go server and the C server, starts all three fresh and
# runs benches/equivalent.py (16 requests) and benches/edges.py (84 more) with the lex-sys
# service as the reference. Seconds, no timing, no FastAPI: the gate the benchmark runs
# first, runnable on every push.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$here/build"
"$here/scripts/build.sh" "$here/examples/users/users.ls" "$here/build/users"
(cd "$here/benches/go_users" && go build -o "$here/build/go_users" .)
gcc -O2 -Wall -Werror -o "$here/build/floor" "$here/benches/c_floor/floor.c"
pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT
run() { # starts the three servers on fresh ports, then runs $1 against them
  pids=()
  local base=$((19600 + RANDOM % 300 * 4))
  "$here/build/users" $base >/dev/null & pids+=($!)
  "$here/build/go_users" $((base + 1)) & pids+=($!)
  "$here/build/floor" $((base + 2)) >/dev/null & pids+=($!)
  for p in 0 1 2; do
    for _ in $(seq 1 100); do (echo > /dev/tcp/127.0.0.1/$((base + p))) 2>/dev/null && break; sleep 0.1; done
  done
  python3 "$here/benches/$1" $base $((base + 1)) $((base + 2))
  cleanup
}
run equivalent.py
run edges.py
