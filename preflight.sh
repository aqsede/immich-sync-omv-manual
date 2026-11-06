#!/usr/bin/env bash
#
# Read-only checks. Changes nothing on the NAS, in Immich, or on the drive.
#   sudo ./preflight.sh [--notify-test]
# Run it before enabling anything, and again after an OMV/Immich/Docker upgrade.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
NOTIFY_TEST=0
[[ ${1:-} == "--notify-test" ]] && NOTIFY_TEST=1

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo ./preflight.sh" >&2; exit 2; }
[[ -r $ENV_FILE ]] || { echo "Missing $ENV_FILE" >&2; exit 2; }
set -a; . "$ENV_FILE"; set +a
IMMICH_EXCLUDE_DIRS="${IMMICH_EXCLUDE_DIRS-thumbs encoded-video}"
DB_DUMP_CONTAINER="${DB_DUMP_CONTAINER-immich_postgres}"
. "$SCRIPT_DIR/lib.sh"

PASS=0; WARN=0; FAIL=0
ok()  { echo "  [ OK ] $*"; PASS=$((PASS + 1)); }
wn()  { echo "  [WARN] $*"; WARN=$((WARN + 1)); }
bad() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
sec() { echo; echo "== $* =="; }

# ------------------------------------------------------------------ system ---
sec "System"
. /etc/os-release 2>/dev/null || true
echo "  OS: ${PRETTY_NAME:-unknown} (codename: ${VERSION_CODENAME:-?})"
OMV_VER="$(dpkg-query -W -f='${Version}' openmediavault 2>/dev/null || true)"
if [[ -n $OMV_VER ]]; then
  echo "  OpenMediaVault package: $OMV_VER"
else
  wn "openmediavault package not found (not an OMV system? the script itself does not need OMV)"
fi
case "${VERSION_CODENAME:-}" in
  bookworm) ok "Debian 12 (OMV 7 base)" ;;
  trixie)   ok "Debian 13 (OMV 8 base)" ;;
  *)        wn "Untested Debian release '${VERSION_CODENAME:-?}'; only Debian 12/13 (OMV 7/8) were considered" ;;
esac
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  ok "bash $BASH_VERSION"
else
  bad "bash $BASH_VERSION is too old (need >= 4.4)"
fi
for c in rsync btrfs flock findmnt df numfmt gzip udevadm systemctl timeout; do
  if command -v "$c" >/dev/null 2>&1; then :; else bad "missing command: $c"; fi
done
echo "  $(rsync --version 2>/dev/null | head -n1)"
echo "  $(btrfs --version 2>/dev/null | head -n1)"
if dpkg -s openmediavault-usbbackup >/dev/null 2>&1; then
  wn "OMV 'USB Backup' plugin is installed. Do NOT configure it for the same drive (two backups would fire)."
fi

# --------------------------------------------------------- rsync self-test ---
sec "rsync behaviour (temp dirs only)"
selftest() {
  local t out new del
  t="$(mktemp -d)" || return 1
  mkdir -p "$t/src/thumbs/sub" "$t/src/library" "$t/dst/thumbs"
  touch "$t/src/thumbs/.immich" "$t/src/thumbs/sub/a.webp" "$t/src/library/p.jpg" "$t/dst/thumbs/stale.webp"
  local IMMICH_EXCLUDE_DIRS="thumbs"
  local -a X
  mapfile -t X < <(extra_args immich)
  out="$(run_rsync "$t/src" "$t/dst" -n "${X[@]}")" || { rm -rf "$t"; return 1; }
  new="$(require_stat 'Total transferred file size' "$out")" || { echo "stats: transferred-size line not found"; rm -rf "$t"; return 1; }
  del="$(require_stat 'Number of deleted files' "$out")"     || { echo "stats: deleted-files line not found"; rm -rf "$t"; return 1; }
  out="$(run_rsync "$t/src" "$t/dst" "${X[@]}")" || { rm -rf "$t"; return 1; }
  local r=0
  [[ -e $t/dst/thumbs/.immich ]]      || { echo "filter: .immich marker was NOT kept"; r=1; }
  [[ ! -e $t/dst/thumbs/sub ]]        || { echo "filter: excluded thumbs content was copied"; r=1; }
  [[ ! -e $t/dst/thumbs/stale.webp ]] || { echo "filter: stale excluded file was not cleaned"; r=1; }
  [[ -e $t/dst/library/p.jpg ]]       || { echo "filter: normal file was not copied"; r=1; }
  rm -rf "$t"
  return $r
}
if selftest; then
  ok "rsync statistics parse correctly and the exclude filter keeps .immich markers"
