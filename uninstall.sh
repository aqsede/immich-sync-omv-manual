#!/usr/bin/env bash
#
# Removes what install.sh / backup.sh put on the system.
#
#   sudo bash ./uninstall.sh                 remove the udev rule and the systemd unit (the trigger)
#   sudo bash ./uninstall.sh --purge         ... plus the log file, lock file, mount-point folder,
#                                       leftover test containers and failed-unit state
#   sudo bash ./uninstall.sh --wipe-drive    FIRST delete current/ and all snapshots from the backup
#                                       drive (asks you to type a confirmation), then as above
#
# Your Immich, Portainer and the repo folder itself are never touched. The last lines
# printed tell you how to remove the repo (and .env) by hand.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
PURGE=0; WIPE=0
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    --wipe-drive) WIPE=1; PURGE=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "Unknown option: $a" >&2; exit 2 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash ./uninstall.sh" >&2; exit 1; }

if systemctl is-active --quiet immich-usb-backup.service 2>/dev/null; then
  echo "A backup is running right now. Wait for it to finish (journalctl -fu immich-usb-backup)." >&2
  exit 1
fi

if [[ -r $ENV_FILE ]]; then set -a; . "$ENV_FILE"; set +a; fi
LOG_FILE="${LOG_FILE:-/var/log/immich-usb-backup.log}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/immich-usb-backup}"

# ---------------------------------------------------------------- drive ---
if (( WIPE )); then
  [[ -n ${USB_UUID:-} ]] || { echo "USB_UUID unknown (is .env missing?). Cannot find the drive." >&2; exit 1; }
  DEV="/dev/disk/by-uuid/$USB_UUID"
  [[ -b $DEV ]] || { echo "Plug the backup drive in first (UUID $USB_UUID)." >&2; exit 1; }
  if findmnt -rn -S "UUID=$USB_UUID" >/dev/null 2>&1; then
    echo "The drive is already mounted somewhere. Unmount it first." >&2; exit 1
  fi
  trap 'mountpoint -q "$MOUNT_POINT" && umount "$MOUNT_POINT" || true' EXIT
  mkdir -p "$MOUNT_POINT"
  mount -t btrfs -o noatime "$DEV" "$MOUNT_POINT"
  echo "Backup drive contents:"
  btrfs subvolume list "$MOUNT_POINT" | sed 's/^/  /'
  df -h "$MOUNT_POINT" | sed 's/^/  /'
  echo
  echo "This PERMANENTLY deletes current/, every snapshot and README-RESTORE.md from the drive."
  echo "The drive stays formatted (same UUID) but empty. Your live Immich is not affected."
  read -r -p 'Type DELETE BACKUP to continue: ' ans
  [[ $ans == "DELETE BACKUP" ]] || { echo "Aborted, nothing deleted."; exit 1; }
  shopt -s nullglob
  for s in "$MOUNT_POINT"/snapshots/20??-??-??_??????; do
    btrfs subvolume delete -c "$s" >/dev/null && echo "  deleted snapshot $(basename "$s")"
  done
  shopt -u nullglob
  rmdir "$MOUNT_POINT/snapshots" 2>/dev/null || true
  if btrfs subvolume show "$MOUNT_POINT/current" >/dev/null 2>&1; then
    btrfs subvolume delete -c "$MOUNT_POINT/current" >/dev/null && echo "  deleted current/"
  fi
  rm -f "$MOUNT_POINT/README-RESTORE.md"
  sync
  umount "$MOUNT_POINT"
  trap - EXIT
  echo "Drive wiped and unmounted."
fi

# --------------------------------------------------------------- system ---
rm -f /etc/udev/rules.d/99-immich-usb-backup.rules /etc/systemd/system/immich-usb-backup.service
udevadm control --reload
systemctl daemon-reload
echo "Removed the udev rule and the systemd unit. Plugging the drive in no longer triggers anything."

if (( PURGE )); then
  systemctl reset-failed immich-usb-backup.service immich-first-backup.service immich-verify.service 2>/dev/null || true
  rm -f "$LOG_FILE" /run/immich-usb-backup.lock
  if [[ -d $MOUNT_POINT ]] && ! mountpoint -q "$MOUNT_POINT"; then
    rmdir "$MOUNT_POINT" 2>/dev/null && echo "Removed empty mount point $MOUNT_POINT" \
      || echo "Left $MOUNT_POINT in place (not empty)."
  fi
  if command -v docker >/dev/null 2>&1; then
    ids="$(docker ps -aq --filter name=immich-restore 2>/dev/null || true)"
    [[ -z $ids ]] || { docker rm -f -v $ids >/dev/null && echo "Removed leftover test containers."; }
  fi
  echo "Removed log file, lock file and failed-unit state."
fi

cat <<MSG

Done. Still on the system, by design:
  - this repo folder and your .env:   sudo rm -rf "$REPO_DIR"     (do this last; it deletes this script)
  - packages you installed yourself (rsync, btrfs-progs): leave them, other things may use them
  - systemd journal lines about immich-usb-backup: they age out by themselves. To erase ALL
    journal history on this machine right now (affects every service):
      sudo journalctl --rotate && sudo journalctl --vacuum-time=1s
MSG
