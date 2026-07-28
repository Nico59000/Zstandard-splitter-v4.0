#!/bin/sh

# zstd-splitter.sh 4.0 — POSIX tar compression, splitting, integrity, and SSH/SFTP.
#
# EIGIIB: contracts and hazards are explicit; routine mechanics stay implicit
# in names, ordering, and tests. Comments explain why, not what the next line does.
#
# Flow: bootstrap -> observers -> safeguards -> engines -> manifest -> local work
#       -> network policy -> transport/transactions -> version-gated admin -> CLI.
#
# Invariants:
# - manifests are parsed as data, never executed;
# - validated output is published transactionally;
# - user-controlled remote text is validated and quoted;
# - temporary state is private and cleaned on exit or signal;
# - FEATURE_LEVEL is the sole capability boundary across the shared 4.x skeleton.

set -eu
LC_ALL=C
export LC_ALL

# Neutralize ambient tool options; generated state is private by default.
IFS=' \t\n'
CDPATH=
ENV=
BASH_ENV=
unset TAR_OPTIONS GZIP BZIP BZIP2 XZ_DEFAULTS XZ_OPT ZSTD_CLEVEL \
    ZSTD_NBTHREADS LZIP LZOP LZ4_CLEVEL POSIXLY_CORRECT ENV BASH_ENV CDPATH \
    2>/dev/null || :
umask 077

PROGRAM_NAME=${0##*/}
PROGRAM_VERSION=4.0
MANIFEST_FORMAT=1
SUFFIX_LENGTH=6
ACTION=
PART_SIZE=
ENGINE=zstd
ENGINE_SET=0
COMPRESSION_LEVEL=
THREADS=0
THREADS_SET=0
FORCE=0
STRICT_INTEGRITY=0
MANIFEST_FILE=
DESTINATION=
WORK_DIR=
TAR_PID=
COMPRESS_PID=
SPLIT_PID=
EXTRACT_PID=
LAST_ARCHIVE=
CHILD_PIDS=
RUNTIME_PATH_READY=0
EXTRACTION_DESTINATION=
EXTRACTION_STAGE=
EXTRACTION_BACKUP=

FEATURE_LEVEL=40
NETWORK_OPTIONS=
NETWORK_CONFIG=
REMOTE_DESTINATIONS=
NETWORK_QUERY_MODE=
NETWORK_TEMP_DIR=
NETWORK_CONTROL_DIR=
NETWORK_COUNTER=0
SELF_PATH=
LAST_PART_PREFIX=
LAST_MANIFEST=
NET_PROFILE=safe
NET_TRANSPORT=sftp
NET_RESUME=yes
NET_ATOMIC=yes
NET_REMOTE_VERIFY=all
NET_REMOTE_EXTRACT=
NET_RETRY=3
NET_RETRY_DELAY=3
NET_BACKOFF=linear
NET_CONNECT_TIMEOUT=15
NET_KEEPALIVE_INTERVAL=15
NET_KEEPALIVE_COUNT=3
NET_HOST_KEY_POLICY=strict
NET_KNOWN_HOSTS=
NET_IDENTITY=
NET_PORT=
NET_JUMP=
NET_ADDRESS_FAMILY=any
NET_BIND_INTERFACE=
NET_BIND_ADDRESS=
NET_SSH_COMPRESSION=no
NET_CONTROL_MASTER=no
NET_CONTROL_PERSIST=0
NET_JOBS=1
NET_SFTP_BUFFER=32768
NET_SFTP_REQUESTS=64
NET_BANDWIDTH=0
NET_STREAM_BLOCK=1048576
NET_MTU_CHECK=off
NET_MTU_REQUIRED=9000
NET_TUNE=off
NET_REMOTE_FSYNC=yes
NET_CLEANUP=always
NET_DRY_RUN=no
NET_QUORUM=0
NET_AUDIT_LOG=
NET_GC_DAYS=7
NET_RETAIN=all
NET_LOCK=yes
NET_ALLOW_UNVERIFIED=no
ACTIVE_STAGE_TARGET=
ACTIVE_STAGE_DIR=
ACTIVE_STAGE_LOCK=
NETWORK_CONNECTED_TARGETS=


# -- Diagnostics and observer channels --
escape_control_text()
{
    ZSS_ESCAPE_VALUE=$1
    export ZSS_ESCAPE_VALUE
    awk 'BEGIN {
        value = ENVIRON["ZSS_ESCAPE_VALUE"]
        for (i = 1; i < 32; i++) control[sprintf("%c", i)] = sprintf("\\u%04x", i)
        control[sprintf("%c", 127)] = "\\u007f"
        for (i = 1; i <= length(value); i++) {
            c = substr(value, i, 1)
            if (c in control) printf "%s", control[c]
            else printf "%s", c
        }
    }'
    unset ZSS_ESCAPE_VALUE
}

print_error()
{
    printf '%s: %s\n' "$(escape_control_text "$PROGRAM_NAME")" "$(escape_control_text "$*")" >&2
}

print_info()
{
    printf '%s\n' "$(escape_control_text "$*")"
}

# -- Runtime safeguards and lifecycle --
runtime_sanitize_path()
{
    [ "$RUNTIME_PATH_READY" -eq 0 ] || return 0
    runtime_path_input=${ZSTD_SPLITTER_PATH-${PATH-}}
    [ -n "$runtime_path_input" ] || runtime_path_input=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
    runtime_path_output=
    runtime_old_ifs=$IFS
    IFS=:
    set -f
    for runtime_path_entry in $runtime_path_input
    do
        case $runtime_path_entry in
            /*)
                if [ -z "$runtime_path_output" ]; then
                    runtime_path_output=$runtime_path_entry
                else
                    runtime_path_output=$runtime_path_output:$runtime_path_entry
                fi
                ;;
            '') : ;; # Empty entries mean the current directory and are dropped.
            *) print_error "ignoring unsafe relative PATH entry: $runtime_path_entry" ;;
        esac
    done
    set +f
    IFS=$runtime_old_ifs
    [ -n "$runtime_path_output" ] || runtime_path_output=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
    PATH=$runtime_path_output
    export PATH
    RUNTIME_PATH_READY=1
}

contains_control_characters()
{
    control_newline='
'
    control_tab='	'
    control_cr=$(printf '\r')
    case $1 in
        *"$control_newline"*|*"$control_tab"*|*"$control_cr"*) return 0 ;;
    esac
    printf '%s' "$1" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1
}

absolute_existing_path()
{
    absolute_input=$1
    contains_control_characters "$absolute_input" && return 1
    case $absolute_input in /*) ;; *) absolute_input=$(pwd -P)/$absolute_input ;; esac
    absolute_dir=$(dirname "$absolute_input")
    absolute_base=$(basename "$absolute_input")
    absolute_dir=$(cd "$absolute_dir" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "${absolute_dir%/}" "$absolute_base"
}

absolute_destination_path()
{
    destination_input=$1
    contains_control_characters "$destination_input" && return 1
    [ -n "$destination_input" ] || return 1
    case $destination_input in /*) ;; *) destination_input=$(pwd -P)/$destination_input ;; esac
    destination_parent=$(dirname "$destination_input")
    destination_base=$(basename "$destination_input")
    case $destination_base in ''|.|..) return 1 ;; esac
    case "/$destination_input/" in */../*|*/./*) return 1 ;; esac
    mkdir -p "$destination_parent" || return 1
    destination_parent=$(cd "$destination_parent" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "${destination_parent%/}" "$destination_base"
}

unsafe_destructive_path()
{
    destructive_path=$1
    case $destructive_path in ''|/|//|///|.|..) return 0 ;; esac
    case "/$destructive_path/" in */../*|*/./*) return 0 ;; esac
    if [ -d "$destructive_path" ] && [ ! -L "$destructive_path" ]; then
        destructive_real=$(cd "$destructive_path" 2>/dev/null && pwd -P) || return 0
        [ "$destructive_real" = / ] && return 0
    fi
    return 1
}

safe_remove_tree()
{
    remove_path=$1
    [ -e "$remove_path" ] || [ -L "$remove_path" ] || return 0
    if unsafe_destructive_path "$remove_path"; then
        print_error "refusing unsafe recursive removal: $remove_path"
        return 1
    fi
    rm -rf "$remove_path"
}

secure_tmp_parent()
{
    # Ambient TMPDIR is intentionally ignored: privileged wrappers and service
    # managers may inherit it from an untrusted caller. Administrators may set
    # the explicit trusted override ZSTD_SPLITTER_TMPDIR.
    secure_parent=${ZSTD_SPLITTER_TMPDIR:-/tmp}
    case $secure_parent in /*) ;; *) secure_parent=/tmp ;; esac
    [ ! -L "$secure_parent" ] && [ -d "$secure_parent" ] && [ -w "$secure_parent" ] || secure_parent=/tmp
    (cd "$secure_parent" 2>/dev/null && pwd -P)
}

register_child_pid()
{
    case ${1-} in ''|*[!0-9]*) return 0 ;; esac
    case " $CHILD_PIDS " in *" $1 "*) return 0 ;; esac
    CHILD_PIDS="$CHILD_PIDS $1"
}

unregister_child_pid()
{
    unregister_target=${1-}
    unregister_new=
    unregister_old_ifs=$IFS
    IFS=' '
    for unregister_pid in $CHILD_PIDS
    do
        [ "$unregister_pid" = "$unregister_target" ] || unregister_new="$unregister_new $unregister_pid"
    done
    IFS=$unregister_old_ifs
    CHILD_PIDS=$unregister_new
}


terminate_children()
{
    child_old_ifs=$IFS
    IFS=' '
    for child_pid in $CHILD_PIDS "$TAR_PID" "$COMPRESS_PID" "$SPLIT_PID" "$EXTRACT_PID" ${PROGRESS_PID-}
    do
        case $child_pid in ''|*[!0-9]*) continue ;; esac
        kill "$child_pid" 2>/dev/null || :
    done
    for child_pid in $CHILD_PIDS "$TAR_PID" "$COMPRESS_PID" "$SPLIT_PID" "$EXTRACT_PID" ${PROGRESS_PID-}
    do
        case $child_pid in ''|*[!0-9]*) continue ;; esac
        wait "$child_pid" 2>/dev/null || :
    done
    IFS=$child_old_ifs
    CHILD_PIDS=
}

source_type_walk()
{
    type_path=$1
    if contains_control_characters "$type_path"; then
        print_error "refusing filesystem path containing a control character: $type_path"
        return 1
    fi
    if [ -L "$type_path" ]; then
        type_link_target=$(readlink "$type_path") || return 1
        if contains_control_characters "$type_link_target"; then
            print_error "refusing symbolic-link target containing a control character: $type_path"
            return 1
        fi
        return 0
    fi
    if [ -f "$type_path" ]; then return 0; fi
    if [ -d "$type_path" ]; then
        for type_child in "$type_path"/* "$type_path"/.[!.]* "$type_path"/..?*
        do
            [ -e "$type_child" ] || [ -L "$type_child" ] || continue
            (source_type_walk "$type_child") || return 1
        done
        return 0
    fi
    print_error "refusing unsupported special filesystem object: $type_path"
    return 1
}

validate_tar_member_list()
{
    member_list=$1
    awk '
        function bad_component(path, n,a,i) {
            n=split(path,a,"/")
            for (i=1;i<=n;i++) if (a[i] == "..") return 1
            return 0
        }
        {
            name=$0
            if (name == "") next
            if (name ~ /^\// || bad_component(name)) {
                print "unsafe archive member: " name > "/dev/stderr"
                exit 1
            }
            if (name ~ /[[:cntrl:]]/) {
                print "archive member contains a control character" > "/dev/stderr"
                exit 1
            }
        }
    ' "$member_list"
}

validate_archive_members()
{
    member_archive=$1
    member_engine=$2
    member_fifo=$WORK_DIR/member-list.pipe
    member_file=$WORK_DIR/member-list.txt
    rm -f "$member_fifo" "$member_file"
    mkfifo "$member_fifo" || return 1
    start_decompressor "$member_engine" "$member_archive" "$member_fifo"
    member_compress_pid=$COMPRESS_PID
    register_child_pid "$member_compress_pid"
    tar -tf "$member_fifo" >"$member_file" &
    member_tar_pid=$!
    register_child_pid "$member_tar_pid"
    member_status=0
    wait "$member_compress_pid" || member_status=1
    unregister_child_pid "$member_compress_pid"
    COMPRESS_PID=
    wait "$member_tar_pid" || member_status=1
    unregister_child_pid "$member_tar_pid"
    rm -f "$member_fifo"
    [ "$member_status" -eq 0 ] || {
        print_error "cannot safely list archive members before extraction"
        return 1
    }
    validate_tar_member_list "$member_file" || {
        print_error "archive member safety validation failed"
        return 1
    }
}

validate_remote_target()
{
    remote_target_value=$1
    [ -n "$remote_target_value" ] || return 1
    contains_control_characters "$remote_target_value" && return 1
    case $remote_target_value in
        -*|*[!A-Za-z0-9._@%+:\[\],-]*) return 1 ;;
    esac
    case ${remote_target_value#*@} in *@*) return 1 ;; esac
    return 0
}

validate_jump_spec()
{
    jump_value=$1
    [ -z "$jump_value" ] && return 0
    [ "$jump_value" = none ] && return 0
    jump_old_ifs=$IFS
    IFS=,
    set -f
    for jump_hop in $jump_value
    do
        validate_remote_target "$jump_hop" || { set +f; IFS=$jump_old_ifs; return 1; }
    done
    set +f
    IFS=$jump_old_ifs
    return 0
}

validate_remote_path()
{
    remote_path_value=$1
    case $remote_path_value in /*) ;; *) return 1 ;; esac
    contains_control_characters "$remote_path_value" && return 1
    case "/$remote_path_value/" in */../*|*/./*) return 1 ;; esac
    return 0
}

validate_remote_extract_path()
{
    remote_extract_value=$1
    [ -z "$remote_extract_value" ] && return 0
    [ "$remote_extract_value" = auto ] && return 0
    validate_remote_path "$remote_extract_value" || return 1
    case $remote_extract_value in /|//|///) return 1 ;; esac
    return 0
}

validate_plain_option_text()
{
    contains_control_characters "$1" && return 1
    return 0
}

publish_staged_files()
{
    publish_stage=$1
    publish_destination=$2
    [ -d "$publish_stage" ] || return 1
    [ -d "$publish_destination" ] && [ ! -L "$publish_destination" ] || return 1

    publish_collision=0
    for publish_file in "$publish_stage"/* "$publish_stage"/.[!.]* "$publish_stage"/..?*
    do
        [ -e "$publish_file" ] || [ -L "$publish_file" ] || continue
        publish_final=$publish_destination/${publish_file##*/}
        if [ -e "$publish_final" ] || [ -L "$publish_final" ]; then publish_collision=1; fi
    done
    if [ "$publish_collision" -eq 1 ]; then
        confirm_replace "Destination files already exist. Replace them transactionally?" || return 1
    fi

    publish_backup=$publish_destination/.zstd-splitter-backup.$$
    publish_index=0
    while ! mkdir "$publish_backup" 2>/dev/null; do
        publish_index=$((publish_index + 1))
        [ "$publish_index" -le 100 ] || return 1
        publish_backup=$publish_destination/.zstd-splitter-backup.$$.$publish_index
    done
    chmod 700 "$publish_backup" 2>/dev/null || :
    publish_moved_list=$publish_backup/.moved
    publish_new_list=$publish_backup/.new
    : >"$publish_moved_list"; : >"$publish_new_list"

    publish_rollback()
    {
        while IFS= read -r rollback_name
        do
            [ -n "$rollback_name" ] || continue
            rm -f "$publish_destination/$rollback_name" 2>/dev/null || :
        done <"$publish_new_list"
        while IFS= read -r rollback_name
        do
            [ -n "$rollback_name" ] || continue
            if [ -e "$publish_backup/$rollback_name" ] || [ -L "$publish_backup/$rollback_name" ]; then
                mv "$publish_backup/$rollback_name" "$publish_destination/$rollback_name" 2>/dev/null || :
            fi
        done <"$publish_moved_list"
    }

    for publish_file in "$publish_stage"/* "$publish_stage"/.[!.]* "$publish_stage"/..?*
    do
        [ -e "$publish_file" ] || [ -L "$publish_file" ] || continue
        publish_name=${publish_file##*/}
        contains_control_characters "$publish_name" && { publish_rollback; safe_remove_tree "$publish_backup" || :; return 1; }
        publish_final=$publish_destination/$publish_name
        if [ -e "$publish_final" ] || [ -L "$publish_final" ]; then
            mv "$publish_final" "$publish_backup/$publish_name" || {
                publish_rollback; safe_remove_tree "$publish_backup" || :; return 1;
            }
            printf '%s\n' "$publish_name" >>"$publish_moved_list"
        fi
        if ! mv "$publish_file" "$publish_final"; then
            publish_rollback
            safe_remove_tree "$publish_backup" || :
            return 1
        fi
        printf '%s\n' "$publish_name" >>"$publish_new_list"
    done
    safe_remove_tree "$publish_backup" || return 1
    safe_remove_tree "$publish_stage" || :
}

