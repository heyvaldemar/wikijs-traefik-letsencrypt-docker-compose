#!/usr/bin/env bash
# wikijs-restore-database.sh [backup-file-name]
#
# Replaces the Wiki.js database with one of the dumps the `backup` job wrote.
#
#   ./wikijs-restore-database.sh               list and ask
#   ./wikijs-restore-database.sh <file-name>   restore that one
#
# EXPERIMENTAL (branch compose-jobs-spike). The backup is now a scheduled job
# (Compose >= 5.8.0, Engine >= 29.10.0 with the jobs extension). A job runs to
# completion and its container is removed, so this script can no longer exec
# into a long-running `backups` container, as the previous version did. Instead:
#   - the backup directory, file prefix and image come from the `backup` job
#     as `docker compose config` resolves it (the same .env the job runs with,
#     so the two cannot disagree);
#   - the dumps are read from the job's backup volume by a throwaway container
#     started from the job's own image;
#   - the dump is loaded through the running database container over its local
#     socket, with that container's own POSTGRES_USER / POSTGRES_DB.
#
# CI runs this exact file against a marker written after the backup it
# restores, and requires the data in the backup to come back.
#
# Needs jq. Set COMPOSE_PROJECT_NAME if the stack was started with a -p other
# than wikijs, DOCKER_COMPOSE_FILE if the compose file is not the one next to
# this script.
set -Eeuo pipefail

PROJECT="${COMPOSE_PROJECT_NAME:-wikijs}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE_PATH="${DOCKER_COMPOSE_FILE:-$HERE/wikijs-traefik-letsencrypt-docker-compose.yml}"
APP_SERVICE="wikijs"
DB_SERVICE="postgres"
JOB="backup"

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }

cid() {  # the container of one compose service in this project
  docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" | head -n 1
}
APP="$(cid "$APP_SERVICE")"; DBC="$(cid "$DB_SERVICE")"
[ -n "$DBC" ] || { echo "error: no $DB_SERVICE container in compose project '$PROJECT' (set COMPOSE_PROJECT_NAME)" >&2; exit 1; }
[ -n "$APP" ] || { echo "error: no $APP_SERVICE container in compose project '$PROJECT'" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$DBC")" = true ] || { echo "error: the $DB_SERVICE container is not running" >&2; exit 1; }

# The resolved job. It holds the database password in its environment: it is
# only ever read into variables below, never printed.
CFG="$(docker compose -p "$PROJECT" -f "$COMPOSE_FILE_PATH" config --format json)"
jq -e --arg j "$JOB" '.jobs[$j]' <<<"$CFG" >/dev/null \
  || { echo "error: the compose file declares no '$JOB' job" >&2; exit 1; }
IMAGE="$(jq -r --arg j "$JOB" '.jobs[$j].image' <<<"$CFG")"
DIR="$(jq -r --arg j "$JOB" '.jobs[$j].environment.POSTGRES_BACKUPS_PATH' <<<"$CFG")"
NAME="$(jq -r --arg j "$JOB" '.jobs[$j].environment.POSTGRES_BACKUP_NAME' <<<"$CFG")"
VOL_SRC="$(jq -r --arg j "$JOB" --arg d "$DIR" '.jobs[$j].volumes[] | select(.target == $d) | .source' <<<"$CFG")"
# Compose names a volume <project>_<key> when it creates it; a volume only a job
# uses is created by the engine under the bare key (Compose 5.8.0), and is not
# in the top-level volumes of the resolved file at all, so fall back to the key.
VOL="$(jq -r --arg s "$VOL_SRC" '.volumes[$s].name // $s' <<<"$CFG")"
[ -n "$IMAGE" ] && [ -n "$DIR" ] && [ -n "$NAME" ] && [ -n "$VOL" ] \
  || { echo "error: could not read the backup directory, name, image or volume from the '$JOB' job" >&2; exit 1; }

in_volume() {  # run a command in a throwaway container that has the backups read-only
  docker run --rm -i -v "$VOL:$DIR:ro" "$IMAGE" "$@"
}

SELECTED="${1:-}"
if [ -z "$SELECTED" ]; then
  echo "Database backups in $DIR:"
  in_volume sh -c "ls -1 '$DIR' | grep -E '^$NAME-.*\\.gz\$'" || { echo "  none found" >&2; exit 1; }
  read -r -p "File name to restore: " SELECTED
fi
case "$SELECTED" in ""|*/*) echo "error: give a file name from the list, not a path" >&2; exit 1 ;; esac
in_volume gunzip -t "$DIR/$SELECTED" >/dev/null \
  || { echo "error: $DIR/$SELECTED is missing or does not open; nothing was changed" >&2; exit 1; }

echo "Stopping $APP_SERVICE so nothing writes while the database is replaced"
docker stop "$APP" >/dev/null
restart() { docker start "$APP" >/dev/null && echo "Started $APP_SERVICE"; }
trap 'restart' EXIT
echo "Restoring $SELECTED"
# shellcheck disable=SC2016  # expands in the database container, from its own environment
if ! { docker exec "$DBC" sh -c 'set -eu
         dropdb --force -U "$POSTGRES_USER" --if-exists "$POSTGRES_DB"
         createdb -U "$POSTGRES_USER" "$POSTGRES_DB"' \
       && in_volume gunzip -c "$DIR/$SELECTED" \
         | docker exec -i "$DBC" sh -c 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null'; }; then
  echo "error: the restore failed part-way. The database may now be empty: restore another backup before using Wiki.js." >&2
  exit 1
fi
echo "Restored $SELECTED"
