# Security notes

The 4.0 runtime was re-audited on 2026-07-28. The executable now enforces
private creation permissions, sanitized command lookup, transactional local
and remote publication, safe archive-member staging, strict remote quoting,
signal cleanup, active-stage cleanup, and explicit SSH control-master
shutdown.

See [`RUNTIME-SECURITY.md`](RUNTIME-SECURITY.md) for the complete threat
model, corrected findings, adversarial tests, and residual risks.

## Network defaults

- Strict host-key checking is the default.
- Password prompting is suppressed with `BatchMode=yes`.
- Agent forwarding, X11 forwarding, TTY allocation, local commands, and
  arbitrary forwarding are disabled.
- Remote publication uses a unique private staging directory, a per-archive
  lock, receiver-side verification, and transactional publication.
- `accept-new` is a controlled bootstrap mode; changed host keys are not
  accepted.

## Integrity boundary

SHA-256 detects accidental or unauthorized modification only while the
manifest is independently trusted. It does not authenticate a manifest that
an attacker can replace together with the archive. Signed manifests remain a
recommended future extension.
