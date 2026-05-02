# Lookout

A native macOS menu-bar app that watches GitHub for things needing your attention — mentions, review requests, assigned issues, comments on threads you're in, and your own pull requests with failing CI.

A binoculars sits in your menu bar. When something needs you, a number appears. Click it for the list. Click a row to open it in your browser. That's the app.

## What it watches

Three signals, deduped into a single list:

- **GitHub Notifications** — the unified feed (mentions, review requests, assigns, comments, state changes, CI activity on threads you're subscribed to).
- **Open PRs requesting your review** — `is:open is:pr review-requested:@me`.
- **Your open PRs with failing CI** — `is:open is:pr author:@me status:failure`.

Items are grouped by repository in the panel. Each row shows a kind icon, the title, and how long ago it was updated.

## Setup

1. Create a **classic** Personal Access Token at [github.com/settings/tokens/new](https://github.com/settings/tokens/new) — fine-grained PATs do not work with GitHub's Notifications API and are rejected. Required scopes:
   - `notifications`
   - `repo` (or `public_repo` if you only watch public repositories)
   - `read:user`
2. Launch Lookout. On first run a sheet asks for the token. Paste it and click **Save**.
3. The token is validated against `GET /user` and stored in your macOS Keychain (service `cc.jorviksoftware.Lookout`). It is sent only to `api.github.com`.

## How polling works

Lookout polls GitHub at the cadence GitHub itself recommends — it reads the `X-Poll-Interval` response header (typically 60 s) and uses `If-Modified-Since` so untouched polls don't burn rate-limit budget.

It pauses on system sleep and resumes — with an immediate refresh — on wake.

## Right-click menu

- **About Lookout**
- **Refresh** — force a poll now
- **Re-enter GitHub Token…** — replace the stored token
- **Settings…** — menu-bar pill toggle, Launch at Login, update checker
- **Quit Lookout**

## Privacy

- No telemetry. No analytics. No ads. No subscriptions.
- The PAT lives in your Keychain and is never written to disk in plain text.
- Network traffic goes only to `api.github.com`.

## Build

```sh
./build.sh
```

Produces `Lookout.app`, signed with Developer ID `EG86BCGUE7`.

## Licence

Public Domain — No Rights Reserved.
