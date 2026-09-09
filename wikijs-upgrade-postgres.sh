#!/bin/bash
# Move this deployment's PostgreSQL to the major version the compose file pins.
#
# A PostgreSQL data directory belongs to one major version. Start 17 on a
# directory that 14 wrote and the server exits with "database files are
# incompatible with server", so `git pull && docker compose up -d` is not the
# upgrade path across a major: the data has to be dumped by the old server and
# loaded into a cluster the new one initialises.
#
# What this does, stopping at the first thing that fails:
#   1. reads the major the compose file pins and the major the running
#      container reports, and does nothing when they already match
#   2. dumps the database with the OLD server's own pg_dump, to a file beside
#      this script, and refuses to go on if that dump is empty
#   3. stops the stack keeping every volume, and removes ONLY the postgres
#      data volume
#   4. starts the new postgres alone and waits until it accepts connections
#   5. loads the dump, then brings the rest of the stack back up
#
# The dump is left in place afterwards. Copy it somewhere else before you
# delete it: it is the only copy of the old cluster once step 3 has run.
#
#   ./wikijs-upgrade-postgres.sh --dry-run   say what would happen
#   ./wikijs-upgrade-postgres.sh             do it
set -euo pipefail
cd "$(dirname "$0")"

# The single quotes around every psql and pg_dump invocation below are
# deliberate: $POSTGRES_USER and $POSTGRES_DB have to expand inside the
# container, from its own environment, so this script never reads .env and
# the credentials never reach a host process list.

COMPOSE_FILE="wikijs-traefik-letsencrypt-docker-compose.yml"
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$(pwd)")}"
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done
dc() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

# 1. The two majors. The pinned one is read from the compose file, which is
#    the single source of truth for every version in this stack; the running
#    one is asked of the server itself rather than assumed from the last tag
#    somebody remembers deploying.
pinned="$(grep -oE 'postgres:\$\{[A-Z0-9_]+:-[0-9]+' "$COMPOSE_FILE" | grep -oE '[0-9]+$' | head -1)"
if [ -z "$pinned" ]; then
  echo "could not read the pinned PostgreSQL major from $COMPOSE_FILE" >&2
  exit 1
fi
cid="$(dc ps -q postgres 2>/dev/null || true)"
if [ -z "$cid" ]; then
  echo "the postgres container is not running: start the stack first, or there is nothing to migrate" >&2
  exit 1
fi
running="$(docker exec "$cid" postgres --version | grep -oE '[0-9]+' | head -1)"
echo "pinned major: $pinned   running major: $running"
if [ "$pinned" = "$running" ]; then
  echo "already on $pinned — nothing to do"
  exit 0
fi
if [ "$pinned" -lt "$running" ]; then
  echo "the compose file pins $pinned and the server runs $running: pg_dump cannot move data backwards, nothing done" >&2
  exit 1
fi

# 2. The dump, taken by the old server's own pg_dump so the client and the
#    cluster are the same major. The credentials are read from the container's
#    environment, never from .env: this script never sees them.
stamp="$(date -u '+%Y%m%d-%H%M%S')"
dump="wikijs-postgres-${running}-to-${pinned}-${stamp}.sql.gz"
echo "dumping to $dump"
if [ "$DRY_RUN" = "true" ]; then
  echo "--dry-run: would dump, then remove the postgres volume and restore into $pinned"
  exit 0
fi
# shellcheck disable=SC2016  # expands in the container, not here — see the note above
dc exec -T postgres sh -c 'pg_dump --no-owner --no-acl -U "$POSTGRES_USER" -d "$POSTGRES_DB"' | gzip > "$dump"
# An empty or truncated dump here would be discovered after the old cluster is
# already gone, which is the one order this must never happen in.
if [ ! -s "$dump" ] || ! gzip -t "$dump" 2>/dev/null; then
  echo "the dump is empty or not a valid archive — nothing has been removed, the stack is untouched" >&2
  exit 1
fi
# Read the header into a variable rather than piping into `grep -q`: grep
# closes the pipe on its first match, gzip dies of SIGPIPE, and under
# `set -o pipefail` that non-zero status would reject every correct dump ever
# taken. Which it did, on the first run of this script.
head_text="$(gzip -dc "$dump" 2>/dev/null | head -20 || true)"
case "$head_text" in
  *"PostgreSQL database dump"*) ;;
  *) echo "the dump does not look like a pg_dump archive — nothing has been removed" >&2; exit 1 ;;
esac
echo "dump written: $(wc -c < "$dump") bytes"

# 3. The data volume, and only that one. Named from the container's own mount
#    table rather than assembled from the project name, which is wrong the
#    moment somebody sets COMPOSE_PROJECT_NAME.
vol="$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}')"
if [ -z "$vol" ]; then
  echo "could not find the postgres data volume — the dump is in $dump and nothing has been removed" >&2
  exit 1
fi
echo "stopping the stack, keeping every volume"
dc down
echo "removing the old data directory: $vol"
docker volume rm "$vol" >/dev/null

# 4. The new cluster, alone, so nothing writes to it before the data is in.
echo "starting PostgreSQL $pinned"
dc up -d postgres
for _ in $(seq 1 60); do
  # shellcheck disable=SC2016  # expands in the container, not here — see the note above
  if dc exec -T postgres sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
# shellcheck disable=SC2016  # expands in the container, not here — see the note above
if ! dc exec -T postgres sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1; then
  echo "PostgreSQL $pinned did not come up — the dump is in $dump" >&2
  exit 1
fi

# 5. The data. ON_ERROR_STOP so a failed statement fails the migration instead
#    of leaving a half-loaded database that looks like it worked.
echo "loading $dump"
# shellcheck disable=SC2016  # expands in the container, not here — see the note above
gzip -dc "$dump" | dc exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -q -o /dev/null -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
echo "bringing the rest of the stack up"
dc up -d
echo
echo "PostgreSQL is on $pinned and the data is loaded."
echo "The dump is still here: $dump — copy it somewhere else before you delete it."
