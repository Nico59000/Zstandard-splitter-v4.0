# Testing — zstd-splitter 4.0

Run from the package root:

```sh
sh tests/eigiib-documentation-test.sh
sh tests/feature-matrix-test.sh
sh tests/smoke-test.sh
sh tests/network-dry-run.sh
sh tests/mock-network-test.sh
sh tests/runtime-static-audit.sh
sh tests/runtime-security-test.sh
sh tests/packaging-security-test.sh
```

## Contract groups

- **documentation:** EIGIIB structure, help snapshot, and public feature claims;
- **local:** strict create, verify, join, extract, and rollback;
- **network:** command construction and mocked transactional SSH/SFTP;
- **runtime security:** hostile inputs, signals, staging, quoting, and cleanup;
- **packaging:** privileged path validation and checksum verification.

Mocked network tests are deterministic integration tests, not a claim of execution
on every physical operating system, OpenSSH release, or network path.
