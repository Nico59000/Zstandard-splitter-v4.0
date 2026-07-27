# Network examples — 4.0

```sh
# Transactional single-destination push
zstd-splitter -P -i -R backup@host:/srv/backups PART

# Pull a published bundle
zstd-splitter -G -i \
  -R backup@host:/srv/backups/archive.tar.zst.bundle/archive.tar.zst.part.aaaaaa \
  -d downloaded

# Safe preflight/configuration
zstd-splitter -Q network -R backup@host:/srv/backups
zstd-splitter -Q config -O dry-run=yes
```

4.1 profile and tuning examples are intentionally omitted because this package rejects them.

4.2 fan-out, quorum, relay, and administration examples are intentionally omitted because this package rejects them.
