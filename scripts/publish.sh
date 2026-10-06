#!/bin/bash
# Publish `src/web.ls` as a package: the `lex-sys-vcs` store a project names in its `lex-sys.toml`
#
#   [dependencies.web]
#   git = "https://github.com/alpibrusl/lexsys-web"
#   rev = "<a commit that has the store>"
#   path = ".lex-sys-vcs"
#
# `web` imports `schema`, so the store records `lexsys-schema` as a requirement, at the commit `SCHEMA_REV` of
# `.github/workflows/ci.yml` (a consumer fetches it from there; it must be named in the consumer's own project file too,
# which is where the consumer's program imports it). A store refuses a changed body, so it is rebuilt, never appended to.
#
#   scripts/publish.sh           rebuild .lex-sys-vcs from src/web.ls (commit the result)
#   scripts/publish.sh --check   rebuild it in a temporary directory and fail if it is not the committed one
#
#   LEX_SYS   the compiler (default: lex-sys on PATH; the revision CI builds with)
# Needs git and network access to the schema repository (a checkout is cached by the compiler).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
LEX_SYS=${LEX_SYS:-lex-sys}
rev=$(sed -n 's/^ *SCHEMA_REV: *//p' "$here/.github/workflows/ci.yml")
[ -n "$rev" ] || { echo "publish: no SCHEMA_REV in ci.yml" >&2; exit 2; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$LEX_SYS" vcs lock --git https://github.com/alpibrusl/lexsys-schema --rev "$rev" -o "$work/schema.lock" --all >/dev/null
out=$here/.lex-sys-vcs
[ "${1:-}" = --check ] && out=$work/store
rm -rf "$out"
(cd "$here" && "$LEX_SYS" vcs publish --std --store "$out" --requires "$work/schema.lock" src/web.ls >/dev/null)
if [ "${1:-}" = --check ]; then
  diff -r "$work/store" "$here/.lex-sys-vcs" >/dev/null || { echo "publish: .lex-sys-vcs is not what src/web.ls publishes; run scripts/publish.sh" >&2; exit 1; }
  echo "the committed store is what src/web.ls publishes"
fi
