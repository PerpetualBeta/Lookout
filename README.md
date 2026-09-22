# Lookout

A native macOS menu-bar app that watches GitHub for things needing your attention — mentions, review requests, assigned issues, comments on threads you're in, your own pull requests with failing CI, and anything opened on a repo you own.

## What it does

- Sits silently in the menu bar as a binoculars icon
- When something on GitHub needs you, the icon switches to a red-tinted filled variant and slowly pulses until you've resolved the items
- **Left-click** — opens a popover listing items grouped by repository, each with kind icon, title, and how long ago it was updated
- **Click an item** — opens it on github.com
- **Right-click** — menu with About, Refresh, Re-enter Token, Check for Updates…, Settings, Quit
- **Mark all read** in the popover footer clears unread notifications on GitHub itself (`PUT /notifications`)

Five signals are deduped into a single list, by URL:

| Source | What it covers |
|---|---|
| GitHub Notifications API | The unified feed: mentions, review requests, assigns, comments, state changes, CI activity on threads you're subscribed to |
| Search: `is:open is:pr review-requested:@me` | Open PRs requesting your review |
| Search: `is:open is:pr author:@me status:failure` | Your open PRs with failing CI |
| Search: `is:open user:<you>` — issues **and** pull requests | Anything open on a repo **you own**, regardless of whether you watch it, at any age |
| GraphQL search: `is:open user:<you>`, `type: DISCUSSION` | Open discussions on a repo **you own**. Needs GraphQL: the REST search endpoint does not index discussions |

### Why that last row exists

The notifications inbox only fires for repos you are **subscribed** to, and owning a repo does not
subscribe you to it. Open something on a repo you own but do not watch and GitHub tells you nothing —
so Lookout, reading only the inbox, told you nothing either.

That was fixed for issues, and then **not** for pull requests, because GitHub's `is:issue` search
qualifier *excludes* PRs. A pull request opened by someone else on your own repo therefore matched
nothing at all: no review requested of you, not authored by you, excluded from the owned-repo search,
and no notification because you do not watch your own repo. Three open PRs on QuitProtect sat unseen
for three days.

Then it happened a third time, to **discussions**. A discussion is neither an issue nor a pull
request, and the REST search endpoint the two rows above use does not index discussions at all, so no
query string could have reached them. Seven discussions on Save Cannes, opened over two days, sat
unanswered with nothing in the notifications inbox for any of them. That row needs GraphQL, which is
the only GraphQL call in the app.

All three are now covered.

Owned-repo results, discussions included, are kept only if the **last person to act wasn't you** — a new thread qualifies,
and it drops off once you reply, until the other party responds again.

Reacting counts as acting. A thread whose last comment you have reacted to — any reaction, not just a
thumbs-up — is not one waiting on you, and drops off the same way a reply would. Without this an
answered report reported itself for ever: the other party's "thanks, will do" stays the last comment
permanently, so the thread could never clear except by closing the issue, which is wrong when you are
legitimately waiting on them. It corrects itself, which is what makes it safe — the moment they
comment again, the newest comment carries no reaction of yours and the thread returns. The reactions
of a comment are only looked up when the comment reports having some, so a thread nobody has reacted
to costs no extra request.

Discussions apply that same rule with one deliberate difference: the reaction test looks at whatever
was said **last**, which for a discussion with no replies is the opening post itself. An issue is a
body followed by a conversation, so its last comment is the right place to look; a discussion is very
often nothing but its opening post, and a reaction to that post is how you acknowledge it. A
discussion also drops off once it is marked as **answered**, or if it is **locked**, since neither is
waiting on a reply from you.

**Nothing is filtered by age.** Issues used to carry a 365-day `created:` window, which meant an issue
still open on its first birthday quietly stopped being reported — the same silent-drop this search
exists to prevent, just on a delay. An open issue or PR is a request for your action and it does not
expire. The escape hatch remains for the case the window was written for, a repo seeded with hundreds
of bulk-imported legacy tickets: set `Lookout.issueLookbackDays` and only issues created inside that
many days are considered. Unset — the default — nothing is dropped for being old.

## Installation

Two formats on every release — both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/Lookout/releases/latest/download/Lookout.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places the app in `/Applications` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/Lookout/releases/latest)** — unzip and drag `Lookout.app` to your Applications folder.

Or install it with [Homebrew](https://brew.sh):

```sh
brew install --cask perpetualbeta/jorvik/lookout
```

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

Auto-updates are handled by Sparkle. Use the **Check for Updates…** entry in the right-click menu to check on demand; Sparkle's prompt offers an "Automatically download and install updates in the future" checkbox the first time an update is available.

## Privacy

- No telemetry. No analytics. No ads. No subscriptions.
- The PAT lives in your macOS Keychain and is never written to disk in plain text.
- Network traffic goes only to `api.github.com`.

## Building from source

Lookout is a Swift app with no dependencies beyond macOS system frameworks. No Xcode project is required.

The build is driven by the shared [`release.mk`](https://github.com/PerpetualBeta/jorvik-release) Make include, so `jorvik-release` has to be checked out **beside this repo** — the Makefile looks for it at `../jorvik-release/`. macOS ships GNU Make 3.81 as `make`, which is too old, so `gmake` comes from [Homebrew](https://brew.sh).

```bash
brew install make   # GNU Make 4+, if you do not already have gmake
git clone https://github.com/PerpetualBeta/jorvik-release.git
git clone https://github.com/PerpetualBeta/Lookout.git
cd Lookout
gmake build
open .build/Lookout.app
```

The target is defined in the shared `release.mk` from `jorvik-release/`; signing uses the Developer ID identity.

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
