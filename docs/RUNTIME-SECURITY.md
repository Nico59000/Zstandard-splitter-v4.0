# Runtime security audit — zstd-splitter 4.0

Audit date: 2026-07-28  
Package revision: `runtime-security-audit-r2`

## Scope

This audit covers the executable shell code, local archive operations,
manifest parsing, temporary files, signal handling, extraction and publication
transactions, SSH/SFTP command construction, retry behaviour, remote staging,
cleanup, and the package's test harness. 4.0 transactional SSH/SFTP.

The audit is a best-effort engineering review, not a formal proof that no
vulnerability exists. Runtime safety also depends on the shell, `tar`, the
selected compression engine, OpenSSH, filesystem semantics, account
privileges, and the trustworthiness of local and remote hosts.

## Threat model

The hardened defaults are intended to resist:

- shell metacharacters, apostrophes, whitespace, and option-like SSH targets;
- hostile inherited `PATH` entries and compressor or `tar` environment options;
- predictable or shared temporary paths;
- archive path traversal and publication into a destination before validation;
- FIFO, device, socket, and other special-file sources;
- interruption during compression, extraction, local publication, upload, or
  remote atomic publication;
- corrupted parts, archives, manifests, and interrupted downloads;
- terminal-control injection through status, error, inventory, or audit data;
- leaked SSH control masters, remote locks, and remote staging directories.

It does not assume that an attacker already controls the same Unix account,
root, the remote SSH account, the selected compressor binary, or the kernel.

## Findings corrected

| ID | Severity | Corrective control |
|---|---|---|
| RSE-001 | Critical | Correct POSIX single-quote escaping for every interpolated remote shell path; adversarial apostrophe/semicolon execution test. |
| RSE-002 | High | Extraction first lists and validates archive members, extracts into a private staging tree, verifies strict content when enabled, and publishes transactionally. |
| RSE-003 | High | Split-part and manifest replacement use backup-and-rollback publication; a failed intermediate `mv` restores the previous complete set. |
| RSE-004 | High | Pull operations download into private staging, validate parts/archive/manifest, then publish; corrupt downloads never replace existing local files. |
| RSE-005 | High | `umask 077`, private `mktemp` directories, private SSH control sockets, and an explicit trusted `ZSTD_SPLITTER_TMPDIR`; ambient `TMPDIR` is ignored. |
| RSE-006 | High | Global EXIT/HUP/INT/QUIT/TERM traps are active in every branch, including 4.0 and 4.0.1; direct pipeline children are registered, terminated, and waited for. |
| RSE-007 | High | Active remote staging is registered and aborted on abnormal exit; persistent SSH control masters are explicitly closed before private state is removed. |
| RSE-008 | Medium | Source trees reject FIFO/device/socket objects and control-character paths or symlink targets; human diagnostics and structured protocols escape control bytes. |
| RSE-009 | Medium | Strict manifests reject missing or duplicate scalar keys, duplicate part suffixes, invalid hashes/sizes, unsupported engines, and ambiguous end markers. |
| RSE-010 | Medium | SSH destinations and jump hops are grammar-checked; forwarding, TTY, local commands, agent forwarding, and X11 forwarding remain disabled. |
| RSE-011 | Medium | `TAR_OPTIONS` and compressor option environments are cleared; relative and empty `PATH` elements are removed. |
| RSE-012 | Medium | Remote publication has explicit installed/backed-up state, so collision failure cannot delete an already-published bundle. |
| RSE-016 | Medium | Privileged install/uninstall helpers require an absolute traversal-free `PREFIX`, install the security documentation, and refuse to follow a documentation-directory symlink during removal. |


## Runtime invariants

1. `stdout` is reserved for ordinary program output. Machine observers use
   dedicated descriptors only when explicitly requested.
2. Archive data is never evaluated as shell code. The scripts contain no
   `eval` and no legacy backtick substitution.
3. All security-sensitive temporary directories are created with exclusive
   `mkdir`/`mktemp` semantics and private permissions.
4. Existing local or remote destinations are moved to backups before a new
   object is installed; failures restore the previous object.
5. Remote paths are absolute, reject traversal and control characters, and
   are POSIX-single-quoted before inclusion in a remote command.
6. Strict SHA-256 validation is completed again at the receiving side before
   remote publication.
7. A signal returns the conventional status (`129`, `130`, `131`, or `143`)
   after cleanup rather than silently reporting success.

## Tests supplied

```sh
sh tests/runtime-static-audit.sh
sh tests/runtime-security-test.sh
sh tests/smoke-test.sh
sh tests/network-dry-run.sh
sh tests/mock-network-test.sh
```


The adversarial suite exercises command injection, option injection, hostile
`PATH`, hostile `TAR_OPTIONS`, path traversal, control-character filenames,
FIFO refusal, ambiguous manifests, signal cleanup, forced publication
failures, remote collision rollback, corrupt pull protection, and SSH helper
path quoting. Network tests use a deterministic SSH/SFTP simulator; they do
not prove behaviour on every physical OpenSSH or filesystem implementation.

## Residual risks and operating limits

- **Integrity is not authenticity.** A party that can replace both payload and
  manifest can recalculate SHA-256 values. Use an independently protected or
  signed manifest before treating an untrusted archive as authentic.
- **Source inventory is not a filesystem snapshot.** A hostile concurrent
  writer can race between reads. Quiesce the source or use LVM, ZFS, Btrfs,
  APFS, or another snapshot mechanism for security-sensitive backups.
- **Resource exhaustion remains possible.** Compression bombs, sparse files,
  huge manifests, inode exhaustion, and disk exhaustion require filesystem
  quotas, free-space policy, process limits, and external supervision.
- **Root extraction is higher risk.** `tar` metadata semantics vary, and an
  untrusted archive may contain ownership or privileged-mode metadata. Run as
  a dedicated unprivileged account unless restoration of privileged metadata
  is an explicit administrative requirement.
- **Portable shell cannot remove every TOCTOU race** in attacker-writable
  parent directories. Use directories owned by the executing account and not
  writable by unrelated users.
- `allow-unverified=yes`, `host-key-policy=accept-new`, `atomic=no`, and
  `cleanup=never` deliberately lower protection and should be limited to
  controlled recovery or bootstrap situations.
- SSH security still depends on protected private keys, verified host keys,
  restricted remote accounts, and a trustworthy remote shell and toolchain.
- The 4.x series does not implement a distributed multi-hop route-vector
  protocol; `ProxyJump` is transport routing, not an archive-validation hop.

## Recommended service hardening

- execute under a dedicated non-root account;
- use `-i`, strict host-key checking, a protected `known_hosts`, atomic
  publication, and receiver-side `remote-verify=all` for important archives;
- launch services with a minimal environment, for example `env -i`, and set
  `ZSTD_SPLITTER_PATH` only to administrator-controlled absolute directories;
- place output, audit, temporary, and SSH state in private account-owned
  directories;
- apply systemd or container limits for CPU, memory, files, processes, and
  writable paths;
- restrict the remote SSH account with least privilege, a dedicated key, and
  server-side policy appropriate to the deployment;
- retain the package checksum file and this audit report outside the transfer
  destination when independent verification is required.
