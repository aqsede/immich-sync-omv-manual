# immich-usb-backup

Plug in one specific btrfs USB drive and your Immich library, your Portainer stack files and a
fresh database dump are mirrored onto it, followed by a read-only btrfs snapshot. You get an
email, unplug the drive, store it, repeat whenever you like.

```
OMV NAS (Immich + Portainer)  --(plug in drive)-->  btrfs USB drive
                                                     current/      plain-file mirror (rsync --delete)
                                                     snapshots/    read-only history, newest N kept
                                                     README-RESTORE.md
```

---

## Step 0: create and fill in `.env`

Every value that differs between machines lives in `.env`. Nothing else needs editing.

```bash
cd /opt/immich-usb-backup              # the repo, on the NAS's own disk (not the USB drive)
cp .env.example .env
chmod 600 .env                         # it may hold a webhook URL
nano .env
```

`.env` is gitignored, so `git pull` never overwrites your values.

Fill in these five first. Run the "how to find it" command, copy the answer into `.env`.

| Variable | What it is | How to find it |
|---|---|---|
| `USB_UUID` | The backup drive's filesystem UUID. Only this drive triggers a backup. | Plug the drive in, run `lsblk -f` (or `sudo blkid /dev/sdX`). Use the UUID of the **btrfs** line. A filesystem on the whole disk (no `sdb1`) is fine. |
| `IMMICH_UPLOAD_LOCATION` | The folder on the NAS that holds `library/`, `upload/`, `backups/`... | It is `UPLOAD_LOCATION` in your Immich stack's variables in Portainer. Or: `docker inspect immich_server --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'` and take the **source** whose destination is `/data`. |
| `PORTAINER_DATA_DIR` | Portainer's data folder (holds `compose/<id>/docker-compose.yml`, `stack.env`, `portainer.db`). | `docker inspect portainer --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'` and take the **source** whose destination is `/data`. If Portainer runs from a named volume the source is its real path. |
| `DB_DUMP_CONTAINER` | Name of Immich's Postgres container. | `docker ps --format '{{.Names}}  {{.Image}}' \| grep -i postgres` (default `immich_postgres`). Leave empty to disable the fresh dump and rely on Immich's own daily dumps. |
| `IMMICH_EXCLUDE_DIRS` | Folders directly inside the upload folder whose **contents** are not copied. Space separated. | Default `thumbs encoded-video`: Immich rebuilds both. Add other disposable folders if you have them (e.g. `thumbs.old.backup`). Check sizes with `sudo du -sh "<upload folder>"/*/`. The `.immich` marker file in each excluded folder is still copied because Immich won't start without it. |

The rest have sensible defaults:

