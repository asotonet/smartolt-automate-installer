#!/usr/bin/env bash
# SmartOLT Automate installer — interactive wizard.
#
# Pulls four prebuilt images from Docker Hub (asoton/smartolt-automate, ...-frontend,
# ...-proxy, ...-certbot) and brings them up as a 5-service compose stack with
# healthchecks, reverse-proxy, optional HTTPS.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/asotonet/smartolt-automate-installer/main/scripts/install.sh | bash
#   # or, after cloning:
#   ./scripts/install.sh
#
# Re-runnable: existing .env and data/ are preserved unless explicitly overwritten.

set -euo pipefail

# ─── terminal styling ──────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[36m"; NC="\033[0m"
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; BLUE=""; NC=""
fi

# ─── bootstrap: detect invocation mode and fetch assets if needed ─────────────
#
# When invoked as 'curl ... | bash', we don't have access to .env.example,
# docker-compose.yml, etc. We fetch the repo into a tempdir and chdir there.
# When invoked as './scripts/install.sh' from a clone, we just use the local
# directory.
REPO_OWNER="${SMARTOLT_INSTALLER_REPO_OWNER:-asotonet}"
REPO_NAME="${SMARTOLT_INSTALLER_REPO_NAME:-smartolt-automate-installer}"
REPO_REF="${SMARTOLT_INSTALLER_REPO_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}"

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
is_piped=0
if [[ -z "${SCRIPT_PATH}" || "${SCRIPT_PATH}" == "bash" || ! -f "${SCRIPT_PATH}" ]]; then
  is_piped=1
fi

if [[ "$is_piped" == "1" ]]; then
  # Need to fetch the rest of the repo before we can do anything.
  TMPDIR_INSTALL="$(mktemp -d -t smartolt-install-XXXXXX)"
  trap 'rm -rf "$TMPDIR_INSTALL"' EXIT
  printf "==> Fetching installer assets from %s/%s@%s ...\n" "$REPO_OWNER" "$REPO_NAME" "$REPO_REF"
  for f in .env.example docker-compose.yml configs/olts.example.yaml scripts/stack.sh; do
    mkdir -p "$TMPDIR_INSTALL/$(dirname "$f")"
    if ! curl -fsSL "$RAW_BASE/$f" -o "$TMPDIR_INSTALL/$f"; then
      printf "ERROR: failed to fetch %s\n" "$f" >&2
      exit 1
    fi
  done
  chmod +x "$TMPDIR_INSTALL/scripts/stack.sh"
  cd "$TMPDIR_INSTALL"
  printf "    \033[32m\u2713\033[0m Assets ready in %s\n" "$TMPDIR_INSTALL"
else
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
  cd "$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo "$SCRIPT_DIR")"
fi

# ─── output helpers ───────────────────────────────────────────────────────────
step() { printf "\n${BLUE}==>${NC} ${BOLD}%s${NC}\n" "$1"; }
ok()   { printf "    ${GREEN}\u2713${NC} %s\n" "$1"; }
warn() { printf "    ${YELLOW}!${NC} %s\n" "$1"; }
err()  { printf "    ${RED}\u2717${NC} %s\n" "$1"; }

# ─── defaults ─────────────────────────────────────────────────────────────────
DEFAULT_IMAGE_TAG="${SMARTOLT_IMAGE_TAG:-v0.2.0}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-asoton}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-smartolt_api_automate}"

ask() {
  local var="$1" prompt="$2" default="${3:-}" secret="${4:-}"
  local reply
  local displayed_default="${default:-(required)}"

  # When invoked via 'curl ... | bash', stdin is the script body, not the
  # terminal. Reading from stdin would consume the rest of the script.
  # Detect this and switch to /dev/tty so the user can actually type.
  # We probe by trying to open /dev/tty on fd 3.
  local tty_ok=0
  if [[ ! -t 0 ]]; then
    if { exec 3</dev/tty; } 2>/dev/null; then
      tty_ok=1
      exec 3<&-
    fi
  fi

  if [[ "$tty_ok" == "1" ]]; then
    if [[ "$secret" == "1" ]]; then
      read -r -s -p "$(printf "    %s [%s]: " "$prompt" "$displayed_default")" reply </dev/tty
      printf "\n"
    else
      read -r -p "$(printf "    %s [%s]: " "$prompt" "$displayed_default")" reply </dev/tty
    fi
  else
    if [[ "$secret" == "1" ]]; then
      read -r -s -p "$(printf "    %s [%s]: " "$prompt" "$displayed_default")" reply
      printf "\n"
    else
      read -r -p "$(printf "    %s [%s]: " "$prompt" "$displayed_default")" reply
    fi
  fi
  reply="${reply:-$default}"
  if [[ -z "$reply" ]]; then
    err "Value required for $var"
    return 1
  fi
  printf -v "$var" '%s' "$reply"
}

