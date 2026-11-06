#!/usr/bin/env bash
#
# Checks the backup drive WITHOUT needing a spare machine (the practical substitute for a
# full restore rehearsal). The drive is mounted READ-ONLY; nothing is written to the drive,
# to Immich, or to Portainer.
#
#   sudo ./verify-backup.sh [--deep] [--skip-db]
#     --deep     also compare every file by checksum with the live library. Slow: it
#                reads both disks completely (budget 1-2 hours per 200 GB). Use
#                systemd-run so an SSH drop can't kill it:
#                  sudo systemd-run --unit=immich-verify ./verify-backup.sh --deep
#                  journalctl -fu immich-verify
#     --skip-db  skip the database restore test (it takes a few minutes)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
DEEP=0; SKIP_DB=0
for a in "$@"; do
  case "$a" in
    --deep) DEEP=1 ;;
    --skip-db) SKIP_DB=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $a" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo ./verify-backup.sh" >&2; exit 2; }
[[ -r $ENV_FILE ]] || { echo "Missing $ENV_FILE" >&2; exit 2; }
set -a; . "$ENV_FILE"; set +a
MOUNT_POINT="${MOUNT_POINT:-/mnt/immich-usb-backup}"
IMMICH_EXCLUDE_DIRS="${IMMICH_EXCLUDE_DIRS-thumbs encoded-video}"
. "$SCRIPT_DIR/lib.sh"

PASS=0; WARN=0; FAIL=0
ok()  { echo "  [ OK ] $*"; PASS=$((PASS + 1)); }
wn()  { echo "  [WARN] $*"; WARN=$((WARN + 1)); }
bad() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
sec() { echo; echo "== $* =="; }

# Same lock as backup.sh: never run while a backup is running (or vice versa)
exec 9>/run/immich-usb-backup.lock
flock -n 9 || { echo "A backup is running right now. Try again when it has finished." >&2; exit 2; }

