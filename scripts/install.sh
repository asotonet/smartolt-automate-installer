#!/usr/bin/env bash
# SmartOLT Automate installer — interactive and non-interactive wizard.
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
# Non-interactive / automated usage:
#   ./scripts/install.sh --yes                                # use defaults for everything
#   SMARTOLT_ADMIN_USERNAME=ops \
#   SMARTOLT_ADMIN_PASSWORD=secret \
#   SMARTOLT_BASE_URL=https://tenant.smartolt.com \
#   SMARTOLT_API_KEY=... \
#   SMARTOLT_PUBLIC_DOMAIN=panel.example.com \
#   ./scripts/install.sh --yes                                # fully unattended
#
#   SMARTOLT_INSTALL_SKIP_DEPLOY=1 ./scripts/install.sh --yes   # write files only, don't deploy
#   SMARTOLT_INSTALL_DRY_RUN=1     ./scripts/install.sh --yes   # print plan, touch nothing
#
# Environment variables (all optional; sensible defaults are used):
#   SMARTOLT_INSTALL_NONINTERACTIVE=1   same as --yes
#   SMARTOLT_ADMIN_USERNAME             default: admin
#   SMARTOLT_ADMIN_PASSWORD             default: random 20 chars (printed at end)
#   SMARTOLT_BASE_URL                   SmartOLT tenant URL (deferred to panel if empty)
#   SMARTOLT_API_KEY                    SmartOLT API key
#   SMARTOLT_TIMEZONE                   IANA tz, default: America/Bogota
#   SMARTOLT_HOUR_START                 0-23, default: 2
#   SMARTOLT_HOUR_END                   0-23, default: 3
#   SMARTOLT_PUBLIC_DOMAIN              enables HTTPS if set
#   SMARTOLT_LETSENCRYPT_EMAIL          default: admin@<public_domain>
#   SMARTOLT_OVERWRITE_ENV=Y|N          default: N (preserve existing .env)
#   SMARTOLT_KEEP_DB=Y|N                default: Y (preserve existing data/)
#   SMARTOLT_INSTALL_SKIP_DEPLOY=1      write files but don't deploy
#   SMARTOLT_INSTALL_DRY_RUN=1          print plan only
#   SMARTOLT_IMAGE_TAG                  default: v0.3.0
#   DOCKERHUB_NAMESPACE                 default: asoton
#
# Re-runnable: existing .env and data/ are preserved unless explicitly overwritten.

# Fail fast on real errors. -u is intentionally NOT set because too many things
# in this script depend on unset variable semantics (e.g. when ask fails the
# caller might still reference the variable; we'd rather emit a friendly
# message than an obscure "unbound variable" error). -o pipefail keeps us
# honest about failing commands in pipelines.
set -eo pipefail

# ─── constants ────────────────────────────────────────────────────────────────
readonly REPO_OWNER_DEFAULT="asotonet"
readonly REPO_NAME_DEFAULT="smartolt-automate-installer"
readonly REPO_REF_DEFAULT="main"
readonly DEFAULT_IMAGE_TAG_DEFAULT="v0.3.0"
readonly DOCKERHUB_NAMESPACE_DEFAULT="asoton"
readonly COMPOSE_PROJECT_NAME_DEFAULT="smartolt_api_automate"

# Files we need from the repo to do anything useful. Listed once so the
# bootstrap can fetch them and the rest of the script can refer to them.
readonly REQUIRED_FILES=(
  .env.example
  docker-compose.yml
  configs/olts.example.yaml
  scripts/stack.sh
  scripts/upgrade.sh
)
# Certbot DNS-01 hooks (manual provider). The certbot container reads them
# from /scripts via the volume mount in docker-compose.yml. Glob-expanded
# by the copy loop below.
readonly REQUIRED_GLOBS=(
  "scripts/ssl/*.sh"
)

