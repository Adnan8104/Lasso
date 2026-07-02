#!/bin/bash
# Signals that user attention is needed, then marks the next resume. Produces no stdout.
set -u
runtime_dir="${LASSO_RUNTIME_DIR:-$HOME/.lasso}"
mkdir -p "$runtime_dir"
input=$(cat)
if printf '%s' "$input" | grep -qiE 'permission|approve|allow|confirm'; then
  sid=$(printf '%s' "$input" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
  printf '%s' "$sid" > "$runtime_dir/.switch-back" 2>/dev/null
  touch "$runtime_dir/.awaiting" >/dev/null 2>&1
fi