| Variable | Default | Meaning |
|---|---|---|
| `MOUNT_POINT` | `/mnt/immich-usb-backup` | Where the script mounts the drive. If OMV already mounted it elsewhere, that mount is used and left mounted. |
| `DB_DUMP_USER`, `DB_DUMP_DBNAME` | empty | Empty = auto-detected from the container. `preflight.sh` prints what it found. |
| `DB_DUMP_KEEP` | 5 | Fresh dumps kept in `current/db-dumps/`. |
| `SNAPSHOT_KEEP` | 12 | Read-only snapshots kept on the drive. |
| `SPACE_SAFETY_PERCENT` | 5 | The run aborts if new data plus this headroom won't fit. |
| `SPACE_WARN_PERCENT` | 85 | Adds a warning to the email when the drive is fuller than this. |
| `MAX_DELETE_FILES` | 5000 | The run aborts if it would delete more files than this from the drive copy (guards against an unmounted/empty source). Override once with `--force`. |
| `NOTIFY_EMAIL` | empty | Email via the system `sendmail` (OMV's notification setup). |
| `NOTIFY_WEBHOOK_URL` | empty | ntfy-style webhook. |
| `LOG_FILE` | `/var/log/immich-usb-backup.log` | |

Then check the values: `sudo ./preflight.sh`.

---

## Enabling it, in this order (install last)

Run `chmod +x *.sh` once. Steps 1 to 6 change nothing on your Immich; the trigger is installed
only in step 7, so your first full sync is one you watch.

| Step | Command | What it proves |
|---|---|---|
| 1 | `sudo ./preflight.sh` | Tools, paths, rsync's real output and filter behaviour (temp dirs), DB login, a `pg_dump` streamed to nowhere (size and time), drive present and btrfs. Read-only. |
| 2 | `sudo ./verify-db-dump.sh` | Immich's newest dump restores into a throwaway, network-less Postgres and the row counts match live. Production untouched. |
| 3 | Plug in the drive, `sudo ./backup.sh --dry-run` | Mount works, what would be copied, free space check, pending deletions. Changes nothing. |
| 4 | `sudo systemd-run --unit=immich-first-backup ./backup.sh` then `journalctl -fu immich-first-backup` | The first real sync. `systemd-run` means an SSH drop can't kill it. For scale: about 80 minutes for 200 GB on the author's NAS. |
| 5 | `sudo ./backup.sh --dry-run` again | It should say about 0 bytes to copy for Immich. |
| 6 | `sudo ./verify-backup.sh` (add `--deep` once for a byte-for-byte compare) | Layout, snapshots read-only, file counts, your Portainer stack files and the host paths they expect, dump integrity, and the database restore test from the dump **on the drive**. Mounts the drive read-only. |
| 7 | `sudo ./install.sh`, then `sudo ./preflight.sh` with the drive plugged in, then unplug and re-plug the drive | The udev trigger, end to end. Watch `journalctl -fu immich-usb-backup`. |
| 8 | Optional, when you ever have a spare machine: full restore rehearsal from `RESTORE.md` | Everything coming back on fresh hardware. |

Only delete anything from Google or your phone when you are comfortable. Step 8 is the one
thing nothing else here replaces (see "What is and isn't verified").

---

## Day to day

1. Plug the drive in. 2. Wait for the email "done ... safe to unplug" (a few minutes when little
changed, longer after big imports). 3. Unplug it and store it away.

- Manual run any time: `sudo systemctl start immich-usb-backup`, or `sudo ./backup.sh`.
- Follow a run: `journalctl -fu immich-usb-backup` (also logged to `LOG_FILE`).
- If the email says **FAILED** or has warnings, the message says why. Common ones: drive would be
  full, a source looked empty, too many deletions (use `--force` only if expected).
- A drive left plugged in while the NAS boots counts as a plug-in, so a backup runs.

### What a run does

1. udev matches the drive's UUID and starts `immich-usb-backup.service`.
2. Mount the drive (or reuse OMV's mount), then **plan** with a dry-run rsync.
3. Stop with an email instead of syncing if: new data won't fit, a source is missing/empty, too many
   files would be deleted, or rsync's statistics can't be read (fails closed).
4. `pg_dump` of the Immich database onto the drive, verified. **Database first, files second**
   (Immich's recommended order: worst case is a file the database doesn't know yet).
5. rsync `--delete` of the Immich folder and Portainer data into `current/`.
6. Read-only snapshot, prune beyond `SNAPSHOT_KEEP`, space warning if needed.
7. Unmount, email "safe to unplug".

The snapshot is taken after the sync, so a bad sync never overwrites the previous good snapshot.
It never writes to Immich's folders, its database or Portainer. The only load on the live system
is `pg_dump`, a read-only consistent read.

---

## Changing `.env` after install

`backup.sh` reads `.env` fresh on every run, so almost every change applies from the next run with
nothing to restart.

| You change | Do this afterwards |
|---|---|
| `USB_UUID` (new drive) | `sudo ./install.sh` (the udev rule contains the UUID). A new empty drive does a full first sync; run it attended like step 4. |
| Anything else (paths, excludes, snapshot count, notifications, DB settings...) | Nothing to reinstall. Check with `sudo ./preflight.sh` and `sudo ./backup.sh --dry-run`. |
| `MOUNT_POINT` | Nothing to reinstall. The old folder stays behind: `sudo rmdir <old path>`. |
| `IMMICH_EXCLUDE_DIRS` (adding a folder) | The next run **removes** that folder's contents from `current/`; older snapshots keep them until pruned. |

`git pull` for new script versions: they apply immediately. Re-run `sudo ./install.sh` only if the
files under `udev/` or `systemd/` changed. If a pulled `.env.example` gained new settings, copy
them into your `.env` (missing ones fall back to defaults).

---

## Uninstall

What this project puts on your system, and nowhere else:

| Item | Created by |
|---|---|
| `/etc/udev/rules.d/99-immich-usb-backup.rules` | `install.sh` |
| `/etc/systemd/system/immich-usb-backup.service` | `install.sh` |
| `/var/log/immich-usb-backup.log` | each run |
| `/run/immich-usb-backup.lock` (RAM, gone at reboot) | each run |
| `/mnt/immich-usb-backup/` (empty folder) | each run |
| `current/`, `snapshots/`, `README-RESTORE.md` on the **drive** | each run |
| journal lines for the unit | systemd |

```bash
cd /opt/immich-usb-backup
sudo ./uninstall.sh                # trigger only: stops plugging in the drive from doing anything
sudo ./uninstall.sh --purge        # + log, lock, mount-point folder, leftover test containers, failed-unit state
sudo ./uninstall.sh --wipe-drive   # + FIRST deletes current/ and all snapshots from the drive
                                   #   (plug it in; you must type DELETE BACKUP to confirm)
cd / && sudo rm -rf /opt/immich-usb-backup     # last: the repo and your .env
```

Journal lines age out by themselves; to erase all journal history on the machine (every service)
use `sudo journalctl --rotate && sudo journalctl --vacuum-time=1s`. Your Immich and Portainer are
never touched by uninstalling. Without `--wipe-drive`, the backup stays on the drive as plain files.

---

## What's in the repo

| File | Purpose |
|---|---|
| `.env.example` | Template for `.env` (copy it; `.env` is gitignored). |
| `backup.sh` | The backup itself. Run by udev/systemd, or by hand. |
| `lib.sh` | Small shared helpers, **sourced** by the other scripts (see below). Not run on its own; has no `#!` line and no exec bit on purpose. Must stay next to the scripts. |
| `install.sh` / `uninstall.sh` | Install or remove the udev rule and systemd unit (rendered from the two `.in` templates using `.env`). |
| `preflight.sh` | Read-only health check; run after any OMV, Docker or Immich upgrade too. |
| `verify-db-dump.sh` | Restore-tests a database dump in a throwaway container. |
| `verify-backup.sh` | Checks the drive itself (the practical stand-in for a restore rehearsal). |
| `udev/`, `systemd/` | Templates for the trigger. |
| `RESTORE.md` | How to rebuild from the drive; also copied onto the drive on each run. |

**`lib.sh`** holds the functions that more than one script needs, so there is one copy of each and
`preflight.sh` tests exactly the code `backup.sh` uses:

- `extra_args`: builds the rsync filter that skips the contents of `thumbs`/`encoded-video` but keeps their `.immich` marker.
- `run_rsync`: the one rsync command line (`-aH --delete ...`); exit code 24 (files vanished mid-copy) counts as success.
- `stat_num` / `require_stat`: read numbers from rsync's `--stats` text. The strict one fails if the line is missing, so the space check and delete guard can't silently pass.
- `detect_db_settings`: finds the Postgres user and database name from the container.

---

## OMV 7 and OMV 8

OMV 7 is Debian 12, OMV 8 is Debian 13. The scripts use stock Debian tools, Docker and systemd/udev.
`preflight.sh` tests rsync's real behaviour on your machine, so run it after an OMV upgrade, and
after Immich or Docker upgrades.

- Don't add the backup drive to OMV's *Storage > File Systems* and don't configure OMV's *USB Backup*
  plugin for it. If you do add it, the script copes (uses OMV's mount, leaves it mounted; unmount in OMV before unplugging).
- Email uses `sendmail` with a 30-second timeout.
- The rule and unit use their own file names under `/etc`; `preflight.sh` checks they survive upgrades.

---

## What is and isn't verified

Proven on a real NAS (OMV 7.7.24, Debian 12, rsync 3.2.7, btrfs-progs 6.2, Immich 3.3.6): preflight,
rsync parsing and filters, `pg_dump`, database restore of both Immich's dump and the drive's dump with matching row counts,
dry-run planning, a full first sync of about 200 GB, snapshot creation, clean unmount, and a second
run reporting nothing to copy.

Not proven until you do it:

- The udev plug-in trigger (step 7).
- Snapshot pruning (only happens once you have more than `SNAPSHOT_KEEP` snapshots).
- Email delivery: confirm the first "done" email arrived, or run `sudo ./preflight.sh --notify-test`.
- A real restore onto fresh hardware (step 8). `verify-backup.sh --deep` shows every file and the
  database on the drive are intact and your stack files are there. It does not prove that Immich
  *boots* from them.

Other facts worth knowing:

- Each snapshot costs only what changed. Deleted photos stay on the drive until the snapshots that hold them are pruned.
- `stack.env` (it contains the DB password) is copied and the drive is unencrypted: store it somewhere you trust.
- `portainer.db` is copied while Portainer runs, so it is best effort; the `compose/` text files are what matter.
- Photos uploaded while a run is in progress may be missing from that run's database dump. They are picked up next time.
