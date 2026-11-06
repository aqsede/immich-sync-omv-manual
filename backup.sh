#!/usr/bin/env bash
#
# immich-usb-backup
# Mirrors the Immich library + Portainer config (+ a fresh DB dump) onto a btrfs
# USB drive with rsync --delete, then takes a read-only btrfs snapshot.
# Started by udev when the configured drive is plugged in, or run by hand.
#
set -Eeuo pipefail

usage() {
  cat <<USAGE
Usage: sudo backup.sh [--dry-run] [--force]
  --dry-run  mount the drive, check free space and pending deletions, change nothing
  --force    skip the "too many files would be deleted" safety stop
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
START_TS=$(date +%s)

DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Must run as root." >&2; exit 2; }
[[ -r $ENV_FILE ]] || { echo "Missing $ENV_FILE (copy .env.example to .env and edit it)." >&2; exit 2; }

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${USB_UUID:?USB_UUID is not set in .env}"
: "${IMMICH_UPLOAD_LOCATION:?IMMICH_UPLOAD_LOCATION is not set in .env}"
: "${PORTAINER_DATA_DIR:?PORTAINER_DATA_DIR is not set in .env}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/immich-usb-backup}"
IMMICH_EXCLUDE_DIRS="${IMMICH_EXCLUDE_DIRS-thumbs encoded-video}"
DB_DUMP_CONTAINER="${DB_DUMP_CONTAINER-immich_postgres}"
DB_DUMP_USER="${DB_DUMP_USER:-}"        # empty = auto-detect from the container
DB_DUMP_DBNAME="${DB_DUMP_DBNAME:-}"    # empty = auto-detect from the container
DB_DUMP_KEEP="${DB_DUMP_KEEP:-5}"
DB_BACKUP_MAX_AGE_DAYS="${DB_BACKUP_MAX_AGE_DAYS:-3}"
SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-12}"
SPACE_SAFETY_PERCENT="${SPACE_SAFETY_PERCENT:-5}"
SPACE_WARN_PERCENT="${SPACE_WARN_PERCENT:-85}"
MAX_DELETE_FILES="${MAX_DELETE_FILES:-5000}"
NOTIFY_WEBHOOK_URL="${NOTIFY_WEBHOOK_URL:-}"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
LOG_FILE="${LOG_FILE:-/var/log/immich-usb-backup.log}"

# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

mkdir -p "$(dirname "$LOG_FILE")"

# ---------------------------------------------------------------- helpers ---
WARNINGS=()
MNT=""
MOUNTED_BY_US=0
CUR=""

log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
warn() { log "WARNING: $*"; WARNINGS+=("$*"); }
hr()   { numfmt --to=iec --suffix=B "$1"; }

notify() {  # notify <status> <message> [priority]
  local title="Immich USB backup: $1" body="$2" prio="${3:-default}"
  if [[ -n $NOTIFY_WEBHOOK_URL ]]; then
    curl -fsS -m 15 -H "Title: $title" -H "Priority: $prio" -d "$body" \
      "$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1 || log "webhook notification failed"
  fi
  if [[ -n $NOTIFY_EMAIL ]] && command -v sendmail >/dev/null 2>&1; then
    printf 'To: %s\nSubject: %s\n\n%s\n' "$NOTIFY_EMAIL" "$title" "$body" \
      | timeout 30 sendmail -t >/dev/null 2>&1 || log "email notification failed"
  fi
}

do_unmount() {
  if (( MOUNTED_BY_US )) && mountpoint -q "$MNT"; then
    sync
    btrfs filesystem sync "$MNT" >/dev/null 2>&1 || true
    if umount "$MNT"; then
      MOUNTED_BY_US=0
      log "Unmounted $MNT"
    else
      return 1
    fi
  fi
  return 0
}

cleanup() { do_unmount || log "Could not unmount $MNT (busy?)"; }
trap cleanup EXIT

