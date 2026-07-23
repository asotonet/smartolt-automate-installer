# SmartOLT Automate Installer

One-command installer for [SmartOLT Automate](https://github.com/asotonet/smartolt-automate). A single `./smartolt.sh` script pulls prebuilt Docker images from Docker Hub, generates `.env`, and brings the full 4-service stack online — including the reverse proxy and auto-HTTPS (Traefik with ACME HTTP-01 Let's Encrypt).

This repository is **public** and contains no application source code. The full source lives in the upstream project; the images you pull are pinned to specific versions.

## Features

- **Single entry point** — `./smartolt.sh` with subcommands: `install`, `deploy`, `status`, `logs`, `renew`, `upgrade`, `destroy`. No more juggling 4 separate scripts.
- **Non-interactive by default** — `./smartolt.sh install --yes` runs end-to-end with zero env vars (deployable defaults are committed in `.env.example`). Set env vars to override.
- **Interactive wizard** — `install` without `--yes` walks you through every prompt.
- **Prebuilt images** — pulls `asoton/smartolt-automate`, `asoton/smartolt-automate-frontend`, and `asoton/smartolt-automate-traefik` from Docker Hub. No `git clone`, no build step.
- **Four deploy profiles** — pick how the stack is exposed: direct LAN, public HTTPS via Traefik + Let's Encrypt, HTTPS via an external reverse proxy (Cloudflare Tunnel / Caddy / nginx), or frontend-only with no proxy at all. See [Deploy profiles](#deploy-profiles) below.
- **Traefik reverse proxy** (when included in the profile) — single image replaces both Caddy + certbot. Discovers services via Docker labels. Self-signed cert at boot, auto-issues Let's Encrypt when `SMARTOLT_PUBLIC_DOMAIN` is set.
- **HTTPS included** — 47 DNS providers supported out of the box (Cloudflare, Route53, DigitalOcean, Gandi, Hetzner, Google Cloud DNS, plus manual mode). Cert issuance and renewal are managed from the panel, no shell access needed. Traefik auto-renews via ACME HTTP-01 ~30 days before expiry.
- **Hot reload** — change the SmartOLT tenant URL, API token, scheduler window, or SSL settings from the panel; no `docker compose restart` required.
- **Token safety** — the SmartOLT API token is never echoed in full. The panel shows a `abc…2345`-style preview.
- **Precise teardown** — `./smartolt.sh destroy` removes only artifacts the installer created. Templates (`*.example.*`) and other Docker projects are untouched.
- **Re-runnable** — re-running install preserves your database, logs, and existing `.env` unless you opt in to overwriting.

## Quick start

The minimal install path — zero env vars required:

```bash
git clone https://github.com/asotonet/smartolt-automate-installer
cd smartolt-automate-installer
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

`.env.example` ships with deployable defaults (Costa Rica TZ, image tag `v0.4.9`, scheduler window 02:00–03:00, etc.) — see that file for the full list of tunable parameters and their meanings.

### Production deployment (with public domain)

```bash
SMARTOLT_DEPLOY_PROFILE=https-public \
SMARTOLT_PUBLIC_DOMAIN=panel.example.com \
SMARTOLT_LETSENCRYPT_EMAIL=ops@example.com \
SMARTOLT_ADMIN_USERNAME=ops \
SMARTOLT_ADMIN_PASSWORD='MyStrongPass!' \
  ./smartolt.sh install --yes
```

This:

1. Runs the `https-public` profile: frontend bound to loopback only, Traefik routes via Docker labels, Let's Encrypt cert auto-issued.
2. Traefik issues a real LE cert via ACME HTTP-01 once DNS resolves to the host (you'll see a self-signed cert warning during the first ~30s, then it switches automatically).

## Deploy profiles

A profile is a named bundle of three things: **how the frontend is exposed**, **whether Traefik runs**, and **where HTTPS comes from**. Pick the profile that matches your environment; the install wizard asks for it (or you can pin `SMARTOLT_DEPLOY_PROFILE=` in `.env` to skip the prompt). The wizard auto-detects when possible: `SMARTOLT_PUBLIC_DOMAIN` set → `https-public`, otherwise `lan`.

| Profile | Frontend on host | Traefik | HTTPS | Use when |
|---|---|---|---|---|
| `lan` | `:8080` on `0.0.0.0` | runs, doesn't route (self-signed on `:443`) | none (LE off) | LAN testing, no DNS, no public exposure |
| `https-public` | loopback `:8080` only | runs, routes by labels | Let's Encrypt via ACME HTTP-01 | Production with a public domain |
| `https-behind-external-proxy` | loopback `:8080` only | **doesn't run** | handled by your external proxy | Cloudflare Tunnel / Caddy / nginx in front of the host; the stack never sees the public network |
| `frontend-only` | `:8080` on `0.0.0.0` | **doesn't run** | none | Lowest resource footprint; LAN only, no HTTPS, no proxy container |

`SMARTOLT_DEPLOY_PROFILE` is the single knob. The wizard writes `EXPOSE_FRONTEND_DIRECTLY`, `FRONTEND_BIND_IP`, and `TRAEFIK_ENABLE` to `.env` so subsequent `./smartolt.sh deploy` calls keep the same routing without re-running the wizard.

For `https-behind-external-proxy`, point your external proxy at `http://127.0.0.1:8080` (the frontend loopback bind). Example with a local Caddy:

```caddyfile
# /etc/caddy/Caddyfile
panel.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

For `frontend-only`, open `http://HOST:8080/` directly. There is no HTTPS and no external entry point.

The Traefik container is excluded from the compose stack in `https-behind-external-proxy` and `frontend-only` profiles (via Compose's `profiles:` feature), so it doesn't pull, doesn't start, and doesn't bind ports. The `lan` profile keeps Traefik running (so `:443` serves an instant self-signed HTTPS), but disables routing by labels — useful when you want to flip between `:8080` and `:443` without redeploying.

If you change profile after install, edit `SMARTOLT_DEPLOY_PROFILE` in `.env` and run `./smartolt.sh deploy`.

The wizard will ask you for:

1. **Prerequisites** — confirms `docker`, `docker compose`, Docker Hub connectivity.
2. **Existing state** — asks whether to overwrite `.env` / keep the database.
3. **Admin credentials** — username and password (min 8 chars).
4. **SmartOLT connection** — tenant URL (`https://<you>.smartolt.com`) and API key (input is hidden).
5. **Scheduler window** — timezone and integer hour range (default: `America/Costa_Rica`, 02:00–03:00).
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
- `--keep-images` / `--keep-data` (`destroy` only)

## Non-interactive / CI mode

Set env vars to pre-answer every install question. With `--yes`, the wizard runs to completion without any prompt:

```bash
SMARTOLT_INSTALL_NONINTERACTIVE=1 \
SMARTOLT_ADMIN_USERNAME=ops \
SMARTOLT_ADMIN_PASSWORD='MyStrongPass!' \
SMARTOLT_BASE_URL=https://my-tenant.smartolt.com \
SMARTOLT_API_KEY=your-api-key \
SCHEDULER_TIMEZONE=America/Costa_Rica \
SCHEDULER_HOUR_START=2 \
SCHEDULER_HOUR_END=3 \
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
| `SMARTOLT_BASE_URL` | _(empty)_ | Tenant URL, e.g. `https://my-tenant.smartolt.com`. Set from the panel after first login. |
| `SMARTOLT_API_KEY` | _(empty)_ | API key with read on `/get_olts`, `/get_onus_statuses`, write on `/onu/reboot`. Set from the panel. |
| `INITIAL_ADMIN_USERNAME` / `_PASSWORD` | `admin` / `change-me-now` | Created on first boot. After that, manage users from the panel. `change-me-now` is a sentinel that triggers random generation in non-interactive mode. |
| `SCHEDULER_TIMEZONE` | `America/Costa_Rica` | IANA timezone |
| `SCHEDULER_HOUR_START` / `_END` | `2` / `3` | Window as integer hours; END must be > START |
| `SMARTOLT_IMAGE` | `asoton/smartolt-automate:v0.4.9` | Backend + web tier image |
| `SMARTOLT_FRONTEND_IMAGE` | `asoton/smartolt-automate-frontend:v0.4.9` | Frontend image |
| `PROXY_IMAGE` | `asoton/smartolt-automate-traefik:v0.4.9` | Traefik reverse proxy + ACME |
| `PULL_POLICY` | `always` | `always` pulls on every `up`; `missing`/`if_not_present` honours local cache |
| `SMARTOLT_DEPLOY_PROFILE` | _(empty — inferred)_ | One of `lan`, `https-public`, `https-behind-external-proxy`, `frontend-only`. See [Deploy profiles](#deploy-profiles). If empty, the wizard infers from `SMARTOLT_PUBLIC_DOMAIN`: set → `https-public`, empty → `lan`. |
| `SMARTOLT_PUBLIC_DOMAIN` | _(empty)_ | When set, Traefik issues a real Let's Encrypt cert via HTTP-01. The hostname's DNS A record MUST point at this host. When empty, Traefik serves a self-signed cert (instant HTTPS, browser warning). Required for the `https-public` profile; ignored for the others. |
| `SMARTOLT_LETSENCRYPT_EMAIL` | `admin@example.com` | Email for ACME registration |
| `EXPOSE_FRONTEND_DIRECTLY` | `true` | When `true`, the frontend publishes on `0.0.0.0:8080` (LAN/test mode). When `false`, only reachable via Traefik on `:443` (production with a public domain). Auto-detected from `SMARTOLT_PUBLIC_DOMAIN` by `install`. |
| `TRAEFIK_DASHBOARD` | `false` | Set to `true` to enable Traefik's web dashboard on `:8081`. |

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

The web tier mounts `/var/run/docker.sock` so the core scheduler can `docker compose exec` into the Traefik container for renewal flows. This is documented as the only practical way to drive cert operations without exposing a custom control port.

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

- `--keep-images` — preserve the 3 asoton/smartolt-automate* images
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
| Traefik container shows `unhealthy` on Windows + Docker Desktop | The Traefik `docker` provider can't read the Windows named pipe (`/var/run/docker.sock` is a `\\.\pipe\docker_engine` on Windows hosts) | Expected on Windows + Docker Desktop. Use `http://localhost:8080/` (with `EXPOSE_FRONTEND_DIRECTLY=true`) to access the UI directly. On Linux the provider works normally. |
| Traefik logs `client version 1.24 is too old` on a fresh Linux install (Ubuntu 24.04+ / Docker Engine 29+) | The bundled Traefik binary in the `:v0.4.9` image has a docker client pinned to API v1.24, which the modern Docker daemon rejects. ACME certs never get issued; the panel UI is unreachable on `:443`. | Pin `PROXY_IMAGE=asoton/smartolt-automate-traefik:latest` in `.env` and `./smartolt.sh deploy`. The `:latest` tag ships Traefik 3.7+, which negotiates a modern API version with the daemon. |
| Scheduler runs at the wrong hour after install | The wizard writes `SCHEDULER_TIMEZONE` to `.env`, but the core scheduler actually reads its timezone from the bind-mounted `configs/global.yaml` file. The installer copies a template default that is not refreshed when you change `SCHEDULER_TIMEZONE`. | Edit `configs/global.yaml` to match `SCHEDULER_TIMEZONE`. The core hot-reloads it within ~2s. |
| `docker compose pull` reports `not found` for a tag that exists on Docker Hub | The image registry occasionally returns stale negative responses. | Wait 5–10 minutes and retry. Alternatively pull the specific image manually (`docker pull asoton/smartolt-automate-traefik:latest`) before `./smartolt.sh deploy`. |

## Publishing a new release

`scripts/release.sh` is self-contained: by default it `docker pull`s the 3 images from Docker Hub at the requested version, retags as `:latest`, and pushes both. No local build required.

```bash
# Tag + push with the version in .env
./scripts/release.sh

# Tag + push a specific version (e.g. for a release candidate)
./scripts/release.sh v0.5.0

# Skip the docker pull and use whatever is already in the local cache
# (use this if you've built the images locally from source)
./scripts/release.sh v0.5.0 --skip-pull

# Verify a tag is live on Docker Hub (no push)
./scripts/release.sh --check
./scripts/release.sh --check v0.5.0
```

The script logs in via `~/.docker/config.json` (run `docker login -u asoton` first). Override with `DOCKERHUB_NAMESPACE=...` to push to a personal repo.

It always updates `:latest` alongside the explicit version, so fresh installs that don't pin a tag still pull the latest stable.

## Related

- **Upstream project**: <https://github.com/asotonet/smartolt-automate> — full source, CI, release pipeline.
- **SmartOLT API docs**: <https://smartolt.com/api-docs> (login required).

## License

MIT — see [LICENSE](./LICENSE).
