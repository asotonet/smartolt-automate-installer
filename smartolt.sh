#!/usr/bin/env bash
# SmartOLT Automate installer — single entry point.
#
# Usage:
#   ./smartolt.sh install   [flags]   first-time deploy (wizard + pull + up)
#   ./smartolt.sh deploy              re-apply docker compose up -d
#   ./smartolt.sh status              container status + healthchecks
#   ./smartolt.sh logs [service]      tail logs (-f) of one or all services
#   ./smartolt.sh renew               force certbot renew (debug only)
#   ./smartolt.sh upgrade [ver]       pull new images, restart containers
#   ./smartolt.sh destroy [flags]     nuke everything the installer created
#
# Common flags (works on install / destroy / upgrade):
#   -y, --yes       skip confirmation prompts
#   --dry-run       print the plan without changing anything
#
# install-only flags:
#   --non-interactive    don't prompt (use env vars + defaults)
#
# destroy-only flags:
#   --keep-images       don't delete the 4 asoton/smartolt-automate* images
#   --keep-certs        preserve the certbot volume
#   --keep-data         preserve data/, logs/, state/ on the host
#
# Environment variables (install/upgrade):
#   SMARTOLT_ADMIN_USERNAME     default: admin
#   SMARTOLT_ADMIN_PASSWORD     default: random 20-char (printed at end)
#   SMARTOLT_BASE_URL           SmartOLT tenant URL (deferred to panel if empty)
#   SMARTOLT_API_KEY            SmartOLT API key
#   SMARTOLT_TIMEZONE           IANA tz, default: America/Bogota
#   SMARTOLT_HOUR_START         0-23, default: 2
#   SMARTOLT_HOUR_END           0-23, default: 3
#   SMARTOLT_PUBLIC_DOMAIN      enables HTTPS if set
#   SMARTOLT_LETSENCRYPT_EMAIL  default: admin@<public_domain>
#   SMARTOLT_OVERWRITE_ENV      Y to overwrite existing .env
#   SMARTOLT_KEEP_DB            N to wipe the existing database
#   SMARTOLT_INSTALL_NONINTERACTIVE   same as --non-interactive
#   SMARTOLT_INSTALL_SKIP_DEPLOY      write files only, don't deploy
#   SMARTOLT_INSTALL_DRY_RUN          same as --dry-run
#   SMARTOLT_IMAGE_TAG              default: v0.3.3
#   DOCKERHUB_NAMESPACE             default: asoton

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CMD="${1:-status}"
shift || true

# ─── output helpers ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  RED=$'\033[31m'; BLUE=$'\033[36m'; NC=$'\033[0m'
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; BLUE=""; NC=""
fi
step() { printf "\n%s==>%s %s%s%s\n" "$BLUE" "$NC" "$BOLD" "$*" "$NC"; }
ok()   { printf "    %s✓%s %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "    %s!%s %s\n" "$YELLOW" "$NC" "$*"; }
err()  { printf "    %s✗%s %s\n" "$RED" "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }
confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local reply
  printf "%sType YES to continue:%s " "$RED" "$NC"
  read -r reply
  [[ "$reply" == "YES" ]]
}

# ─── flags ──────────────────────────────────────────────────────────────────
ASSUME_YES=0
DRY_RUN=0
KEEP_IMAGES=0
KEEP_CERTS=0
KEEP_DATA=0
NONINTERACTIVE=0
NO_FOLLOW=0
SUB_ARGS=()  # non-flag args passed through to the subcommand

# Parse flags anywhere in the arg list. Flags stay attached to ARGS so
# subcommands can read them; positional args go to SUB_ARGS.
parse_args=("$@")
i=0
while [[ $i -lt ${#parse_args[@]} ]]; do
  a="${parse_args[$i]}"
  case "$a" in
    -y|--yes)         ASSUME_YES=1; NONINTERACTIVE=1 ;;  # -y implies non-interactive
    --dry-run)        DRY_RUN=1 ;;
    --keep-images)    KEEP_IMAGES=1 ;;
    --keep-certs)     KEEP_CERTS=1 ;;
    --keep-data)      KEEP_DATA=1 ;;
    --non-interactive) NONINTERACTIVE=1 ;;
    --no-follow)      NO_FOLLOW=1 ;;
    --help|-h)        sed -n '2,28p' "$0"; exit 0 ;;
    *)                SUB_ARGS+=("$a") ;;
  esac
  i=$((i+1))
done
[[ -n "${SMARTOLT_INSTALL_NONINTERACTIVE:-}" ]] && NONINTERACTIVE=1
if [[ $NONINTERACTIVE -eq 0 && ! -t 0 && ! -r /dev/tty ]]; then
  NONINTERACTIVE=1
fi