die() {
  [[ $BASHPID -eq $$ ]] || exit 1   # inside a $(...) subshell: let the parent report it
  trap - ERR
  log "ERROR: $*"
  notify "FAILED" "$* (see $LOG_FILE)" high
  exit 1
}
trap 'die "Unexpected error at line $LINENO"' ERR

exec 9>/run/immich-usb-backup.lock
flock -n 9 || { log "Another backup run is in progress, exiting."; trap - EXIT; exit 0; }

# ------------------------------------------------------------ drive mount ---
log "=== Backup run started (dry-run=$DRY_RUN force=$FORCE) ==="

DEV="/dev/disk/by-uuid/$USB_UUID"
for _ in $(seq 1 30); do [[ -b $DEV ]] && break; sleep 1; done
[[ -b $DEV ]] || die "Drive with UUID $USB_UUID not found"

EXISTING="$(findmnt -rn -S "UUID=$USB_UUID" -o TARGET 2>/dev/null | head -n1 || true)"
if [[ -n $EXISTING ]]; then
  MNT="$EXISTING"
  log "Drive already mounted at $MNT (will leave it mounted)"
else
  mkdir -p "$MOUNT_POINT"
  mount -t btrfs -o noatime "$DEV" "$MOUNT_POINT" || die "Could not mount $DEV"
  MNT="$MOUNT_POINT"
  MOUNTED_BY_US=1
  log "Mounted $DEV at $MNT"
fi

[[ "$(findmnt -no FSTYPE -T "$MNT")" == "btrfs" ]] || die "$MNT is not btrfs"

CUR="$MNT/current"
SNAPDIR="$MNT/snapshots"
if [[ ! -e $CUR ]]; then
  if (( DRY_RUN )); then
    log "First run: would create subvolume $CUR"
  else
    btrfs subvolume create "$CUR" >/dev/null
    log "Created subvolume $CUR"
  fi
elif ! btrfs subvolume show "$CUR" >/dev/null 2>&1; then
  die "$CUR exists but is not a btrfs subvolume; move it away so the script can create one"
fi

# ---------------------------------------------------------- sync planning ---
declare -A SRC=( [immich]="$IMMICH_UPLOAD_LOCATION" [portainer]="$PORTAINER_DATA_DIR" )
NAMES=(immich portainer)

log "Planning (dry run of rsync) ..."
TOTAL_NEW=0
TOTAL_DEL=0
for name in "${NAMES[@]}"; do
  src="${SRC[$name]}"
  [[ -d $src ]] || die "Source for $name does not exist: $src"
  [[ -n "$(ls -A "$src" 2>/dev/null)" ]] || die "Source for $name is empty: $src (is the NAS filesystem mounted?)"
  mapfile -t XARGS < <(extra_args "$name")
  dst="$CUR/$name"
  if [[ -d $dst ]]; then
    out="$(run_rsync "$src" "$dst" -n "${XARGS[@]}")" || die "Planning rsync failed for $name"
  else
    # destination does not exist yet: compare against an empty directory
    empty="$(mktemp -d)"
    out="$(run_rsync "$src" "$empty" -n "${XARGS[@]}")" || { rmdir "$empty"; die "Planning rsync failed for $name"; }
    rmdir "$empty"
  fi
  new_b="$(require_stat 'Total transferred file size' "$out")" \
    || die "Could not read rsync statistics for $name (unexpected rsync output). Run ./preflight.sh"
  del_n="$(require_stat 'Number of deleted files' "$out")" \
    || die "Could not read rsync statistics for $name (unexpected rsync output). Run ./preflight.sh"
  log "  $name: $(hr "$new_b") to copy, $del_n files to delete from the drive copy"
  TOTAL_NEW=$(( TOTAL_NEW + new_b ))
  TOTAL_DEL=$(( TOTAL_DEL + del_n ))
done

