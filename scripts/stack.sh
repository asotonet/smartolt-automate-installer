#!/usr/bin/env bash
# Operate the local docker compose stack.
#
# Usage:
#   scripts/stack.sh pull              # pull latest images from Docker Hub
#   scripts/stack.sh up                # docker compose up -d
#   scripts/stack.sh down              # docker compose down
#   scripts/stack.sh restart [svc...]  # docker compose restart [services]
#   scripts/stack.sh status            # show status + health URLs
#   scripts/stack.sh logs [svc...]     # tail logs (-f)
#   scripts/stack.sh ps                # docker compose ps
#   scripts/stack.sh upgrade           # pull + up -d in one shot
#   scripts/stack.sh config            # show rendered compose config
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

cmd="${1:-status}"
shift || true

if [[ ! -f ".env" ]]; then
  echo "No .env file found. Run scripts/install.sh first."
  exit 1
fi

case "$cmd" in
  pull)
    docker compose pull "$@"
    ;;
  up)
    docker compose up -d "$@"
    ;;
  down)
    docker compose down "$@"
    ;;
  restart)
    docker compose restart "$@"
    ;;
  ps)
    docker compose ps "$@"
    ;;
  logs)
    docker compose logs -f "$@"
    ;;
  config)
    docker compose config "$@"
    ;;
  upgrade)
    # If the upgrade.sh script is present and no specific tag was passed,
    # delegate to it so the user gets the new-version check.
    if [[ -x "scripts/upgrade.sh" ]] && [[ $# -eq 0 ]]; then
      exec scripts/upgrade.sh --apply
    fi
    docker compose pull "$@"
    docker compose up -d
    docker compose ps
    echo ""
    echo "Probing /api/service/livez ..."
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if curl -sSf -o /dev/null --max-time 4 http://localhost/api/service/livez 2>/dev/null; then
        echo "OK: service is up at http://localhost/"
        exit 0
      fi
      sleep 3
    done
    echo "Warning: /api/service/livez did not respond yet. Check 'docker compose logs'."
    exit 0
    ;;
  status)
    docker compose ps
    echo ""
    echo "Images:"
    grep -E '^(SMARTOLT_IMAGE|SMARTOLT_FRONTEND_IMAGE|PROXY_IMAGE|CERTBOT_IMAGE)=' .env \
      | sed 's/^/  /'
    echo ""
    echo "Probes:"
    for url in \
      "http://localhost/api/service/livez"; do
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 "$url" 2>/dev/null || echo "000")
      printf "  %-50s -> HTTP %s\n" "$url" "$code"
    done
    ;;
  *)
    echo "Unknown command: $cmd"
    echo "Usage: $0 {pull|up|down|restart|status|logs|ps|upgrade|config} [args...]"
    exit 1
    ;;
esac