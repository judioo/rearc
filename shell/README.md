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
symlinking them), `--dist DIR`, `--skip-build`, `--dev-mock-keychain` (see
"Keychain" below).

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
| `--rearc-selftest` | Chromium runtime proof; exits 0 on success, nonzero on failure, 124 on the 120 s watchdog |
| `--user-data-dir=PATH` | Chromium profile dir (default `~/Library/Application Support/ReArc/Chromium`; temp dir for the self-test) |
| `REARC_CHROMIUM_TRACE=1` | log every tab/service event and engine call (including script evaluations) to stderr |

### ABI 1.5 adoption

The shell still calls `ReArcEngineConfigure(1, …)`. After `ready` it probes
`ReArcEngineABIMinorVersion()`; the framework is weak-linked, so the symbol is
looked up with `dlsym` first and an engine that predates the export counts as
minor 0. `ChromiumCapabilities` enables a feature only when the minor version
is at least 5 **and** `ReArcEngineHasFeature` advertises it, and logs
`capabilities: ABI minor 5: navigation_extended=1 script_evaluation=1 media_metadata_snapshot=1`.
On an older engine all three stay off and the shell behaves as in wave 11.

- **`navigation_extended`: URL admission.** `NavigationURLPolicy` always
  admits `http`, `https`, `data`, `file` and `about:blank`. With the Chromium
  engine it also admits `chrome://settings…`, `chrome://version` and
  `view-source:` around one `http`/`https`/`file` URL. It rejects every other
  `chrome://` host, `javascript:`, `blob:` and nested `view-source:` before
  the URL reaches the engine. The command bar, `URLEntry.resolve` and
  navigation requests all use the same policy, with the schemes taken from
  `EngineHost.navigationSchemes`. On WebKit, `chrome://` and `view-source:`
  are not admitted.
- **Settings routing.** On the Chromium path the browser settings entry
  points open Chromium WebUI in a single reused tab (`BrowserInternalPage`).
  They are the app menu's Settings… (⌘,), Clear Browsing Data… (⇧⌘⌫) and
  About Chromium Engine items, and the command-bar commands Settings,
  Privacy and Security Settings, Site Settings, Clear Browsing Data… and
  About Chromium Engine. View > View Page Source (⌥⌘U) and the matching
  command open `view-source:` for the selected tab. All of these are hidden
  or disabled when `navigation_extended` is off.
- **`script_evaluation`: boost editor and element picker.**
  `ChromiumRuntime.evaluateScript` passes a retained `ScriptEvaluationBox` as
  the context with a static C callback. The callback copies the borrowed
  strings (it never frees them) and balances the retain exactly once, on
  completion or on synchronous rejection. `ChromiumEngine.evaluate` runs one
  evaluation per tab at a time (FIFO). It waits for the commit and retries
  once on `invalid_state`. Results are dropped as `staleDocument` when the tab,
  content generation or committed document changed. `cancelled` and `timeout`
  surface as typed errors (`ChromiumScriptError`), and the default timeout is
  3 s, clamped to 1–30000 ms. Editor scripts run in the `editor` isolated
  world, boost worlds are `rearc.boost.<id>`, and `.page` is the main world.
  The editor and picker (`BoostEditorEngine`, shared with `WKEngine`) use
  `BoostPickerScript` in the editor world. Picking uses a native overlay
  (`ChromiumPickerOverlayView`) that turns mouse moves and clicks into
  `snapshotAt(x, y)` evaluations (view points = CSS px at 100% zoom). Escape
  cancels.
- **`media_metadata_snapshot`.** Each media event replaces playback and
  audible state. `has_metadata=false` means the metadata is unchanged.
  `has_metadata=true` replaces title, artist and album together, and an empty
  or missing string clears that field (`ChromiumMediaMapping`, unit-tested).
  Album reaches Now Playing as `MPMediaItemPropertyAlbumTitle`.

### Self-test

The self-test:

1. Logs the capabilities and keychain mode.
2. Creates a tab and commits a `data:` document with its expected title, then
   evaluates `document.title` there.
