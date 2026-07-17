# Changelog

All notable changes to the **installer** repository are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.4.3] — 2026-07-17

### Changed
- **Traefik 3.1 replaces Caddy + certbot** as the reverse proxy / HTTPS
  terminator. Single image (`asoton/smartolt-automate-traefik`) handles:
  - Reverse proxy `/api/*` → web tier, `/*` → frontend
  - ACME HTTP-01 cert issuance and renewal (auto on first request when
    `SMARTOLT_PUBLIC_DOMAIN` is set)
  - HTTP→HTTPS redirect on port 80

  Previous Caddy + certbot DNS-01 stack was split across two containers
  with shared volumes; Traefik's docker provider removes the need for a
  static config file — routers are declared via container labels.

### Removed
- `CERTBOT_IMAGE` env var and `asoton/smartolt-automate-certbot` image.
- `proxy_caddy`, `certbot_etc`, `certbot_work`, `certbot_logs` volumes.
- `scripts/ssl/dns-auth-hook.sh` and `dns-cleanup-hook.sh` (DNS-01 hooks).

### Notes
- **Windows + Docker Desktop**: Traefik's docker provider can't read
  the Windows named pipe, so Traefik stays `unhealthy` on Windows
  hosts. The frontend remains reachable via `http://localhost:8080/`
  (host port mapping on the frontend container). On Linux this is a
  non-issue.

## [0.4.2] — 2026-07-17

### Fixed
- **Port mapping**: `:8080` was mapped to the backend core's `/healthz`
  endpoint (which gave a 404 for anyone trying to load the UI). Reassigned:
  - `:8080` → frontend (the React UI — open this in your browser)
  - `:8090` → backend core health (was `:8080`)
  - `:8000` → web tier (FastAPI `/api/...`)
  - `:443`  → Caddy HTTPS proxy (unchanged)

All operator-facing output (`install` summary, `status`) now lists the
right URL for each role. `.env.example` documents the new
`FRONTEND_PORT`, `HEALTH_PORT`, `WEB_API_PORT` vars so the host mapping
is operator-tunable without editing `docker-compose.yml`.

## [0.4.1] — 2026-07-17

### Changed
- **`.env.example` ships with safe, deployable defaults** — running
  `./smartolt.sh install --yes` on a fresh clone, with **no env vars
  set externally**, now produces a working 5-service stack. Previously
  `.env.example` contained placeholders like `your-subdomain.smartolt.com`
  and `replace-with-your-api-key` that would fail install validation
  on first use.
- **`smartolt.sh install --yes` implies `--non-interactive`** — `-y` no
  longer just skips confirmation; it also forces the non-interactive path
  so prompts never block in piped/cron invocations.
- **`smartolt.sh install` auto-loads `.env` if present** so values you
  edited in `.env` flow through to the wizard (and to subsequent
  commands like `status` / `upgrade`).
- **Admin password sentinel**: `INITIAL_ADMIN_PASSWORD=change-me-now` is
  treated as a placeholder. If install runs non-interactive and finds
  the sentinel (or empty), it auto-generates a 20-char random password
  and prints it at the end of the run. Edit `.env` to pin a password.

### Operator workflow

The minimal install path is now:

```bash
git clone https://github.com/asotonet/smartolt-automate-installer
cd smartolt-automate-installer
./smartolt.sh install --yes
# (admin password printed at the end — copy it before closing the shell)
```

If the operator wants to pre-configure the SmartOLT tenant and admin
password, they can edit `.env` before install and re-run:

```bash
./smartolt.sh destroy -y
sed -i 's|^INITIAL_ADMIN_PASSWORD=.*|INITIAL_ADMIN_PASSWORD=MyStrongPass!|' .env
./smartolt.sh install --yes
```

## [0.4.0] — 2026-07-17

### Changed
- **Unified operator interface**: `scripts/install.sh`, `scripts/upgrade.sh`,
  `scripts/stack.sh`, and `scripts/destroy.sh` are replaced by a single
  `./smartolt.sh` with subcommands. Old script paths are kept as thin
  wrappers that exec into `smartolt.sh` for backward compatibility (they
  print a deprecation hint but otherwise work as before).

