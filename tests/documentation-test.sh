#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
SCRIPT=$ROOT/src/zstd-splitter.sh
EXPECTED_VERSION=4.0
EXPECTED_LEVEL=40
TMP_HELP=${TMPDIR:-/tmp}/zstd-splitter-help.$$
trap 'rm -f "$TMP_HELP"' 0 1 2 3 15

actual_version=$($SCRIPT --version)
[ "$actual_version" = "zstd-splitter.sh $EXPECTED_VERSION" ] || {
    echo "unexpected --version output: $actual_version" >&2; exit 1
}
[ "$(cat "$ROOT/VERSION")" = "$EXPECTED_VERSION" ] || { echo 'VERSION mismatch' >&2; exit 1; }
grep -q "^PROGRAM_VERSION=$EXPECTED_VERSION$" "$SCRIPT"
grep -q "^FEATURE_LEVEL=$EXPECTED_LEVEL$" "$SCRIPT"
"$SCRIPT" -h >"$TMP_HELP"
cmp "$TMP_HELP" "$ROOT/docs/BUILTIN_HELP.txt"
for file in README.md CHANGELOG.md man/man1/zstd-splitter.1 \
            docs/CODE-ARCHITECTURE.md docs/VERSION-MATRIX.md \
            docs/FEATURE-MATRIX-AUDIT.md
do
    test -s "$ROOT/$file" || { echo "missing documentation: $file" >&2; exit 1; }
done
if grep -F -- 'profile=safe|lan' "$TMP_HELP" >/dev/null 2>&1; then
    echo "unavailable feature advertised in help: profile=safe|lan" >&2; exit 1
fi
if grep -F -- 'jobs=NUMBER' "$TMP_HELP" >/dev/null 2>&1; then
    echo "unavailable feature advertised in help: jobs=NUMBER" >&2; exit 1
fi
if grep -F -- 'mtu-check=' "$TMP_HELP" >/dev/null 2>&1; then
    echo "unavailable feature advertised in help: mtu-check=" >&2; exit 1
fi
if grep -F -- '  -Y' "$TMP_HELP" >/dev/null 2>&1; then
    echo "unavailable feature advertised in help:   -Y" >&2; exit 1
fi
if grep -F -- 'quorum=NUMBER' "$TMP_HELP" >/dev/null 2>&1; then
    echo "unavailable feature advertised in help: quorum=NUMBER" >&2; exit 1
fi
if grep -F -- 'audit-log=FILE' "$TMP_HELP" >/dev/null 2>&1; then
    echo "unavailable feature advertised in help: audit-log=FILE" >&2; exit 1
fi
if grep -F -- '-Q portability' "$TMP_HELP" >/dev/null 2>&1; then
    echo "unavailable feature advertised in help: -Q portability" >&2; exit 1
fi
printf 'documentation test passed for 4.0\n'
