#!/usr/bin/env bash
# End-to-end proof for the experimental `jobs.backup` (branch compose-jobs-spike).
#
# Requires: docker, docker compose >= 5.8.0, Docker Engine >= 29.10.0 running
# with the jobs extension, jq, and the stack already up. BACKUP_CRON in .env
# must be short (CI uses "*/2 * * * *").
#
# It proves three things and nothing else:
#   1. the engine fired the job on its own: `docker events` (started before
#      `compose up`, read from JOBS_EVENTS_FILE) shows runs of the job created,
#      started and finished with exit code 0, and this script never runs
#      `docker compose run`;
#   2. a backup the job wrote on its own contains data written just before it
#      ran, and the shipped ./wikijs-restore-database.sh brings that data back
#      after it was deleted;
#   3. a failed run is visible: with the database stopped, the next run exits
#      non-zero, its container is kept, and a .failed file is left.
#
# Run from the repository root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-wikijs}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-wikijs-traefik-letsencrypt-docker-compose.yml}"
EVENTS_FILE="${JOBS_EVENTS_FILE:?set JOBS_EVENTS_FILE to the file that docker events (JSON format) writes}"
JOB="backup"
FIRE_WAIT="${FIRE_WAIT:-300}"      # seconds to wait for one scheduled run
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