### Subcommands

```
./smartolt.sh install [flags]    first-time deploy (wizard + pull + up)
./smartolt.sh deploy              re-apply docker compose up -d
./smartolt.sh status              container status + healthchecks
./smartolt.sh logs [svc] [--no-follow]
./smartolt.sh renew               force certbot renew (debug only)
./smartolt.sh upgrade [ver]       pull new images, restart containers
./smartolt.sh destroy [flags]     nuke everything the installer created
```

### Flags

- `-y, --yes` — skip confirmation prompts
- `--dry-run` — print the plan, change nothing
- `--non-interactive` — install without prompts (env vars + defaults)
- `--keep-images` / `--keep-certs` / `--keep-data` (destroy)
- `--no-follow` — tail logs once and exit

## [0.3.9] — 2026-07-17

### Changed
- `scripts/release.sh` is now self-contained in publish mode: by default
  it `docker pull`s the 4 images at the requested version from Docker Hub,
  then retags as `:latest` and pushes both tags. Previously the script
  required the images to already be present locally (often meaning you
  had to run the upstream `Smartolt_API_Automate/scripts/release.sh`
  build first on the same machine). The new flag `--skip-pull` opts out
  of the pull step for the case where you've built the images locally
  from source.
- Plan section now prints the chosen strategy explicitly so operators
  can see whether a pull will happen before it does.
- Pull failures abort the script before any push (a partial publish
  was previously possible if one of the 4 pulls failed mid-way).

## [0.3.8] — 2026-07-17

### Fixed
- `scripts/destroy.sh`: avoid spurious `Failed to remove volume` log
  entries for volumes that `docker compose down --remove-orphans` had
  already removed. The script now re-checks existence inside the rm
  loop and skips volumes that are already gone.

## [0.3.7] — 2026-07-17

### Added
- `scripts/destroy.sh` — precise teardown that removes ONLY artifacts the
  installer created. Bounded scope:
  - 5 containers with the canonical `smartolt-automate{-web,-frontend,-proxy,-certbot}`
    names that `docker-compose.yml` pins via `container_name`.
  - 7 named volumes matching `<project>_{logs,state,data,proxy_caddy,certbot_etc,certbot_work,certbot_logs}`.
  - 1 default network per project.
  - 4 images in the `asoton/` namespace only (`smartolt-automate{,,-frontend,-proxy,-certbot}`).
  - Filesystem artifacts: `.env`, `configs/olts.yaml`, and the contents of
    `./configs`, `./data`, `./logs`, `./state` — but **never** templates
    (`*.example.*`, `*.example`) and **never** files outside those four
    subdirectories.
- Project name detection is robust: reads `COMPOSE_PROJECT_NAME` from
  `.env`, falls back to the default, and additionally scans existing
  installer volumes to discover projects whose `.env` is missing or stale.
  Handles the case where a previous install crashed mid-write.
- Flags: `--yes`/`-y` (skip confirmation), `--keep-images`,
  `--keep-certs` (preserve the certbot volume), `--keep-data`
  (preserve `data/`, `logs/`, `state/`).

## [0.3.7] — 2026-07-17

### Added
- `scripts/destroy.sh` — precise teardown that removes ONLY artifacts the
  installer created. Bounded scope:
  - 5 containers with the canonical `smartolt-automate{-web,-frontend,-proxy,-certbot}`
    names that `docker-compose.yml` pins via `container_name`.
  - 7 named volumes matching `<project>_{logs,state,data,proxy_caddy,certbot_etc,certbot_work,certbot_logs}`.
  - 1 default network per project.
  - 4 images in the `asoton/` namespace only (`smartolt-automate{,,-frontend,-proxy,-certbot}`).
  - Filesystem artifacts: `.env`, `configs/olts.yaml`, and the contents of
    `./configs`, `./data`, `./logs`, `./state` — but **never** templates
    (`*.example.*`, `*.example`) and **never** files outside those four
    subdirectories.
- Project name detection is robust: reads `COMPOSE_PROJECT_NAME` from
  `.env`, falls back to the default, and additionally scans existing
  installer volumes to discover projects whose `.env` is missing or stale.
  Handles the case where a previous install crashed mid-write.
