# SmartOLT Automate Installer

One-command installer for [SmartOLT Automate](https://github.com/asotonet/smartolt-automate). A single `./smartolt.sh` script pulls prebuilt Docker images from Docker Hub, generates `.env`, and brings the full 4-service stack online — including the reverse proxy and auto-HTTPS (Traefik with ACME HTTP-01 Let's Encrypt).

This repository is **public** and contains no application source code. The full source lives in the upstream project; the images you pull are pinned to specific versions.

## Features

- **Single entry point** — `./smartolt.sh` with subcommands: `install`, `deploy`, `status`, `logs`, `renew`, `upgrade`, `destroy`. No more juggling 4 separate scripts.
- **Non-interactive by default** — `./smartolt.sh install --yes` runs end-to-end with zero env vars (deployable defaults are committed in `.env.example`). Set env vars to override.
- **Interactive wizard** — `install` without `--yes` walks you through every prompt.
- **Prebuilt images** — pulls `asoton/smartolt-automate`, `asoton/smartolt-automate-frontend`, and `asoton/smartolt-automate-traefik` from Docker Hub. No `git clone`, no build step.
- **Traefik reverse proxy** — single image replaces both Caddy + certbot. Discovers services via Docker labels. Self-signed cert at boot, auto-issues Let's Encrypt when `SMARTOLT_PUBLIC_DOMAIN` is set.
- **HTTPS included** — 47 DNS providers supported out of the box (Cloudflare, Route53, DigitalOcean, Gandi, Hetzner, Google Cloud DNS, plus manual mode). Cert issuance and renewal are managed from the panel, no shell access needed. The core scheduler triggers a renewal check twice a day (belt-and-suspenders fallback for ACME HTTP-01).
- **Hot reload** — change the SmartOLT tenant URL, API token, scheduler window, or SSL settings from the panel; no `docker compose restart` required.
- **Two deployment modes** — `EXPOSE_FRONTEND_DIRECTLY` toggles between LAN mode (frontend on `:8080` for everyone) and production mode (frontend only reachable via Traefik on `:443`).
- **Token safety** — the SmartOLT API token is never echoed in full. The panel shows a `abc…2345`-style preview.
- **Precise teardown** — `./smartolt.sh destroy` removes only artifacts the installer created. Templates (`*.example.*`) and other Docker projects are untouched.
- **Re-runnable** — re-running install preserves your database, logs, and existing `.env` unless you opt in to overwriting.

## Quick start

The minimal install path — zero env vars required:

```bash
git clone https://github.com/asotonet/smartolt-automate-installer
cd smartolt-automate-installer
git checkout v0.4.7  # pin to a known-good installer version
./smartolt.sh install --yes
```

The first run prints an auto-generated admin password at the end — copy it before closing the shell. The stack is now running on:

- `http://localhost:8080/` — the frontend UI (login with the admin user you chose).
- `https://localhost/` — Traefik HTTPS proxy (self-signed cert until `SMARTOLT_PUBLIC_DOMAIN` is set and DNS points at the host).

If you want to pre-configure the SmartOLT tenant URL/API key and a known admin password before installing, edit `.env` and re-run:

```bash
sed -i 's|^INITIAL_ADMIN_PASSWORD=.*|INITIAL_ADMIN_PASSWORD=MyStrongPass!|' .env
# Optionally set SMARTOLT_BASE_URL and SMARTOLT_API_KEY in .env too.
./smartolt.sh install --yes
```

`.env.example` ships with deployable defaults (Bogota TZ, image tag `v0.4.9`, scheduler window 02:00–03:00, etc.) — see that file for the full list of tunable parameters and their meanings.

### Production deployment (with public domain)

```bash
SMARTOLT_PUBLIC_DOMAIN=panel.example.com \
SMARTOLT_LETSENCRYPT_EMAIL=ops@example.com \
SMARTOLT_ADMIN_USERNAME=ops \
SMARTOLT_ADMIN_PASSWORD='MyStrongPass!' \
  ./smartolt.sh install --yes
```

This:

1. Sets `EXPOSE_FRONTEND_DIRECTLY=false` (auto-detected from `SMARTOLT_PUBLIC_DOMAIN`) so the frontend is only reachable via Traefik on `:443` (loopback bind, no direct host port).
2. Sets `TRAEFIK_ENABLE=true` so Traefik routes via Docker labels.
3. Traefik auto-issues a Let's Encrypt cert via ACME HTTP-01 once DNS resolves to the host (you'll see a self-signed cert warning during the first ~30s, then it switches automatically).