AVAIL="$(df -B1 --output=avail "$MNT" | tail -n1 | tr -d ' ')"
NEEDED=$(( TOTAL_NEW + TOTAL_NEW * SPACE_SAFETY_PERCENT / 100 ))
log "Space: need ~$(hr "$NEEDED") (incl. ${SPACE_SAFETY_PERCENT}% headroom), drive has $(hr "$AVAIL") free"
if (( NEEDED > AVAIL )); then
  die "New data will NOT fit on the drive: need ~$(hr "$NEEDED"), only $(hr "$AVAIL") free. Lower SNAPSHOT_KEEP, delete old snapshots, or use a bigger drive."
fi

if (( TOTAL_DEL > MAX_DELETE_FILES )) && (( ! FORCE )); then
  die "Sync would delete $TOTAL_DEL files from the backup (limit $MAX_DELETE_FILES). If that is expected run: sudo $SCRIPT_DIR/backup.sh --force. If not, check the NAS filesystems are mounted."
fi

if (( DRY_RUN )); then
  log "Dry run finished; nothing was changed."
  exit 0
fi

# -------------------------------------------------------------- DB dump -----
DB_DUMPED=0
dump_database() {
  [[ -n $DB_DUMP_CONTAINER ]] || { log "Fresh DB dump disabled"; return 1; }
  command -v docker >/dev/null 2>&1 || { warn "docker not found, skipping fresh DB dump"; return 1; }
  if [[ "$(docker inspect -f '{{.State.Running}}' "$DB_DUMP_CONTAINER" 2>/dev/null || true)" != "true" ]]; then
    warn "Container '$DB_DUMP_CONTAINER' is not running, skipping fresh DB dump"
    return 1
  fi
  detect_db_settings
  local dir="$CUR/db-dumps" ts out tmp
  mkdir -p "$dir"
  ts="$(date +%Y-%m-%d_%H%M%S)"
  out="$dir/immich-db-$ts.sql.gz"
  tmp="$out.partial"
  log "Dumping database '$DB_DUMP_DBNAME' (user '$DB_DUMP_USER') from '$DB_DUMP_CONTAINER' ..."
  # Same command Immich documents (pg_dump, one database). No -t: a TTY would corrupt the pipe.
  if docker exec "$DB_DUMP_CONTAINER" pg_dump --clean --if-exists \
       --dbname="$DB_DUMP_DBNAME" --username="$DB_DUMP_USER" | gzip > "$tmp" \
     && gzip -t "$tmp" && [[ -s $tmp ]] \
     && gzip -dc "$tmp" | tail -c 400 | grep -q 'PostgreSQL database dump complete'; then
    mv "$tmp" "$out"
    log "DB dump written: $(basename "$out") ($(hr "$(stat -c %s "$out")"))"
    find "$dir" -maxdepth 1 -name 'immich-db-*.sql.gz' -printf '%T@ %p\n' \
      | sort -rn | tail -n +$(( DB_DUMP_KEEP + 1 )) | cut -d' ' -f2- | xargs -r rm -f --
    return 0
  fi
  rm -f "$tmp"
  warn "Fresh DB dump FAILED"
  return 1
}
if dump_database; then DB_DUMPED=1; fi

if (( ! DB_DUMPED )); then
  recent="$(find "$IMMICH_UPLOAD_LOCATION/backups" -maxdepth 1 -type f -name '*.sql.gz' \
            -mtime "-$DB_BACKUP_MAX_AGE_DAYS" -print -quit 2>/dev/null || true)"
  [[ -n $recent ]] || warn "No database dump newer than $DB_BACKUP_MAX_AGE_DAYS days in $IMMICH_UPLOAD_LOCATION/backups; the backup may have no usable database"
fi

# ------------------------------------------------------------------ sync ----
SUMMARY=()
for name in "${NAMES[@]}"; do
  src="${SRC[$name]}"
  dst="$CUR/$name"
  mkdir -p "$dst"
  mapfile -t XARGS < <(extra_args "$name")
  log "Syncing $name: $src -> $dst"
  out="$(run_rsync "$src" "$dst" "${XARGS[@]}")" || die "rsync failed for $name"
  new_files="$(stat_num 'Number of regular files transferred' "$out")"
  [[ $new_files != 0 ]] || new_files="$(stat_num 'Number of files transferred' "$out")"
  del_n="$(stat_num 'Number of deleted files' "$out")"
  new_b="$(stat_num 'Total transferred file size' "$out")"
  log "  $name done: $new_files files / $(hr "$new_b") copied, $del_n deleted"
  SUMMARY+=("$name: +$new_files files ($(hr "$new_b")), -$del_n")