# ─── output ──────────────────────────────────────────────────────────────────
# Use ANSI escapes only when stdout is a TTY. Note: -t 1 because some
# invocations (curl | bash) keep stdout as a pipe even when stdin is a TTY.
if [[ -t 1 ]]; then
  readonly C_BOLD=$'\033[1m'
  readonly C_GREEN=$'\033[32m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_RED=$'\033[31m'
  readonly C_BLUE=$'\033[36m'
  readonly C_NC=$'\033[0m'
else
  readonly C_BOLD=""
  readonly C_GREEN=""
  readonly C_YELLOW=""
  readonly C_RED=""
  readonly C_BLUE=""
  readonly C_NC=""
fi

step() { printf "\n%s==>%s %s%s%s\n" "$C_BLUE" "$C_NC" "$C_BOLD" "$*" "$C_NC"; }
ok()   { printf "    %s✓%s %s\n" "$C_GREEN" "$C_NC" "$*"; }
warn() { printf "    %s!%s %s\n" "$C_YELLOW" "$C_NC" "$*"; }
err()  { printf "    %s✗%s %s\n" "$C_RED" "$C_NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ─── detect invocation mode ──────────────────────────────────────────────────
#
# Three invocation modes:
#   1. 'curl ... | bash'  — no local files. We git-clone the installer
#      repo into $HOME/.smartolt-automate-installer (or git pull if
#      it already exists). The clone is used to fetch the source of
#      truth for the wizard; the stack (docker-compose.yml, .env,
#      configs/, data/, logs/) is created in the cwd where the user
#      invoked curl, so they keep ownership of the deployment.
#   2. './scripts/install.sh' from a clone (e.g. /opt/smartolt-automate)
#      — use the local directory as-is for both the installer and
#      the stack. This is the "production" mode after a one-time
#      clone.
#   3. 'bash <(curl ...)' or similar — same as #1.
#
# The detection must work even when set -u would be active (we don't use
# it, but defensive code is cheap).
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
[[ -z "$SCRIPT_PATH" || "$SCRIPT_PATH" == "bash" || ! -f "$SCRIPT_PATH" ]] \
  && INVOCATION="piped" || INVOCATION="local"

# In piped mode we clone into this persistent dir, not a tempdir, so
# subsequent runs (and 'git pull' for updates) work without re-cloning.
INSTALLER_HOME_DEFAULT="${HOME}/.smartolt-automate-installer"
INSTALLER_HOME="${SMARTOLT_INSTALLER_HOME:-$INSTALLER_HOME_DEFAULT}"

# In piped mode the stack is set up in the cwd the user invoked us from,
# not inside the installer clone. Remember that path so we can come back
# to it after the clone.
ORIG_CWD=""

TMPDIR_INSTALL=""
cleanup() {
  local rc=$?
  if [[ -n "$TMPDIR_INSTALL" && -d "$TMPDIR_INSTALL" ]]; then
    rm -rf "$TMPDIR_INSTALL"
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

# ─── bootstrap: get into a directory with all the repo files ─────────────────
if [[ "$INVOCATION" == "piped" ]]; then
  ORIG_CWD="$(pwd)"
  REPO_OWNER="${SMARTOLT_INSTALLER_REPO_OWNER:-$REPO_OWNER_DEFAULT}"
  REPO_NAME="${SMARTOLT_INSTALLER_REPO_NAME:-$REPO_NAME_DEFAULT}"
  REPO_REF="${SMARTOLT_INSTALLER_REPO_REF:-$REPO_REF_DEFAULT}"
  CLONE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"

  if [[ -d "$INSTALLER_HOME/.git" ]]; then
    step "0/8  Updating existing installer"
    printf "    Location: %s\n" "$INSTALLER_HOME"
    if ! (cd "$INSTALLER_HOME" && git fetch --tags --prune origin >/dev/null 2>&1); then
      die "Failed to fetch updates from $CLONE_URL"
    fi
    # If we're pinned to a specific ref (tag/branch), check it out.
    # Otherwise do a fast-forward pull of whatever local branch is checked out.
    if [[ "$REPO_REF" != "main" && "$REPO_REF" != "master" ]]; then
      if ! (cd "$INSTALLER_HOME" && git checkout "$REPO_REF" >/dev/null 2>&1); then
        die "Failed to check out $REPO_REF in $INSTALLER_HOME"
      fi
      ok "Checked out $REPO_REF"
    else
      if (cd "$INSTALLER_HOME" && git pull --ff-only >/dev/null 2>&1); then
        ok "Pulled latest"
      else
        warn "git pull --ff-only failed; using whatever is checked out"
      fi
    fi
  else
    # If a stale non-git directory exists at that path, refuse to clobber it.
    if [[ -e "$INSTALLER_HOME" ]]; then
      die "Path $INSTALLER_HOME exists but is not a git repo. Remove it, or set SMARTOLT_INSTALLER_HOME elsewhere."
    fi
    step "0/8  Cloning installer"
    printf "    Source:  %s\n" "$CLONE_URL"
    printf "    Target:  %s\n" "$INSTALLER_HOME"
    if ! command -v git >/dev/null 2>&1; then
      die "git is required for 'curl | bash' installation. Install git, or clone the repo manually and run ./scripts/install.sh."
    fi
    if ! git clone --depth 1 "$CLONE_URL" "$INSTALLER_HOME" 2>&1 | tail -3; then
      die "git clone failed. Check that $CLONE_URL is reachable."
    fi
    # If the user pinned a specific ref, check it out. (Doing this in two
    # steps instead of 'git clone --branch' avoids a Git bug where
    # 'clone --branch' fails when the URL has been rewritten via
    # insteadOf to file:// or similar.)
    if [[ "$REPO_REF" != "main" && "$REPO_REF" != "master" ]]; then
      if ! (cd "$INSTALLER_HOME" && git checkout "$REPO_REF" >/dev/null 2>&1); then
        die "Cloned OK but ref $REPO_REF does not exist on the remote."
      fi
      ok "Checked out $REPO_REF"
    fi
    ok "Cloned"
  fi
  export SMARTOLT_INSTALLER_HOME="$INSTALLER_HOME"

  # Copy the wizard's working files (the source of truth for the stack)
  # to the user's cwd. The installer clone stays pristine in $HOME for
  # future 'git pull' updates; the stack lives where the user invoked us.
  step "0/8  Copying stack files to $ORIG_CWD"
  for f in "${REQUIRED_FILES[@]}"; do
    target="$ORIG_CWD/$f"
    if [[ -e "$target" ]]; then
      # Don't clobber existing user state (.env, configs/, etc.).
      : # leave it alone
    else
      mkdir -p "$(dirname "$target")"
      cp -f "$INSTALLER_HOME/$f" "$target"
    fi
  done
  # Glob-expanded files (e.g. certbot DNS-01 hooks). Each match is copied
  # to the same relative path under ORIG_CWD; existing files are left alone.
  for g in "${REQUIRED_GLOBS[@]}"; do
    # shellcheck disable=SC2086
    for src in $INSTALLER_HOME/$g; do
      [[ -f "$src" ]] || continue
      rel="${src#$INSTALLER_HOME/}"
      target="$ORIG_CWD/$rel"
      if [[ -e "$target" ]]; then
        :
      else
        mkdir -p "$(dirname "$target")"
        cp -f "$src" "$target"
        chmod +x "$target"
      fi
    done
  done
  ok "Stack files ready in $ORIG_CWD"

  # Run the rest of the wizard from the user's cwd.
  cd "$ORIG_CWD"
else
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  cd "$SCRIPT_DIR/.."
fi

# After this point we MUST be in a directory that has all REQUIRED_FILES.
for f in "${REQUIRED_FILES[@]}"; do
  [[ -f "$f" ]] || die "Required file missing after bootstrap: $f"
done
# Glob-expanded files must also exist (at least one match per glob).
for g in "${REQUIRED_GLOBS[@]}"; do
  # shellcheck disable=SC2086
  found=0
  for _ in $g; do
    found=$((found + 1))
    break
  done
  if (( found == 0 )); then
    die "Required file missing after bootstrap: $g"
  fi
done

# ─── defaults (can be overridden via env) ────────────────────────────────────
DEFAULT_IMAGE_TAG="${SMARTOLT_IMAGE_TAG:-$DEFAULT_IMAGE_TAG_DEFAULT}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-$DOCKERHUB_NAMESPACE_DEFAULT}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$COMPOSE_PROJECT_NAME_DEFAULT}"
export COMPOSE_PROJECT_NAME

# ─── non-interactive mode ─────────────────────────────────────────────────────
#
# Three ways to opt in (highest priority first):
#   1. CLI flag: --yes, -y, --non-interactive
#   2. Env var:  SMARTOLT_INSTALL_NONINTERACTIVE=1
#   3. Heuristic: stdin is not a TTY and there's no /dev/tty available
#
# In non-interactive mode every prompt is skipped and the wizard falls back
# to defaults (or to overrides from env vars documented in README.md).
# If a question is unanswered and no sensible default exists, the wizard
# dies with a message naming the env var to set.
#
# `SMARTOLT_INSTALL_SKIP_DEPLOY=1` writes files but does NOT call
# `docker compose pull/up` and skips the healthcheck.
# `SMARTOLT_INSTALL_DRY_RUN=1` only prints the plan.
#
# You can also pre-answer every question via env vars:
#   SMARTOLT_ADMIN_USERNAME, SMARTOLT_ADMIN_PASSWORD
#   SMARTOLT_BASE_URL, SMARTOLT_API_KEY
#   SMARTOLT_TIMEZONE, SMARTOLT_HOUR_START, SMARTOLT_HOUR_END
#   SMARTOLT_PUBLIC_DOMAIN, SMARTOLT_LETSENCRYPT_EMAIL
#   SMARTOLT_OVERWRITE_ENV=Y, SMARTOLT_KEEP_DB=N
NONINTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y|--non-interactive) NONINTERACTIVE=1 ;;
  esac
done
[[ -n "${SMARTOLT_INSTALL_NONINTERACTIVE:-}" ]] && NONINTERACTIVE=1
if [[ $NONINTERACTIVE -eq 0 && ! -t 0 && ! -r /dev/tty ]]; then
  # No TTY available at all (CI, systemd unit, piped from curl without -t).
  NONINTERACTIVE=1
fi
export NONINTERACTIVE

SKIP_DEPLOY="${SMARTOLT_INSTALL_SKIP_DEPLOY:-0}"
DRY_RUN="${SMARTOLT_INSTALL_DRY_RUN:-0}"

# ─── input helpers ───────────────────────────────────────────────────────────
#
# We have to read from /dev/tty (not stdin) when invoked as 'curl | bash' because
# stdin is the script body. We probe /dev/tty with a real open() because plain
# [ -r /dev/tty ] returns true in headless subshells where the actual open
# still fails.
have_tty() {
  [[ -t 0 ]] && return 0
  if { exec 3</dev/tty; } 2>/dev/null; then
    exec 3<&-
    return 0
  fi
  return 1
}

# Read one line into the variable named by $1. Honors a default. If $3 is
# "secret", the input is read with -s (no echo). Exits non-zero if the user
# provides an empty value AND no default was given.
#
# In non-interactive mode (NONINTERACTIVE=1) the prompt is skipped, the
# default is taken silently, and the chosen value is logged so the operator
# can audit it after the fact.
#
# Usage: read_input VAR "Prompt" [default] [secret]
read_input() {
  local var_name="$1" prompt="$2" default="${3:-}" mode="${4:-}"
  local displayed="${default:-(required)}" reply=""

  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    if [[ -z "$default" ]]; then
      die "Refusing to run non-interactively: '$prompt' is required and no default is available. Set the corresponding env var before invoking this script."
    fi
    reply="$default"
    printf "    %s: %s (default)\n" "$prompt" "$([[ "$mode" == "secret" ]] && echo "***" || echo "$reply")"
  elif have_tty; then
    if [[ "$mode" == "secret" ]]; then
      read -r -s -p "    $prompt [$displayed]: " reply </dev/tty || true
      printf "\n"
    else
      read -r -p "    $prompt [$displayed]: " reply </dev/tty || true
    fi
  else
    # Fallback: read from stdin (only works if the user piped input in
    # via a heredoc or printf; otherwise we block until EOF, which is
    # the desired behavior for non-interactive runs).
    if [[ "$mode" == "secret" ]]; then
      read -r -s -p "    $prompt [$displayed]: " reply || true
      printf "\n"
    else
      read -r -p "    $prompt [$displayed]: " reply || true
    fi
  fi

  reply="${reply:-$default}"
  if [[ -z "$reply" && -z "$default" ]]; then
    # No default, user pressed Enter with no input: caller gets empty
    # string and decides whether to treat that as a skip or an error.
    printf -v "$var_name" '%s' ""
    return 0
  fi
  if [[ -z "$reply" ]]; then
    err "A value is required."
    return 1
  fi
  printf -v "$var_name" '%s' "$reply"
}

# Yes/no prompt. Sets the named variable to "y" or "n".
# Usage: read_yn VAR "Prompt" [default=Y|N]
read_yn() {
  local var_name="$1" prompt="$2" default="${3:-Y}" reply=""
  local shown
  if [[ "$default" =~ ^[Yy]$ ]]; then shown="Y/n"; else shown="y/N"; fi

  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    if [[ "$default" =~ ^[Yy]$ ]]; then
      printf "    %s: Y (default)\n" "$prompt"
      printf -v "$var_name" 'y'
    else
      printf "    %s: n (default)\n" "$prompt"
      printf -v "$var_name" 'n'
    fi
    return 0
  fi

  if have_tty; then
    read -r -p "    $prompt [$shown]: " reply </dev/tty || true
  else
    read -r -p "    $prompt [$shown]: " reply || true
  fi
  reply="${reply:-$default}"
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    printf -v "$var_name" 'y'
  elif [[ "$reply" =~ ^[Nn]$ ]]; then
    printf -v "$var_name" 'n'
  else
    err "Please answer Y or n (got '$reply')."
    return 1
  fi
}

# Read a positive integer in [min, max]. Re-prompts on invalid input.
# Usage: read_int VAR "Prompt" min max [default]
read_int() {
  local var_name="$1" prompt="$2" min="$3" max="$4" default="${5:-}" reply=""
  while :; do
    if ! read_input "$var_name" "$prompt ($min-$max)" "$default"; then
      return 1
    fi
    reply="${!var_name}"
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= min && reply <= max )); then
      return 0
    fi
    err "Enter an integer between $min and $max."
    printf -v "$var_name" ''
  done
}

