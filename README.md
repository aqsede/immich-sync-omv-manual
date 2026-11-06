# immich-usb-backup

Plug in a specific btrfs USB drive and your Immich library, Portainer stack config and a
fresh database dump get mirrored onto it, followed by a read-only btrfs snapshot. Unplug it,
store it, repeat whenever you like.

```
OMV NAS (Immich + Portainer)  --(plug in drive)-->  btrfs USB drive
                                                     current/      plain-file mirror (rsync --delete)
                                                     snapshots/    read-only history, N kept
```

## What a run does

1. udev matches the drive's **UUID** (from `.env`) and starts `immich-usb-backup.service`.
2. `backup.sh` mounts it (or reuses OMV's mount) and **plans first** with a dry-run rsync.
3. It stops with a notification instead of syncing if: the new data **won't fit**, a source is
   missing/empty (NAS filesystem not mounted), more than `MAX_DELETE_FILES` would be deleted
   (override once with `--force`), or rsync's statistics can't be read (fails closed).
4. Dumps the Immich DB onto the drive with `pg_dump` (the command Immich documents), then
   verifies the file ends properly. **Database first, files second**: Immich's docs recommend
   this order so the worst case is a file the DB doesn't know about, never a DB row pointing at
   a missing file.
5. rsync `--delete` of the Immich folder and Portainer data. Thumbs and encoded video content is
   skipped, but their `.immich` marker files are kept (Immich won't start without them).
6. Read-only snapshot, prune beyond `SNAPSHOT_KEEP`, warn if the drive is over `SPACE_WARN_PERCENT`.
7. Unmounts and notifies "safe to unplug".

## What it can and can't do to your Immich

It never writes to Immich's folders, its database, or Portainer: the sources are only read
(`--delete` applies to the drive copy only). The one thing that touches the running system is
`pg_dump`, which is a read-only, consistent snapshot of the database and runs alongside normal
use. Photos uploaded during a run land after the dump, so they may be missing from this backup
but never corrupt it. For a perfectly in-sync run, stop `immich_server` first.

## Enabling it safely (in this order, install last)

| Step | Command | Proves |
|---|---|---|
| 1 | `sudo ./preflight.sh` | tools, paths, `.immich` markers, rsync output + filter behaviour on temp dirs, DB login, a `pg_dump` streamed to nowhere (size/time), udev rule |
| 2 | `sudo ./verify-db-dump.sh` | the newest Immich dump restores into a throwaway, network-less Postgres and row counts match live. Nothing in production is touched |
| 3 | Plug the drive in, `sudo ./backup.sh --dry-run` | mount works, the plan, free space, deletions |
| 4 | `sudo systemd-run --unit=immich-first-backup ./backup.sh`, watch with `journalctl -fu immich-first-backup` | first real sync, attended. Using systemd-run means an SSH drop can't kill it |
| 5 | `sudo ./backup.sh --dry-run` again | idempotent: should report ~0 bytes to copy |
| 6 | `sudo ./verify-db-dump.sh /mnt/immich-usb-backup/current/db-dumps/<newest>` (mount the drive first) | the dump **on the drive** restores |
| 7 | `sudo ./install.sh`, then unplug and re-plug the drive | the udev trigger works end to end |
| 8 | Restore rehearsal from `RESTORE.md` on a spare machine/VM | you can actually recover |

Only after step 8, and ideally after a few weeks of real use, delete anything from Google or your phone.

Optional, slower: `sudo rsync -rcn --delete --exclude=/thumbs/ --exclude=/encoded-video/ <upload>/ <drive>/current/immich/`
compares every file by checksum against the drive.

## Setup

```bash
# one-time: prepare the drive (ERASES it; check the device name first!)
sudo mkfs.btrfs -L immich-backup /dev/sdX1
lsblk -f                       # note the drive's UUID

git clone <your-repo> /opt/immich-usb-backup && cd /opt/immich-usb-backup
cp .env.example .env && nano .env
# then follow the table above (preflight first, install.sh last)
```

Install on the NAS's own disk, not the USB drive. `apt install rsync btrfs-progs` if tools are missing.

## OMV 7 and OMV 8

OMV 7 is Debian 12, OMV 8 is Debian 13 (released as 8.0.1; OMV 7 upgrades with
`omv-release-upgrade`). The script only uses stock Debian tools, Docker and systemd/udev, none
of which OMV 8 changed in its release notes. Differences that could matter are newer rsync and
btrfs-progs, which is why `preflight.sh` tests rsync's real output and filters on your machine.
**Run it after an OMV upgrade** (and after Immich or Docker upgrades).

- Don't add the drive to OMV's *Storage > File Systems* and don't configure OMV's *USB Backup*
  plugin for it; either would compete with this setup. If you do add it, the script copes: it uses
  OMV's mount and leaves it mounted, so unmount it in OMV before unplugging.
- The udev rule and unit use their own file names under `/etc`. OMV did not document managing
  those, but I haven't verified that it never touches them, so `preflight.sh` checks they're still
  present after upgrades.
- Email uses `sendmail` with a 30 s timeout. OMV 8 fixed tools hanging on `sendmail` when
  notifications are disabled; the timeout covers OMV 7.
- Get Portainer's real data path with `docker volume inspect portainer_data --format '{{.Mountpoint}}'`.

## Updating

`git pull`. `backup.sh` runs straight from the repo. Re-run `sudo ./install.sh` only if you changed
`USB_UUID` or the `udev/` or `systemd/` files. `.env` is gitignored so pulls never overwrite it.

## Notes

- Immich creates its own DB dumps daily in `<upload>/backups` (default keep 14); those are mirrored
  too, so the drive holds two kinds of dump.
- A drive left plugged in at boot counts as "add", so a backup runs.
- Each snapshot costs only what changed. Deleted photos stay on the drive until the snapshots
  holding them are pruned.
- `stack.env` (DB password) is copied and the drive is unencrypted: keep it somewhere you trust.
- `portainer.db` is copied while Portainer runs, so it's best effort; the `compose/` text files are
  what matter.
- Restore steps: `RESTORE.md` (also copied onto the drive on each run).
