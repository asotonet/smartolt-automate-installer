#!/usr/bin/env bash
# Detect new versions of SmartOLT Automate and offer to upgrade.
#
# Strategy:
# - Read the currently-installed tag from .env (SMARTOLT_IMAGE, etc.)
# - List all semver tags on Docker Hub (asoton/smartolt-automate)
# - Pick the highest one that isn't a prerelease unless --pre is set
# - If newer than what's installed, show a diff and offer to upgrade
# - 'apply': update .env, pull, and re-create the stack
#
# Usage:
#   scripts/upgrade.sh            # check + prompt
#   scripts/upgrade.sh --check    # check only, no changes
#   scripts/upgrade.sh --apply    # non-interactive: apply the latest
#   scripts/upgrade.sh --pre      # include prereleases (v0.3.0-rc.1, etc.)
#   scripts/upgrade.sh v0.2.5     # upgrade to a specific tag
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# ─── output helpers ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[36m"; NC="\033[0m"
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; BLUE=""; NC=""
fi
step() { printf "\n${BLUE}==>${NC} ${BOLD}%s${NC}\n" "$1"; }
ok()   { printf "    ${GREEN}\u2713${NC} %s\n" "$1"; }
warn() { printf "    ${YELLOW}!${NC} %s\n" "$1"; }
err()  { printf "    ${RED}\u2717${NC} %s\n" "$1"; }

# ─── args ────────────────────────────────────────────────────────────────────
MODE="check"        # check | apply
INCLUDE_PRERELEASE=0
TARGET_TAG=""
for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --apply) MODE="apply" ;;
    --pre)   INCLUDE_PRERELEASE=1 ;;
    --help|-h)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    v*|[0-9]*)
      if [[ -z "$TARGET_TAG" ]]; then
        TARGET_TAG="$arg"
        MODE="${MODE:-apply}"
      else
        err "Multiple target tags specified: $TARGET_TAG and $arg"
        exit 1
      fi
      ;;
    *)
      err "Unknown argument: $arg"
      exit 1
      ;;
  esac
done

# ─── sanity ──────────────────────────────────────────────────────────────────
if [[ ! -f ".env" ]]; then
  err "No .env file found. Run scripts/install.sh first."
  exit 1
fi
require_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }
require_cmd docker
require_cmd python3 || require_cmd python
PYTHON="$(command -v python3 || command -v python)"

# ─── read currently installed image tag ──────────────────────────────────────
# Take the tag portion of SMARTOLT_IMAGE (asoton/smartolt-automate:vX.Y.Z).
get_env_var() {
  local key="$1"
  local val
  val=$(grep -E "^${key}=" .env | head -1 | cut -d= -f2-)
  # strip comments and surrounding quotes
  val="${val%%#*}"
  val="${val%\"}"
  val="${val#\"}"
  printf '%s' "$val"
}

CURRENT_BACKEND=$(get_env_var SMARTOLT_IMAGE)
CURRENT_TAG="${CURRENT_BACKEND##*:}"

# Default to the project's default if the value is missing.
if [[ -z "$CURRENT_TAG" || "$CURRENT_TAG" == "$CURRENT_BACKEND" ]]; then
  CURRENT_TAG="v0.2.0"
fi

# ─── fetch remote tags from Docker Hub ────────────────────────────────────────
REPO_OWNER="${DOCKERHUB_NAMESPACE:-asoton}"
REPO_NAME="smartolt-automate"
step "Checking Docker Hub for ${REPO_OWNER}/${REPO_NAME} tags..."

# We don't need auth for a public pull list. Two requests, both unauthenticated.
get_remote_tags() {
  # Public, anonymous. The 401 response is what tells us the token endpoint to use.
  local tok
  tok=$(curl -sS \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO_OWNER}/${REPO_NAME}:pull" \
    | "$PYTHON" -c "import sys,json; print(json.load(sys.stdin).get('token',''))")
  if [[ -z "$tok" ]]; then
    return 1
  fi
  curl -sS -H "Authorization: Bearer $tok" \
    "https://registry-1.docker.io/v2/${REPO_OWNER}/${REPO_NAME}/tags/list" \
    | "$PYTHON" -c "
import json, sys, re
data = json.load(sys.stdin)
tags = data.get('tags', [])
semver = []
for t in tags:
    m = re.match(r'^v?(\d+)\.(\d+)\.(\d+)(?:-(.+))?$', t)
    if m:
        major, minor, patch, pre = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
        semver.append((major, minor, patch, pre or '', t))
semver.sort(key=lambda x: (x[0], x[1], x[2], 0 if x[3] == '' else 1))
for _, _, _, _, t in semver:
    print(t)
"
}

REMOTE_TAGS=$(get_remote_tags) || {
  err "Failed to list tags from Docker Hub (network issue?)"
  exit 1
}

if [[ -z "$REMOTE_TAGS" ]]; then
  err "No semver tags found on Docker Hub for ${REPO_OWNER}/${REPO_NAME}."
  exit 1
fi

# ─── filter prereleases unless requested ─────────────────────────────────────
FILTERED_TAGS="$REMOTE_TAGS"
if [[ "$INCLUDE_PRERELEASE" == "0" ]]; then
  FILTERED_TAGS=$(printf '%s\n' "$REMOTE_TAGS" | grep -vE -- '-rc|-alpha|-beta|-dev' || true)
fi

LATEST_TAG=$(printf '%s\n' "$FILTERED_TAGS" | tail -1)
if [[ -z "$LATEST_TAG" ]]; then
  err "No stable tags available (only prereleases; rerun with --pre)."
  exit 1
fi

