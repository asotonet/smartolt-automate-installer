#!/usr/bin/env bash
# Certbot manual-auth hook for DNS-01.
#
# Reads the TXT record from configs/public_access.yaml (populated by the
# web admin endpoint) and asks the operator to create the record before
# certbot continues.
#
# The web tier writes a `challenge_token` field into configs/global.yaml
# when the user clicks "Start issuance". That field is the value that
# needs to be set as a TXT on `_acme-challenge.<domain>`.
#
# This hook:
#   1. Reads the pending challenge_token + domain from the YAML.
#   2. Echoes a clear instruction to the operator (this is what certbot
#      captures into its log).
#   3. Waits until the TXT resolves (poll every 10s, max 5 min).
#   4. Returns 0 on success, non-zero on timeout.

set -euo pipefail

YAML_FILE="${GLOBAL_CONFIG_PATH:-/app/configs/global.yaml}"
DOMAIN="${CERTBOT_DOMAIN:-}"
echo "[dns-auth-hook] domain=${DOMAIN}"

if [ -z "${DOMAIN}" ]; then
  echo "[dns-auth-hook] CERTBOT_DOMAIN is empty" >&2
  exit 1
fi

# Certbot passes the domain without the leading underscore.
CHALLENGE_HOST="_acme-challenge.${DOMAIN}"

# Read the token from the YAML (python because we already have it in the image).
TOKEN=$(python3 - <<PY
import os, yaml
p = os.environ.get("GLOBAL_CONFIG_PATH", "/app/configs/global.yaml")
try:
    raw = yaml.safe_load(open(p, encoding="utf-8")) or {}
    pa = raw.get("public_access") or {}
    print(pa.get("challenge_token", ""))
except Exception as e:
    print(f"ERROR: {e}", file=__import__('sys').stderr)
    raise SystemExit(1)
PY
)

if [ -z "${TOKEN}" ]; then
  echo "[dns-auth-hook] challenge_token is empty in ${YAML_FILE}" >&2
  exit 1
fi

echo
echo "================================================================"
echo "  DNS-01 challenge required"
echo "  Add this TXT record to your DNS provider BEFORE continuing:"
echo
echo "    Host: ${CHALLENGE_HOST}"
echo "    Type: TXT"
echo "    Value: ${TOKEN}"
echo
echo "  TTL: 60 seconds (lower = faster)"
echo "  After saving, this script will verify the TXT propagates."
echo "================================================================"
echo

# Poll until visible (max 5 min).
DEADLINE=$((SECONDS + 300))
while [ "${SECONDS}" -lt "${DEADLINE}" ]; do
  if command -v dig >/dev/null 2>&1; then
    OBSERVED=$(dig +short TXT "${CHALLENGE_HOST}" @1.1.1.1 | tr -d '"' || true)
  elif command -v nslookup >/dev/null 2>&1; then
    OBSERVED=$(nslookup -type=TXT "${CHALLENGE_HOST}" 1.1.1.1 2>/dev/null | awk -F'"' '/text =/ {print $2; exit}')
  else
    echo "[dns-auth-hook] Neither dig nor nslookup available" >&2
    exit 1
  fi

  if [ "${OBSERVED}" = "${TOKEN}" ]; then
    echo "[dns-auth-hook] TXT record visible. Proceeding with certbot."
    exit 0
  fi
  echo "[dns-auth-hook] waiting for TXT propagation... (got='${OBSERVED}')"
  sleep 10
done

echo "[dns-auth-hook] timed out waiting for ${CHALLENGE_HOST}" >&2
exit 1