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
#   SCHEDULER_TIMEZONE         IANA tz, default: America/Costa_Rica
#   SMARTOLT_HOUR_START         0-23, default: 2
#   SMARTOLT_HOUR_END           0-23, default: 3
#   SMARTOLT_PUBLIC_DOMAIN      enables HTTPS if set
#   SMARTOLT_LETSENCRYPT_EMAIL  default: admin@<public_domain>
#   SMARTOLT_OVERWRITE_ENV      Y to overwrite existing .env
#   SMARTOLT_KEEP_DB            N to wipe the existing database
#   SMARTOLT_INSTALL_NONINTERACTIVE   same as --non-interactive
#   SMARTOLT_INSTALL_SKIP_DEPLOY      write files only, don't deploy
#   SMARTOLT_INSTALL_DRY_RUN          same as --dry-run
#   SMARTOLT_IMAGE_TAG              default: v0.4.9
#   DOCKERHUB_NAMESPACE             default: asoton

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# The subcommand is mandatory. We do NOT default to 'status' — that
# used to silently run `./smartolt.sh` and print a status table, which
# obscured typos like `./smartolt.sh isntall`. An empty CMD is caught
# by the dispatch block below, which prints usage and exits non-zero.
CMD="${1:-}"
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
    --help|-h)        : ;;  # let the dispatch block handle --help / -h
    *)                SUB_ARGS+=("$a") ;;
  esac
  i=$((i+1))
done
[[ -n "${SMARTOLT_INSTALL_NONINTERACTIVE:-}" ]] && NONINTERACTIVE=1
if [[ $NONINTERACTIVE -eq 0 && ! -t 0 && ! -r /dev/tty ]]; then
  NONINTERACTIVE=1
fi

# ─── load .env (if present) so config flows into our defaults ──────────────
# We load only if .env exists (no error if it doesn't).
#
# Shell-exported vars WIN over .env values. A plain `set -a; source;
# set +a` would let .env overwrite the shell — e.g. an empty
# `SMARTOLT_DEPLOY_PROFILE=` in the freshly-bootstrapped .env
# clobbers the operator's shell export. We snapshot the shell's
# values for every .env key, source the file, then re-apply the
# shell snapshot on top of the .env values.
if [[ -f .env ]]; then
  # Build a snapshot of operator shell exports for keys defined in
  # .env. We only need to remember keys that the operator actually
  # had set in the shell — the rest are owned by .env.
  declare -A _SHELL_SNAPSHOT=()
  _loader_shell_val=""
  while IFS= read -r line; do
    # Skip comments and blank lines.
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Key is everything up to the first '='.
    key="${line%%=*}"
    # Only accept names that are valid POSIX shell identifiers.
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # Was the operator exporting this in the shell? If so, remember
    # the value. (Indirect lookup: ${!key} would lose values with
    # funny chars, but the value here is just for re-export and
    # sanity.)
    _loader_shell_val="${!key-__unset__}"
    if [[ "$_loader_shell_val" != "__unset__" ]]; then
      _SHELL_SNAPSHOT["$key"]="$_loader_shell_val"
    fi
  done < .env
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  # Restore operator exports on top of .env values.
  for key in "${!_SHELL_SNAPSHOT[@]}"; do
    # Skip names that aren't valid shell identifiers (shouldn't
    # happen given the parse above, but defensive).
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    printf -v escaped '%q' "${_SHELL_SNAPSHOT[$key]}"
    eval "export $key=$escaped"
  done
  unset _SHELL_SNAPSHOT
fi

# Resolve the deploy profile (lan / https-public /
# https-behind-external-proxy / frontend-only) and apply its derived
# vars. Done unconditionally — even on `install` before .env exists, so
# that EXPOSE_FRONTEND_DIRECTLY / FRONTEND_BIND_IP / TRAEFIK_ENABLE are
# always defined before the wizard writes them.
# (The _init_profile call itself lives just below, after the function
# definitions it depends on.)

