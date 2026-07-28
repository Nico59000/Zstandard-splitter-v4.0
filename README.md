# zstd-splitter 4.0

`zstd-splitter` is a POSIX `/bin/sh` utility for tar-compatible compression,
splitting, strict integrity, reconstruction, extraction, and version-gated
SSH/SFTP administration. This README is cumulative: it describes the inherited
3.0 and 4.0 foundations before the capabilities specific to this package.

## Release lineage

- **3.0 — strict integrity:** canonical source inventory, compressed-archive SHA-256, per-part SHA-256, reconstruction checks, extraction, and restored-content validation.
- **4.0 — transactional SSH/SFTP:** push, pull, staging, locking, remote verification, optional remote extraction, and atomic bundle publication.
- **4.1 boundary:** profiles, parallelism, window/buffer tuning, connection-reuse controls, and MTU diagnostics are intentionally unavailable.
- **4.2 boundary:** fan-out, quorum, relay, health, inventory, garbage collection, and JSON Lines audit logging are intentionally unavailable.
- **4.0 — original feature release:** uses the GNU-oriented dependency profile; use the matching `.1` release for macOS/BSD abstraction.

## Local archive layer inherited from 3.0

Supported engines are `zstd`, `gzip`, `bzip2`, `xz`, `lzma`, `lzip`, `lzop`, and
`lz4`, when the corresponding external program is installed.

```sh
# Create and split
zstd-splitter -c -i -e zstd -s 1G /srv/data

# Verify, join, or extract
zstd-splitter -v -i data.tar.zst.part.aaaaaa
zstd-splitter -j -i data.tar.zst.part.aaaaaa
zstd-splitter -x -i -d restored data.tar.zst.part.aaaaaa
```

Strict mode records and verifies:

1. the canonical source inventory;
2. the aggregate SHA-256 of that inventory;
3. the compressed archive size and SHA-256;
4. every split part size and SHA-256;
5. the restored source inventory after extraction.

## 4.0 transactional SSH/SFTP layer

```sh
# Compress and publish immediately
zstd-splitter -c -i -s 1G \
  -R backup@nas:/srv/backups /srv/data

# Push and pull an existing strict part set
zstd-splitter -P -i -R backup@nas:/srv/backups \
  data.tar.zst.part.aaaaaa

zstd-splitter -G -i \
  -R backup@nas:/srv/backups/data.tar.zst.bundle/data.tar.zst.part.aaaaaa \
  -d downloaded
```

The transaction uses a remote incoming directory, optional archive lock, per-file
size and SHA-256 verification, remote archive reconstruction, codec-native stream
verification, optional content extraction/validation, and atomic bundle publication.
Host-key checking defaults to strict; interactive authentication and forwarding are
not enabled by the script.

## 4.1 capability boundary

This package uses the fixed safe single-worker transport. It rejects named
profiles other than the implicit `safe` profile, parallel jobs, custom SFTP
windows, stream-block tuning, user connection-reuse tuning, route/MTU diagnostics,
and adaptive tuning.

## 4.2 capability boundary

Only one effective remote is accepted per operation. Fan-out, quorum, relay,
health, inventory, garbage collection, and JSON Lines audit logging are rejected.
Arbitrary autonomous multi-hop vector routing is not implemented in any 4.x
package.

## Platform dependency profile

This original feature release expects the GNU-oriented commands documented in the
package, including `sha256sum`. The corresponding `.1` maintenance package keeps
the same feature level while adding macOS/BSD SHA-256, `stat`, `tar`, route, and
`ping` abstractions as applicable.

## Configuration

Use repeated `-O NAME=VALUE` options or `-F FILE`. The version-specific accepted
options are documented in `docs/NETWORK-OPTIONS.md` and represented by
`config/network.conf.example`.

## Installation

```sh
sudo sh packaging/install.sh
man zstd-splitter
```

## Code documentation and validation

The `.sh` file contains an implementation map, section headers, and contracts on
stateful and security-sensitive functions. Maintainer documentation is in:

- `docs/CODE-ARCHITECTURE.md`;
- `docs/VERSION-MATRIX.md`;
- `docs/FEATURE-MATRIX-AUDIT.md`.

Run:

```sh
sh tests/documentation-test.sh
sh tests/feature-matrix-test.sh
sh tests/smoke-test.sh
sh tests/network-dry-run.sh
sh tests/mock-network-test.sh
```

The mocked SSH/SFTP tests validate deterministic command and transaction behavior;
they do not claim testing on every physical operating system or network.


## Runtime security audit revision

Package revision `runtime-security-audit-r2` incorporates the 2026-07-28
execution-security review without changing the public feature level of
version 4.0. It hardens shell quoting, temporary state, signal cleanup,
extraction staging, manifest ambiguity checks, transactional publication,
pull verification, remote-stage cleanup, persistent SSH control-session
cleanup, and terminal-safe diagnostics.

Run:

```sh
sh tests/runtime-static-audit.sh
sh tests/runtime-security-test.sh
```

The complete threat model and residual limits are documented in
[`docs/RUNTIME-SECURITY.md`](docs/RUNTIME-SECURITY.md). SHA-256 provides
integrity, not origin authentication; security-sensitive deployments should
protect or sign manifests independently.
