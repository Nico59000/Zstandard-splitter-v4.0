# Network examples — 4.0

```sh
# Transactional push
zstd-splitter -P -i -R backup@host:/srv/backups PART

# Verified pull
zstd-splitter -G -i \
  -R backup@host:/srv/backups/a.bundle/a.tar.zst.part.aaaaaa -d downloaded
```
