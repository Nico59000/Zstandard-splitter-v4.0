# Code architecture — zstd-splitter 4.0

The program is one POSIX `/bin/sh` translation unit with `FEATURE_LEVEL=40`.
The structure is linear by design:

```text
bootstrap -> safeguards -> engines -> manifest -> local workflows
          -> network policy -> SSH/SFTP transactions -> gated administration -> CLI
```

## Boundaries

- **Observers** report state but never decide operation success.
- **Safeguards** own path validation, private temporary state, child cleanup, and
  transactional publication.
- **Manifest code** treats metadata as data and validates it before use.
- **Local workflows** create or consume archives only through validated staging.
- **Network policy** parses options and enforces `FEATURE_LEVEL`.
- **Transport** builds SSH/SFTP commands from validated, quoted components.
- **Remote transactions** own staging, locks, verification, publish, and rollback.

Administration and relay code is present only in the shared skeleton and remains gated.

## Invariants

1. No manifest content is evaluated as shell code.
2. No output replaces a prior valid output before verification succeeds.
3. Every child and remote stage is registered before it can outlive its caller.
4. Destructive paths are absolute, validated, and confined to known staging roots.
5. Dedicated observer channels may fail without changing operation status.
6. A feature is documented only where its version gate permits execution.

## Navigation

The section markers in `src/zstd-splitter.sh` identify subsystem boundaries.
Function names carry routine detail; comments are reserved for rationale, hazards,
and portability exceptions. Exact protocols live in their dedicated documents,
not in this architecture overview.

See `EIGIIB.md`, `VERSION-MATRIX.md`, and `RUNTIME-SECURITY.md`.