else
  bad "rsync self-test failed (see message above); backup.sh would refuse to run"
fi

# ----------------------------------------------------------------- sources ---
sec "Sources"
for pair in "Immich upload:$IMMICH_UPLOAD_LOCATION" "Portainer data:$PORTAINER_DATA_DIR"; do
  label="${pair%%:*}"; path="${pair#*:}"
  if [[ -d $path && -n "$(ls -A "$path" 2>/dev/null)" ]]; then
    ok "$label exists and is not empty: $path"
  else
    bad "$label missing or empty: $path"
  fi
done
for f in upload library thumbs encoded-video profile backups; do
  if [[ -e "$IMMICH_UPLOAD_LOCATION/$f/.immich" ]]; then
    :
  else
    wn "no .immich marker in $IMMICH_UPLOAD_LOCATION/$f (folder unused or UPLOAD_LOCATION is wrong?)"
  fi
done
[[ -d $PORTAINER_DATA_DIR/compose ]] \
  && ok "Portainer stack folder found: $(ls -1 "$PORTAINER_DATA_DIR/compose" | tr '\n' ' ')" \
  || wn "no compose/ folder in $PORTAINER_DATA_DIR (stacks created from git/upload may be stored elsewhere)"
if [[ -n "$(find "$IMMICH_UPLOAD_LOCATION/backups" -maxdepth 1 -name '*.sql.gz' -mtime -3 -print -quit 2>/dev/null)" ]]; then
  ok "Immich's own automatic DB dump is recent (<3 days) in backups/"
else
  wn "no Immich DB dump newer than 3 days in $IMMICH_UPLOAD_LOCATION/backups"
fi

# ---------------------------------------------------------------- database ---
sec "Immich database (read-only queries)"
if [[ -z $DB_DUMP_CONTAINER ]]; then
  wn "fresh DB dump is disabled (DB_DUMP_CONTAINER empty); relying on Immich's own dumps"
elif ! command -v docker >/dev/null 2>&1; then
  bad "docker not found"
elif [[ "$(docker inspect -f '{{.State.Running}}' "$DB_DUMP_CONTAINER" 2>/dev/null)" != "true" ]]; then
  bad "container '$DB_DUMP_CONTAINER' is not running. Postgres containers present:"
  docker ps --format '        {{.Names}}  ({{.Image}})' | grep -i -E 'postgres|database|db' || echo "        (none matched)"