3. Loads pages from a loopback HTTP fixture and waits for title events.
4. Attaches the SwiftUI-hosted view to a window and captures a viewport PNG.
5. Installs one boost and checks its CSS and isolated-world JS.
6. Goes back and forward, and checks mute and PiP.
7. Checks script evaluation:
   - each world sees only its own globals (boost, main and editor);
   - JSON results, including `undefined` and awaited Promises;
   - an exception and a rejected Promise give `script_error` with details;
   - a 300 ms timeout, after which the next evaluation still succeeds;
   - a cross-document navigation cancels a pending evaluation.
8. Exercises the boost editor: the overlay picks the `<h1>`, live CSS applies,
   and the repair scan returns candidates.
9. Commits `view-source:`, `chrome://version` and `chrome://settings`, and
   checks that WebUI refuses evaluation (`unsupported`).
10. Checks that `javascript:`, `chrome://flags` and nested `view-source:` are
    still `invalid_url`.
11. Verifies every evaluation context was released (`live contexts: 0`),
    then shuts down cleanly.

With the mock keychain the run reaches `RESULT PASS`
(`selftest-chromium-mockkeychain.log`). The real-Keychain run is covered
below.

### Keychain

Chromium encrypts cookies with a key stored in the login keychain as
"Chromium Safe Storage". The development bundle is ad-hoc signed, gets a new
code hash on every build and keeps the bundle id `org.chromium.Chromium`. The
keychain item's access list therefore does not trust it, so macOS asks for
authorization. Until the user answers, the async key read
(`os_crypt_async` `GetKeyTask` → `SecItemCopyMatching` → `securityd`) blocks
the cookie store, and the first `http(s)` load stays at progress 0.1.
`data:` still commits because it needs no cookies, and shutdown is clean.
The self-test logs `KEYCHAIN-STALL` and fails. `selftest-chromium.log` is
such a run, and `selftest-chromium-keychain-stall.txt` has the sampled stack,
signing identity and timeline. To proceed, answer the prompt with Always
Allow and rerun with `--skip-build` (same code hash), or use the mock
keychain:

```
scripts/bundle-chromium.sh --dev-mock-keychain --selftest   # log: selftest-chromium-mockkeychain.log
```

> **`--dev-mock-keychain` disables real cookie encryption.** It sets
> `ReArcDevUseMockKeychain` in the bundle's Info.plist, and debug builds then
> pass Chromium's `--use-mock-keychain`, which encrypts cookies and saved
> data with a fixed in-process key instead of a Keychain secret. It is off
> by default, the script refuses it together with `--release`, and release
> builds ignore the key (and log that they did). Never ship a bundle built
> with it.

#### Stable development signing

Set `REARC_SIGN_IDENTITY` (and optionally `REARC_TEAM_ID`, which the script
verifies) in the environment or in the git-ignored `signing.local.env`. Copy
`signing.example.env` to create it, and list identities with
`security find-identity -v -p codesigning`. The script then signs the ReArc
executable with that identity. The designated requirement becomes the bundle
id plus the certificate rather than a per-build code hash, so a single Always
Allow for Safe Storage should survive rebuilds. An Apple Development
certificate is enough for this. It does not make the bundle distributable.

Production needs:

- a stable signing identity: a Developer ID certificate with a Team ID,
  instead of ad-hoc signing;
- a unique ReArc bundle id instead of `org.chromium.Chromium`, with the
  helpers and framework set to match;
- Safe Storage access granted to that identity: the app creates and owns its
  own Safe Storage item, so the item's access list matches the designated
  requirement across updates and no authorization prompt blocks startup.

### Chromium limits

- **One profile.** Every shell profile maps to the engine's
  `default_profile_id`: cookies and storage are shared across profiles, and
  ephemeral (private) profiles are not honored. `EngineHost.makeEngine` is
  where per-profile engine ids will be chosen.
- **Picture in Picture** is reported unsupported (`canPictureInPicture` is false).
- **No script evaluation on `file:` or WebUI pages** (the engine returns
  `unsupported`), so the boost editor does nothing there.
- **Picker coordinates assume 100% page zoom**, because the ABI reports no
  zoom factor.
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
    concrete type), launch options and the pure boost-plan mapping. The pure
    Chromium helpers (`ChromiumCapabilities`, `ChromiumScriptEvaluation`,
    `ChromiumMediaMapping`, `ChromiumLaunchArguments`) are compiled in every
    build and unit-tested without Chromium.
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