publish_generated_set()
{
    generated_prefix=$1
    final_prefix=$2
    generated_manifest=$3
    final_manifest=$4
    generated_strict=$5
    generated_dir=$(dirname "$final_prefix")
    generated_backup=$generated_dir/.zstd-splitter-publish.$$
    generated_index=0
    while ! mkdir "$generated_backup" 2>/dev/null; do
        generated_index=$((generated_index + 1))
        [ "$generated_index" -le 100 ] || return 1
        generated_backup=$generated_dir/.zstd-splitter-publish.$$.$generated_index
    done
    chmod 700 "$generated_backup" 2>/dev/null || :
    generated_old=$generated_backup/.old
    generated_new=$generated_backup/.new
    : >"$generated_old"; : >"$generated_new"

    for generated_existing in "$final_prefix"??????
    do
        [ -e "$generated_existing" ] || [ -L "$generated_existing" ] || continue
        generated_suffix=${generated_existing#"$final_prefix"}
        case $generated_suffix in
            [a-z][a-z][a-z][a-z][a-z][a-z])
                generated_name=${generated_existing##*/}
                mv "$generated_existing" "$generated_backup/$generated_name" || { safe_remove_tree "$generated_backup" || :; return 1; }
                printf '%s\n' "$generated_name" >>"$generated_old"
                ;;
        esac
    done
    if [ "$generated_strict" -eq 1 ] && { [ -e "$final_manifest" ] || [ -L "$final_manifest" ]; }; then
        generated_name=${final_manifest##*/}
        mv "$final_manifest" "$generated_backup/$generated_name" || { safe_remove_tree "$generated_backup" || :; return 1; }
        printf '%s\n' "$generated_name" >>"$generated_old"
    fi

    generated_rollback()
    {
        while IFS= read -r generated_name
        do
            [ -n "$generated_name" ] || continue
            rm -f "$generated_dir/$generated_name" 2>/dev/null || :
        done <"$generated_new"
        while IFS= read -r generated_name
        do
            [ -n "$generated_name" ] || continue
            if [ -e "$generated_backup/$generated_name" ] || [ -L "$generated_backup/$generated_name" ]; then
                mv "$generated_backup/$generated_name" "$generated_dir/$generated_name" 2>/dev/null || :
            fi
        done <"$generated_old"
    }

    PUBLISHED_PARTS=0
    for generated_part in "$generated_prefix"??????
    do
        [ -f "$generated_part" ] || continue
        generated_suffix=${generated_part#"$generated_prefix"}
        case $generated_suffix in [a-z][a-z][a-z][a-z][a-z][a-z]) ;; *) continue ;; esac
        generated_final=$final_prefix$generated_suffix
        generated_name=${generated_final##*/}
        if ! mv "$generated_part" "$generated_final"; then
            generated_rollback; safe_remove_tree "$generated_backup" || :; return 1
        fi
        printf '%s\n' "$generated_name" >>"$generated_new"
        PUBLISHED_PARTS=$((PUBLISHED_PARTS + 1))
    done
    if [ "$generated_strict" -eq 1 ]; then
        generated_name=${final_manifest##*/}
        if ! mv "$generated_manifest" "$final_manifest"; then
            generated_rollback; safe_remove_tree "$generated_backup" || :; return 1
        fi
        printf '%s\n' "$generated_name" >>"$generated_new"
    fi
    safe_remove_tree "$generated_backup" || return 1
    [ "$PUBLISHED_PARTS" -gt 0 ]
}

list_engines()
{
    cat <<'EOF_ENGINES'
Supported compression engines:
  zstd   .tar.zst   command: zstd   levels: 1-22   threads: yes
  gzip   .tar.gz    command: gzip   levels: 1-9    threads: no
  bzip2  .tar.bz2   command: bzip2  levels: 1-9    threads: no
  xz     .tar.xz    command: xz     levels: 0-9    threads: yes
  lzma   .tar.lzma  command: xz     levels: 0-9    threads: yes
  lzip   .tar.lz    command: lzip   levels: 0-9    threads: no
  lzop   .tar.lzo   command: lzop   levels: 1-9    threads: no
  lz4    .tar.lz4   command: lz4    levels: 1-12   threads: no

Aliases accepted by -e:
  zst -> zstd, gz -> gzip, bz2 -> bzip2, lzo -> lzop

An engine is usable only when its external command is installed.
EOF_ENGINES
}

usage()
{
    cat <<EOF_USAGE
Usage:
  $PROGRAM_NAME -c -s SIZE [-e ENGINE] [-l LEVEL] [-T THREADS] [-i] [-f]
                [-R DESTINATION] [-O NAME=VALUE] SOURCE
  $PROGRAM_NAME -j [-i] [-m MANIFEST] [-f] PART
  $PROGRAM_NAME -x [-i] [-m MANIFEST] [-d DIRECTORY] [-f] INPUT
  $PROGRAM_NAME -v [-i] [-m MANIFEST] INPUT
  $PROGRAM_NAME -P -i -R DESTINATION [-O NAME=VALUE] INPUT
  $PROGRAM_NAME -G -i -R REMOTE_INPUT [-d DIRECTORY] [-O NAME=VALUE]
  $PROGRAM_NAME -Q MODE [-R DESTINATION] [-O NAME=VALUE]
  $PROGRAM_NAME -E | -h

Actions:
  -c  create, compress, and split a tar stream
  -j  join parts and verify the reconstructed archive
  -x  extract an archive or verified part set
  -v  verify without extracting
  -P  push a strict archive set through SSH/SFTP
  -G  pull and verify a remote archive set
  -Q  query network or config
  -E  list compression engines

Core options:
  -e ENGINE    compression engine; default: zstd
  -s SIZE      maximum part size; required with -c
  -l LEVEL     engine-specific compression level
  -T THREADS   zstd/xz/lzma workers; default: 0
  -i            strict SHA-256 manifest processing
  -m MANIFEST   explicit manifest
  -d DIRECTORY  extraction or pull destination
  -f            permit replacement; required for destructive maintenance
  -R SPEC       [USER@]HOST:/absolute/path
  -O NAME=VALUE network option; repeatable
  -F FILE       network option file
  -h            display help
  --            end option processing

Network scope:
  Transactional single-destination push/pull, staging, verification,
  locking, optional remote extraction, and atomic publication.
  This feature release uses the GNU-oriented dependency profile; the
  matching .1 maintenance release adds macOS/BSD abstractions.

Safety rule:
  stdout is reserved for ordinary command output; diagnostics use stderr.

Runtime environment:
  ZSTD_SPLITTER_PATH    trusted absolute command-search path
  ZSTD_SPLITTER_TMPDIR  trusted absolute parent for private state

See the installed man page and package docs/INDEX.md for full contracts.
EOF_USAGE
}

cleanup()
{
    cleanup_status=$?
    trap - 0 1 2 3 15

    terminate_children
    network_abort_active_stage
    network_close_control_masters

    # If publication of an extracted tree was interrupted after the previous
    # destination had been moved aside, restore that previous tree.
    if [ -n "$EXTRACTION_BACKUP" ] && { [ -e "$EXTRACTION_BACKUP" ] || [ -L "$EXTRACTION_BACKUP" ]; }; then
        if [ -n "$EXTRACTION_DESTINATION" ] && { [ -e "$EXTRACTION_DESTINATION" ] || [ -L "$EXTRACTION_DESTINATION" ]; }; then
            safe_remove_tree "$EXTRACTION_DESTINATION" || :
        fi
        [ -z "$EXTRACTION_DESTINATION" ] || mv "$EXTRACTION_BACKUP" "$EXTRACTION_DESTINATION" 2>/dev/null || :
        EXTRACTION_BACKUP=
    fi
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then safe_remove_tree "$WORK_DIR" || :; fi
    if [ -n "$NETWORK_TEMP_DIR" ] && [ -d "$NETWORK_TEMP_DIR" ]; then safe_remove_tree "$NETWORK_TEMP_DIR" || :; fi
    return "$cleanup_status"
}

handle_signal()
{
    signal_name=$1
    signal_status=$2
    print_error "operation interrupted by $signal_name"
    exit "$signal_status"
}

trap cleanup 0
trap 'handle_signal HUP 129' 1
trap 'handle_signal INT 130' 2
trap 'handle_signal QUIT 131' 3
trap 'handle_signal TERM 143' 15

require_command()
{
    if ! command -v "$1" >/dev/null 2>&1; then
        print_error "required command not found: $1"
        return 1
    fi
}

require_base_commands()
{
    for required_command in tar split cat mkdir rm mv dirname basename mkfifo awk wc tr
    do
        require_command "$required_command" || return 1
    done
}

require_integrity_commands()
{
    for required_command in sha256sum cmp readlink
    do
        require_command "$required_command" || return 1
    done
}

# -- Compression and metadata backends --
normalize_engine()
{
    case $1 in
        zstd|zst) printf '%s\n' zstd ;;
        gzip|gz) printf '%s\n' gzip ;;
        bzip2|bz2) printf '%s\n' bzip2 ;;
        xz) printf '%s\n' xz ;;
        lzma) printf '%s\n' lzma ;;
        lzip) printf '%s\n' lzip ;;
        lzop|lzo) printf '%s\n' lzop ;;
        lz4) printf '%s\n' lz4 ;;
        *) return 1 ;;
    esac
}

engine_extension()
{
    case $1 in
        zstd) printf '%s\n' zst ;;
        gzip) printf '%s\n' gz ;;
        bzip2) printf '%s\n' bz2 ;;
        xz) printf '%s\n' xz ;;
        lzma) printf '%s\n' lzma ;;
        lzip) printf '%s\n' lz ;;
        lzop) printf '%s\n' lzo ;;
        lz4) printf '%s\n' lz4 ;;
        *) return 1 ;;
    esac
}

engine_command()
{
    case $1 in
        zstd) printf '%s\n' zstd ;;
        gzip) printf '%s\n' gzip ;;
        bzip2) printf '%s\n' bzip2 ;;
        xz|lzma) printf '%s\n' xz ;;
        lzip) printf '%s\n' lzip ;;
        lzop) printf '%s\n' lzop ;;
        lz4) printf '%s\n' lz4 ;;
        *) return 1 ;;
    esac
}

engine_default_level()
{
    case $1 in
        zstd) printf '%s\n' 3 ;;
        gzip) printf '%s\n' 6 ;;
        bzip2) printf '%s\n' 9 ;;
        xz|lzma) printf '%s\n' 6 ;;
        lzip) printf '%s\n' 6 ;;
        lzop) printf '%s\n' 3 ;;
        lz4) printf '%s\n' 1 ;;
        *) return 1 ;;
    esac
}

engine_supports_threads()
{
    case $1 in
        zstd|xz|lzma) return 0 ;;
        *) return 1 ;;
    esac
}

validate_integer_range()
{
    integer_value=$1
    integer_min=$2
    integer_max=$3

    case $integer_value in
        ''|*[!0-9]*) return 1 ;;
    esac

    [ "$integer_value" -ge "$integer_min" ] && \
        [ "$integer_value" -le "$integer_max" ]
}

validate_engine_level()
{
    level_engine=$1
    level_value=$2

    case $level_engine in
        zstd) validate_integer_range "$level_value" 1 22 ;;
        gzip|bzip2|lzop) validate_integer_range "$level_value" 1 9 ;;
        xz|lzma|lzip) validate_integer_range "$level_value" 0 9 ;;
        lz4) validate_integer_range "$level_value" 1 12 ;;
        *) return 1 ;;
    esac
}

validate_nonnegative_integer()
{
    case $1 in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

require_engine()
{
    compressor_command=$(engine_command "$1") || return 1
    require_command "$compressor_command"
}

make_work_dir()
{
    work_parent=$1
    work_parent=$(cd "$work_parent" 2>/dev/null && pwd -P) || {
        print_error "cannot access temporary-directory parent: $work_parent"
        return 1
    }
    old_umask=$(umask)
    umask 077
    WORK_DIR=
    if command -v mktemp >/dev/null 2>&1; then
        WORK_DIR=$(mktemp -d "$work_parent/.tar-splitter.XXXXXX" 2>/dev/null || :)
    fi
    if [ -z "$WORK_DIR" ]; then
        work_index=0
        while [ "$work_index" -le 100 ]
        do
            WORK_DIR=$work_parent/.tar-splitter.$$.$work_index
            mkdir "$WORK_DIR" 2>/dev/null && break
            WORK_DIR=
            work_index=$((work_index + 1))
        done
    fi
    umask "$old_umask"
    [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] || {
        print_error "cannot create a private temporary working directory in: $work_parent"
        return 1
    }
    chmod 700 "$WORK_DIR" 2>/dev/null || :
}

confirm_replace()
{
    confirm_prompt=$1

    if [ "$FORCE" -eq 1 ]; then
        return 0
    fi

    if [ ! -t 0 ]; then
        print_error "$confirm_prompt Use -f to permit replacement."
        return 1
    fi

    printf '%s [y/N] ' "$confirm_prompt" >&2
    IFS= read -r confirm_answer || return 1

    case $confirm_answer in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

size_to_bytes()
{
    size_input=$1

    awk -v value="$size_input" '
        BEGIN {
            if (value !~ /^[1-9][0-9]*([KkMmGgTtPp]([iI]?[bB])?)?$/) {
                exit 1
            }
            number = value
            sub(/[KkMmGgTtPp].*$/, "", number)
            suffix = value
            sub(/^[0-9]+/, "", suffix)
            suffix = toupper(suffix)
            sub(/IB$/, "", suffix)
            sub(/B$/, "", suffix)
            multiplier = 1
            if (suffix == "K") multiplier = 1024
            else if (suffix == "M") multiplier = 1024 ^ 2
            else if (suffix == "G") multiplier = 1024 ^ 3
            else if (suffix == "T") multiplier = 1024 ^ 4
            else if (suffix == "P") multiplier = 1024 ^ 5
            else if (suffix != "") exit 1
            bytes = number * multiplier
            if (bytes < 1) exit 1
            printf "%.0f\n", bytes
        }
    '
}

file_size()
{
    wc -c <"$1" | awk '{print $1}'
}

sha256_file()
{
    sha256sum "$1" | awk '{print $1}'
}

sha256_stream()
{
    sha256sum | awk '{print $1}'
}

# -- Integrity manifest --
encode_manifest_text()
{
    ZSS_ENCODE_VALUE=$1
    export ZSS_ENCODE_VALUE
    awk 'BEGIN {
        value = ENVIRON["ZSS_ENCODE_VALUE"]
        gsub(/%/, "%25", value)
        gsub(/\t/, "%09", value)
        gsub(/\r/, "%0D", value)
        gsub(/\n/, "%0A", value)
        printf "%s", value
    }'
    unset ZSS_ENCODE_VALUE
}

# Recursively emits canonical directory/file/link records. Calls recurse in
# subshells so POSIX global variables cannot leak into sibling paths.
manifest_walk()
{
    walk_actual=$1
    walk_relative=$2
    walk_output=$3
    walk_encoded=$(encode_manifest_text "$walk_relative")

    if [ -L "$walk_actual" ]; then
        walk_hash=$(readlink "$walk_actual" | sha256_stream) || return 1
        walk_size=$(readlink "$walk_actual" | wc -c | awk '{print $1}') || return 1
        printf 'source\tL\t%s\t%s\t%s\n' \
            "$walk_hash" "$walk_size" "$walk_encoded" >>"$walk_output"
        return 0
    fi

    if [ -f "$walk_actual" ]; then
        walk_hash=$(sha256_file "$walk_actual") || return 1
        walk_size=$(file_size "$walk_actual") || return 1
        printf 'source\tF\t%s\t%s\t%s\n' \
            "$walk_hash" "$walk_size" "$walk_encoded" >>"$walk_output"
        return 0
    fi

    if [ -d "$walk_actual" ]; then
        printf 'source\tD\t-\t0\t%s\n' "$walk_encoded" >>"$walk_output"

        for walk_child in \
            "$walk_actual"/* \
            "$walk_actual"/.[!.]* \
            "$walk_actual"/..?*
        do
            if [ ! -e "$walk_child" ] && [ ! -L "$walk_child" ]; then
                continue
            fi
            walk_child_name=${walk_child##*/}
            ( manifest_walk "$walk_child" "$walk_relative/$walk_child_name" \
                "$walk_output" ) || return 1
        done
        return 0
    fi

    print_error "strict integrity does not support this filesystem object: $walk_actual"
    return 1
}

generate_source_records_for_source()
{
    record_source=$1
    record_root=$2
    record_output=$3
    : >"$record_output"
    manifest_walk "$record_source" "$record_root" "$record_output"
}

generate_source_records_for_directory_contents()
{
    record_directory=$1
    record_output=$2
    : >"$record_output"

    for record_child in \
        "$record_directory"/* \
        "$record_directory"/.[!.]* \
        "$record_directory"/..?*
    do
        if [ ! -e "$record_child" ] && [ ! -L "$record_child" ]; then
            continue
        fi
        record_name=${record_child##*/}
        manifest_walk "$record_child" "$record_name" "$record_output" || return 1
    done
}

manifest_value()
{
    manifest_key=$1
    manifest_path=$2
    awk -F '\t' -v key="$manifest_key" '$1 == key { print $2; exit }' "$manifest_path"
}

manifest_record_count()
{
    manifest_tag=$1
    manifest_path=$2
    awk -F '\t' -v tag="$manifest_tag" '$1 == tag { count++ } END { print count + 0 }' \
        "$manifest_path"
}

validate_sha256_text()
{
    printf '%s\n' "$1" | awk '
        length($0) != 64 { exit 1 }
        $0 !~ /^[0-9a-f]+$/ { exit 1 }
    '
}

# Validates the complete manifest schema before any record is trusted.
validate_manifest_structure()
{
    manifest_path=$1

    if [ ! -f "$manifest_path" ]; then
        print_error "strict-integrity manifest not found: $manifest_path"
        return 1
    fi

    manifest_header=$(awk 'NR == 1 { print; exit }' "$manifest_path")
    expected_manifest_header=$(printf 'zstd-splitter-manifest\t%s' "$MANIFEST_FORMAT")
    if [ "$manifest_header" != "$expected_manifest_header" ]; then
        print_error "unsupported or invalid manifest header: $manifest_path"
        return 1
    fi

    if ! awk -F '\t' '
        BEGIN {
            required["tool_version"]=1; required["engine"]=1; required["archive_name"]=1;
            required["archive_size"]=1; required["archive_sha256"]=1;
            required["source_root"]=1; required["source_entry_count"]=1;
            required["source_tree_sha256"]=1; required["part_count"]=1;
            required["part_size_bytes"]=1
        }
        $1 in required { count[$1]++ }
        $1 == "part" { if (seen_part[$2]++) bad=1 }
        $1 == "end" && $2 == "manifest" { end_count++ }
        END {
            for (key in required) if (count[key] != 1) bad=1
            if (end_count != 1) bad=1
            exit bad ? 1 : 0
        }
    ' "$manifest_path"; then
        print_error "manifest contains duplicate, missing, or ambiguous records"
        return 1
    fi

    manifest_engine=$(manifest_value engine "$manifest_path")
    manifest_archive_sha=$(manifest_value archive_sha256 "$manifest_path")
    manifest_source_sha=$(manifest_value source_tree_sha256 "$manifest_path")
    manifest_archive_size=$(manifest_value archive_size "$manifest_path")
    manifest_source_count=$(manifest_value source_entry_count "$manifest_path")
    manifest_part_count=$(manifest_value part_count "$manifest_path")

    if [ -z "$manifest_engine" ] || [ -z "$manifest_archive_sha" ] || \
       [ -z "$manifest_source_sha" ] || [ -z "$manifest_archive_size" ] || \
       [ -z "$manifest_source_count" ] || [ -z "$manifest_part_count" ]; then
        print_error "manifest is missing required fields: $manifest_path"
        return 1
    fi

    case $manifest_engine in
        zstd|gzip|bzip2|xz|lzma|lzip|lzop|lz4) ;;
        *) print_error "unsupported compression engine in manifest: $manifest_engine"; return 1 ;;
    esac

    validate_sha256_text "$manifest_archive_sha" || {
        print_error "invalid archive SHA-256 in manifest"
        return 1
    }
    validate_sha256_text "$manifest_source_sha" || {
        print_error "invalid source-tree SHA-256 in manifest"
        return 1
    }

    case $manifest_archive_size in ''|*[!0-9]*)
        print_error "invalid archive size in manifest"
        return 1
    esac
    case $manifest_source_count in ''|*[!0-9]*)
        print_error "invalid source entry count in manifest"
        return 1
    esac
    case $manifest_part_count in ''|*[!0-9]*|0)
        print_error "invalid part count in manifest"
        return 1
    esac

    manifest_source_records=$WORK_DIR/manifest-source-records
    manifest_part_records=$WORK_DIR/manifest-part-records
    awk -F '\t' '$1 == "source" { print }' "$manifest_path" >"$manifest_source_records"
    awk -F '\t' '$1 == "part" { print }' "$manifest_path" >"$manifest_part_records"

    actual_source_count=$(manifest_record_count source "$manifest_path")
    actual_part_count=$(manifest_record_count part "$manifest_path")
    actual_source_sha=$(sha256_file "$manifest_source_records")

    if [ "$actual_source_count" != "$manifest_source_count" ]; then
        print_error "source entry count does not match manifest records"
        return 1
    fi
    if [ "$actual_part_count" != "$manifest_part_count" ]; then
        print_error "part count does not match manifest records"
        return 1
    fi
    if [ "$actual_source_sha" != "$manifest_source_sha" ]; then
        print_error "source inventory records do not match their aggregate SHA-256"
        return 1
    fi

    awk -F '\t' '
        $1 == "part" {
            if ($2 !~ /^[a-z][a-z][a-z][a-z][a-z][a-z]$/) exit 1
            if ($3 !~ /^[0-9]+$/) exit 1
            if (length($4) != 64 || $4 !~ /^[0-9a-f]+$/) exit 1
        }
    ' "$manifest_path" || {
        print_error "invalid part record in manifest"
        return 1
    }

    return 0
}

