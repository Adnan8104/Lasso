#!/bin/bash
# Signals that work resumed after a permission/approval step. Produces no stdout.
set -u
runtime_dir="${LASSO_RUNTIME_DIR:-$HOME/.lasso}"
mkdir -p "$runtime_dir"
if [ -f "$runtime_dir/.awaiting" ]; then
  rm -f "$runtime_dir/.awaiting" >/dev/null 2>&1
  input=$(cat)
  sid=$(printf '%s' "$input" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
  printf '%s' "$sid" > "$runtime_dir/.switch-away" 2>/dev/null
fi
