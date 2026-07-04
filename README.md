# SmartOLT Automate Installer

One-command installer for [SmartOLT Automate](https://github.com/<owner>/smartolt-automate): a guided wizard that pulls prebuilt Docker images from Docker Hub, generates `.env`, and brings the full 5-service stack online — including the optional reverse proxy and HTTPS (Caddy + certbot with DNS-01).

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
curl -fsSL https://raw.githubusercontent.com/<owner>/smartolt-automate-installer/main/scripts/install.sh | bash
```

Or, if you prefer to clone first:

```bash
git clone https://github.com/<owner>/smartolt-automate-installer
cd smartolt-automate-installer
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
| `SMARTOLT_IMAGE` | `asoton/smartolt-automate:v0.2.0` | Backend + web tier image |
| `SMARTOLT_FRONTEND_IMAGE` | `asoton/smartolt-automate-frontend:v0.2.0` | Frontend image |
| `PROXY_IMAGE` | `asoton/smartolt-automate-proxy:v0.2.0` | Caddy image |
| `CERTBOT_IMAGE` | `asoton/smartolt-automate-certbot:v0.2.0` | Certbot image (46 DNS plugins) |
| `PULL_POLICY` | `always` | `always` pulls on every `up`; `missing`/`if_not_present` honours local cache |

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

- **Upstream project**: <https://github.com/<owner>/smartolt-automate> — full source, CI, release pipeline.
- **SmartOLT API docs**: <https://smartolt.com/api-docs> (login required).

## License

MIT — see [LICENSE](./LICENSE).