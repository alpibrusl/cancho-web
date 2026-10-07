#!/bin/bash
# Build an example against the locked packages.
#
#   scripts/build.sh examples/users/users.cho build/users
#
# The packages are fetched fresh and re-verified against the locks in deps/
# every time (`vcs fetch` refuses a store whose source no longer matches its
# pin), never taken from a copy checked in here. Where the stores live:
#
#   CANCHO        the cancho compiler binary     (default: cancho on PATH)
#   CANCHO_DIR    a checkout of cancho           (default: ../cancho)
#   SCHEMA_DIR     a checkout of cancho-schema     (default: ../cancho-schema)
#   PG_DIR         a checkout of cancho-pg         (default: ../cancho-pg; read only by a
#                  program that imports `pg`, and `pg.pool` from its `.cancho-vcs-pool`)
#
# Any other `.cho` file beside the program is built with it: the module `pgen` wrote
# for `examples/users_pg` is `queries.cho`, next to `users_pg.cho`.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
CANCHO=${CANCHO:-cancho}
CANCHO_DIR=${CANCHO_DIR:-$here/../cancho}
SCHEMA_DIR=${SCHEMA_DIR:-$here/../cancho-schema}
PG_DIR=${PG_DIR:-$here/../cancho-pg}
src=$1
out=$2
deps="$here/build/deps"
rm -rf "$deps"
mkdir -p "$deps" "$(dirname "$out")"
# One shared directory: `vcs fetch` writes each file as <source_hash>.cho, so
# two packages that share a dependency write one file, not two.
"$CANCHO" vcs fetch --lock "$here/deps/http-server.lock" --store "$CANCHO_DIR/packages/http-server/.cancho-vcs" -o "$deps" >/dev/null
"$CANCHO" vcs fetch --lock "$here/deps/schema.lock" --store "$SCHEMA_DIR/.cancho-vcs" -o "$deps" >/dev/null
if grep -q '^import pg;' "$src" "$(dirname "$src")"/*.cho; then
  "$CANCHO" vcs fetch --lock "$here/deps/pg.lock" --store "$PG_DIR/.cancho-vcs" -o "$deps" >/dev/null
fi
# `pg.pool` is a package of its own; its store requires `pg`'s, which `fetch` finds beside it
if grep -q '^import pg\.pool;' "$src" "$(dirname "$src")"/*.cho; then
  "$CANCHO" vcs fetch --lock "$here/deps/pool.lock" --store "$PG_DIR/.cancho-vcs-pool" -o "$deps" >/dev/null
fi
siblings=()
for f in "$(dirname "$src")"/*.cho; do
  [ "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" = "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" ] || siblings+=("$f")
done
"$CANCHO" build --std "$src" ${siblings[@]+"${siblings[@]}"} "$here"/src/*.cho "$deps"/*.cho -o "$out"
