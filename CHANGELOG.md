# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.2.1] - 2026-09-02

### Fixed

- `tests/e2e-backup-restore.sh` hardened against what the first CI runs
  across the fleet surfaced: no `grep -q` on a `docker logs` pipe (with
  `pipefail`, grep exiting early failed the whole pipeline on long
  logs); the dump content check scans the whole dump instead of its
  first 80 lines; content and restore are judged on a backup taken
  after the marker exists; containers are resolved through
  `docker compose ps -q` so a `container_name` override cannot break
  the lookup; the fake-old prune file uses `touch -t`, which BusyBox
  accepts.

## [1.2.0] - 2026-09-02

### Added

- **`tests/e2e-backup-restore.sh`** — seven end-to-end scenarios against
  the live stack, run by CI on every push and by you locally: the
  required-variable guard fires, a backup is produced, it is a readable
  archive with real dump content (and a readable data `tar.gz` where the
  stack has one), a database outage is reported as `FAILED`, **restore
  genuinely replaces database state** (a marker row inserted after the
  baseline backup is gone after restoring it), and pruning removes only
  old files.

## [1.1.0] - 2026-09-02

### Fixed

- **A failed database dump no longer produces a silent, corrupt backup.**
  The old loop piped the dump into `gzip` and only checked `gzip`'s exit
  status, so a dump that failed halfway (database down, wrong password,
  disk full) still left a small `.gz` that looked like a backup. The loop
  now runs with `pipefail`, logs `Database backup OK: <file> (<bytes>
  bytes)` or `Database backup FAILED` per cycle, keeps a failed dump as
  `<file>.failed` for diagnosis, and prunes only its own files. Retention
  set to `0` disables pruning instead of deleting everything.

### Added

- CI now waits for the first backup cycle and proves the produced
  archive is readable and contains a real dump header (plus a readable
  `tar.gz` for the data backup where the stack has one).

## [1.0.0] - 2026-09-02

First semver release. Brings this template to the fleet standard established
in [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose).

### Security

- **`.env` is no longer tracked in git.** The previous tracked file
  carried a literal `WIKIJS_DB_PASSWORD` value, which remains in git
  history. If you deployed with it, rotate: `ALTER USER wikijsdbuser
  WITH PASSWORD '<new strong password>';`, update `.env`, recreate.

### Changed

- **Wiki.js pinned to 2.5.314** (was the floating `2.5` tag),
  **PostgreSQL to 14.24** (was the floating `14` tag), and **Traefik to
  v3.7** (was 3.2), all pinned by `tag@sha256:digest` in the compose
  `x-images` block. `git pull` delivers the tested combination; the
  `*_IMAGE_TAG` variables in `.env` override deliberately.
- Required variables (`WIKIJS_DB_PASSWORD`, `WIKIJS_HOSTNAME`, the
  Traefik trio) now fail fast with `${VAR:?…}` guards; database
  name/user, log level, and all backup knobs have defaults, so `.env`
  carries only secrets and deliberate overrides.
- The backup loop reads its settings from the container environment at
  runtime (`$$VAR` escaping) instead of compose-time interpolation, so
  the defaults apply even when the variables are absent from `.env`.
- The restore script no longer captures an unused password variable and
  quotes its container-ID lookups (shellcheck clean).

### Added

- **Deployment Verification workflow**: shellcheck + actionlint; a Trivy
  scan of each pinned image; daily `check-pin-freshness` (digest drift,
  Wiki.js/Traefik release lag, PostgreSQL patch lag within the major
  line); and a deploy-and-test job that boots the full stack with an
  ephemeral `.env`, requires the Wiki.js UI to answer 200 over HTTPS
  through Traefik, and verifies a produced backup is a valid PostgreSQL
  dump.
- `.env.example` with generation commands; `.gitignore` for `.env`.

[Unreleased]: https://github.com/heyvaldemar/wikijs-traefik-letsencrypt-docker-compose/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/heyvaldemar/wikijs-traefik-letsencrypt-docker-compose/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/heyvaldemar/wikijs-traefik-letsencrypt-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/wikijs-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/wikijs-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
