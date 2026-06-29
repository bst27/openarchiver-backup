# openarchiver-backup

Restic-based backup & restore for a self-hosted [OpenArchiver](https://openarchiver.com)
Docker stack — packaged as a small standalone sidecar so the official OpenArchiver
repository stays untouched.

- **What it does:** briefly stops the stack, snapshots the PostgreSQL volume, the
  Meilisearch volume, the email/attachment storage and the upstream `.env` into a
  deduplicated, encrypted [restic](https://restic.net) repository (S3 by default),
  prunes old snapshots, then starts the stack again.
- **Built on:** [resticker](https://github.com/djmaze/resticker) (`mazzolino/restic`).

## Quick start

```bash
cp .env.example .env                       # then edit: repository, password, S3 creds, paths
docker compose run --rm restic snapshots   # first run auto-creates the (empty) repository
docker compose run --rm backup             # make a backup
```

➡️ **Full instructions, including restore, are in [backup-and-restore.md](./backup-and-restore.md).**
