# Network options — zstd-splitter 4.0

This document is the source of truth for `-O NAME=VALUE` and `-F FILE`.

## Transaction invariant

Remote output moves from private staging to the final bundle only after the
requested size, SHA-256, codec, and optional content checks succeed.

## Baseline 4.0 settings

- transport: `transport`, `resume`, `bandwidth`
- publication: `atomic`, `lock`, `retain`, `cleanup`
- verification: `remote-verify`, `remote-extract`, `remote-fsync`, `allow-unverified`
- SSH: `identity`, `port`, `jump`, `known-hosts`, `host-key-policy`
- routing: `address-family`, `bind-interface`, `bind-address`
- liveness: `connect-timeout`, `server-alive-interval`, `server-alive-count`
- retry: `retry`, `retry-delay`, `retry-backoff`
- diagnostics: `dry-run`

## Version boundary

Profiles, parallel transfer, SFTP-window tuning, connection reuse, and MTU
diagnostics are rejected at feature level 40.

## Administration boundary

Fan-out, quorum, relay, health, inventory, garbage collection, and audit
logging are rejected below feature level 42.

## Portability boundary

`-Q portability` belongs to the matching `.1` maintenance release.

## Safety limits

- remote paths are absolute and validated;
- host-key checking cannot be disabled;
- `remote-verify=none` requires `allow-unverified=yes`;
- newlines in network file names are refused;
- arbitrary autonomous multi-hop routing is not implemented.
