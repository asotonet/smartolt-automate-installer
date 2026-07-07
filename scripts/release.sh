#!/usr/bin/env bash
# Tag and push all four SmartOLT Automate images to Docker Hub.
#
# Why this script exists: the wizard references backend, frontend,
# proxy, and certbot by tag. If any of them is missing the tag for
# the version that's in .env / DEFAULT_IMAGE_TAG, `docker compose pull`
# fails on the first fresh install. We've shipped releases where one
# of the four was forgotten. This script makes that mistake impossible.
#
# Usage:
#   scripts/release.sh                     # tag + push with the version from .env
#   scripts/release.sh v0.3.0             # tag + push with explicit version
#   scripts/release.sh --check            # verify the tag exists in Docker Hub
#   scripts/release.sh --check v0.3.0     # verify a specific tag
#
# Requires: docker, an authenticated `docker login` session against Docker Hub,
# network access to registry-1.docker.io, python3 for the verification step.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

NAMESPACE="${DOCKERHUB_NAMESPACE:-asoton}"

# ─── output ────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  readonly C_BOLD=$'\033[1m'
  readonly C_GREEN=$'\033[32m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_RED=$'\033[31m'
  readonly C_BLUE=$'\033[36m'
  readonly C_NC=$'\033[0m'
else
  readonly C_BOLD=""; readonly C_GREEN=""; readonly C_YELLOW=""
  readonly C_RED=""; readonly C_BLUE=""; readonly C_NC=""
fi
step() { printf "\n%s==>%s %s%s%s\n" "$C_BLUE" "$C_NC" "$C_BOLD" "$*" "$C_NC"; }
ok()   { printf "    %s✓%s %s\n" "$C_GREEN" "$C_NC" "$*"; }
warn() { printf "    %s!%s %s\n" "$C_YELLOW" "$C_NC" "$*"; }
err()  { printf "    %s✗%s %s\n" "$C_RED" "$C_NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ─── helpers ───────────────────────────────────────────────────────────────
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

# Detect the version to tag. Order of preference:
#   1. explicit argument (e.g. scripts/release.sh v0.3.0)
#   2. SMARTOLT_IMAGE_TAG env var
#   3. tag parsed from SMARTOLT_IMAGE in .env (the wizard writes this)
#   4. DEFAULT_IMAGE_TAG_DEFAULT from scripts/install.sh
get_version() {
  if [[ -n "${1:-}" ]]; then
    echo "$1"
    return
  fi
  if [[ -n "${SMARTOLT_IMAGE_TAG:-}" ]]; then
    echo "$SMARTOLT_IMAGE_TAG"
    return
  fi
  if [[ -f .env ]]; then
    local from_env
    from_env="$(grep -E '^SMARTOLT_IMAGE=' .env | head -1 | cut -d= -f2- | sed 's/.*://')"
    if [[ -n "$from_env" ]]; then
      echo "$from_env"
      return
    fi
  fi
  if [[ -f scripts/install.sh ]]; then
    grep -oE 'DEFAULT_IMAGE_TAG_DEFAULT="[^"]+"' scripts/install.sh \
      | head -1 | sed -E 's/.*"([^"]+)".*/\1/'
    return
  fi
  die "Could not detect a version. Pass it as the first argument: scripts/release.sh v0.3.0"
}

# Image-name resolution. Maps the env var in .env to the repo basename.
declare -A IMAGE_BASENAME=(
  [SMARTOLT_IMAGE]="smartolt-automate"
  [SMARTOLT_FRONTEND_IMAGE]="smartolt-automate-frontend"
  [PROXY_IMAGE]="smartolt-automate-proxy"
  [CERTBOT_IMAGE]="smartolt-automate-certbot"
)

# Tag and push one image: IMAGE_TAG where IMAGE_TAG is a local image:tag.
publish() {
  local src_tag="$1" dst_tag="$2" name="$3"
  if ! docker image inspect "$src_tag" >/dev/null 2>&1; then
    err "Local image not found: $src_tag"
    return 1
  fi
  if [[ "$src_tag" != "$dst_tag" ]]; then
    docker tag "$src_tag" "$dst_tag"
    ok "tagged $src_tag -> $dst_tag"
  fi
  if docker push "$dst_tag" 2>&1 | tail -3; then
    ok "pushed $dst_tag"
    return 0
  else
    err "push failed: $dst_tag"
    return 1
  fi
}

# Verify a tag exists on Docker Hub for the given repo.
verify_remote_tag() {
  local repo="$1" tag="$2"
  local tok
  tok=$(curl --silent --show-error --fail \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${NAMESPACE}/${repo}:pull" \
    | "$PYTHON" -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || echo "")
  if [[ -z "$tok" ]]; then
    warn "could not authenticate against Docker Hub for $repo"
    return 1
  fi
  if curl --silent --show-error --fail \
       -H "Authorization: Bearer $tok" \
       "https://registry-1.docker.io/v2/${NAMESPACE}/${repo}/tags/list" \
       | "$PYTHON" -c "
import sys, json
tags = json.load(sys.stdin).get('tags', [])
sys.exit(0 if '$tag' in tags else 1)
" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# ─── preflight ─────────────────────────────────────────────────────────────
require_cmd docker
require_cmd curl
PYTHON="$(command -v python3 || command -v python)"
[[ -n "$PYTHON" ]] || die "Missing dependency: python3 (or python)"

# Auth check. Either via `docker login` or env-provided creds.
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
if [[ -z "$DOCKERHUB_TOKEN" ]]; then
  if grep -q "\"https://index.docker.io/v1/\"" "${HOME}/.docker/config.json" 2>/dev/null; then
    ok "logged in to Docker Hub via ~/.docker/config.json"
  else
    die "Not logged in to Docker Hub. Run: docker login -u ${NAMESPACE}"
  fi
fi

# ─── args ──────────────────────────────────────────────────────────────────
MODE="publish"
TARGET_VERSION=""
for arg in "$@"; do
  case "$arg" in
    --check)  MODE="check" ;;
    --help|-h)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    v*|[0-9]*)
      [[ -z "$TARGET_VERSION" ]] || die "Multiple versions specified"
      TARGET_VERSION="$arg"
      ;;
    *)
      die "Unknown argument: $arg (try --help)"
      ;;
  esac
