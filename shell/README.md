# ReArc Shell

Native macOS SwiftUI prototype of an Arc-style browser chrome, written
clean-room from the behavioral spec in `docs/RECON.md`. SwiftPM only — no
`.xcodeproj`. Requires macOS 14+ and a Swift 5.10+ toolchain.

```
swift build   # builds the `rearc` executable (WebKit engine only)
swift test    # runs the SidebarModel and ReArc unit tests
swift run rearc   # launches the prototype
```

Plain `swift build` / `swift test` never need a Chromium build: all Chromium
code sits behind `#if REARC_CHROMIUM`, which the manifest defines only when
`REARC_CHROMIUM_OUT` and `REARC_ENGINE_INCLUDE` are set (the bundle script
does that, with its own scratch path `.build-chromium/`).

## Engines

`WKEngine` (WKWebView) is the default. The Chromium engine (`ChromiumEngine`,
over the C ABI in `engine/docs/C-ABI.md`) is used only when **both**:

1. it is requested, with `--rearc-engine=chromium` or `REARC_ENGINE=chromium`
   (the flag wins; `--rearc-engine=webkit` forces WebKit), and
2. the binary was built with `REARC_CHROMIUM` and runs from a bundle that
   embeds `Chromium Framework.framework`.

Otherwise the request is ignored with a warning on stderr and the WebKit path
runs unchanged. `ReArcMain` makes this choice before `ReArcApp.main()`.

### Build and run with Chromium

Needs the existing engine output in `engine/chromium/src/out/ReArc-dev-arm64`
(override with `REARC_CHROMIUM_OUT`). The script never builds Chromium and
never writes under `engine/`. It refuses to run while a Chromium build is in
progress.

```
scripts/bundle-chromium.sh              # build + assemble dist/chromium/ReArc.app
scripts/bundle-chromium.sh --selftest   # ...then run the self-test, log to selftest-chromium.log
dist/chromium/ReArc.app/Contents/MacOS/ReArc --rearc-engine=chromium
```

Options: `--release`, `--copy-dylibs` (clone the dylibs instead of
symlinking them), `--dist DIR`, `--skip-build`.

Bundle layout (component build, see "Linking and startup" in C-ABI.md):

```
dist/chromium/
  ReArc.app/Contents/MacOS/ReArc                       shell executable, rpath @executable_path/../Frameworks
  ReArc.app/Contents/Frameworks/Chromium Framework.framework   physical copy (helpers, Info.plists, resources)
  *.dylib                                              component dylib closure next to the .app
```

The framework's `@loader_path/../../../../../..` rpath resolves to the
directory that contains `ReArc.app`, so the dylibs must stay beside it. The
script checks that every `@rpath` dependency of the executable, framework and
dylibs resolves.

Flags and environment:

| | |
|---|---|
| `--rearc-engine=chromium\|webkit`, `REARC_ENGINE` | engine selection |
| `--rearc-selftest` | Chromium runtime proof; exits 0 on success, nonzero on failure, 124 on the 60 s watchdog |
| `--user-data-dir=PATH` | Chromium profile dir (default `~/Library/Application Support/ReArc/Chromium`; temp dir for the self-test) |
| `REARC_CHROMIUM_TRACE=1` | log every tab/service event and engine call to stderr |

The self-test creates a tab, rejects a `data:` URL (an ABI limit; see below),
loads pages from a loopback HTTP fixture and waits for title events, attaches
the SwiftUI-hosted view to a window, captures a viewport PNG, installs one
boost and checks its CSS and isolated-world JS, goes back and forward, checks
mute and PiP, then shuts down cleanly.

### Chromium v1 limits

- **One profile.** Every shell profile maps to the engine's
  `default_profile_id`: cookies and storage are shared across profiles, and
  ephemeral (private) profiles are not honored. `EngineHost.makeEngine` is
  where per-profile engine ids will be chosen.
- **Picture in Picture** is reported unsupported (`canPictureInPicture` is false).
- **Only `http`, `https` and `about:blank` navigate.** `data:` and `file:` URLs are
  rejected by the engine (`invalid_url`).
