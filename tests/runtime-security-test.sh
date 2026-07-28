#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." 2>/dev/null && pwd -P)
SCRIPT=$ROOT/src/zstd-splitter.sh
VERSION=$(cat "$ROOT/VERSION")
TMP=${TMPDIR:-/tmp}/zstd-splitter-runtime-security.$$ 
MOCK=$TMP/mock-bin
REMOTE=$TMP/remote
DATA=$TMP/data
ESCAPE=/tmp/zss-runtime-escape.$$
PWN=$TMP/pwned
PWN2=$TMP/pwned-option
trap 'rm -rf "$TMP" "$ESCAPE" "$PWN" "$PWN2"' 0 1 2 3 15
mkdir -p "$MOCK" "$REMOTE" "$DATA/source/sub"
printf 'alpha\n' >"$DATA/source/a file.txt"
printf 'beta\n' >"$DATA/source/sub/b.txt"

fail() { printf 'runtime security test failed: %s\n' "$*" >&2; exit 1; }

# PATH and option-injection hardening: a relative PATH entry and hostile tar
# environment option must neither invoke a local fake command nor break tar.
cat >"$TMP/tar" <<EOF_FAKE_TAR
#!/bin/sh
: >"$TMP/fake-tar-ran"
exit 91
EOF_FAKE_TAR
chmod +x "$TMP/tar"
(
    cd "$TMP"
    PATH=.:/usr/bin:/bin TAR_OPTIONS=--definitely-invalid-option \
        "$SCRIPT" -c -i -s 16K "$DATA/source" >/dev/null 2>"$TMP/path.err"
)
test ! -e "$TMP/fake-tar-ran" || fail "relative PATH command hijack succeeded"
test -f "$DATA/source.tar.zst.part.aaaaaa" || fail "baseline archive missing"

# Ambiguous manifests are rejected: scalar keys and part suffixes must be unique
# and the end marker must occur exactly once.
cp "$DATA/source.tar.zst.manifest.sha256" "$TMP/duplicate.manifest.sha256"
printf 'engine\tgzip\n' >>"$TMP/duplicate.manifest.sha256"
set +e
"$SCRIPT" -v -i -m "$TMP/duplicate.manifest.sha256" \
    "$DATA/source.tar.zst.part.aaaaaa" >/dev/null 2>"$TMP/duplicate.err"
duplicate_status=$?
set -e
[ "$duplicate_status" -ne 0 ] || fail "ambiguous duplicate manifest field was accepted"

# Sensitive outputs are private by default.
if stat -c %a "$DATA/source.tar.zst.part.aaaaaa" >/dev/null 2>&1; then
    [ "$(stat -c %a "$DATA/source.tar.zst.part.aaaaaa")" = 600 ] || fail "part mode is not 0600"
    [ "$(stat -c %a "$DATA/source.tar.zst.manifest.sha256")" = 600 ] || fail "manifest mode is not 0600"
fi

# Special objects are refused instead of being read indefinitely or exposing a
# device/socket through the archive pipeline.
mkdir "$DATA/special"
mkfifo "$DATA/special/blocking.fifo"
set +e
timeout 15 "$SCRIPT" -c -s 16K "$DATA/special" >/dev/null 2>"$TMP/special.err"
special_status=$?
set -e
[ "$special_status" -ne 0 ] || fail "FIFO source was accepted"
[ "$special_status" -ne 124 ] || fail "FIFO source caused a blocking timeout"

# Control bytes in paths are rejected and human diagnostics escape them,
# preventing terminal-control injection through filenames.
CONTROL_CHAR=$(printf '\033')
mkdir "$DATA/control-name"
printf 'unsafe\n' >"$DATA/control-name/file${CONTROL_CHAR}escape"
set +e
"$SCRIPT" -c -s 16K "$DATA/control-name" >/dev/null 2>"$TMP/control-name.err"
control_status=$?
set -e
[ "$control_status" -ne 0 ] || fail "control-character filename was accepted"
python3 - "$TMP/control-name.err" <<'PY_CONTROL'
import sys
raw=open(sys.argv[1],'rb').read()
assert b'\x1b' not in raw, raw
assert b'\\u001b' in raw, raw
PY_CONTROL

