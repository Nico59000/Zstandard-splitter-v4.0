#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." 2>/dev/null && pwd -P)
TMP=${TMPDIR:-/tmp}/zstd-splitter-packaging-security.$$
trap 'rm -rf "$TMP"' 0 1 2 3 15
mkdir -p "$TMP"
fail() { printf 'packaging security test failed: %s\n' "$*" >&2; exit 1; }

set +e
PREFIX=relative sh "$ROOT/packaging/install.sh" >/dev/null 2>"$TMP/relative-install.err"
status=$?
set -e
[ "$status" -eq 2 ] || fail "relative install PREFIX was not rejected"
set +e
PREFIX='../escape' sh "$ROOT/packaging/uninstall.sh" >/dev/null 2>"$TMP/relative-uninstall.err"
status=$?
set -e
[ "$status" -eq 2 ] || fail "relative uninstall PREFIX was not rejected"

PREFIX="$TMP/prefix" sh "$ROOT/packaging/install.sh" >/dev/null
[ -x "$TMP/prefix/bin/zstd-splitter" ] || fail "installed executable missing"
[ -f "$TMP/prefix/share/doc/zstd-splitter/RUNTIME-SECURITY.md" ] || fail "runtime security documentation not installed"
[ -f "$TMP/prefix/share/man/man1/zstd-splitter.1.gz" ] || fail "manpage missing"

# An attacker-controlled documentation symlink is removed as a link rather than
# recursively following or deleting its target.
mkdir "$TMP/symlink-target"
printf 'KEEP\n' >"$TMP/symlink-target/sentinel"
rm -rf "$TMP/prefix/share/doc/zstd-splitter"
ln -s "$TMP/symlink-target" "$TMP/prefix/share/doc/zstd-splitter"
PREFIX="$TMP/prefix" sh "$ROOT/packaging/uninstall.sh" >/dev/null
[ ! -e "$TMP/prefix/share/doc/zstd-splitter" ] || fail "documentation symlink was not removed"
grep -q '^KEEP$' "$TMP/symlink-target/sentinel" || fail "uninstall followed documentation symlink"

printf 'packaging security test passed\n'
