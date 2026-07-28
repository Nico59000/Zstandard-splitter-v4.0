#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL
PREFIX=${PREFIX:-/usr/local}
case $PREFIX in
    /*) ;;
    *) printf 'uninstall: PREFIX must be an absolute path\n' >&2; exit 2 ;;
esac
case "/$PREFIX/" in
    */../*|*/./*) printf 'uninstall: PREFIX must not contain dot traversal\n' >&2; exit 2 ;;
esac
if printf '%s' "$PREFIX" | grep '[[:cntrl:]]' >/dev/null 2>&1; then
    printf 'uninstall: PREFIX contains a control character\n' >&2; exit 2
fi
case $PREFIX in /) DEST_ROOT= ;; *) DEST_ROOT=${PREFIX%/} ;; esac
rm -f "$DEST_ROOT/bin/zstd-splitter" "$DEST_ROOT/share/man/man1/zstd-splitter.1.gz"
DOC_DIR=$DEST_ROOT/share/doc/zstd-splitter
if [ -L "$DOC_DIR" ]; then
    rm -f "$DOC_DIR"
elif [ -d "$DOC_DIR" ]; then
    rm -rf "$DOC_DIR"
elif [ -e "$DOC_DIR" ]; then
    rm -f "$DOC_DIR"
fi
printf 'Removed zstd-splitter from %s\n' "$PREFIX"