done

VERSION="$(get_version "$TARGET_VERSION")"
[[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]] || die "Not a semver version: $VERSION"
# Normalize to 'v' prefix.
[[ "$VERSION" == v* ]] || VERSION="v$VERSION"

step "Tagging plan"
printf "    Namespace:  %s\n" "$NAMESPACE"
printf "    Version:    %s\n" "$VERSION"

if [[ "$MODE" == "check" ]]; then
  echo
  printf "    %-12s %s\n" "image" "tag"
  echo "    ------------ ------"
  rc=0
  for repo in smartolt-automate smartolt-automate-frontend smartolt-automate-proxy smartolt-automate-certbot; do
    if verify_remote_tag "$repo" "$VERSION"; then
      printf "    %-12s %s  ✓\n" "$repo" "$VERSION"
    else
      printf "    %-12s %s  %s✗ MISSING%s\n" "$repo" "$VERSION" "$C_RED" "$C_NC"
      rc=1
    fi
  done
  exit $rc
fi

step "Tagging and pushing 4 images"
fail=0
# Order matters: backend first, then frontend, then proxy, then certbot.
# If something fails the remaining steps still run.
declare -a ORDER=(SMARTOLT_IMAGE SMARTOLT_FRONTEND_IMAGE PROXY_IMAGE CERTBOT_IMAGE)
for var in "${ORDER[@]}"; do
  repo="${IMAGE_BASENAME[$var]}"
  src="${NAMESPACE}/${repo}:${VERSION}"
  dst="${NAMESPACE}/${repo}:latest"
  printf "    %s:%s\n" "$repo" "$VERSION"
  if ! publish "$src" "$src" "$repo"; then
    fail=$((fail + 1))
    continue
  fi
  # Also keep :latest updated. Idempotent; Docker Hub deduplicates layers.
  printf "    %s:latest\n" "$repo"
  publish "$src" "$dst" "$repo" || fail=$((fail + 1))
done

if (( fail > 0 )); then
  err "$fail image(s) failed"
  exit 1
fi

step "Verification"
rc=0
for repo in smartolt-automate smartolt-automate-frontend smartolt-automate-proxy smartolt-automate-certbot; do
  if verify_remote_tag "$repo" "$VERSION"; then
    ok "$repo:$VERSION"
  else
    err "$repo:$VERSION not found on Docker Hub (push may have failed silently)"
    rc=1
  fi
done

if (( rc == 0 )); then
  printf "\n%sDone.%s\n  Version %s published to asoton/{smartolt-automate,...}.\n" \
    "$C_BOLD" "$C_NC" "$VERSION"
fi
exit $rc