# SmartOLT Automate Installer

One-command installer for [SmartOLT Automate](https://github.com/asotonet/smartolt-automate): a guided wizard that pulls prebuilt Docker images from Docker Hub, generates `.env`, and brings the full 5-service stack online — including the optional reverse proxy and HTTPS (Caddy + certbot with DNS-01).

This repository is **public** and contains no application source code. The full source lives in the upstream project; the images you pull are signed and pinned to specific versions.

## Features

- **Single entry point** — one `./smartolt.sh` with subcommands: `install`, `deploy`, `status`, `logs`, `renew`, `upgrade`, `destroy`. No more juggling 4 separate scripts.
- **Interactive wizard** — `install` walks you through 7 steps: prerequisites, admin credentials, SmartOLT connection, scheduler window, public access, deploy, healthcheck. Or run with `--non-interactive` and env vars for full automation.
- **Prebuilt images** — pulls `asoton/smartolt-automate`, `asoton/smartolt-automate-frontend`, `asoton/smartolt-automate-proxy`, and `asoton/smartolt-automate-certbot` from Docker Hub. No `git clone`, no build step.
- **HTTPS included** — 47 DNS providers supported out of the box (Cloudflare, Route53, DigitalOcean, Gandi, Hetzner, Google Cloud DNS, plus manual mode). Cert issuance and renewal are managed from the panel, no shell access needed. Auto-renewal runs twice a day via the core scheduler.
- **Hot reload** — change the SmartOLT tenant URL, API token, scheduler window, or SSL settings from the panel; no `docker compose restart` required.
- **Token safety** — the SmartOLT API token is never echoed in full. The panel shows a `abc…2345`-style preview.
- **Precise teardown** — `./smartolt.sh destroy` removes only artifacts the installer created. Templates (`*.example.*`) and other Docker projects are untouched.
- **Re-runnable** — re-running install preserves your database, logs, and existing `.env` unless you opt in to overwriting.

## Quick start

The minimal install path — zero env vars required:

```bash
git clone https://github.com/asotonet/smartolt-automate-installer
cd smartolt-automate-installer
git checkout v0.4.0  # pin to a known-good installer version
./smartolt.sh install --yes
```

The first run prints an auto-generated admin password at the end — copy it
before closing the shell. The stack is now running on `http://localhost/`.

If you want to pre-configure the SmartOLT tenant URL/API key and a known
admin password before installing, edit `.env` and re-run:

```bash
sed -i 's|^INITIAL_ADMIN_PASSWORD=.*|INITIAL_ADMIN_PASSWORD=MyStrongPass!|' .env
# Optionally set SMARTOLT_BASE_URL and SMARTOLT_API_KEY in .env too.
./smartolt.sh install --yes
```

`.env.example` ships with deployable defaults (Bogota TZ, image tag `v0.3.3`,
scheduler window 02:00–03:00, etc.) — see that file for the full list of
tunable parameters and their meanings.

### Interactive wizard

For a guided first-run that prompts for every value:

```bash
./smartolt.sh install    # no --yes: walks through every prompt
```

The wizard will ask you for:

1. **Prerequisites** — confirms `docker`, `docker compose`, Docker Hub connectivity.
2. **Existing state** — asks whether to overwrite `.env` / keep the database.
3. **Admin credentials** — username and password (min 8 chars).
4. **SmartOLT connection** — tenant URL (`https://<you>.smartolt.com`) and API key (input is hidden).
5. **Scheduler window** — timezone and integer hour range (default: `America/Bogota`, 02:00–03:00).
6. **Public access** — optional. If you enable it, you'll need a domain pointing at this server and a DNS provider.
7. **Deploy** — `docker compose pull`, `docker compose up -d`, and a healthcheck probe.

When the wizard finishes you'll have:

- `http://localhost/` — the dashboard (login with the admin user you chose).
- 5 healthy containers: `smartolt-automate`, `web`, `frontend`, `proxy`, `certbot`.
- An `.env` you can edit at any time. Changes to image tags require `./scripts/stack.sh upgrade`.

## Day-to-day operations

```bash
./smartolt.sh status   # show container status + healthcheck URLs
./smartolt.sh logs     # tail logs of all services (-f follow)
./smartolt.sh logs smartolt-automate-web --no-follow   # tail once and exit
./smartolt.sh deploy    # re-apply docker compose up -d
./smartolt.sh renew     # force certbot renew now (debug)
./smartolt.sh upgrade   # pull + restart at the version in .env
./smartolt.sh upgrade v0.3.4   # upgrade to a specific tag
./smartolt.sh destroy   # nuke everything the installer created
```

The legacy `scripts/install.sh`, `scripts/upgrade.sh`, `scripts/stack.sh`, and `scripts/destroy.sh` are kept as thin wrappers that delegate to `./smartolt.sh` for backward compatibility — they print the new canonical command in their deprecation path.

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