write_integrity_manifest()
{
    wim_output_manifest=$1
    wim_source_records=$2
    wim_source_root=$3
    wim_archive_file=$4
    wim_temporary_prefix=$5
    wim_part_count=$6
    wim_part_size_bytes=$7

    wim_source_entry_count=$(awk 'END { print NR + 0 }' "$wim_source_records")
    wim_source_tree_sha=$(sha256_file "$wim_source_records")
    wim_archive_sha=$(sha256_file "$wim_archive_file")
    wim_archive_size=$(file_size "$wim_archive_file")
    wim_archive_name_encoded=$(encode_manifest_text "${wim_archive_file##*/}")
    wim_source_root_encoded=$(encode_manifest_text "$wim_source_root")

    {
        printf 'zstd-splitter-manifest\t%s\n' "$MANIFEST_FORMAT"
        printf 'tool_version\t%s\n' "$PROGRAM_VERSION"
        printf 'engine\t%s\n' "$ENGINE"
        printf 'archive_name\t%s\n' "$wim_archive_name_encoded"
        printf 'archive_size\t%s\n' "$wim_archive_size"
        printf 'archive_sha256\t%s\n' "$wim_archive_sha"
        printf 'source_root\t%s\n' "$wim_source_root_encoded"
        printf 'source_entry_count\t%s\n' "$wim_source_entry_count"
        printf 'source_tree_sha256\t%s\n' "$wim_source_tree_sha"
        printf 'part_count\t%s\n' "$wim_part_count"
        printf 'part_size_bytes\t%s\n' "$wim_part_size_bytes"
        cat "$wim_source_records"

        for wim_part in "$wim_temporary_prefix"??????
        do
            if [ ! -f "$wim_part" ]; then
                continue
            fi
            wim_suffix=${wim_part#"$wim_temporary_prefix"}
            wim_size=$(file_size "$wim_part")
            wim_sha=$(sha256_file "$wim_part")
            printf 'part\t%s\t%s\t%s\n' \
                "$wim_suffix" "$wim_size" "$wim_sha"
        done
        printf 'end\tmanifest\n'
    } >"$wim_output_manifest"
}

start_compressor()
{
    compressor_input=$1
    compressor_output=$2

    case $ENGINE in
        zstd) zstd -q -T"$THREADS" -"$COMPRESSION_LEVEL" -c \
            <"$compressor_input" >"$compressor_output" & ;;
        gzip) gzip -c -"$COMPRESSION_LEVEL" \
            <"$compressor_input" >"$compressor_output" & ;;
        bzip2) bzip2 -c -"$COMPRESSION_LEVEL" \
            <"$compressor_input" >"$compressor_output" & ;;
        xz) xz -c -"$COMPRESSION_LEVEL" -T"$THREADS" \
            <"$compressor_input" >"$compressor_output" & ;;
        lzma) xz --format=lzma -c -"$COMPRESSION_LEVEL" -T"$THREADS" \
            <"$compressor_input" >"$compressor_output" & ;;
        lzip) lzip -q -c -"$COMPRESSION_LEVEL" \
            <"$compressor_input" >"$compressor_output" & ;;
        lzop) lzop -q -c -"$COMPRESSION_LEVEL" \
            <"$compressor_input" >"$compressor_output" & ;;
        lz4) lz4 -q -z -c -"$COMPRESSION_LEVEL" \
            <"$compressor_input" >"$compressor_output" & ;;
        *) print_error "unsupported compression engine: $ENGINE"; return 1 ;;
    esac

    COMPRESS_PID=$!
}

start_decompressor()
{
    decompressor_engine=$1
    decompressor_input=$2
    decompressor_output=$3

    case $decompressor_engine in
        zstd) zstd -q -d -c "$decompressor_input" >"$decompressor_output" & ;;
        gzip) gzip -d -c "$decompressor_input" >"$decompressor_output" & ;;
        bzip2) bzip2 -d -c "$decompressor_input" >"$decompressor_output" & ;;
        xz) xz -d -c "$decompressor_input" >"$decompressor_output" & ;;
        lzma) xz --format=lzma -d -c "$decompressor_input" >"$decompressor_output" & ;;
        lzip) lzip -q -d -c "$decompressor_input" >"$decompressor_output" & ;;
        lzop) lzop -q -d -c "$decompressor_input" >"$decompressor_output" & ;;
        lz4) lz4 -q -d -c "$decompressor_input" >"$decompressor_output" & ;;
        *) print_error "unsupported compression engine: $decompressor_engine"; return 1 ;;
    esac

    COMPRESS_PID=$!
}

verify_archive_native()
{
    verify_engine=$1
    verify_file=$2

    case $verify_engine in
        zstd) zstd -q -t "$verify_file" ;;
        gzip) gzip -t "$verify_file" ;;
        bzip2) bzip2 -t "$verify_file" ;;
        xz) xz -t "$verify_file" ;;
        lzma) xz --format=lzma -t "$verify_file" ;;
        lzip) lzip -q -t "$verify_file" ;;
        lzop) lzop -q -t "$verify_file" ;;
        lz4) lz4 -q -t "$verify_file" ;;
        *) return 1 ;;
    esac
}

detect_engine_from_part()
{
    case $1 in
        *.tar.zst.part.[a-z][a-z][a-z][a-z][a-z][a-z]) printf '%s\n' zstd ;;
        *.tar.gz.part.[a-z][a-z][a-z][a-z][a-z][a-z]) printf '%s\n' gzip ;;
        *.tar.bz2.part.[a-z][a-z][a-z][a-z][a-z][a-z]) printf '%s\n' bzip2 ;;
        *.tar.xz.part.[a-z][a-z][a-z][a-z][a-z][a-z]) printf '%s\n' xz ;;
        *.tar.lzma.part.[a-z][a-z][a-z][a-z][a-z][a-z]) printf '%s\n' lzma ;;
        *.tar.lz.part.[a-z][a-z][a-z][a-z][a-z][a-z]) printf '%s\n' lzip ;;
        *.tar.lzo.part.[a-z][a-z][a-z][a-z][a-z][a-z]) printf '%s\n' lzop ;;
        *.tar.lz4.part.[a-z][a-z][a-z][a-z][a-z][a-z]) printf '%s\n' lz4 ;;
        *) return 1 ;;
    esac
}

detect_engine_from_archive()
{
    case $1 in
        *.tar.zst) printf '%s\n' zstd ;;
        *.tar.gz) printf '%s\n' gzip ;;
        *.tar.bz2) printf '%s\n' bzip2 ;;
        *.tar.xz) printf '%s\n' xz ;;
        *.tar.lzma) printf '%s\n' lzma ;;
        *.tar.lz) printf '%s\n' lzip ;;
        *.tar.lzo) printf '%s\n' lzop ;;
        *.tar.lz4) printf '%s\n' lz4 ;;
        *) return 1 ;;
    esac
}

archive_base_without_extension()
{
    case $1 in
        *.tar.zst) printf '%s\n' "${1%.tar.zst}" ;;
        *.tar.gz) printf '%s\n' "${1%.tar.gz}" ;;
        *.tar.bz2) printf '%s\n' "${1%.tar.bz2}" ;;
        *.tar.xz) printf '%s\n' "${1%.tar.xz}" ;;
        *.tar.lzma) printf '%s\n' "${1%.tar.lzma}" ;;
        *.tar.lz) printf '%s\n' "${1%.tar.lz}" ;;
        *.tar.lzo) printf '%s\n' "${1%.tar.lzo}" ;;
        *.tar.lz4) printf '%s\n' "${1%.tar.lz4}" ;;
        *) return 1 ;;
    esac
}

infer_manifest_for_archive()
{
    printf '%s.manifest.sha256\n' "$1"
}

infer_manifest_for_part()
{
    infer_prefix=${1%??????}
    infer_archive=${infer_prefix%.part.}
    infer_manifest_for_archive "$infer_archive"
}

resolve_manifest()
{
    resolve_input=$1
    resolve_kind=$2

    if [ -n "$MANIFEST_FILE" ]; then
        printf '%s\n' "$MANIFEST_FILE"
    elif [ "$resolve_kind" = part ]; then
        infer_manifest_for_part "$resolve_input"
    else
        infer_manifest_for_archive "$resolve_input"
    fi
}

validate_manifest_archive_identity()
{
    identity_manifest=$1
    identity_archive=$2
    identity_engine=$3

    manifest_engine=$(manifest_value engine "$identity_manifest")
    manifest_archive_name=$(manifest_value archive_name "$identity_manifest")
    actual_archive_name=$(encode_manifest_text "${identity_archive##*/}")

    if [ "$manifest_engine" != "$identity_engine" ]; then
        print_error "manifest engine mismatch: expected $identity_engine, found $manifest_engine"
        return 1
    fi
    if [ "$manifest_archive_name" != "$actual_archive_name" ]; then
        print_error "manifest archive name does not match: $identity_archive"
        return 1
    fi
}

validate_archive_against_manifest()
{
    archive_path=$1
    archive_engine=$2
    archive_manifest=$3

    validate_manifest_structure "$archive_manifest" || return 1
    validate_manifest_archive_identity "$archive_manifest" "$archive_path" \
        "$archive_engine" || return 1

    expected_archive_size=$(manifest_value archive_size "$archive_manifest")
    expected_archive_sha=$(manifest_value archive_sha256 "$archive_manifest")
    actual_archive_size=$(file_size "$archive_path")
    actual_archive_sha=$(sha256_file "$archive_path")

    if [ "$actual_archive_size" != "$expected_archive_size" ]; then
        print_error "compressed archive size mismatch"
        return 1
    fi
    if [ "$actual_archive_sha" != "$expected_archive_sha" ]; then
        print_error "compressed archive SHA-256 mismatch"
        return 1
    fi

    print_info "Strict archive SHA-256 verified: $actual_archive_sha"
}

validate_parts_against_manifest()
{
    selected_part=$1
    parts_manifest=$2
    input_prefix=${selected_part%??????}

    validate_manifest_structure "$parts_manifest" || return 1

    expected_part_count=$(manifest_value part_count "$parts_manifest")
    actual_part_count=0
    for actual_part in "$input_prefix"??????
    do
        if [ ! -f "$actual_part" ]; then
            continue
        fi
        actual_suffix=${actual_part#"$input_prefix"}
        case $actual_suffix in
            [a-z][a-z][a-z][a-z][a-z][a-z]) actual_part_count=$((actual_part_count + 1)) ;;
        esac
    done

    if [ "$actual_part_count" != "$expected_part_count" ]; then
        print_error "part count mismatch: expected $expected_part_count, found $actual_part_count"
        return 1
    fi

    part_records=$WORK_DIR/part-records
    awk -F '\t' '$1 == "part" { print }' "$parts_manifest" >"$part_records"

    while IFS="$(printf '\t')" read -r part_tag part_suffix expected_size expected_sha
    do
        [ "$part_tag" = part ] || continue
        part_path=$input_prefix$part_suffix
        if [ ! -f "$part_path" ]; then
            print_error "manifest part is missing: $part_path"
            return 1
        fi
        actual_size=$(file_size "$part_path")
        if [ "$actual_size" != "$expected_size" ]; then
            print_error "part size mismatch: $part_path"
            return 1
        fi
        actual_sha=$(sha256_file "$part_path")
        if [ "$actual_sha" != "$expected_sha" ]; then
            print_error "part SHA-256 mismatch: $part_path"
            return 1
        fi
    done <"$part_records"

    print_info "Strict SHA-256 verification passed for $expected_part_count parts."
}

concatenate_parts()
{
    selected_part=$1
    output_archive=$2
    parts_manifest=${3-}
    input_prefix=${selected_part%??????}
    : >"$output_archive"

    if [ -n "$parts_manifest" ]; then
        part_records=$WORK_DIR/part-records
        awk -F '\t' '$1 == "part" { print }' "$parts_manifest" >"$part_records"
        joined_count=0
        while IFS="$(printf '\t')" read -r part_tag part_suffix expected_size expected_sha
        do
            [ "$part_tag" = part ] || continue
            cat "$input_prefix$part_suffix" >>"$output_archive"
            joined_count=$((joined_count + 1))
        done <"$part_records"
    else
        joined_count=0
        for archive_part in "$input_prefix"??????
        do
            if [ ! -f "$archive_part" ]; then
                continue
            fi
            suffix=${archive_part#"$input_prefix"}
            case $suffix in
                [a-z][a-z][a-z][a-z][a-z][a-z])
                    cat "$archive_part" >>"$output_archive"
                    joined_count=$((joined_count + 1))
                    ;;
            esac
        done
    fi

    if [ "$joined_count" -eq 0 ]; then
        print_error "no matching archive parts were found"
        return 1
    fi

    print_info "Joined parts: $joined_count"
}

# Creates the tar+codec stream, splits it, and publishes outputs only after
# all child processes and strict source stability checks succeed.
# -- Local archive workflows --
compress_and_split()
{
    source_path=$1

    if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]; then
        print_error "source does not exist: $source_path"
        return 1
    fi

    while [ "$source_path" != / ] && [ "${source_path%/}" != "$source_path" ]
    do
        source_path=${source_path%/}
    done

    if [ "$source_path" = / ]; then
        print_error "archiving the filesystem root directly is refused"
        return 1
    fi

    if ! part_size_bytes=$(size_to_bytes "$PART_SIZE"); then
        print_error "invalid part size: $PART_SIZE"
        print_error "use a positive byte count or a value such as 100M or 2GiB"
        return 2
    fi

    source_dir_input=$(dirname "$source_path")
    source_name=$(basename "$source_path")
    source_dir=$(cd "$source_dir_input" 2>/dev/null && pwd -P) || {
        print_error "cannot access source directory: $source_dir_input"
        return 1
    }

    if [ "$source_name" = . ] || [ "$source_name" = .. ]; then
        canonical_source=$(cd "$source_path" 2>/dev/null && pwd -P) || {
            print_error "cannot resolve source: $source_path"
            return 1
        }
        source_dir=$(dirname "$canonical_source")
        source_name=$(basename "$canonical_source")
    fi

    source_actual=$source_dir/$source_name
    source_type_walk "$source_actual" || return 1
    archive_extension=$(engine_extension "$ENGINE")
    archive_file=$source_dir/$source_name.tar.$archive_extension
    output_prefix=$archive_file.part.
    output_manifest=$archive_file.manifest.sha256

    existing_output=0
    for existing_part in "$output_prefix"??????
    do
        if [ -f "$existing_part" ]; then
            existing_output=1
            break
        fi
    done
    if [ "$STRICT_INTEGRITY" -eq 1 ] && [ -e "$output_manifest" ]; then
        existing_output=1
    fi

    if [ "$existing_output" -eq 1 ]; then
        if ! confirm_replace "Archive parts or manifest already exist. Replace them?"; then
            print_info "Operation cancelled."
            return 0
        fi
    fi

    make_work_dir "$source_dir"
    tar_pipe=$WORK_DIR/tar.pipe
    compressed_pipe=$WORK_DIR/compressed.pipe
    temporary_prefix=$WORK_DIR/part.
    temporary_archive=$WORK_DIR/$source_name.tar.$archive_extension
    source_records_before=$WORK_DIR/source-before.records
    source_records_after=$WORK_DIR/source-after.records
    temporary_manifest=$WORK_DIR/manifest.sha256

    mkfifo "$tar_pipe" "$compressed_pipe"

    if [ "$STRICT_INTEGRITY" -eq 1 ]; then
        print_info "Computing strict source SHA-256 inventory..."
        generate_source_records_for_source "$source_actual" "$source_name" \
            "$source_records_before" || return 1
        source_tree_sha=$(sha256_file "$source_records_before")
        print_info "Source tree SHA-256: $source_tree_sha"
    fi

    print_info "Source: $source_actual"
    print_info "Compression engine: $ENGINE"
    print_info "Compression level: $COMPRESSION_LEVEL"
    if engine_supports_threads "$ENGINE"; then
        print_info "Compression threads: $THREADS"
    fi
    print_info "Maximum part size: $PART_SIZE ($part_size_bytes bytes)"

    tar -C "$source_dir" -cf "$tar_pipe" "./$source_name" &
    TAR_PID=$!
    register_child_pid "$TAR_PID"
    start_compressor "$tar_pipe" "$compressed_pipe"
    register_child_pid "$COMPRESS_PID"
    split -a "$SUFFIX_LENGTH" -b "$part_size_bytes" \
        "$compressed_pipe" "$temporary_prefix" &
    SPLIT_PID=$!
    register_child_pid "$SPLIT_PID"

    pipeline_status=0
    if ! wait "$TAR_PID"; then pipeline_status=1; fi
    unregister_child_pid "$TAR_PID"
    TAR_PID=
    if ! wait "$COMPRESS_PID"; then pipeline_status=1; fi
    unregister_child_pid "$COMPRESS_PID"
    COMPRESS_PID=
    if ! wait "$SPLIT_PID"; then pipeline_status=1; fi
    unregister_child_pid "$SPLIT_PID"
    SPLIT_PID=

    if [ "$pipeline_status" -ne 0 ]; then
        print_error "archiving, compression, or splitting failed"
        return 1
    fi

    part_count=0
    for temporary_part in "$temporary_prefix"??????
    do
        [ -f "$temporary_part" ] || continue
        suffix=${temporary_part#"$temporary_prefix"}
        case $suffix in
            [a-z][a-z][a-z][a-z][a-z][a-z]) part_count=$((part_count + 1)) ;;
            *) print_error "unexpected split suffix: $suffix"; return 1 ;;
        esac
    done

    if [ "$part_count" -eq 0 ]; then
        print_error "no archive part was created"
        return 1
    fi

    : >"$temporary_archive"
    for temporary_part in "$temporary_prefix"??????
    do
        [ -f "$temporary_part" ] || continue
        cat "$temporary_part" >>"$temporary_archive"
    done

    print_info "Verifying the compressed stream before publishing parts..."
    if ! verify_archive_native "$ENGINE" "$temporary_archive"; then
        print_error "the generated compressed stream failed native verification"
        return 1
    fi

    if [ "$STRICT_INTEGRITY" -eq 1 ]; then
        print_info "Checking that the source did not change during compression..."
        generate_source_records_for_source "$source_actual" "$source_name" \
            "$source_records_after" || return 1
        if ! cmp -s "$source_records_before" "$source_records_after"; then
            print_error "source content changed during compression; no output was published"
            return 1
        fi

        write_integrity_manifest "$temporary_manifest" "$source_records_before" \
            "$source_name" "$temporary_archive" "$temporary_prefix" \
            "$part_count" "$part_size_bytes"
        validate_manifest_structure "$temporary_manifest" || return 1
    fi

    if ! publish_generated_set "$temporary_prefix" "$output_prefix" "$temporary_manifest" "$output_manifest" "$STRICT_INTEGRITY"; then
        print_error "cannot publish archive parts transactionally; previous outputs were restored"
        return 1
    fi

    safe_remove_tree "$WORK_DIR"
    WORK_DIR=

    LAST_PART_PREFIX=$output_prefix
    LAST_MANIFEST=
    [ "$STRICT_INTEGRITY" -eq 0 ] || LAST_MANIFEST=$output_manifest
    LAST_ARCHIVE=$archive_file

    print_info "Compression and splitting completed."
    print_info "Parts created: $part_count"
    print_info "Output prefix: $output_prefix"
    if [ "$STRICT_INTEGRITY" -eq 1 ]; then
        print_info "Strict-integrity manifest: $output_manifest"
    fi
}