# ─── shared helpers ──────────────────────────────────────────────────────────
DEFAULT_IMAGE_TAG="${SMARTOLT_IMAGE_TAG:-v0.4.9}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-asoton}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-smartolt_api_automate}"
export COMPOSE_PROJECT_NAME

# ─── deploy profiles ─────────────────────────────────────────────────────────
# A profile is a named bundle of (frontend exposure, Traefik presence,
# HTTPS source) settings. The operator picks one (or the wizard infers
# one) and the script sets the derived vars accordingly.
#
# Available profiles:
#   lan                              — frontend on :8080 LAN, Traefik runs
#                                       but does NOT route (operator uses
#                                       :8080 directly). Self-signed :443.
#   https-public                     — frontend loopback only, Traefik
#                                       routes via HTTPS with a Let's
#                                       Encrypt cert. The "production
#                                       with a public domain" default.
#   https-behind-external-proxy      — frontend loopback, NO Traefik
#                                       container. Operator runs Caddy /
#                                       Cloudflare Tunnel / nginx outside
#                                       the stack and points it at
#                                       http://127.0.0.1:8080.
#   frontend-only                    — frontend on :8080 LAN, NO Traefik.
#                                       HTTP only, no HTTPS. Lowest
#                                       resource footprint.
#
# Resolution order (highest priority first):
#   1. SMARTOLT_DEPLOY_PROFILE env var (explicit override)
#   2. .env file's SMARTOLT_DEPLOY_PROFILE (persistent choice)
#   3. Inferred from SMARTOLT_PUBLIC_DOMAIN:
#        set   → https-public
#        empty → lan
#   4. Default: lan
_profile_normalize() {
  case "${1,,}" in
    lan) echo "lan" ;;
    https-public|https_public|public|https) echo "https-public" ;;
    https-behind-external-proxy|behind-external-proxy|external-proxy|behind) echo "https-behind-external-proxy" ;;
    frontend-only|frontend_only|direct) echo "frontend-only" ;;
    *) return 1 ;;
  esac
}

# Returns the active profile name (echoes it; non-zero on unknown).
_resolve_profile() {
  local raw="${SMARTOLT_DEPLOY_PROFILE:-}"
  if [[ -n "$raw" ]]; then
    _profile_normalize "$raw"
    return $?
  fi
  # No explicit profile — infer from PUBLIC_DOMAIN.
  if [[ -n "${SMARTOLT_PUBLIC_DOMAIN:-}" ]]; then
    echo "https-public"
    return 0
  fi
  echo "lan"
  return 0
}

# Apply a profile's settings to the runtime env. Echoes the human-
# readable summary. Unknown profile is a fatal error.
_apply_profile() {
  local profile="$1"
  case "$profile" in
    lan)
      EXPOSE_FRONTEND_DIRECTLY="true"
      FRONTEND_BIND_IP="0.0.0.0"
      TRAEFIK_ENABLE="false"   # Traefik runs but doesn't route
      ;;
    https-public)
      EXPOSE_FRONTEND_DIRECTLY="false"
      FRONTEND_BIND_IP="127.0.0.1"
      TRAEFIK_ENABLE="true"
      ;;
    https-behind-external-proxy)
      EXPOSE_FRONTEND_DIRECTLY="false"
      FRONTEND_BIND_IP="127.0.0.1"
      TRAEFIK_ENABLE="false"   # ignored — Traefik service not started
      ;;
    frontend-only)
      EXPOSE_FRONTEND_DIRECTLY="true"
      FRONTEND_BIND_IP="0.0.0.0"
      TRAEFIK_ENABLE="false"
      ;;
    *)
      die "Unknown deploy profile: $profile"
      ;;
  esac
  export EXPOSE_FRONTEND_DIRECTLY FRONTEND_BIND_IP TRAEFIK_ENABLE
  printf '%s' "$profile"
}

