#!/bin/bash
# Build an example against the locked packages.
#
#   scripts/build.sh examples/users/users.ls build/users
#
# The packages are fetched fresh and re-verified against the locks in deps/
# every time (`vcs fetch` refuses a store whose source no longer matches its
# pin), never taken from a copy checked in here. Where the stores live:
#
#   LEX_SYS        the lex-sys compiler binary     (default: lex-sys on PATH)
#   LEX_SYS_DIR    a checkout of lex-sys           (default: ../lex-sys)
#   SCHEMA_DIR     a checkout of lexsys-schema     (default: ../lexsys-schema)
#   PG_DIR         a checkout of lexsys-pg         (default: ../lexsys-pg; read only by a
#                  program that imports `pg`, and `pg.pool` from its `.lex-sys-vcs-pool`)
#
# Any other `.ls` file beside the program is built with it: the module `pgen` wrote
# for `examples/users_pg` is `queries.ls`, next to `users_pg.ls`.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
LEX_SYS=${LEX_SYS:-lex-sys}
LEX_SYS_DIR=${LEX_SYS_DIR:-$here/../lex-sys}
SCHEMA_DIR=${SCHEMA_DIR:-$here/../lexsys-schema}
PG_DIR=${PG_DIR:-$here/../lexsys-pg}
src=$1
out=$2
deps="$here/build/deps"
rm -rf "$deps"
mkdir -p "$deps" "$(dirname "$out")"
# One shared directory: `vcs fetch` writes each file as <source_hash>.ls, so
# two packages that share a dependency write one file, not two.
"$LEX_SYS" vcs fetch --lock "$here/deps/http-server.lock" --store "$LEX_SYS_DIR/packages/http-server/.lex-sys-vcs" -o "$deps" >/dev/null
"$LEX_SYS" vcs fetch --lock "$here/deps/schema.lock" --store "$SCHEMA_DIR/.lex-sys-vcs" -o "$deps" >/dev/null
if grep -q '^import pg;' "$src" "$(dirname "$src")"/*.ls; then
  "$LEX_SYS" vcs fetch --lock "$here/deps/pg.lock" --store "$PG_DIR/.lex-sys-vcs" -o "$deps" >/dev/null
fi
# `pg.pool` is a package of its own; its store requires `pg`'s, which `fetch` finds beside it
if grep -q '^import pg\.pool;' "$src" "$(dirname "$src")"/*.ls; then
  "$LEX_SYS" vcs fetch --lock "$here/deps/pool.lock" --store "$PG_DIR/.lex-sys-vcs-pool" -o "$deps" >/dev/null
fi
siblings=()
for f in "$(dirname "$src")"/*.ls; do
  [ "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" = "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" ] || siblings+=("$f")
done
"$LEX_SYS" build --std "$src" ${siblings[@]+"${siblings[@]}"} "$here"/src/*.ls "$deps"/*.ls -o "$out"
