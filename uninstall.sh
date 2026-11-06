#!/usr/bin/env bash
# Removes the udev rule and systemd unit. Leaves the repo, .env and the drive untouched.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo ./uninstall.sh" >&2; exit 1; }
rm -f /etc/udev/rules.d/99-immich-usb-backup.rules /etc/systemd/system/immich-usb-backup.service
udevadm control --reload
systemctl daemon-reload
echo "Uninstalled."
