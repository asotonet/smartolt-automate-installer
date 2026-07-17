# Changelog

All notable changes to the **installer** repository are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.3.5] — 2026-07-17

### Changed
- Default image tag is now `v0.3.0` (was `v0.2.7`). v0.3.0 of the upstream
  app adds automatic Let's Encrypt renewal: the core scheduler runs
  `certbot renew` twice a day (configurable via `SSL_RENEW_HOUR`) by
  calling the web tier's `/api/internal/public-access/renew-now`
  endpoint. The web container auto-generates `INTERNAL_API_TOKEN` on
  first boot and persists it under `data/internal_token`; the core
  reads the same file via the shared `./data` volume.
- `docker-compose.yml` updated to match upstream: dropped
  `PROXY_HTTP_PORT` (proxy is HTTPS-only), added new env vars
  (`INTERNAL_API_TOKEN`, `INTERNAL_API_TOKEN_FILE`, `WEB_SERVICE_NAME`,
  `WEB_INTERNAL_PORT`, `SSL_RENEW_HOUR`) on both `smartolt-automate`
  and `web`, and mounts `./scripts/ssl` into the certbot container so
  the DNS-01 hooks are available.

### Added
- `scripts/ssl/dns-auth-hook.sh` and `scripts/ssl/dns-cleanup-hook.sh`
  shipped with the installer (copied into the user's cwd by the wizard)
  so manual DNS-01 provider works out of the box. `install.sh` now
  glob-copies them via `REQUIRED_GLOBS`.
- `.env.example` documents the new SSL renewal variables.

### Notes
- Operators already on a previous version don't need to re-run the wizard:
  `./scripts/upgrade.sh --apply` will pull the new `v0.3.0` images and
  start the SSL renewal cron automatically on the next schedule.
- First boot after upgrade may take a few seconds longer than usual
  while the web tier auto-generates the `INTERNAL_API_TOKEN` and writes
  it to `data/internal_token` with mode `0600`.

## [0.3.4] — 2026-07-06

### Changed
- Default image tag is now `v0.2.7` (was `v0.2.6`). v0.2.7 fixes a
  bug where the panel reported "Certificate issued" after
  `POST /api/admin/public-access/issue`, but the proxy kept serving
  the HTTP-only Caddyfile from the original `PUT`. The HTTPS-enabled
  Caddyfile was only being written to the web container's local
  filesystem. Now it's pushed to the proxy container via
  `docker compose exec` so HTTPS comes up immediately.

## [0.3.4] — 2026-07-06

### Changed
- Default image tag is now `v0.2.7` (was `v0.2.6`). v0.2.7 fixes a
  bug where the panel reported "Certificate issued" after
  `POST /api/admin/public-access/issue`, but the proxy kept serving
  the HTTP-only Caddyfile from the original `PUT`. The HTTPS-enabled
  Caddyfile was only being written to the web container's local
  filesystem. Now it's pushed to the proxy container via
  `docker compose exec` so HTTPS comes up immediately.

## [0.3.2] — 2026-07-06

### Changed
- Default image tag is now `v0.2.6` (was `v0.2.5`). v0.2.6 fixes a bug
  where the web tier was reading SmartOLT URL/key from env vars
  (loaded once at startup) instead of from the runtime registry.
  After configuring SmartOLT from the panel, the next
  `GET /api/olts` call was hitting `''` as base URL and httpx was
  raising 'Request URL is missing http:// protocol'.

## [0.3.0] — 2026-07-06

### Changed
- Default image tag is now `v0.2.5` (was `v0.2.3`). v0.2.5 makes the
  SmartOLT connection optional at boot: the service starts in
  'unconfigured' mode and the admin sets the tenant URL + API token
  from the panel. The backend picks up the change via a 2-second
  mtime poll on `configs/global.yaml`. No need to set
  `SMARTOLT_BASE_URL` / `SMARTOLT_API_KEY` in `.env` before deploying.

## [0.2.9] — 2026-07-06

### Changed
- Default image tag is now `v0.2.3` (was `v0.2.2`). v0.2.3 fixes a
  silent failure where the entrypoint was running as the `app` user
  instead of `root`, so the `chown -R app:app /app/configs` never
  took effect. Bind-mounted `./configs` owned by `root` on the host
  stayed unwritable for the `app` user inside the container, so
  `PUT /api/config/olts` still failed with `Permission denied` even
  on `v0.2.2`.

## [0.2.8] — 2026-07-05

### Changed
- Default image tag is now `v0.2.2` (was `v0.2.1`). v0.2.2 includes the
  container entrypoint that fixes `Permission denied` when the
  bind-mounted `./configs` directory is owned by `root` on the host.

## [0.2.7] — 2026-07-05

### Fixed
- `install.sh` default image tag and `.env.example` were still pointing
  to `v0.2.0`, so a fresh install would pull the old images and miss
  the bug fix (config_written_locally) and i18n work that shipped in
  v0.2.1.

## [0.2.6] — 2026-07-04

### Added
- `curl ... | bash` invocation now `git clone`s the installer into
  `$HOME/.smartolt-automate-installer` and copies the wizard's
  working files (compose template, .env.example, etc.) to the user's
  cwd. The stack lives in the cwd; the installer stays in `$HOME` for
  future `git pull` updates.

## [0.2.5] — 2026-07-04

### Fixed
- `upgrade.sh`: bring up the full stack (not just `smartolt-automate
  + web`) so the proxy, frontend, and certbot come back after the
  mandatory `docker compose down`. Also bootstrap `configs/olts.yaml`
  from the template if missing, and `docker compose down
  --remove-orphans` before up to clear stale containers from a
  different `COMPOSE_PROJECT_NAME`.

## [0.2.4] — 2026-07-04

### Fixed
- `upgrade.sh` rewrite for robustness: atomic `.env` snapshot/rollback,
  proper semver parse for prerelease filter, `--check` wins over
  implicit 'tag implies apply', `--yes` for non-interactive apply, single
  Python call for Docker Hub query.

## [0.2.3] — 2026-07-04

### Fixed
- `install.sh` rewrite: env_set uses python-dotenv-compatible quoting
  (handles single quotes, equals, dollar, etc.); bootstrap trap cleans
  up on Ctrl+C; single TTY-probe path; integer / URL / non-empty
  validation; healthcheck returns non-zero on failure.

## [0.2.2] — 2026-07-04

### Added
- `scripts/upgrade.sh` — detect new versions on Docker Hub and offer to upgrade.
  - `scripts/upgrade.sh --check` — non-destructive check.
  - `scripts/upgrade.sh --apply` — update `.env`, pull, recreate containers.
  - `scripts/upgrade.sh <tag>` — upgrade to a specific version.
  - `scripts/upgrade.sh --pre` — include prereleases.
- `scripts/stack.sh upgrade` now delegates to `upgrade.sh --apply` when no
  extra args are passed, so `stack.sh upgrade` and `upgrade.sh` do the
  same thing.

## [0.2.1] — 2026-07-04

### Fixed
- `install.sh` could not run from `curl ... | bash`:
  - `BASH_SOURCE[0]` is unset when the script is piped from stdin
    (Bash treats stdin as the script body). Detect piped invocation
    and skip the file-based path resolution.
  - `ADMIN_PASSWORD` validation while-loop tripped `set -u` on the
    first iteration; pre-initialise it to an empty string.
  - `read` from stdin consumed the rest of the script body. When
    stdin is not a TTY, switch to reading from `/dev/tty`. The
    probe uses an actual `open()` because `[ -r /dev/tty ]` returns
    true in headless subshells where the open still fails.
  - The wizard depended on the repo being cloned first; it now
    fetches `.env.example`, `docker-compose.yml`,
    `configs/olts.example.yaml`, and `scripts/stack.sh` from
    `raw.githubusercontent.com` into a `mktemp` dir when invoked
    via `curl | bash`.

## [0.2.0] — 2026-07-04

### Added
- Initial public release.
- `scripts/install.sh` — interactive wizard (7 steps) with prerequisites, admin credentials, SmartOLT connection, scheduler window, optional HTTPS, and one-shot deploy + healthcheck.
- `scripts/stack.sh` — `pull`, `up`, `down`, `restart`, `status`, `logs`, `ps`, `upgrade`, `config` subcommands.
- `docker-compose.yml` — 5-service template pulling prebuilt images from `asoton/smartolt-automate{-frontend,-proxy,-certbot}` on Docker Hub.
- `.env.example` — full environment variable reference.
- `configs/olts.example.yaml` — sample OLT list for first-time setup.
- MIT license.
- README with quick start, configuration, architecture, and troubleshooting.