# ─── load .env (if present) so config flows into our defaults ──────────────
# We load only if .env exists (no error if it doesn't). Anything the
# operator set explicitly in the shell still wins (the load uses no -u to
# ignore already-set variables, except for a few we want to honor from
# .env even when the shell has a value).
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# ─── shared helpers ──────────────────────────────────────────────────────────
DEFAULT_IMAGE_TAG="${SMARTOLT_IMAGE_TAG:-v0.5.3}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-asoton}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-smartolt_api_automate}"
export COMPOSE_PROJECT_NAME

# Decide whether the frontend container publishes on all interfaces
# (0.0.0.0) or only on the loopback (127.0.0.1).
#
# Behavior:
#   - If the operator explicitly set EXPOSE_FRONTEND_DIRECTLY in the shell
#     (passed via env var when invoking this script), respect it as-is.
#   - Otherwise, auto-detect based on SMARTOLT_PUBLIC_DOMAIN:
#       empty PUBLIC_DOMAIN → expose directly (true, 0.0.0.0)
#       set PUBLIC_DOMAIN   → loopback only (false, 127.0.0.1)
#   - If the variable is unset entirely, default to direct (true, 0.0.0.0).
#
# Strip trailing \r that Windows-edited .env files may carry.
EXPOSE_FRONTEND_DIRECTLY="${EXPOSE_FRONTEND_DIRECTLY%$'\r'}"
if [[ -z "${EXPOSE_FRONTEND_DIRECTLY:-}" ]]; then
  # Variable is unset → default to direct.
  EXPOSE_FRONTEND_DIRECTLY="true"
fi
# At this point EXPOSE_FRONTEND_DIRECTLY is either "true", "false", or
# "yes"/"no" — anything else is treated as false (loopback).
if [[ "${EXPOSE_FRONTEND_DIRECTLY}" =~ ^[Yy](es)?$ ]]; then
  FRONTEND_BIND_IP="${FRONTEND_BIND_IP:-0.0.0.0}"
else
  FRONTEND_BIND_IP="${FRONTEND_BIND_IP:-127.0.0.1}"
fi
export FRONTEND_BIND_IP EXPOSE_FRONTEND_DIRECTLY

CONTAINER_NAMES=(smartolt-automate smartolt-automate-web smartolt-automate-frontend smartolt-automate-traefik)

container_status() {
  docker ps -a --filter "name=smartolt" \
    --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
}

# Write KEY=VALUE pairs into .env, preserving order and comments. Pure
# Python so we don't fight bash quote escaping on edge cases (values with
# spaces, $, ", ', etc).
_write_env_file() {
  python3 - "$@" <<'PY'
import sys, os, pathlib

path = pathlib.Path(".env")
keys = ["SMARTOLT_BASE_URL", "SMARTOLT_API_KEY", "SCHEDULER_TIMEZONE",
        "SCHEDULER_HOUR_START", "SCHEDULER_HOUR_END", "TZ",
        "INITIAL_ADMIN_USERNAME", "INITIAL_ADMIN_PASSWORD",
        "SMARTOLT_IMAGE", "SMARTOLT_FRONTEND_IMAGE",
        "PROXY_IMAGE", "CERTBOT_IMAGE"]
vals = sys.argv[1:1 + len(keys)]
if len(vals) != len(keys):
    sys.exit(f"Internal error: expected {len(keys)} env values, got {len(vals)}")
pairs = list(zip(keys, vals))

existing, order = {}, []
if path.exists():
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k = line.split("=", 1)[0]
            if k not in existing:
                existing[k] = line
                order.append(k)

out = []
for k in order:
    if k not in dict(pairs):
        out.append(existing[k])

for k, v in pairs:
    needs_quote = any(c in v for c in ' "\'\\$') or v == ""
    if needs_quote:
        escaped = v.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")
        out.append(f'{k}="{escaped}"')
    else:
        out.append(f"{k}={v}")

path.write_text("\n".join(out) + "\n")
PY
}

