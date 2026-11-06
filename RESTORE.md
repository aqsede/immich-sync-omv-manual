# Restoring Immich from this drive

Everything on this drive is plain files, readable from any Linux machine (btrfs).

```
current/              latest mirror
  immich/             library, upload, profile, backups  (thumbs/encoded-video are skipped on purpose)
  portainer/          Portainer data: compose/<id>/docker-compose.yml + stack.env, portainer.db
  db-dumps/           fresh Immich database dumps (immich-db-*.sql.gz), newest = best
  LAST_SYNC.txt       when this was last synced
snapshots/<date>/     read-only point-in-time copies of current/ (use if latest looks damaged)
```

If the latest data looks wrong (corrupted/deleted photos), use the newest snapshot that
looks good instead of `current/`. Mount: `mount UUID=<drive-uuid> /mnt/x`.

## Steps on a fresh machine

1. Install OS/OMV, Docker and Portainer.
2. Copy the library back to the same path used as `UPLOAD_LOCATION`:
   `rsync -a /mnt/x/current/immich/ /path/to/UPLOAD_LOCATION/`
3. Get the stack back, either way:
   - Open `portainer/compose/<id>/docker-compose.yml` and `stack.env` (check each `<id>`
     folder, one of them is Immich) and recreate the stack in Portainer's web editor, or
   - Stop Portainer, copy `portainer/` into Portainer's data dir, start Portainer.
   Keep the same Immich version tag (`IMMICH_VERSION` in stack.env) for the restore;
   upgrade afterwards.
4. Restore the database. The database folder (`DB_DATA_LOCATION`) must start EMPTY.
   Deploy the stack, then stop everything except the database container, and restore
   the newest dump (this is Immich's documented method; check the current
   "Backup and Restore" page at https://docs.immich.app if anything differs):

   ```
   docker compose down -v      # or stop the stack in Portainer; empty DB_DATA_LOCATION
   docker compose pull && docker compose create
   docker start immich_postgres
   sleep 10
   gunzip --stdout /mnt/x/current/db-dumps/immich-db-XXXX.sql.gz \
     | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
     | docker exec -i immich_postgres psql --dbname=postgres --username=<DB_USERNAME>
   docker compose up -d
   ```
5. Log in and check albums, people and a few old photos. Then in Immich:
   Administration > Jobs, run the Thumbnail Generation and Transcode Videos jobs
   (select "missing") to rebuild what was skipped.
