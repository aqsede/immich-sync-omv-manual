# immich-usb-backup

Plug in a specific btrfs USB drive and your Immich library, Portainer stack config and a
fresh database dump get mirrored onto it automatically, followed by a read-only btrfs
snapshot. Unplug it, store it somewhere safe, repeat whenever you like.

```
OMV NAS (Immich + Portainer)  --(plug in drive)-->  btrfs USB drive
                                                     current/      plain-file mirror (rsync --delete)
                                                     snapshots/    read-only history, N kept
```

## What happens when you plug the drive in

1. udev matches the drive's **UUID** (from `.env`) and starts `immich-usb-backup.service`.
2. `backup.sh` mounts it (or reuses OMV's mount), then **plans first**: a dry-run rsync
   measures how much new data there is and how many files would be deleted.
3. Safety stops, with a notification instead of a sync:
   - new data **won't fit** on the drive (free space minus headroom)
   - a source is missing or empty (e.g. NAS filesystem not mounted)
   - more than `MAX_DELETE_FILES` would be deleted (override once with `--force`)
4. Dumps the Immich DB straight onto the drive (`db-dumps/`).
5. rsync `--delete` for the Immich folder (skipping thumbs/encoded-video) and Portainer data.
6. Takes a read-only snapshot, prunes beyond `SNAPSHOT_KEEP`.
7. Warns if the drive is fuller than `SPACE_WARN_PERCENT`, unmounts, notifies "safe to unplug".

The snapshot is taken after the sync. A bad sync therefore never overwrites the previous
snapshot, which is the point of Option B.

## Setup

```bash
# one-time: prepare the drive (ERASES it; check the device name first!)
sudo mkfs.btrfs -L immich-backup /dev/sdX1
lsblk -f                      # note the drive's UUID

git clone <your-repo> /opt/immich-usb-backup && cd /opt/immich-usb-backup
cp .env.example .env && nano .env
sudo ./install.sh

# with the drive plugged in:
sudo ./backup.sh --dry-run    # plan only, changes nothing
sudo ./backup.sh              # first real run (can take hours; the udev trigger does the same)
```

Install on the NAS's own disk (not the USB drive). `apt install rsync btrfs-progs` if the
installer reports missing tools.

Watch a triggered run with `journalctl -fu immich-usb-backup`; the log is also at `LOG_FILE`.

## Updating

`git pull`. `backup.sh` is run straight from the repo, so changes apply immediately. Re-run
`sudo ./install.sh` only if you changed `USB_UUID` or the files under `udev/` or `systemd/`.

`.env` is gitignored, so pulls never overwrite your values. Commit `.env.example` changes
when you add new settings.

## Notes

- Immich creates its own DB dumps daily in `<upload>/backups`; those are mirrored too, so
  you have two kinds of dump on the drive.
- If the drive is left plugged in at boot, udev counts that as "add" and a backup runs.
- Snapshots share unchanged data, so each costs only what changed. Deleted photos stay on
  the drive until the snapshots holding them are pruned.
- The Portainer folder includes `stack.env` (DB password) and the drive is unencrypted,
  so keep it somewhere you trust.
- Restore steps are in `RESTORE.md`, which is also copied onto the drive on each run.
  **Rehearse a restore on a spare machine or VM before deleting anything from Google or your phone.**