# Yes/no prompt. Sets the named variable to "y" or "n".
# Usage: read_yn VAR "Prompt" [default=Y|N]
read_yn() {
  local var_name="$1" prompt="$2" default="${3:-Y}" reply=""
  local shown
  if [[ "$default" =~ ^[Yy]$ ]]; then shown="Y/n"; else shown="y/N"; fi

  if have_tty; then
    read -r -p "    $prompt [$shown]: " reply </dev/tty || true
  else
    read -r -p "    $prompt [$shown]: " reply || true
  fi
  reply="${reply:-$default}"
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    printf -v "$var_name" 'y'
  elif [[ "$reply" =~ ^[Nn]$ ]]; then
    printf -v "$var_name" 'n'
  else
    err "Please answer Y or N (got '$reply')."
    return 1
  fi
}

# Read a positive integer in [min, max]. Re-prompts on invalid input.
# Usage: read_int VAR "Prompt" min max [default]
read_int() {
  local var_name="$1" prompt="$2" min="$3" max="$4" default="${5:-}" reply=""
  while :; do
    if ! read_input "$var_name" "$prompt ($min-$max)" "$default"; then
      return 1
    fi
    reply="${!var_name}"
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= min && reply <= max )); then
      return 0
    fi
    err "Enter an integer between $min and $max."
    printf -v "$var_name" ''
  done
}

