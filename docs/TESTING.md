# Testing

Run tests from the package root.

```sh
sh tests/documentation-test.sh
sh tests/feature-matrix-test.sh
sh tests/smoke-test.sh
sh tests/network-dry-run.sh
sh tests/mock-network-test.sh
```

Maintenance releases (`*.1`) also provide:

```sh
sh tests/portability-test.sh
sh packaging/verify-checksums.sh
```

## Test roles

- `documentation-test.sh`: checks `VERSION`, `PROGRAM_VERSION`, `FEATURE_LEVEL`,
  built-in help capture, required documentation files, and version-specific help.
- `feature-matrix-test.sh`: verifies positive and negative capability gates.
- `smoke-test.sh`: exercises strict compression, splitting, reconstruction,
  extraction, and restored-content comparison.
- `network-dry-run.sh`: checks network parsing and command construction without a host.
- `mock-network-test.sh`: simulates SSH/SFTP staging, verification, publication,
  and pull; maintenance variants exercise portable remote SHA-256 selection.
- `portability-test.sh`: substitutes supported SHA-256/stat implementations.

## Validation boundary

Mocked tests are deterministic and suitable for regression testing, but they do
not replace execution against physical Linux, macOS, OpenBSD, FreeBSD, and NetBSD
hosts with real OpenSSH servers and network paths.


## Runtime security audit

```sh
sh tests/runtime-static-audit.sh
sh tests/runtime-security-test.sh
sh tests/packaging-security-test.sh
```

The static test pins the execution invariants in the source. The adversarial
test covers injection, hostile environments, private modes, special objects,
traversal, ambiguous manifests, signals, rollback, remote quoting, collision
cleanup, corrupt pulls, and persistent SSH control-session cleanup.
