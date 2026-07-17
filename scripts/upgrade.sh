#!/usr/bin/env bash
# Detect new versions of SmartOLT Automate and offer to upgrade.
#
# Strategy:
# - Read the currently-installed tag from .env (SMARTOLT_IMAGE, etc.).
# - List all semver tags on Docker Hub (asoton/smartolt-automate).
# - Pick the highest stable one (or --pre / explicit tag).
# - --check: show what would happen and exit.
# - --apply: update .env, pull, and re-create the smartolt-automate + web
#   containers. data/, logs/, configs/ are untouched.
#
# Usage:
#   scripts/upgrade.sh            # check + prompt
#   scripts/upgrade.sh --check    # check only, no changes
#   scripts/upgrade.sh --apply    # apply the latest stable release
#   scripts/upgrade.sh --apply --yes    # non-interactive apply
#   scripts/upgrade.sh --pre      # include prereleases
#   scripts/upgrade.sh v0.3.0     # upgrade to a specific tag
#   scripts/upgrade.sh v0.3.0 --apply --yes   # non-interactive

# No `set -u`: this script handles many empty/default values and we
# prefer friendly errors over "unbound variable" tracebacks.
set -eo pipefail

# ─── constants ────────────────────────────────────────────────────────────────
readonly REPO_OWNER_DEFAULT="asoton"
readonly REPO_NAME="smartolt-automate"
readonly HEALTHCHECK_URL="http://localhost/api/service/livez"
readonly HEALTHCHECK_TIMEOUT=4
readonly HEALTHCHECK_RETRIES=15
readonly HEALTHCHECK_INTERVAL=3
readonly IMAGE_VARS=(
  "SMARTOLT_IMAGE:smartolt-automate"
  "SMARTOLT_FRONTEND_IMAGE:smartolt-automate-frontend"
  "PROXY_IMAGE:smartolt-automate-proxy"
  "CERTBOT_IMAGE:smartolt-automate-certbot"
)

# ─── output ──────────────────────────────────────────────────────────────────
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

# ─── TTY probe (same trick as install.sh) ────────────────────────────────────
have_tty() {
  [[ -t 0 ]] && return 0
  if { exec 3</dev/tty; } 2>/dev/null; then
    exec 3<&-
    return 0
  fi
  return 1
}

# Read a Y/n answer from /dev/tty if possible, else stdin, else default.
# Sets the named variable to "y" or "n". If $3 is "force" or stdin is not
# a TTY, the default is taken without asking.
read_yn() {
  local var_name="$1" prompt="$2" default="${3:-Y}" force="${4:-}"
  local reply=""
  if [[ "$force" == "force" || ! -t 0 && ! -r /dev/tty ]]; then
    reply="$default"
  elif have_tty; then
    local shown
    if [[ "$default" =~ ^[Yy]$ ]]; then shown="Y/n"; else shown="y/N"; fi
    read -r -p "    $prompt [$shown]: " reply </dev/tty || true
    reply="${reply:-$default}"
  else
    reply="$default"
  fi
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    printf -v "$var_name" 'y'
  else
    printf -v "$var_name" 'n'
  fi
}

# ─── parse arguments ─────────────────────────────────────────────────────────
MODE="check"          # check | apply
INCLUDE_PRERELEASE=0
ASSUME_YES=0
TARGET_TAG=""
HAS_CHECK_FLAG=0
HAS_APPLY_FLAG=0
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; HAS_CHECK_FLAG=1 ;;
    --apply) MODE="apply"; HAS_APPLY_FLAG=1 ;;
    --pre)   INCLUDE_PRERELEASE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --help|-h)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    --*)
      die "Unknown flag: $1 (try --help)"
      ;;
    v*|[0-9]*)
      if [[ -n "$TARGET_TAG" ]]; then
        die "Multiple target tags: $TARGET_TAG and $1"
      fi
      TARGET_TAG="$1"
      ;;
    *)
      die "Unknown argument: $1 (try --help)"
      ;;
  esac
  shift
done

# A bare positional tag implies --apply unless --check was explicit.
# `upgrade.sh v0.3.0`         -> apply
# `upgrade.sh v0.3.0 --check` -> check
# `upgrade.sh --check v0.3.0` -> check
if [[ -n "$TARGET_TAG" && $HAS_APPLY_FLAG -eq 0 && $HAS_CHECK_FLAG -eq 0 ]]; then
  MODE="apply"
fi

# ─── sanity checks ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

