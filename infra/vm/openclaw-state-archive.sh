#!/usr/bin/env bash
set -euo pipefail

ACCOUNT_NAME="${ACCOUNT_NAME:-openclaw96c9db66}"
CONTAINER_NAME="${CONTAINER_NAME:-openclaw-state-archives}"
STATE_DIR="${STATE_DIR:-/data/openclaw/.openclaw}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="/tmp/openclaw-state-${STAMP}.tar.gz"
BLOB_NAME="${STAMP}/openclaw-state.tar.gz"

if [ ! -d "$STATE_DIR" ]; then
  echo "State directory not found: $STATE_DIR" >&2
  exit 1
fi

/usr/bin/az login --identity --allow-no-subscriptions >/dev/null
/usr/bin/az storage container create \
  --name "$CONTAINER_NAME" \
  --account-name "$ACCOUNT_NAME" \
  --auth-mode login \
  --public-access off \
  --only-show-errors >/dev/null

tar -C "$(dirname "$STATE_DIR")" -czf "$ARCHIVE" "$(basename "$STATE_DIR")"
/usr/bin/az storage blob upload \
  --account-name "$ACCOUNT_NAME" \
  --container-name "$CONTAINER_NAME" \
  --name "$BLOB_NAME" \
  --file "$ARCHIVE" \
  --auth-mode login \
  --only-show-errors >/dev/null

rm -f "$ARCHIVE"
