# Code architecture — zstd-splitter 4.0

## Scope

The executable is a single POSIX `/bin/sh` file. It deliberately keeps local
archive processing and network orchestration in one source so the same strict
manifest and codec rules can be reused locally and on a remote helper.

- Program version: `4.0`
- Feature level: `40`
- Portability maintenance layer: `no`
- Network profiles/tuning: `no`
- 4.2 administration layer: `no`

## Source sections

1. **CLI and diagnostics** — `usage`, `list_engines`, `print_error`, `print_info`.
2. **Lifecycle** — traps, dependency checks, temporary directories, overwrite policy.
3. **Codec registry** — engine aliases, extensions, levels, worker support.
4. **Portable integrity primitives** — file sizes and SHA-256 adapters.
5. **Manifest model** — canonical paths, regular files, directories, symbolic links,
   archive identity, sizes, and aggregate/source hashes.
6. **Local workflows** — create/split, join, verify, and extract.
7. **Network configuration** — profiles, `NAME=VALUE` overlays, validation, and gates.
8. **Transport** — command construction, SFTP batch files, SSH streams, retry/backoff.
9. **Remote transaction** — preflight, staging, per-file verification, helper validation,
   atomic publication, cleanup, and pull.
10. **Advanced network layer** — diagnostics and version-gated administration.
11. **Entry point** — interactive menu, aliases, `getopts`, and dispatch.

## Important state

- `FEATURE_LEVEL` is the executable capability boundary (`40`, `41`, or `42`).
- `STRICT_INTEGRITY` requires the manifest checks before publication or extraction.
- `REMOTE_DESTINATIONS` is newline-delimited, never evaluated as shell code.
- `NETWORK_TEMP_DIR` contains generated batch files, manifests, helper scripts, and
  control sockets; `cleanup` removes it on normal exit and signals.
- `LAST_PART_PREFIX`, `LAST_MANIFEST`, and `LAST_ARCHIVE` connect local creation to
  an optional immediate network push.

## Invariants

- A compressed set is published only after all producer processes succeed.
- Strict creation inventories the source before and after compression and rejects a
  source that changes in flight.
- Strict reconstruction verifies each part and the aggregate archive hash.
- Strict extraction regenerates the canonical source inventory.
- Remote files use `.partial` names until size and SHA-256 verification succeeds.
- Remote bundle publication occurs only after helper verification.
- Lower releases reject later features even though the shared source contains dormant
  helper functions for those milestones.

## Feature-specific notes

- Only the 4.0 transactional single-destination network layer is callable. Advanced tuning and 4.2 administration functions are hard-gated.

## Portability boundary

This original feature release keeps its GNU-oriented utility assumptions. The corresponding `.1` package adds macOS/BSD abstraction without changing the feature level.

## Maintainer checks

```sh
sh -n src/zstd-splitter.sh
sh tests/documentation-test.sh
sh tests/feature-matrix-test.sh
sh tests/smoke-test.sh
sh tests/network-dry-run.sh
```

Maintenance releases also run `tests/portability-test.sh`. Network behavior is
covered by `tests/mock-network-test.sh`; it is a deterministic simulation and does
not replace a physical OpenSSH interoperability test.