[[ -f ".env" ]] || die "No .env found. Run scripts/install.sh first."
command -v docker >/dev/null 2>&1 || die "Missing dependency: docker"
PYTHON="$(command -v python3 || command -v python)"
[[ -n "$PYTHON" ]] || die "Missing dependency: python3 (or python)"
command -v curl >/dev/null 2>&1 || die "Missing dependency: curl"

# ─── read currently installed image tag ──────────────────────────────────────
#
# Use Python (not grep/sed) so we can handle quoted values, comments, etc.
get_env_var() {
  "$PYTHON" - "$1" .env <<'PY'
import sys, pathlib, re
key, path = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
if not p.exists():
    sys.exit(0)
for line in p.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$', line)
    if not m:
        continue
    k, raw = m.group(1), m.group(2)
    if k != key:
        continue
    # Strip comments at the end of the line (but not inside quotes).
    # Easiest correct approach: find matching closing quote.
    val = raw
    if val.startswith('"'):
        end = val.find('"', 1)
        if end != -1:
            val = val[1:end]
            # unescape python-dotenv style: \\ and \"
            val = val.replace('\\\\', '\x00').replace('\\"', '"').replace('\x00', '\\')
            print(val, end="")
            sys.exit(0)
    elif val.startswith("'"):
        end = val.find("'", 1)
        if end != -1:
            print(val[1:end], end="")
            sys.exit(0)
    # bare value
    val = val.split('#', 1)[0].rstrip()
    print(val, end="")
    sys.exit(0)
PY
}

CURRENT_BACKEND="$(get_env_var SMARTOLT_IMAGE)"
CURRENT_TAG="${CURRENT_BACKEND##*:}"
if [[ -z "$CURRENT_TAG" || "$CURRENT_TAG" == "$CURRENT_BACKEND" ]]; then
  # Either no SMARTOLT_IMAGE in .env, or it's a digest (sha256:...).
  CURRENT_TAG="v0.3.0"
fi

# ─── fetch remote tags from Docker Hub ───────────────────────────────────────
REPO_OWNER="${DOCKERHUB_NAMESPACE:-$REPO_OWNER_DEFAULT}"

step "Checking Docker Hub for ${REPO_OWNER}/${REPO_NAME} tags"

# Single Python call does the whole thing: auth, fetch, parse, sort, filter.
# Returns one tag per line, highest first.
get_remote_tags() {
  "$PYTHON" - "$REPO_OWNER" "$REPO_NAME" "$INCLUDE_PRERELEASE" <<'PY'
import json, sys, urllib.request, urllib.error, re

owner, repo, include_pre = sys.argv[1], sys.argv[2], int(sys.argv[3])

try:
    # Get an anonymous bearer token (works for public repos).
    auth_url = f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{owner}/{repo}:pull"
    with urllib.request.urlopen(auth_url, timeout=10) as r:
        tok = json.loads(r.read())["token"]
    req = urllib.request.Request(
        f"https://registry-1.docker.io/v2/{owner}/{repo}/tags/list",
        headers={"Authorization": f"Bearer {tok}"},
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        data = json.loads(r.read())
except Exception as e:
    print(f"# error: {e}", file=sys.stderr)
    sys.exit(1)

tags = data.get("tags", [])
parsed = []
for t in tags:
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)(?:[-.](.+))?$", t)
    if not m:
        continue
    major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
    pre = m.group(4) or ""
    if pre and not include_pre:
        continue
    # Sort key: (major, minor, patch, is_prerelease, pre_str)
    # stable > prerelease at the same x.y.z
    parsed.append((major, minor, patch, 0 if pre == "" else 1, pre, t))

# Highest first.
parsed.sort(reverse=True)
for _, _, _, _, _, t in parsed:
    print(t)
PY
}

REMOTE_TAGS="$(get_remote_tags || true)"
if [[ -z "$REMOTE_TAGS" ]]; then
  die "No semver tags available on Docker Hub for ${REPO_OWNER}/${REPO_NAME} (network error?)"
fi

LATEST_TAG="$(printf '%s\n' "$REMOTE_TAGS" | head -1)"
if [[ -z "$LATEST_TAG" ]]; then
  die "No tags found. (Try --pre to include prereleases.)"
fi

