#!/bin/bash
# Pin the authority report of the users service. `cancho authority` says what the program can do: the capabilities it performs (with their
# arguments), whether the report is bounded, and the foreign symbols it reaches. `docs/authority.json` is that report as of the last time a
# person approved it. This script regenerates it from the sources and the locked packages and fails on any difference, so a new capability or a
# new foreign call is a red diff that is only made green by committing the new file, which is the approval.
#
#   scripts/check-authority.sh             compare; exit 0 if the report is the committed one, 1 (and show the diff) if not
#   scripts/check-authority.sh --update    write docs/authority.json (after reading what changed)
#
#   CANCHO   the compiler (default: cancho on PATH; the revision ci.yml builds with)
#   EXAMPLE  which service (default: users, pinned in docs/authority.json; any other, e.g. `guarded`, `users_pg`, `users_threads`, in
#            docs/authority-<name>.json). All of examples/<name>/*.cho is analysed with it.
#
# The program is examples/<name>/*.cho, src/web.cho and the packages that `scripts/build.sh` fetches into build/deps (the script builds first, so it
# needs what build.sh needs: CANCHO_DIR, SCHEMA_DIR and, for users_pg, PG_DIR).
# What is left out of the pinned file: the list of provably pure functions and the three counts (`folded_operators`, `folded_calls`,
# `functions`). They change with every function anyone adds, say nothing about authority, and would make every change red. Everything else the report
# has is pinned, including any field a later compiler adds.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
CANCHO=${CANCHO:-cancho}
EXAMPLE=${EXAMPLE:-users}
pinned=docs/authority.json
[ "$EXAMPLE" = users ] || pinned=docs/authority-$EXAMPLE.json
mode=compare
case "${1:-}" in
  "") ;;
  --update) mode=update ;;
  *) echo "usage: $0 [--update]" >&2; exit 2 ;;
esac
cd "$here"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Building fetches the packages this example (and only this one) imports into build/deps, which is what is analysed with it.
scripts/build.sh "examples/$EXAMPLE/$EXAMPLE.cho" "$work/bin" >/dev/null
"$CANCHO" authority examples/$EXAMPLE/*.cho src/web.cho build/deps/*.cho --std --output json > "$work/raw.json"
python3 - "$work/raw.json" > "$work/report.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
if "unbounded_by" not in report:
    sys.exit("check-authority: this compiler's report has no `unbounded_by`; use the compiler ci.yml builds with")
for volatile in ("pure", "folded_operators", "folded_calls", "functions"):
    report.pop(volatile, None)
print(json.dumps(report, indent=2))
PY
if [ "$mode" = update ]; then
  cp "$work/report.json" "$pinned"
  echo "wrote $pinned"
  exit 0
fi
if diff -u "$pinned" "$work/report.json"; then
  echo "the committed authority report is what the $EXAMPLE service has"
else
  echo "check-authority: the report changed; read the diff, and if it is what you meant, run scripts/check-authority.sh --update and commit $pinned" >&2
  exit 1
fi
