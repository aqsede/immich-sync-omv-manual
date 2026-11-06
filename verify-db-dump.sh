#!/usr/bin/env bash
#
# Proves a database dump actually restores, WITHOUT touching your live Immich:
# starts a throwaway Postgres from the same image/settings as your Immich database
# container, with no network and its own scratch volume, restores the dump into it
# the way Immich documents, compares row counts with the live database, then
# deletes the container and volume.
#
#   sudo bash ./verify-db-dump.sh [path/to/dump.sql.gz]
#
# With no argument it tests the newest dump in <IMMICH_UPLOAD_LOCATION>/backups.
# To test the one on your USB drive: ./verify-db-dump.sh /mnt/<drive>/current/db-dumps/immich-db-XXXX.sql.gz
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 2; }
[[ -r $ENV_FILE ]] || { echo "Missing $ENV_FILE" >&2; exit 2; }
set -a; . "$ENV_FILE"; set +a
DB_DUMP_CONTAINER="${DB_DUMP_CONTAINER-immich_postgres}"
DB_DUMP_USER="${DB_DUMP_USER:-}"
DB_DUMP_DBNAME="${DB_DUMP_DBNAME:-}"
. "$SCRIPT_DIR/lib.sh"

fail() { echo "FAILED: $*" >&2; exit 1; }

[[ -n $DB_DUMP_CONTAINER ]] || fail "DB_DUMP_CONTAINER is empty in .env"
[[ "$(docker inspect -f '{{.State.Running}}' "$DB_DUMP_CONTAINER" 2>/dev/null || true)" == "true" ]] \
  || fail "container '$DB_DUMP_CONTAINER' is not running"
detect_db_settings

DUMP="${1:-}"
if [[ -z $DUMP ]]; then
  DUMP="$(find "$IMMICH_UPLOAD_LOCATION/backups" -maxdepth 1 -type f -name '*.sql.gz' -printf '%T@ %p\n' 2>/dev/null \
          | sort -rn | head -n1 | cut -d' ' -f2-)"
fi
[[ -n $DUMP && -f $DUMP ]] || fail "no dump found (pass a path as the first argument)"
gzip -t "$DUMP" || fail "$DUMP is not a valid gzip file"
echo "Testing dump: $DUMP ($(numfmt --to=iec --suffix=B "$(stat -c %s "$DUMP")"))"

DOCKER_ROOT="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
AVAIL="$(df -B1 --output=avail "$DOCKER_ROOT" | tail -n1 | tr -d ' ')"
NEED=$(( $(stat -c %s "$DUMP") * 10 ))
(( AVAIL > NEED )) || fail "not enough free space for the scratch database on $DOCKER_ROOT (have $(numfmt --to=iec "$AVAIL"), want ~$(numfmt --to=iec "$NEED"))"

IMAGE="$(docker inspect -f '{{.Config.Image}}' "$DB_DUMP_CONTAINER")"
# sed drops the blank line docker inspect appends; an empty "" argument made postgres exit
mapfile -t CMD < <(docker inspect -f '{{range .Config.Cmd}}{{println .}}{{end}}' "$DB_DUMP_CONTAINER" | sed '/^$/d')
NAME="immich-restore-test-$$"

cleanup() {
  docker rm -f -v "$NAME" >/dev/null 2>&1 || true
  echo "Throwaway container and volume removed."
}
trap cleanup EXIT

echo "Starting throwaway Postgres ($IMAGE), no network ..."
docker run -d --name "$NAME" --network none \
  --env-file <(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$DB_DUMP_CONTAINER" \
               | grep -E '^POSTGRES_(USER|DB|PASSWORD|INITDB_ARGS)=') \
  "$IMAGE" "${CMD[@]}" >/dev/null

echo -n "Waiting for it to initialise "
ready=0
for _ in $(seq 1 240); do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]]; then
    echo
    echo "--- container logs ---" >&2
    docker logs "$NAME" 2>&1 | tail -n 25 >&2
    fail "the throwaway Postgres container exited (logs above)"
  fi
  # TCP on loopback: the temporary init-time server only listens on a unix socket,
  # so this only succeeds once the real server is up.
  if docker exec "$NAME" pg_isready -h 127.0.0.1 -U "$DB_DUMP_USER" -d "$DB_DUMP_DBNAME" >/dev/null 2>&1; then
    ready=1; break
  fi
  echo -n "."; sleep 1
done
echo
(( ready )) || { docker logs "$NAME" 2>&1 | tail -n 25 >&2; fail "throwaway Postgres did not become ready in 4 minutes"; }
sleep 2

echo "Restoring (single transaction, stops at first error). This can take several minutes and prints nothing meanwhile ..."
gunzip --stdout "$DUMP" \
  | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
  | docker exec -i "$NAME" psql --dbname="$DB_DUMP_DBNAME" --username="$DB_DUMP_USER" \
      --single-transaction --set ON_ERROR_STOP=on -q >/dev/null \
  || fail "restore reported an error: this dump is NOT restorable as-is"

count_rows() {  # <container> <table>
  docker exec "$1" psql --username="$DB_DUMP_USER" --dbname="$DB_DUMP_DBNAME" -tAX -c \
    "select case when to_regclass(format('public.%I','$2')) is null then -1 else (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I','$2'), false, true, '')))[1]::text::bigint end"
}

echo
printf '%-12s %12s %12s\n' "table" "live" "restored"
bad_tables=0
for t in asset album person user; do
  live="$(count_rows "$DB_DUMP_CONTAINER" "$t" || echo '?')"
  rest="$(count_rows "$NAME" "$t" || echo '?')"
  printf '%-12s %12s %12s\n' "$t" "$live" "$rest"
  if [[ $t == asset ]] && [[ $rest == "-1" || $rest == "?" || $rest == "0" ]] && [[ $live != "0" && $live != "-1" && $live != "?" ]]; then
    bad_tables=1
  fi
done
echo
if (( bad_tables )); then
  fail "restored database has no assets but the live one does"
fi
echo "PASSED: the dump restores cleanly. 'restored' may trail 'live' slightly if photos were added since the dump."
