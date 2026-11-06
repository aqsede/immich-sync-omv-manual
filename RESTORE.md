# Restoring Immich from this drive

Everything on this drive is plain files, readable from any Linux machine (btrfs).

```
current/              latest mirror
  immich/             library, upload, profile, backups (+ empty thumbs/ and encoded-video/ holding only .immich)
  portainer/          Portainer data: compose/<id>/docker-compose.yml + stack.env, portainer.db
  db-dumps/           fresh Immich database dumps (immich-db-*.sql.gz), newest = best
  LAST_SYNC.txt       when this was last synced
snapshots/<date>/     read-only point-in-time copies of current/ (use if latest looks damaged)
```

If the latest data looks wrong (corrupted/deleted photos), use the newest snapshot that
looks good instead of `current/`. Mount it with `mount UUID=<drive-uuid> /mnt/x`.

Thumbnails and transcoded videos are intentionally not backed up; Immich rebuilds them.

## Steps on a fresh machine

1. Install OS/OMV, Docker and Portainer.
2. Recreate the stack. Open `portainer/compose/<id>/docker-compose.yml` and `stack.env`
   (check each `<id>` folder; one is Immich) and paste them into a new stack in Portainer,
   but DO NOT deploy yet. Set `UPLOAD_LOCATION` and `DB_DATA_LOCATION` to fresh paths.
   Keep the same Immich version (`IMMICH_VERSION` in stack.env) for the restore; upgrade afterwards.
   If the compose file mounts extra host folders (for example `thumbs`/`encoded-video` on an
   SSD, or any other absolute path), create those folders on the new machine, or edit the
   paths. They only hold data Immich can rebuild, but the folders must exist and be writable.
   `verify-backup.sh` prints the list of host paths your stack expects.
3. Copy the library into the new `UPLOAD_LOCATION`:
   `rsync -a /mnt/x/current/immich/ /path/to/UPLOAD_LOCATION/`
4. Make sure all six folders exist, each with a `.immich` file, or Immich will refuse to
   start ("Failed to read ... .immich"):
   ```
   cd /path/to/UPLOAD_LOCATION
   for d in upload library thumbs encoded-video profile backups; do mkdir -p "$d"; [ -e "$d/.immich" ] || touch "$d/.immich"; done
   ```
5. Put a dump where Immich can see it: `cp /mnt/x/current/db-dumps/immich-db-XXXX.sql.gz /path/to/UPLOAD_LOCATION/backups/`
   (the dumps made by Immich itself are already in `backups/` after step 3).
6. Deploy the stack (empty database), open Immich in the browser. On the welcome screen
   click **Restore from backup**, review the folder check, choose the dump (or use
   **Select from computer** with a `.sql.gz` from `db-dumps/`) and restore.
   (This is the web restore introduced in Immich v2.5.0; see "Backup and Restore" at
   https://docs.immich.app if the screens differ in your version.)
7. Log in, check albums, people and a few old photos. Then in Administration > Job Queues
   run the missing Thumbnail Generation and Transcode Videos jobs.

## Alternative: command-line restore (Immich's documented method)

The database must be brand new (the Immich server must not have run yet). With the stack
created but not started, and `DB_DATA_LOCATION` empty:

```
docker compose create             # or create the stack's containers without starting them
docker start immich_postgres
sleep 10
gunzip --stdout /mnt/x/current/db-dumps/immich-db-XXXX.sql.gz \
 | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
 | docker exec -i immich_postgres psql --dbname=<DB_DATABASE_NAME> --username=<DB_USERNAME> --single-transaction --set ON_ERROR_STOP=on
docker compose up -d
```
`<DB_USERNAME>` / `<DB_DATABASE_NAME>` are in stack.env (usually postgres / immich).

## Notes

- `portainer.db` is copied while Portainer runs, so treat it as best effort. The `compose/`
  folders (plain text) are what you really need.
- Test this procedure on a spare machine or VM before relying on it.