done

missing_markers=()
for f in upload library thumbs encoded-video profile backups; do
  if [[ -e "$IMMICH_UPLOAD_LOCATION/$f/.immich" && ! -e "$CUR/immich/$f/.immich" ]]; then
    missing_markers+=("$f")
  fi
done
if (( ${#missing_markers[@]} )); then
  warn "Immich .immich marker missing in the backup for: ${missing_markers[*]} (a restored Immich may refuse to start, see RESTORE.md)"
fi

cp -f "$SCRIPT_DIR/RESTORE.md" "$MNT/README-RESTORE.md" 2>/dev/null || true
{
  echo "Last sync:  $(date '+%F %T %z')"
  echo "Host:       $(hostname)"
  echo "Immich:     $IMMICH_UPLOAD_LOCATION"
  echo "Portainer:  $PORTAINER_DATA_DIR"
  echo "DB dump:    $([[ $DB_DUMPED -eq 1 ]] && echo fresh || echo "not made (see log)")"
} > "$CUR/LAST_SYNC.txt"

# -------------------------------------------------------------- snapshot ----
mkdir -p "$SNAPDIR"
SNAP_NAME="$(date +%Y-%m-%d_%H%M%S)"
btrfs subvolume snapshot -r "$CUR" "$SNAPDIR/$SNAP_NAME" >/dev/null || die "Snapshot failed"
log "Snapshot created: snapshots/$SNAP_NAME"

shopt -s nullglob
SNAPS=("$SNAPDIR"/20??-??-??_??????)
shopt -u nullglob
EXCESS=$(( ${#SNAPS[@]} - SNAPSHOT_KEEP ))
for (( i = 0; i < EXCESS; i++ )); do
  if btrfs subvolume delete -c "${SNAPS[$i]}" >/dev/null; then
    log "Pruned old snapshot $(basename "${SNAPS[$i]}")"
  else
    warn "Could not prune old snapshot $(basename "${SNAPS[$i]}")"
  fi
done

# ---------------------------------------------------------------- finish ----
USED_PCT="$(df --output=pcent "$MNT" | tail -n1 | tr -dc '0-9')"
AVAIL_AFTER="$(df -B1 --output=avail "$MNT" | tail -n1 | tr -d ' ')"
if (( USED_PCT >= SPACE_WARN_PERCENT )); then
  warn "Drive is ${USED_PCT}% full ($(hr "$AVAIL_AFTER") free). Reduce SNAPSHOT_KEEP or plan a bigger drive."
fi

ELAPSED=$(( $(date +%s) - START_TS ))
MSG="Snapshot $SNAP_NAME. $(IFS='; '; echo "${SUMMARY[*]}"). Drive ${USED_PCT}% used, $(hr "$AVAIL_AFTER") free. Took $((ELAPSED / 60))m$((ELAPSED % 60))s."

if (( ${#WARNINGS[@]} )); then
  MSG+=" WARNINGS: $(IFS=' | '; echo "${WARNINGS[*]}")"
fi

WAS_OURS=$MOUNTED_BY_US
if do_unmount; then
  if (( WAS_OURS )); then
    MSG+=" Drive unmounted: safe to unplug."
  else
    MSG+=" Drive was mounted by OMV: unmount it there before unplugging."
  fi
  PRIO=default; (( ${#WARNINGS[@]} )) && PRIO=high
  log "SUCCESS: $MSG"
  notify "done" "$MSG" "$PRIO"
else
  log "SUCCESS (sync ok) but unmount failed: $MSG"
  notify "done, NOT unmounted" "$MSG Could not unmount, do not unplug yet." high
fi