- **Boost editor and element picker are WebKit-only.** The ABI has no script
  evaluation call. Installed boosts (CSS and JS) do apply in Chromium.
- **No SwiftUI scenes.** The Chromium path owns a single `NSWindow` hosting
  `BrowserView` with its own main menu. Little Arc windows are not opened,
  and closing the window quits.
- **Popups and `target=_blank`** become today tabs in the sidebar.
- **Bundle identity.** The bundle keeps `CFBundleIdentifier`
  `org.chromium.Chromium` (helpers and framework expect it); only the
  executable and display name change to ReArc.
- **Hidden-tab loads can be slow.** A tab that was never attached sometimes
  takes several seconds to start its first network request.

## Layout

- `Sources/SidebarModel/` — pure-Swift model layer (no SwiftUI/AppKit/WebKit):
  `Space`, `Tab` (favorite/pinned/today), `SidebarStore`, `URLEntry`.
  Fully unit-tested in `Tests/SidebarModelTests/`.
- `Sources/ReArc/` — the shell app:
  - `Engine/` — `WebEngine` protocol, `WKEngine` (WKWebView), `EngineHost`
    (one engine per tab; `makeEngine` is the only place that picks the
    concrete type), launch options and the pure boost-plan mapping.
  - `Chromium/` — `ChromiumRuntime` (ABI callbacks, startup/shutdown),
    `ChromiumEngine`, `ChromiumWebView` (attachment lease host),
    `ChromiumHost` (window and menu), `ChromiumSelfTest`. Compiled only with
    `REARC_CHROMIUM`.
  - `Sidebar/` — favorites row, pinned/today sections with drag-to-reorder,
    hover-to-close rows, bottom bar (space switcher, new space, avatar).
  - `CommandBar/` — centered floating URL/search panel.
  - `BrowserViewModel` — glue between store, engines, overlay, and shortcuts.

## Model rules worth knowing

- Favorites are **global** (shown in every space); pinned and today tabs are
  per-space. New today tabs insert at the **top** of their section.
- Reordering never crosses sections — `moveTab` interprets the destination
  index within the tab's own kind. Cross-section moves go through
  `pinTab`/`unpinTab` (pinned ⇄ today). Favorites can only be reordered.
- Closing the selected tab selects whatever now occupies its display position
  (next tab, or previous if it was last), `nil` when nothing remains.
- Selection is remembered per space when switching spaces.
- Display order = favorites → pinned → today; Cmd+Shift+]/[ and Ctrl+Tab
  cycle through that order with wraparound.
- Submitting the command bar on a **favorite** spawns a today tab instead of
  mutating the favorite (favorites are launchpads).

## Shortcuts

| Keys | Action |
|---|---|
| ⌘T | New today tab + open command bar |
| ⌘L | Open command bar for current tab |
| ⌘W | Close selected tab (⌘W is stripped from File > Close Window) |
| ⌘S | Toggle sidebar |
| ⌘⇧] / ⌘⇧[ | Next / previous tab |
| ⌃⇥ | Next tab |

## Sync (P0 + P1)

Sidebar mutations are recorded in a local **mutation journal** (LexoRank ordering,
device id, monotonic sequence) and optionally pushed through a **SyncEngine**.

- **Local-only (default in SwiftPM dev builds)**: `LocalSyncEngine` — journal +
  coalescing run, but nothing leaves the machine. The bottom-bar dot stays grey.
- **CloudKit backup (signed app)**: enable the iCloud capability and container
  `iCloud.net.rearc.sidebar` in an Xcode target that embeds `rearc`, with CloudKit
  services checked for that container. Create the custom zone
  `com.rearc.sidebar.graph.v1` on first run (the adapter initializes lazily).
  Without entitlements, `CloudKitSyncAvailability.makeEngine()` returns
  `unavailable(reason:)` and the app does not crash.

SwiftPM `swift run rearc` does not inject entitlements; use **Product → Archive**
or an Xcode scheme with the ReArc entitlements plist linked to test CloudKit sync.
