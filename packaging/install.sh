#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL
umask 022
PREFIX=${PREFIX:-/usr/local}
case $PREFIX in
    /*) ;;
    *) printf 'install: PREFIX must be an absolute path\n' >&2; exit 2 ;;
esac
case "/$PREFIX/" in
    */../*|*/./*) printf 'install: PREFIX must not contain dot traversal\n' >&2; exit 2 ;;
esac
if printf '%s' "$PREFIX" | grep '[[:cntrl:]]' >/dev/null 2>&1; then
    printf 'install: PREFIX contains a control character\n' >&2; exit 2
fi
case $PREFIX in /) DEST_ROOT= ;; *) DEST_ROOT=${PREFIX%/} ;; esac
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")/.." 2>/dev/null && pwd -P)
[ -f "$SCRIPT_DIR/src/zstd-splitter.sh" ] || { printf 'install: package source is missing\n' >&2; exit 1; }
install -d "$DEST_ROOT/bin" "$DEST_ROOT/share/man/man1" "$DEST_ROOT/share/doc/zstd-splitter"
install -m 0755 "$SCRIPT_DIR/src/zstd-splitter.sh" "$DEST_ROOT/bin/zstd-splitter"
install -m 0644 "$SCRIPT_DIR/man/man1/zstd-splitter.1.gz" "$DEST_ROOT/share/man/man1/zstd-splitter.1.gz"
for document in "$SCRIPT_DIR/README.md" "$SCRIPT_DIR/CHANGELOG.md" "$SCRIPT_DIR"/docs/*.md
do
    [ -f "$document" ] || continue
    install -m 0644 "$document" "$DEST_ROOT/share/doc/zstd-splitter/$(basename "$document")"
done
printf 'Installed zstd-splitter under %s\n' "$PREFIX"
