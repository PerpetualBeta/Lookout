# Lookout

A native macOS menu-bar app that watches GitHub for things needing your attention — mentions, review requests, assigned issues, comments on threads you're in, and your own pull requests with failing CI.

## What it does

- Sits silently in the menu bar as a binoculars icon
- When something on GitHub needs you, the icon switches to a red-tinted filled variant and slowly pulses until you've resolved the items
- **Left-click** — opens a popover listing items grouped by repository, each with kind icon, title, and how long ago it was updated
- **Click an item** — opens it on github.com
- **Right-click** — menu with About, Refresh, Re-enter Token, Settings, Quit
- **Mark all read** in the popover footer clears unread notifications on GitHub itself (`PUT /notifications`)

Three signals are deduped into a single list:

| Source | What it covers |
|---|---|
| GitHub Notifications API | The unified feed: mentions, review requests, assigns, comments, state changes, CI activity on threads you're subscribed to |
| Search: `is:open is:pr review-requested:@me` | Open PRs requesting your review |
| Search: `is:open is:pr author:@me status:failure` | Your open PRs with failing CI |

## Installation

Two formats on every release — both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/Lookout/releases/latest/download/Lookout.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places the app in `/Applications` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/Lookout/releases/latest)** — unzip and drag `Lookout.app` to your Applications folder.

After installation, launch Lookout — a binoculars icon appears in the menu bar. On first launch a sheet asks for a GitHub Personal Access Token (see **Setup** below).

## Setup

Lookout needs a **classic** Personal Access Token. Fine-grained PATs do not work with GitHub's Notifications API and are rejected by the server.

1. Go to [github.com/settings/tokens/new](https://github.com/settings/tokens/new) and create a new token. Required scopes:
   - `notifications`
   - `repo` (or `public_repo` if you only watch public repositories)
   - `read:user`
2. Launch Lookout. On first run a sheet asks for the token. Paste it and click **Save**.
3. The token is validated against `GET /user`, then stored in your macOS Keychain (service `cc.jorviksoftware.Lookout`). It is sent only to `api.github.com`.

To replace the token later: right-click the menu-bar icon → **Re-enter GitHub Token…**

## How it works

Lookout polls GitHub at the cadence GitHub itself recommends — it reads the `X-Poll-Interval` response header (typically 60 s) and uses `If-Modified-Since` so untouched polls don't burn rate-limit budget.

It pauses on system sleep and resumes — with an immediate refresh — on wake.

The three sources run concurrently on each poll. Items are deduped by URL, sorted by recency, and grouped by repository in the popover.

## Day-to-day use

| Action | Result |
|---|---|
| Left-click binoculars | Open the items popover |
| Right-click binoculars | Open the standard Jorvik menu |
| Click an item row | Open it on github.com |
| Refresh button (popover header) | Force an immediate poll |
| Mark all read (popover footer) | Mark every GitHub notification as read |

## Settings

Right-click the icon → **Settings…** for:

- **Menu Bar Icon** — toggle the always-visible grey background pill
- **General** — Launch at Login
- **Updates** — check interval (daily / weekly / monthly / never), auto-install toggle, manual *Check Now*

## Privacy

- No telemetry. No analytics. No ads. No subscriptions.
- The PAT lives in your macOS Keychain and is never written to disk in plain text.
- Network traffic goes only to `api.github.com`.

## Building from source

Lookout is a Swift app with no dependencies beyond macOS system frameworks. No Xcode project is required.

```bash
cd ~/Desktop/Lookout
./build.sh
open Lookout.app
```

The build script generates the `.icns` from `generate_icon.swift`, compiles the Swift sources with `swiftc`, links against Cocoa, SwiftUI, ServiceManagement, and Security, then signs the bundle with the Developer ID identity.

## Architecture

| File | Purpose |
|---|---|
| `main.swift` | `AppDelegate`; owns the `NSStatusItem`, popover, right-click menu, and edit-menu plumbing for paste in the setup sheet |
| `LookoutCore.swift` | Observable polling engine; manages sleep/wake, error states, retry timing |
| `LookoutGitHub.swift` | Actor-isolated client for GitHub's API; three concurrent sources, deduped by URL, surfaces detailed error messages from `validate()` |
| `LookoutKeychain.swift` | PAT storage in macOS Keychain (service `cc.jorviksoftware.Lookout`, account `github-pat`) |
| `LookoutPanel.swift` | SwiftUI popover content; grouped list, empty / error / unconfigured states |
| `LookoutSetup.swift` | Token entry sheet; validates against `GET /user` before saving |
| `JorvikKit/` | Shared About, Settings, menu-bar pill (canonical), update checker, window helper |

### Icon

Generated by `generate_icon.swift` (`swift generate_icon.swift <output-dir>`). Draws using Core Graphics: brand-blue rounded-rect background with a subtle radial gradient, a watchful-eye motif (almond outline, iris ring, soft inner ring, filled pupil), and four cardinal tick marks beyond the eye. Outputs all 10 required PNG sizes; `iconutil` then assembles them into `AppIcon.icns`.

## Requirements

- macOS 14.0 (Sonoma) or later
- A GitHub classic Personal Access Token (see **Setup**)
- For building from source: Swift command-line tools and an Apple developer certificate for code signing

---

Lookout is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
