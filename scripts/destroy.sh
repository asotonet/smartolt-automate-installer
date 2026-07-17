#!/usr/bin/env bash
# Deprecated: use ./smartolt.sh destroy
exec "$(dirname "$0")/../smartolt.sh" destroy "$@"
