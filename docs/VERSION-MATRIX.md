# 4.x capability matrix

| Capability | 4.0 / 4.0.1 | 4.1 / 4.1.1 | 4.2 / 4.2.1 |
|---|:---:|:---:|:---:|
| strict local integrity | yes | yes | yes |
| single-destination transactional SSH/SFTP | yes | yes | yes |
| profiles, parallel parts, SFTP tuning | no | yes | yes |
| progress and structured-error observers | no | yes | yes |
| MTU/route diagnostics | no | yes | yes |
| fan-out and quorum | no | no | yes |
| relay | no | no | yes |
| health, inventory, GC, JSONL audit | no | no | yes |
| macOS/BSD abstraction | `.1` only | `.1` only | `.1` only |

The `.1` suffix changes portability, never `FEATURE_LEVEL`. Autonomous multi-hop
vector routing is outside the 4.x line.