# ─── subcommand: install ─────────────────────────────────────────────────────
# Auto-install Docker via the official get-docker.sh script when the
# binary or daemon is missing. This makes `./smartolt.sh install` a true
# one-command deploy on a fresh Ubuntu/Debian/CentOS host.
#
# Flow:
#   1. Detect whether the `docker` CLI is on PATH.
#   2. If not (or `docker info` fails), curl the official install script
#      from get.docker.com and pipe it to `sh`.
#   3. Verify the install by re-running `docker --version` and
#      `docker info`.
#   4. Skip on Windows / macOS (operator installs Docker Desktop manually).
_ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    return 0
  fi
  # Windows / macOS — we can't auto-install Docker here. Operator runs
  # Docker Desktop manually.
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*|Darwin*)
      return 0 ;;
  esac
  warn "Docker not detected. Installing via the official get-docker.sh script..."
  if ! command -v curl >/dev/null 2>&1; then
    die "curl is required to install Docker automatically. Install curl (e.g. 'apt install curl') and re-run."
  fi
  # Run the official Docker install script. It auto-detects the distro
  # and uses the right package manager (apt for Debian/Ubuntu, dnf/yum
  # for Fedora/CentOS/RHEL, etc.). Output goes to a log file we can show
  # on failure.
  local log
  log="$(mktemp -t smartolt-install-docker-XXXXXX.log 2>/dev/null || echo /tmp/smartolt-install-docker.log)"
  if ! curl --fail --silent --show-error --location \
        https://get.docker.com -o "$log"; then
    err "curl failed to download get.docker.com. Install Docker manually:"
    err "  https://docs.docker.com/engine/install/"
    sed 's/^/    /' "$log" >&2
    rm -f "$log"
    die "aborting install"
  fi
  if ! sh "$log" 2>&1 | tee -a "$log" >&2; then
    err "Docker install script failed. Last lines:"
    tail -n 20 "$log" >&2
    rm -f "$log"
    die "aborting install"
  fi
  rm -f "$log"
  # Sanity-check the install.
  if ! command -v docker >/dev/null 2>&1; then
    die "Docker install script ran but 'docker' is still not on PATH."
  fi
  # The install script doesn't auto-start the daemon on some distros.
  if ! docker info >/dev/null 2>&1; then
    warn "Docker installed but daemon is not running. Trying to start it..."
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now docker || die "Failed to start docker via systemctl."
    elif command -v service >/dev/null 2>&1; then
      service docker start || die "Failed to start docker via service."
    else
      die "Docker installed but daemon not running and no init system detected. Start it manually."
    fi
    # Give the daemon a moment to come up.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      docker info >/dev/null 2>&1 && break
      sleep 1
    done
  fi
  if ! docker info >/dev/null 2>&1; then
    die "Docker installed but the daemon is still not responding."
  fi
  ok "Docker installed and running"
}