# Resolve the active profile (considering .env + env vars + inference)
# and apply it. Sets EXPOSE_FRONTEND_DIRECTLY, FRONTEND_BIND_IP,
# TRAEFIK_ENABLE, and echoes the profile name.
_init_profile() {
  # Strip \r that Windows-edited .env files may carry.
  local raw="${SMARTOLT_DEPLOY_PROFILE%$'\r'}"
  SMARTOLT_DEPLOY_PROFILE="$raw"
  local resolved
  if ! resolved="$(_resolve_profile 2>/dev/null)"; then
    die "Invalid SMARTOLT_DEPLOY_PROFILE='$SMARTOLT_DEPLOY_PROFILE'. Valid: lan, https-public, https-behind-external-proxy, frontend-only"
  fi
  _apply_profile "$resolved" >/dev/null
  REPLY_PROFILE="$resolved"
  export REPLY_PROFILE
}

# Whether the active profile needs the Traefik service to start.
# Returns 0 if yes, 1 if no (caller can use this in shell conditionals).
_profile_needs_traefik() {
  case "${REPLY_PROFILE:-lan}" in
    lan|https-public) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve + apply the active profile now that all helpers exist.
_init_profile

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
keys = ["SMARTOLT_DEPLOY_PROFILE", "SMARTOLT_BASE_URL", "SMARTOLT_API_KEY",
        "SCHEDULER_TIMEZONE", "SCHEDULER_HOUR_START", "SCHEDULER_HOUR_END",
        "INITIAL_ADMIN_USERNAME", "INITIAL_ADMIN_PASSWORD",
        "SMARTOLT_IMAGE", "SMARTOLT_FRONTEND_IMAGE", "PROXY_IMAGE",
        "SMARTOLT_PUBLIC_DOMAIN", "SMARTOLT_LETSENCRYPT_EMAIL"]
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

# ─── shared: guard before any deploy-side subcommand ──────────────────────────
# Subcommands that touch docker compose (`deploy`, `logs`, `renew`,
# `upgrade`) must refuse to run if there's no usable .env — either the
# file is missing entirely, or it's a 0-byte stub left behind by a
# failed install. Without this guard, `deploy` happily starts pulling
# images and creating containers from defaults baked into
# docker-compose.yml, then dies with a cryptic compose error.
#
# Returns 0 when .env exists as a file (and is non-empty). Deeper
# content validation is done by _validate_profile_env(), which knows
# the active profile's required-var list and produces a single error
# listing every missing var plus a copy-paste example.
_require_env() {
  [[ -f .env ]] || return 1
  # Treat 0-byte files as missing — the wizard may have crashed before
  # writing anything. Comments-only files are accepted at this layer
  # (deeper validation will report the missing keys).
  [[ -s .env ]] || return 1
  return 0
}

# ─── shared: per-profile .env validation ─────────────────────────────────────
# The four profiles need different .env vars. This function reads the
# active profile (via _init_profile / REPLY_PROFILE) and checks every
# required var has a non-empty value. On failure, it prints the list
# of missing vars with their description, type, and a copy-paste-ready
# example line for .env, then exits 1.
#
# Validation rules per profile:
#   common         every profile needs these
#     SMARTOLT_IMAGE, SMARTOLT_FRONTEND_IMAGE
#     INITIAL_ADMIN_USERNAME, INITIAL_ADMIN_PASSWORD (not 'change-me-now')
#   lan            (no extras)
#   https-public
#     SMARTOLT_PUBLIC_DOMAIN    non-empty, no spaces, at least one dot
#     SMARTOLT_LETSENCRYPT_EMAIL  contains '@' and a dot in the domain part
#   https-behind-external-proxy
#     (no extras; the external proxy is the operator's responsibility)
#   frontend-only
#     (no extras)
#
# PROXY_IMAGE is required when the profile needs Traefik (lan,
# https-public). The wizard always writes it; we check it too so a
# manual edit that wipes it is caught.
#
# Run this AFTER _init_profile and AFTER .env has been sourced.

