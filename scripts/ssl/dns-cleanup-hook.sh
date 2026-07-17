#!/usr/bin/env bash
# Certbot manual-cleanup hook.
# Called by certbot after a successful issuance. We clear the
# challenge_token from configs/global.yaml so the operator can remove
# the TXT record from their DNS.

set -euo pipefail

YAML_FILE="${GLOBAL_CONFIG_PATH:-/app/configs/global.yaml}"

python3 - <<PY
import os, yaml
p = os.environ.get("GLOBAL_CONFIG_PATH", "/app/configs/global.yaml")
try:
    raw = yaml.safe_load(open(p, encoding="utf-8")) or {}
    pa = raw.get("public_access") or {}
    pa["challenge_token"] = ""
    pa["challenge_domain"] = ""
    raw["public_access"] = pa
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        yaml.safe_dump(raw, f, sort_keys=False, allow_unicode=True)
    os.replace(tmp, p)
except Exception as e:
    print(f"ERROR clearing challenge: {e}", file=__import__('sys').stderr)
    raise SystemExit(1)
PY

echo "[dns-cleanup-hook] challenge cleared from ${YAML_FILE}"