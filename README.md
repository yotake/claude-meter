# ClaudeMeter

**[日本語 README はこちら / Japanese README](README.ja.md)**

A lightweight macOS menu bar app that shows your Claude usage in real time.

> ClaudeMeter is free. If it saves you time, you can **[sponsor development ❤️](https://github.com/sponsors/yotake)**.

## Screenshots

<p align="center">
  <img src="assets/screenshot-en.png" width="300" alt="ClaudeMeter popover (English)">
  &nbsp;&nbsp;
  <img src="assets/screenshot-ja.png" width="300" alt="ClaudeMeter popover (日本語)">
</p>

The UI follows your macOS language (Japanese / English).

## What it shows

The same numbers as **claude.ai → Settings → Usage**, right in your menu bar:

- **Current session** — 5-hour rolling window utilization, with time until reset
- **Weekly limits** — all models / Sonnet only / Opus only, with reset day
- **Codex rate limits** *(optional)* — read from your local Codex CLI logs
- **API spend** *(optional)* — this month's spend via a Claude **Admin** key
- **Multiple accounts** — track several subscriptions/keys at once

The menu bar shows the selected account's session % (e.g. `21%`), tinted by a
burn-rate forecast. Click the icon for the full breakdown.

## How it works

Polls `https://api.anthropic.com/api/oauth/usage` every 5 minutes for
subscription usage (5-hour session + 7-day limits). That endpoint requires an
**OAuth token with the `user:profile` scope**.

### Authentication

ClaudeMeter does **not** access the macOS Keychain directly (an ad-hoc–signed
app reading the Keychain can trigger antivirus warnings). Instead, you paste the
OAuth token that the `claude` CLI already manages, once, into the popover.

The pasted token is stored at
`~/Library/Application Support/ClaudeMeter/credentials.json` (mode `0600`) and
the app **auto-refreshes it** using the refresh token, so you normally never
paste again.

> **Note:** the first auto-refresh rotates the refresh token, so the `claude`
> CLI may ask you to log in again next time. After that, ClaudeMeter and the CLI
> manage tokens independently.

### Rate limits (HTTP 429)

The usage endpoint throttles aggressive polling. On a 429 the app waits the
server's `Retry-After` (+60s) and recovers automatically — don't spam refresh.

## Requirements

- macOS 13 (Ventura) or later
- A Claude **Max / Pro** subscription (required to reach the usage endpoint)
- *(build from source only)* Swift Command Line Tools — `xcode-select --install`

## Install (released DMG)

1. Download `ClaudeMeter-<version>.dmg` from
   [Releases](https://github.com/yotake/claude-meter/releases), open it, and
   drag `ClaudeMeter.app` to Applications.
2. The released build is currently **ad-hoc signed (not notarized)**, so
   Gatekeeper blocks the first launch. Allow it with any of:
   - Right-click `ClaudeMeter.app` → **Open** → **Open** in the dialog
   - **System Settings → Privacy & Security** → **Open Anyway**
   - Remove the quarantine attribute from Terminal:
     ```sh
     xattr -d com.apple.quarantine /Applications/ClaudeMeter.app
     ```
3. Click the menu bar icon and paste your token (see **Setup** below).

## Setup (token)

If you already use the `claude` CLI, copy its token to the clipboard:

```sh
security find-generic-password -s "Claude Code-credentials" -w | pbcopy
```

`security` is Apple's signed, built-in CLI. If a Keychain prompt appears, click
**Allow** (ClaudeMeter itself never touches the Keychain). Then open the
popover, paste into the field, and press **Save**. It shows
"Authenticated (auto-refresh)" and refreshes the token for you from then on.

Optional:
- Paste a Claude **Admin** key (`sk-ant-admin…`) instead to track API spend.
- Set a custom **Codex sessions folder** in Settings if your logs aren't in the
  default `~/.codex/sessions` (it also honors the `CODEX_HOME` env var).

## Build from source

```sh
./build.sh
open ClaudeMeter.app
```

## Start at login

**System Settings → General → Login Items** → add `ClaudeMeter.app`.

## Build a release

`release.sh` builds a universal (Apple Silicon + Intel) DMG into `dist/`:

```sh
./release.sh                 # ad-hoc signed DMG (Gatekeeper warns users)
```

To produce a **notarized** DMG with no Gatekeeper warning (needs an Apple
Developer Program membership), set the signing identity and notary credentials
and re-run — see the header of `release.sh` for the exact env vars:

```sh
SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="claude-meter" \
./release.sh
```

No secrets are written to the repo — credentials are read from the environment
/ login keychain at run time only.

## Support

ClaudeMeter is free and open source. If it's useful to you, a small tip via
**[GitHub Sponsors ❤️](https://github.com/sponsors/yotake)** helps cover the
Apple Developer membership and keeps it maintained.

## Caveats

- It uses a **private API** (`/api/oauth/usage`) and reads local CLI tokens/logs,
  so an Anthropic/OpenAI change can break it.
- If a token expires and you see an error, grab a fresh one (run `claude` once,
  then `security … | pbcopy` again) and re-paste via **Update token**.