# Catalogue of vars: "KEY|DESCRIPTION|TYPE|EXAMPLE". Printed on missing.
# TYPE is a one-word hint shown in the error: 'FQDN', 'email', 'image',
# 'integer hour', 'IANA tz', 'username', 'password'. Operators see the
# type so they know what shape the value should take.
_PROFILE_REQUIRED_VARS=(
  # Common — required for every profile.
  "SMARTOLT_IMAGE|Backend + web-tier image (Docker Hub: asoton/smartolt-automate:<tag>)|image|asoton/smartolt-automate:v0.4.9"
  "SMARTOLT_FRONTEND_IMAGE|Frontend image (Docker Hub: asoton/smartolt-automate-frontend:<tag>)|image|asoton/smartolt-automate-frontend:v0.4.9"
  "INITIAL_ADMIN_USERNAME|Admin login created on first boot. After that, manage users from the panel.|username|admin"
  "INITIAL_ADMIN_PASSWORD|Admin password for first boot. Must be >= 8 characters; the literal 'change-me-now' is a sentinel that auto-generates a random password and prints it.|password|MyStrongPass!2026"
)

# Reads a single key from .env (returns empty string if missing/blank).
_env_value() {
  local key="$1"
  [[ -f .env ]] || return 0
  local v
  v="$(grep -E "^${key}=" .env | head -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/')"
  printf '%s' "$v"
}

# Print the missing-var block and exit 1.
_fail_missing_vars() {
  local profile="$1"; shift
  local -a missing=("$@")
  err "Profile '$profile' requires the following vars in .env that are missing or empty:"
  printf '\n'
  local entry key desc type example
  for entry in "${missing[@]}"; do
    IFS='|' read -r key desc type example <<<"$entry"
    printf '    %s\n' "$key  ($type)"
    printf '      what:  %s\n' "$desc"
    printf '      e.g.:  %s=%s\n\n' "$key" "$example"
  done
  printf '    Edit .env and set the values, then re-run:\n'
  printf '      ./smartolt.sh deploy\n\n'
  exit 1
}

