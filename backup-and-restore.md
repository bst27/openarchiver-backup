# OpenArchiver — Backup & Restore

Backup and restore for a self-hosted OpenArchiver Docker stack, using
[restic](https://restic.net) via [resticker](https://github.com/djmaze/resticker).

This tooling is a **standalone project**. It does **not** modify your OpenArchiver
installation — it only reads the running stack's Docker volumes and email storage,
and briefly stops the stack so the copy is consistent.

---

## 1. What gets backed up (and why)

| Component | Source | Why it matters |
|---|---|---|
| **PostgreSQL** | volume `*_pgdata` | All metadata: users, audit logs, settings, and the **ingestion sources incl. their encrypted mailbox credentials**. |
| **Email content + attachments** | host dir `STORAGE_LOCAL_ROOT_PATH` (e.g. `/var/data/open-archiver`) | The actual archived `.eml` files and attachments — the bulk of the data. |
| **Meilisearch index** | volume `*_meilidata` | The full-text search index. Rebuildable, but reindexing a large archive takes a long time — backing it up makes restore instant. |
| **Upstream `.env`** | `OA_PROJECT_DIR/.env` | Holds `ENCRYPTION_KEY` (which **decrypts the stored account credentials**), `JWT_SECRET`, DB/Redis/Meili passwords. Without it the restored credentials are unusable. |
| **Upstream `docker-compose.yml`** | `OA_PROJECT_DIR/docker-compose.yml` | So the stack can be recreated exactly. |

> Valkey (the job queue) is intentionally **not** backed up — it only holds
> ephemeral background jobs.

> ⚠️ **One secret you must keep safe and *separate from the backup*:**
> the **`RESTIC_PASSWORD`** (without it the repository cannot be decrypted → no
> restore). The confidentiality of the archived credentials
> rests entirely on the `RESTIC_PASSWORD`, so guard it well.

---

## 2. How it works

- A short-lived `mazzolino/restic` container mounts the stack's volumes + email
  storage and the upstream `.env`/`docker-compose.yml`.
- Before the snapshot it runs `docker stop open-archiver postgres meilisearch valkey tika`
  (so PostgreSQL/Meilisearch are copied **cold** = consistent), and afterwards it
  always starts them again — even if the backup failed.
- restic deduplicates and encrypts everything, then old snapshots are pruned.

**Downtime** = the duration of the backup. The first run uploads everything
and is slow; subsequent runs only upload changed blocks and are quick.

> **Security note:** the container mounts the Docker socket so it can stop/start
> the stack. That is effectively host-root access — fine for a self-hosted box you
> control, but be aware of it.

> **Version note:** PostgreSQL is backed up at the file level, so a restore must go
> into the **same PostgreSQL major version** (the stack pins `postgres:17`).

---

## 3. Prerequisites

- The OpenArchiver stack runs via Docker Compose on this host.
- Docker + Docker Compose v2 (`docker compose`).
- An S3-compatible bucket (or a local/SFTP target — see §8).
- This repo checked out somewhere on the same host.

Find your stack's volume names:

```bash
docker volume ls | grep -E 'pgdata|meilidata'
# e.g. openarchiver_pgdata / openarchiver_meilidata
```

---

## 4. Configure

```bash
cp .env.example .env
```

Edit `.env`:

- `RESTIC_REPOSITORY` — your S3 bucket, e.g.
  `s3:https://s3.eu-central-1.amazonaws.com/my-bucket/openarchiver`
- `RESTIC_PASSWORD` — generate once: `openssl rand -base64 32` — **store it safely.**
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — bucket credentials.
- `OA_PROJECT_DIR` — path of your OpenArchiver checkout (its `.env` lives there).
- `STORAGE_LOCAL_ROOT_PATH` — same value as in OpenArchiver's `.env`.
- `PG_VOLUME` / `MEILI_VOLUME` — the volume names from §3.
- `RESTIC_FORGET_ARGS` — retention policy (ships with a sane default).

> Using a non-S3 backend (local disk, SFTP/Storage Box)? See §8 — you set a
> different `RESTIC_REPOSITORY` and enable the matching compose overlay.

---

## 5. Initialize the repository (once)

Any `restic` command auto-creates the repository on first use, so just run:

```bash
docker compose run --rm restic snapshots
```

The first time you'll see `Repository successfully initialized.` followed by an
empty snapshot list. (Running it again simply lists snapshots.)

---

## 6. Run a backup

```bash
docker compose run --rm backup
```

This stops the stack, snapshots everything, prunes per the retention policy, and
restarts the stack.

Inspect:

```bash
docker compose run --rm restic snapshots     # list snapshots
docker compose run --rm restic check         # verify repository integrity
```

After it finishes, confirm the stack is healthy:

```bash
docker ps   # open-archiver, postgres, meilisearch, valkey, tika should be "Up"
```

### Retention

After each backup, restic runs `forget` with `RESTIC_FORGET_ARGS` (from `.env`),
then prunes. Tune it in `.env` (shipped default: keep 7 daily, 4 weekly, 6 monthly,
then `--prune`):

```ini
RESTIC_FORGET_ARGS=--keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
```

Leave it empty to skip `forget` entirely (keeps every snapshot, prunes nothing).

### Scheduling

This is run-on-demand by design. To automate, add a cron entry on the host, e.g.:

```cron
30 3 * * *  cd /path/to/openarchiver-backup && docker compose run --rm backup >> /var/log/oa-backup.log 2>&1
```

---

## 7. Restore

> A restore **overwrites** the live PostgreSQL/Meilisearch volumes and the email
> storage. Always start with the dry-run.

**If restoring onto a fresh host:** first lay down the stack so the volumes and
containers exist, then stop it:

```bash
cd "$OA_PROJECT_DIR"
docker compose up -d          # creates volumes + containers
docker compose stop
cd -                          # back to openarchiver-backup
```

**Dry-run** (shows snapshots, changes nothing):

```bash
docker compose run --rm restore latest
```

**Perform the restore:**

```bash
docker compose run --rm restore latest --force
# or a specific snapshot id:
docker compose run --rm restore <snapshotID> --force
```

This stops the stack, wipes and restores the two volumes + the email storage in
place, restores the upstream `.env`/`docker-compose.yml` to `./restore-out/staging/`
for manual pickup, and starts the stack again.

**Restore the `.env` if needed** (the script never overwrites it automatically):

```bash
cp ./restore-out/staging/.env  "$OA_PROJECT_DIR/.env"
cd "$OA_PROJECT_DIR" && docker compose up -d
```

**Verify:** log in to the web UI, run a search, and check that the email count and
ingestion sources look right.

---

## 8. Other backup targets (flexible)

restic is backend-agnostic. The **base** `docker-compose.yml` defines the backup
*sources* (always the same); a backend only changes the *destination*. S3 needs
nothing but env vars; backends that need host access (a local repo dir, an SSH key)
add it via an overlay you copy to `docker-compose.override.yml`:

| Target | `RESTIC_REPOSITORY` | Env | Overlay |
|---|---|---|---|
| S3 / B2 / MinIO / Hetzner **Object Storage** | `s3:https://<endpoint>/<bucket>/openarchiver` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | — |
| Local / external disk | `/srv/restic` | `RESTIC_LOCAL_REPO_PATH` (host dir) | `docker-compose.local.yml.example` |
| SFTP / another server | `sftp:user@host:/srv/restic` | `SSH_KEY_PATH` | `docker-compose.sftp.yml.example` |
| Hetzner **Storage Box** | `sftp:hetzner-sb:restic/openarchiver-prod` | `SSH_KEY_PATH` + `ssh/config` — see §9 | `docker-compose.sftp.yml.example` |

Enable an overlay by copying it to the auto-merged name, e.g. for a local disk:

```bash
cp docker-compose.local.yml.example docker-compose.override.yml
```

> ⚠️ A Hetzner **Storage Box** is **not** S3 — it speaks SFTP on port 23. (Hetzner
> **Object Storage** is the S3-compatible product; use the `s3:` row for that.)
>
> 💡 Without the local overlay a path repo like `/srv/restic` would be written
> *inside* the throwaway `--rm` container and lost — the overlay mounts the host
> dir in at `/srv/restic`.

---

## 9. Hetzner Storage Box (SFTP)

A Storage Box is an SFTP target on **port 23**. restic's sftp backend can't put a
port in the repository URL, so the port + key are configured in a small `ssh/config`
that gets mounted into the container. **Your private key stays owned by your user** —
only the throwaway `ssh/config` needs to be root-owned (ssh runs as root in the
container and rejects a non-root-owned config; for the private key that ownership
check is skipped, so it loads fine read-only).

### 9.1 Put your public key on the box (once)

Supply your SSH key when creating the Storage Box.

### 9.2 Create SSH config

Create `ssh/config` with the following template. Replace
`u123456` with your Storage Box ID and make it root-owned:

```
Host hetzner-sb
    HostName u123456.your-storagebox.de
    User u123456
    Port 23
    IdentityFile /keys/sb_key          # in-container path of your key (see 9.4)
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new   # trusts the host key on first connect
```

```bash
sudo chown root:root ssh/config && sudo chmod 600 ssh/config
```

### 9.3 Point `.env` at the box

```ini
RESTIC_REPOSITORY=sftp:hetzner-sb:restic/openarchiver-prod
SSH_KEY_PATH=/home/<you>/.ssh/id_ed25519     # your PRIVATE key; stays yours
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY stay empty
```

The path after the host alias (`restic/openarchiver-prod`) is **where the repo
lives**. SFTP on a Storage Box is chrooted, so it lands as a top-level folder
`restic/openarchiver-prod` in your box. Different paths = independent repos, so
**several repos can share one Storage Box** (e.g. `restic/host-a`, `restic/host-b`).

### 9.4 Enable the SFTP mounts via `docker-compose.override.yml`

The ssh config + key mounts live in a per-deployment overlay that `docker compose`
auto-merges on top of `docker-compose.yml` (so the tracked compose stays clean and
S3 stays the no-overlay default). Enable it by copying the example:

```bash
cp docker-compose.sftp.yml.example docker-compose.override.yml
```

This **appends** two mounts to `backup`, `restic` and `restore`: `./ssh` →
`/root/.ssh` (the root-owned config) and your key (`SSH_KEY_PATH`) → `/keys/sb_key`.
The key goes to a separate path, not inside `/root/.ssh` — mounting a file into the
read-only `./ssh` mount would fail. The real override file is gitignored.

### 9.5 Initialize and back up

```bash
docker compose run --rm restic snapshots   # auto-creates the repo, then empty list
docker compose run --rm backup
```

Verify the repo exists on the box:

```bash
sftp -P 23 u123456@u123456.your-storagebox.de
sftp> ls restic/openarchiver-prod
config   data   index   keys   locks   snapshots
```

---

## 10. Troubleshooting

- **Stack didn't restart after a failed backup** — `POST_COMMANDS_EXIT` should
  always restart it; if not, run `docker start postgres meilisearch valkey tika open-archiver`.
- **"repository is already locked"** — a previous run was interrupted:
  `docker compose run --rm restic unlock`.
- **Wrong volume names** — re-check with `docker volume ls` and fix
  `PG_VOLUME`/`MEILI_VOLUME` in `.env`.
