# Install Lasso

Lasso is currently a Hammerspoon-based macOS prototype.

## Setup

1. Install Hammerspoon from https://www.hammerspoon.org/.
2. Clone this repo.
3. Run:

```bash
./install.sh
```

4. Open Hammerspoon and grant Accessibility permission when macOS asks.
5. Use the menu-bar lasso to pick your away app, return app, delay, and optional chat detection.

## Connecting a Tool

Any local tool that can run shell commands on lifecycle events can use Lasso:

- task submitted: `~/.lasso/adapters/submit.sh`
- task finished: `~/.lasso/adapters/done.sh`
- attention/permission needed: `~/.lasso/adapters/permission.sh`
- work resumed after permission: `~/.lasso/adapters/resume.sh`

The adapters also accept JSON on stdin. If the JSON includes a `session_id`, Lasso can return to the exact window/session that started the task.

## Manual Test

```bash
echo '{"session_id":"demo"}' | ~/.lasso/adapters/submit.sh
sleep 3
echo '{"session_id":"demo"}' | ~/.lasso/adapters/done.sh
```