# ─── utilities ───────────────────────────────────────────────────────────────
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

docker_hub_reachable() {
  local code
  code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "https://registry-1.docker.io/v2/" 2>/dev/null || echo 000)
  [[ "$code" == "200" || "$code" == "401" ]]
}

# Write KEY=VALUE lines into a .env file in-place, preserving everything else
# and quoting values that contain spaces or shell metacharacters. Uses a
# Python one-liner so we don't have to worry about sed/escape issues.
#
# Quoting follows the python-dotenv / docker compose rules:
#   - bare: KEY=value (no spaces, no '#', no '=')
#   - double-quoted: KEY="..." with backslash escapes for " and \
#   - single-quoted: KEY='...' (no escapes, literal)
#
# We always prefer double quotes because they handle the most cases
# (including values that contain single quotes like "O'Brien").
env_set() {
  local file="$1"; shift
  python3 - "$file" "$@" <<'PY'
import sys, pathlib

def quote_value(v: str) -> str:
    # Always quote. This is conservative but eliminates edge cases.
    # Escape backslash and double-quote only.
    out = []
    for ch in v:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'

def needs_quote(v: str) -> bool:
    # Values that need quoting: contain whitespace, '#', '=', '"', "'", etc.
    # Empty strings are written as bare (KEY=), not as KEY="".
    if not v:
        return False
    if any(c in v for c in ' \t"\'#$&`\\'):
        return True
    if v.startswith(("-", "+", ".")):
        # Bare values that look like numbers/flags could be ambiguous.
        return True
    return False

path = pathlib.Path(sys.argv[1])
pairs = []
i = 2
while i < len(sys.argv):
    pairs.append((sys.argv[i], sys.argv[i+1]))
    i += 2

existing = {}
order = []
if path.exists():
    for line in path.read_text().splitlines():
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, _, _ = line.partition("=")
        if key in existing:
            continue
        existing[key] = line
        order.append(key)

out_lines = []
written = set()
for key, line in existing.items():
    if any(k == key for k, _ in pairs):
        continue
    out_lines.append(line)
for k, v in pairs:
    if needs_quote(v):
        out_lines.append(f"{k}={quote_value(v)}")
    else:
        out_lines.append(f"{k}={v}")
    written.add(k)
for k, v in pairs:
    if k not in written:
        if needs_quote(v):
            out_lines.append(f"{k}={quote_value(v)}")
        else:
            out_lines.append(f"{k}={v}")
path.write_text("\n".join(out_lines) + "\n")
PY
}