# The ambient TMPDIR is not trusted for network-control sockets or helper data.
mkdir "$TMP/untrusted-tmp"
REAL_MKTEMP=$(command -v mktemp)
cat >"$MOCK/mktemp" <<EOF_MKTEMP
#!/bin/sh
printf '%s\\n' "\$*" >>"$TMP/mktemp.log"
exec "$REAL_MKTEMP" "\$@"
EOF_MKTEMP
chmod +x "$MOCK/mktemp"
TMPDIR="$TMP/untrusted-tmp" ZSTD_SPLITTER_PATH="$MOCK:/usr/bin:/bin" \
    "$SCRIPT" -Q network -R "mock:$REMOTE/tmp-check" -O dry-run=yes \
    >/dev/null 2>"$TMP/tmpdir.err"
if grep -F "$TMP/untrusted-tmp" "$TMP/mktemp.log" >/dev/null 2>&1; then
    fail "ambient TMPDIR was used for security-sensitive network state"
fi
rm -f "$MOCK/mktemp"

# An interrupt must activate the global cleanup trap, kill direct pipeline
# children and remove private working directories without publishing output.
mkdir "$DATA/signal-source"
printf 'signal test\n' >"$DATA/signal-source/input"
cat >"$MOCK/zstd" <<'EOF_SLOW_ZSTD'
#!/bin/sh
exec sleep 30
EOF_SLOW_ZSTD
chmod +x "$MOCK/zstd"
set +e
ZSTD_SPLITTER_PATH="$MOCK:/usr/bin:/bin" "$SCRIPT" -c -i -s 16K \
    "$DATA/signal-source" >/dev/null 2>"$TMP/signal.err" &
signal_pid=$!
sleep 1
kill -TERM "$signal_pid" 2>/dev/null || :
wait "$signal_pid"
signal_status=$?
set -e
[ "$signal_status" -eq 143 ] || fail "TERM did not produce exit status 143 (got $signal_status)"
for signal_tmp in "$DATA"/.tar-splitter.*; do
    [ -e "$signal_tmp" ] || [ -L "$signal_tmp" ] || continue
    fail "working directory leaked after TERM: $signal_tmp"
done
test ! -e "$DATA/signal-source.tar.zst.part.aaaaaa" || fail "interrupted compression published output"
rm -f "$MOCK/zstd"

# A malicious tar member must be rejected before extraction. The pre-existing
# destination and any path outside the destination must remain untouched.
python3 - "$TMP/evil.tar" "$ESCAPE" <<'PY'
import io,sys,tarfile
archive,escape=sys.argv[1:]
with tarfile.open(archive,'w') as t:
    data=b'escape'
    x=tarfile.TarInfo('../'+escape.rsplit('/',1)[-1])
    x.size=len(data)
    t.addfile(x,io.BytesIO(data))
PY
zstd -q -f "$TMP/evil.tar" -o "$TMP/evil.tar.zst"
mkdir "$DATA/existing-destination"
printf 'KEEP\n' >"$DATA/existing-destination/sentinel"
set +e
"$SCRIPT" -x -f -d "$DATA/existing-destination" "$TMP/evil.tar.zst" >/dev/null 2>"$TMP/evil.err"
evil_status=$?
set -e
[ "$evil_status" -ne 0 ] || fail "path-traversal archive was accepted"
grep -q '^KEEP$' "$DATA/existing-destination/sentinel" || fail "existing extraction destination was changed"
test ! -e "$ESCAPE" || fail "archive escaped extraction staging"

# Local multi-file publication is transactional. Force the second final part
# move to fail and verify that the previous complete set is restored byte-for-byte.
mkdir "$DATA/transaction"
dd if=/dev/urandom of="$DATA/transaction/random.bin" bs=1024 count=128 2>/dev/null
"$SCRIPT" -c -i -s 16K "$DATA/transaction" >/dev/null
(
    cd "$DATA"
    sha256sum transaction.tar.zst.part.?????? transaction.tar.zst.manifest.sha256 >"$TMP/old-set.sha256"
)
printf 'changed\n' >>"$DATA/transaction/random.bin"
REAL_MV=$(command -v mv)
cat >"$MOCK/mv" <<EOF_MV
#!/bin/sh
case \${1-}:\${2-} in
    */.tar-splitter.*/part.aaaaab:"$DATA/transaction.tar.zst.part.aaaaab") exit 93 ;;
esac
exec "$REAL_MV" "\$@"
EOF_MV
chmod +x "$MOCK/mv"
set +e
ZSTD_SPLITTER_PATH="$MOCK:/usr/bin:/bin" "$SCRIPT" -c -i -f -s 16K "$DATA/transaction" >/dev/null 2>"$TMP/publish.err"
publish_status=$?
set -e
[ "$publish_status" -ne 0 ] || fail "forced publication failure unexpectedly succeeded"
(
    cd "$DATA"
    sha256sum -c "$TMP/old-set.sha256" >/dev/null
) || fail "previous output set was not restored after publication failure"
rm -f "$MOCK/mv"

