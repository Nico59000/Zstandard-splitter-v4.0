#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." 2>/dev/null && pwd -P)
SCRIPT=$ROOT/src/zstd-splitter.sh
VERSION=$(cat "$ROOT/VERSION")
fail() { printf 'runtime static audit failed: %s\n' "$*" >&2; exit 1; }
require_text() { grep -F "$1" "$SCRIPT" >/dev/null 2>&1 || fail "missing invariant: $1"; }
reject_text() { grep -F "$1" "$SCRIPT" >/dev/null 2>&1 && fail "forbidden construct present: $1" || :; }

# Shell execution discipline.
require_text '#!/bin/sh'
require_text 'set -eu'
require_text 'umask 077'
require_text 'trap cleanup 0'
reject_text 'eval '
reject_text '`'
reject_text 'StrictHostKeyChecking=no'
reject_text 'ForwardAgent=yes'
reject_text 'ForwardX11=yes'

# Environment, path, temporary-state and cleanup isolation.
require_text 'unset TAR_OPTIONS GZIP BZIP BZIP2'
require_text 'runtime_sanitize_path()'
require_text 'ZSTD_SPLITTER_TMPDIR'
reject_text 'secure_parent=${TMPDIR:-/tmp}'
require_text 'NETWORK_CONTROL_DIR=$NETWORK_TEMP_DIR/control'
require_text 'network_close_control_masters()'
require_text 'network_abort_active_stage()'
require_text 'ACTIVE_STAGE_TARGET='
require_text 'safe_remove_tree()'

# Filesystem/archive transaction invariants.
require_text 'source_type_walk()'
require_text 'refusing unsupported special filesystem object'
require_text 'validate_archive_members()'
require_text 'archive member contains a control character'
require_text 'publish_generated_set()'
require_text 'publish_staged_files()'
require_text 'manifest contains duplicate, missing, or ambiguous records'
require_text 'bundle_backed=0'
require_text 'bundle_installed=0'

# SSH/SFTP command construction and remote runtime environment.
require_text 'POSIX single-quote escaping'
require_text 'validate_remote_target()'
require_text 'validate_jump_spec()'
require_text 'PermitLocalCommand=no'
require_text 'ClearAllForwardings=yes'
require_text 'ENV= BASH_ENV= CDPATH= sh'

case $VERSION in
    4.0|4.0.1)
        require_text 'FEATURE_LEVEL=40'
        ;;
    4.1|4.1.1)
        require_text 'FEATURE_LEVEL=41'
        require_text 'PROGRESS_MODE='
        require_text 'ERROR_MODE='
        ;;
    4.2|4.2.1)
        require_text 'FEATURE_LEVEL=42'
        require_text 'prepare_audit_log()'
        require_text 'audit-log must not be a symbolic link'
        require_text 'PROGRESS_MODE='
        require_text 'ERROR_MODE='
        ;;
esac
case $VERSION in
    4.0.1|4.1.1|4.2.1)
        require_text 'shasum -a 256'
        require_text 'openssl dgst -sha256'
        require_text 'stat -f %z'
        ;;
esac

printf 'runtime static audit passed for %s\n' "$VERSION"