compose() { docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" "$@"; }

DBC="$(compose ps -aq postgres | head -n 1)"
[ -n "$DBC" ] || { echo "error: database container not found" >&2; exit 1; }

# The job as Compose resolves it: image, backup directory, file prefix, volume.
# Holds the database password in its environment; only ever read into
# variables, never printed.
CFG="$(compose config --format json)"
IMAGE="$(jq -r --arg j "$JOB" '.jobs[$j].image' <<<"$CFG")"
DIR="$(jq -r --arg j "$JOB" '.jobs[$j].environment.POSTGRES_BACKUPS_PATH' <<<"$CFG")"
NAME="$(jq -r --arg j "$JOB" '.jobs[$j].environment.POSTGRES_BACKUP_NAME' <<<"$CFG")"
VOL_SRC="$(jq -r --arg j "$JOB" --arg d "$DIR" '.jobs[$j].volumes[] | select(.target == $d) | .source' <<<"$CFG")"
VOL="$(jq -r --arg s "$VOL_SRC" '.volumes[$s].name // $s' <<<"$CFG")"
CRON="$(jq -r --arg j "$JOB" '.jobs[$j].triggers.schedule[0].cron' <<<"$CFG")"

in_volume() { docker run --rm -i -v "$VOL:$DIR:ro" "$IMAGE" "$@"; }
db_sql() { printf '%s\n' "$1" | docker exec -i "$DBC" sh -c 'psql -tAq -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'; }
note() { echo "  $*"; echo "- $*" >> "$SUMMARY"; }

# --- Test runner ---
PASSED=0; FAILED=0; FAILURES=()
run_test() {
  local name="$1"
  echo; echo "=== $name ==="; echo "### $name" >> "$SUMMARY"
  if "$name"; then echo "  PASS: $name"; PASSED=$((PASSED + 1))
  else echo "  FAIL: $name" >&2; FAILED=$((FAILED + 1)); FAILURES+=("$name"); fi
}
fail() { echo "  ASSERT: $*" >&2; return 1; }

# Finished runs of the job after epoch $1, as "time<TAB>exit<TAB>run-id<TAB>oneoff".
finished_runs_after() {
  jq -r --argjson t "$1" '
    select(.Type == "container" and .Action == "die"
           and .Actor.Attributes["com.docker.job.id"] != null
           and .time > $t)
    | [.time, .Actor.Attributes.exitCode, .Actor.Attributes["com.docker.job.run-id"][0:12],
       .Actor.Attributes["com.docker.compose.oneoff"]] | @tsv' "$EVENTS_FILE"
}
# Created runs of the job at or after epoch $1 (a run that started before the
# data existed cannot contain it).
created_runs_after() {
  jq -r --argjson t "$1" '
    select(.Type == "container" and .Action == "create"
           and .Actor.Attributes["com.docker.job.id"] != null
           and .time >= $t)
    | [.time, .Actor.Attributes["com.docker.job.run-id"][0:12]] | @tsv' "$EVENTS_FILE"
}
wait_for_runs() {  # wait_for_runs <after-epoch> <count> <want-exit: zero|nonzero>
  local after="$1" count="$2" want="$3" waited=0 n
  while :; do
    if [ "$want" = zero ]; then n="$(finished_runs_after "$after" | awk -F'\t' '$2 == 0' | wc -l)"
    else n="$(finished_runs_after "$after" | awk -F'\t' '$2 != 0' | wc -l)"; fi
    [ "$n" -ge "$count" ] && return 0
    [ "$waited" -lt "$FIRE_WAIT" ] || return 1
    sleep 5; waited=$((waited + 5))
  done
}

TOKEN="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
BASELINE=""

test_versions_and_schedule() {
  local engine compose_v
  engine="$(docker version --format '{{.Server.Version}}')"
  compose_v="$(docker compose version --short)"
  note "engine $engine, compose $compose_v, job '$JOB' cron '$CRON'"
  [ "$(printf '%s\n%s\n' 29.10.0 "$engine" | sort -V | head -n1)" = 29.10.0 ] || { fail "engine $engine is older than 29.10.0"; return 1; }
  [ "$(printf '%s\n%s\n' 5.8.0 "$compose_v" | sort -V | head -n1)" = 5.8.0 ] || { fail "compose $compose_v is older than 5.8.0"; return 1; }
  grep -q . "$EVENTS_FILE" || { fail "no events were captured: start docker events before compose up"; return 1; }
}

test_job_fires_by_itself() {
  local t0 first_wait runs created
  # Data that must end up in a backup written after this moment.
  db_sql "CREATE TABLE IF NOT EXISTS jobs_spike_proof (token text); INSERT INTO jobs_spike_proof VALUES ('$TOKEN');"
  t0="$(date +%s)"
  note "token written at epoch $t0; waiting up to ${FIRE_WAIT}s for the engine to fire the job (no compose run is ever invoked)"
  wait_for_runs "$t0" 1 zero || { fail "no scheduled run finished with exit 0 within ${FIRE_WAIT}s"; return 1; }
  # A second run proves it recurs on the clock, not once.
  first_wait="$(date +%s)"
  wait_for_runs "$t0" 2 zero || { fail "the schedule fired once but not twice within ${FIRE_WAIT}s more"; return 1; }
  runs="$(finished_runs_after "$t0" | awk -F'\t' '$2 == 0')"
  created="$(created_runs_after "$t0")"
  note "runs created by the engine after the token: $(wc -l <<<"$created") ($(awk -F'\t' '{printf "%s@%s ", $2, $1}' <<<"$created"))"
  note "runs finished with exit 0: $(wc -l <<<"$runs") ($(awk -F'\t' '{printf "%s@%s oneoff=%s ", $3, $1, $4}' <<<"$runs"))"
  [ "$(awk -F'\t' '$4 != "False"' <<<"$runs" | wc -l)" -eq 0 ] || { fail "a run is labelled oneoff: it was not a scheduled run"; return 1; }
  # Which of the job's files holds the token? Newest first.
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if in_volume sh -c "gunzip -c '$DIR/$f' | grep -qF '$TOKEN'"; then BASELINE="$f"; break; fi
  done < <(in_volume sh -c "ls -1 '$DIR' | grep -E '^$NAME-.*\\.gz\$' | sort -r")
  [ -n "$BASELINE" ] || { fail "none of the backups written by the job contains the token"; return 1; }
  note "backup that holds the token: $BASELINE"
  echo "  (waited $(( $(date +%s) - first_wait ))s for the second run after the first)"
}

test_restore_brings_the_data_back() {
  [ -n "$BASELINE" ] || { fail "no baseline backup from the previous test"; return 1; }
  db_sql "DELETE FROM jobs_spike_proof;
          CREATE TABLE IF NOT EXISTS restore_test (id int); INSERT INTO restore_test VALUES (1);"
  [ "$(db_sql "SELECT count(*) FROM jobs_spike_proof WHERE token = '$TOKEN';" | tr -d '[:space:]')" = 0 ] \
    || { fail "could not delete the token"; return 1; }
  echo "  restoring $BASELINE with the shipped ./wikijs-restore-database.sh"
  COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" DOCKER_COMPOSE_FILE="$REPO_ROOT/$DOCKER_COMPOSE_FILE" \
    ./wikijs-restore-database.sh "$BASELINE" || { fail "the shipped restore script failed"; return 1; }
  local got gone
  got="$(db_sql "SELECT count(*) FROM jobs_spike_proof WHERE token = '$TOKEN';" | tr -d '[:space:]')"
  gone="$(db_sql "SELECT to_regclass('public.restore_test');" | tr -d '[:space:]')"
  [ "$got" = 1 ] || { fail "the token written before the backup did not come back (count=$got)"; return 1; }
  [ -z "$gone" ] || { fail "the row written after the backup survived the restore"; return 1; }
  note "restore from $BASELINE: token back (count=1), post-backup marker gone"
}

test_failed_run_is_visible() {
  local t0 kept failed
  t0="$(date +%s)"
  echo "  stopping the database so the next scheduled run fails"
  docker stop "$DBC" >/dev/null
  wait_for_runs "$t0" 1 nonzero || { docker start "$DBC" >/dev/null; fail "no failed run within ${FIRE_WAIT}s"; return 1; }
  docker start "$DBC" >/dev/null
  kept="$(docker ps -a --filter 'label=com.docker.job.id' --filter 'status=exited' --format '{{.Names}} {{.Status}}' | head -n 3)"
  failed="$(in_volume sh -c "ls -1 '$DIR' | grep -E '\\.failed\$' | head -n 3" || true)"
  note "failed run: $(finished_runs_after "$t0" | awk -F'\t' '$2 != 0 {printf "%s exit=%s ", $3, $2}')"
  note "kept container: ${kept:-none}; .failed file: ${failed:-none}"
  [ -n "$kept" ] || { fail "Compose kept no container for the failed run"; return 1; }
  [ -n "$failed" ] || { fail "no .failed file left for diagnosis"; return 1; }
}

echo "=== jobs.backup spike: scheduled run + restore ==="
echo "  project=$COMPOSE_PROJECT_NAME job=$JOB cron='$CRON' volume=$VOL"
echo "## jobs.backup spike" >> "$SUMMARY"

run_test test_versions_and_schedule
run_test test_job_fires_by_itself
run_test test_restore_brings_the_data_back
run_test test_failed_run_is_visible

echo; echo "==============================="
echo "Passed: $PASSED  Failed: $FAILED"
if [ "${#FAILURES[@]}" -gt 0 ]; then echo "Failures:"; for f in "${FAILURES[@]}"; do echo "  - $f"; done; fi
[ "$FAILED" -eq 0 ]
