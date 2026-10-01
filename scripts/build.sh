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
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
LEX_SYS=${LEX_SYS:-lex-sys}
LEX_SYS_DIR=${LEX_SYS_DIR:-$here/../lex-sys}
SCHEMA_DIR=${SCHEMA_DIR:-$here/../lexsys-schema}
src=$1
out=$2
deps="$here/build/deps"
rm -rf "$deps"
mkdir -p "$deps" "$(dirname "$out")"
# One shared directory: `vcs fetch` writes each file as <source_hash>.ls, so
# two packages that share a dependency write one file, not two.
"$LEX_SYS" vcs fetch --lock "$here/deps/http-server.lock" --store "$LEX_SYS_DIR/packages/http-server/.lex-sys-vcs" -o "$deps" >/dev/null
"$LEX_SYS" vcs fetch --lock "$here/deps/schema.lock" --store "$SCHEMA_DIR/.lex-sys-vcs" -o "$deps" >/dev/null
"$LEX_SYS" build --std "$src" "$deps"/*.ls -o "$out"
