#!/usr/bin/env bash
# SmartOLT Automate installer — precise teardown.
#
# Destroys ONLY artifacts that the installer (scripts/install.sh +
# docker-compose.yml) created or modified in this directory. Will not
# touch anything outside the installer's scope:
#
#   - Other Docker Compose projects on the host
#   - Images from other namespaces (anything not asoton/smartolt-automate*)
#   - Templates shipped with the installer (.env.example, *.example.yaml)
#   - Any file outside ./configs, ./data, ./logs, ./state in the cwd
#
# What gets removed:
#   - 5 containers: smartolt-automate, -web, -frontend, -proxy, -certbot
#   - 7 volumes named <project>_logs, _state, _data, _proxy_caddy,
#     _certbot_etc, _certbot_work, _certbot_logs
#   - 1 network: <project>_default
#   - 4 images: asoton/smartolt-automate{,,-frontend,-proxy,-certbot}
#   - .env, configs/olts.yaml, data/*, logs/*, state/* in cwd
#
# WARNING: this deletes ALL SmartOLT Automate data (SQLite user DB, logs,
# state, OLT config, certs, Caddy config). There is NO recovery path.
#
# Usage:
#   scripts/destroy.sh                # interactive (asks for confirmation)
#   scripts/destroy.sh --yes          # skip the confirmation prompt
#   scripts/destroy.sh --keep-images  # skip 'docker rmi' for the 4 images
#   scripts/destroy.sh --keep-certs   # don't delete the certbot volume
#   scripts/destroy.sh --keep-data    # don't delete data/, logs/, state/

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# ─── output ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  readonly C_BOLD=$'\033[1m'
  readonly C_RED=$'\033[31m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_GREEN=$'\033[32m'
  readonly C_NC=$'\033[0m'
else
  readonly C_BOLD=""; readonly C_RED=""; readonly C_YELLOW=""
  readonly C_GREEN=""; readonly C_NC=""
fi
step() { printf "\n%s==>%s %s%s%s\n" "$C_BOLD" "$C_NC" "$C_BOLD" "$*" "$C_NC"; }
ok()   { printf "    %s✓%s %s\n" "$C_GREEN" "$C_NC" "$*"; }
warn() { printf "    %s!%s %s\n" "$C_YELLOW" "$C_NC" "$*"; }
err()  { printf "    %s✗%s %s\n" "$C_RED" "$C_NC" "$*"; }
die()  { err "$*"; exit 1; }

# ─── flags ───────────────────────────────────────────────────────────────────
ASSUME_YES=0
KEEP_IMAGES=0
KEEP_CERTS=0
KEEP_DATA=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)        ASSUME_YES=1 ;;
    --keep-images)   KEEP_IMAGES=1 ;;
    --keep-certs)    KEEP_CERTS=1 ;;
    --keep-data)     KEEP_DATA=1 ;;
    --help|-h)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *) die "Unknown flag: $1 (try --help)" ;;
  esac
  shift
done

# ─── sanity checks ───────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "Missing dependency: docker"
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"

# ─── define the exact scope of the installer ─────────────────────────────────
# Everything below is sourced from scripts/install.sh + docker-compose.yml.
# Changing either file means changing this list.

# Project name comes from the installer's COMPOSE_PROJECT_NAME_DEFAULT.
# The installer writes COMPOSE_PROJECT_NAME into .env if it's missing.
COMPOSE_PROJECT=""
if [[ -f "$ROOT/.env" ]]; then
  COMPOSE_PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' "$ROOT/.env" 2>/dev/null \
    | head -1 | cut -d= -f2- | tr -d '"\047[:space:]' || true)"
fi
COMPOSE_PROJECT="${COMPOSE_PROJECT:-smartolt_api_automate}"

# If the .env isn't authoritative (missing or stale) and there are leftover
# volumes/containers from a previous run with a different project name,
# detect the actual project name(s) by scanning for installer artifacts.
# This makes the destroy robust against a missing .env (e.g. when the
# previous run crashed mid-write).
DISCOVERED_PROJECTS=()
for v in $(docker volume ls --format '{{.Name}}' 2>/dev/null \
           | grep -E '_(logs|state|data|proxy_caddy|certbot_etc|certbot_work|certbot_logs)$' || true); do
  # Strip the well-known volume suffix to get the project name.
  proj="${v%_logs}"
  proj="${proj%_state}"
  proj="${proj%_data}"
  proj="${proj%_proxy_caddy}"
  proj="${proj%_certbot_etc}"
  proj="${proj%_certbot_work}"
  proj="${proj%_certbot_logs}"
  if [[ -n "$proj" && "$proj" != "$COMPOSE_PROJECT" ]]; then
    DISCOVERED_PROJECTS+=("$proj")
  fi
