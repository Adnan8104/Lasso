#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.hammerspoon" "$HOME/.lasso" "$HOME/.lasso/adapters"
cp "$root/hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua"
cp "$root/lasso.svg" "$HOME/.hammerspoon/lasso.svg"
cp "$root/lasso-off.svg" "$HOME/.hammerspoon/lasso-off.svg"
cp "$root/adapters/"*.sh "$HOME/.lasso/adapters/"
chmod +x "$HOME/.lasso/adapters/"*.sh
cat > "$HOME/.lasso/config.json" <<'JSON'
{
  "enabled": true,
  "awayApp": "Google Chrome",
  "returnApp": "Terminal",
  "chatApp": "Assistant",
  "delay": 1.5,
  "chatDetect": false,
  "debug": false
}
JSON
if command -v hs >/dev/null 2>&1; then
  hs -c 'hs.reload()' >/dev/null 2>&1 || true
fi
printf 'Lasso installed. Open Hammerspoon and grant Accessibility permission if macOS asks.\n'
printf 'Runtime: ~/.lasso\nAdapters: ~/.lasso/adapters\n'
