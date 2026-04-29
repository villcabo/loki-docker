#!/usr/bin/env bash
# Crea el directorio de datos definido en LOKI_DATA_DIR (o el default).
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

LOKI_DATA_DIR="${LOKI_DATA_DIR:-./data/loki}"

mkdir -p "$LOKI_DATA_DIR"
echo "✓ ${LOKI_DATA_DIR}"