join_parts()
{
    selected_part=$(absolute_existing_path "$1") || { print_error "cannot resolve part path: $1"; return 1; }

    if [ ! -f "$selected_part" ]; then
        print_error "part does not exist: $selected_part"
        return 1
    fi

    if ! detected_engine=$(detect_engine_from_part "$selected_part"); then
        print_error "invalid or unsupported part name"
        print_error "expected format: NAME.tar.EXT.part.aaaaaa"
        return 2
    fi

    ENGINE=$detected_engine
    require_engine "$ENGINE" || return 1
    input_prefix=${selected_part%??????}
    output_file=${input_prefix%.part.}
    output_dir=$(dirname "$output_file")
    output_name=$(basename "$output_file")

    if [ -e "$output_file" ]; then
        if ! confirm_replace "Output archive already exists. Replace it?"; then
            print_info "Operation cancelled."
            LAST_ARCHIVE=$output_file
            return 0
        fi
    fi

    make_work_dir "$output_dir"
    temporary_archive=$WORK_DIR/$output_name
    strict_manifest=

    if [ "$STRICT_INTEGRITY" -eq 1 ]; then
        strict_manifest=$(resolve_manifest "$selected_part" part)
        validate_parts_against_manifest "$selected_part" "$strict_manifest" || return 1
        validate_manifest_archive_identity "$strict_manifest" "$output_file" "$ENGINE" || return 1
    fi

    concatenate_parts "$selected_part" "$temporary_archive" "$strict_manifest" || return 1

    print_info "Detected compression engine: $ENGINE"
    print_info "Verifying the reconstructed compressed stream..."
    if ! verify_archive_native "$ENGINE" "$temporary_archive"; then
        print_error "the reconstructed file failed $ENGINE native verification"
        return 1
    fi

    if [ "$STRICT_INTEGRITY" -eq 1 ]; then
        validate_archive_against_manifest "$temporary_archive" "$ENGINE" \
            "$strict_manifest" || return 1
    fi

    mv -f "$temporary_archive" "$output_file"
    safe_remove_tree "$WORK_DIR"
    WORK_DIR=
    LAST_ARCHIVE=$output_file

    print_info "Archive joined and verified: $output_file"
}

verify_input()
{
    verify_input_path=$(absolute_existing_path "$1") || { print_error "cannot resolve input path: $1"; return 1; }

    if detected_engine=$(detect_engine_from_part "$verify_input_path" 2>/dev/null); then
        if [ ! -f "$verify_input_path" ]; then
            print_error "part does not exist: $verify_input_path"
            return 1
        fi
        ENGINE=$detected_engine
        require_engine "$ENGINE" || return 1
        output_archive=${verify_input_path%??????}
        output_archive=${output_archive%.part.}
        output_dir=$(dirname "$output_archive")
        make_work_dir "$output_dir"
        temporary_archive=$WORK_DIR/$(basename "$output_archive")
        strict_manifest=
        if [ "$STRICT_INTEGRITY" -eq 1 ]; then
            strict_manifest=$(resolve_manifest "$verify_input_path" part)
            validate_parts_against_manifest "$verify_input_path" "$strict_manifest" || return 1
            validate_manifest_archive_identity "$strict_manifest" "$output_archive" "$ENGINE" || return 1
        fi
        concatenate_parts "$verify_input_path" "$temporary_archive" "$strict_manifest" || return 1
        if ! verify_archive_native "$ENGINE" "$temporary_archive"; then
            print_error "reconstructed stream failed native verification"
            return 1
        fi
        if [ "$STRICT_INTEGRITY" -eq 1 ]; then
            validate_archive_against_manifest "$temporary_archive" "$ENGINE" \
                "$strict_manifest" || return 1
        fi
        safe_remove_tree "$WORK_DIR"
        WORK_DIR=
        print_info "Verification completed successfully for the part set."
        return 0
    fi

    if ! detected_engine=$(detect_engine_from_archive "$verify_input_path"); then
        print_error "unsupported archive or part name: $verify_input_path"
        return 2
    fi
    if [ ! -f "$verify_input_path" ]; then
        print_error "archive does not exist: $verify_input_path"
        return 1
    fi

    ENGINE=$detected_engine
    require_engine "$ENGINE" || return 1
    output_dir=$(dirname "$verify_input_path")
    make_work_dir "$output_dir"

    if ! verify_archive_native "$ENGINE" "$verify_input_path"; then
        print_error "archive failed $ENGINE native verification"
        return 1
    fi
    if [ "$STRICT_INTEGRITY" -eq 1 ]; then
        strict_manifest=$(resolve_manifest "$verify_input_path" archive)
        validate_archive_against_manifest "$verify_input_path" "$ENGINE" \
            "$strict_manifest" || return 1
    fi

    safe_remove_tree "$WORK_DIR"
    WORK_DIR=
    print_info "Archive verification completed successfully: $verify_input_path"
}

prepare_extraction_destination()
{
    destination_path=$(absolute_destination_path "$1") || {
        print_error "refusing unsafe extraction destination: $1"
        return 1
    }
    if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
        confirm_replace "Extraction destination already exists. Replace it transactionally?" || {
            print_info "Operation cancelled."
            return 1
        }
    fi
    EXTRACTION_DESTINATION=$destination_path
    extraction_parent=$(dirname "$destination_path")
    make_work_dir "$extraction_parent" || return 1
    EXTRACTION_STAGE=$WORK_DIR/extracted
    mkdir "$EXTRACTION_STAGE" || return 1
    chmod 700 "$EXTRACTION_STAGE" 2>/dev/null || :
}

publish_extraction_destination()
{
    extraction_destination=$EXTRACTION_DESTINATION
    extraction_stage=$EXTRACTION_STAGE
    extraction_parent=$(dirname "$extraction_destination")
    extraction_backup=$extraction_parent/.zstd-splitter-extract-backup.$$
    extraction_index=0
    while [ -e "$extraction_backup" ] || [ -L "$extraction_backup" ]; do
        extraction_index=$((extraction_index + 1))
        [ "$extraction_index" -le 100 ] || return 1
        extraction_backup=$extraction_parent/.zstd-splitter-extract-backup.$$.$extraction_index
    done
    EXTRACTION_BACKUP=
    if [ -e "$extraction_destination" ] || [ -L "$extraction_destination" ]; then
        mv "$extraction_destination" "$extraction_backup" || return 1
        EXTRACTION_BACKUP=$extraction_backup
    fi
    if ! mv "$extraction_stage" "$extraction_destination"; then
        [ -z "$EXTRACTION_BACKUP" ] || mv "$EXTRACTION_BACKUP" "$extraction_destination" 2>/dev/null || :
        return 1
    fi
    if [ -n "$EXTRACTION_BACKUP" ]; then safe_remove_tree "$EXTRACTION_BACKUP" || return 1; fi
    EXTRACTION_STAGE=
    EXTRACTION_BACKUP=
}

extract_archive()
{
    extract_input=$(absolute_existing_path "$1") || { print_error "cannot resolve archive input: $1"; return 1; }
    extract_archive_path=$extract_input

    if detected_engine=$(detect_engine_from_part "$extract_input" 2>/dev/null); then
        join_parts "$extract_input" || return 1
        extract_archive_path=$LAST_ARCHIVE
    else
        if ! detected_engine=$(detect_engine_from_archive "$extract_input"); then print_error "unsupported archive or part name: $extract_input"; return 2; fi
        [ -f "$extract_input" ] || { print_error "archive does not exist: $extract_input"; return 1; }
        ENGINE=$detected_engine
        require_engine "$ENGINE" || return 1
    fi

    archive_dir=$(dirname "$extract_archive_path")
    archive_base=$(archive_base_without_extension "$extract_archive_path")
    if [ -z "$DESTINATION" ]; then extraction_destination=$archive_base.extracted; else extraction_destination=$DESTINATION; fi

    strict_manifest=
    if [ "$STRICT_INTEGRITY" -eq 1 ]; then
        strict_manifest=$(resolve_manifest "$extract_archive_path" archive)
        make_work_dir "$archive_dir"
        validate_archive_against_manifest "$extract_archive_path" "$ENGINE" "$strict_manifest" || return 1
        safe_remove_tree "$WORK_DIR"; WORK_DIR=
    fi

    prepare_extraction_destination "$extraction_destination" || return 1
    validate_archive_members "$extract_archive_path" "$ENGINE" || return 1
    tar_pipe=$WORK_DIR/extract.tar.pipe
    mkfifo "$tar_pipe" || return 1

    print_info "Extracting with engine $ENGINE to private staging: $EXTRACTION_STAGE"
    :
    start_decompressor "$ENGINE" "$extract_archive_path" "$tar_pipe"
    extract_compress_pid=$COMPRESS_PID
    register_child_pid "$extract_compress_pid"
    ( cd "$EXTRACTION_STAGE" && tar -xf "$tar_pipe" ) &
    EXTRACT_PID=$!
    register_child_pid "$EXTRACT_PID"
    :

    extraction_status=0
    wait "$extract_compress_pid" || extraction_status=1
    unregister_child_pid "$extract_compress_pid"
    COMPRESS_PID=
    wait "$EXTRACT_PID" || extraction_status=1
    unregister_child_pid "$EXTRACT_PID"
    EXTRACT_PID=
    :
    if [ "$extraction_status" -ne 0 ]; then
        :
        print_error "decompression or tar extraction failed"
        return 1
    fi

    if [ "$STRICT_INTEGRITY" -eq 1 ]; then
        extracted_records=$WORK_DIR/extracted-source.records
        expected_records=$WORK_DIR/expected-source.records
        generate_source_records_for_directory_contents "$EXTRACTION_STAGE" "$extracted_records" || return 1
        awk -F '\t' '$1 == "source" { print }' "$strict_manifest" >"$expected_records"
        extracted_sha=$(sha256_file "$extracted_records")
        expected_sha=$(manifest_value source_tree_sha256 "$strict_manifest")
        if [ "$extracted_sha" != "$expected_sha" ] || ! cmp -s "$expected_records" "$extracted_records"; then
            :
            print_error "extracted source tree failed strict SHA-256 validation"
            print_error "expected: $expected_sha"
            print_error "actual:   $extracted_sha"
            return 1
        fi
        print_info "Extracted source tree SHA-256 verified: $extracted_sha"
    fi

    publish_extraction_destination || { :; print_error "cannot publish extracted directory transactionally"; return 1; }
    :
    safe_remove_tree "$WORK_DIR"
    WORK_DIR=
    print_info "Extraction completed and verified: $EXTRACTION_DESTINATION"
}

append_line()
{
    append_variable=$1
    append_value=$2
    case $append_variable in
        REMOTE_DESTINATIONS)
            if [ -n "$REMOTE_DESTINATIONS" ]; then
                REMOTE_DESTINATIONS=$(printf '%s\n%s' "$REMOTE_DESTINATIONS" "$append_value")
            else
                REMOTE_DESTINATIONS=$append_value
            fi
            ;;
        NETWORK_OPTIONS)
            if [ -n "$NETWORK_OPTIONS" ]; then
                NETWORK_OPTIONS=$(printf '%s\n%s' "$NETWORK_OPTIONS" "$append_value")
            else
                NETWORK_OPTIONS=$append_value
            fi
            ;;
        *) print_error "internal append target is not permitted: $append_variable"; return 2 ;;
    esac
}

