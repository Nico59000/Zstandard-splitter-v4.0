# Functional and documentation audit — 4.0

Audit date: 2026-07-27

## Result

- Script syntax: checked with `dash -n`.
- Built-in help: regenerated from the executable and pinned in
  `docs/BUILTIN_HELP.txt`.
- Code documentation: implementation map, section headers, contracts, and
  `docs/CODE-ARCHITECTURE.md` added or refreshed.
- Feature boundary: verified against `docs/VERSION-MATRIX.md` by
  `tests/feature-matrix-test.sh`.
- Local integrity cycle: covered by `tests/smoke-test.sh`.
- Network command construction and version gates: covered by
  `tests/network-dry-run.sh` and `tests/mock-network-test.sh`.
- Portability adapters: not part of this original feature release.

## Capability statement

This package implements feature level **40**. Maintenance suffix `.1` changes
portability assumptions only and does not enable capabilities from the next feature
milestone.

## Known validation limit

The package tests use local execution and a mocked SSH/SFTP environment. They do not
claim validation on every physical Linux, macOS, OpenBSD, FreeBSD, or NetBSD host.
