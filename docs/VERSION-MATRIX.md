# Release feature matrix

The six packages use one shared implementation skeleton with hard `FEATURE_LEVEL`
gates. A function may exist in the source before it becomes callable; the rows
below describe the public and executable capability boundary.

| Feature | 4.0 | 4.0.1 | 4.1 | 4.1.1 | 4.2 | 4.2.1 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Local create/join/verify/extract | yes | yes | yes | yes | yes | yes |
| Strict source/archive/part SHA-256 | yes | yes | yes | yes | yes | yes |
| SSH/SFTP push and pull | yes | yes | yes | yes | yes | yes |
| Staging, lock, remote validation, atomic publication | yes | yes | yes | yes | yes | yes |
| Optional remote extraction | yes | yes | yes | yes | yes | yes |
| Manual bandwidth cap and connection safety controls | yes | yes | yes | yes | yes | yes |
| Portable SHA-256/stat/tar abstraction | no | yes | no | yes | no | yes |
| `-Q portability` | no | yes | no | yes | no | yes |
| Named network profiles | no | no | yes | yes | yes | yes |
| Parallel SFTP part transfers | no | no | yes | yes | yes | yes |
| User SFTP-window/stream-buffer tuning | no | no | yes | yes | yes | yes |
| User SSH connection-reuse tuning | no | no | yes | yes | yes | yes |
| Route/MTU/jumbo diagnostics | no | no | yes | yes | yes | yes |
| Adaptive network recommendations | no | no | yes | yes | yes | yes |
| Multi-destination fan-out and quorum | no | no | no | no | yes | yes |
| Remote-to-remote relay | no | no | no | no | yes | yes |
| Health, inventory, and garbage collection | no | no | no | no | yes | yes |
| JSON Lines audit log | no | no | no | no | yes | yes |
| Arbitrary distributed multi-hop vector route | no | no | no | no | no | no |

## Gate invariants

- `FEATURE_LEVEL=40`: one remote, safe profile, one transfer worker, default
  SFTP window, no user connection-reuse tuning, no MTU/tuning actions.
- `FEATURE_LEVEL=41`: adds profiles, parallelism, window/buffer tuning,
  connection-reuse controls, route/MTU diagnostics, and recommendations.
- `FEATURE_LEVEL=42`: adds repeated remotes, quorum, relay, administration
  queries, and audit logging.
- Maintenance suffix `.1` adds portability only; it never raises
  `FEATURE_LEVEL`.