- Flags: `--yes`/`-y` (skip confirmation), `--keep-images`,
  `--keep-certs` (preserve the certbot volume), `--keep-data`
  (preserve `data/`, `logs/`, `state/`).

### Fixed
- Healthcheck probe URL changed from `http://localhost/api/service/livez`
  (which only works once Caddy is serving real HTTPS) to a primary +
  fallback strategy: tries `http://localhost/api/service/livez` first,
  then falls back to `http://localhost:8080/healthz` (the backend's
  health endpoint, which is always exposed on the host). The install
  succeeds even on fresh installs where no SSL cert has been issued.
- Default image tag bumped to `v0.3.3`. v0.3.3 fixes:
  - **SSL renewal timing**: `_ssl_renew_job` re-resolves `INTERNAL_API_TOKEN`
    on every invocation (was cached at scheduler startup). The web tier
    generates the token on first boot, which can happen **after** the
    core's scheduler starts. Caching caused the first cron tick after
    a fresh deploy to log `ssl_renew_skipped_no_internal_token`.
  - **Internal API path corrected**: the call site now hits
    `/api/admin/public-access/_internal/renew-now` (the actual route on
    the public-access router, which has prefix `/api/admin/public-access`).
    The previous `/api/internal/public-access/renew-now` returned 404.

## [0.3.6] — 2026-07-17

### Added
- **Fully non-interactive mode** for `scripts/install.sh`. Activated by:
  - CLI flag: `--yes`, `-y`, `--non-interactive`
  - Env var: `SMARTOLT_INSTALL_NONINTERACTIVE=1`
  - Heuristic: stdin is not a TTY and no `/dev/tty` is available (e.g. `curl ... | bash` without `-t`, CI runners, systemd units)
- **Optional dry-run** (`SMARTOLT_INSTALL_DRY_RUN=1`): prints the full plan
  (env-var-derived values, image tags, generated admin password) without
  touching the filesystem or invoking `docker compose`.
- **Optional skip-deploy** (`SMARTOLT_INSTALL_SKIP_DEPLOY=1`): writes `.env`
  and `configs/olts.yaml` but skips `docker compose pull/up` and the
  healthcheck. Useful for CI where another step will deploy later.
- **All wizard questions can be pre-answered via env vars**: documented in
  README under the "Non-interactive / fully automated" section.
  - `SMARTOLT_ADMIN_USERNAME`, `SMARTOLT_ADMIN_PASSWORD`
  - `SMARTOLT_BASE_URL`, `SMARTOLT_API_KEY`
  - `SMARTOLT_TIMEZONE`, `SMARTOLT_HOUR_START`, `SMARTOLT_HOUR_END`
  - `SMARTOLT_PUBLIC_DOMAIN`, `SMARTOLT_LETSENCRYPT_EMAIL`
  - `SMARTOLT_OVERWRITE_ENV`, `SMARTOLT_KEEP_DB`
- Default admin password in non-interactive mode is now an auto-generated
  20-char random string (printed once at the end of the run), instead of
  prompting. Operators who need a fixed password can set
  `SMARTOLT_ADMIN_PASSWORD=<≥8 chars>`.
- When `SMARTOLT_PUBLIC_DOMAIN` is set, HTTPS is auto-enabled with
  `admin@<public_domain>` as the Let's Encrypt email (overridable via
  `SMARTOLT_LETSENCRYPT_EMAIL`).

### Fixed
- `step "8/8"` would print "Healthcheck did not respond" when
  `SKIP_DEPLOY=1` or `DRY_RUN=1`, because `$up` was being reset to `0`
  in the healthcheck loop unconditionally. Now `$up` defaults to `1`
  in skip/dry-run paths and the loop runs only in the real deploy path.
- `cat <<EOF ... EOF` heredoc structure around the summary section was
  malformed (had `Next steps:` floating outside a heredoc, which crashed
  with `Next: command not found` when `NEXT` substitutions fired).
  Rewritten with `printf` so it works under both TTY and non-TTY
  invocations, and doesn't depend on ANSI color environment variables.

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