resolve_self_path()
{
    case $0 in
        /*) SELF_PATH=$0 ;;
        *)
            self_dir=$(dirname "$0")
            self_base=$(basename "$0")
            SELF_PATH=$(cd "$self_dir" 2>/dev/null && pwd -P)/$self_base
            ;;
    esac
    [ -f "$SELF_PATH" ] || {
        print_error "cannot resolve the running script for remote verification: $SELF_PATH"
        return 1
    }
}

make_network_temp_dir()
{
    [ -n "$NETWORK_TEMP_DIR" ] && [ -d "$NETWORK_TEMP_DIR" ] && return 0
    network_tmp_parent=$(secure_tmp_parent) || return 1
    old_umask=$(umask)
    umask 077
    NETWORK_TEMP_DIR=$(mktemp -d "$network_tmp_parent/zstd-splitter-network.XXXXXX" 2>/dev/null || :)
    if [ -z "$NETWORK_TEMP_DIR" ]; then
        network_index=0
        while [ "$network_index" -le 100 ]; do
            NETWORK_TEMP_DIR=$network_tmp_parent/zstd-splitter-network.$$.$network_index
            mkdir "$NETWORK_TEMP_DIR" 2>/dev/null && break
            NETWORK_TEMP_DIR=
            network_index=$((network_index + 1))
        done
    fi
    umask "$old_umask"
    [ -n "$NETWORK_TEMP_DIR" ] && [ -d "$NETWORK_TEMP_DIR" ] || {
        print_error "cannot create private network temporary directory"
        return 1
    }
    chmod 700 "$NETWORK_TEMP_DIR" 2>/dev/null || :
    NETWORK_CONTROL_DIR=$NETWORK_TEMP_DIR/control
    mkdir "$NETWORK_CONTROL_DIR" || return 1
    chmod 700 "$NETWORK_CONTROL_DIR" 2>/dev/null || :
}

network_require_commands()
{
    for network_command in sed date sleep grep mktemp
    do
        require_command "$network_command" || return 1
    done
    if [ "$NET_DRY_RUN" != yes ]; then
        require_command ssh || return 1
        require_command sftp || return 1
    fi
    resolve_self_path || return 1
    make_network_temp_dir || return 1
}

network_validate_yes_no()
{
    case $1 in yes|no) return 0 ;; *) return 1 ;; esac
}

network_read_option_lines()
{
    if [ -n "$NETWORK_CONFIG" ]; then
        [ -f "$NETWORK_CONFIG" ] || {
            print_error "network configuration file not found: $NETWORK_CONFIG"
            return 1
        }
        sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$NETWORK_CONFIG"
    fi
    [ -z "$NETWORK_OPTIONS" ] || printf '%s\n' "$NETWORK_OPTIONS"
}

network_find_last_option()
{
    find_key=$1
    network_read_option_lines | awk -F= -v key="$find_key" '
        $1 == key { sub(/^[^=]*=/, ""); value=$0; found=1 }
        END { if (found) print value }
    '
}

# -- Network policy and capability gates --
network_apply_profile()
{
    profile_name=$1
    case $profile_name in
        safe)
            NET_JOBS=1; NET_SFTP_BUFFER=32768; NET_SFTP_REQUESTS=64
            NET_RETRY=3; NET_KEEPALIVE_INTERVAL=15; NET_KEEPALIVE_COUNT=3
            NET_REMOTE_FSYNC=yes; NET_ATOMIC=yes; NET_RESUME=yes
            ;;
        lan)
            NET_JOBS=3; NET_SFTP_BUFFER=262144; NET_SFTP_REQUESTS=128
            NET_RETRY=2; NET_CONNECT_TIMEOUT=10; NET_REMOTE_FSYNC=no
            NET_CONTROL_MASTER=auto; NET_CONTROL_PERSIST=120
            ;;
        jumbo-lan)
            NET_JOBS=4; NET_SFTP_BUFFER=1048576; NET_SFTP_REQUESTS=128
            NET_STREAM_BLOCK=4194304; NET_MTU_CHECK=path; NET_MTU_REQUIRED=9000
            NET_RETRY=2; NET_REMOTE_FSYNC=no; NET_CONTROL_PERSIST=120
            ;;
        wan)
            NET_JOBS=2; NET_SFTP_BUFFER=131072; NET_SFTP_REQUESTS=128
            NET_RETRY=5; NET_RETRY_DELAY=3; NET_BACKOFF=exponential
            NET_KEEPALIVE_INTERVAL=15; NET_KEEPALIVE_COUNT=3
            ;;
        high-latency)
            NET_JOBS=2; NET_SFTP_BUFFER=262144; NET_SFTP_REQUESTS=256
            NET_RETRY=5; NET_BACKOFF=exponential; NET_CONTROL_PERSIST=300
            ;;
        metered)
            NET_JOBS=1; NET_SFTP_BUFFER=65536; NET_SFTP_REQUESTS=32
            [ "$NET_BANDWIDTH" -ne 0 ] || NET_BANDWIDTH=10000
            ;;
        unstable)
            NET_JOBS=1; NET_SFTP_BUFFER=32768; NET_SFTP_REQUESTS=32
            NET_RETRY=8; NET_RETRY_DELAY=2; NET_BACKOFF=exponential
            NET_KEEPALIVE_INTERVAL=10; NET_KEEPALIVE_COUNT=3
            ;;
        archive)
            NET_JOBS=1; NET_SFTP_BUFFER=65536; NET_SFTP_REQUESTS=64
            NET_REMOTE_FSYNC=yes; NET_RETAIN=all; NET_ATOMIC=yes
            NET_RETRY=5
            ;;
        *)
            print_error "unknown network profile: $profile_name"
            return 2
            ;;
    esac
    NET_PROFILE=$profile_name
}

network_apply_pair()
{
    option_line=$1
    case $option_line in
        *=*) option_key=${option_line%%=*}; option_value=${option_line#*=} ;;
        *) print_error "invalid network option (expected NAME=VALUE): $option_line"; return 2 ;;
    esac
    case $option_key in
        profile) : ;;
        transport) NET_TRANSPORT=$option_value ;;
        resume) NET_RESUME=$option_value ;;
        atomic) NET_ATOMIC=$option_value ;;
        remote-verify) NET_REMOTE_VERIFY=$option_value ;;
        remote-extract) NET_REMOTE_EXTRACT=$option_value ;;
        retry) NET_RETRY=$option_value ;;
        retry-delay) NET_RETRY_DELAY=$option_value ;;
        retry-backoff) NET_BACKOFF=$option_value ;;
        connect-timeout) NET_CONNECT_TIMEOUT=$option_value ;;
        server-alive-interval) NET_KEEPALIVE_INTERVAL=$option_value ;;
        server-alive-count) NET_KEEPALIVE_COUNT=$option_value ;;
        host-key-policy) NET_HOST_KEY_POLICY=$option_value ;;
        known-hosts) NET_KNOWN_HOSTS=$option_value ;;
        identity) NET_IDENTITY=$option_value ;;
        port) NET_PORT=$option_value ;;
        jump) NET_JUMP=$option_value ;;
        address-family) NET_ADDRESS_FAMILY=$option_value ;;
        bind-interface) NET_BIND_INTERFACE=$option_value ;;
        bind-address) NET_BIND_ADDRESS=$option_value ;;
        ssh-compression) NET_SSH_COMPRESSION=$option_value ;;
        control-master) NET_CONTROL_MASTER=$option_value ;;
        control-persist) NET_CONTROL_PERSIST=$option_value ;;
        jobs) NET_JOBS=$option_value ;;
        sftp-buffer) NET_SFTP_BUFFER=$option_value ;;
        sftp-requests) NET_SFTP_REQUESTS=$option_value ;;
        bandwidth) NET_BANDWIDTH=$option_value ;;
        stream-block) NET_STREAM_BLOCK=$option_value ;;
        mtu-check) NET_MTU_CHECK=$option_value ;;
        mtu-required) NET_MTU_REQUIRED=$option_value ;;
        tune) NET_TUNE=$option_value ;;
        remote-fsync) NET_REMOTE_FSYNC=$option_value ;;
        cleanup) NET_CLEANUP=$option_value ;;
        dry-run) NET_DRY_RUN=$option_value ;;
        quorum) NET_QUORUM=$option_value ;;
        audit-log) NET_AUDIT_LOG=$option_value ;;
        gc-days) NET_GC_DAYS=$option_value ;;
        retain) NET_RETAIN=$option_value ;;
        lock) NET_LOCK=$option_value ;;
        allow-unverified) NET_ALLOW_UNVERIFIED=$option_value ;;
        destination) append_line REMOTE_DESTINATIONS "$option_value" ;;
        *) print_error "unknown network option: $option_key"; return 2 ;;
    esac
}

network_validate_settings()
{
    case $NET_TRANSPORT in sftp|ssh-stream) ;; *) print_error "invalid transport: $NET_TRANSPORT"; return 2 ;; esac
    for yn_pair in \
        "resume:$NET_RESUME" "atomic:$NET_ATOMIC" \
        "remote-fsync:$NET_REMOTE_FSYNC" "dry-run:$NET_DRY_RUN" \
        "lock:$NET_LOCK" "allow-unverified:$NET_ALLOW_UNVERIFIED"
    do
        yn_name=${yn_pair%%:*}; yn_value=${yn_pair#*:}
        network_validate_yes_no "$yn_value" || {
            print_error "$yn_name must be yes or no"
            return 2
        }
    done
    for int_pair in \
        "retry:$NET_RETRY" "retry-delay:$NET_RETRY_DELAY" \
        "connect-timeout:$NET_CONNECT_TIMEOUT" \
        "server-alive-interval:$NET_KEEPALIVE_INTERVAL" \
        "server-alive-count:$NET_KEEPALIVE_COUNT" \
        "control-persist:$NET_CONTROL_PERSIST" \
        "jobs:$NET_JOBS" "sftp-buffer:$NET_SFTP_BUFFER" \
        "sftp-requests:$NET_SFTP_REQUESTS" "bandwidth:$NET_BANDWIDTH" \
        "stream-block:$NET_STREAM_BLOCK" "mtu-required:$NET_MTU_REQUIRED" \
        "quorum:$NET_QUORUM" "gc-days:$NET_GC_DAYS"
    do
        int_name=${int_pair%%:*}; int_value=${int_pair#*:}
        validate_nonnegative_integer "$int_value" || {
            print_error "$int_name must be a non-negative integer"
            return 2
        }
    done
    [ "$NET_JOBS" -gt 0 ] || { print_error "jobs must be greater than zero"; return 2; }
    [ "$NET_SFTP_BUFFER" -gt 0 ] || { print_error "sftp-buffer must be greater than zero"; return 2; }
    [ "$NET_SFTP_REQUESTS" -gt 0 ] || { print_error "sftp-requests must be greater than zero"; return 2; }
    case $NET_HOST_KEY_POLICY in strict|accept-new) ;; *) print_error "invalid host-key-policy"; return 2 ;; esac
    case $NET_CONTROL_MASTER in yes|no|ask|auto|autoask) ;; *) print_error "invalid control-master"; return 2 ;; esac
    case $NET_ADDRESS_FAMILY in any|inet|inet6) ;; *) print_error "invalid address-family"; return 2 ;; esac
    case $NET_BACKOFF in linear|exponential) ;; *) print_error "invalid retry-backoff"; return 2 ;; esac
    case $NET_MTU_CHECK in off|local|remote|path) ;; *) print_error "invalid mtu-check"; return 2 ;; esac
    case $NET_TUNE in off|safe|adaptive) ;; *) print_error "invalid tune value"; return 2 ;; esac
    case $NET_CLEANUP in success|always|never) ;; *) print_error "invalid cleanup policy"; return 2 ;; esac
    case $NET_RETAIN in parts|archive|all) ;; *) print_error "invalid retain value"; return 2 ;; esac
    case $NET_REMOTE_VERIFY in parts|archive|content|all|none) ;; *) print_error "invalid remote-verify"; return 2 ;; esac
    case $NET_SSH_COMPRESSION in yes|no) ;; *) print_error "ssh-compression must be yes or no"; return 2 ;; esac
    case $NET_CONTROL_MASTER in no|yes|ask|auto|autoask) ;; *) print_error "invalid control-master value"; return 2 ;; esac
    case $NET_CONTROL_PERSIST in no|yes|''|*[!0-9]*) print_error "control-persist must be a non-negative integer"; return 2 ;; esac
    [ -z "$NET_PORT" ] || { validate_integer_range "$NET_PORT" 1 65535 || { print_error "port must be in 1..65535"; return 2; }; }
    validate_remote_extract_path "$NET_REMOTE_EXTRACT" || { print_error "unsafe remote-extract path"; return 2; }
    for text_value in "$NET_KNOWN_HOSTS" "$NET_IDENTITY" "$NET_JUMP" "$NET_BIND_INTERFACE" "$NET_BIND_ADDRESS" "$NET_AUDIT_LOG"
    do
        validate_plain_option_text "$text_value" || { print_error "network option contains a control character"; return 2; }
    done
    validate_jump_spec "$NET_JUMP" || { print_error "invalid or unsafe jump destination"; return 2; }
    [ "$NET_RETRY" -le 100 ] || { print_error "retry exceeds safety limit 100"; return 2; }
    [ "$NET_RETRY_DELAY" -le 3600 ] || { print_error "retry-delay exceeds safety limit 3600"; return 2; }
    [ "$NET_JOBS" -le 64 ] || { print_error "jobs exceeds safety limit 64"; return 2; }
    [ "$NET_SFTP_BUFFER" -le 16777216 ] || { print_error "sftp-buffer exceeds safety limit 16 MiB"; return 2; }
    [ "$NET_SFTP_REQUESTS" -le 1024 ] || { print_error "sftp-requests exceeds safety limit 1024"; return 2; }

    if [ "$FEATURE_LEVEL" -lt 41 ]; then
        [ "$NET_PROFILE" = safe ] || { print_error "network profiles require version 4.1"; return 2; }
        [ "$NET_JOBS" -eq 1 ] || { print_error "parallel network jobs require version 4.1"; return 2; }
        [ "$NET_SFTP_BUFFER" -eq 32768 ] || { print_error "SFTP buffer tuning requires version 4.1"; return 2; }
        [ "$NET_SFTP_REQUESTS" -eq 64 ] || { print_error "SFTP request-window tuning requires version 4.1"; return 2; }
        [ "$NET_STREAM_BLOCK" -eq 1048576 ] || { print_error "stream-block tuning requires version 4.1"; return 2; }
        [ "$NET_CONTROL_MASTER" = no ] || { print_error "connection-reuse tuning requires version 4.1"; return 2; }
        [ "$NET_CONTROL_PERSIST" -eq 0 ] || { print_error "connection-reuse tuning requires version 4.1"; return 2; }
        [ "$NET_MTU_CHECK" = off ] || { print_error "MTU diagnostics require version 4.1"; return 2; }
        [ "$NET_TUNE" = off ] || { print_error "network tuning requires version 4.1"; return 2; }
    fi
    if [ "$FEATURE_LEVEL" -lt 42 ]; then
        [ "$NET_QUORUM" -eq 0 ] || { print_error "quorum requires version 4.2"; return 2; }
        [ -z "$NET_AUDIT_LOG" ] || { print_error "audit-log requires version 4.2"; return 2; }
        [ "$NET_GC_DAYS" -eq 7 ] || { print_error "gc-days requires version 4.2"; return 2; }
    fi
}

# Applies profile defaults, overlays explicit options, validates values, and
# enforces the release feature boundary before any network side effect.

network_initialize()
{
    requested_profile=$(network_find_last_option profile || :)
    [ -n "$requested_profile" ] || requested_profile=safe
    network_apply_profile "$requested_profile" || return

    old_ifs=$IFS
    IFS='
'
    set -f
    for network_line in $(network_read_option_lines)
    do
        network_apply_pair "$network_line" || { set +f; IFS=$old_ifs; return; }
    done
    set +f
    IFS=$old_ifs
    network_validate_settings || return
    remote_count_now=$(network_count_remotes)
    if [ "$FEATURE_LEVEL" -lt 42 ] && [ "$remote_count_now" -gt 1 ]; then
        print_error "multiple remote specifications require version 4.2"
        return 2
    fi
    if [ "$ACTION" = query ] && [ "$NETWORK_QUERY_MODE" = config ]; then
        return 0
    fi
    network_require_commands || return
}

network_count_remotes()
{
    [ -z "$REMOTE_DESTINATIONS" ] && { printf '%s\n' 0; return; }
    printf '%s\n' "$REMOTE_DESTINATIONS" | awk 'NF { count++ } END { print count + 0 }'
}

# -- SSH/SFTP transport and remote transactions --
parse_remote_spec()
{
    remote_spec=$1
    contains_control_characters "$remote_spec" && {
        print_error "remote specifications containing control characters are refused"
        return 2
    }
    case $remote_spec in
        *']:'*)
            REMOTE_TARGET=${remote_spec%%]:*}]
            REMOTE_PATH=${remote_spec#*]:}
            ;;
        *:*)
            REMOTE_TARGET=${remote_spec%%:*}
            REMOTE_PATH=${remote_spec#*:}
            ;;
        *)
            print_error "invalid remote specification: $remote_spec"
            return 2
            ;;
    esac
    validate_remote_target "$REMOTE_TARGET" || {
        print_error "unsafe or invalid SSH destination: $REMOTE_TARGET"
        return 2
    }
    validate_remote_path "$REMOTE_PATH" || {
        print_error "unsafe or invalid absolute remote path: $REMOTE_PATH"
        return 2
    }
}

shell_quote()
{
    # POSIX single-quote escaping: ' becomes '\'' inside a quoted word.
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

sftp_quote()
{
    contains_control_characters "$1" && {
        print_error "SFTP paths containing tabs or line breaks are refused"
        return 1
    }
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

register_network_target()
{
    network_target_value=$1
    case "
$NETWORK_CONNECTED_TARGETS
" in *"
$network_target_value
"*) return 0 ;; esac
    if [ -n "$NETWORK_CONNECTED_TARGETS" ]; then
        NETWORK_CONNECTED_TARGETS=$(printf '%s\n%s' "$NETWORK_CONNECTED_TARGETS" "$network_target_value")
    else
        NETWORK_CONNECTED_TARGETS=$network_target_value
    fi
}

clear_active_stage()
{
    active_target=${1-}; active_dir=${2-}
    if [ "$ACTIVE_STAGE_TARGET" = "$active_target" ] && [ "$ACTIVE_STAGE_DIR" = "$active_dir" ]; then
        ACTIVE_STAGE_TARGET=
        ACTIVE_STAGE_DIR=
        ACTIVE_STAGE_LOCK=
    fi
}

network_abort_active_stage()
{
    [ -n "$ACTIVE_STAGE_TARGET" ] && [ -n "$ACTIVE_STAGE_DIR" ] || return 0
    abort_saved_target=$ACTIVE_STAGE_TARGET
    abort_saved_dir=$ACTIVE_STAGE_DIR
    abort_saved_lock=$ACTIVE_STAGE_LOCK
    ACTIVE_STAGE_TARGET=
    ACTIVE_STAGE_DIR=
    ACTIVE_STAGE_LOCK=
    network_stage_abort "$abort_saved_target" "$abort_saved_dir" "$abort_saved_lock" || :
}

network_close_control_masters()
{
    [ "$NET_DRY_RUN" != yes ] || return 0
    [ "$NET_CONTROL_MASTER" != no ] || return 0
    [ -n "$NETWORK_CONTROL_DIR" ] && [ -d "$NETWORK_CONTROL_DIR" ] || return 0
    command -v ssh >/dev/null 2>&1 || return 0
    close_targets=$NETWORK_CONNECTED_TARGETS
    close_old_ifs=$IFS
    IFS='
'
    set -f
    for close_target in $close_targets
    do
        [ -n "$close_target" ] || continue
        set -- ssh -q -o BatchMode=yes -o RequestTTY=no \
            -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes \
            -o PermitLocalCommand=no -o "ControlPath=$NETWORK_CONTROL_DIR/%C" -O exit
        [ -z "$NET_IDENTITY" ] || set -- "$@" -o IdentitiesOnly=yes -i "$NET_IDENTITY"
        [ -z "$NET_PORT" ] || set -- "$@" -p "$NET_PORT"
        [ -z "$NET_JUMP" ] || set -- "$@" -J "$NET_JUMP"
        case $NET_ADDRESS_FAMILY in inet) set -- "$@" -4 ;; inet6) set -- "$@" -6 ;; esac
        "$@" "$close_target" >/dev/null 2>&1 || :
    done
    set +f
    IFS=$close_old_ifs
    NETWORK_CONNECTED_TARGETS=
}

network_print_command()
{
    printf '[dry-run]'
    for print_arg in "$@"; do printf ' %s' "$(shell_quote "$print_arg")"; done
    printf '\n'
}

# Builds one non-interactive SSH command from validated state. No user-provided
# network option is evaluated as shell source.
ssh_run()
{
    ssh_destination=$1
    ssh_command=$2
    validate_remote_target "$ssh_destination" || {
        print_error "unsafe SSH destination: $ssh_destination"
        return 2
    }
    set -- ssh -o BatchMode=yes -o RequestTTY=no \
        -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes \
        -o PermitLocalCommand=no -o EscapeChar=none \
        -o "ConnectTimeout=$NET_CONNECT_TIMEOUT" \
        -o "ServerAliveInterval=$NET_KEEPALIVE_INTERVAL" \
        -o "ServerAliveCountMax=$NET_KEEPALIVE_COUNT" \
        -o "Compression=$NET_SSH_COMPRESSION" \
        -o "StrictHostKeyChecking=$( [ "$NET_HOST_KEY_POLICY" = strict ] && printf yes || printf %s "$NET_HOST_KEY_POLICY" )" \
        -o "ControlMaster=$NET_CONTROL_MASTER" \
        -o "ControlPersist=$NET_CONTROL_PERSIST" \
        -o "ControlPath=$NETWORK_CONTROL_DIR/%C"
    [ -z "$NET_KNOWN_HOSTS" ] || set -- "$@" -o "UserKnownHostsFile=$NET_KNOWN_HOSTS"
    if [ -n "$NET_IDENTITY" ]; then set -- "$@" -o IdentitiesOnly=yes -i "$NET_IDENTITY"; fi
    [ -z "$NET_PORT" ] || set -- "$@" -p "$NET_PORT"
    [ -z "$NET_JUMP" ] || set -- "$@" -J "$NET_JUMP"
    case $NET_ADDRESS_FAMILY in inet) set -- "$@" -4 ;; inet6) set -- "$@" -6 ;; esac
    [ -z "$NET_BIND_INTERFACE" ] || set -- "$@" -B "$NET_BIND_INTERFACE"
    [ -z "$NET_BIND_ADDRESS" ] || set -- "$@" -b "$NET_BIND_ADDRESS"
    set -- "$@" "$ssh_destination" "$ssh_command"
    if [ "$NET_DRY_RUN" = yes ]; then network_print_command "$@"; return 0; fi
    register_network_target "$ssh_destination"
    "$@"
}

sftp_run_batch()
{
    sftp_destination=$1
    sftp_batch=$2
    validate_remote_target "$sftp_destination" || {
        print_error "unsafe SFTP destination: $sftp_destination"
        return 2
    }
    set -- sftp -q -b "$sftp_batch" -B "$NET_SFTP_BUFFER" -R "$NET_SFTP_REQUESTS" \
        -o BatchMode=yes -o ForwardAgent=no -o ForwardX11=no \
        -o ClearAllForwardings=yes -o PermitLocalCommand=no \
        -o "ConnectTimeout=$NET_CONNECT_TIMEOUT" \
        -o "ServerAliveInterval=$NET_KEEPALIVE_INTERVAL" \
        -o "ServerAliveCountMax=$NET_KEEPALIVE_COUNT" \
        -o "Compression=$NET_SSH_COMPRESSION" \
        -o "StrictHostKeyChecking=$( [ "$NET_HOST_KEY_POLICY" = strict ] && printf yes || printf %s "$NET_HOST_KEY_POLICY" )" \
        -o "ControlMaster=$NET_CONTROL_MASTER" \
        -o "ControlPersist=$NET_CONTROL_PERSIST" \
        -o "ControlPath=$NETWORK_CONTROL_DIR/%C"
    [ "$NET_BANDWIDTH" -eq 0 ] || set -- "$@" -l "$NET_BANDWIDTH"
    [ -z "$NET_KNOWN_HOSTS" ] || set -- "$@" -o "UserKnownHostsFile=$NET_KNOWN_HOSTS"
    if [ -n "$NET_IDENTITY" ]; then set -- "$@" -o IdentitiesOnly=yes -i "$NET_IDENTITY"; fi
    [ -z "$NET_PORT" ] || set -- "$@" -P "$NET_PORT"
    [ -z "$NET_JUMP" ] || set -- "$@" -J "$NET_JUMP"
    case $NET_ADDRESS_FAMILY in inet) set -- "$@" -4 ;; inet6) set -- "$@" -6 ;; esac
    set -- "$@" "$sftp_destination"
    if [ "$NET_DRY_RUN" = yes ]; then
        network_print_command "$@"
        sed 's/^/[dry-run sftp] /' "$sftp_batch"
        return 0
    fi
    register_network_target "$sftp_destination"
    "$@"
}

network_retry()
{
    retry_attempt=0
    retry_delay=$NET_RETRY_DELAY
    while :; do
        if "$@"; then return 0; fi
        retry_attempt=$((retry_attempt + 1))
        [ "$retry_attempt" -le "$NET_RETRY" ] || return 1
        print_error "network operation failed; retry $retry_attempt/$NET_RETRY in ${retry_delay}s"
        sleep "$retry_delay"
        case $NET_BACKOFF in
            linear) retry_delay=$((retry_delay + NET_RETRY_DELAY)) ;;
            exponential) retry_delay=$((retry_delay * 2)) ;;
        esac
    done
}

sftp_put_one()
{
    put_destination=$1; put_local=$2; put_remote=$3
    make_network_temp_dir || return 1
    NETWORK_COUNTER=$((NETWORK_COUNTER + 1))
    put_batch=$(mktemp "$NETWORK_TEMP_DIR/put.XXXXXX")
    if [ "$NET_RESUME" = yes ]; then put_flag='put -a'; else put_flag=put; fi
    printf '%s %s %s\n' "$put_flag" "$(sftp_quote "$put_local")" "$(sftp_quote "$put_remote")" >"$put_batch"
    sftp_run_batch "$put_destination" "$put_batch"
}

sftp_get_one()
{
    get_destination=$1; get_remote=$2; get_local=$3
    make_network_temp_dir || return 1
    NETWORK_COUNTER=$((NETWORK_COUNTER + 1))
    get_batch=$(mktemp "$NETWORK_TEMP_DIR/get.XXXXXX")
    if [ "$NET_RESUME" = yes ]; then get_flag='get -a'; else get_flag=get; fi
    printf '%s %s %s\n' "$get_flag" "$(sftp_quote "$get_remote")" "$(sftp_quote "$get_local")" >"$get_batch"
    sftp_run_batch "$get_destination" "$get_batch"
}

json_escape()
{
    ZSS_JSON_VALUE=$1
    export ZSS_JSON_VALUE
    awk 'BEGIN {
        value = ENVIRON["ZSS_JSON_VALUE"]
        for (i = 1; i < 32; i++) control[sprintf("%c", i)] = sprintf("\\u%04x", i)
        for (i = 1; i <= length(value); i++) {
            c = substr(value, i, 1)
            if (c == "\\") printf "\\\\"
            else if (c == "\"") printf "\\\""
            else if (c in control) printf "%s", control[c]
            else printf "%s", c
        }
    }' 
    unset ZSS_JSON_VALUE
}

audit_event()
{
    audit_name=$1; audit_status=$2; audit_detail=${3-}
    [ -n "$NET_AUDIT_LOG" ] || return 0
    audit_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '{"time":"%s","program":"%s","version":"%s","event":"%s","status":"%s","detail":"%s"}\n' \
        "$(json_escape "$audit_time")" "$(json_escape "$PROGRAM_NAME")" \
        "$(json_escape "$PROGRAM_VERSION")" "$(json_escape "$audit_name")" \
        "$(json_escape "$audit_status")" "$(json_escape "$audit_detail")" \
        >>"$NET_AUDIT_LOG"
}

network_transfer_id()
{
    make_network_temp_dir || return 1
    transfer_token_file=$(mktemp "$NETWORK_TEMP_DIR/transfer-id.XXXXXX") || return 1
    transfer_token=${transfer_token_file##*.}
    rm -f "$transfer_token_file"
    printf '%s-%s-%s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" "$$" "$transfer_token"
}

network_prepare_local_set()
{
    transfer_input=$(absolute_existing_path "$1") || { print_error "cannot resolve network input: $1"; return 1; }
    make_network_temp_dir || return 1
    NETWORK_FILE_LIST=$NETWORK_TEMP_DIR/local-files.$$.list
    : >"$NETWORK_FILE_LIST"
    NETWORK_MANIFEST_PATH=
    NETWORK_SELECTED_PART=
    NETWORK_ARCHIVE_NAME=
    NETWORK_ENGINE=

    if detected_engine=$(detect_engine_from_part "$transfer_input" 2>/dev/null); then
        [ -f "$transfer_input" ] || { print_error "part does not exist: $transfer_input"; return 1; }
        NETWORK_ENGINE=$detected_engine
        transfer_prefix=${transfer_input%??????}
        transfer_archive=${transfer_prefix%.part.}
        NETWORK_ARCHIVE_NAME=$(basename "$transfer_archive")
        NETWORK_MANIFEST_PATH=$(resolve_manifest "$transfer_input" part)
        if [ "$STRICT_INTEGRITY" -eq 1 ]; then
            make_work_dir "$(dirname "$transfer_input")"
            validate_parts_against_manifest "$transfer_input" "$NETWORK_MANIFEST_PATH" || return 1
            awk -F '\t' '$1 == "part" { print $2 }' "$NETWORK_MANIFEST_PATH" >"$NETWORK_TEMP_DIR/suffixes.$$.list"
            while IFS= read -r transfer_suffix; do
                transfer_file=$transfer_prefix$transfer_suffix
                case $transfer_file in *'
'*) print_error "network transfer refuses newlines in file names"; return 1 ;; esac
                printf '%s\n' "$transfer_file" >>"$NETWORK_FILE_LIST"
                [ -n "$NETWORK_SELECTED_PART" ] || NETWORK_SELECTED_PART=$transfer_file
            done <"$NETWORK_TEMP_DIR/suffixes.$$.list"
            safe_remove_tree "$WORK_DIR"; WORK_DIR=
            printf '%s\n' "$NETWORK_MANIFEST_PATH" >>"$NETWORK_FILE_LIST"
        else
            [ "$NET_ALLOW_UNVERIFIED" = yes ] || {
                print_error "network transfer requires -i or -O allow-unverified=yes"
                return 2
            }
            for transfer_file in "$transfer_prefix"??????; do [ -f "$transfer_file" ] && printf '%s\n' "$transfer_file" >>"$NETWORK_FILE_LIST"; done
            NETWORK_SELECTED_PART=$transfer_input
        fi
    elif detected_engine=$(detect_engine_from_archive "$transfer_input" 2>/dev/null); then
        [ -f "$transfer_input" ] || { print_error "archive does not exist: $transfer_input"; return 1; }
        NETWORK_ENGINE=$detected_engine
        NETWORK_ARCHIVE_NAME=$(basename "$transfer_input")
        printf '%s\n' "$transfer_input" >>"$NETWORK_FILE_LIST"
        if [ "$STRICT_INTEGRITY" -eq 1 ]; then
            NETWORK_MANIFEST_PATH=$(resolve_manifest "$transfer_input" archive)
            make_work_dir "$(dirname "$transfer_input")"
            validate_archive_against_manifest "$transfer_input" "$detected_engine" "$NETWORK_MANIFEST_PATH" || return 1
            safe_remove_tree "$WORK_DIR"; WORK_DIR=
            printf '%s\n' "$NETWORK_MANIFEST_PATH" >>"$NETWORK_FILE_LIST"
        elif [ "$NET_ALLOW_UNVERIFIED" != yes ]; then
            print_error "network transfer requires -i or -O allow-unverified=yes"
            return 2
        fi
    else
        print_error "network input must be a supported archive or split part"
        return 2
    fi
}

ssh_stream_put_one()
{
    stream_destination=$1; stream_local=$2; stream_remote=$3
    if [ "$NET_DRY_RUN" = yes ]; then
        print_info "[dry-run] ssh-stream upload $(shell_quote "$stream_local") -> $(shell_quote "$stream_destination:$stream_remote")"
        return 0
    fi
    ssh_run "$stream_destination" "cat > $(shell_quote "$stream_remote")" <"$stream_local"
}

ssh_stream_get_one()
{
    stream_destination=$1; stream_remote=$2; stream_local=$3
    if [ "$NET_DRY_RUN" = yes ]; then
        print_info "[dry-run] ssh-stream download $(shell_quote "$stream_destination:$stream_remote") -> $(shell_quote "$stream_local")"
        return 0
    fi
    ssh_run "$stream_destination" "cat $(shell_quote "$stream_remote")" >"$stream_local"
}

network_put_one()
{
    case $NET_TRANSPORT in
        sftp) sftp_put_one "$@" ;;
        ssh-stream) ssh_stream_put_one "$@" ;;
    esac
}

network_get_one()
{
    case $NET_TRANSPORT in
        sftp) sftp_get_one "$@" ;;
        ssh-stream) ssh_stream_get_one "$@" ;;
    esac
}

network_remote_verify_commit()
{
    verify_target=$1; verify_partial=$2; verify_final=$3; verify_size=$4; verify_sha=$5
    q_partial=$(shell_quote "$verify_partial")
    q_final=$(shell_quote "$verify_final")
    q_sha=$(shell_quote "$verify_sha")
    verify_command="set -eu; test -f $q_partial; test \"\$(wc -c < $q_partial | tr -d ' ')\" = $(shell_quote "$verify_size"); test \"\$(sha256sum $q_partial | awk '{print \$1}')\" = $q_sha; mv -f $q_partial $q_final"
    if [ "$NET_REMOTE_FSYNC" = yes ]; then
        verify_command="$verify_command; sync -f $q_final 2>/dev/null || sync"
    fi
    ssh_run "$verify_target" "$verify_command"
}

network_remote_preflight()
{
    preflight_spec=$1
    parse_remote_spec "$preflight_spec" || return
    preflight_engine_command=$(engine_command "$NETWORK_ENGINE" 2>/dev/null || :)
    preflight_commands="sh tar split cat mkdir rm mv dirname basename mkfifo awk wc tr cmp readlink sha256sum"
    [ -z "$preflight_engine_command" ] || preflight_commands="$preflight_commands $preflight_engine_command"
    preflight_script=$(cat <<EOF_REMOTE_PREFLIGHT
set -eu
umask 077
ENV= BASH_ENV= CDPATH=
export ENV BASH_ENV CDPATH
for c in $preflight_commands; do
    command -v "\$c" >/dev/null 2>&1 || { echo "missing remote command: \$c" >&2; exit 1; }
done
test -w $(shell_quote "$REMOTE_PATH") 2>/dev/null || { mkdir -p $(shell_quote "$REMOTE_PATH"); test -w $(shell_quote "$REMOTE_PATH"); }
EOF_REMOTE_PREFLIGHT
)
    ssh_run "$REMOTE_TARGET" "$preflight_script"
}

network_stage_begin()
{
    stage_spec=$1; archive_name=$2
    parse_remote_spec "$stage_spec" || return
    contains_control_characters "$archive_name" && {
        print_error "archive names containing control characters cannot be published remotely"
        return 2
    }
    STAGE_TARGET=$REMOTE_TARGET
    STAGE_ROOT=$REMOTE_PATH
    STAGE_ID=$(network_transfer_id)
    STAGE_DIR=$STAGE_ROOT/.zstd-splitter.incoming/$STAGE_ID
    STAGE_LOCK=$STAGE_ROOT/.zstd-splitter.locks/$archive_name.lock
    STAGE_BUNDLE=$STAGE_ROOT/$archive_name.bundle
    q_root=$(shell_quote "$STAGE_ROOT")
    q_stage=$(shell_quote "$STAGE_DIR")
    q_lock=$(shell_quote "$STAGE_LOCK")
    q_incoming=$(shell_quote "$STAGE_ROOT/.zstd-splitter.incoming")
    q_locks=$(shell_quote "$STAGE_ROOT/.zstd-splitter.locks")
    stage_command="set -eu; umask 077; mkdir -p $q_root $q_incoming $q_locks"
    if [ "$NET_LOCK" = yes ]; then
        stage_command="$stage_command; mkdir $q_lock"
    fi
    stage_command="$stage_command; if ! mkdir $q_stage; then rmdir $q_lock 2>/dev/null || :; exit 1; fi"
    if ssh_run "$STAGE_TARGET" "$stage_command"; then
        ACTIVE_STAGE_TARGET=$STAGE_TARGET
        ACTIVE_STAGE_DIR=$STAGE_DIR
        ACTIVE_STAGE_LOCK=$STAGE_LOCK
        return 0
    else
        stage_status=$?
        return "$stage_status"
    fi
}

network_stage_abort()
{
    abort_target=$1; abort_stage=$2; abort_lock=$3
    abort_command=
    if [ "$NET_CLEANUP" != never ]; then
        abort_command="rm -rf $(shell_quote "$abort_stage");"
    fi
    abort_command="$abort_command rmdir $(shell_quote "$abort_lock") 2>/dev/null || :"
    ssh_run "$abort_target" "$abort_command" || :
    clear_active_stage "$abort_target" "$abort_stage"
}

network_upload_file_to_stage()
{
    upload_target=$1; upload_stage=$2; upload_file=$3
    upload_base=$(basename "$upload_file")
    upload_partial=$upload_stage/$upload_base.partial
    upload_final=$upload_stage/$upload_base
    upload_size=$(file_size "$upload_file")
    upload_sha=$(sha256_file "$upload_file")
    network_retry network_put_one "$upload_target" "$upload_file" "$upload_partial" || return 1
    network_retry network_remote_verify_commit "$upload_target" "$upload_partial" "$upload_final" "$upload_size" "$upload_sha"
}

network_upload_list_parallel()
{
    parallel_target=$1; parallel_stage=$2; parallel_list=$3
    if [ "$FEATURE_LEVEL" -lt 41 ] || [ "$NET_JOBS" -le 1 ]; then
        while IFS= read -r parallel_file; do
            network_upload_file_to_stage "$parallel_target" "$parallel_stage" "$parallel_file" || return 1
        done <"$parallel_list"
        return 0
    fi

    parallel_pids=
    parallel_count=0
    parallel_status=0
    while IFS= read -r parallel_file; do
        network_upload_file_to_stage "$parallel_target" "$parallel_stage" "$parallel_file" &
        parallel_pid=$!
        register_child_pid "$parallel_pid"
        parallel_pids="$parallel_pids $parallel_pid"
        parallel_count=$((parallel_count + 1))
        if [ "$parallel_count" -ge "$NET_JOBS" ]; then
            parallel_old_ifs=$IFS; IFS=' '
            for parallel_pid in $parallel_pids; do wait "$parallel_pid" || parallel_status=1; unregister_child_pid "$parallel_pid"; done
            IFS=$parallel_old_ifs
            [ "$parallel_status" -eq 0 ] || return 1
            parallel_pids=; parallel_count=0
        fi
    done <"$parallel_list"
    parallel_old_ifs=$IFS; IFS=' '
    for parallel_pid in $parallel_pids; do wait "$parallel_pid" || parallel_status=1; unregister_child_pid "$parallel_pid"; done
    IFS=$parallel_old_ifs
    [ "$parallel_status" -eq 0 ]
}

# Uploads/runs the same script remotely so archive/content verification uses
# the identical manifest format and codec rules as the local host.
network_remote_helper_action()
{
    helper_target=$1; helper_stage=$2; helper_selected=$3; helper_manifest=$4
    helper_name=.zstd-splitter-helper.sh
    network_upload_file_to_stage "$helper_target" "$helper_stage" "$SELF_PATH" || return 1
    uploaded_self=$helper_stage/$(basename "$SELF_PATH")
    ssh_run "$helper_target" "mv -f $(shell_quote "$uploaded_self") $(shell_quote "$helper_stage/$helper_name")" || return 1

    q_stage=$(shell_quote "$helper_stage")
    q_helper=$(shell_quote "./$helper_name")
    q_selected=$(shell_quote "$helper_selected")
    q_manifest=$(shell_quote "$helper_manifest")
    remote_command="set -eu; umask 077; cd $q_stage; ENV= BASH_ENV= CDPATH= sh $q_helper -v -i -m $q_manifest $q_selected"
    case $NET_RETAIN in
        archive|all) remote_command="$remote_command; ENV= BASH_ENV= CDPATH= sh $q_helper -j -i -f -m $q_manifest $q_selected" ;;
    esac
    if [ -n "$NET_REMOTE_EXTRACT" ]; then
        remote_command="$remote_command; ENV= BASH_ENV= CDPATH= sh $q_helper -x -i -f -m $q_manifest -d .extracted $q_selected"
    elif [ "$NET_REMOTE_VERIFY" = content ] || [ "$NET_REMOTE_VERIFY" = all ]; then
        remote_command="$remote_command; ENV= BASH_ENV= CDPATH= sh $q_helper -x -i -f -m $q_manifest -d .verify-extracted $q_selected; rm -rf .verify-extracted"
    fi
    if [ "$NET_RETAIN" = parts ]; then
        remote_archive=${helper_selected%.part.??????}
        remote_command="$remote_command; rm -f $(shell_quote "$remote_archive")"
    fi
    remote_command="$remote_command; rm -f $q_helper"
    ssh_run "$helper_target" "$remote_command"
}

network_stage_publish()
{
    publish_target=$1; publish_root=$2; publish_stage=$3; publish_bundle=$4; publish_lock=$5; publish_archive=$6
    publish_token=${publish_stage##*/}
    publish_backup=$publish_root/.zstd-splitter.backup.$publish_archive.$publish_token
    q_stage=$(shell_quote "$publish_stage")
    q_bundle=$(shell_quote "$publish_bundle")
    q_lock=$(shell_quote "$publish_lock")
    q_backup=$(shell_quote "$publish_backup")
    force_flag=$FORCE

    if [ -n "$NET_REMOTE_EXTRACT" ]; then
        if [ "$NET_REMOTE_EXTRACT" = auto ]; then publish_extract=$publish_root/$publish_archive.extracted; else publish_extract=$NET_REMOTE_EXTRACT; fi
        validate_remote_extract_path "$publish_extract" || { print_error "unsafe remote extraction destination: $publish_extract"; return 2; }
        publish_extract_backup=$publish_extract.zstd-splitter-backup.$publish_token
        q_extract=$(shell_quote "$publish_extract")
        q_extract_backup=$(shell_quote "$publish_extract_backup")
        q_extract_parent=$(shell_quote "$(dirname "$publish_extract")")
        publish_command=$(cat <<EOF_REMOTE_PUBLISH
set -eu
umask 077
stage=$q_stage
bundle=$q_bundle
lock=$q_lock
backup=$q_backup
extract=$q_extract
extract_backup=$q_extract_backup
extract_parent=$q_extract_parent
force=$force_flag
bundle_backed=0
bundle_installed=0
extract_backed=0
extract_installed=0
rollback()
{
    [ "\$bundle_installed" -eq 0 ] || rm -rf "\$bundle"
    [ "\$bundle_backed" -eq 0 ] || mv "\$backup" "\$bundle"
    [ "\$extract_installed" -eq 0 ] || rm -rf "\$extract"
    [ "\$extract_backed" -eq 0 ] || mv "\$extract_backup" "\$extract"
    rmdir "\$lock" 2>/dev/null || :
}
finish()
{
    status=\$?
    trap - 0 1 2 3 15
    [ "\$status" -eq 0 ] || rollback
    exit "\$status"
}
trap finish 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 131' 3
trap 'exit 143' 15
mkdir -p "\$extract_parent"
if [ -e "\$bundle" ]; then [ "\$force" -eq 1 ] || exit 1; mv "\$bundle" "\$backup"; bundle_backed=1; fi
if [ -e "\$extract" ]; then [ "\$force" -eq 1 ] || exit 1; mv "\$extract" "\$extract_backup"; extract_backed=1; fi
mv "\$stage/.extracted" "\$extract"; extract_installed=1
mv "\$stage" "\$bundle"; bundle_installed=1
rm -rf "\$backup" "\$extract_backup"
rmdir "\$lock" 2>/dev/null || :
trap - 0 1 2 3 15
EOF_REMOTE_PUBLISH
)
    elif [ "$NET_ATOMIC" = yes ]; then
        publish_command=$(cat <<EOF_REMOTE_PUBLISH
set -eu
umask 077
stage=$q_stage
bundle=$q_bundle
lock=$q_lock
backup=$q_backup
force=$force_flag
bundle_backed=0
bundle_installed=0
rollback()
{
    [ "\$bundle_installed" -eq 0 ] || rm -rf "\$bundle"
    [ "\$bundle_backed" -eq 0 ] || mv "\$backup" "\$bundle"
    rmdir "\$lock" 2>/dev/null || :
}
finish()
{
    status=\$?
    trap - 0 1 2 3 15
    [ "\$status" -eq 0 ] || rollback
    exit "\$status"
}
trap finish 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 131' 3
trap 'exit 143' 15
if [ -e "\$bundle" ]; then [ "\$force" -eq 1 ] || exit 1; mv "\$bundle" "\$backup"; bundle_backed=1; fi
mv "\$stage" "\$bundle"; bundle_installed=1
rm -rf "\$backup"
rmdir "\$lock" 2>/dev/null || :
trap - 0 1 2 3 15
EOF_REMOTE_PUBLISH
)
    else
        q_root=$(shell_quote "$publish_root")
        publish_command=$(cat <<EOF_REMOTE_PUBLISH
set -eu
umask 077
stage=$q_stage
root=$q_root
lock=$q_lock
force=$force_flag
for f in "\$stage"/* "\$stage"/.[!.]* "\$stage"/..?*
do
    [ -e "\$f" ] || [ -L "\$f" ] || continue
    name=\${f##*/}
    final=\$root/\$name
    if [ -e "\$final" ] || [ -L "\$final" ]; then [ "\$force" -eq 1 ] || exit 1; rm -rf "\$final"; fi
    mv "\$f" "\$final"
