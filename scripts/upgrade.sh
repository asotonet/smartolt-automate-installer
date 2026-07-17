#!/usr/bin/env bash
# Deprecated: use ./smartolt.sh upgrade [version]
exec "$(dirname "$0")/../smartolt.sh" upgrade "$@"