ask_yn() {
  local var="$1" prompt="$2" default="${3:-Y}"
  local reply

  local tty_ok=0
  if [[ ! -t 0 ]]; then
    if { exec 3</dev/tty; } 2>/dev/null; then
      tty_ok=1
      exec 3<&-
    fi
  fi

  if [[ "$tty_ok" == "1" ]]; then
    read -r -p "$(printf "    %s [Y/n]: " "$prompt")" reply </dev/tty
  else
    read -r -p "$(printf "    %s [Y/n]: " "$prompt")" reply
  fi
  reply="${reply:-$default}"
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    printf -v "$var" 'y'
  else
    printf -v "$var" 'n'
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; return 1; }
}

# ─── 1. prerequisites ─────────────────────────────────────────────────────────
step "1/7  Verifying prerequisites"
require_cmd docker || exit 1
ok "docker $(docker --version | awk '{print $3}' | tr -d ',')"

if ! docker info >/dev/null 2>&1; then
  err "Can't reach the Docker daemon. Is it running?"
  exit 1
fi
ok "Docker daemon reachable"

if ! docker compose version >/dev/null 2>&1; then
  if ! command -v docker-compose >/dev/null 2>&1; then
    err "Neither 'docker compose' (v2) nor 'docker-compose' (v1) found."
    exit 1
  fi
  warn "Found legacy docker-compose v1. Consider migrating to the 'docker compose' plugin."
fi
ok "docker compose available"

# Connectivity to Docker Hub (informational)
if curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
  "https://registry-1.docker.io/v2/" | grep -q '^200\|^401$'; then
  ok "Docker Hub reachable"
else
  warn "Docker Hub not reachable from this network. 'docker compose pull' may fail."
fi

# ─── 2. current state ─────────────────────────────────────────────────────────
step "2/7  Inspecting current state"
if [[ -f ".env" ]]; then
  warn "Existing .env found in this directory."
  ask_yn OVERWRITE_ENV "Overwrite .env?"
else
  OVERWRITE_ENV="y"
fi

if [[ -d "data" && -f "data/app.db" ]]; then
  warn "Existing database found (data/app.db)."
  ask_yn KEEP_DB "Keep database (admin users, history)?" "Y"
else
  KEEP_DB="Y"
fi

# ─── 3. admin credentials ─────────────────────────────────────────────────────
step "3/7  Admin credentials"
if [[ "$KEEP_DB" == "y" ]]; then
  warn "Keeping existing database — admin credentials below apply only on a fresh DB."
fi
ask ADMIN_USER     "Admin username"               "admin"
ADMIN_PASSWORD=""
ask ADMIN_PASSWORD "Admin password (min 8 chars)" "" 1
while [[ "${#ADMIN_PASSWORD}" -lt 8 ]]; do
  err "Password too short (min 8 chars)."
  ADMIN_PASSWORD=""
  ask ADMIN_PASSWORD "Admin password (min 8 chars)" "" 1
done
ok "Admin user: $ADMIN_USER"

# ─── 4. SmartOLT connection ────────────────────────────────────────────────────
step "4/7  SmartOLT tenant connection"
ask OLT_BASE_URL "Tenant base URL"   "https://my-tenant.smartolt.com"
case "$OLT_BASE_URL" in
  https://*.smartolt.com|https://*.smartolt.net) ;;
  https://*)  warn "URL doesn't look like a SmartOLT subdomain — continuing anyway.";;
  *)          err "URL must start with https://"; exit 1;;
esac
ask OLT_API_KEY "SmartOLT API key" "" 1
ok "Tenant: $OLT_BASE_URL"

# ─── 5. scheduler window ───────────────────────────────────────────────────────
step "5/7  Scheduler window"
ask_yn USE_BOGOTA "Use America/Bogota timezone?" "Y"
if [[ "$USE_BOGOTA" == "y" ]]; then
  TZ_NAME="America/Bogota"
else
  ask TZ_NAME "IANA timezone (e.g. America/Mexico_City)" "America/Bogota"
fi
ask SCHED_HOUR_START "Window START hour (0-23, integer)" "2"
ask SCHED_HOUR_END   "Window END hour   (0-23, integer)" "3"
if ! [[ "$SCHED_HOUR_START" =~ ^[0-9]+$ && "$SCHED_HOUR_END" =~ ^[0-9]+$ ]]; then
  err "Hours must be integers."
  exit 1
fi
if (( SCHED_HOUR_END <= SCHED_HOUR_START )); then
  err "End hour must be GREATER than start hour (no midnight crossing in MVP)."
  exit 1
fi
ok "Window: ${SCHED_HOUR_START}:00 to ${SCHED_HOUR_END}:00 ($TZ_NAME)"

# ─── 6. public access (HTTPS) ──────────────────────────────────────────────────
step "6/7  Public access / HTTPS"
ask_yn ENABLE_SSL "Expose the dashboard to the internet with HTTPS?" "N"
ENABLE_SSL_ANS="$ENABLE_SSL"
PUBLIC_DOMAIN=""
ADMIN_EMAIL=""
if [[ "$ENABLE_SSL" == "y" ]]; then
  ask PUBLIC_DOMAIN "Public domain (e.g. panel.example.com)" ""
  ask ADMIN_EMAIL   "Email for Let's Encrypt notifications"  "admin@${PUBLIC_DOMAIN#*.}"
  ok "HTTPS will be enabled for $PUBLIC_DOMAIN after you issue a cert in the panel."