# Extraction publication is transactional too: force the staging-directory
# rename to fail after the old destination is backed up, then require rollback.
rm -rf "$DATA/restore-target"
"$SCRIPT" -x -i -f -d "$DATA/restore-target" "$DATA/source.tar.zst.part.aaaaaa" >/dev/null
printf 'ORIGINAL\n' >"$DATA/restore-target/rollback-sentinel"
cat >"$MOCK/mv" <<EOF_MV2
#!/bin/sh
case \${1-}:\${2-} in
    */extracted:"$DATA/restore-target") exit 94 ;;
esac
exec "$REAL_MV" "\$@"
EOF_MV2
chmod +x "$MOCK/mv"
set +e
ZSTD_SPLITTER_PATH="$MOCK:/usr/bin:/bin" "$SCRIPT" -x -i -f -d "$DATA/restore-target" "$DATA/source.tar.zst.part.aaaaaa" >/dev/null 2>"$TMP/extract-rollback.err"
extract_status=$?
set -e
[ "$extract_status" -ne 0 ] || fail "forced extraction publication failure unexpectedly succeeded"
grep -q '^ORIGINAL$' "$DATA/restore-target/rollback-sentinel" || fail "old extraction destination was not restored"
rm -f "$MOCK/mv"

# Minimal SSH/SFTP harness. ssh executes the generated remote shell command;
# sftp copies files according to its batch input.
cat >"$MOCK/ssh" <<'PYSSH'
#!/usr/bin/env python3
import os,subprocess,sys
args=sys.argv[1:]
if '-O' in args:
    i=args.index('-O')
    if i+1 < len(args) and args[i+1] == 'exit':
        log=os.environ.get('ZSS_CONTROL_LOG')
        if log:
            with open(log,'a',encoding='utf-8') as f: f.write('control-master-exit\n')
        raise SystemExit(0)
raise SystemExit(subprocess.call(['/bin/sh','-c',sys.argv[-1]],stdin=sys.stdin,stdout=sys.stdout,stderr=sys.stderr,env=os.environ.copy()))
PYSSH
cat >"$MOCK/sftp" <<'PYSFTP'
#!/usr/bin/env python3
import os,shlex,shutil,sys
args=sys.argv[1:]; batch=None; i=0
while i < len(args):
    if args[i]=='-b': batch=args[i+1]; i+=2
    elif args[i] in ('-B','-R','-l','-P','-i','-J','-o'): i+=2
    else: i+=1
if not batch: raise SystemExit(2)
for raw in open(batch,encoding='utf-8'):
    p=shlex.split(raw.strip())
    if not p: continue
    j=1
    if j < len(p) and p[j]=='-a': j+=1
    src,dst=p[j],p[j+1]
    os.makedirs(os.path.dirname(dst) or '.',exist_ok=True)
    shutil.copyfile(src,dst)
PYSFTP
chmod +x "$MOCK/ssh" "$MOCK/sftp"

# Destination beginning with '-' is rejected before ssh can parse it as an
# option (for example ProxyCommand).
set +e
PATH="$MOCK:/usr/bin:/bin" "$SCRIPT" -Q network -R "-oProxyCommand=touch$PWN2:/tmp" >/dev/null 2>"$TMP/option-injection.err"
option_status=$?
set -e
[ "$option_status" -ne 0 ] || fail "SSH option-like destination was accepted"
test ! -e "$PWN2" || fail "SSH option injection executed"

# A remote path containing spaces, apostrophes, semicolons and shell text must
# remain a literal path. This is an end-to-end test of POSIX shell quoting.
REMOTE_TRICKY="$REMOTE/space and quote'; touch '$PWN'; #"
mkdir -p "$REMOTE_TRICKY"
ZSS_CONTROL_LOG="$TMP/control-close.log" PATH="$MOCK:/usr/bin:/bin" "$SCRIPT" -P -i \
    -R "mock:$REMOTE_TRICKY" -O remote-fsync=no -O remote-verify=archive \
    "$DATA/source.tar.zst.part.aaaaaa" >/dev/null
test ! -e "$PWN" || fail "remote path command injection executed"
BUNDLE="$REMOTE_TRICKY/source.tar.zst.bundle"
test -f "$BUNDLE/source.tar.zst.manifest.sha256" || fail "quoted remote publication missing"