# Determine the next tag.
NEXT_TAG="$LATEST_TAG"
if [[ -n "$TARGET_TAG" ]]; then
  # Validate that the requested tag actually exists.
  if ! printf '%s\n' "$REMOTE_TAGS" | grep -qx "$TARGET_TAG"; then
    die "Tag '$TARGET_TAG' not found on Docker Hub. Latest available: $LATEST_TAG"
  fi
  NEXT_TAG="$TARGET_TAG"
fi

# ─── compare versions ────────────────────────────────────────────────────────
# Returns 0 if $1 == $2, 1 if $1 > $2, 2 if $1 < $2.
version_cmp() {
  "$PYTHON" - "$1" "$2" <<'PY'
import re, sys
def parse(v):
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)(?:[-.](.+))?$", v)
    if not m:
        sys.exit(2)
    return int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4) or ""
a = parse(sys.argv[1]); b = parse(sys.argv[2])
sa, sb = a[3] == "", b[3] == ""
# Stable > prerelease.
if sa and not sb: sys.exit(1)
if sb and not sa: sys.exit(2)
if a[:3] != b[:3]:
    sys.exit(1 if a[:3] > b[:3] else 2)
# Same x.y.z: prerelease string compared lexicographically.
if a[3] == b[3]: sys.exit(0)
sys.exit(1 if a[3] > b[3] else 2)
PY
}

set +e
version_cmp "$CURRENT_TAG" "$NEXT_TAG"
cmp_result=$?
set -e

# ─── show what we found ──────────────────────────────────────────────────────
step "Versions"
printf "    Installed:  %s\n" "$CURRENT_TAG"
printf "    Latest:     %s\n" "$LATEST_TAG"
if [[ -n "$TARGET_TAG" ]]; then
  printf "    Requested:  %s\n" "$TARGET_TAG"
fi

case "$cmp_result" in
  0)
    if [[ -n "$TARGET_TAG" ]]; then
      warn "Already on the requested tag ($CURRENT_TAG)."
    else
      ok "Already on the latest stable release ($CURRENT_TAG)."
    fi
    exit 0
    ;;
  1)
    warn "Downgrade detected: $CURRENT_TAG -> $NEXT_TAG"
    ;;
  2)
    # CURRENT < NEXT, this is the normal upgrade path.
    ;;
  *)
    die "Could not compare versions: $CURRENT_TAG vs $NEXT_TAG"
    ;;
esac

# ─── check-only mode stops here ─────────────────────────────────────────────
if [[ "$MODE" == "check" ]]; then
  printf "\nRun '%sscripts/upgrade.sh --apply%s' to upgrade to %s%s%s.\n" \
    "$C_BOLD" "$C_NC" "$C_BLUE" "$NEXT_TAG" "$C_NC"
  exit 0
fi

# ─── confirm before applying ─────────────────────────────────────────────────
printf "\nThis will:\n"
printf "  - update .env to use %s%s%s\n" "$C_BOLD" "$NEXT_TAG" "$C_NC"
printf "  - pull new images for backend, frontend, proxy, and certbot\n"
printf "  - recreate the smartolt-automate and web containers\n"
printf "  - leave data/, logs/, configs/, and the database untouched\n\n"