done
rmdir "\$stage"
rmdir "\$lock" 2>/dev/null || :
EOF_REMOTE_PUBLISH
)
    fi
    if ssh_run "$publish_target" "$publish_command"; then
        clear_active_stage "$publish_target" "$publish_stage"
        return 0
    else
        publish_status=$?
        return "$publish_status"
    fi
}

network_push_one()
{
    push_spec=$1; push_input=$2
    audit_event push start "$push_spec"
    network_prepare_local_set "$push_input" || { audit_event push failed "$push_spec"; return 1; }
    network_remote_preflight "$push_spec" || { audit_event push failed "$push_spec"; return 1; }
    network_stage_begin "$push_spec" "$NETWORK_ARCHIVE_NAME" || { audit_event push failed "$push_spec"; return 1; }

    if ! network_upload_list_parallel "$STAGE_TARGET" "$STAGE_DIR" "$NETWORK_FILE_LIST"; then
        network_stage_abort "$STAGE_TARGET" "$STAGE_DIR" "$STAGE_LOCK"
        audit_event push failed "$push_spec"
        return 1
    fi

    if [ "$STRICT_INTEGRITY" -eq 1 ]; then
        if [ -n "$NETWORK_SELECTED_PART" ] && { [ "$NET_REMOTE_VERIFY" != none ] && [ "$NET_REMOTE_VERIFY" != parts ] || [ -n "$NET_REMOTE_EXTRACT" ]; }; then
            selected_base=$(basename "$NETWORK_SELECTED_PART")
            manifest_base=$(basename "$NETWORK_MANIFEST_PATH")
            if ! network_remote_helper_action "$STAGE_TARGET" "$STAGE_DIR" "$selected_base" "$manifest_base"; then
                network_stage_abort "$STAGE_TARGET" "$STAGE_DIR" "$STAGE_LOCK"
                audit_event push failed "$push_spec"
                return 1
            fi
        elif [ -z "$NETWORK_SELECTED_PART" ] && { [ "$NET_REMOTE_VERIFY" != none ] || [ -n "$NET_REMOTE_EXTRACT" ]; }; then
            # Complete archive: remote native and manifest verification through helper.
            archive_base=$NETWORK_ARCHIVE_NAME
            manifest_base=$(basename "$NETWORK_MANIFEST_PATH")
            network_upload_file_to_stage "$STAGE_TARGET" "$STAGE_DIR" "$SELF_PATH" || {
                network_stage_abort "$STAGE_TARGET" "$STAGE_DIR" "$STAGE_LOCK" || :
                audit_event push failed "$push_spec"
                return 1
            }
            uploaded_self=$STAGE_DIR/$(basename "$SELF_PATH")
            remote_cmd="set -eu; umask 077; cd $(shell_quote "$STAGE_DIR"); ENV= BASH_ENV= CDPATH= sh $(shell_quote "./$(basename "$SELF_PATH")") -v -i -m $(shell_quote "$manifest_base") $(shell_quote "$archive_base"); rm -f $(shell_quote "./$(basename "$SELF_PATH")")"
            ssh_run "$STAGE_TARGET" "$remote_cmd" || {
                network_stage_abort "$STAGE_TARGET" "$STAGE_DIR" "$STAGE_LOCK" || :
                audit_event push failed "$push_spec"
                return 1
            }
        fi
    fi

    network_stage_publish "$STAGE_TARGET" "$STAGE_ROOT" "$STAGE_DIR" "$STAGE_BUNDLE" "$STAGE_LOCK" "$NETWORK_ARCHIVE_NAME" || {
        network_stage_abort "$STAGE_TARGET" "$STAGE_DIR" "$STAGE_LOCK" || :
        audit_event push failed "$push_spec"
        return 1
    }
    print_info "Remote publication completed: $push_spec -> $STAGE_BUNDLE"
    audit_event push success "$push_spec"
}