case $VERSION in
    4.1|4.1.1|4.2|4.2.1)
        grep -q '^control-master-exit$' "$TMP/control-close.log" || \
            fail "persistent SSH control master was not explicitly closed"
        ;;
esac

# A collision without -f must fail cleanly and remove staging and lock state.
set +e
PATH="$MOCK:/usr/bin:/bin" "$SCRIPT" -P -i \
    -R "mock:$REMOTE_TRICKY" -O remote-fsync=no -O remote-verify=archive \
    "$DATA/source.tar.zst.part.aaaaaa" >/dev/null 2>"$TMP/collision.err"
collision_status=$?
set -e
[ "$collision_status" -ne 0 ] || fail "remote bundle collision unexpectedly succeeded"
for lock_entry in "$REMOTE_TRICKY/.zstd-splitter.locks"/*; do
    [ -e "$lock_entry" ] || [ -L "$lock_entry" ] || continue
    fail "remote lock leaked after failed publication"
done
for stage_entry in "$REMOTE_TRICKY/.zstd-splitter.incoming"/*; do
    [ -e "$stage_entry" ] || [ -L "$stage_entry" ] || continue
    fail "remote staging directory leaked after failed publication"
done

# Corrupt a remote part and require pull verification to fail before replacing
# any pre-existing local file.
REMOTE_PART="$BUNDLE/source.tar.zst.part.aaaaaa"
python3 - "$REMOTE_PART" <<'PY_CORRUPT'
import sys
p=sys.argv[1]
with open(p,'r+b') as f:
    b=f.read(1)
    f.seek(0)
    f.write(bytes([(b[0] if b else 0) ^ 0xff]))
PY_CORRUPT
mkdir "$DATA/pull-safe"
printf 'OLD-CONTENT\n' >"$DATA/pull-safe/source.tar.zst.part.aaaaaa"
printf 'SENTINEL\n' >"$DATA/pull-safe/sentinel"
set +e
PATH="$MOCK:/usr/bin:/bin" "$SCRIPT" -G -i \
    -R "mock:$REMOTE_PART" -d "$DATA/pull-safe" -O remote-fsync=no \
    >/dev/null 2>"$TMP/corrupt-pull.err"
pull_status=$?
set -e
[ "$pull_status" -ne 0 ] || fail "corrupt remote part set was accepted"
grep -q '^OLD-CONTENT$' "$DATA/pull-safe/source.tar.zst.part.aaaaaa" || fail "failed pull replaced existing file"
grep -q '^SENTINEL$' "$DATA/pull-safe/sentinel" || fail "failed pull changed unrelated destination content"

# 4.2 audit logs reject symlinks and are private regular files.
case $VERSION in
    4.2|4.2.1)
        printf 'AUDIT-TARGET\n' >"$TMP/audit-target"
        ln -s "$TMP/audit-target" "$TMP/audit-link"
        set +e
        "$SCRIPT" -Q config -O "audit-log=$TMP/audit-link" >/dev/null 2>"$TMP/audit-symlink.err"
        audit_symlink_status=$?
        set -e
        [ "$audit_symlink_status" -ne 0 ] || fail "symlink audit log was accepted"
        grep -q '^AUDIT-TARGET$' "$TMP/audit-target" || fail "audit-log symlink target was modified"
        "$SCRIPT" -Q config -O "audit-log=$TMP/audit.jsonl" >/dev/null
        [ -f "$TMP/audit.jsonl" ] || fail "audit log was not created"
        if stat -c %a "$TMP/audit.jsonl" >/dev/null 2>&1; then
            [ "$(stat -c %a "$TMP/audit.jsonl")" = 600 ] || fail "audit log mode is not 0600"
        fi
        ;;
esac

case $VERSION in
    4.1|4.1.1|4.2|4.2.1)
        set +e
        "$SCRIPT" -a json -b 3 -n -c -s 16K "$DATA/control-name" \
            >/dev/null 2>"$TMP/control-json.stderr" 3>"$TMP/control-json.jsonl"
        json_status=$?
        set -e
        [ "$json_status" -ne 0 ] || fail "control-character source unexpectedly succeeded in JSON mode"
        python3 - "$TMP/control-json.jsonl" <<'PY_JSON'
import json,sys
lines=[x for x in open(sys.argv[1],encoding='utf-8') if x.strip()]
assert lines
for line in lines: json.loads(line)
PY_JSON
        ;;
esac

printf 'runtime security adversarial test passed for %s\n' "$VERSION"
