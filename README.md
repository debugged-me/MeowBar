# MeowBar

Your AI usage, at a glance — a tiny native macOS menu bar app that shows how much
of your **Claude Code** and **Codex** limits you have left.

![MeowBar popover](preview.png)

## Why

Claude and Codex rate-limit you on hidden 5-hour and weekly windows. MeowBar puts
those numbers where they belong: always visible, always fresh, zero setup.

## Features

- **No accounts, no API keys** — reads the credentials your CLI tools already
  stored on your Mac (Keychain for Claude, `codex app-server` JSON-RPC for Codex)
- **The icon is the meter** — brand icons fill bottom-up with usage; text turns
  into short status words (`running`, `task done`, `nearing limit`, `limit
  reached`) that auto-clear
- **Always-fresh Claude** — optional status-line bridge: Claude Code pushes its
  limits on every render, zero API polling, no 429s (Settings → Claude)
- **Self-healing sign-in** — when the Claude token expires and refresh fails,
  MeowBar launches `claude` briefly so it renews itself; error states carry
  action buttons (`Run codex login in Terminal`, `Open Devin`, …)
- **Pace verdicts** — `plenty left` / `comfortable` / `cutting it close` /
  `hit limit in …` projected from the window's burn rate
- **Popover detail** — plan name (`Plus`, `Pro · unlimited`), session + weekly
  bars in brand colors, reset countdowns; drag it off the bar to detach into a
  floating window
- **Positions** — sit on the right with the other icons or float center-top as
  an "island" under the notch (Settings → Position)
- **Display modes** — % left or countdown-to-reset in the bar
- **Optional third provider** — Devin quota when the Devin IDE is signed in;
  hidden entirely otherwise
- **Configurable alerts** — macOS notifications at 75 / 90 / 95% and on window
  reset, each toggleable in Settings
- **Polite** — Liquid Glass popover, dismisses on any key or outside click
- **Persistent** — launch-at-login toggle in Settings
- **Featherweight** — native Swift, ~100 MB RAM, 0% CPU idle

## Install

1. Download `MeowBar.dmg`, open it, drag **MeowBar** to **Applications**
2. Launch it — macOS warns once since it's ad-hoc signed:
   right-click → **Open** (or System Settings → Privacy & Security → Open Anyway)
3. Allow the one-time **Keychain prompt** (choose *Always Allow*) so it can read
   your Claude credentials

## Requirements

- macOS 14+, Apple Silicon
- Signed in to `claude` and/or `codex` on that Mac (Claude needs a Pro/Max
  subscription login — pure API-key users have no OAuth credential to read)

## Privacy

No analytics, no telemetry, no accounts. The only network calls are the same
usage endpoints your CLI tools already hit. Credentials never leave the keychain
paths macOS already protects.

## Build

```sh
./build.sh   # → build/MeowBar.app + build/MeowBar.dmg (and ./MeowBar.dmg for the site)
```

Single `swiftc` invocation — no Xcode project, no dependencies.

## Files

```
MeowBar/Sources/main.swift            app, menu bar, island panel, alert engine
MeowBar/Sources/UsageService.swift    credentials, providers, statusline bridge
MeowBar/Sources/PopoverView.swift     popover UI
MeowBar/Sources/SettingsView.swift    settings window
MeowBar/Sources/statusline/main.swift meowbar-statusline helper (Claude bridge)
index.html                            landing page (self-contained, pairs with MeowBar.dmg)
```
