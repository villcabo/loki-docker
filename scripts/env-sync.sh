#!/usr/bin/env bash
# Sync .env with .env.example — safely merge new variables without losing
# the values you've already overridden.
#
# SAFETY FIRST: by default the script computes the merge in a temp file,
# SHOWS YOU A DIFF, and asks for confirmation before replacing .env. Nothing
# is written to .env unless you type "y".
#
# Behavior:
#   First run (no .env):   copies .env.example → .env as-is (all vars commented).
#                          You then uncomment what you want to override.
#                          No confirmation needed.
#
#   Subsequent runs:       walks .env.example line-by-line. For each `KEY=value`
#                          line it finds in the template:
#                            - if the user already has KEY uncommented in .env,
#                              keep the user's value unchanged
#                            - otherwise, copy the line from .env.example
#                              (which is normally commented)
#                          Orphaned keys (in your .env but NOT in .env.example)
#                          are preserved at the bottom of the file with a
#                          warning header so you notice and clean them up.
#                          A diff is shown; you must confirm [y/N] before apply.
#
# The existing .env is backed up to .env.bak.<timestamp> on every apply.
# Backups are gitignored.
#
# Usage (from the project root):
#   bash scripts/env-sync.sh            # interactive (diff + confirm)
#   bash scripts/env-sync.sh -y         # non-interactive (CI, scripts)
#   bash scripts/env-sync.sh --yes      # same as -y
set -uo pipefail

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,/^set/p' "$0" | sed 's/^# \?//' | sed '$d'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [-y|--yes] [-h|--help]" >&2
      exit 2
      ;;
  esac
done

cd "$(dirname "$0")/.."

EXAMPLE=".env.example"
TARGET=".env"

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()    { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
warn()  { printf "  ${YELLOW}!${NC} %s\n" "$1"; }
bad()   { printf "  ${RED}✗${NC} %s\n" "$1" >&2; }
info()  { printf "\n${BOLD}%s${NC}\n" "$1"; }

if [ ! -f "$EXAMPLE" ]; then
  bad "$EXAMPLE not found (run from the project root or via scripts/env-sync.sh)"
  exit 1
fi

# ── First-time setup ────────────────────────────────────────────────────────
if [ ! -f "$TARGET" ]; then
  cp "$EXAMPLE" "$TARGET"
  info "First-time setup"
  ok "created $TARGET from $EXAMPLE"
  echo
  printf "  Next step: open ${BOLD}$TARGET${NC} and uncomment the variables you want\n"
  printf "  to override from the defaults baked into the compose files.\n"
  exit 0
fi

# ── Merge mode ──────────────────────────────────────────────────────────────
info "Syncing $TARGET from $EXAMPLE"

# Collect user's CURRENT uncommented keys and their values.
user_keys=()
user_vals=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|\#*) continue ;;                         # blank / comment → skip
  esac
  if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    user_keys+=("${BASH_REMATCH[1]}")
    user_vals+=("${BASH_REMATCH[2]}")
  fi
done < "$TARGET"

lookup_user_value() {
  local key="$1" i
  for i in "${!user_keys[@]}"; do
    if [ "${user_keys[$i]}" = "$key" ]; then
      echo "${user_vals[$i]}"
      return 0
    fi
  done
  return 1
}

# Collect all known keys from .env.example (both commented and uncommented).
#
# IMPORTANT: only match lines where the var is at column 0, optionally
# preceded by "# " (single space). This avoids picking up PROSE EXAMPLES
# inside comment blocks like "#   COMPOSE_FILE=docker-compose.yml:..." which
# are indented with multiple spaces.
DECL_RE='^#? ?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'

template_keys=()
while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ $DECL_RE ]]; then
    template_keys+=("${BASH_REMATCH[1]}")
  fi
done < "$EXAMPLE"

key_in_template() {
  local key="$1" k
  for k in "${template_keys[@]}"; do
    [ "$k" = "$key" ] && return 0
  done
  return 1
}

# Build new .env by walking the template.
tmp=$(mktemp)
preserved=0
written_keys=()

key_already_written() {
  local key="$1" k
  for k in "${written_keys[@]}"; do
    [ "$k" = "$key" ] && return 0
  done
  return 1
}

while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ $DECL_RE ]]; then
    key="${BASH_REMATCH[1]}"
    if key_already_written "$key"; then
      continue
    fi
    written_keys+=("$key")
    if user_val=$(lookup_user_value "$key"); then
      echo "${key}=${user_val}" >> "$tmp"
      preserved=$((preserved + 1))
    else
      echo "$line" >> "$tmp"
    fi
  else
    echo "$line" >> "$tmp"
  fi
done < "$EXAMPLE"

# Append orphaned keys (in .env but NOT in template) to the bottom
orphans=()
for key in "${user_keys[@]}"; do
  if ! key_in_template "$key"; then
    orphans+=("$key")
  fi
done

if [ "${#orphans[@]}" -gt 0 ]; then
  {
    echo ""
    echo "# ─────────────────────────────────────────────────────────────────"
    echo "# ORPHANED keys — these are in your .env but no longer in .env.example."
    echo "# They might be leftover from an older version. Review and delete if"
    echo "# they're no longer needed."
    echo "# ─────────────────────────────────────────────────────────────────"
    for key in "${orphans[@]}"; do
      val=$(lookup_user_value "$key")
      echo "${key}=${val}"
    done
  } >> "$tmp"
fi

# ── Diff + confirm ──────────────────────────────────────────────────────────
new_keys=0
for k in "${template_keys[@]}"; do
  if ! lookup_user_value "$k" >/dev/null; then
    new_keys=$((new_keys + 1))
  fi
done

info "Proposed changes"
printf "  preserved:  ${BOLD}%d${NC} user override(s)\n" "$preserved"
printf "  new keys:   ${BOLD}%d${NC} template key(s) available (commented)\n" "$new_keys"
if [ "${#orphans[@]}" -gt 0 ]; then
  printf "  orphaned:   ${BOLD}${YELLOW}%d${NC} key(s) moved to bottom — review them\n" "${#orphans[@]}"
  for key in "${orphans[@]}"; do
    printf "              - %s\n" "$key"
  done
fi

if cmp -s "$TARGET" "$tmp"; then
  echo
  ok "no changes — .env is already in sync with .env.example"
  rm -f "$tmp"
  exit 0
fi

info "Diff (current .env → proposed .env)"
if command -v diff >/dev/null 2>&1; then
  if [ -t 1 ] && command -v git >/dev/null 2>&1; then
    git --no-pager diff --no-index --color=always "$TARGET" "$tmp" 2>/dev/null | tail -n +5 || true
  else
    diff -u "$TARGET" "$tmp" | sed 's/^/  /' || true
  fi
else
  echo "  (diff command not available — skipping preview)"
fi

if [ "$ASSUME_YES" != "1" ]; then
  echo
  printf "${BOLD}Apply these changes?${NC} [y/N] "
  read -r answer </dev/tty || answer=""
  case "$answer" in
    y|Y|yes|YES)
      ;;
    *)
      printf "\n${YELLOW}Aborted — .env left untouched.${NC}\n"
      rm -f "$tmp"
      exit 0
      ;;
  esac
fi

# ── Apply ───────────────────────────────────────────────────────────────────
backup="${TARGET}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$TARGET" "$backup"
mv "$tmp" "$TARGET"

info "Applied"
ok "backup saved to $backup"
printf "\n${GREEN}${BOLD}Sync complete.${NC}\n"
