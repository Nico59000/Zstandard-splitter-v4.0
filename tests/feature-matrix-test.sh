#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
SCRIPT=$ROOT/src/zstd-splitter.sh
help=$($SCRIPT -h)

if printf '%s\n' "$help" | grep -q '^  -Y'; then echo 'relay advertised below 4.2' >&2; exit 1; fi
for word in 'quorum=' 'audit-log=' 'gc-days='; do if printf '%s\n' "$help" | grep -q "$word"; then echo "4.2 option advertised: $word" >&2; exit 1; fi; done
for word in 'profile=' 'jobs=' 'sftp-buffer=' 'mtu-check='; do if printf '%s\n' "$help" | grep -q "$word"; then echo "4.1 option advertised: $word" >&2; exit 1; fi; done
if printf '%s\n' "$help" | grep -q ' -Q portability'; then echo 'portability query advertised in feature release' >&2; exit 1; fi
if "$SCRIPT" -Q config -O dry-run=yes -O 'profile=lan' >/dev/null 2>&1; then echo 'unexpected option: profile=lan' >&2; exit 1; fi
if "$SCRIPT" -Q config -O dry-run=yes -O 'jobs=2' >/dev/null 2>&1; then echo 'unexpected option: jobs=2' >&2; exit 1; fi
if "$SCRIPT" -Q config -O dry-run=yes -O 'sftp-buffer=65536' >/dev/null 2>&1; then echo 'unexpected option: sftp-buffer=65536' >&2; exit 1; fi
if "$SCRIPT" -Q config -O dry-run=yes -O 'sftp-requests=96' >/dev/null 2>&1; then echo 'unexpected option: sftp-requests=96' >&2; exit 1; fi
if "$SCRIPT" -Q config -O dry-run=yes -O 'stream-block=2097152' >/dev/null 2>&1; then echo 'unexpected option: stream-block=2097152' >&2; exit 1; fi
if "$SCRIPT" -Q config -O dry-run=yes -O 'control-master=auto' >/dev/null 2>&1; then echo 'unexpected option: control-master=auto' >&2; exit 1; fi
if "$SCRIPT" -Q config -O dry-run=yes -O 'control-persist=30' >/dev/null 2>&1; then echo 'unexpected option: control-persist=30' >&2; exit 1; fi
if "$SCRIPT" -Q config -O dry-run=yes -O 'mtu-check=path' >/dev/null 2>&1; then echo 'unexpected option: mtu-check=path' >&2; exit 1; fi
if "$SCRIPT" -Q config -O dry-run=yes -O 'tune=adaptive' >/dev/null 2>&1; then echo 'unexpected option: tune=adaptive' >&2; exit 1; fi
if "$SCRIPT" -Q config -O dry-run=yes -O 'quorum=1' >/dev/null 2>&1; then echo 'unexpected option: quorum=1' >&2; exit 1; fi
if "$SCRIPT" -Q config -O dry-run=yes -O 'audit-log=/tmp/zss-audit.jsonl' >/dev/null 2>&1; then echo 'unexpected option: audit-log=/tmp/zss-audit.jsonl' >&2; exit 1; fi
if "$SCRIPT" -Q config -O dry-run=yes -O 'gc-days=30' >/dev/null 2>&1; then echo 'unexpected option: gc-days=30' >&2; exit 1; fi
if "$SCRIPT" -Q health -R example.invalid:/srv/backups -O dry-run=yes >/dev/null 2>&1; then echo 'unexpected query: health' >&2; exit 1; fi
if "$SCRIPT" -Q inventory -R example.invalid:/srv/backups -O dry-run=yes >/dev/null 2>&1; then echo 'unexpected query: inventory' >&2; exit 1; fi
if "$SCRIPT" -Q gc -R example.invalid:/srv/backups -O dry-run=yes >/dev/null 2>&1; then echo 'unexpected query: gc' >&2; exit 1; fi
if "$SCRIPT" -Q portability -R example.invalid:/srv/backups -O dry-run=yes >/dev/null 2>&1; then echo 'unexpected portability query' >&2; exit 1; fi
printf 'feature matrix test passed for 4.0\n'