MNT=""; MOUNTED_BY_US=0
cleanup() {
  if (( MOUNTED_BY_US )) && mountpoint -q "$MNT"; then
    umount "$MNT" && echo "Unmounted $MNT" || echo "WARNING: could not unmount $MNT"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

DEV="/dev/disk/by-uuid/$USB_UUID"
[[ -b $DEV ]] || { echo "The backup drive (UUID $USB_UUID) is not plugged in." >&2; exit 2; }
EXISTING="$(findmnt -rn -S "UUID=$USB_UUID" -o TARGET 2>/dev/null | head -n1 || true)"
if [[ -n $EXISTING ]]; then
  MNT="$EXISTING"; echo "Drive already mounted at $MNT (using it, read-only access only)"
else
  mkdir -p "$MOUNT_POINT"
  mount -t btrfs -o ro,noatime "$DEV" "$MOUNT_POINT" || { echo "Could not mount the drive" >&2; exit 2; }
  MNT="$MOUNT_POINT"; MOUNTED_BY_US=1; echo "Mounted $MNT read-only"
fi
CUR="$MNT/current"

# ------------------------------------------------------------------ layout ---
sec "Layout"
[[ -d $CUR ]] || { bad "no current/ folder: nothing has been backed up yet"; exit 1; }
btrfs subvolume show "$CUR" >/dev/null 2>&1 && ok "current/ is a btrfs subvolume" || bad "current/ is not a subvolume"
for d in immich portainer db-dumps; do
  [[ -d $CUR/$d ]] && ok "current/$d exists" || bad "current/$d is missing"
done
if [[ -f $CUR/LAST_SYNC.txt ]]; then echo "  last sync info:"; sed 's/^/    /' "$CUR/LAST_SYNC.txt"; fi
for f in upload library profile backups; do
  if [[ -d $IMMICH_UPLOAD_LOCATION/$f ]]; then
    [[ -d $CUR/immich/$f ]] && ok "immich/$f present in the backup" || bad "immich/$f is MISSING from the backup"
  fi
done

sec "File counts (originals), live vs drive"
for f in upload library profile; do
  [[ -d $IMMICH_UPLOAD_LOCATION/$f ]] || continue
  live="$(find "$IMMICH_UPLOAD_LOCATION/$f" -type f 2>/dev/null | wc -l)"
  back="$(find "$CUR/immich/$f" -type f 2>/dev/null | wc -l)"
  printf '  %-10s live %8s   drive %8s\n' "$f" "$live" "$back"
  if (( back > live )); then
    wn "$f: more files on the drive than live (files deleted from Immich since the last backup?)"
  elif (( live > 0 && back * 100 < live * 99 )); then
    bad "$f: the drive has under 99% of the live file count; run a backup and re-check"
  fi
done

# --------------------------------------------------------------- snapshots ---
sec "Snapshots"
shopt -s nullglob
snaps=("$MNT"/snapshots/20??-??-??_??????)
shopt -u nullglob
if (( ${#snaps[@]} )); then
  ok "${#snaps[@]} snapshot(s); newest: $(basename "${snaps[-1]}")"
  for s in "${snaps[@]}"; do
    btrfs property get -ts "$s" ro 2>/dev/null | grep -q 'ro=true' || bad "$(basename "$s") is not read-only"
  done
  [[ -d ${snaps[-1]}/immich && -d ${snaps[-1]}/db-dumps ]] && ok "newest snapshot contains immich/ and db-dumps/" || bad "newest snapshot is incomplete"
else
  bad "no snapshots found"
fi

# ------------------------------------------------------------------- stack ---
sec "Portainer stack (what you would rebuild from)"
found=0
for f in "$CUR"/portainer/compose/*/docker-compose.yml; do
  [[ -f $f ]] || continue
  grep -qi 'immich-app/immich-server\|immich_server' "$f" || continue
  found=1
  d="$(dirname "$f")"
  ok "Immich stack found: compose/$(basename "$d")/docker-compose.yml"
  if [[ -f $d/stack.env ]]; then
    ok "stack.env present next to it"
    for k in UPLOAD_LOCATION DB_DATA_LOCATION DB_PASSWORD; do
      grep -q "^$k=" "$d/stack.env" && ok "  $k is set" || wn "  $k not in stack.env (may be hard-coded in the compose file)"
    done
    ver="$(sed -n 's/^IMMICH_VERSION=//p' "$d/stack.env" | head -n1)"
    echo "  IMMICH_VERSION=${ver:-<not set, image tag is in the compose file>}"
  else
    wn "no stack.env beside it (variables may be written inline)"
  fi
  echo "  host paths this stack expects (they must exist, or be edited, on a restore machine):"
  grep -E '^\s*-\s+[^#]*:/' "$f" | grep -v -E '^\s*-\s+(/etc/localtime|/etc/timezone)' | sed 's/^/    /'
done
(( found )) || bad "no stack file mentioning Immich found under portainer/compose/"

# ------------------------------------------------------------------- dumps ---
sec "Database dumps on the drive"
newest="$(find "$CUR/db-dumps" -maxdepth 1 -name 'immich-db-*.sql.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)"
if [[ -n $newest ]]; then
  age_h=$(( ( $(date +%s) - $(stat -c %Y "$newest") ) / 3600 ))
  if gzip -t "$newest" 2>/dev/null; then ok "newest: $(basename "$newest") ($(numfmt --to=iec --suffix=B "$(stat -c %s "$newest")"), ${age_h}h old), gzip intact"
  else bad "$(basename "$newest") is corrupt"; fi
else
  bad "no immich-db-*.sql.gz on the drive"
fi
nb="$(find "$CUR/immich/backups" -maxdepth 1 -name '*.sql.gz' 2>/dev/null | wc -l)"
echo "  Immich's own dumps also on the drive: $nb"

# -------------------------------------------------------------- deep check ---
if (( DEEP )); then
  sec "Deep compare: every file by checksum (slow)"
  tmp="$(mktemp)"
  mapfile -t X < <(extra_args immich)
  rc=0
  LC_ALL=C rsync -rcn --delete --delete-excluded --itemize-changes "${X[@]}" \
    "$IMMICH_UPLOAD_LOCATION/" "$CUR/immich/" >"$tmp" 2>"$tmp.err" || rc=$?
  if [[ $rc -ne 0 && $rc -ne 24 ]]; then
    bad "compare failed (rsync exit $rc): $(head -n3 "$tmp.err")"
  else
    new="$(grep -c '^>f+++++++++' "$tmp" || true)"
    mod="$(grep '^>f' "$tmp" | grep -vc '^>f+++++++++' || true)"
    del="$(grep -c '^\*deleting' "$tmp" || true)"
    if [[ $mod == 0 ]]; then
      ok "every file present on both sides is byte-identical"
    else
      bad "$mod file(s) differ between the live library and the drive. First ones:"
      grep '^>f' "$tmp" | grep -v '^>f+++++++++' | head -n 20 | sed 's/^/        /'
    fi
    echo "  info: $new file(s) on the live library not yet on the drive (new since the last backup, incl. Immich's daily DB dump): normal"
    echo "  info: $del file(s) only on the drive (deleted from Immich since): normal, older snapshots still hold them"
  fi
  rm -f "$tmp" "$tmp.err"
else
  echo
  echo "(skipped the byte-for-byte compare; add --deep to run it)"
fi

# ---------------------------------------------------------------- db test ---
if (( SKIP_DB )); then
  echo
  echo "(skipped the database restore test)"
elif [[ -n ${newest:-} ]]; then
  sec "Database restore test on the newest dump from the drive"
  if "$SCRIPT_DIR/verify-db-dump.sh" "$newest"; then ok "database dump restores cleanly"; else bad "database restore test failed"; fi
fi

echo
echo "Result: $PASS ok, $WARN warnings, $FAIL failures"
(( FAIL == 0 ))