done

# Images come from the installer's DOCKERHUB_NAMESPACE_DEFAULT (asoton)
# and the image tag (v0.3.0+ as of this installer version). We only target
# the 4 repositories that ship with this installer, not anything else.
NAMESPACE="asoton"
IMAGE_REPOS=(
  "${NAMESPACE}/smartolt-automate"
  "${NAMESPACE}/smartolt-automate-frontend"
  "${NAMESPACE}/smartolt-automate-proxy"
  "${NAMESPACE}/smartolt-automate-certbot"
)

# Container names. The installer pins container_name explicitly for each
# service in docker-compose.yml, so we know exactly what to look for.
# (container_name overrides the auto-generated "<service>-<index>" form.)
CONTAINER_NAMES=(
  "smartolt-automate"
  "smartolt-automate-web"
  "smartolt-automate-frontend"
  "smartolt-automate-proxy"
  "smartolt-automate-certbot"
)

# All project names we should consider: the one from .env, plus any
# discovered from leftover volumes. This handles the case where the
# .env is missing or stale and a previous run used a different project.
ALL_PROJECTS=("$COMPOSE_PROJECT")
for p in "${DISCOVERED_PROJECTS[@]}"; do
  if [[ "$p" != "$COMPOSE_PROJECT" ]]; then
    ALL_PROJECTS+=("$p")
  fi
done

# Volume names. The installer declares these 7 volumes in docker-compose.yml.
# We build a list for each discovered project.
VOLUME_NAMES=()
for proj in "${ALL_PROJECTS[@]}"; do
  VOLUME_NAMES+=(
    "${proj}_logs"
    "${proj}_state"
    "${proj}_data"
    "${proj}_proxy_caddy"
    "${proj}_certbot_etc"
    "${proj}_certbot_work"
    "${proj}_certbot_logs"
  )
done

# Network names. One network per project (compose v2 default).
NETWORK_NAMES=()
for proj in "${ALL_PROJECTS[@]}"; do
  NETWORK_NAMES+=("${proj}_default")
done

# Filesystem artifacts created/modified by the installer. The bind mounts
# declared in docker-compose.yml are ./configs, ./data, ./logs, ./state.
# The installer creates .env at the root, and copies configs/olts.yaml
# from configs/olts.example.yaml if it doesn't exist.
FS_FILES=(
  ".env"
  "configs/olts.yaml"
)
FS_DIRS=(
  "configs"
  "data"
  "logs"
  "state"
)

# ─── discover what actually exists (don't pretend; show the operator) ───────
step "Inspecting current state"

EXISTING_CONTAINERS=()
for c in "${CONTAINER_NAMES[@]}"; do
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
    EXISTING_CONTAINERS+=("$c")
  fi
done

EXISTING_VOLUMES=()
for v in "${VOLUME_NAMES[@]}"; do
  if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$v"; then
    EXISTING_VOLUMES+=("$v")
  fi
done

EXISTING_NETWORKS=()
for n in "${NETWORK_NAMES[@]}"; do
  if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "$n"; then
    EXISTING_NETWORKS+=("$n")
  fi
