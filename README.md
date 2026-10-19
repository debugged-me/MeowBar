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
  `may run out in ~…` — a rounded guess from the window's burn rate, silent until there's enough signal, plus an even-pace
  marker on every bar (fill past the tick = ahead of pace)
- **Auto-started session clock** — Claude's 5-hour window only opens on your
  first message; when it's idle and you're at your Mac, MeowBar opens it with
  a one-word Haiku prompt so the reset comes sooner (Settings → Claude)
- **History** — click a provider's name for its last 7 days and busiest hours,
  kept locally for 8 days
- **Never blank** — last-good numbers are cached on disk; a relaunch or rate
  limit shows them (with their age) instead of an error, and repeated 429s
  back off exponentially
- **A cat** — naps when nothing's running, trots while an agent works,
  startles near a limit (holds still with Reduce Motion)
- **Global shortcut** — ⌃⌥M opens the popover from anywhere (configurable)
- **Scriptable** — `MeowBar.app/Contents/MacOS/MeowBar --json` prints the
  cached numbers for shell prompts and scripts
- **Popover detail** — plan name (`Plus`, `Pro · unlimited`), session + weekly
  bars in brand colors, reset countdowns
- **Positions** — sit on the right with the other icons or float center-top as
  an "island" under the notch (Settings → Position)
- **Display modes** — % left or countdown-to-reset in the bar
- **Optional third provider** — Devin quota when the Devin IDE is signed in;
  hidden entirely otherwise
- **Configurable alerts** — macOS notifications at 75 / 90 / 95% and on window
  reset, each toggleable in Settings; near a limit they point at the other
  tool if it has headroom ("Codex has 70% left")
- **Update check** — once a day against `version.json` next to the DMG (set
  `MeowBarUpdateURL` in `Info.plist`; empty = off)
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
./build.sh   # → build/MeowBar.app + build/MeowBar.dmg (+ ./MeowBar.dmg, ./version.json for the site)
swift test   # unit tests for the pure logic in MeowBar/Sources/Core
```

Plain `swiftc` — no Xcode project, no dependencies. `Package.swift` exists only
for the tests.

Signing is ad-hoc by default. With an Apple Developer ID:

```sh
xcrun notarytool store-credentials meowbar          # once
MEOWBAR_SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
MEOWBAR_NOTARY_PROFILE=meowbar ./build.sh            # signed, notarized, stapled DMG
```

To ship an update: bump `CFBundleShortVersionString` in `Info.plist`, build,
and upload `MeowBar.dmg` + `version.json` side by side.

## Files

```
MeowBar/Sources/main.swift            app, menu bar, island panel, alert engine, store
MeowBar/Sources/UsageService.swift    credentials, providers, statusline bridge, session clock
MeowBar/Sources/PopoverView.swift     popover UI, history strip, cat
MeowBar/Sources/SettingsView.swift    settings window
MeowBar/Sources/OnboardingView.swift  first-launch window
MeowBar/Sources/AppSupport.swift      on-disk cache/history, --json, update check
MeowBar/Sources/HotKey.swift          global shortcut
MeowBar/Sources/Core/                 pure logic (models, pace, history, clock) — unit-tested
Tests/MeowBarCoreTests/               swift test
MeowBar/Sources/statusline/main.swift meowbar-statusline helper (Claude bridge)
index.html                            landing page (self-contained, pairs with MeowBar.dmg)
```