# ─── compare versions ────────────────────────────────────────────────────────
cmp_versions() {
  # echo 1 if $1 > $2, 0 if equal, -1 if less. Strips leading 'v'.
  "$PYTHON" - "$1" "$2" <<'PY'
import re, sys
def parse(v):
    m = re.match(r'^v?(\d+)\.(\d+)\.(\d+)(?:-(.+))?$', v)
    if not m:
        sys.exit(2)
    return int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4) or ''
a, b = parse(sys.argv[1]), parse(sys.argv[2])
# stable > prerelease
sa, sb = a[3] == '', b[3] == ''
if sa != sb:
    sys.exit(0 if sa else 1)  # stable wins
if a[:3] != b[:3]:
    sys.exit(0 if a[:3] > b[:3] else 1)
sys.exit(0 if a[3] > b[3] else (0 if a[3] < b[3] else 2))  # 2 = equal
PY
}

# cmp_versions exits 0 if $1 > $2, 1 if $1 < $2, 2 if equal. We invert
# because shell `if` treats 0 as success.
is_newer() {
  cmp_versions "$1" "$2"
  case $? in
    0) return 0 ;;  # newer
    1|2) return 1 ;;
    *) return 2 ;;
  esac
}

step "Versions"
printf "    Installed:  %s\n" "$CURRENT_TAG"
printf "    Latest:     %s\n" "$LATEST_TAG"

if [[ -n "$TARGET_TAG" ]]; then
  printf "    Requested:  %s\n" "$TARGET_TAG"
fi

# Determine what tag we'll be moving to.
NEXT_TAG="$LATEST_TAG"
if [[ -n "$TARGET_TAG" ]]; then
  NEXT_TAG="$TARGET_TAG"
fi

# cmp_versions exits 0 if $1 > $2, 1 if $1 < $2, 2 if equal.
# is_newer $a $b returns 0 if $a > $b, 1 otherwise.
if is_newer "$CURRENT_TAG" "$NEXT_TAG"; then
  warn "Downgrade detected: $CURRENT_TAG -> $NEXT_TAG"
elif is_newer "$NEXT_TAG" "$CURRENT_TAG"; then
  # NEXT_TAG is newer; nothing to do for now.
  :
else
  ok "Already on $CURRENT_TAG (no upgrade needed)."
  if [[ "$MODE" == "check" ]]; then
    exit 0
  fi
  # In --apply mode with no version change, just confirm and exit.
  if [[ -z "$TARGET_TAG" ]]; then
    exit 0
  fi
  # User explicitly asked for a specific tag equal to current.
  warn "Requested tag equals the installed one; nothing to do."
  exit 0
fi

# If mode is 'check', stop here.
if [[ "$MODE" == "check" ]]; then
  printf "\nRun '${BOLD}scripts/upgrade.sh --apply${NC}' to upgrade to ${NEXT_TAG}.\n"
  exit 0
fi

# ─── confirm before applying ─────────────────────────────────────────────────
printf "\nThis will:\n"
printf "  - update .env to use %s\n" "$NEXT_TAG"
printf "  - pull new images for backend, frontend, proxy, and certbot\n"
printf "  - recreate the smartolt-automate and web containers\n"
printf "  - leave data/, logs/, configs/, and the database untouched\n\n"

if [[ -t 0 ]]; then
  read -r -p "Proceed? [Y/n]: " reply
  reply="${reply:-Y}"
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# ─── apply the upgrade ───────────────────────────────────────────────────────
step "Updating .env to ${NEXT_TAG}"
for var in SMARTOLT_IMAGE SMARTOLT_FRONTEND_IMAGE PROXY_IMAGE CERTBOT_IMAGE; do
  if grep -qE "^${var}=" .env; then
    new_value="${REPO_OWNER}/$(echo "$var" | sed -E 's|^SMARTOLT_(.*)_IMAGE|\1|; s|^PROXY_IMAGE$|smartolt-automate-proxy|; s|^CERTBOT_IMAGE$|smartolt-automate-certbot|'):${NEXT_TAG}"
    # Map variable to image name. Do it explicitly to avoid sed backrefs hell.
    case "$var" in
      SMARTOLT_IMAGE)          new_value="${REPO_OWNER}/smartolt-automate:${NEXT_TAG}" ;;
      SMARTOLT_FRONTEND_IMAGE) new_value="${REPO_OWNER}/smartolt-automate-frontend:${NEXT_TAG}" ;;
      PROXY_IMAGE)             new_value="${REPO_OWNER}/smartolt-automate-proxy:${NEXT_TAG}" ;;
      CERTBOT_IMAGE)           new_value="${REPO_OWNER}/smartolt-automate-certbot:${NEXT_TAG}" ;;
    esac
    # Use a python one-liner to do safe in-place rewrite (no sed escaping issues).
    "$PYTHON" - "$var" "$new_value" .env <<'PY'
import sys, pathlib
key, new, path = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
lines = p.read_text().splitlines()
out = []
replaced = False
for line in lines:
    if line.startswith(f"{key}="):
        out.append(f"{key}={new}")
        replaced = True
    else:
        out.append(line)
if not replaced:
    out.append(f"{key}={new}")
p.write_text("\n".join(out) + "\n")
PY
    ok "$var=$new_value"
  fi
done

step "Pulling new images"
docker compose pull

step "Recreating smartolt-automate and web"
docker compose up -d --force-recreate smartolt-automate web

step "Waiting for healthchecks"
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sSf -o /dev/null --max-time 4 http://localhost/api/service/livez 2>/dev/null; then
    ok "Service is up at http://localhost/"
    break
  fi
  sleep 3
done

step "Done"
printf "  Previous version:  %s\n" "$CURRENT_TAG"
printf "  Current version:   %s\n" "$NEXT_TAG"
printf "\n  Verify the panel at ${BLUE}http://localhost/${NC}\n"