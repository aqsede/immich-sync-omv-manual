# shellcheck shell=bash
# Shared helpers, sourced by backup.sh, preflight.sh and verify-db-dump.sh.

# rsync filter args for a source, one per line.
# Excluded Immich folders keep their .immich marker file: Immich refuses to start
# after a restore if a folder's marker is missing (docs: "System Integrity").
extra_args() {
  case "$1" in
    immich)
      local d
      for d in $IMMICH_EXCLUDE_DIRS; do
        printf -- '--include=/%s/\n--include=/%s/.immich\n--exclude=/%s/*\n' "$d" "$d" "$d"
      done ;;
  esac
}

# run_rsync <src> <dst> [extra rsync args...]   (prints rsync --stats output)
run_rsync() {
  local src="$1" dst="$2" rc=0
  shift 2
  LC_ALL=C rsync -aH --numeric-ids --delete --delete-excluded --stats "$@" "$src/" "$dst/" || rc=$?
  [[ $rc -eq 0 || $rc -eq 24 ]] || return "$rc"   # 24 = files vanished mid-transfer, fine
}

# Lenient: integer or 0 (only for log lines).
stat_num() {
  local v
  v="$(grep -m1 "^$1:" <<<"$2" | sed -E 's/^[^:]+: ([0-9,]+).*/\1/' | tr -d ',' || true)"
  echo "${v:-0}"
}

# Strict: prints the integer, or fails if the line is missing or not a number.
# Used for the space check and delete guard so they fail CLOSED if rsync's
# output format ever changes.
require_stat() {
  local line v
  line="$(grep -m1 "^$1:" <<<"$2" || true)"
  [[ -n $line ]] || return 1
  v="$(sed -E 's/^[^:]+: ([0-9,]+).*/\1/' <<<"$line" | tr -d ',')"
  [[ $v =~ ^[0-9]+$ ]] || return 1
  echo "$v"
}

# Fill DB_DUMP_USER / DB_DUMP_DBNAME from the Postgres container's own env
# (POSTGRES_USER / POSTGRES_DB) when .env leaves them empty.
detect_db_settings() {
  local envs=""
  if [[ -n ${DB_DUMP_CONTAINER:-} ]] && command -v docker >/dev/null 2>&1; then
    envs="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$DB_DUMP_CONTAINER" 2>/dev/null || true)"
  fi
  if [[ -z ${DB_DUMP_USER:-} ]]; then
    DB_DUMP_USER="$(sed -n 's/^POSTGRES_USER=//p' <<<"$envs" | head -n1)"
  fi
  if [[ -z ${DB_DUMP_DBNAME:-} ]]; then
    DB_DUMP_DBNAME="$(sed -n 's/^POSTGRES_DB=//p' <<<"$envs" | head -n1)"
  fi
  DB_DUMP_USER="${DB_DUMP_USER:-postgres}"
  DB_DUMP_DBNAME="${DB_DUMP_DBNAME:-immich}"
}
