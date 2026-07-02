<p align="center">
  <img src="app-icon.svg" width="160" alt="Lasso app logo">
</p>

<h1 align="center">Lasso</h1>

<p align="center">A lightweight macOS focus router for long-running work.</p>

---

Lasso is a small macOS menu-bar prototype that routes focus away while a long-running task is working, then brings you back when attention is needed again.

## What It Does

- Sends focus to a chosen away app after a task starts.
- Returns to the original window when the task finishes.
- Supports per-session return when adapters provide a `session_id`.
- Includes optional desktop chat detection through macOS Accessibility.

## Install

Requires macOS and [Hammerspoon](https://www.hammerspoon.org/).

```bash
git clone https://github.com/Adnan8104/Lasso.git
cd Lasso
./install.sh
```

Then open Hammerspoon and grant Accessibility permission if macOS asks.

## Use With Any Hookable Tool

Point your tool's lifecycle hooks at the adapter scripts installed in `~/.lasso/adapters/`:

- `submit.sh` when a task starts
- `done.sh` when a task finishes
- `permission.sh` when user attention is needed
- `resume.sh` after an attention step resumes

More detail is in `docs/install.md`.

## Files

- `hammerspoon/init.lua` - Hammerspoon runtime.
- `adapters/` - generic shell adapters.
- `install.sh` - local installer.
- `app-icon.svg`, `lasso.svg`, `lasso-off.svg` - app and menu-bar icons.