The wizard will ask you for:

1. **Prerequisites** — confirms `docker`, `docker compose`, Docker Hub connectivity.
2. **Existing state** — asks whether to overwrite `.env` / keep the database.
3. **Admin credentials** — username and password (min 8 chars).
4. **SmartOLT connection** — tenant URL (`https://<you>.smartolt.com`) and API key (input is hidden).
5. **Scheduler window** — timezone and integer hour range (default: `America/Bogota`, 02:00–03:00).
6. **Public access** — optional. If you enable it, you'll need a domain pointing at this server and a DNS provider.
7. **Deploy** — `docker compose pull`, `docker compose up -d`, and a healthcheck probe.

When the wizard finishes you'll have:

- `http://localhost:8080/` — the frontend UI (login with the admin user you chose).
- 4 healthy containers: `smartolt-automate`, `web`, `frontend`, `traefik`.
- An `.env` you can edit at any time. Changes to image tags require `./smartolt.sh upgrade`.

## Day-to-day operations

```bash
./smartolt.sh status   # show container status + healthcheck URLs
./smartolt.sh logs     # tail logs of all services (-f follow)
./smartolt.sh logs smartolt-automate-web --no-follow   # tail once and exit
./smartolt.sh deploy    # re-apply docker compose up -d
./smartolt.sh renew     # force a renew-now check (debug)
./smartolt.sh upgrade   # pull + restart at the version in .env
./smartolt.sh upgrade v0.4.10  # upgrade to a specific tag
./smartolt.sh destroy   # nuke everything the installer created
```

Common flags (work on `install`, `destroy`, `upgrade`):

- `-y, --yes` — skip confirmation prompts
- `--dry-run` — print the plan, change nothing
- `--non-interactive` — `install` without prompts (uses env vars + defaults)
- `--keep-images` / `--keep-certs` / `--keep-data` (`destroy` only)

The legacy `scripts/install.sh`, `scripts/upgrade.sh`, `scripts/stack.sh`, and `scripts/destroy.sh` are kept as thin wrappers that delegate to `./smartolt.sh` for backward compatibility.

## Non-interactive / CI mode

Set env vars to pre-answer every install question. With `--yes`, the wizard runs to completion without any prompt:

```bash
SMARTOLT_INSTALL_NONINTERACTIVE=1 \
SMARTOLT_ADMIN_USERNAME=ops \
SMARTOLT_ADMIN_PASSWORD='MyStrongPass!' \
SMARTOLT_BASE_URL=https://my-tenant.smartolt.com \
SMARTOLT_API_KEY=your-api-key \
SMARTOLT_TIMEZONE=America/Bogota \
SMARTOLT_HOUR_START=2 \
SMARTOLT_HOUR_END=3 \
  ./smartolt.sh install --yes
```

