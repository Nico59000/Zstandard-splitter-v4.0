# Network options — zstd-splitter 4.0

## Transaction model

1. Validate the strict manifest and local input.
2. Preflight the remote host and destination.
3. Create a uniquely named incoming staging directory.
4. Upload or stream each file using a `.partial` name.
5. Verify size and SHA-256 before the final staging name is exposed.
6. Reconstruct and validate the archive remotely.
7. Optionally extract and validate the source inventory.
8. Atomically publish `ARCHIVE.bundle` and release the lock.

## Baseline options available in every 4.x package

### Connection and security

- `transport=sftp|ssh-stream`
- `identity=FILE`, `port=PORT`, `jump=HOST`
- `known-hosts=FILE`, `host-key-policy=strict|accept-new`
- `address-family=any|inet|inet6`
- `bind-interface=INTERFACE`, `bind-address=ADDRESS`
- `ssh-compression=yes|no`

### Reliability and publication

- `resume=yes|no`, `atomic=yes|no`, `lock=yes|no`
- `remote-verify=parts|archive|content|all|none`
- `remote-extract=PATH|auto`, `remote-fsync=yes|no`
- `retry=N`, `retry-delay=SECONDS`, `retry-backoff=linear|exponential`
- `connect-timeout=SECONDS`
- `server-alive-interval=SECONDS`, `server-alive-count=COUNT`
- `cleanup=success|always|never`, `retain=parts|archive|all`
- `allow-unverified=yes|no`, `dry-run=yes|no`
- `bandwidth=KBIT/S`

## 4.1 options unavailable here

The release rejects non-safe profiles, multiple jobs, custom SFTP windows,
stream-block tuning, user connection-reuse settings, MTU diagnostics, and adaptive
tuning.

## 4.2 options unavailable here

Repeated effective remotes, quorum, audit logging, `gc-days`, relay, health,
inventory, and garbage collection are rejected.

## Portability query

`-Q portability` is not part of this original feature release. Use the matching
`.1` maintenance package.

## Security limits

- Remote paths must be absolute.
- Host-key checking cannot be disabled by this interface.
- Manifests are parsed as data, not sourced as shell code.
- `remote-verify=none` requires the explicit `allow-unverified=yes` escape hatch.
- Arbitrary distributed multi-hop vector routing is not implemented.