_validate_profile_env() {
  local profile="${REPLY_PROFILE:-}"
  [[ -n "$profile" ]] || profile="lan"

  # 1. Common checks (every profile).
  local -a missing=()
  local entry key desc type example val
  for entry in "${_PROFILE_REQUIRED_VARS[@]}"; do
    IFS='|' read -r key desc type example <<<"$entry"
    val="$(_env_value "$key")"
    if [[ -z "$val" ]]; then
      missing+=("$entry")
      continue
    fi
    # Special case: the literal 'change-me-now' sentinel for the
    # password is NOT a valid runtime value; the wizard never writes
    # it (install regenerates or prompts). On deploy we want a real pw.
    if [[ "$key" == "INITIAL_ADMIN_PASSWORD" && "$val" == "change-me-now" ]]; then
      missing+=("$entry")
      continue
    fi
    # Type-specific light validation (so we catch obvious typos).
    case "$type" in
      password)
        if (( ${#val} < 8 )); then
          missing+=("$entry")
        fi
        ;;
      FQDN)
        # No spaces, at least one dot.
        if [[ "$val" =~ [[:space:]] ]] || [[ "$val" != *.* ]]; then
          missing+=("$entry")
        fi
        ;;
      email)
        if [[ "$val" != *@*.* ]]; then
          missing+=("$entry")
        fi
        ;;
      image)
        if [[ "$val" != *:* ]]; then
          missing+=("$entry")
        fi
        ;;
    esac
  done

  # 2. Profile-specific checks.
  case "$profile" in
    https-public)
      for entry in \
        "SMARTOLT_PUBLIC_DOMAIN|Public hostname the panel is served from. The DNS A record MUST point at this host before ACME HTTP-01 works.|FQDN|panel.example.com" \
        "SMARTOLT_LETSENCRYPT_EMAIL|Email registered with Let's Encrypt for cert expiry notifications.|email|ops@example.com" ; do
        IFS='|' read -r key desc type example <<<"$entry"
        val="$(_env_value "$key")"
        if [[ -z "$val" ]]; then
          missing+=("$entry"); continue
        fi
        case "$type" in
          FQDN)
            if [[ "$val" =~ [[:space:]] ]] || [[ "$val" != *.* ]]; then
              missing+=("$entry"); continue
            fi
            ;;
          email)
            if [[ "$val" != *@*.* ]]; then
              missing+=("$entry"); continue
            fi
            ;;
        esac
      done
      ;;
    lan|https-public)
      # These profiles include Traefik in the stack, so PROXY_IMAGE
      # must be set. (frontend-only and https-behind-external-proxy
      # don't start the Traefik container so the image isn't required.)
      entry="PROXY_IMAGE|Traefik reverse proxy + ACME image (Docker Hub: asoton/smartolt-automate-traefik:<tag>)|image|asoton/smartolt-automate-traefik:v0.4.9"
      IFS='|' read -r key desc type example <<<"$entry"
      val="$(_env_value "$key")"
      if [[ -z "$val" ]] || [[ "$val" != *:* ]]; then
        missing+=("$entry")
      fi
      ;;
  esac

  if (( ${#missing[@]} > 0 )); then
    _fail_missing_vars "$profile" "${missing[@]}"
  fi
  return 0
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

  # If the compose stack is already up from a previous run, tear it
  # down so the wizard's `up` doesn't fail with a container-name
  # conflict. This handles stale installs (half-finished wizard,
  # aborted pull, recovered crash) where the operator reruns
  # ./smartolt.sh install on a host that still has containers from
  # the previous attempt. Skip if no .env exists yet (first-time
  # install on a clean host).
  if [[ -f .env ]]; then
    if docker ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -qx "smartolt-automate"; then
      warn "Existing smartolt-automate container found; running 'docker compose down' before reinstall."
      docker compose --project-name "$COMPOSE_PROJECT_NAME" down --remove-orphans 2>&1 | tail -3 || true
    fi
  fi

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

  step "2.5/7  Deploy profile"
  # Re-resolve now that .env has been bootstrapped. If the operator set
  # SMARTOLT_PUBLIC_DOMAIN via the env after the early _init_profile call
  # we still want to honor it for the inference rule.
  PROFILE_RAW="${SMARTOLT_DEPLOY_PROFILE:-}"
  [[ -z "$PROFILE_RAW" && -n "${SMARTOLT_PUBLIC_DOMAIN:-}" ]] && PROFILE_RAW="https-public"
  if [[ -n "$PROFILE_RAW" ]]; then
    if ! PROFILE="$(_profile_normalize "$PROFILE_RAW")"; then
      die "Invalid SMARTOLT_DEPLOY_PROFILE='$PROFILE_RAW'. Valid: lan, https-public, https-behind-external-proxy, frontend-only"
    fi
    ok "Profile: $PROFILE (from SMARTOLT_DEPLOY_PROFILE env / .env)."
  elif [[ $NONINTERACTIVE -eq 1 ]]; then
    PROFILE="lan"
    ok "Profile: lan (auto-selected; pass SMARTOLT_DEPLOY_PROFILE=... to override)."
  else
    PROFILE=""
    while :; do
      printf "\n    Pick a deploy profile:\n"
      printf "      [1] lan                              — frontend on :8080 LAN, Traefik runs but doesn't route (self-signed :443)\n"
      printf "      [2] https-public                     — frontend loopback, Traefik issues a LE cert for SMARTOLT_PUBLIC_DOMAIN\n"
      printf "      [3] https-behind-external-proxy      — frontend loopback, NO Traefik; you run Caddy/Cloudflare Tunnel/nginx outside the stack\n"
      printf "      [4] frontend-only                    — frontend on :8080 LAN, NO Traefik, no HTTPS\n"
      printf "    Profile [1]: "
      read -r ans
      case "${ans:-1}" in
        2|https-public) PROFILE="https-public" ;;
        3|https-behind-external-proxy|external) PROFILE="https-behind-external-proxy" ;;
        4|frontend-only|direct) PROFILE="frontend-only" ;;
        1|lan|"") PROFILE="lan" ;;
        *) warn "Invalid selection: '$ans'. Try again."; PROFILE=""; continue ;;
      esac
      # Confirmation loop: if the operator types anything other than 'y'
      # (or empty for default) we redisplay the menu and ask again. This
      # avoids silent typos like 'https-pubic' or wrong-arrow hits.
      printf "    Confirm '%s'? [Y/n/retry]: " "$PROFILE"
      read -r confirm_ans
      case "${confirm_ans:-Y}" in
        Y|y|yes|"") break ;;
        n|N|no)    PROFILE=""; continue ;;
        r|R|retry|back) PROFILE=""; continue ;;
        *)         warn "Invalid answer: '$confirm_ans'. Re-showing menu."; PROFILE=""; continue ;;
      esac
    done
  fi
  SMARTOLT_DEPLOY_PROFILE="$PROFILE"
  export SMARTOLT_DEPLOY_PROFILE
  ok "Profile: $PROFILE"
  # Apply profile to derive EXPOSE_FRONTEND_DIRECTLY / FRONTEND_BIND_IP /
  # TRAEFIK_ENABLE. The wizard may further nudge these for the wizard
  # step 6 (HTTPS) below.
  _apply_profile "$PROFILE" >/dev/null

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
  # Read the TZ from the env var the operator's .env actually
  # exposes (SCHEDULER_TIMEZONE). The previous name was
  # SMARTOLT_TIMEZONE, which the .env.example no longer ships —
  # reading the right name avoids the wizard silently defaulting
  # to America/Bogota on a stack whose .env has Costa Rica.
  TZ_NAME="${SCHEDULER_TIMEZONE:-}"
  if [[ -z "$TZ_NAME" ]]; then
    if [[ $NONINTERACTIVE -eq 1 ]]; then
      TZ_NAME="America/Costa_Rica"
    else
      read -r -p "    IANA timezone [America/Costa_Rica]: " TZ_NAME
      TZ_NAME="${TZ_NAME:-America/Costa_Rica}"
    fi
  fi
  SCHED_HOUR_START="${SCHEDULER_HOUR_START:-}"
  [[ -z "$SCHED_HOUR_START" ]] && { if [[ $NONINTERACTIVE -eq 1 ]]; then SCHED_HOUR_START="2"; else
    read -r -p "    Window START hour [2]: " SCHED_HOUR_START; SCHED_HOUR_START="${SCHED_HOUR_START:-2}"; fi
  }
  SCHED_HOUR_END="${SCHEDULER_HOUR_END:-}"
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
  PUBLIC_DOMAIN=""; ADMIN_EMAIL=""
  case "$PROFILE" in
    https-public)
      # Profile forces HTTPS via Let's Encrypt. Domain is mandatory.
      ENABLE_SSL="y"
      PUBLIC_DOMAIN="${SMARTOLT_PUBLIC_DOMAIN:-}"
      [[ -z "$PUBLIC_DOMAIN" && $NONINTERACTIVE -eq 1 ]] && die "SMARTOLT_PUBLIC_DOMAIN is required for the https-public profile."
      if [[ -z "$PUBLIC_DOMAIN" && $NONINTERACTIVE -ne 1 ]]; then
        read -r -p "    Public domain (e.g. panel.example.com): " PUBLIC_DOMAIN
      fi
      [[ -z "$PUBLIC_DOMAIN" ]] && die "SMARTOLT_PUBLIC_DOMAIN is required for the https-public profile."
      PUBLIC_DOMAIN="${PUBLIC_DOMAIN#\*.}"
      ADMIN_EMAIL="${SMARTOLT_LETSENCRYPT_EMAIL:-admin@${PUBLIC_DOMAIN#*.}}"
      ok "HTTPS will be enabled for $PUBLIC_DOMAIN."
      ;;
    https-behind-external-proxy|frontend-only)
      # HTTPS, if any, is handled by something outside the stack.
      ENABLE_SSL="n"
      ok "HTTPS: handled externally (no Traefik in this profile)."
      ;;
    lan|*)
      # Original behavior: optional HTTPS via Traefik ACME.
      if [[ -n "${SMARTOLT_PUBLIC_DOMAIN:-}" ]]; then
        ENABLE_SSL="y"
      elif [[ $NONINTERACTIVE -eq 1 ]]; then
        ok "Public access: deferred."
      else
        read -r -p "    Enable HTTPS? [y/N]: " ans; ans="${ans:-N}"
        [[ "$ans" =~ ^[Yy]$ ]] && ENABLE_SSL="y"
      fi
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
      ;;
  esac

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

  # Resolve the proxy image. Order of precedence:
  #   1. Operator's shell export (PROXY_IMAGE=:hotfix — survives the
  #      .env source that happens at the top of the script because
  #      the snapshot-restore in the loader pins shell values above
  #      .env values).
  #   2. Value already in .env from a prior install.
  #   3. The default tag (${IMAGE_TAG}).
  _resolve_image() {
    local key="$1" default="$2"
    local v=""
    # 1. Shell value (already restored on top of the .env source by
    #    the snapshot-restore loader at the top of the script).
    if [[ -n "${!key+x}" && -n "${!key}" ]]; then
      v="${!key}"
    fi
    # 2. .env value, only if shell didn't have one.
    if [[ -z "$v" ]]; then
      v="$(grep -E "^${key}=" .env | head -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/')"
    fi
    # An empty value, the literal placeholder, or one that still
    # references the default IMAGE_TAG is treated as "use default".
    if [[ -z "$v" ]] || [[ "$v" == *"v0.3.3"* ]]; then
      printf '%s' "$default"
    else
      printf '%s' "$v"
    fi
  }
  local PROXY_IMAGE_RESOLVED
  PROXY_IMAGE_RESOLVED="$(_resolve_image PROXY_IMAGE "${DOCKERHUB_NAMESPACE}/smartolt-automate-traefik:${IMAGE_TAG}")"
  local BACKEND_IMAGE_RESOLVED
  BACKEND_IMAGE_RESOLVED="$(_resolve_image SMARTOLT_IMAGE "${DOCKERHUB_NAMESPACE}/smartolt-automate:${IMAGE_TAG}")"
  local FRONTEND_IMAGE_RESOLVED
  FRONTEND_IMAGE_RESOLVED="$(_resolve_image SMARTOLT_FRONTEND_IMAGE "${DOCKERHUB_NAMESPACE}/smartolt-automate-frontend:${IMAGE_TAG}")"

  _write_env_file "$PROFILE" \
    "$OLT_BASE_URL" "$OLT_API_KEY" \
    "$TZ_NAME" "$SCHED_HOUR_START" "$SCHED_HOUR_END" \
    "$ADMIN_USER" "$ADMIN_PASSWORD" \
    "$BACKEND_IMAGE_RESOLVED" \
    "$FRONTEND_IMAGE_RESOLVED" \
    "$PROXY_IMAGE_RESOLVED" \
    "$PUBLIC_DOMAIN" "$ADMIN_EMAIL"
  ok "Wrote wizard values to .env (image pins preserved if previously set)"

  # TRAEFIK_ENABLE and the frontend bind are already derived from the
  # profile selected in step 2.5. We just persist them to .env so a
  # later `./smartolt.sh deploy` (which re-loads .env on startup) keeps
  # the same routing behaviour without re-running the wizard.
  sed -i.bak -E "s|^SMARTOLT_DEPLOY_PROFILE=.*|SMARTOLT_DEPLOY_PROFILE=${SMARTOLT_DEPLOY_PROFILE}|" .env
  sed -i.bak -E "s|^TRAEFIK_ENABLE=.*|TRAEFIK_ENABLE=${TRAEFIK_ENABLE}|" .env
  sed -i.bak -E "s|^EXPOSE_FRONTEND_DIRECTLY=.*|EXPOSE_FRONTEND_DIRECTLY=${EXPOSE_FRONTEND_DIRECTLY}|" .env
  sed -i.bak -E "s|^FRONTEND_BIND_IP=.*|FRONTEND_BIND_IP=${FRONTEND_BIND_IP}|" .env
  rm -f .env.bak
  ok "Frontend host bind: $FRONTEND_BIND_IP (EXPOSE_FRONTEND_DIRECTLY=$EXPOSE_FRONTEND_DIRECTLY, TRAEFIK_ENABLE=$TRAEFIK_ENABLE)"

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
  _init_profile
  _validate_profile_env
  local COMPOSE_PROFILES_ARGS=()
  if _profile_needs_traefik; then
    COMPOSE_PROFILES_ARGS=(--profile traefik)
    ok "Profile '$PROFILE' includes the Traefik service."
  else
    ok "Profile '$PROFILE' skips Traefik — the container will not start."
  fi
  docker compose --project-name "$COMPOSE_PROJECT_NAME" "${COMPOSE_PROFILES_ARGS[@]}" pull 2>&1 | tail -5
  docker compose --project-name "$COMPOSE_PROJECT_NAME" "${COMPOSE_PROFILES_ARGS[@]}" up -d 2>&1 | tail -8

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
  _require_env || die "Run './smartolt.sh install' first to generate .env."
  _init_profile
  _validate_profile_env
  local COMPOSE_PROFILES_ARGS=()
  if _profile_needs_traefik; then
    COMPOSE_PROFILES_ARGS=(--profile traefik)
    ok "Profile '$REPLY_PROFILE' includes the Traefik service."
  else
    ok "Profile '$REPLY_PROFILE' skips Traefik — the container will not start."
  fi
  # Compose with `profiles:` does NOT remove containers that were
  # started under a different profile — they become orphans. If a
  # Traefik container exists from a previous profile and the new
  # profile doesn't need it, the orphan will keep holding ports 80/443
  # and silently contradict the operator's intent. Detect and down
  # before up to keep the deploy idempotent across profile changes.
  if [[ -n "$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x smartolt-automate-traefik)" ]] \
     && ! _profile_needs_traefik; then
    warn "Traefik container exists from a previous profile; removing it before up."
    docker compose --project-name "$COMPOSE_PROJECT_NAME" --profile traefik down --remove-orphans 2>&1 | tail -3
  fi
  docker compose --project-name "$COMPOSE_PROJECT_NAME" "${COMPOSE_PROFILES_ARGS[@]}" up -d "$@"
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
  _require_env || die "No usable .env here. Run './smartolt.sh install' first."
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
  _require_env || die "No usable .env here. Run './smartolt.sh install' first."
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
  _require_env || die "No usable .env here. Run './smartolt.sh install' first."
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