Or render-only (write files, don't deploy):

```bash
SMARTOLT_INSTALL_SKIP_DEPLOY=1 \
  ./smartolt.sh install --yes
```

Or just see the plan:

```bash
./smartolt.sh install --dry-run
```

The full list of env vars is documented in `.env.example`.

## Configuration

All configuration lives in `.env` (created by the wizard from `.env.example`). Edit and re-run `./smartolt.sh deploy` to apply image changes, or update values from the panel for runtime settings.

### Key variables

| Variable | Default | Description |
|---|---|---|
| `SMARTOLT_BASE_URL` | — | Tenant URL, e.g. `https://my-tenant.smartolt.com` |
| `SMARTOLT_API_KEY` | — | API key with read on `/get_olts`, `/get_onus_statuses`, write on `/onu/reboot` |
| `INITIAL_ADMIN_USERNAME` / `_PASSWORD` | — | Created on first boot. After that, manage users from the panel. `change-me-now` is a sentinel that triggers random generation in non-interactive mode. |
| `SCHEDULER_TIMEZONE` | `America/Bogota` | IANA timezone |
| `SCHEDULER_HOUR_START` / `_END` | `2` / `3` | Window as integer hours; END must be > START |
| `PROXY_HTTPS_PORT` | `443` | Host port for the Traefik HTTPS entrypoint |
| `SMARTOLT_IMAGE` | `asoton/smartolt-automate:v0.4.9` | Backend + web tier image |
| `SMARTOLT_FRONTEND_IMAGE` | `asoton/smartolt-automate-frontend:v0.4.9` | Frontend image |
| `PROXY_IMAGE` | `asoton/smartolt-automate-traefik:v0.4.9` | Traefik reverse proxy + ACME |
| `PULL_POLICY` | `always` | `always` pulls on every `up`; `missing`/`if_not_present` honours local cache |
| `SMARTOLT_PUBLIC_DOMAIN` | _(empty)_ | When set, Traefik issues a real Let's Encrypt cert via HTTP-01. The hostname's DNS A record MUST point at this host. When empty, Traefik serves a self-signed cert (instant HTTPS, browser warning). |
| `SMARTOLT_LETSENCRYPT_EMAIL` | `admin@example.com` | Email for ACME registration |
| `TRAEFIK_DASHBOARD` | `false` | Set to `true` to enable Traefik's web dashboard on `:8081` |
| `SSL_RENEW_HOUR` | `3,15` | Cron hours for the core's certbot-renew fallback. With Traefik, ACME HTTP-01 certs renew automatically; this is belt-and-suspenders. |
| `EXPOSE_FRONTEND_DIRECTLY` | `true` | When `true`, the frontend publishes on `0.0.0.0:8080` (LAN/test mode). When `false`, only reachable via Traefik on `:443` (production with a public domain). Auto-detected from `SMARTOLT_PUBLIC_DOMAIN` by `install`. |
| `FRONTEND_BIND_IP` | `0.0.0.0` | Internal — host IP the frontend binds to. Set to `127.0.0.1` for loopback-only. |
| `INTERNAL_API_TOKEN` | _(empty)_ | Shared secret between core scheduler and web tier for SSL renewal. Auto-generated by web on first boot and persisted to `data/internal_token`. |

## Architecture

```
                          ┌────────────────────────┐
                          │     Your server        │
                          │                        │
   Internet ── :80 ───► Traefik (proxy) :443 ──► :80 frontend (nginx)
                          │                        │
                          │  :80  ── /api/* ─────► web:8000 (FastAPI)
                          │                        │     │
                          │                        │     ▼
                          │                        │  smartolt-automate:8080
                          │                        │
                          │  cert renewal (auto    │
                          │  via ACME HTTP-01)     │
                          └────────────────────────┘
```

When `EXPOSE_FRONTEND_DIRECTLY=true`, the frontend container also publishes on the host (`0.0.0.0:8080`) for direct access without going through Traefik. When `false`, only Traefik can reach it (loopback bind, `127.0.0.1:8080`).

The web tier mounts `/var/run/docker.sock` so the core scheduler can `docker compose exec` into the certbot/proxy containers for renewal flows. This is documented as the only practical way to drive cert operations without exposing a custom control port.

## Requirements

- Docker Engine 24+ with Compose v2
- 1 vCPU + 512 MB RAM available
- Outbound HTTPS (port 443) to `registry-1.docker.io`
- For HTTPS: ports 80 and 443 free on the host, a domain with an `A`/`AAAA` record pointing at the server

## Updating

```bash
./smartolt.sh upgrade          # check Docker Hub for a newer version (default: tag in .env)
./smartolt.sh upgrade v0.4.10  # upgrade to a specific tag
```

The upgrade script:

- Reads the current version from `.env`.
- Updates `.env`, pulls the new images, and recreates only the affected containers.
- Leaves `data/`, `logs/`, `configs/`, and the database untouched.

If you prefer manual control:

```bash
# Edit .env to set a new image tag, e.g.:
#   SMARTOLT_IMAGE=asoton/smartolt-automate:v0.5.0
./smartolt.sh deploy
```

The wizard can also be re-run; it preserves your database and will only overwrite `.env` if you confirm.

## Uninstalling

```bash
./smartolt.sh destroy -y        # removes containers, volumes, network, .env
```

Options:

- `--keep-images` — preserve the 4 asoton/smartolt-automate* images
- `--keep-certs` — preserve the certbot volume (so the LE cert isn't lost)
- `--keep-data` — preserve `data/`, `logs/`, `state/` on the host

To keep all persistent data and only stop the stack (without removing it):

```bash
docker compose down   # stops containers but keeps volumes
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `connection closed` / `TLS handshake failed` on `https://localhost/` | Traefik needs the host port 443 free; or no router matches the hostname | Make sure ports 80 and 443 are free on the host. With `SMARTOLT_PUBLIC_DOMAIN` empty, only the catch-all router (`localhost`, `127.0.0.1`) is registered. |
| Browser warns about untrusted cert | Traefik is serving the auto-generated self-signed cert | Expected during the first ~30s after install. Once `SMARTOLT_PUBLIC_DOMAIN` is set and DNS points at the host, Traefik auto-issues the real cert and switches over transparently. |
| `http://localhost:8080/` doesn't respond (Windows + Docker Desktop) | `EXPOSE_FRONTEND_DIRECTLY` defaulted to `false` because a stale `.env` had it that way | `rm .env && ./smartolt.sh install --yes` (regenerates the file with deployable defaults) |
| Traefik container shows `unhealthy` | The Traefik `docker` provider can't read the Windows named pipe (`/var/run/docker.sock` is a `\\.\pipe\docker_engine` on Windows hosts) | Expected on Windows + Docker Desktop. Use `http://localhost:8080/` (with `EXPOSE_FRONTEND_DIRECTLY=true`) to access the UI directly. On Linux the provider works normally. |
| Cert renewal fails with `connection refused` | The web tier isn't running, so the internal `_internal/renew-now` endpoint isn't reachable | `./smartolt.sh logs smartolt-automate-web` to diagnose; `./smartolt.sh status` to confirm the web tier is healthy |

## Publishing a new release

`scripts/release.sh` is self-contained: by default it `docker pull`s the 4 images from Docker Hub at the requested version, retags as `:latest`, and pushes both. No local build required.

```bash
# Tag + push with the version in .env
./scripts/release.sh

# Tag + push a specific version (e.g. for a release candidate)
./scripts/release.sh v0.4.10

# Skip the docker pull and use whatever is already in the local cache
# (use this if you've built the images locally from source)
./scripts/release.sh v0.4.10 --skip-pull

# Verify a tag is live on Docker Hub (no push)
./scripts/release.sh --check
./scripts/release.sh --check v0.4.10
```

The script logs in via `~/.docker/config.json` (run `docker login -u asoton` first). Override with `DOCKERHUB_NAMESPACE=...` to push to a personal repo.

It always updates `:latest` alongside the explicit version, so fresh installs that don't pin a tag still pull the latest stable.

## Related

- **Upstream project**: <https://github.com/asotonet/smartolt-automate> — full source, CI, release pipeline.
- **SmartOLT API docs**: <https://smartolt.com/api-docs> (login required).

## License

MIT — see [LICENSE](./LICENSE).
