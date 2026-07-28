#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
SCRIPT=$ROOT/src/zstd-splitter.sh

test -f "$ROOT/docs/EIGIIB.md"
test -f "$ROOT/docs/INDEX.md"
grep -q 'EIGIIB:' "$SCRIPT"
grep -q 'Explicit Is Good, Implicit Is Better' "$ROOT/docs/EIGIIB.md"
grep -q 'docs/INDEX.md' "$ROOT/README.md"
grep -q 'EIGIIB' "$ROOT/docs/CODE-ARCHITECTURE.md"

readme_lines=$(wc -l <"$ROOT/README.md" | tr -d ' ')
arch_lines=$(wc -l <"$ROOT/docs/CODE-ARCHITECTURE.md" | tr -d ' ')
[ "$readme_lines" -le 190 ] || { echo 'README is too expansive for EIGIIB' >&2; exit 1; }
[ "$arch_lines" -le 120 ] || { echo 'architecture document is too expansive for EIGIIB' >&2; exit 1; }

# Public options may appear once in the man-page option table.
awk '/^\.SH ACTIONS AND OPTIONS/{in_options=1; next} /^\.SH /{in_options=0} in_options && /^\.B -/{print}'   "$ROOT/man/man1/zstd-splitter.1" | sort | uniq -d | grep . && {
    echo 'duplicate man-page option entries' >&2; exit 1;
} || :

help_tmp=${TMPDIR:-/tmp}/zss-eigiib-help.$$
trap 'rm -f "$help_tmp"' EXIT HUP INT TERM
"$SCRIPT" -h >"$help_tmp"
cmp -s "$help_tmp" "$ROOT/docs/BUILTIN_HELP.txt" || {
    echo 'BUILTIN_HELP.txt is stale' >&2; exit 1;
}
printf 'EIGIIB documentation test passed
'
