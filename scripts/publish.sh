#!/bin/bash
# Publish `src/web.cho` as a package: the `cancho-vcs` store a project names in its `cancho.toml`
#
#   [dependencies.web]
#   git = "https://github.com/alpibrusl/cancho-web"
#   rev = "<a commit that has the store>"
#   path = ".cancho-vcs"
#
# `web` imports `schema`, so the store records `cancho-schema` as a requirement, at the commit `SCHEMA_REV` of
# `.github/workflows/ci.yml` (a consumer fetches it from there; it must be named in the consumer's own project file too,
# which is where the consumer's program imports it). A store refuses a changed body, so it is rebuilt, never appended to.
#
#   scripts/publish.sh           rebuild .cancho-vcs from src/web.cho (commit the result)
#   scripts/publish.sh --check   rebuild it in a temporary directory and fail if it is not the committed one
#
#   CANCHO   the compiler (default: cancho on PATH; the revision CI builds with)
# Needs git and network access to the schema repository (a checkout is cached by the compiler).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
CANCHO=${CANCHO:-cancho}
rev=$(sed -n 's/^ *SCHEMA_REV: *//p' "$here/.github/workflows/ci.yml")
[ -n "$rev" ] || { echo "publish: no SCHEMA_REV in ci.yml" >&2; exit 2; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$CANCHO" vcs lock --git https://github.com/alpibrusl/cancho-schema --rev "$rev" -o "$work/schema.lock" --all >/dev/null
out=$here/.cancho-vcs
[ "${1:-}" = --check ] && out=$work/store
rm -rf "$out"
(cd "$here" && "$CANCHO" vcs publish --std --store "$out" --requires "$work/schema.lock" src/web.cho >/dev/null)
if [ "${1:-}" = --check ]; then
  diff -r "$work/store" "$here/.cancho-vcs" >/dev/null || { echo "publish: .cancho-vcs is not what src/web.cho publishes; run scripts/publish.sh" >&2; exit 1; }
  echo "the committed store is what src/web.cho publishes"
fi
