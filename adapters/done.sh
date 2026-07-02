#!/bin/bash
# Signals that a task finished. Produces no stdout.
set -u
runtime_dir="${LASSO_RUNTIME_DIR:-$HOME/.lasso}"
mkdir -p "$runtime_dir"
input=$(cat)
sid=$(printf '%s' "$input" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
printf '%s' "$sid" > "$runtime_dir/.switch-back" 2>/dev/null
