#!/usr/bin/env bash
# Creates the data directories defined in LOKI_DATA_DIR / GRAFANA_DATA_DIR
# and fixes ownership for the in-container users.
#   - Loki:    uid:gid 10001:10001
#   - Grafana: uid:gid 472:0
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

ensure_dir() {
  local dir="$1"
  local uid="$2"
  local gid="$3"

  mkdir -p "$dir"
  local current_uid
  current_uid="$(stat -c '%u' "$dir")"
  if [[ "$current_uid" != "$uid" ]]; then
    if [[ "$EUID" -eq 0 ]]; then
      chown -R "${uid}:${gid}" "$dir"
    else
      sudo chown -R "${uid}:${gid}" "$dir"
    fi
  fi
  echo "✓ ${dir} (owner ${uid}:${gid})"
}

ensure_dir "${LOKI_DATA_DIR:-./data/loki}" 10001 10001

if [[ "${COMPOSE_FILE:-}" == *grafana* ]]; then
  ensure_dir "${GRAFANA_DATA_DIR:-./data/grafana}" 472 0
fi