# ─── 1. prerequisites ─────────────────────────────────────────────────────────
step "1/8  Verifying prerequisites"
require_cmd docker
ok "docker $(docker --version | awk '{print $3}' | tr -d ',')"

if ! docker info >/dev/null 2>&1; then
  die "Docker daemon is not reachable. Is Docker running?"
fi
ok "Docker daemon reachable"

if docker compose version >/dev/null 2>&1; then
  ok "docker compose available"
elif command -v docker-compose >/dev/null 2>&1; then
  warn "Found legacy docker-compose v1. The 'docker compose' plugin is recommended."
else
  die "Neither 'docker compose' (v2) nor 'docker-compose' (v1) found."
fi

if docker_hub_reachable; then
  ok "Docker Hub reachable"
else
  warn "Docker Hub not reachable. 'docker compose pull' will fail until network is fixed."
fi

# ─── 2. current state ─────────────────────────────────────────────────────────
step "2/8  Inspecting current state"

OVERWRITE_ENV="n"
if [[ -n "${SMARTOLT_OVERWRITE_ENV:-}" ]]; then
  OVERWRITE_ENV="${SMARTOLT_OVERWRITE_ENV}"
elif [[ -f ".env" ]]; then
  warn "Existing .env found in this directory."
  if ! read_yn OVERWRITE_ENV "Overwrite .env?" "N"; then
    die "Aborted by user."
  fi
fi

KEEP_DB="Y"
if [[ -n "${SMARTOLT_KEEP_DB:-}" ]]; then
  KEEP_DB="${SMARTOLT_KEEP_DB}"
elif [[ -d "data" && -f "data/app.db" ]]; then
  warn "Existing database found (data/app.db)."
  if ! read_yn KEEP_DB "Keep database (admin users, history)?" "Y"; then
    die "Aborted by user."
  fi
fi

# ─── 3. admin credentials ─────────────────────────────────────────────────────
step "3/8  Admin credentials"
if [[ "$KEEP_DB" == "y" && -f "data/app.db" ]]; then
  warn "Keeping existing database — these credentials apply only on a fresh DB."
fi

# Resolve admin username from env, else prompt (with default "admin").
if [[ -n "${SMARTOLT_ADMIN_USERNAME:-}" ]]; then
  ADMIN_USER="${SMARTOLT_ADMIN_USERNAME}"
  ok "Admin username (from env): $ADMIN_USER"
elif ! read_input ADMIN_USER "Admin username" "admin"; then
  die "Admin username is required."
fi

ADMIN_PASSWORD=""
ADMIN_PASSWORD_GENERATED=""

