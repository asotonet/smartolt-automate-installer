# SmartOLT Automate Installer

One-command installer for [SmartOLT Automate](https://github.com/asotonet/smartolt-automate): a guided wizard that pulls prebuilt Docker images from Docker Hub, generates `.env`, and brings the full 5-service stack online — including the optional reverse proxy and HTTPS (Caddy + certbot with DNS-01).

This repository is **public** and contains no application source code. The full source lives in the upstream project; the images you pull are signed and pinned to specific versions.

## Features

- **Interactive wizard** — 7 steps: prerequisites, admin credentials, SmartOLT connection, scheduler window, public access, deploy, healthcheck.
- **Prebuilt images** — pulls `asoton/smartolt-automate`, `asoton/smartolt-automate-frontend`, `asoton/smartolt-automate-proxy`, and `asoton/smartolt-automate-certbot` from Docker Hub. No `git clone`, no build step.
- **HTTPS included** — 47 DNS providers supported out of the box (Cloudflare, Route53, DigitalOcean, Gandi, Hetzner, Google Cloud DNS, plus manual mode). Cert issuance and renewal are managed from the panel, no shell access needed.
- **Hot reload** — change the SmartOLT tenant URL, API token, scheduler window, or SSL settings from the panel; no `docker compose restart` required.
- **Token safety** — the SmartOLT API token is never echoed in full. The panel shows a `abc…2345`-style preview.
- **Re-runnable** — re-running the wizard preserves your database, logs, and existing `.env` unless you opt in to overwriting.

## Quick start

```bash
# Run the wizard (no clone required):
curl -fsSL https://raw.githubusercontent.com/asotonet/smartolt-automate-installer/main/scripts/install.sh | bash

# Or, if you prefer to clone first:
git clone https://github.com/asotonet/smartolt-automate-installer
cd smartolt-automate-installer
git checkout v0.3.6  # pin to a known-good installer version
./scripts/install.sh
```

The wizard will ask you for:

1. **Prerequisites** — confirms `docker`, `docker compose`, Docker Hub connectivity.
2. **Existing state** — asks whether to overwrite `.env` / keep the database.
3. **Admin credentials** — username and password (min 8 chars).
4. **SmartOLT connection** — tenant URL (`https://<you>.smartolt.com`) and API key (input is hidden).
5. **Scheduler window** — timezone and integer hour range (default: `America/Bogota`, 02:00–03:00).
6. **Public access** — optional. If you enable it, you'll need a domain pointing at this server and a DNS provider.
7. **Deploy** — `docker compose pull`, `docker compose up -d`, and a healthcheck probe.

### Non-interactive / fully automated

The wizard supports three modes that skip all prompts. Activated by:

| Trigger | Example |
|---|---|
| CLI flag | `./scripts/install.sh --yes` |
| Env var | `SMARTOLT_INSTALL_NONINTERACTIVE=1 ./scripts/install.sh` |
| Heuristic | stdin is not a TTY (e.g. `curl ... \| bash` without `-t`, CI, systemd) |

In non-interactive mode the wizard uses defaults for every question unless an
override is provided via env var. Defaults are documented below.

Common scenarios:

```bash
# 1. Quick install with auto-generated admin password (printed at the end):
SMARTOLT_INSTALL_NONINTERACTIVE=1 \
  ./scripts/install.sh --yes

# 2. Production install with all config pinned via env vars:
SMARTOLT_ADMIN_USERNAME=ops \
SMARTOLT_ADMIN_PASSWORD='super-secret-9u2nF' \
SMARTOLT_BASE_URL=https://my-tenant.smartolt.com \
SMARTOLT_API_KEY=your-api-key-here \
SMARTOLT_TIMEZONE=America/Bogota \
SMARTOLT_HOUR_START=2 \
SMARTOLT_HOUR_END=3 \
SMARTOLT_PUBLIC_DOMAIN=panel.example.com \
SMARTOLT_LETSENCRYPT_EMAIL=ops@example.com \
SMARTOLT_INSTALL_NONINTERACTIVE=1 \
  ./scripts/install.sh --yes

# 3. One-liner for a CI pipeline (curl | bash, no TTY at all):
curl -fsSL https://raw.githubusercontent.com/asotonet/smartolt-automate-installer/main/scripts/install.sh \
  | SMARTOLT_ADMIN_USERNAME=ops \
    SMARTOLT_ADMIN_PASSWORD=$ADMIN_PW \
    SMARTOLT_PUBLIC_DOMAIN=panel.example.com \
    SMARTOLT_INSTALL_NONINTERACTIVE=1 \
    bash

# 4. Render-only mode (write files, don't deploy):
SMARTOLT_INSTALL_SKIP_DEPLOY=1 \
SMARTOLT_INSTALL_NONINTERACTIVE=1 \
  ./scripts/install.sh --yes

# 5. Dry run (print plan, touch nothing):
SMARTOLT_INSTALL_DRY_RUN=1 \
SMARTOLT_INSTALL_NONINTERACTIVE=1 \
  ./scripts/install.sh --yes
```

#### Environment variables (all optional)

| Variable | Default | Description |
|---|---|---|
| `SMARTOLT_INSTALL_NONINTERACTIVE` | _unset_ | Set to `1` to force non-interactive mode |
| `SMARTOLT_INSTALL_SKIP_DEPLOY` | `0` | Set to `1` to write files but skip `docker compose pull/up` and the healthcheck |
| `SMARTOLT_INSTALL_DRY_RUN` | `0` | Set to `1` to print the plan without touching anything |
| `SMARTOLT_ADMIN_USERNAME` | `admin` | Initial admin login |
| `SMARTOLT_ADMIN_PASSWORD` | random 20 chars | Set explicitly to pin the password. Auto-generated in non-interactive mode otherwise (printed at the end) |
| `SMARTOLT_OVERWRITE_ENV` | `N` | `Y` to overwrite existing `.env` |
| `SMARTOLT_KEEP_DB` | `Y` | `N` to wipe the existing database |
| `SMARTOLT_BASE_URL` | _empty_ | SmartOLT tenant URL (deferred to panel if empty) |
| `SMARTOLT_API_KEY` | _empty_ | SmartOLT API key |
| `SMARTOLT_TIMEZONE` | `America/Bogota` | IANA timezone |
| `SMARTOLT_HOUR_START` | `2` | Scheduler window start hour (0–23) |
| `SMARTOLT_HOUR_END` | `3` | Scheduler window end hour (1–23, must be > start) |
| `SMARTOLT_PUBLIC_DOMAIN` | _empty_ | If set, HTTPS is auto-enabled for this domain |
| `SMARTOLT_LETSENCRYPT_EMAIL` | `admin@<public_domain>` | Email for Let's Encrypt expiry notifications |
| `SMARTOLT_IMAGE_TAG` | `v0.3.0` | Image tag to install (overrides the wizard default) |
| `DOCKERHUB_NAMESPACE` | `asoton` | Docker Hub namespace |

If any required value is missing and no default applies, the wizard exits
with a clear error message naming the env var to set.

When the wizard finishes you'll have:

- `http://localhost/` — the dashboard (login with the admin user you chose).
- 5 healthy containers: `smartolt-automate`, `web`, `frontend`, `proxy`, `certbot`.
- An `.env` you can edit at any time. Changes to image tags require `./scripts/stack.sh upgrade`.

## Day-to-day operations

```bash
./scripts/stack.sh status   # show container status + healthcheck URLs
./scripts/stack.sh logs web # tail logs of the web tier
./scripts/stack.sh upgrade  # pull new images + restart
./scripts/stack.sh down     # stop the stack
./scripts/stack.sh restart  # restart a specific service
```

## Publishing a new release

`scripts/release.sh` tags and pushes all four images
(`smartolt-automate`, `...-frontend`, `...-proxy`, `...-certbot`)
to Docker Hub under one version. Idempotent: re-tagging an
identical image deduplicates at the layer level.

```bash
# Tag + push with the version in .env
./scripts/release.sh

# Tag + push a specific version (e.g. for a release candidate)
./scripts/release.sh v0.3.0

# Verify a tag is live on Docker Hub (no push)
./scripts/release.sh --check
./scripts/release.sh --check v0.3.0
```

The script logs in via `~/.docker/config.json` (run `docker login -u asoton`
first). Override with `DOCKERHUB_NAMESPACE=...` to push to a personal repo.

It always updates `:latest` alongside the explicit version, so
fresh installs that don't pin a tag still pull the latest stable.

## Configuration

All configuration lives in `.env` (created by the wizard). Edit and re-run `./scripts/stack.sh upgrade` to apply image changes, or update values from the panel for runtime settings.

Key variables:

| Variable | Default | Description |
|---|---|---|
| `SMARTOLT_BASE_URL` | — | Tenant URL, e.g. `https://my-tenant.smartolt.com` |
| `SMARTOLT_API_KEY` | — | API key with read on `/get_olts`, `/get_onus_statuses`, write on `/onu/reboot` |
| `INITIAL_ADMIN_USERNAME` / `_PASSWORD` | — | Created on first boot. After that, manage users from the panel. |
| `SCHEDULER_TIMEZONE` | `America/Bogota` | IANA timezone |
| `SCHEDULER_HOUR_START` / `_END` | `2` / `3` | Window as integer hours (UTC offset of the timezone) |
| `PROXY_HTTP_PORT` / `PROXY_HTTPS_PORT` | `80` / `443` | Host ports for the reverse proxy |
| `SMARTOLT_IMAGE` | `asoton/smartolt-automate:v0.3.0` | Backend + web tier image |
| `SMARTOLT_FRONTEND_IMAGE` | `asoton/smartolt-automate-frontend:v0.3.0` | Frontend image |
| `PROXY_IMAGE` | `asoton/smartolt-automate-proxy:v0.3.0` | Caddy image |
| `CERTBOT_IMAGE` | `asoton/smartolt-automate-certbot:v0.3.0` | Certbot image (46 DNS plugins) |
| `PULL_POLICY` | `always` | `always` pulls on every `up`; `missing`/`if_not_present` honours local cache |
| `INTERNAL_API_TOKEN` | (auto-generated) | Shared secret between core scheduler and web tier for the SSL renewal cron. Auto-created by web on first boot and persisted to `data/internal_token`. Leave blank unless you want a fixed value. |
| `SSL_RENEW_HOUR` | `3,15` | Hours of day when the core scheduler triggers `certbot renew`. Default: 03:00 and 15:00 in the scheduler timezone. |

## Architecture

```
                                ┌────────────────────┐
                                │  Your server       │
                                │                    │
Internet ──── :80 / :443 ───►  Caddy (proxy)        │
                                │                    │
                                │   /api/* ────────► web:8000 (FastAPI)  ──► smartolt-automate:8080
                                │   /* ──────────► frontend:80 (nginx)
                                │                    │
                                │ certbot (sleeping,  │
                                │ invoked on demand) │
                                └────────────────────┘
```

The web tier mounts `/var/run/docker.sock` so it can `docker compose exec` into the certbot and proxy containers to issue certs and reload Caddy. This is documented as the only practical way to drive certbot without exposing a custom control port.

## Requirements

- Docker Engine 24+ with Compose v2
- 1 vCPU + 512 MB RAM available
- Outbound HTTPS (port 443) to `registry-1.docker.io` and your DNS provider's API
- If using HTTPS: ports 80 and 443 free on the host, a domain with an `A`/`AAAA` record pointing at the server

## Updating

```bash
./scripts/upgrade.sh          # check Docker Hub for a newer version
./scripts/upgrade.sh --apply  # upgrade to the latest stable release
./scripts/upgrade.sh v0.3.0   # upgrade to a specific tag
./scripts/upgrade.sh --pre    # include prereleases (v0.3.0-rc.1, etc.)
```

The upgrade script:
- Reads the current version from `.env`.
- Lists all semver tags on Docker Hub.
- Picks the highest stable release (or the version you specified).
- Updates `.env`, pulls the new images, and recreates only the `smartolt-automate` and `web` containers.
- Leaves `data/`, `logs/`, `configs/`, and the database untouched.

If you prefer manual control:

```bash
# Edit .env to set a new image tag, e.g.:
#   SMARTOLT_IMAGE=asoton/smartolt-automate:v0.3.0
./scripts/stack.sh upgrade
```

The wizard can also be re-run; it preserves your database and will only overwrite `.env` if you confirm.

## Uninstalling

```bash
./scripts/stack.sh down --volumes   # WARNING: this deletes data/, logs/, state/, certificates
```

To keep persistent data, drop the `--volumes` flag.

## Related

- **Upstream project**: <https://github.com/asotonet/smartolt-automate> — full source, CI, release pipeline.
- **SmartOLT API docs**: <https://smartolt.com/api-docs> (login required).

## License

MIT — see [LICENSE](./LICENSE).