else
  ok "HTTP only (default proxy ports 80/443)."
fi

# ─── 7. write & deploy ────────────────────────────────────────────────────────
step "7/7  Generating configuration"

if [[ "$OVERWRITE_ENV" == "y" ]]; then
  cp -f .env.example .env
  # Substitute values into the template.
  sed -i.bak \
    -e "s|^SMARTOLT_BASE_URL=.*|SMARTOLT_BASE_URL=${OLT_BASE_URL}|" \
    -e "s|^SMARTOLT_API_KEY=.*|SMARTOLT_API_KEY=${OLT_API_KEY}|" \
    -e "s|^SCHEDULER_TIMEZONE=.*|SCHEDULER_TIMEZONE=${TZ_NAME}|" \
    -e "s|^SCHEDULER_HOUR_START=.*|SCHEDULER_HOUR_START=${SCHED_HOUR_START}|" \
    -e "s|^SCHEDULER_HOUR_END=.*|SCHEDULER_HOUR_END=${SCHED_HOUR_END}|" \
    -e "s|^TZ=.*|TZ=${TZ_NAME}|" \
    -e "s|^INITIAL_ADMIN_USERNAME=.*|INITIAL_ADMIN_USERNAME=${ADMIN_USER}|" \
    -e "s|^INITIAL_ADMIN_PASSWORD=.*|INITIAL_ADMIN_PASSWORD=${ADMIN_PASSWORD}|" \
    -e "s|^SMARTOLT_IMAGE=.*|SMARTOLT_IMAGE=${DOCKERHUB_NAMESPACE}/smartolt-automate:${DEFAULT_IMAGE_TAG}|" \
    -e "s|^SMARTOLT_FRONTEND_IMAGE=.*|SMARTOLT_FRONTEND_IMAGE=${DOCKERHUB_NAMESPACE}/smartolt-automate-frontend:${DEFAULT_IMAGE_TAG}|" \
    -e "s|^PROXY_IMAGE=.*|PROXY_IMAGE=${DOCKERHUB_NAMESPACE}/smartolt-automate-proxy:${DEFAULT_IMAGE_TAG}|" \
    -e "s|^CERTBOT_IMAGE=.*|CERTBOT_IMAGE=${DOCKERHUB_NAMESPACE}/smartolt-automate-certbot:${DEFAULT_IMAGE_TAG}|" \
    .env
  rm -f .env.bak
  ok ".env written"
else
  warn "Keeping existing .env"
fi

mkdir -p configs
if [[ ! -f "configs/olts.yaml" ]]; then
  if [[ -f "configs/olts.example.yaml" ]]; then
    cp -f configs/olts.example.yaml configs/olts.yaml
    ok "configs/olts.yaml created from template"
  else
    warn "No configs/olts.yaml template shipped. You'll need to create one before enabling OLTs."
  fi
fi

ask_yn DO_PULL "Run 'docker compose pull' now?" "Y"
if [[ "$DO_PULL" == "y" ]]; then
  docker compose pull
fi

ask_yn DO_UP "Bring the stack up with 'docker compose up -d'?" "Y"
if [[ "$DO_UP" == "y" ]]; then
  docker compose up -d
fi

# ─── healthcheck ──────────────────────────────────────────────────────────────
step "Verifying healthchecks"
sleep 5
docker compose ps
echo ""
printf "  Probing /api/service/livez ...\n"
HEALTH_URL="http://localhost/api/service/livez"
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sSf -o /dev/null --max-time 4 "$HEALTH_URL"; then
    ok "Service reachable at $HEALTH_URL"
    break
  fi
  sleep 3
done

# ─── summary ──────────────────────────────────────────────────────────────────
cat <<EOF

${BOLD}Done.${NC}

  Dashboard:      ${BLUE}http://localhost/${NC}
  API health:     ${BLUE}${HEALTH_URL}${NC}
  Admin login:    ${BOLD}${ADMIN_USER}${NC} / (the password you set)

${BOLD}Next steps:${NC}
  - Open ${BLUE}http://localhost/${NC} and log in.
  - Go to ${BOLD}Configuración → Conexión SmartOLT${NC} — the values you provided
    here are the initial bootstrap; the panel is the source of truth after.
  $(
    if [[ "$ENABLE_SSL_ANS" == "y" ]]; then
      printf "%s\n" \
        "- Go to ${BOLD}Configuración → Acceso público${NC}, pick your DNS provider,"
      printf "%s\n" \
        "  fill in its credentials, and issue the certificate."
    fi
  )
  - Add OLTs by editing ${BOLD}configs/olts.yaml${NC} (or via the panel when ready).

${BOLD}Re-running:${NC}
  ./scripts/install.sh             # re-run wizard (preserves data/)
  ./scripts/stack.sh status        # show status + URLs
  ./scripts/stack.sh logs web      # tail logs
  ./scripts/stack.sh upgrade       # pull new images + up -d
  ./scripts/stack.sh down          # stop the stack
EOF