# Code architecture — zstd-splitter 4.0

`src/zstd-splitter.sh` is a POSIX `/bin/sh` program with `FEATURE_LEVEL=40`.
Later-feature functions may remain in the shared source skeleton, but CLI parsing
and `network_validate_settings` make them unreachable below their release level.

## Execution layers

1. **Process bootstrap** — locale, private umask, hostile environment removal,
   runtime variables, and feature constants.
2. **Observer layer** — progress and structured error channels where available;
   dedicated-descriptor writes are isolated from operation status.
3. **Runtime-security primitives** — trusted `PATH`, temporary-parent policy,
   canonical paths, destructive-path guards, child registries, special-object
   refusal, archive-member validation, and transactional publication helpers.
4. **Engine and metadata abstraction** — compression registry, levels, thread
   policy, file-size backend, and SHA-256 backend.
5. **Strict manifest layer** — canonical source records, scalar uniqueness,
   per-part hashes, whole-archive hash, and restored-tree comparison.
6. **Local workflow layer** — compress/split, verify, join, extract, staging,
   backup, commit, rollback, and signal cleanup.
7. **Network configuration layer** — option parsing, profile application,
   capability gates, remote-target/path grammar, and security defaults.
8. **SSH/SFTP transport layer** — safely quoted remote commands, batch files,
   retries, partial uploads, receiver-side hash/size verification, and control
   session tracking.
9. **Remote transaction layer** — staging, locks, helper verification, optional
   extraction, atomic publication, active-stage abort, and rollback.
10. **Administration layer** — only at feature level 42: fan-out, quorum, relay,
    inventory, health, garbage collection, and audit events.
11. **CLI dispatcher** — action validation, incompatible-option rejection, and
    exact operand cardinality.

## Security-sensitive function groups

- `runtime_sanitize_path`, `secure_tmp_parent`, `safe_remove_tree`
- `source_type_walk`, `validate_archive_members`
- `publish_staged_files`, `publish_generated_set`
- `validate_manifest_structure`, `validate_parts_against_manifest`
- `shell_quote`, `sftp_quote`, `validate_remote_target`, `validate_jump_spec`
- `network_stage_begin`, `network_stage_abort`, `network_stage_publish`
- `network_abort_active_stage`, `network_close_control_masters`
- `cleanup`, `handle_signal`, `terminate_children`

## Maintainer invariants

- Never introduce `eval`, unquoted user data, or executable manifest content.
- Never publish local or remote output before validation succeeds.
- Every background PID must be registered and unregistered after `wait`.
- Every remote stage must be either published or aborted.
- Every destructive recursive removal must pass `safe_remove_tree` locally or
  use a path created from a validated absolute remote root.
- Structured output must escape all JSON control characters and must not alter
  the action exit status when a consumer closes its descriptor.
- Any new feature must be added to the feature matrix and rejected below its
  intended `FEATURE_LEVEL`.

See `RUNTIME-SECURITY.md` for the audited threat model and residual risks.
