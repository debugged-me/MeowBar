# MeowBar

A macOS menu bar app that shows your Claude Code and Codex usage limits at a glance —
a personal, self-built alternative to Purrlet. No license, no account, no analytics.
Everything stays on your Mac.

macOS 14+ (built and tested on arm64).

## What it does

- Lives in the menu bar as `🐱 <max session %>` — no Dock icon (`LSUIElement`).
- Click the cat → popover showing, per provider (Claude / Codex):
  - **Session (5-hour) limit**: progress bar, % used, % left, reset countdown
  - **Weekly limit**: same
  - **Pace**: compares elapsed fraction of the window vs. used fraction and says
    whether you're on track or will hit the limit early
- Refreshes every 60 seconds (also on popover open).
- Notifications at 75%, 90%, 95% and when a limit resets.
- Quit button in the popover footer.

## Data sources (no accounts, no API keys)

### Claude Code
- OAuth credentials live in the macOS Keychain, service `Claude Code-credentials`
  (same place Purrlet reads — first launch shows a one-time Keychain prompt).
- The item is JSON: `{ claudeAiOauth: { accessToken, refreshToken, expiresAt, … } }`.
- If `accessToken` is expired → refresh via
  `POST https://api.anthropic.com/v1/oauth/token`
  body `{ client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e", grant_type: "refresh_token", refresh_token }`.
- Usage: `GET https://api.anthropic.com/api/oauth/usage`
  headers `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`.
  Response: `five_hour.utilization / resets_at`, `seven_day.utilization / resets_at`.
- If refresh is blocked or fails: show "run `claude` once to refresh credentials".

### Codex (ChatGPT sign-in)
- Reads `~/.codex/auth.json` → `tokens.access_token` (JWT) + `tokens.account_id`.
- Usage: `GET https://chatgpt.com/backend-api/wham/usage`
  headers `Authorization: Bearer <token>`, `ChatGPT-Account-Id: <account_id>`.
  Response: `rate_limit.primary_window` (5h) and `secondary_window` (7d):
  `used_percent`, `limit_window_seconds`, `reset_after_seconds`, `reset_at`.
- If the JWT is expired (401): show "run `codex` once to refresh credentials".

## Project layout

```
MeowBar/
  PLAN.md                 ← this file
  build.sh                ← swiftc compile → .app bundle → ad-hoc codesign
  MeowBar/
    Info.plist            ← LSUIElement=1, bundle id com.meowbar.app
    Sources/
      main.swift          ← NSApplication setup + AppDelegate + status item
      UsageService.swift  ← credential loading, refresh, usage endpoints, models
      PopoverView.swift   ← SwiftUI popover content
  build/MeowBar.app       ← output (gitignored)
```

## Build & install

```sh
./build.sh                       # produces build/MeowBar.app
cp -R build/MeowBar.app /Applications/
open /Applications/MeowBar.app   # right-click → Open on first launch (unsigned)
```

## Known limitations vs Purrlet

- No onboarding tour, no themes, English only.
- Token refresh for Claude depends on Anthropic's OAuth endpoint accepting the
  request; if it ever fails, run `claude` once and the app picks up fresh creds.
- Notifications require granting permission on first alert.
