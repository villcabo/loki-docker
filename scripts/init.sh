#!/usr/bin/env bash
# Creates the data directory defined in LOKI_DATA_DIR (or the default) and
# fixes ownership for Loki's in-container user (uid:gid 10001:10001).
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

LOKI_DATA_DIR="${LOKI_DATA_DIR:-./data/loki}"
LOKI_UID=10001
LOKI_GID=10001

mkdir -p "$LOKI_DATA_DIR"

current_uid="$(stat -c '%u' "$LOKI_DATA_DIR")"
if [[ "$current_uid" != "$LOKI_UID" ]]; then
  if [[ "$EUID" -eq 0 ]]; then
    chown -R "${LOKI_UID}:${LOKI_GID}" "$LOKI_DATA_DIR"
  else
    sudo chown -R "${LOKI_UID}:${LOKI_GID}" "$LOKI_DATA_DIR"
  fi
fi

echo "✓ ${LOKI_DATA_DIR} (owner ${LOKI_UID}:${LOKI_GID})"
