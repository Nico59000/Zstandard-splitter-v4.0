# zstd-splitter 4.0

`zstd-splitter` is a POSIX `/bin/sh` utility for tar-compatible compression,
splitting, strict integrity, reconstruction, extraction, and SSH/SFTP transfer.

## Quick start

```sh
zstd-splitter -c -i -s 1G /srv/data
zstd-splitter -v -i data.tar.zst.part.aaaaaa
zstd-splitter -x -i -d restored data.tar.zst.part.aaaaaa
zstd-splitter -P -i -R backup@nas:/srv/backups data.tar.zst.part.aaaaaa
```

Supported engines: `zstd`, `gzip`, `bzip2`, `xz`, `lzma`, `lzip`, `lzop`,
and `lz4`, when installed.

## Release scope

| Layer | This package |
|---|---|
| 3.0 integrity | source inventory, archive SHA-256, per-part SHA-256, restored-tree validation |
| 4.0 transport | SSH/SFTP staging, retry, verification, locking, atomic publication |
| 4.0 focus | transactional single-destination SSH/SFTP |
| Not enabled | profiles, parallel SFTP, MTU diagnostics, fan-out, quorum, relay, administration |

Arbitrary autonomous multi-hop vector routing is not implemented in 4.x.

## Integrity and runtime model

- Strict mode (`-i`) validates source, archive, parts, and restored content.
- Local and remote publication use private staging and rollback.
- Host-key checking defaults to `strict`; forwarding is not enabled.
- SHA-256 proves integrity, not manifest origin. Protect or sign manifests.

Detailed contracts: `docs/INTEGRITY-MANIFEST.md`, `docs/RUNTIME-SECURITY.md`,
and `docs/SECURITY.md`.

## Installation

```sh
sudo sh packaging/install.sh
man zstd-splitter
```

## Documentation and tests

`docs/INDEX.md` routes operators and maintainers to the single source of truth.
Code and documentation follow EIGIIB: **Explicit Is Good, Implicit Is Better;**
**too explicit is never good.** See `docs/EIGIIB.md`.

```sh
sh tests/eigiib-documentation-test.sh
sh tests/feature-matrix-test.sh
sh tests/smoke-test.sh
sh tests/network-dry-run.sh
sh tests/mock-network-test.sh
sh tests/runtime-static-audit.sh
sh tests/runtime-security-test.sh
```

Mocked SSH/SFTP tests validate deterministic transactions; they do not claim
coverage of every physical operating system or network.