network_push_many()
{
    push_input=$1
    remote_count=$(network_count_remotes)
    [ "$remote_count" -gt 0 ] || { print_error "at least one -R destination is required"; return 2; }
    if [ "$FEATURE_LEVEL" -lt 42 ] && [ "$remote_count" -gt 1 ]; then
        print_error "multiple destinations require version 4.2"
        return 2
    fi
    push_required=$remote_count
    [ "$NET_QUORUM" -gt 0 ] && push_required=$NET_QUORUM
    [ "$push_required" -le "$remote_count" ] || { print_error "quorum exceeds destination count"; return 2; }

    push_success=0
    make_network_temp_dir || return 1
    push_remote_list=$NETWORK_TEMP_DIR/push-remotes.$$.list
    printf '%s
' "$REMOTE_DESTINATIONS" >"$push_remote_list"
    while IFS= read -r push_spec; do
        if network_push_one "$push_spec" "$push_input"; then push_success=$((push_success + 1)); fi
    done <"$push_remote_list"
    print_info "Successful remote destinations: $push_success/$remote_count (required: $push_required)"
    [ "$push_success" -ge "$push_required" ]
}

resolve_pull_destination()
{
    pull_destination_input=${1:-.}
    if [ "$pull_destination_input" = . ]; then
        pwd -P
        return
    fi
    case $pull_destination_input in /*) pull_destination_abs=$pull_destination_input ;; *) pull_destination_abs=$(pwd -P)/$pull_destination_input ;; esac
    if [ -e "$pull_destination_abs" ] || [ -L "$pull_destination_abs" ]; then
        [ -d "$pull_destination_abs" ] && [ ! -L "$pull_destination_abs" ] || return 1
        (cd "$pull_destination_abs" 2>/dev/null && pwd -P)
        return
    fi
    pull_parent=$(dirname "$pull_destination_abs")
    pull_base=$(basename "$pull_destination_abs")
    case $pull_base in ''|.|..) return 1 ;; esac
    case "/$pull_destination_abs/" in */../*|*/./*) return 1 ;; esac
    mkdir -p "$pull_parent" || return 1
    pull_parent=$(cd "$pull_parent" 2>/dev/null && pwd -P) || return 1
    pull_destination_abs=${pull_parent%/}/$pull_base
    mkdir "$pull_destination_abs" || return 1
    chmod 700 "$pull_destination_abs" 2>/dev/null || :
    printf '%s\n' "$pull_destination_abs"
}

network_pull()
{
    pull_spec=$1
    parse_remote_spec "$pull_spec" || return
    pull_target=$REMOTE_TARGET
    pull_remote_input=$REMOTE_PATH
    pull_destination=${DESTINATION:-.}
    pull_destination=$(resolve_pull_destination "$pull_destination") || {
        print_error "unsafe pull destination: $pull_destination"
        return 1
    }
    [ -d "$pull_destination" ] || mkdir -p "$pull_destination"
    make_network_temp_dir || return 1
    old_umask=$(umask); umask 077
    pull_stage=$(mktemp -d "$pull_destination/.zstd-splitter-pull.XXXXXX" 2>/dev/null || :)
    umask "$old_umask"
    [ -n "$pull_stage" ] || { print_error "cannot create private pull staging directory"; return 1; }

    saved_manifest_file=$MANIFEST_FILE
    MANIFEST_FILE=
    pull_result=1
    if detect_engine_from_part "$pull_remote_input" >/dev/null 2>&1; then
        pull_remote_prefix=${pull_remote_input%??????}
        pull_remote_archive=${pull_remote_prefix%.part.}
        pull_remote_manifest=$pull_remote_archive.manifest.sha256
        pull_manifest_final=$pull_stage/$(basename "$pull_remote_manifest")
        pull_manifest_partial=$pull_manifest_final.partial
        network_retry network_get_one "$pull_target" "$pull_remote_manifest" "$pull_manifest_partial" || { MANIFEST_FILE=$saved_manifest_file; safe_remove_tree "$pull_stage"; return 1; }
        mv "$pull_manifest_partial" "$pull_manifest_final"
        make_work_dir "$pull_stage"
        validate_manifest_structure "$pull_manifest_final" || { MANIFEST_FILE=$saved_manifest_file; safe_remove_tree "$pull_stage"; return 1; }
        safe_remove_tree "$WORK_DIR"; WORK_DIR=
        pull_local_prefix=$pull_stage/$(basename "$pull_remote_prefix")
        pull_first=
        awk -F '\t' '$1 == "part" { print $2 }' "$pull_manifest_final" >"$NETWORK_TEMP_DIR/pull-suffixes.$$.list"
        while IFS= read -r pull_suffix; do
            pull_remote_file=$pull_remote_prefix$pull_suffix
            pull_local_final=$pull_local_prefix$pull_suffix
            pull_local_partial=$pull_local_final.partial
            network_retry network_get_one "$pull_target" "$pull_remote_file" "$pull_local_partial" || { MANIFEST_FILE=$saved_manifest_file; safe_remove_tree "$pull_stage"; return 1; }
            mv "$pull_local_partial" "$pull_local_final"
            [ -n "$pull_first" ] || pull_first=$pull_local_final
        done <"$NETWORK_TEMP_DIR/pull-suffixes.$$.list"
        verify_input "$pull_first" || { MANIFEST_FILE=$saved_manifest_file; safe_remove_tree "$pull_stage"; return 1; }
        publish_staged_files "$pull_stage" "$pull_destination" || { MANIFEST_FILE=$saved_manifest_file; return 1; }
        print_info "Remote part set downloaded and verified in: $pull_destination"
        pull_result=0
    else
        detect_engine_from_archive "$pull_remote_input" >/dev/null 2>&1 || { MANIFEST_FILE=$saved_manifest_file; safe_remove_tree "$pull_stage"; print_error "unsupported remote input"; return 2; }
        pull_remote_manifest=$pull_remote_input.manifest.sha256
        pull_local_archive=$pull_stage/$(basename "$pull_remote_input")
        pull_local_manifest=$pull_stage/$(basename "$pull_remote_manifest")
        network_retry network_get_one "$pull_target" "$pull_remote_input" "$pull_local_archive.partial" || { MANIFEST_FILE=$saved_manifest_file; safe_remove_tree "$pull_stage"; return 1; }
        network_retry network_get_one "$pull_target" "$pull_remote_manifest" "$pull_local_manifest.partial" || { MANIFEST_FILE=$saved_manifest_file; safe_remove_tree "$pull_stage"; return 1; }
        mv "$pull_local_archive.partial" "$pull_local_archive"
        mv "$pull_local_manifest.partial" "$pull_local_manifest"
        verify_input "$pull_local_archive" || { MANIFEST_FILE=$saved_manifest_file; safe_remove_tree "$pull_stage"; return 1; }
        publish_staged_files "$pull_stage" "$pull_destination" || { MANIFEST_FILE=$saved_manifest_file; return 1; }
        print_info "Remote archive downloaded and verified in: $pull_destination"
        pull_result=0
    fi
    MANIFEST_FILE=$saved_manifest_file
    return "$pull_result"
}

network_print_config()
{
    cat <<EOF_NETWORK_CONFIG
profile=$NET_PROFILE
transport=$NET_TRANSPORT
resume=$NET_RESUME
atomic=$NET_ATOMIC
remote-verify=$NET_REMOTE_VERIFY
remote-extract=$NET_REMOTE_EXTRACT
retry=$NET_RETRY
retry-delay=$NET_RETRY_DELAY
retry-backoff=$NET_BACKOFF
connect-timeout=$NET_CONNECT_TIMEOUT
server-alive-interval=$NET_KEEPALIVE_INTERVAL
server-alive-count=$NET_KEEPALIVE_COUNT
host-key-policy=$NET_HOST_KEY_POLICY
jobs=$NET_JOBS
sftp-buffer=$NET_SFTP_BUFFER
sftp-requests=$NET_SFTP_REQUESTS
bandwidth=$NET_BANDWIDTH
stream-block=$NET_STREAM_BLOCK
mtu-check=$NET_MTU_CHECK
mtu-required=$NET_MTU_REQUIRED
tune=$NET_TUNE
remote-fsync=$NET_REMOTE_FSYNC
cleanup=$NET_CLEANUP
quorum=$NET_QUORUM
retain=$NET_RETAIN
EOF_NETWORK_CONFIG
}

network_mtu_diagnostic()
{
    mtu_spec=$1
    parse_remote_spec "$mtu_spec" || return
    mtu_target=$REMOTE_TARGET
    mtu_host=${mtu_target##*@}
    mtu_host=${mtu_host#[}; mtu_host=${mtu_host%]}
    print_info "MTU diagnostic target: $mtu_host"
    if command -v ip >/dev/null 2>&1; then
        print_info "Local route:"
        ip route get "$mtu_host" 2>/dev/null || print_info "  unavailable"
    else
        print_info "Local route: ip command unavailable"
    fi
    print_info "Remote interfaces and MTUs:"
    ssh_run "$mtu_target" "if command -v ip >/dev/null 2>&1; then ip -o link show; else ifconfig 2>/dev/null || :; fi"
    if [ "$NET_DRY_RUN" != yes ] && [ "$NET_MTU_CHECK" = path ] && command -v ping >/dev/null 2>&1; then
        mtu_payload=$((NET_MTU_REQUIRED - 28))
        if ping -c 1 -W 2 -M do -s "$mtu_payload" "$mtu_host" >/dev/null 2>&1; then
            print_info "Path MTU probe passed for IPv4 payload $mtu_payload (target MTU $NET_MTU_REQUIRED)."
        else
            print_info "Path MTU probe did not confirm target MTU $NET_MTU_REQUIRED."
        fi
    fi
}

network_adaptive_recommendation()
{
    [ "$NET_TUNE" = off ] && return 0
    print_info "Adaptive recommendation (non-destructive):"
    case $NET_PROFILE in
        jumbo-lan) print_info "  use sftp-buffer=$NET_SFTP_BUFFER, requests=$NET_SFTP_REQUESTS, jobs=$NET_JOBS after the MTU path probe passes" ;;
        high-latency|wan) print_info "  prioritize in-flight SFTP requests ($NET_SFTP_REQUESTS) and persistent SSH control connections" ;;
        metered) print_info "  bandwidth is limited to $NET_BANDWIDTH Kbit/s" ;;
        *) print_info "  current safe profile values are retained; no kernel or interface settings are changed" ;;
    esac
}

# -- Version-gated administration and relay --
network_query()
{
    query_mode=$1
    case $query_mode in
        config) network_print_config; return 0 ;;
    esac
    remote_count=$(network_count_remotes)
    [ "$remote_count" -gt 0 ] || { print_error "query mode $query_mode requires -R"; return 2; }
    make_network_temp_dir || return 1
    query_remote_list=$NETWORK_TEMP_DIR/query-remotes.$$.list
    printf '%s
' "$REMOTE_DESTINATIONS" >"$query_remote_list"
    while IFS= read -r query_spec; do
        parse_remote_spec "$query_spec" || return
        case $query_mode in
            network)
                print_info "SSH connectivity: $REMOTE_TARGET"
                ssh_run "$REMOTE_TARGET" "printf 'connected\\n'; uname -a 2>/dev/null || :"
                [ "$FEATURE_LEVEL" -lt 41 ] || network_mtu_diagnostic "$query_spec"
                network_adaptive_recommendation
                ;;
            health)
                [ "$FEATURE_LEVEL" -ge 42 ] || { print_error "health query requires version 4.2"; return 2; }
                ssh_run "$REMOTE_TARGET" "set -eu; test -d $(shell_quote "$REMOTE_PATH") || mkdir -p $(shell_quote "$REMOTE_PATH"); command -v sh; command -v tar; command -v sha256sum; df -Pk $(shell_quote "$REMOTE_PATH")"
                ;;
            inventory)
                [ "$FEATURE_LEVEL" -ge 42 ] || { print_error "inventory requires version 4.2"; return 2; }
                ssh_run "$REMOTE_TARGET" "find $(shell_quote "$REMOTE_PATH") -maxdepth 2 -type f \\( -name '*.manifest.sha256' -o -name '*.part.*' -o -name '*.tar.*' \\) -print 2>/dev/null | sort"
                ;;
            gc)
                [ "$FEATURE_LEVEL" -ge 42 ] || { print_error "gc requires version 4.2"; return 2; }
                [ "$FORCE" -eq 1 ] || { print_error "gc requires -f"; return 2; }
                ssh_run "$REMOTE_TARGET" "find $(shell_quote "$REMOTE_PATH/.zstd-splitter.incoming") -mindepth 1 -maxdepth 1 -type d -mtime +$NET_GC_DAYS -print -exec rm -rf {} + 2>/dev/null || :"
                ;;
            *) print_error "unknown network query mode: $query_mode"; return 2 ;;
        esac
    done <"$query_remote_list"
}

network_fetch_remote_manifest()
{
    fetch_spec=$1
    parse_remote_spec "$fetch_spec" || return
    FETCH_TARGET=$REMOTE_TARGET
    FETCH_PART=$REMOTE_PATH
    detect_engine_from_part "$FETCH_PART" >/dev/null 2>&1 || {
        print_error "relay source must identify a split part"
        return 2
    }
    FETCH_PREFIX=${FETCH_PART%??????}
    FETCH_ARCHIVE=${FETCH_PREFIX%.part.}
    FETCH_MANIFEST=$FETCH_ARCHIVE.manifest.sha256
    FETCH_LOCAL_MANIFEST=$NETWORK_TEMP_DIR/relay.manifest.sha256
    network_retry network_get_one "$FETCH_TARGET" "$FETCH_MANIFEST" "$FETCH_LOCAL_MANIFEST" || return 1
    make_work_dir "$NETWORK_TEMP_DIR"
    validate_manifest_structure "$FETCH_LOCAL_MANIFEST" || return 1
    safe_remove_tree "$WORK_DIR"; WORK_DIR=
}

network_stream_remote_file()
{
    stream_src_target=$1; stream_src_path=$2; stream_dst_target=$3; stream_dst_path=$4
    if [ "$NET_DRY_RUN" = yes ]; then
        print_info "[dry-run] relay $(shell_quote "$stream_src_target:$stream_src_path") -> $(shell_quote "$stream_dst_target:$stream_dst_path")"
        return 0
    fi
    make_network_temp_dir || return 1
    NETWORK_COUNTER=$((NETWORK_COUNTER + 1))
    stream_fifo=$NETWORK_TEMP_DIR/relay.$$.${NETWORK_COUNTER}.fifo
    mkfifo "$stream_fifo"
    ssh_run "$stream_src_target" "cat $(shell_quote "$stream_src_path")" >"$stream_fifo" &
    stream_src_pid=$!
    register_child_pid "$stream_src_pid"
    ssh_run "$stream_dst_target" "cat > $(shell_quote "$stream_dst_path")" <"$stream_fifo" &
    stream_dst_pid=$!
    register_child_pid "$stream_dst_pid"
    stream_status=0
    wait "$stream_src_pid" || stream_status=1
    unregister_child_pid "$stream_src_pid"
    wait "$stream_dst_pid" || stream_status=1
    unregister_child_pid "$stream_dst_pid"
    rm -f "$stream_fifo"
    [ "$stream_status" -eq 0 ]
}

network_relay_one()
{
    relay_source=$1; relay_destination=$2
    network_fetch_remote_manifest "$relay_source" || return 1
    relay_archive_name=$(basename "$FETCH_ARCHIVE")
    network_stage_begin "$relay_destination" "$relay_archive_name" || return 1
    relay_source_dir=$(dirname "$FETCH_PART")
    relay_selected=
    awk -F '\t' '$1 == "part" { print $2 "|" $3 "|" $4 }' "$FETCH_LOCAL_MANIFEST" >"$NETWORK_TEMP_DIR/relay-parts.$$.list"
    while IFS='|' read -r relay_suffix relay_size relay_sha; do
        relay_name=$(basename "$FETCH_PREFIX")$relay_suffix
        relay_src_path=$relay_source_dir/$relay_name
        relay_partial=$STAGE_DIR/$relay_name.partial
        relay_final=$STAGE_DIR/$relay_name
        ssh_run "$FETCH_TARGET" "test \"\$(wc -c < $(shell_quote "$relay_src_path") | tr -d ' ')\" = $(shell_quote "$relay_size"); test \"\$(sha256sum $(shell_quote "$relay_src_path") | awk '{print \$1}')\" = $(shell_quote "$relay_sha")" || return 1
        network_retry network_stream_remote_file "$FETCH_TARGET" "$relay_src_path" "$STAGE_TARGET" "$relay_partial" || return 1
        network_remote_verify_commit "$STAGE_TARGET" "$relay_partial" "$relay_final" "$relay_size" "$relay_sha" || return 1
        [ -n "$relay_selected" ] || relay_selected=$relay_name
    done <"$NETWORK_TEMP_DIR/relay-parts.$$.list"

    relay_manifest_base=$(basename "$FETCH_MANIFEST")
    network_upload_file_to_stage "$STAGE_TARGET" "$STAGE_DIR" "$FETCH_LOCAL_MANIFEST" || return 1
    ssh_run "$STAGE_TARGET" "mv -f $(shell_quote "$STAGE_DIR/$(basename "$FETCH_LOCAL_MANIFEST")") $(shell_quote "$STAGE_DIR/$relay_manifest_base")" || return 1
    network_remote_helper_action "$STAGE_TARGET" "$STAGE_DIR" "$relay_selected" "$relay_manifest_base" || return 1
    network_stage_publish "$STAGE_TARGET" "$STAGE_ROOT" "$STAGE_DIR" "$STAGE_BUNDLE" "$STAGE_LOCK" "$relay_archive_name"
}

# FEATURE_LEVEL 42: coordinates one remote source and one or more destinations;
# payload bytes stream through the coordinator without persistent local storage.
network_relay()
{
    [ "$FEATURE_LEVEL" -ge 42 ] || { print_error "relay requires version 4.2"; return 2; }
    remote_count=$(network_count_remotes)
    [ "$remote_count" -ge 2 ] || { print_error "relay requires a source and at least one destination via -R"; return 2; }
    relay_source=$(printf '%s\n' "$REMOTE_DESTINATIONS" | awk 'NR == 1 { print; exit }')
    relay_destinations=$(printf '%s\n' "$REMOTE_DESTINATIONS" | awk 'NR > 1')
    relay_total=$((remote_count - 1))
    relay_required=$relay_total
    [ "$NET_QUORUM" -gt 0 ] && relay_required=$NET_QUORUM
    relay_success=0
    relay_destination_list=$NETWORK_TEMP_DIR/relay-destinations.$$.list
    printf '%s
' "$relay_destinations" >"$relay_destination_list"
    while IFS= read -r relay_destination; do
        network_relay_one "$relay_source" "$relay_destination" && relay_success=$((relay_success + 1))
    done <"$relay_destination_list"
    print_info "Successful relay destinations: $relay_success/$relay_total (required: $relay_required)"
    [ "$relay_success" -ge "$relay_required" ]
}

# -- CLI dispatch --
interactive_mode()
{
    if [ ! -t 0 ]; then
        print_error "no action was specified and standard input is not interactive"
        usage >&2
        return 2
    fi

    printf '%s\n' \
        "tar compression splitter $PROGRAM_VERSION" \
        "1) Compress and split" \
        "2) Join parts" \
        "3) Extract archive or parts" \
        "4) Verify archive or parts" \
        "5) List compression engines" \
        "q) Quit"

    printf 'Select an action: '
    IFS= read -r menu_choice || return 1

    case $menu_choice in
        1|c|C)
            printf 'Source file, directory, or link: '
            IFS= read -r menu_source || return 1
            printf 'Compression engine [zstd]: '
            IFS= read -r menu_engine || return 1
            [ -n "$menu_engine" ] || menu_engine=zstd
            if ! ENGINE=$(normalize_engine "$menu_engine"); then
                print_error "unsupported compression engine: $menu_engine"
                return 2
            fi
            COMPRESSION_LEVEL=$(engine_default_level "$ENGINE")
            printf 'Maximum part size: '
            IFS= read -r PART_SIZE || return 1
            printf 'Enable strict SHA-256 integrity? [y/N] '
            IFS= read -r menu_integrity || return 1
            case $menu_integrity in y|Y|yes|YES|Yes) STRICT_INTEGRITY=1 ;; esac
            require_engine "$ENGINE" || return 1
            [ "$STRICT_INTEGRITY" -eq 0 ] || require_integrity_commands || return 1
            compress_and_split "$menu_source"
            ;;
        2|j|J)
            printf 'Path to any archive part: '
            IFS= read -r menu_part || return 1
            printf 'Require strict SHA-256 manifest? [y/N] '
            IFS= read -r menu_integrity || return 1
            case $menu_integrity in y|Y|yes|YES|Yes) STRICT_INTEGRITY=1 ;; esac
            [ "$STRICT_INTEGRITY" -eq 0 ] || require_integrity_commands || return 1
            join_parts "$menu_part"
            ;;
        3|x|X)
            printf 'Archive or part: '
            IFS= read -r menu_input || return 1
            printf 'Extraction destination [automatic]: '
            IFS= read -r DESTINATION || return 1
            printf 'Require strict SHA-256 manifest? [y/N] '
            IFS= read -r menu_integrity || return 1
            case $menu_integrity in y|Y|yes|YES|Yes) STRICT_INTEGRITY=1 ;; esac
            [ "$STRICT_INTEGRITY" -eq 0 ] || require_integrity_commands || return 1
            extract_archive "$menu_input"
            ;;
        4|v|V)
            printf 'Archive or part: '
            IFS= read -r menu_input || return 1
            printf 'Require strict SHA-256 manifest? [y/N] '
            IFS= read -r menu_integrity || return 1
            case $menu_integrity in y|Y|yes|YES|Yes) STRICT_INTEGRITY=1 ;; esac
            [ "$STRICT_INTEGRITY" -eq 0 ] || require_integrity_commands || return 1
            verify_input "$menu_input"
            ;;
        5|e|E) list_engines ;;
        q|Q) return 0 ;;
        *) print_error "unknown menu selection"; return 2 ;;
    esac
}

# Normalizes long aliases, parses POSIX short options with getopts, dispatches one
# action, and preserves documented exit-status semantics.
main()
{
    runtime_sanitize_path || return 1
    if [ "$#" -eq 0 ]; then
        require_base_commands
        interactive_mode
        return
    fi

    case ${1-} in
        --help) usage; return 0 ;;
        --engines) list_engines; return 0 ;;
        --version) printf '%s %s
' "$PROGRAM_NAME" "$PROGRAM_VERSION"; return 0 ;;
    esac

    OPTIND=1
    while getopts ':cjxvPGYQ:R:O:F:e:s:l:T:im:d:fEh' option
    do
        case $option in
            c|j|x|v|P|G|Y)
                if [ -n "$ACTION" ]; then
                    print_error "only one action may be specified"
                    usage >&2
                    return 2
                fi
                case $option in
                    c) ACTION=compress ;;
                    j) ACTION=join ;;
                    x) ACTION=extract ;;
                    v) ACTION=verify ;;
                    P) ACTION=push ;;
                    G) ACTION=pull ;;
                    Y) ACTION=relay ;;
                esac
                ;;
            Q)
                [ -z "$ACTION" ] || { print_error "only one action may be specified"; return 2; }
                ACTION=query; NETWORK_QUERY_MODE=$OPTARG
                ;;
            R) append_line REMOTE_DESTINATIONS "$OPTARG" ;;
            O) append_line NETWORK_OPTIONS "$OPTARG" ;;
            F) NETWORK_CONFIG=$OPTARG ;;
            e) ENGINE=$OPTARG; ENGINE_SET=1 ;;
            s) PART_SIZE=$OPTARG ;;
            l) COMPRESSION_LEVEL=$OPTARG ;;
            T) THREADS=$OPTARG; THREADS_SET=1 ;;
            i) STRICT_INTEGRITY=1 ;;
            m) MANIFEST_FILE=$OPTARG ;;
            d) DESTINATION=$OPTARG ;;
            f) FORCE=1 ;;
            E) list_engines; return 0 ;;
            h) usage; return 0 ;;
            :) print_error "option -$OPTARG requires an argument"; usage >&2; return 2 ;;
            \?) print_error "unknown option: -$OPTARG"; usage >&2; return 2 ;;
        esac
    done
    shift $((OPTIND - 1))

    if [ -n "$NETWORK_CONFIG" ]; then
        NETWORK_CONFIG=$(absolute_existing_path "$NETWORK_CONFIG") || { print_error "cannot resolve network configuration file"; return 1; }
    fi
    if [ -n "$MANIFEST_FILE" ]; then
        MANIFEST_FILE=$(absolute_existing_path "$MANIFEST_FILE") || { print_error "cannot resolve manifest file"; return 1; }
    fi

    if [ -z "$ACTION" ]; then
        print_error "one action is required"
        usage >&2
        return 2
    fi

    require_base_commands
    network_needed=0
    case $ACTION in push|pull|query|relay) network_needed=1 ;; esac
    [ -z "$REMOTE_DESTINATIONS" ] || network_needed=1
    if [ "$network_needed" -eq 1 ]; then
        network_initialize || return
    fi
    if [ "$STRICT_INTEGRITY" -eq 1 ]; then require_integrity_commands; fi

    case $ACTION in
        compress)
            if ! ENGINE=$(normalize_engine "$ENGINE"); then print_error "unsupported compression engine"; list_engines >&2; return 2; fi
            [ -z "$COMPRESSION_LEVEL" ] && COMPRESSION_LEVEL=$(engine_default_level "$ENGINE")
            validate_engine_level "$ENGINE" "$COMPRESSION_LEVEL" || { print_error "invalid compression level for engine $ENGINE: $COMPRESSION_LEVEL"; return 2; }
            validate_nonnegative_integer "$THREADS" || { print_error "thread count must be a non-negative integer"; return 2; }
            if [ "$THREADS_SET" -eq 1 ] && ! engine_supports_threads "$ENGINE"; then print_error "option -T is not supported by engine $ENGINE"; return 2; fi
            [ -z "$PART_SIZE" ] && { print_error "option -s SIZE is required with -c"; return 2; }
            [ -z "$MANIFEST_FILE" ] || { print_error "option -m is not valid with -c"; return 2; }
            [ -z "$DESTINATION" ] || { print_error "option -d is not valid with -c"; return 2; }
            [ "$#" -eq 1 ] || { print_error "compression requires exactly one SOURCE operand"; return 2; }
            if [ -n "$REMOTE_DESTINATIONS" ] && [ "$STRICT_INTEGRITY" -eq 0 ]; then
                STRICT_INTEGRITY=1
                require_integrity_commands
                print_info "Strict integrity enabled automatically for network publication."
            fi
            require_engine "$ENGINE" || return 1
            compress_and_split "$1" || return
            if [ -n "$REMOTE_DESTINATIONS" ]; then
                network_push_many "${LAST_PART_PREFIX}aaaaaa"
            fi
            ;;
        join)
            [ "$ENGINE_SET" -eq 0 ] || { print_error "option -e is not valid with -j"; return 2; }
            [ -z "$PART_SIZE" ] || { print_error "option -s is not valid with -j"; return 2; }
            [ -z "$COMPRESSION_LEVEL" ] || { print_error "option -l is not valid with -j"; return 2; }
            [ "$THREADS_SET" -eq 0 ] || { print_error "option -T is not valid with -j"; return 2; }
            [ -z "$DESTINATION" ] || { print_error "option -d is not valid with -j"; return 2; }
            [ -z "$REMOTE_DESTINATIONS" ] || { print_error "option -R is not valid with -j"; return 2; }
            [ "$#" -eq 1 ] || { print_error "joining requires exactly one PART operand"; return 2; }
            [ -z "$MANIFEST_FILE" ] || [ "$STRICT_INTEGRITY" -eq 1 ] || { print_error "option -m requires -i"; return 2; }
            join_parts "$1"
            ;;
        extract)
            [ "$ENGINE_SET" -eq 0 ] || { print_error "option -e is not valid with -x"; return 2; }
            [ -z "$PART_SIZE" ] || { print_error "option -s is not valid with -x"; return 2; }
            [ -z "$COMPRESSION_LEVEL" ] || { print_error "option -l is not valid with -x"; return 2; }
            [ "$THREADS_SET" -eq 0 ] || { print_error "option -T is not valid with -x"; return 2; }
            [ -z "$REMOTE_DESTINATIONS" ] || { print_error "option -R is not valid with -x"; return 2; }
            [ "$#" -eq 1 ] || { print_error "extraction requires exactly one INPUT operand"; return 2; }
            [ -z "$MANIFEST_FILE" ] || [ "$STRICT_INTEGRITY" -eq 1 ] || { print_error "option -m requires -i"; return 2; }
            extract_archive "$1"
            ;;
        verify)
            [ "$ENGINE_SET" -eq 0 ] || { print_error "option -e is not valid with -v"; return 2; }
            [ -z "$PART_SIZE" ] || { print_error "option -s is not valid with -v"; return 2; }
            [ -z "$COMPRESSION_LEVEL" ] || { print_error "option -l is not valid with -v"; return 2; }
            [ "$THREADS_SET" -eq 0 ] || { print_error "option -T is not valid with -v"; return 2; }
            [ -z "$DESTINATION" ] || { print_error "option -d is not valid with -v"; return 2; }
            [ -z "$REMOTE_DESTINATIONS" ] || { print_error "option -R is not valid with -v"; return 2; }
            [ "$#" -eq 1 ] || { print_error "verification requires exactly one INPUT operand"; return 2; }
            [ -z "$MANIFEST_FILE" ] || [ "$STRICT_INTEGRITY" -eq 1 ] || { print_error "option -m requires -i"; return 2; }
            verify_input "$1"
            ;;
        push)
            [ "$#" -eq 1 ] || { print_error "push requires exactly one local INPUT operand"; return 2; }
            [ "$STRICT_INTEGRITY" -eq 1 ] || [ "$NET_ALLOW_UNVERIFIED" = yes ] || { print_error "push requires -i"; return 2; }
            network_push_many "$1"
            ;;
        pull)
            [ "$#" -eq 0 ] || { print_error "pull takes its remote input from -R and no operand"; return 2; }
            [ "$STRICT_INTEGRITY" -eq 1 ] || { print_error "pull requires -i"; return 2; }
            remote_count=$(network_count_remotes)
            [ "$remote_count" -eq 1 ] || { print_error "pull requires exactly one -R remote input"; return 2; }
            network_pull "$REMOTE_DESTINATIONS"
            ;;
        query)
            [ "$#" -eq 0 ] || { print_error "network query takes no operand"; return 2; }
            network_query "$NETWORK_QUERY_MODE"
            ;;
        relay)
            [ "$#" -eq 0 ] || { print_error "relay uses -R specifications and takes no operand"; return 2; }
            [ "$STRICT_INTEGRITY" -eq 1 ] || { print_error "relay requires -i"; return 2; }
            network_relay
            ;;
    esac
}

main "$@"
