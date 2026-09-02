# Wiki.js + Traefik + Let's Encrypt — Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/wikijs-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/wikijs-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)

This repository deploys **Wiki.js** — a modern, self-hosted wiki — behind **Traefik** with automatic **Let's Encrypt TLS**, backed by **PostgreSQL**, with a scheduled **backup container** and a companion **restore script**.

📙 Full narrative installation guide on the blog: [heyvaldemar.com/install-wikijs-using-docker-compose/](https://www.heyvaldemar.com/install-wikijs-using-docker-compose/).

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/wikijs-traefik-letsencrypt-docker-compose
cd wikijs-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create wikijs-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: WIKIJS_DB_PASSWORD, WIKIJS_HOSTNAME, TRAEFIK_ACME_EMAIL,
#   TRAEFIK_HOSTNAME, TRAEFIK_BASIC_AUTH. See .env.example for
#   generation commands.

# 4. Deploy
docker compose -f wikijs-traefik-letsencrypt-docker-compose.yml -p wikijs up -d
```

Within a minute or two, `https://${WIKIJS_HOSTNAME}` serves the Wiki.js first-run setup wizard (create your admin account there) and `https://${TRAEFIK_HOSTNAME}` serves the basic-auth protected Traefik dashboard, both with fresh Let's Encrypt certificates.

### What success looks like

```bash
docker compose -f wikijs-traefik-letsencrypt-docker-compose.yml -p wikijs ps
# Expected: postgres, wikijs, traefik show "(healthy)"; backups shows "Up"

curl -fsS -o /dev/null -w "%{http_code}\n" "https://${WIKIJS_HOSTNAME}/"
# Expected: 200 (the setup wizard, or your wiki once configured)

# First backup lands after BACKUP_INIT_SLEEP (default 30m):
docker compose -f wikijs-traefik-letsencrypt-docker-compose.yml -p wikijs exec backups \
  sh -c 'ls -la "$POSTGRES_BACKUPS_PATH"'
```

### Common first-deploy issues

- **Cert issuance fails.** DNS hasn't propagated to your server's IP yet, or port 80/443 isn't reachable from the internet. Confirm with `dig +short ${WIKIJS_HOSTNAME}`.
- **`docker compose up` fails with `set in .env`.** A required variable is empty in `.env`; the error names it. Most likely: `WIKIJS_DB_PASSWORD`.
- **Network not found.** Step 2 (the `docker network create` commands) was skipped.
- **Wiki.js restarts while postgres is still initializing.** Normal on slow disks: the healthcheck-gated `depends_on` holds Wiki.js until PostgreSQL reports ready.

### Apply `.env` or compose-file changes

```bash
docker compose -f wikijs-traefik-letsencrypt-docker-compose.yml -p wikijs up -d --force-recreate
```

## Supply chain trust

This repository is a deployment template, not a custom image. It orchestrates three upstream images:

- [`requarks/wiki`](https://hub.docker.com/r/requarks/wiki) — Wiki.js upstream
- [`postgres`](https://hub.docker.com/_/postgres) — PostgreSQL, Docker Hub official image
- [`traefik`](https://hub.docker.com/_/traefik) — reverse proxy, Docker Hub official image

All three are pinned to `tag@sha256:<digest>` as interpolation defaults in the compose file's `x-images` block. Compose pulls by digest, not by tag, so two users deploying on different days get byte-identical image manifests — and `git pull` alone delivers the version combination this repository has tested. Setting `WIKIJS_IMAGE_TAG`, `WIKIJS_POSTGRES_IMAGE_TAG`, or `TRAEFIK_IMAGE_TAG` in `.env` overrides the default when you deliberately want a different version.

The daily `check-pin-freshness` CI job re-resolves each pinned tag against its registry and compares the pinned Wiki.js and Traefik versions against the latest upstream releases. PostgreSQL is tracked within its major line only: a major bump requires a dump/restore migration of your data, so it only ever happens in a major release of this template with explicit upgrade notes. GitHub Actions are pinned by commit SHA with version comments; Dependabot keeps those fresh.

## Production checklist

- [ ] **Strong `WIKIJS_DB_PASSWORD`** — generate per `.env.example`, at least 24 random characters.
- [ ] **Host-mount the backups volume.** By default dumps land in the `wikijs-database-backups` named volume — if the host dies, backups die with it. Bind-mount the path to a host directory covered by your off-host backup solution (restic, rclone, Borg, S3 sync).
- [ ] **Know the restore procedure.** Run `./wikijs-restore-database.sh` against a test environment before you need it in production.
- [ ] **Verify Let's Encrypt cert issuance.** Watch `docker compose -p wikijs logs traefik -f` on first start for `Adding certificate for domain(s)`.
- [ ] **Lock down the Traefik dashboard.** Basic auth is basic. Consider Traefik's `IPAllowList` middleware or not exposing the dashboard publicly at all.
- [ ] **Plan the PostgreSQL 14 exit.** PostgreSQL 14 reaches end of life in November 2026. A future major release of this template will move to a newer major with dump/restore instructions; watch the releases.

## Backups

The `backups` container runs `pg_dump | gzip` on a loop: an initial delay (`BACKUP_INIT_SLEEP`, default 30m), then one timestamped dump every `BACKUP_INTERVAL` (default 24h), pruning files older than `POSTGRES_BACKUP_PRUNE_DAYS` (default 7). All knobs are `.env`-overridable — see `.env.example`.

Each cycle logs `Database backup OK: <file> (<bytes> bytes)` or `Database backup FAILED` (the same for the data archive where there is one). A failed dump is kept as `<file>.failed` for diagnosis and never overwrites a good backup — grep the log for `FAILED` from your monitoring.

**Verify backups are running:**

```bash
docker compose -f wikijs-traefik-letsencrypt-docker-compose.yml -p wikijs exec backups \
  sh -c 'ls -la "$POSTGRES_BACKUPS_PATH"'
```

**Restore:**

```bash
chmod +x wikijs-restore-database.sh
./wikijs-restore-database.sh
```

The script lists available dumps, prompts for a selection, stops Wiki.js, recreates the database from the chosen dump, and starts Wiki.js again. It assumes the default database name and user; adjust the variables at the top if you changed them in `.env`.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/wikijs-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC: shellcheck + actionlint, a Trivy scan of each pinned image, the daily `check-pin-freshness` job, and a deploy-and-test job that boots the full stack with an ephemeral `.env` and short backup intervals, requires the Wiki.js UI to answer 200 over HTTPS through Traefik, and verifies that a backup file appears and contains a valid PostgreSQL dump.

### Backup and restore, proven

`tests/e2e-backup-restore.sh` runs against the live stack and is what CI executes after the HTTPS smoke. The scenario that matters most is the restore roundtrip: insert a marker row, restore the earliest backup, assert the marker is gone — a backup that cannot be restored fails the build. Run it yourself against a running deployment with short intervals in `.env` (`BACKUP_INIT_SLEEP=15s`, `BACKUP_INTERVAL=60s`):

```bash
chmod +x tests/e2e-backup-restore.sh
./tests/e2e-backup-restore.sh
```

It stops the database container briefly to prove failure detection — run it on a staging copy, not on production.

## Security Notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and required variables fail fast with `${VAR:?…}` guards.
- **Pre-rotation advisory.** Before v1.0.0 this repository tracked a `.env` containing a literal `WIKIJS_DB_PASSWORD` value. That value remains in git history. Anyone who deployed with it should rotate: `ALTER USER wikijsdbuser WITH PASSWORD '<new strong password>';` in PostgreSQL, then update `.env` and `docker compose up -d --force-recreate`.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** — Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
