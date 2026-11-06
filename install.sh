#!/usr/bin/env bash
# Renders the udev rule + systemd unit from .env and installs them. Safe to re-run.
# Re-run it after changing USB_UUID or after a git pull that touches udev/ or systemd/.
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo ./install.sh" >&2; exit 1; }
[[ -r $ENV_FILE ]] || { echo "Missing $ENV_FILE. Run: cp .env.example .env  and edit it." >&2; exit 1; }

set -a; . "$ENV_FILE"; set +a

# ---- validate -------------------------------------------------------------
[[ ${USB_UUID:-} =~ ^[0-9a-fA-F-]{8,40}$ ]] || { echo "USB_UUID in .env looks invalid." >&2; exit 1; }
[[ $USB_UUID != 00000000-0000-0000-0000-000000000000 ]] || { echo "USB_UUID is still the placeholder." >&2; exit 1; }

missing=()
for c in rsync btrfs flock findmnt df numfmt gzip udevadm systemctl; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if (( ${#missing[@]} )); then
  echo "Missing commands: ${missing[*]}" >&2
  echo "On OMV/Debian: apt install rsync btrfs-progs util-linux coreutils gzip" >&2
  exit 1
fi

[[ -d ${IMMICH_UPLOAD_LOCATION:-} ]] || echo "WARNING: IMMICH_UPLOAD_LOCATION does not exist: ${IMMICH_UPLOAD_LOCATION:-unset}"
[[ -d ${PORTAINER_DATA_DIR:-} ]]     || echo "WARNING: PORTAINER_DATA_DIR does not exist: ${PORTAINER_DATA_DIR:-unset}"
if [[ -n ${DB_DUMP_CONTAINER-immich_postgres} ]] && ! command -v docker >/dev/null 2>&1; then
  echo "WARNING: docker not found; the fresh DB dump step will be skipped."
fi

chmod +x "$REPO_DIR/backup.sh"

# ---- render + install -----------------------------------------------------
sed "s|@@USB_UUID@@|$USB_UUID|g" \
  "$REPO_DIR/udev/99-immich-usb-backup.rules.in" > /etc/udev/rules.d/99-immich-usb-backup.rules

sed "s|@@REPO_DIR@@|$REPO_DIR|g" \
  "$REPO_DIR/systemd/immich-usb-backup.service.in" > /etc/systemd/system/immich-usb-backup.service

udevadm control --reload
systemctl daemon-reload

cat <<MSG
Installed.
  udev rule : /etc/udev/rules.d/99-immich-usb-backup.rules  (drive UUID $USB_UUID)
  service   : /etc/systemd/system/immich-usb-backup.service  -> $REPO_DIR/backup.sh

Next:
  sudo $REPO_DIR/backup.sh --dry-run     # plug the drive in first; shows what would happen
  journalctl -fu immich-usb-backup       # watch a real run after plugging in
MSG
