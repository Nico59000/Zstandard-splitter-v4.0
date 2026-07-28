# Changelog


## Runtime security audit revision — 2026-07-28

- Correct POSIX remote-shell quoting and add command-injection regression tests.
- Add private extraction and pull staging with transactional publication and rollback.
- Register cleanup traps across every branch, including 4.0/4.0.1.
- Abort active remote staging and close persistent SSH control masters on exit.
- Ignore ambient `TMPDIR`; add trusted `ZSTD_SPLITTER_TMPDIR` and private control state.
- Reject special source objects, control-character paths, ambiguous manifests, and unsafe jump targets.
- Escape terminal and JSON control bytes; protect inventory and garbage-collection output.
- Add static and adversarial runtime-security test suites and a full security report.
- Harden privileged install/uninstall helpers and test symlink-safe removal.

## Documentation and feature-matrix audit — 2026-07-27

- Document the internal `.sh` architecture and security-sensitive function contracts.
- Make built-in help and manpage expose only capabilities available in this release.
- Add executable documentation and feature-matrix regression tests.
- Pin the six-release capability matrix, including the absence of distributed
  multi-hop vector routing.

## 4.0 — 2026-07-26

- Transactional SSH/SFTP push and pull.
- Strict remote SHA-256 verification using the same script.
- Remote staging, per-archive locks and atomic bundle publication.
- Optional remote extraction after validation.
- Retry, keepalive, bastion, identity and host-key controls.

- Corrected recursive strict-inventory path isolation for sibling filesystem objects.