# ─── usage ────────────────────────────────────────────────────────────────────
# Printed when the operator runs the script with no subcommand (mandatory)
# or with --help/-h/help. Same content either way; the exit code differs:
#   - missing subcommand → exit 2 (suggests incorrect usage, like getopt)
#   - explicit --help     → exit 0 (operator asked for it)
_print_usage() {
  cat <<'USAGE'
Usage: ./smartolt.sh <command> [flags]

Commands:
  install      First-time deploy: bootstrap .env, pull images, start the stack.
  deploy       Re-apply 'docker compose up -d' using the current .env / profile.
  status       Show container status + which profile is active.
  logs [svc]   Tail logs of one or all services (-f follow).
  renew        Force a cert-renew check now (debug).
  upgrade [v]  Pull new images at the version in .env (or an explicit tag).
  destroy      Nuke everything the installer created (containers, volumes,
               network, .env). Use --keep-data to preserve the database.

Common flags:
  -y, --yes         Skip confirmation prompts.
      --dry-run     Print the plan, change nothing.
      --non-interactive  Don't prompt; use env vars + defaults.
      --keep-images / --keep-data   (destroy only)

Run './smartolt.sh <command> --help' for command-specific options.

Examples:
  ./smartolt.sh install --yes
  SMARTOLT_PUBLIC_DOMAIN=panel.example.com ./smartolt.sh install --yes
  ./smartolt.sh status
  ./smartolt.sh logs smartolt-automate-web --no-follow
  ./smartolt.sh deploy
  ./smartolt.sh upgrade v0.5.0
  ./smartolt.sh destroy -y --keep-data
USAGE
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
  help|--help|-h)
    _print_usage; exit 0 ;;
  "")
    err "Missing subcommand."
    _print_usage
    exit 2 ;;
  *)
    err "Unknown subcommand: $CMD"
    _print_usage
    exit 1 ;;
esac