# In non-interactive mode, prefer a random password (safer than whatever the
# operator might have left in their shell history). If they really want to
# set it explicitly, SMARTOLT_ADMIN_PASSWORD overrides.
if [[ -n "${SMARTOLT_ADMIN_PASSWORD:-}" ]]; then
  if (( ${#SMARTOLT_ADMIN_PASSWORD} < 8 )); then
    die "SMARTOLT_ADMIN_PASSWORD must be at least 8 characters."
  fi
  ADMIN_PASSWORD="${SMARTOLT_ADMIN_PASSWORD}"
  ok "Admin password (from env): ***"
elif [[ $NONINTERACTIVE -eq 1 ]]; then
  ADMIN_PASSWORD_GENERATED="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
  ADMIN_PASSWORD="$ADMIN_PASSWORD_GENERATED"
  ok "Generated a random admin password (set SMARTOLT_ADMIN_PASSWORD to override)."
else
  if read_yn USE_DEFAULT_PW "Generate a random admin password (you'll see it once)?" "N"; then
    ADMIN_PASSWORD_GENERATED="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
    ADMIN_PASSWORD="$ADMIN_PASSWORD_GENERATED"
    ok "Generated a random password."
  else
    while :; do
      if ! read_input ADMIN_PASSWORD "Admin password (min 8 chars, Enter to keep blank)" "" "secret"; then
        err "Admin password is required."
        ADMIN_PASSWORD=""
        continue
      fi
      if [[ -z "$ADMIN_PASSWORD" ]]; then
        warn "Password is blank. The wizard will generate one for you."
        ADMIN_PASSWORD_GENERATED="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
        ADMIN_PASSWORD="$ADMIN_PASSWORD_GENERATED"
        ok "Generated a random password."
        break
      fi
      if (( ${#ADMIN_PASSWORD} >= 8 )); then
        break
      fi
      err "Password too short (min 8 characters)."
      ADMIN_PASSWORD=""
    done
  fi
fi
ok "Admin user: $ADMIN_USER"

# ─── 4. SmartOLT connection (optional, set later from panel) ─────────────────
step "4/8  SmartOLT tenant connection"
warn "SmartOLT URL and API key are optional. The service boots in"
warn "'unconfigured' mode; you can paste them from the panel"
warn "(Settings → SmartOLT connection) after first login."

OLT_BASE_URL="${SMARTOLT_BASE_URL:-}"
OLT_API_KEY="${SMARTOLT_API_KEY:-}"
# If both URL and API key are provided via env, skip the prompt entirely.
if [[ -n "$OLT_BASE_URL" && -n "$OLT_API_KEY" ]]; then
  SET_SMARTOLT_NOW="y"
  ok "SmartOLT (from env): $OLT_BASE_URL"
elif [[ $NONINTERACTIVE -eq 1 ]]; then
  # Non-interactive: skip SmartOLT setup (the operator can configure it
  # from the panel later). This is the safe default.
  SET_SMARTOLT_NOW="n"
  ok "SmartOLT connection: deferred to post-install panel configuration."
elif read_yn SET_SMARTOLT_NOW "Set SmartOLT now (otherwise: from panel later)?" "N"; then
  if ! read_input OLT_BASE_URL "Tenant base URL (Enter to skip)" ""; then
    warn "No URL — leaving blank."
    OLT_BASE_URL=""
  fi
  if [[ -n "$OLT_BASE_URL" ]]; then
    case "$OLT_BASE_URL" in
      https://*.smartolt.com|https://*.smartolt.net) ;;
      https://*)  warn "URL doesn't look like a SmartOLT subdomain (.com/.net) — continuing anyway.";;
      *)          warn "URL must start with https://. Leaving blank."; OLT_BASE_URL="" ;;
    esac
  fi
  if [[ -n "$OLT_BASE_URL" ]]; then
    if ! read_input OLT_API_KEY "SmartOLT API key (Enter to skip)" "" "secret"; then
      warn "No API key — leaving blank."
      OLT_API_KEY=""
    fi
  fi
fi
if [[ -n "$OLT_BASE_URL" && -n "$OLT_API_KEY" ]]; then
  ok "Tenant: $OLT_BASE_URL"
else
  ok "Tenant: (configure later from the panel)"
fi

# ─── 5. scheduler window ───────────────────────────────────────────────────────
step "5/8  Scheduler window"

if [[ -n "${SMARTOLT_TIMEZONE:-}" ]]; then
  TZ_NAME="${SMARTOLT_TIMEZONE}"
  USE_BOGOTA="n"
  ok "Timezone (from env): $TZ_NAME"
elif [[ $NONINTERACTIVE -eq 1 ]]; then
  TZ_NAME="America/Bogota"
  USE_BOGOTA="y"
  ok "Timezone: $TZ_NAME (default)"
elif ! read_yn USE_BOGOTA "Use America/Bogota timezone?" "Y"; then
  die "Aborted by user."
fi
if [[ -z "${TZ_NAME:-}" ]]; then
  if [[ "$USE_BOGOTA" == "y" ]]; then
    TZ_NAME="America/Bogota"
  else
    if ! read_input TZ_NAME "IANA timezone (e.g. America/Mexico_City)" "America/Bogota"; then
      die "Timezone is required."
    fi
  fi
fi

if [[ -n "${SMARTOLT_HOUR_START:-}" ]]; then
  SCHED_HOUR_START="${SMARTOLT_HOUR_START}"
elif ! read_int SCHED_HOUR_START "Window START hour" 0 23 "2"; then
  die "Window start hour is required."
fi
if [[ -n "${SMARTOLT_HOUR_END:-}" ]]; then
  SCHED_HOUR_END="${SMARTOLT_HOUR_END}"
elif ! read_int SCHED_HOUR_END "Window END hour" 0 23 "3"; then
  die "Window end hour is required."
fi
if (( SCHED_HOUR_END <= SCHED_HOUR_START )); then
  die "End hour ($SCHED_HOUR_END) must be greater than start hour ($SCHED_HOUR_START). (No midnight crossing in MVP.)"
fi
ok "Window: $(printf '%02d:00' "$SCHED_HOUR_START") to $(printf '%02d:00' "$SCHED_HOUR_END") ($TZ_NAME)"

# ─── 6. public access (HTTPS) ──────────────────────────────────────────────────
step "6/8  Public access / HTTPS"

# SSL is auto-enabled when SMARTOLT_PUBLIC_DOMAIN is provided. Otherwise,
# non-interactive mode skips it (default), interactive mode asks.
ENABLE_SSL="n"
if [[ -n "${SMARTOLT_PUBLIC_DOMAIN:-}" ]]; then
  ENABLE_SSL="y"
elif [[ $NONINTERACTIVE -eq 1 ]]; then
  ENABLE_SSL="n"
  ok "Public access: deferred to post-install (set SMARTOLT_PUBLIC_DOMAIN to enable)."
elif ! read_yn ENABLE_SSL "Expose the dashboard to the internet with HTTPS?" "N"; then
  die "Aborted by user."
fi

PUBLIC_DOMAIN=""
ADMIN_EMAIL=""
if [[ "$ENABLE_SSL" == "y" ]]; then
  if [[ -n "${SMARTOLT_PUBLIC_DOMAIN:-}" ]]; then
    PUBLIC_DOMAIN="${SMARTOLT_PUBLIC_DOMAIN}"
    ok "Public domain (from env): $PUBLIC_DOMAIN"
  elif ! read_input PUBLIC_DOMAIN "Public domain (e.g. panel.example.com)"; then
    die "Public domain is required to enable HTTPS."
  fi
  # Strip a leading wildcard label if the user typed one.
  PUBLIC_DOMAIN="${PUBLIC_DOMAIN#\*.}"
  if [[ -n "${SMARTOLT_LETSENCRYPT_EMAIL:-}" ]]; then
    ADMIN_EMAIL="${SMARTOLT_LETSENCRYPT_EMAIL}"
    ok "Let's Encrypt email (from env): $ADMIN_EMAIL"
  elif ! read_input ADMIN_EMAIL "Email for Let's Encrypt notifications" "admin@${PUBLIC_DOMAIN#*.}"; then
    die "Email is required to enable HTTPS."
  fi
  ok "HTTPS will be enabled for $PUBLIC_DOMAIN after you issue a cert in the panel."
else
  ok "HTTP only (default proxy ports 80/443)."
fi

# ─── 7. write & deploy ────────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
  step "7/8  Writing configuration (DRY_RUN — no files written)"
  printf "    Plan summary:\n"
  printf "      SMARTOLT_BASE_URL       = '%s'\n" "$OLT_BASE_URL"
  printf "      SMARTOLT_API_KEY         = %s\n" "$([[ -n "$OLT_API_KEY" ]] && echo '***set***' || echo '(unset)')"
  printf "      SCHEDULER_TIMEZONE       = '%s'\n" "$TZ_NAME"
  printf "      SCHEDULER_HOUR_START     = %s\n" "$SCHED_HOUR_START"
  printf "      SCHEDULER_HOUR_END       = %s\n" "$SCHED_HOUR_END"
  printf "      INITIAL_ADMIN_USERNAME   = '%s'\n" "$ADMIN_USER"
  printf "      INITIAL_ADMIN_PASSWORD   = %s\n" "$([[ -n "$ADMIN_PASSWORD_GENERATED" ]] && echo '(generated, will be printed)' || echo '***set***')"
  printf "      PUBLIC_DOMAIN (HTTPS)     = '%s'  EMAIL='%s'\n" "$PUBLIC_DOMAIN" "$ADMIN_EMAIL"
  printf "      DEFAULT_IMAGE_TAG        = '%s'\n" "$DEFAULT_IMAGE_TAG"
else
  step "7/8  Writing configuration"

  if [[ "$OVERWRITE_ENV" == "y" || ! -f ".env" ]]; then
    if [[ -f ".env" ]]; then
      cp -f .env.example .env
      ok "Copied .env.example -> .env"
    else
      cp -f .env.example .env
      ok "Created .env from .env.example"
    fi
  else
    ok "Keeping existing .env"
  fi

  # Always re-write the user-specific values, even if we kept the rest of .env.
  # This means re-running the wizard with new credentials updates them.
  env_set ".env" \
    "SMARTOLT_BASE_URL"        "$OLT_BASE_URL" \
    "SMARTOLT_API_KEY"          "$OLT_API_KEY" \
    "SCHEDULER_TIMEZONE"        "$TZ_NAME" \
    "SCHEDULER_HOUR_START"      "$SCHED_HOUR_START" \
    "SCHEDULER_HOUR_END"        "$SCHED_HOUR_END" \
    "TZ"                        "$TZ_NAME" \
    "INITIAL_ADMIN_USERNAME"    "$ADMIN_USER" \
    "INITIAL_ADMIN_PASSWORD"    "$ADMIN_PASSWORD" \
    "SMARTOLT_IMAGE"            "${DOCKERHUB_NAMESPACE}/smartolt-automate:${DEFAULT_IMAGE_TAG}" \
    "SMARTOLT_FRONTEND_IMAGE"   "${DOCKERHUB_NAMESPACE}/smartolt-automate-frontend:${DEFAULT_IMAGE_TAG}" \
    "PROXY_IMAGE"               "${DOCKERHUB_NAMESPACE}/smartolt-automate-proxy:${DEFAULT_IMAGE_TAG}" \
    "CERTBOT_IMAGE"             "${DOCKERHUB_NAMESPACE}/smartolt-automate-certbot:${DEFAULT_IMAGE_TAG}"
  ok "Wrote wizard values to .env"

  mkdir -p configs
  if [[ ! -f "configs/olts.yaml" ]]; then
    if [[ -f "configs/olts.example.yaml" ]]; then
      cp -f configs/olts.example.yaml configs/olts.yaml
      ok "configs/olts.yaml created from template"
    else
      warn "No configs/olts.example.yaml template shipped; you will need to create configs/olts.yaml before enabling OLTs."
    fi
  fi
fi

step "8/8  Bringing up the stack"

# Track whether the wizard considers the deployment healthy. SKIP_DEPLOY
# and DRY_RUN both short-circuit deploy+healthcheck with up=1.
up=1
if [[ "$DRY_RUN" -eq 1 ]]; then
  ok "DRY_RUN=1 — skipping docker compose pull/up and healthcheck."
elif [[ "$SKIP_DEPLOY" -eq 1 ]]; then
  ok "SKIP_DEPLOY=1 — skipping docker compose pull/up and healthcheck."
  ok "Files are ready. To deploy: cd $(pwd) && docker compose pull && docker compose up -d"
else
  up=0
  if ! docker compose pull; then
    die "docker compose pull failed. Check 'docker compose config' and your network."
  fi
  ok "Images pulled"

  if ! docker compose up -d; then
    die "docker compose up -d failed. Inspect 'docker compose logs' for details."
  fi
  ok "Stack started"
fi

# ─── healthcheck ──────────────────────────────────────────────────────────────
echo ""
HEALTH_URL="http://localhost/api/service/livez"
if [[ "$DRY_RUN" -eq 1 || "$SKIP_DEPLOY" -eq 1 ]]; then
  # Deploy was skipped; $up was already set to 1 above.
  :
else
  step "Verifying healthchecks"
  printf "  Probing %s ...\n" "$HEALTH_URL"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if curl --silent --show-error --fail --output /dev/null \
         --connect-timeout 2 --max-time 4 "$HEALTH_URL"; then
      up=1
      ok "Service reachable at $HEALTH_URL"
      break
    fi
    printf "  ... retry %d/15\n" "$i"
    sleep 3
  done

  docker compose ps
  echo ""
fi

# ─── summary ──────────────────────────────────────────────────────────────────
printf "\n%sDone.%s\n" "$C_BOLD" "$C_NC"
if [[ "$INVOCATION" == "piped" ]]; then
  printf "  Installer:     ${C_BLUE}%s${C_NC}  (cloned; ${C_BOLD}cd${C_NC} here to re-run)\n\n" "$(pwd)"
fi
printf "  Dashboard:      ${C_BLUE}http://localhost/${C_NC}\n"
printf "  API health:     ${C_BLUE}%s${C_NC}\n" "$HEALTH_URL"
if [[ -n "$ADMIN_PASSWORD_GENERATED" ]]; then
  printf "  Admin user:     ${C_BOLD}%s${C_NC}\n" "$ADMIN_USER"
  printf "  Admin password: ${C_BOLD}%s${C_NC}  ${C_YELLOW}(generated — save it now!)${C_NC}\n" "$ADMIN_PASSWORD_GENERATED"
else
  printf "  Admin user:     ${C_BOLD}%s${C_NC}\n" "$ADMIN_USER"
  printf "  Admin password: ${C_BOLD}(the one you set)${C_NC}\n"
fi

printf "\n${C_BOLD}Next steps:${C_NC}\n"
printf "  - Open ${C_BLUE}http://localhost/${C_NC} and log in.\n"
if [[ -n "$OLT_BASE_URL" && -n "$OLT_API_KEY" ]]; then
  printf "  - SmartOLT connection was set during the wizard. The scheduler will\n"
  printf "    pick up your OLTs on the next reload. Add OLTs by editing\n"
  printf "    ${C_BOLD}configs/olts.yaml${C_NC} or via the panel.\n"
else
  printf "  - Go to ${C_BOLD}Configuración → Conexión SmartOLT${C_NC} and paste your\n"
  printf "    tenant URL + API token. Until then the scheduler stays idle but\n"
  printf "    you can browse the panel freely.\n"
fi
if [[ "$ENABLE_SSL" == "y" ]]; then
  printf "  - Go to ${C_BOLD}Configuración → Acceso público${C_NC}, pick your DNS provider,\n"
  printf "    fill in its credentials, and issue the certificate.\n"
fi
printf "  - Add OLTs by editing ${C_BOLD}configs/olts.yaml${C_NC} (or via the panel).\n"

printf "\n${C_BOLD}Re-running:${C_NC}\n"
printf "  cd %s\n" "$(pwd)"
printf "  ./scripts/install.sh            # re-run wizard (preserves data/, asks before overwriting .env)\n"
printf "  ./scripts/stack.sh status       # container status + healthcheck URLs\n"
printf "  ./scripts/stack.sh logs web     # tail logs of a service\n"
printf "  ./scripts/upgrade.sh --check    # check for new versions on Docker Hub\n"
printf "  ./scripts/stack.sh down         # stop the stack (keeps data)\n"
printf "  git pull                        # update the installer itself\n"
printf "\n"

if [[ $up -ne 1 ]]; then
  warn "Healthcheck did not respond within the timeout. Run './scripts/stack.sh logs web' to debug."
  exit 2
fi
exit 0