# EIGIIB documentation standard

> **Explicit Is Good, Implicit Is Better. Too explicit is never good.**

EIGIIB keeps the contract visible without narrating the implementation.

## What must be explicit

- public inputs, outputs, exit status, and compatibility boundaries;
- integrity, security, transaction, and observer-channel invariants;
- behavior that is surprising, destructive, version-gated, or irreversible;
- the reason for a non-obvious workaround or portability branch.

## What should remain implicit

- mechanics already clear from names and control flow;
- line-by-line paraphrases of shell commands;
- exhaustive function catalogs;
- option tables copied into several documents;
- history that belongs in `CHANGELOG.md`.

## Documentation layers

| Layer | Purpose | Source of truth |
|---|---|---|
| `-h` | command discovery | `usage()` |
| man page | public operational contract | `man/man1/zstd-splitter.1` |
| `README.md` | onboarding and release scope | package root |
| protocol/security docs | exact specialized contracts | `docs/` |
| code comments | rationale and invariants | `src/zstd-splitter.sh` |
| tests | executable behavior | `tests/` |

A fact is fully stated once, then linked. Security wording may be repeated only
where omission would make a local procedure unsafe.

## Review rule

A change passes EIGIIB when a maintainer can find the contract quickly, follow the
code by names and sections, and remove no comment without losing rationale.
`tests/eigiib-documentation-test.sh` enforces the package-level structure; human
review decides whether a comment is useful.
