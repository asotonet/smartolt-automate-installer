#!/usr/bin/env bash
# Deprecated: use ./smartolt.sh {status|deploy|logs}
CMD="${1:-status}"
shift || true
case "$CMD" in
  pull|up|down|restart|ps|config|status|logs|deploy)
    exec "$(dirname "$0")/../smartolt.sh" "$CMD" "$@" ;;
  upgrade)
    exec "$(dirname "$0")/../smartolt.sh" upgrade "$@" ;;
  *)
    echo "Deprecated: use ./smartolt.sh (subcommand: status|deploy|logs|upgrade|...)" >&2
    exit 1 ;;
esac