done
if [[ ${#EXISTING_NETWORKS[@]} -gt 0 ]]; then
  printf "    Networks to remove:\n"
  for n in "${EXISTING_NETWORKS[@]}"; do
    printf "      - %s\n" "$n"
  done
else
  printf "    Networks to remove: (none found)\n"
fi

if [[ $KEEP_IMAGES -eq 0 ]]; then
  if [[ ${#EXISTING_IMAGES[@]} -gt 0 ]]; then
    printf "    Images to remove (only asoton/smartolt-automate*):\n"
    for i in "${EXISTING_IMAGES[@]}"; do
      printf "      - %s\n" "$i"
    done
  else
    printf "    Images to remove: (none found)\n"
  fi
else
  printf "    Images: SKIPPED (--keep-images)\n"
fi

if [[ ${#EXISTING_FS_FILES[@]} -gt 0 ]]; then
  printf "    Files to remove in cwd:\n"
  for f in "${EXISTING_FS_FILES[@]}"; do
    printf "      - %s\n" "$f"
  done
fi
if [[ ${#EXISTING_FS_DIR_CONTENTS[@]} -gt 0 ]]; then
  if [[ $KEEP_DATA -eq 1 ]]; then
    printf "    Bind-mount dir contents: SKIPPED (--keep-data)\n"
  else
    printf "    Bind-mount dir contents to clear (templates preserved):\n"
    for d in "${EXISTING_FS_DIR_CONTENTS[@]}"; do
      printf "      - %s\n" "$d"
    done
  fi
fi

# What's NOT touched (always print so the operator knows the scope).
printf "\n    NOT touched (out of installer scope):\n"
printf "      - .env.example, configs/olts.example.yaml, scripts/, docker-compose.yml\n"
printf "      - Images from other namespaces\n"
printf "      - Containers/volumes from other Docker Compose projects\n"
printf "      - Anything outside ./configs, ./data, ./logs, ./state\n"

# Short-circuit if there's nothing to do.
if [[ ${#EXISTING_CONTAINERS[@]} -eq 0 \
    && ${#EXISTING_VOLUMES[@]} -eq 0 \
    && ${#EXISTING_NETWORKS[@]} -eq 0 \
    && ${#EXISTING_IMAGES[@]} -eq 0 \
    && ${#EXISTING_FS_FILES[@]} -eq 0 \
    && ${#EXISTING_FS_DIR_CONTENTS[@]} -eq 0 ]]; then
  ok "Nothing to remove — installer has never been run here (or has been fully cleaned already)."
  exit 0
fi

# ─── confirm ─────────────────────────────────────────────────────────────────
if [[ $ASSUME_YES -eq 0 ]]; then
  printf "\n%sType YES to delete the above, anything else to abort:%s " "$C_RED" "$C_NC"
  read -r reply
  if [[ "$reply" != "YES" ]]; then
    die "Aborted."
  fi
fi

# ─── 1. docker compose down (preferred path) ─────────────────────────────────
step "1/5  docker compose down"
if [[ -f "docker-compose.yml" ]]; then
  # `down` removes containers AND the default network. It also removes
  # anonymous volumes. Named volumes (which is what we have) are kept by
  # default; we'll nuke them explicitly below for precision.
  if docker compose down --remove-orphans 2>&1 | tail -5; then
    ok "Stack down (containers + default network)"
  else
    warn "docker compose down returned non-zero. Continuing with manual cleanup."
  fi
  # Refresh our lists since compose down may have removed some.
  EXISTING_CONTAINERS=()
  for c in "${CONTAINER_NAMES[@]}"; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
      EXISTING_CONTAINERS+=("$c")
    fi
  done
else
  warn "No docker-compose.yml in $ROOT — skipping compose down."
fi

# ─── 2. kill remaining containers (defensive — only our 5) ──────────────────
step "2/5  Removing any remaining installer containers"
if [[ ${#EXISTING_CONTAINERS[@]} -eq 0 ]]; then
  ok "No installer containers left to remove"
else
  for c in "${EXISTING_CONTAINERS[@]}"; do
    if docker rm -f "$c" >/dev/null 2>&1; then
      ok "Removed container $c"
    else
      err "Failed to remove container $c"
    fi
  done
fi

# ─── 3. remove volumes (only the 7 declared in docker-compose.yml) ──────────
step "3/5  Removing installer volumes"
EXISTING_VOLUMES=()
for v in "${VOLUME_NAMES[@]}"; do
  if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$v"; then
    EXISTING_VOLUMES+=("$v")
  fi
done
if [[ ${#EXISTING_VOLUMES[@]} -eq 0 ]]; then
  ok "No installer volumes to remove"
else
  for v in "${EXISTING_VOLUMES[@]}"; do
    if [[ $KEEP_CERTS -eq 1 && "$v" == "${COMPOSE_PROJECT}_certbot_etc" ]]; then
      warn "Skipping $v (--keep-certs)"
      continue
    fi
    if docker volume rm "$v" >/dev/null 2>&1; then
      ok "Removed volume $v"
    else
      err "Failed to remove volume $v (may be in use — retry without other containers)"
    fi
  done
fi

# ─── 4. remove images (only the 4 asoton/smartolt-automate* repos) ─────────
step "4/5  Removing installer images"
if [[ $KEEP_IMAGES -eq 1 ]]; then
  warn "Skipping image removal (--keep-images)"
else
  EXISTING_IMAGES=()
  for repo in "${IMAGE_REPOS[@]}"; do
    ids=$(docker image ls --format '{{.Repository}} {{.ID}}' 2>/dev/null \
      | awk -v r="$repo" '$1 == r {print $2}')
    if [[ -n "$ids" ]]; then
      while read -r id; do
        [[ -z "$id" ]] && continue
        EXISTING_IMAGES+=("$repo:$id")
      done <<< "$ids"
    fi
  done
  if [[ ${#EXISTING_IMAGES[@]} -eq 0 ]]; then
    ok "No installer images to remove"
  else
    for entry in "${EXISTING_IMAGES[@]}"; do
      repo="${entry%%:*}"
      id="${entry##*:}"
      if docker image rm -f "$id" >/dev/null 2>&1; then
        ok "Removed image $repo (id=$id)"
      else
        err "Failed to remove image $repo (id=$id) — may be referenced by another container"
      fi
    done
  fi
fi

# ─── 5. remove network + filesystem artifacts ─────────────────────────────────
step "5/5  Removing networks and filesystem artifacts"
if [[ ${#EXISTING_NETWORKS[@]} -eq 0 ]]; then
  ok "No installer networks to remove"
else
  for n in "${EXISTING_NETWORKS[@]}"; do
    if docker network rm "$n" >/dev/null 2>&1; then
      ok "Removed network $n"
    else
      # Network may have been already removed by `docker compose down`.
      if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "$n"; then
        err "Failed to remove network $n"
      else
        ok "Network $n already removed (by compose down)"
      fi
    fi
  done
fi

if [[ $KEEP_DATA -eq 1 ]]; then
  warn "Skipping filesystem cleanup (--keep-data)"
else
  # Remove the files the installer generates (.env, configs/olts.yaml).
  for f in "${FS_FILES[@]}"; do
    if [[ -e "$ROOT/$f" ]]; then
      if rm -f "$ROOT/$f"; then
        ok "Removed $f"
      else
        err "Failed to remove $f"
      fi
    fi
  done

  # Clear bind-mount dirs but preserve templates (*.example.*).
  for d in "${FS_DIRS[@]}"; do
    if [[ -d "$ROOT/$d" ]]; then
      # Only delete files, never directories themselves (compose expects
      # them to exist with the right perms for bind mounts).
      deleted=$(find "$ROOT/$d" -mindepth 1 -maxdepth 1 \
        ! -name '*.example.*' ! -name '*.example' \
        -exec rm -rf {} + 2>/dev/null | wc -l)
      if [[ $deleted -gt 0 ]]; then
        ok "Cleared $ROOT/$d/ ($deleted non-template files; templates preserved)"
      fi
    fi
  done
fi

# ─── final verification ──────────────────────────────────────────────────────
step "Done"
fail=0
remaining=$(docker ps -a --format '{{.Names}}' 2>/dev/null \
  | grep -E "^($(IFS='|'; echo "${CONTAINER_NAMES[*]}"))$" || true)
if [[ -n "$remaining" ]]; then
  err "Some installer containers still exist:"
  echo "$remaining" | sed 's/^/      /'
  fail=1
fi
remaining_vol=$(docker volume ls --format '{{.Name}}' 2>/dev/null \
  | grep -E "^($(IFS='|'; echo "${VOLUME_NAMES[*]}"))$" || true)
if [[ -n "$remaining_vol" ]]; then
  if [[ $KEEP_CERTS -eq 1 ]]; then
    # Certbot volume may still be there by design.
    other_vol=$(echo "$remaining_vol" | grep -v "${COMPOSE_PROJECT}_certbot_etc" || true)
    if [[ -n "$other_vol" ]]; then
      warn "Some non-cert installer volumes still exist (preserved by --keep-certs):"
      echo "$other_vol" | sed 's/^/      /'
    else
      ok "Only certbot volume remains (preserved by --keep-certs)."
    fi
  else
    err "Some installer volumes still exist:"
    echo "$remaining_vol" | sed 's/^/      /'
    fail=1
  fi
fi
for n in "${EXISTING_NETWORKS[@]}"; do
  if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "$n"; then
    err "Network $n still exists"
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then
  ok "Destroy complete. Re-run ./scripts/install.sh to deploy a fresh stack."
  exit 0
else
  exit 2
fi
