<p align="center">
  <img src="brand/logo-wordmark.svg" alt="ReArc" width="420">
</p>

# ReArc

An open-source reimplementation of the Arc browser's ideas on macOS: a native
Swift/SwiftUI shell over a lightly patched Chromium that stays easy to update.

## Download

ReArc 0.1.0 is an alpha for Apple silicon Macs on macOS 14 or later.
Download the DMG from [rearc.imara.ae](https://rearc.imara.ae). It is Developer ID signed and notarized,
and updates itself through Sparkle (ReArc › Check for Updates…). What changed in
each release is in [RELEASES.md](RELEASES.md).

On first launch a short onboarding imports your spaces, pinned tabs, favorites,
bookmarks, history and extensions from Arc, Chrome or Brave. Extensions install
in the background, one copy of each. ReArc never reads your passwords or cookies.

## What's in the repo

- **`shell/`**: the browser UI in SwiftUI and AppKit. Sidebar with spaces,
  folders and pinned tabs, command bar, split view, profiles, Peek and Little Arc,
  themes, media and picture in picture, boosts, easels and capture, onboarding and
  import, developer tools docking, Sparkle updates and the iCloud sync foundation.
  `cd shell && swift build && swift test`.
- **`engine/`**: the Chromium pin (`156.0.8078.96`, in `engine/CHROMIUM_PIN`) and
  ReArc's patch overlay (`engine/patches/series`). Also the fetch and build scripts,
  the C ABI the shell talks to (`engine/docs/C-ABI.md`) and its native test hosts.
  The Chromium checkout itself is not in this repo: `engine/scripts/fetch.sh` gets it.
- **`brand/`**: the ReArc "Sunrise" mark and brand guidelines.

## Building

1. Fetch and build the engine: `engine/scripts/fetch.sh`, then `engine/scripts/build.sh`.
2. Build and bundle the shell: `shell/scripts/bundle-chromium.sh`.
3. Signing, iCloud and release builds read your Apple Team ID and identities from
   `shell/signing.local.env`. That file is git-ignored; copy it from
   `shell/signing.example.env`. No personal identifiers live in the repo.

### Release builds

`shell/scripts/build-engine-release.sh` builds the release engine and
`shell/scripts/release.sh` signs, verifies and packages the app. Its `--dmg`,
`--notarize` and `--appcast` options are described in
[engine/docs/RELEASE.md](engine/docs/RELEASE.md). A distributable build also needs:

- **A Safe Browsing key.** Use a Google API key restricted to the Safe Browsing API,
  in `~/.config/rearc/google-api-keys.gn` (outside the repo) as
  `google_api_key = "…"`. `release.sh --dmg` refuses an engine built without one.
- **A current engine.** `release.sh --dmg` refuses an engine pin that is behind
  Chrome's latest Mac Stable or Extended Stable security release.
- **Release notes.** `release.sh --dmg` refuses to build until `RELEASES.md` has an
  entry for that build number.

## License

ReArc is licensed under the [Apache License 2.0](LICENSE). The patch overlay
modifies Chromium, which is © The Chromium Authors under a BSD-style licence;
see [NOTICE](NOTICE).

Arc is a product of The Browser Company. ReArc is an independent project, not
affiliated with or endorsed by The Browser Company, and contains none of its code
or assets.