cmd_install() {
  step "0/7  Verifying prerequisites (auto-install Docker if missing)"
  _ensure_docker
  command -v docker >/dev/null || die "Missing dependency: docker"
  if ! docker info >/dev/null 2>&1; then
    die "Docker daemon is not reachable. Is Docker running?"
  fi
  ok "docker $(docker --version | awk '{print $3}' | tr -d ',')"
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose available"
  else
    die "Neither 'docker compose' (v2) nor 'docker-compose' (v1) found."
  fi

  step "2/7  Inspecting state"
  OVERWRITE_ENV="${SMARTOLT_OVERWRITE_ENV:-}"
  if [[ -z "$OVERWRITE_ENV" && -f .env ]]; then
    warn ".env exists; preserving it (set SMARTOLT_OVERWRITE_ENV=Y to overwrite)."
    OVERWRITE_ENV="n"
  fi
  [[ -z "$OVERWRITE_ENV" ]] && OVERWRITE_ENV="n"

  # First-time install: copy .env.example to .env so all env-driven
  # defaults are populated. The wizard then re-writes the user-specific
  # values on top of this baseline.
  if [[ ! -f .env ]]; then
    [[ -f .env.example ]] || die "Missing .env.example in repo (cannot bootstrap .env)"
    cp -f .env.example .env
    ok "Bootstrapped .env from .env.example (with safe defaults)"
  fi

  KEEP_DB="${SMARTOLT_KEEP_DB:-}"
  [[ -z "$KEEP_DB" && -f data/users.db ]] && { warn "data/users.db exists"; confirm || die "Aborted."; KEEP_DB="n"; }
  [[ -z "$KEEP_DB" ]] && KEEP_DB="y"

  step "3/7  Admin credentials"
  ADMIN_USER="${SMARTOLT_ADMIN_USERNAME:-}"
  [[ -z "$ADMIN_USER" ]] && { if [[ $NONINTERACTIVE -eq 1 ]]; then ADMIN_USER="admin"; else
    read -r -p "    Admin username [admin]: " ADMIN_USER; ADMIN_USER="${ADMIN_USER:-admin}"; fi
    ok "Admin username: $ADMIN_USER"
  }
  ADMIN_PASSWORD=""
  ADMIN_PASSWORD_GENERATED=""

  # Resolve admin password from, in order of priority:
  #   1. SMARTOLT_ADMIN_PASSWORD env var (highest priority, used by CI)
  #   2. INITIAL_ADMIN_PASSWORD from .env (the persistent setting)
  #   3. The literal default "change-me-now" is a sentinel: in non-
  #      interactive mode it triggers auto-generation. In interactive
  #      mode it triggers a prompt.
  if [[ -n "${SMARTOLT_ADMIN_PASSWORD:-}" ]]; then
    (( ${#SMARTOLT_ADMIN_PASSWORD} >= 8 )) || die "SMARTOLT_ADMIN_PASSWORD must be at least 8 characters."
    ADMIN_PASSWORD="$SMARTOLT_ADMIN_PASSWORD"
    ok "Admin password (from SMARTOLT_ADMIN_PASSWORD)."
  elif [[ -n "${INITIAL_ADMIN_PASSWORD:-}" && "${INITIAL_ADMIN_PASSWORD}" != "change-me-now" ]]; then
    (( ${#INITIAL_ADMIN_PASSWORD} >= 8 )) || die "INITIAL_ADMIN_PASSWORD in .env must be at least 8 characters."
    ADMIN_PASSWORD="$INITIAL_ADMIN_PASSWORD"
    ok "Admin password (from .env)."
  elif [[ $NONINTERACTIVE -eq 1 ]]; then
    ADMIN_PASSWORD_GENERATED="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
    ADMIN_PASSWORD="$ADMIN_PASSWORD_GENERATED"
    ok "Generated random admin password (edit INITIAL_ADMIN_PASSWORD in .env to pin)."
  else
    while :; do
      read -r -s -p "    Admin password (min 8 chars, Enter to generate): " ADMIN_PASSWORD; printf "\n"
      if [[ -z "$ADMIN_PASSWORD" ]]; then
        ADMIN_PASSWORD_GENERATED="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
        ADMIN_PASSWORD="$ADMIN_PASSWORD_GENERATED"
        ok "Generated random admin password."
        break
      fi
      (( ${#ADMIN_PASSWORD} >= 8 )) && break
      err "Password too short (min 8 characters)."
    done
  fi

  step "4/7  SmartOLT connection"
  OLT_BASE_URL="${SMARTOLT_BASE_URL:-}"
  OLT_API_KEY="${SMARTOLT_API_KEY:-}"
  if [[ -n "$OLT_BASE_URL" && -n "$OLT_API_KEY" ]]; then
    ok "Tenant (from env): $OLT_BASE_URL"
  elif [[ $NONINTERACTIVE -eq 1 ]]; then
    OLT_BASE_URL=""; OLT_API_KEY=""
    ok "Tenant: deferred to panel."
  else
    read -r -p "    Tenant base URL (Enter to skip): " OLT_BASE_URL
    if [[ -n "$OLT_BASE_URL" ]]; then
      case "$OLT_BASE_URL" in https://*) ;; *) warn "URL should start with https://. Leaving blank."; OLT_BASE_URL="";; esac
      [[ -n "$OLT_BASE_URL" ]] && { read -r -s -p "    API key: " OLT_API_KEY; printf "\n"; }
    fi
  fi

  step "5/7  Scheduler window"
  TZ_NAME="${SMARTOLT_TIMEZONE:-}"
  [[ -z "$TZ_NAME" ]] && { if [[ $NONINTERACTIVE -eq 1 ]]; then TZ_NAME="America/Bogota"; else
    read -r -p "    IANA timezone [America/Bogota]: " TZ_NAME; TZ_NAME="${TZ_NAME:-America/Bogota}"; fi
  }
  SCHED_HOUR_START="${SMARTOLT_HOUR_START:-}"
  [[ -z "$SCHED_HOUR_START" ]] && { if [[ $NONINTERACTIVE -eq 1 ]]; then SCHED_HOUR_START="2"; else
    read -r -p "    Window START hour [2]: " SCHED_HOUR_START; SCHED_HOUR_START="${SCHED_HOUR_START:-2}"; fi
  }
  SCHED_HOUR_END="${SMARTOLT_HOUR_END:-}"
  [[ -z "$SCHED_HOUR_END" ]] && { if [[ $NONINTERACTIVE -eq 1 ]]; then SCHED_HOUR_END="3"; else
    read -r -p "    Window END hour [3]: " SCHED_HOUR_END; SCHED_HOUR_END="${SCHED_HOUR_END:-3}"; fi
  }
  if ! [[ "$SCHED_HOUR_START" =~ ^[0-9]+$ && "$SCHED_HOUR_END" =~ ^[0-9]+$ ]]; then
    die "Hours must be integers."
  fi
  (( SCHED_HOUR_END > SCHED_HOUR_START )) || die "End hour must be > start hour."
  ok "Window: $(printf '%02d:00' "$SCHED_HOUR_START") to $(printf '%02d:00' "$SCHED_HOUR_END") ($TZ_NAME)"

  step "6/7  Public access (HTTPS)"
  ENABLE_SSL="n"
  if [[ -n "${SMARTOLT_PUBLIC_DOMAIN:-}" ]]; then
    ENABLE_SSL="y"
  elif [[ $NONINTERACTIVE -eq 1 ]]; then
    ok "Public access: deferred."
  else
    read -r -p "    Enable HTTPS? [y/N]: " ans; ans="${ans:-N}"
    [[ "$ans" =~ ^[Yy]$ ]] && ENABLE_SSL="y"
  fi
  PUBLIC_DOMAIN=""; ADMIN_EMAIL=""
  if [[ "$ENABLE_SSL" == "y" ]]; then
    PUBLIC_DOMAIN="${SMARTOLT_PUBLIC_DOMAIN:-}"
    [[ -z "$PUBLIC_DOMAIN" ]] && { if [[ $NONINTERACTIVE -eq 1 ]]; then
      die "SMARTOLT_PUBLIC_DOMAIN is required when SSL is enabled."
    else read -r -p "    Public domain (e.g. panel.example.com): " PUBLIC_DOMAIN; fi }
    PUBLIC_DOMAIN="${PUBLIC_DOMAIN#\*.}"
    ADMIN_EMAIL="${SMARTOLT_LETSENCRYPT_EMAIL:-admin@${PUBLIC_DOMAIN#*.}}"
    ok "HTTPS will be enabled for $PUBLIC_DOMAIN."
  else
    ok "HTTP only."
  fi

  IMAGE_TAG="${SMARTOLT_IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"

  step "7/7  Writing configuration"
  if [[ $DRY_RUN -eq 1 ]]; then
    ok "DRY_RUN — files won't be written."
    step "Plan"
    printf "    ADMIN_USER=%s\n" "$ADMIN_USER"
    printf "    ADMIN_PASSWORD=%s\n" "$([[ -n "$ADMIN_PASSWORD_GENERATED" ]] && echo '(generated)' || echo '***set***')"
    printf "    OLT_BASE_URL=%s\n" "${OLT_BASE_URL:-<deferred>}"
    printf "    TZ=%s  WINDOW=%02d:00-%02d:00\n" "$TZ_NAME" "$SCHED_HOUR_START" "$SCHED_HOUR_END"
    printf "    HTTPS=%s  DOMAIN=%s  EMAIL=%s\n" "$ENABLE_SSL" "$PUBLIC_DOMAIN" "$ADMIN_EMAIL"
    printf "    IMAGE_TAG=%s  NAMESPACE=%s\n" "$IMAGE_TAG" "$DOCKERHUB_NAMESPACE"
    return 0
  fi

  if [[ "$OVERWRITE_ENV" == "y" || ! -f .env ]]; then
    cp -f .env.example .env
    ok "Created .env"
  fi

  _write_env_file "$OLT_BASE_URL" "$OLT_API_KEY" "$TZ_NAME" \
    "$SCHED_HOUR_START" "$SCHED_HOUR_END" "$TZ_NAME" \
    "$ADMIN_USER" "$ADMIN_PASSWORD" \
    "${DOCKERHUB_NAMESPACE}/smartolt-automate:${IMAGE_TAG}" \
    "${DOCKERHUB_NAMESPACE}/smartolt-automate-frontend:${IMAGE_TAG}" \
    "${DOCKERHUB_NAMESPACE}/smartolt-automate-traefik:${IMAGE_TAG}" \
  ok "Wrote wizard values to .env"

  # Set TRAEFIK_ENABLE based on whether the operator configured a public
  # domain. Empty PUBLIC_DOMAIN = Traefik ignores the frontend/web
  # containers (operator is using the host port mapping for local testing).
  TRAEFIK_ENABLE="false"
  [[ -n "$PUBLIC_DOMAIN" ]] && TRAEFIK_ENABLE="true"
  sed -i.bak -E "s|^TRAEFIK_ENABLE=.*|TRAEFIK_ENABLE=$TRAEFIK_ENABLE|" .env
  rm -f .env.bak
  ok "TRAEFIK_ENABLE=$TRAEFIK_ENABLE (set by install based on SMARTOLT_PUBLIC_DOMAIN)"

  # Bind the frontend host port to all interfaces or loopback only,
  # depending on whether the operator wants it reachable directly or
  # only via Traefik. We always write the canonical value to .env based
  # on the current SMARTOLT_PUBLIC_DOMAIN; operators who want a fixed
  # value can edit .env *after* install (they'd have to override
  # EXPOSE_FRONTEND_DIRECTLY=true to keep the loopback bind on a
  # re-install with PUBLIC_DOMAIN set).
  if [[ -z "${PUBLIC_DOMAIN}" ]]; then
    TARGET_EFD="true"
    TARGET_BIND="0.0.0.0"
  else
    TARGET_EFD="false"
    TARGET_BIND="127.0.0.1"
  fi
  sed -i.bak -E "s|^EXPOSE_FRONTEND_DIRECTLY=.*|EXPOSE_FRONTEND_DIRECTLY=${TARGET_EFD}|" .env
  sed -i.bak -E "s|^FRONTEND_BIND_IP=.*|FRONTEND_BIND_IP=${TARGET_BIND}|" .env
  rm -f .env.bak
  ok "Frontend host bind: $TARGET_BIND (EXPOSE_FRONTEND_DIRECTLY=$TARGET_EFD)"

  mkdir -p configs
  [[ ! -f configs/olts.yaml && -f configs/olts.example.yaml ]] && {
    cp -f configs/olts.example.yaml configs/olts.yaml
    ok "Created configs/olts.yaml from template"
  }

  if [[ "${SMARTOLT_INSTALL_SKIP_DEPLOY:-0}" -eq 1 ]]; then
    ok "SKIP_DEPLOY=1 — skipping docker compose pull/up."
    return 0
  fi

  step "Bringing up the stack"
  docker compose --project-name "$COMPOSE_PROJECT_NAME" pull 2>&1 | tail -5
  docker compose --project-name "$COMPOSE_PROJECT_NAME" up -d 2>&1 | tail -8

  step "Verifying healthchecks"
  # Probe the frontend (the only host-published service) to confirm the
  # full stack is up. The backend core and web tier are internal; if the
  # frontend is serving HTTP, the compose network is healthy.
  HEALTH="${HEALTHCHECK_URL:-http://localhost:8080/}"
  up=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if curl --silent --fail --output /dev/null --max-time 4 "$HEALTH"; then
      up=1; ok "Service reachable at $HEALTH"; break
    fi
    printf "    ... retry %d/15\n" "$i"; sleep 3
  done
  [[ $up -ne 1 ]] && { warn "Healthcheck did not respond within the timeout."; warn "Run './smartolt.sh logs smartolt-automate' to debug."; exit 2; }

  printf "\n%sDone.%s\n" "$BOLD" "$NC"
  printf "  Dashboard (UI):    %shttp://localhost:8080/%s\n" "$BLUE" "$NC"
  printf "  Traefik proxy (HTTPS): %shttps://localhost/%s  (self-signed cert until SMARTOLT_PUBLIC_DOMAIN is set)\n" "$BLUE" "$NC"
  printf "  Admin user:        %s%s%s\n" "$BOLD" "$ADMIN_USER" "$NC"
  if [[ -n "$ADMIN_PASSWORD_GENERATED" ]]; then
    printf "  Admin pass:    %s%s%s  %s(generated — save it now!)%s\n" "$BOLD" "$ADMIN_PASSWORD_GENERATED" "$NC" "$YELLOW" "$NC"
  fi
}

# ─── subcommand: deploy ──────────────────────────────────────────────────────
cmd_deploy() {
  step "docker compose up -d"
  if [[ ! -f docker-compose.yml ]]; then
    die "No docker-compose.yml here. Run './smartolt.sh install' first."
  fi
  [[ -f .env ]] || die "No .env here. Run './smartolt.sh install' first."
  docker compose --project-name "$COMPOSE_PROJECT_NAME" up -d "$@"
  ok "Stack is up"
}

# ─── subcommand: status ──────────────────────────────────────────────────────
cmd_status() {
  step "Stack status"
  if [[ -f .env ]]; then
    grep -E '^(SMARTOLT_BASE_URL|INITIAL_ADMIN_USERNAME|SMARTOLT_IMAGE)=?' .env \
      | sed 's/^/    /'
  else
    warn "No .env — install first: ./smartolt.sh install"
    return 1
  fi
  printf "\n"
  step "Containers"
  container_status | while IFS=$'\t' read -r name status ports; do
    if [[ "$status" == *"healthy"* ]]; then
      printf "    ${GREEN}✓${NC} %-30s %s\n" "$name" "$status"
    elif [[ "$status" == *"Up"* ]]; then
      printf "    ${YELLOW}~${NC} %-30s %s\n" "$name" "$status"
    else
      printf "    ${RED}✗${NC} %-30s %s\n" "$name" "$status"
    fi
  done
  printf "\n"
  step "Endpoints"
  printf "    Frontend (UI):     %shttp://localhost:8080/%s\n" "$BLUE" "$NC"
  printf "    Traefik proxy (HTTPS): %shttps://localhost/%s  (self-signed cert until SMARTOLT_PUBLIC_DOMAIN is set)\n" "$BLUE" "$NC"
  [[ -f docker-compose.override.yml ]] && {
    warn "docker-compose.override.yml detected — using -f override."
  }
}

# ─── subcommand: logs ────────────────────────────────────────────────────────
cmd_logs() {
  [[ -f docker-compose.yml ]] || die "No docker-compose.yml here. Install first."
  local follow="-f"
  [[ $NO_FOLLOW -eq 1 ]] && follow=""
  docker compose --project-name "$COMPOSE_PROJECT_NAME" logs $follow --tail=100 "${SUB_ARGS[@]}"
}

# ─── subcommand: renew ───────────────────────────────────────────────────────
cmd_renew() {
  # The internal renew endpoint lives on the web tier (port 8000 inside
  # the compose network). The web tier is not published to the host, so
  # we call it via `docker exec` from inside the web container. We could
  # also have used `docker exec` on the core scheduler which POSTs to
  # the web tier internally, but invoking the endpoint directly is
  # simpler for a one-shot debug command.
  step "Forcing certbot renew"
  RESP=$(MSYS_NO_PATHCONV=1 docker exec smartolt-automate-web python -c "
import urllib.request
req = urllib.request.Request(
  'http://127.0.0.1:8000/api/admin/public-access/_internal/renew-now',
  headers={'X-Internal-Token': open('/app/data/internal_token').read().strip()},
  method='POST',
)
try:
  r = urllib.request.urlopen(req, timeout=30)
  print(r.status, r.read().decode())
except Exception as e:
  print('ERROR', e)
" 2>&1 | tail -1)
  echo "  $RESP"
  if echo "$RESP" | grep -q '200 {"ok":true'; then ok "Renewal check finished."; return 0
  else warn "Renewal check failed. Check logs: ./smartolt.sh logs smartolt-automate-traefik"; return 1; fi
}

# ─── subcommand: upgrade ─────────────────────────────────────────────────────
cmd_upgrade() {
  [[ -f .env ]] || die "No .env here. Run './smartolt.sh install' first."
  TARGET="${ARGS[0]:-$(grep -E '^SMARTOLT_IMAGE=' .env | head -1 | cut -d= -f2- | sed 's/.*://')}"
  [[ "$TARGET" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]] || die "Not a semver: $TARGET"
  [[ "$TARGET" == v* ]] || TARGET="v$TARGET"

  step "Will upgrade to $TARGET"
  if [[ $DRY_RUN -eq 1 ]]; then
    ok "DRY_RUN — files won't change."
    return 0
  fi
  confirm || { warn "Aborted."; exit 0; }

  ENV_BACKUP="$(mktemp -t upgrade-env-XXXXXX.bak)"
  cp -f .env "$ENV_BACKUP"
  trap "cp -f '$ENV_BACKUP' .env && rm -f '$ENV_BACKUP'" EXIT INT TERM

  step "Updating .env"
  for var in SMARTOLT_IMAGE SMARTOLT_FRONTEND_IMAGE PROXY_IMAGE CERTBOT_IMAGE; do
    case "$var" in
      SMARTOLT_IMAGE)         repo="smartolt-automate" ;;
      SMARTOLT_FRONTEND_IMAGE) repo="smartolt-automate-frontend" ;;
      PROXY_IMAGE)             repo="smartolt-automate-traefik" ;;
    esac
    sed -i.bak -E "s|^${var}=.*|${var}=${DOCKERHUB_NAMESPACE}/${repo}:${TARGET}|" .env
  done
  rm -f .env.bak
  ok "Tag set to $TARGET"

  step "Pulling + restarting"
  docker compose --project-name "$COMPOSE_PROJECT_NAME" pull 2>&1 | tail -5
  docker compose --project-name "$COMPOSE_PROJECT_NAME" down --remove-orphans 2>&1 | tail -3
  docker compose --project-name "$COMPOSE_PROJECT_NAME" up -d 2>&1 | tail -5
  rm -f "$ENV_BACKUP"
  trap - EXIT INT TERM
  ok "Upgrade to $TARGET complete"
}

# ─── subcommand: destroy ────────────────────────────────────────────────────
cmd_destroy() {
  step "Discovering installer artifacts"
  PROJECT=""
  if [[ -f .env ]]; then
    PROJECT=$(grep -E '^COMPOSE_PROJECT_NAME=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"\047[:space:]' || true)
  fi
  PROJECT="${PROJECT:-smartolt_api_automate}"
  ALL_PROJECTS=("$PROJECT")
  for v in $(docker volume ls --format '{{.Name}}' 2>/dev/null \
             | grep -E '_(logs|state|data|traefik_acme)$'); do
    p="${v%_logs}"; p="${p%_state}"; p="${p%_data}"; p="${p%_traefik_acme}"
    p="${p%_certbot_etc}"; p="${p%_certbot_work}"; p="${p%_certbot_logs}"
    [[ -n "$p" && "$p" != "$PROJECT" ]] && ALL_PROJECTS+=("$p")
  done

  declare -a CONTAINERS_T=() VOLUMES_T=() NETWORKS_T=() IMAGES_T=()
  for n in "${CONTAINER_NAMES[@]}"; do
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$n" && CONTAINERS_T+=("$n")
  done
  for p in "${ALL_PROJECTS[@]}"; do
    for v in ${p}_logs ${p}_state ${p}_data ${p}_traefik_acme; do
      docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$v" && VOLUMES_T+=("$v")
    done
    docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "${p}_default" && NETWORKS_T+=("${p}_default")
  done
  for r in smartolt-automate smartolt-automate-frontend smartolt-automate-traefik; do
    ids=$(docker image ls --format '{{.Repository}} {{.ID}}' 2>/dev/null | awk -v r="$r" '$1 == r {print $2}')
    [[ -n "$ids" ]] && while read -r id; do [[ -n "$id" ]] && IMAGES_T+=("$r:$id"); done <<< "$ids"
  done

  declare -a FS_FILES=()
  [[ -f .env ]] && FS_FILES+=(".env")
  [[ -f configs/olts.yaml ]] && FS_FILES+=("configs/olts.yaml")

  printf "    Project:  %s\n" "$PROJECT"
  printf "    Containers (%d):\n" "${#CONTAINERS_T[@]}"; for c in "${CONTAINERS_T[@]}"; do printf "      - %s\n" "$c"; done
  printf "    Volumes (%d):\n" "${#VOLUMES_T[@]}"; for v in "${VOLUMES_T[@]}"; do printf "      - %s\n" "$v"; done
  printf "    Networks (%d):\n" "${#NETWORKS_T[@]}"; for n in "${NETWORKS_T[@]}"; do printf "      - %s\n" "$n"; done
  printf "    Images (%d):\n" "${#IMAGES_T[@]}"; for i in "${IMAGES_T[@]}"; do printf "      - %s\n" "$i"; done
  printf "    Files (%d):\n" "${#FS_FILES[@]}"; for f in "${FS_FILES[@]}"; do printf "      - %s\n" "$f"; done
  printf "\n    NOT touched (out of scope):\n"
  printf "      - .env.example, configs/olts.example.yaml, scripts/, docker-compose.yml\n"
  printf "      - Images from other namespaces, other Docker projects\n\n"

  if [[ ${#CONTAINERS_T[@]} -eq 0 && ${#VOLUMES_T[@]} -eq 0 && ${#NETWORKS_T[@]} -eq 0 \
     && ${#IMAGES_T[@]} -eq 0 && ${#FS_FILES[@]} -eq 0 ]]; then
    ok "Nothing to remove."; return 0
  fi
  [[ $DRY_RUN -eq 1 ]] && { ok "DRY_RUN — aborting before destroy."; return 0; }
  confirm || { warn "Aborted."; exit 0; }

  step "docker compose down"
  [[ -f docker-compose.yml ]] && docker compose --project-name "$COMPOSE_PROJECT_NAME" down --remove-orphans 2>&1 | tail -3

  step "Removing containers"
  for c in "${CONTAINER_NAMES[@]}"; do docker rm -f "$c" 2>/dev/null && ok "Removed $c"; done

  step "Removing volumes"
  for v in "${VOLUMES_T[@]}"; do
    [[ $KEEP_CERTS -eq 1 && "$v" == *"_certbot_etc" ]] && { warn "Skipping $v"; continue; }
    docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$v" || continue
    docker volume rm "$v" 2>/dev/null && ok "Removed $v"
  done

  step "Removing images"
  if [[ $KEEP_IMAGES -eq 1 ]]; then warn "Skipping image removal."
  else
    for entry in "${IMAGES_T[@]}"; do
      id="${entry##*:}"
      docker image rm -f "$id" 2>/dev/null && ok "Removed $entry"
    done
  fi

  step "Removing networks"
  for n in "${NETWORKS_T[@]}"; do
    docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "$n" || continue
    docker network rm "$n" 2>/dev/null && ok "Removed $n"
  done

  step "Removing files"
  if [[ $KEEP_DATA -eq 1 ]]; then warn "Skipping filesystem cleanup."
  else
    for f in "${FS_FILES[@]}"; do rm -f "$f" && ok "Removed $f"; done
    for d in configs data logs state; do
      [[ -d "$d" ]] && find "$d" -mindepth 1 -maxdepth 1 \
        ! -name '*.example.*' ! -name '*.example' \
        -exec rm -rf {} + 2>/dev/null
    done
    ok "Cleared bind-mount dir contents (templates preserved)"
  fi

  ok "Destroy complete."
}

# ─── dispatch ───────────────────────────────────────────────────────────────
case "$CMD" in
  install)   cmd_install ;;
  deploy)    cmd_deploy ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  renew)     cmd_renew ;;
  upgrade)   cmd_upgrade "${SUB_ARGS[@]}" ;;
  destroy)   cmd_destroy ;;
  help|--help|-h|"")
    sed -n '2,12p' "$0"; exit 0 ;;
  *)  err "Unknown subcommand: $CMD"; printf "Run './smartolt.sh help' for usage.\n"; exit 1 ;;
esac