else
  detect_db_settings
  ok "container '$DB_DUMP_CONTAINER' running (image: $(docker inspect -f '{{.Config.Image}}' "$DB_DUMP_CONTAINER"))"
  echo "  database='$DB_DUMP_DBNAME' user='$DB_DUMP_USER'"
  if docker exec "$DB_DUMP_CONTAINER" psql --username="$DB_DUMP_USER" --dbname="$DB_DUMP_DBNAME" -tAX -c 'select 1' >/dev/null 2>&1; then
    ok "can connect to the database"
    cnt="$(docker exec "$DB_DUMP_CONTAINER" psql --username="$DB_DUMP_USER" --dbname="$DB_DUMP_DBNAME" -tAX -c \
      "select case when to_regclass('public.asset') is null then -1 else (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.asset', false, true, '')))[1]::text::bigint end" 2>/dev/null)"
    echo "  assets in database: ${cnt:-?}"
    t0=$(date +%s)
    if bytes="$(docker exec "$DB_DUMP_CONTAINER" pg_dump --clean --if-exists --dbname="$DB_DUMP_DBNAME" --username="$DB_DUMP_USER" | gzip | wc -c)" \
       && [[ $bytes -gt 1000 ]]; then
      ok "pg_dump works: $(numfmt --to=iec --suffix=B "$bytes") compressed in $(( $(date +%s) - t0 ))s (streamed to nowhere, nothing written)"
    else
      bad "pg_dump failed or produced almost nothing (check DB_DUMP_USER / DB_DUMP_DBNAME)"
    fi
  else
    bad "cannot run psql in '$DB_DUMP_CONTAINER' as '$DB_DUMP_USER' on '$DB_DUMP_DBNAME'. Set DB_DUMP_USER / DB_DUMP_DBNAME in .env"
  fi
fi

# ------------------------------------------------------------- drive/trigger ---
sec "Drive and trigger"
DEV="/dev/disk/by-uuid/$USB_UUID"
RULE=/etc/udev/rules.d/99-immich-usb-backup.rules
UNIT=/etc/systemd/system/immich-usb-backup.service
if [[ -b $DEV ]]; then
  real="$(readlink -f "$DEV")"
  ok "drive present: $real (fstype: $(blkid -s TYPE -o value "$real" 2>/dev/null))"
  [[ "$(blkid -s TYPE -o value "$real" 2>/dev/null)" == btrfs ]] || bad "drive is not btrfs"
  m="$(findmnt -rn -S "UUID=$USB_UUID" -o TARGET 2>/dev/null | head -n1)"
  [[ -n $m ]] && wn "already mounted at $m (backup.sh will use it and leave it mounted; unmount it in OMV afterwards)" \
              || ok "not mounted (backup.sh will mount and unmount it itself)"
else
  wn "drive with UUID $USB_UUID is not plugged in (fine, but then the drive checks are skipped)"
  real=""
fi
if [[ -f $RULE ]]; then
  grep -q "$USB_UUID" "$RULE" && ok "udev rule installed and matches USB_UUID" || bad "udev rule UUID differs from .env: re-run ./install.sh"
  if udevadm verify "$RULE" >/dev/null 2>&1; then ok "udev rule syntax valid"; else wn "udevadm verify unavailable or reported issues"; fi
  if [[ -n $real ]]; then
    wants="$(udevadm test --action=add "$(udevadm info -q path -n "$real")" 2>&1 | grep -o 'SYSTEMD_WANTS=[^ ]*' | head -n1)"
    [[ $wants == *immich-usb-backup.service* ]] \
      && ok "simulated 'add' event would start immich-usb-backup.service (nothing was started)" \
      || bad "simulated 'add' event does NOT start the service"
  fi
else
  echo "  (udev rule not installed yet: expected before the first attended runs)"
fi
[[ -f $UNIT ]] && ok "systemd unit installed" || echo "  (systemd unit not installed yet)"

# ----------------------------------------------------------- notifications ---
sec "Notifications"
[[ -n ${NOTIFY_WEBHOOK_URL:-} ]] && echo "  webhook configured" || echo "  webhook not configured"
[[ -n ${NOTIFY_EMAIL:-} ]]       && echo "  email configured: $NOTIFY_EMAIL" || echo "  email not configured"
if (( NOTIFY_TEST )); then
  [[ -n ${NOTIFY_WEBHOOK_URL:-} ]] && { curl -fsS -m 15 -H "Title: Immich USB backup: test" -d "preflight test message" "$NOTIFY_WEBHOOK_URL" >/dev/null && ok "webhook test sent" || bad "webhook test failed"; }
  if [[ -n ${NOTIFY_EMAIL:-} ]]; then
    printf 'To: %s\nSubject: Immich USB backup: test\n\npreflight test message\n' "$NOTIFY_EMAIL" | timeout 30 sendmail -t \
      && ok "email test handed to sendmail (check your inbox)" || bad "email test failed or timed out"
  fi
else
  echo "  (run with --notify-test to send a test message)"
fi

echo
echo "Result: $PASS ok, $WARN warnings, $FAIL failures"
(( FAIL == 0 ))
