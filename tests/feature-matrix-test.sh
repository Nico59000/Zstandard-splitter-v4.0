#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
SCRIPT=$ROOT/src/zstd-splitter.sh

"$SCRIPT" -Q config -O dry-run=yes >/dev/null
"$SCRIPT" -Q network -R example.invalid:/srv/backups -O dry-run=yes >/dev/null

for opt in profile=lan jobs=2 sftp-buffer=65536 sftp-requests=96 \
           stream-block=2097152 control-master=auto control-persist=30 \
           mtu-check=path tune=adaptive
do
    if "$SCRIPT" -Q network -R example.invalid:/srv/backups -O dry-run=yes -O "$opt" >/dev/null 2>&1; then
        echo "advanced 4.1 option unexpectedly enabled: $opt" >&2
        exit 1
    fi
done

if "$SCRIPT" -Q config -O dry-run=yes -O quorum=1 >/dev/null 2>&1; then
    echo 'quorum unexpectedly enabled before 4.2' >&2; exit 1
fi
if "$SCRIPT" -Q config -O dry-run=yes -O audit-log=/tmp/zss-audit.jsonl >/dev/null 2>&1; then
    echo 'audit-log unexpectedly enabled before 4.2' >&2; exit 1
fi
if "$SCRIPT" -Q config -O dry-run=yes -O gc-days=30 >/dev/null 2>&1; then
    echo 'gc-days unexpectedly enabled before 4.2' >&2; exit 1
fi
if "$SCRIPT" -Q health -R example.invalid:/srv/backups -O dry-run=yes >/dev/null 2>&1; then
    echo "4.0 unexpectedly enabled query health" >&2
    exit 1
fi
if "$SCRIPT" -Q inventory -R example.invalid:/srv/backups -O dry-run=yes >/dev/null 2>&1; then
    echo "4.0 unexpectedly enabled query inventory" >&2
    exit 1
fi
if "$SCRIPT" -Q gc -R example.invalid:/srv/backups -O dry-run=yes >/dev/null 2>&1; then
    echo "4.0 unexpectedly enabled query gc" >&2
    exit 1
fi
if "$SCRIPT" -Q portability -R example.invalid:/srv/backups -O dry-run=yes >/dev/null 2>&1; then
    echo "4.0 unexpectedly enabled query portability" >&2
    exit 1
fi

help=$($SCRIPT -h)
if printf '%s
' "$help" | grep -q '^  -Y '; then echo 'relay advertised before 4.2' >&2; exit 1; fi
printf 'feature matrix test passed for 4.0
'
