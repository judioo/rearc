<p align="center">
  <img src="brand/logo-wordmark.svg" alt="ReArc" width="420">
</p>

# ReArc

An open-source reimplementation of the Arc browser's ideas on macOS: a native
Swift/SwiftUI shell over a lightly patched Chromium that stays easy to update.

- **`shell/`**: the browser UI in SwiftUI and AppKit. Sidebar with spaces,
  folders and pinned tabs, command bar, split view, profiles, Peek and Little Arc,
  themes, media and picture in picture, boosts, easels and capture, and the sync
  foundation. `cd shell && swift build && swift test`.
- **`engine/`**: the Chromium pin (`156.0.8078.74`) and ReArc's patch overlay
  (`engine/patches/series`). Also the fetch and build scripts, the C ABI the shell
  talks to (`engine/docs/C-ABI.md`) and its native test hosts. The Chromium
  checkout itself is not in this repo: `engine/scripts/fetch.sh` gets it.
- **`brand/`**: the ReArc "Sunrise" mark and brand guidelines.

## Building

1. Fetch and build the engine: `engine/scripts/fetch.sh`, then `engine/scripts/build.sh`.
2. Build and bundle the shell: `shell/scripts/bundle-chromium.sh`.
3. Signing, iCloud and release builds read your Apple Team ID and identities from
   `shell/signing.local.env`. That file is git-ignored; copy it from
   `shell/signing.example.env`. No personal identifiers live in the repo.

## License

ReArc is licensed under the [Apache License 2.0](LICENSE). The patch overlay
modifies Chromium, which is © The Chromium Authors under a BSD-style licence;
see [NOTICE](NOTICE).

Arc is a product of The Browser Company. ReArc is an independent project, not
affiliated with or endorsed by The Browser Company, and contains none of its code
or assets.