if [[ $ASSUME_YES -eq 0 ]]; then
  PROCEED="n"
  read_yn PROCEED "Proceed?" "Y"
  if [[ "$PROCEED" != "y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# ─── apply the upgrade ───────────────────────────────────────────────────────
step "Updating .env to ${NEXT_TAG}"

# Snapshot .env before we touch it so we can roll back if the pull
# (or recreate) fails. A partial upgrade (env says v0.3.1 but only
# some images were pulled) leaves the stack in a broken state.
ENV_BACKUP=""
ROLLBACK_DONE=0
cleanup_and_exit() {
  local rc=$?
  # If we still have the backup AND haven't committed the upgrade,
  # restore it. This is what gives us atomic semantics.
  if [[ -n "$ENV_BACKUP" && -f "$ENV_BACKUP" && $ROLLBACK_DONE -eq 0 ]]; then
    cp -f "$ENV_BACKUP" .env
    warn "Rolled .env back to the pre-upgrade state."
  fi
  [[ -n "$ENV_BACKUP" && -f "$ENV_BACKUP" ]] && rm -f "$ENV_BACKUP"
  exit $rc
}
trap cleanup_and_exit EXIT INT TERM
ENV_BACKUP="$(mktemp -t upgrade-env-XXXXXX.bak)"
cp -f .env "$ENV_BACKUP"

# If the user is upgrading from a state that never had configs/olts.yaml
# (e.g. they ran install.sh but skipped the OLT step, or the file was
# deleted), the backend will refuse to start. Bootstrap from the template
# if available. Never overwrite an existing file.
mkdir -p configs
if [[ ! -f "configs/olts.yaml" && -f "configs/olts.example.yaml" ]]; then
  cp -f configs/olts.example.yaml configs/olts.yaml
  ok "Bootstrapped configs/olts.yaml from template"
fi

# Build a list of (var, value) pairs and call env_set once.
# env_set is defined inline so the script is self-contained.
env_set() {
  "$PYTHON" - "$@" <<'PY'
import sys, pathlib, re

def quote_value(v: str) -> str:
    out = []
    for ch in v:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'

def needs_quote(v: str) -> bool:
    if not v:
        return True
    if any(c in v for c in ' \t"\'#$&`\\'):
        return True
    if v.startswith(("-", "+", ".")):
        return True
    return False

# argv: env_path, then key/value pairs
path = pathlib.Path(sys.argv[1])
pairs = []
i = 2
while i < len(sys.argv):
    pairs.append((sys.argv[i], sys.argv[i+1]))
    i += 2

existing = {}
for line in path.read_text().splitlines() if path.exists() else []:
    if not line or line.lstrip().startswith("#") or "=" not in line:
        continue
    k = line.split("=", 1)[0].strip()
    if k not in existing:
        existing[k] = line

out_lines = []
for k, line in existing.items():
    if any(p[0] == k for p in pairs):
        continue
    out_lines.append(line)
for k, v in pairs:
    if needs_quote(v):
        out_lines.append(f"{k}={quote_value(v)}")
    else:
        out_lines.append(f"{k}={v}")
path.write_text("\n".join(out_lines) + "\n")
PY
}

args=(".env")
for spec in "${IMAGE_VARS[@]}"; do
  var="${spec%%:*}"
  image="${spec##*:}"
  args+=("$var" "${REPO_OWNER}/${image}:${NEXT_TAG}")
done
env_set "${args[@]}"
for spec in "${IMAGE_VARS[@]}"; do
  var="${spec%%:*}"
  image="${spec##*:}"
  ok "$var=${REPO_OWNER}/${image}:${NEXT_TAG}"
done

# ─── pull + recreate ────────────────────────────────────────────────────────
step "Pulling new images"
if ! docker compose pull; then
  die "docker compose pull failed. Check your network and that the tag exists."
fi
ok "Images pulled"

# Pull succeeded; mark the new state as committed so the EXIT trap
# doesn't roll it back.
ROLLBACK_DONE=1
rm -f "$ENV_BACKUP"
ENV_BACKUP=""

# Stop the old containers and remove them. We use `down` (not `stop`)
# so docker compose can clean up networks too. --remove-orphans catches
# any containers left over from a previous project name. We do this
# before up so that --force-recreate doesn't fail with "container name
# already in use" when COMPOSE_PROJECT_NAME has changed.
step "Stopping existing stack"
if ! docker compose down --remove-orphans; then
  warn "docker compose down returned non-zero. Continuing anyway."
fi

step "Bringing stack back up"
# `up -d` (no service arg) brings up everything in the compose file,
# not just smartolt-automate + web. The latter would leave the proxy
# and frontend down if they happened to be stopped.
if ! docker compose up -d; then
  die "docker compose up -d failed. Inspect 'docker compose logs' for details."
fi
ok "Containers recreated"

# ─── healthcheck ────────────────────────────────────────────────────────────
step "Waiting for healthchecks"
up=0
for ((i = 1; i <= HEALTHCHECK_RETRIES; i++)); do
  if curl --silent --show-error --fail --output /dev/null \
       --connect-timeout 2 --max-time "$HEALTHCHECK_TIMEOUT" \
       "$HEALTHCHECK_URL"; then
    up=1
    ok "Service reachable at $HEALTHCHECK_URL"
    break
  fi
  printf "  ... retry %d/%d\n" "$i" "$HEALTHCHECK_RETRIES"
  sleep "$HEALTHCHECK_INTERVAL"
done

if [[ $up -ne 1 ]]; then
  warn "Healthcheck did not respond within the timeout. Run 'docker compose logs web' to debug."
  exit 2
fi

step "Done"
printf "  Previous version:  %s\n" "$CURRENT_TAG"
printf "  Current version:   %s\n" "$NEXT_TAG"
printf "\n  Verify the panel at %shttp://localhost/%s\n" "$C_BLUE" "$C_NC"