#!/bin/sh
# =============================================================================
# OpenArchiver restore helper (runs inside the resticker image).
#
#   docker compose run --rm restore [snapshotID|latest]            # dry-run
#   docker compose run --rm restore [snapshotID|latest] --force    # do it
#
# Restores, IN PLACE and OVERWRITING current data:
#   - PostgreSQL volume   -> /volumes/pgdata
#   - Meilisearch volume  -> /volumes/meilidata
#   - email storage       -> /data   (host STORAGE_LOCAL_ROOT_PATH)
# The upstream .env + docker-compose.yml are restored to /restore-out for
# MANUAL pickup (this script never overwrites your live .env automatically).
# =============================================================================
set -eu

SNAP="${1:-latest}"
FORCE="${2:-}"

echo ">>> OpenArchiver restore"
echo "    snapshot:   $SNAP"
echo "    repository: ${RESTIC_REPOSITORY:-<unset>}"
echo

# --- Safety: dry-run unless explicitly forced --------------------------------
if [ "$FORCE" != "--force" ] && [ "${FORCE_RESTORE:-}" != "1" ]; then
  echo "!! DRY-RUN — nothing will be changed."
  echo "!! A real restore OVERWRITES the live PostgreSQL/Meilisearch volumes and"
  echo "!! the email storage at /data. Available snapshots:"
  echo
  restic snapshots || true
  echo
  echo "To actually restore, re-run with --force:"
  echo "    docker compose run --rm restore $SNAP --force"
  exit 0
fi

# --- Pre-flight: make sure the snapshot exists BEFORE we delete anything ------
echo ">>> Verifying snapshot '$SNAP' exists ..."
if ! restic snapshots "$SNAP" 2>/dev/null | grep -qE '^[0-9a-f]{8} '; then
  echo "!! Snapshot '$SNAP' not found in $RESTIC_REPOSITORY — aborting (nothing deleted)."
  echo "!! Available snapshots:"
  restic snapshots || true
  exit 1
fi

# --- Stop the stack (best effort) --------------------------------------------
echo ">>> Stopping OpenArchiver stack ..."
docker stop open-archiver postgres meilisearch valkey tika 2>/dev/null || true

# --- Wipe current contents (keep the mountpoints themselves) -----------------
clear_dir() { find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf {} \; 2>/dev/null || true; }
echo ">>> Clearing current volume/storage contents ..."
clear_dir /volumes/pgdata
clear_dir /volumes/meilidata
clear_dir /data

# --- Restore data in place ---------------------------------------------------
echo ">>> Restoring PostgreSQL, Meilisearch and email storage ..."
restic restore "$SNAP" --target / \
  --include /volumes/pgdata \
  --include /volumes/meilidata \
  --include /data

# --- Restore upstream .env + compose for manual pickup -----------------------
echo ">>> Restoring upstream .env + docker-compose.yml to ./restore-out ..."
rm -rf /restore-out/staging 2>/dev/null || true
restic restore "$SNAP" --target /restore-out --include /staging

cat <<EOF

>>> DATA RESTORE COMPLETE.

    The upstream .env was restored to (on the host):
        ./restore-out/staging/.env
    If you need it, copy it back into your OpenArchiver project dir:
        cp ./restore-out/staging/.env  <OA_PROJECT_DIR>/.env

EOF

# --- Bring the stack back up -------------------------------------------------
echo ">>> Starting the stack ..."
if docker start postgres meilisearch valkey tika open-archiver 2>/dev/null; then
  echo ">>> Stack started."
else
  echo "!! Could not start existing containers (fresh host?)."
  echo "!! Bring the stack up from your OpenArchiver project dir:"
  echo "      docker compose up -d"
fi

echo
echo ">>> Verify the restore: log in, run a search, check the email count."
