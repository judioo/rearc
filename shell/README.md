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
is at least the one that introduced it (5 for the three below, 6–10 for the
ABI 1.10 features, 11–14 for the ABI 1.14 ones, 15–17 for the wave 20 ones)
**and** `ReArcEngineHasFeature`
advertises it, and logs
`capabilities: ABI minor 14: navigation_extended=1 script_evaluation=1 …`.
On an older engine the missing features stay off and the shell behaves as it
did against that engine.

- **`navigation_extended`: URL admission.** `NavigationURLPolicy` always
  admits `http`, `https`, `data`, `file` and `about:blank`. With the Chromium
  engine it also admits `chrome://settings…`, `chrome://version` and
  `view-source:` around one `http`/`https`/`file` URL, and with
  `webui_daily_pages` (ABI 1.14) exactly `chrome://history`, `downloads`,
  `password-manager` and `extensions`. It rejects every other
  `chrome://` host (`flags` included), `javascript:`, `blob:` and nested `view-source:` before
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
  or disabled when `navigation_extended` is off. View > History (⌘Y),
  Downloads (⌥⌘L), Passwords and Extensions, and the matching command-bar
  commands, open Chromium's own pages the same way; they exist only with
  `webui_daily_pages`.
- **`script_evaluation`: boost editor and element picker.**
  `ChromiumRuntime.evaluateScript` passes a retained `ScriptEvaluationBox` as
  the context with a static C callback. The callback copies the borrowed
  strings (it never frees them) and balances the retain exactly once, on
  completion or on synchronous rejection. `ChromiumEngine.evaluate` runs one
  evaluation per tab at a time (FIFO). It waits for the commit and retries
  once on `invalid_state`. Results are dropped as `staleDocument` when the
  document changed (by document identity on ABI 1.7, see below). `cancelled` and `timeout`
  surface as typed errors (`ChromiumScriptError`), and the default timeout is
  3 s, clamped to 1–30000 ms. Editor scripts run in the `editor` isolated
  world, boost worlds are `rearc.boost.<id>`, and `.page` is the main world.
  The editor and picker (`BoostEditorEngine`, shared with `WKEngine`) use
  `BoostPickerScript` in the editor world. With isolated page messages the
  page's own input picks (see ABI 1.10 below). Otherwise a native overlay
  (`ChromiumPickerOverlayView`) turns mouse moves and clicks into
  `snapshotAt(x, y)` evaluations, at view points divided by the page zoom.
  Escape cancels.
- **`media_metadata_snapshot`.** Each media event replaces playback and
  audible state. `has_metadata=false` means the metadata is unchanged.
  `has_metadata=true` replaces title, artist and album together, and an empty
  or missing string clears that field (`ChromiumMediaMapping`, unit-tested).
  Album reaches Now Playing as `MPMediaItemPropertyAlbumTitle`.

### ABI 1.10 adoption (wave 15)

Follows "Exact Swift adoption" in `engine/docs/WAVE-14-REPORT.md`. Every item
is gated on its feature flag (`profiles`, `profile_off_the_record`,
`script_evaluation_identity`, `page_zoom`, `isolated_page_messages`,
`rearc_safe_storage_branding`).

- **Profiles.** Each shell `Profile` (which owns its Spaces) maps to one named
  persistent engine profile, opened with `ReArcProfileOpen` under the
  lowercased profile UUID (`ChromiumProfileKey`). Engine profile IDs are
  session-local and never persisted. Since ABI 1.13 the first profile
  opens the startup `Default` directory instead (see ABI 1.14 adoption
  below). `ChromiumRuntime` keeps the profile registry. It
  coalesces opens, queues lifecycle calls (the engine serializes them and
  answers `busy` otherwise), and creates a tab only once its profile is open.
  `ChromiumEngine` queues navigations and evaluations until then, and a host
  that appeared earlier attaches once the tab exists. A Space's tabs keep their
  BrowserContext when moved: the profile is fixed per engine. Deleting a shell
  profile (with its spaces, after confirmation, since wave 17) closes its
  private windows, then its engine profile.
- **Private windows** (File > New Private Window, ⇧⌘N; both engines) are
  `PrivateWindowModel`s: one page, no sidebar, history or sync. On Chromium a
  private session is one off-the-record profile created with
  `ReArcProfileCreateOffTheRecord` under the active profile. Its popups open
  as further private windows of the same session. When the session's last
  window closes, its engine stays alive until `ReArcProfileClose` completes,
  which erases the session. Teardown order is off-the-record children first,
  one at a time, then the parent (`ChromiumProfileTeardown`). A beforeunload
  veto keeps the profile and its ID. Engine shutdown owns everything at quit,
  and the shell waits for a profile close in flight before calling
  `ReArcEngineShutdown` (and for tab closes too on engines before ABI 1.12,
  which are busy while either is pending). On WebKit the
  private window's engine uses a non-persistent `WKWebsiteDataStore`.
- **Evaluation identity.** `ReArcTabEvaluateScript2` replaces the 1.5 call.
  Before a result is applied, `ReArcTabGetDocumentIdentity` must still match
  the identity the engine captured at acceptance (profile, tab, content and
  document generation, plus navigation ID when `sameNavigation` is set), and
  the identity the caller required (`expecting:`). Otherwise the result is
  discarded as `staleDocument`. There is no commit counting.
- **Zoom.** View > Zoom In / Zoom Out / Actual Size (⌘= / ⌘- / ⌘0) step
  through Chrome's presets on the key private window or the focused tab.
  `ReArcEngineSetZoomCallback` events update every affected tab, including
  same-host siblings in the profile. Selecting a tab re-reads
  `ReArcTabGetZoomFactor`. Chromium persists its own per-host map, and the
  shell keeps none. A badge shows a non-100% zoom, and clicking it resets.
  Picker coordinates are view points divided by the zoom factor
  (`PageZoom.cssPoint`). WebKit uses `WKWebView.pageZoom` per view.
- **Boost editor page messages.** `ReArcEngineSetPageMessageCallback` is
  registered at `ready`, before any tab or editor code. In pick mode on
  http(s), the editor-world picker handles the page's own trusted
  `mousemove`/`click`/Escape and posts `rearcPostMessage(JSON.stringify(…))`.
  The callback copies the message, checks it is for the current document and
  the document picking started on, and accepts only `pick` and `cancel`
  (`BoostEditorPageMessage`). Hover highlighting stays in the page, so there
  is no polling or per-move evaluation. The native overlay remains only where
  the channel cannot work (non-http(s) documents, older engines). Messages
  from boost worlds go to `onBoostPageMessage` as untrusted data.
- **Windows.** `ChromiumShell` owns any number of browser windows on one
  `BrowserViewModel` (File > New Window, ⌘N), Little Arc and private windows
  (through `BrowserWindowPresenting`), Peek and Split View. A tab has one live
  attachment. A host that takes the lease detaches the previous holder first,
  and the other window shows "This tab is open in another window". The key
  window's host takes it back. Before a window closes, every Chromium host in
  it detaches, so the lease moves to a surviving window before the engine
  invalidates the closing one. Closing windows never quits (Quit does).
  Activating the app with no window open opens a new browser window. ⌘W
  closes the tab, or the window when it is a private or Little Arc window.
  ⇧⌘W closes the window.
- **Safe Storage branding.** The engine reads its key from the Keychain item
  "ReArc Safe Storage", and the bundle id is `com.rearc.browser`.

### ABI 1.14 adoption (wave 19)

Follows "Exact Swift adoption" in `engine/docs/WAVE-16-REPORT.md` and
`WAVE-18-REPORT.md` (concern 1). Each item is gated on its minor and flag
(`os_permission_shutdown`, `shutdown_pending_closes`, `profile_directory`,
`webui_daily_pages`); Configure still takes 1.

- **Startup data opened in place.** Builds before named profiles kept
  their cookies and storage in the engine's startup `Default` directory. The
  first shell profile now opens that directory with
  `ReArcProfileOpenDirectory("Default")` (looked up with `dlsym`, through the
  same retained one-shot callback as `ReArcProfileOpen`) instead of a fresh
  `ReArcProfile-<hex>` directory. `ChromiumShell.makeModel` names that owner
  from the loaded sidebar before any tab exists. The decision is made once
  and persisted in `ReArcProfileStorage.json` in the user-data-dir:
  `directories` maps the profile UUID to `Default` and `legacyDefault` is
  `adopted`. Every later launch reopens the recorded mapping. If the first
  profile already has a named directory (data from a wave 15–18 build), it
  keeps it, `legacyDefault` becomes `keptNamed` and Default is left
  untouched: nothing is moved, copied, merged or deleted. A failed adoption
  records nothing and opens named. Engines before 1.13 use the startup
  profile for a recorded `Default` mapping and report `unsupported` for any
  other directory, never a fresh named profile (`ChromiumProfileStoragePlan`,
  unit-tested). The adopted profile is the startup profile: deleting its
  shell profile closes its private children and tabs, and the engine keeps
  the BrowserContext until shutdown (ProfileClose would be `invalid_state`).
  Its private windows are ordinary off-the-record children. As the engine
  report says, pre-wave-14 "Chromium Safe Storage" ciphertext is not
  converted to the ReArc key.
- **Pending closes.** With `shutdown_pending_closes` the shell no longer
  holds `ReArcEngineShutdown` back while standalone tab closes are in
  flight (the engine joins them, and each callback still arrives once). A
  ProfileClose in flight still defers shutdown (`ChromiumShutdownGate`).
- **Daily WebUI.** History, Downloads, Passwords and Extensions (see
  Settings routing above). Admission alone records no history and fills no
  passwords; ABI 1.15 adds both (below). Extension installs still need
  engine work.
- `os_permission_shutdown` needs no Swift call; it is logged.

### ABI 1.15–1.17 adoption (wave 20)

Follows "Exact Swift adoption" in `engine/docs/WAVE-18-REPORT.md` (Wave
18b, concerns A–C). Each item is gated on its minor and flag
(`history_recording` and `password_autofill` at 15, `find_in_page` at 16,
`downloads` at 17); Configure still takes 1. Every feature also works on
WebKit, mapped onto WKWebView.

- **History and passwords (1.15).** No Swift call: Chromium's
  HistoryTabHelper records every non-OTR tab (chrome://history) and
  ChromePasswordManagerClient fills saved credentials. There is no save
  prompt yet, so the shell offers no "save password" UI. Tabs present at
  their real size; no production `--disable-backgrounding-occluded-windows`.
- **Find in page (1.16).** Edit > Find… (⌘F), Find Next (⌘G), Find Previous
  (⇧⌘G), or "Find on Page" in the command bar, open a floating bar at the
  page's top-trailing corner (`FindBar/`). It searches as you type and
  shows "n of m". Return / Shift-Return step through matches, Aa toggles
  match case, and Esc closes and keeps the selection. The field turns red
  on no matches. `FindBarModel` drives one page at a time through
  `FindInPageEngine` (`Engine/FindInPage.swift`). On Chromium, every
  keystroke is a `ReArcTabFindStart` session. The find callback, registered
  at `ready`, routes events by tab. Only `final_update` results of the
  current session change the count (`FindInPageState`). A terminal
  (navigated, closed, stopped, replaced) hides the count, and Return then
  searches the new document. On WebKit, `WKWebView.find` highlights and
  steps, and the shell counts case-folded occurrences of the query in the
  page's `innerText`. Each find bar targets the key page: the private
  window's, else the focused tab (the focused pane in a split).
- **Downloads (1.17).** A downloads button sits in the sidebar's bottom bar.
  Its ring fills while files transfer and it pulses when one starts. An
  orange dot means a download needs attention. It opens a tray, and View >
  Show Downloads (⇧⌘J) toggles it. Rows show the file icon, progress,
  speed and time left, with pause/resume, cancel and Show in Finder. A
  double-click opens a finished file. The context menu adds Copy Download
  Link and Remove from List. The header has Clear and the download folder
  menu (show, change). A dangerous download (`danger_type` not 0, 4, 6, 9,
  10 or 15, still in progress) shows an orange warning with Discard
  (cancel and remove), and Review… opens chrome://downloads (with
  `webui_daily_pages`) for Chromium's keep-dangerous flow; no native accept
  action exists. `DownloadsController` keeps the list newest first, keyed
  by GUID, and saves it with the default directory in `Downloads.json`
  next to `sidebar.json`. A row still in progress at launch becomes
  "Interrupted when ReArc quit", and Chromium's restored items (kind 0)
  merge back in by GUID. On Chromium the download callback is set at
  `ready`, and `ReArcDownloadSetPolicy(profile, directory, 0)` runs for
  each profile as its open completes, before its first tab, OTR included,
  and again on a folder change (`ChromiumDownloadBackend`). Actions map to
  `ReArcDownloadAction`; invalid_state waits for the next event, and
  not_found falls back to Finder / Launch Services. No "Ask where to save"
  option until the file chooser ABI. On WebKit, attachments and
  main-frame responses WebKit cannot show become `WKDownload`s
  (`WebKitDownloadCenter`). They are saved without asking into the same
  folder, uniquified like Chromium ("name (1).ext"), and quarantined when
  done. Pause is cancel-with-resume-data and resume is
  `resumeDownload(fromResumeData:)`. WebKit runs no Safe Browsing check, so
  there is no danger state there.
- **Command-bar history.** The ABI has no history query (WAVE-18-REPORT:
  "Not claimed: command-bar history queries"). The shell therefore records
  committed navigations of sidebar tabs itself, on both engines, in
  `History.json` (`VisitHistory`). Only http(s) pages are recorded, one
  visit per navigation, never from private windows, peeks or Little Arc.
  The store only feeds suggestions; chrome://history stays Chromium's full
  history. Results are ranked by match quality (host start, then URL start,
  then a title word, then a substring; every word must match) times
  frecency (visit count, recency buckets). They are listed after open tabs,
  without repeating an open tab's page, before commands and the search
  fallback. A typed address keeps its Open row first. "Clear Command Bar
  History" empties the store.

### Self-test

The self-test:

1. Logs the capabilities and keychain mode.
2. Creates a tab and commits a `data:` document with its expected title, then
   evaluates `document.title` there.
3. Loads pages from a loopback HTTP fixture and waits for title events.
   Page A declares `/favicon.png`: the favicon event's `icon_ref` is read
   with `ReArcFaviconGet` (a PNG), and a stale ref is `not_found`.
4. Attaches the SwiftUI-hosted view to a window and captures a viewport PNG.
5. Installs one boost and checks its CSS and isolated-world JS.
6. Goes back and forward, and checks mute and PiP.
7. Checks script evaluation:
   - each world sees only its own globals (boost, main and editor);
   - JSON results, including `undefined` and awaited Promises;
   - an exception and a rejected Promise give `script_error` with details;
   - a 300 ms timeout, after which the next evaluation still succeeds;
   - a cross-document navigation cancels a pending evaluation.
8. Exercises the boost editor: the picker picks the `<h1>`, live CSS applies,
   and the repair scan returns candidates.
9. Document identity: a result for the pre-reload document is discarded
   (`staleDocument`), and the identity changes across navigation.
10. Zoom: set 1.5 → zoom event and query agree, a non-finite factor is
    `invalid_argument`, and a pick at a zoomed view point finds the `<h1>`.
11. Page messages: a boost-world message arrives with its package ID, the main
    world has no `rearcPostMessage`, a trusted click picks through the editor
    channel, `cancel` is delivered and an unknown kind is dropped.
12. Moves a tab to a second window (detach, then attach) and back when that
    window closes.
13. Commits `view-source:`, `chrome://version` and `chrome://settings`, and
    checks that WebUI refuses evaluation (`unsupported`). With
    `webui_daily_pages` it commits `chrome://history`, `downloads`,
    `password-manager` and `extensions`. Checks that
    `javascript:`, `chrome://flags` and nested `view-source:` are still
    `invalid_url`.
14. Profiles: two named profiles keep separate cookies, an off-the-record
    child sees neither and leaks nothing, closing the parent closes the child
    first, and reopening gives a new engine ID with the persistent cookie.
    With `profile_directory`: `OpenDirectory("Default")` returns the startup
    ID, a missing directory is `not_found`, `../Default` is
    `invalid_argument`, and every request context is released.
15. Runs the real `ChromiumShell` on a throwaway sidebar. Its first profile
    adopts Default (tab A is on the startup engine profile and the mapping
    is persisted). Then: two browser windows
    sharing a tab, Split View, Peek, Little Arc, the zoom commands (including a
    same-host sibling and the key private window), the sidebar navigation
    controls (the tab's favicon reaches the sidebar cache, `security_state`
    reaches the URL field, and `BrowserViewModel` Back, Forward, Reload,
    Reload Ignoring Cache and Stop drive the selected tab), a private window
    whose close ends its off-the-record session, and closing every window
    without quitting, then reopening.
16. With `find_in_page` (ABI ≥ 1.16): through `FindBarModel` on the
    attached tab, 4 matches with ordinals 1→2→1→4 (backward wrap), 2 with
    match case, "No matches" for a missing word, replaced, stopped and
    navigated terminals, FindNext without a session `invalid_state`, and
    empty text `invalid_argument`. With `downloads` (ABI ≥ 1.17): through
    `DownloadsController` and `ChromiumDownloadBackend`, a 64 KiB attachment
    saved to a temporary policy directory without a picker (the tab stays
    on its page, the tray opens) and removed by a removed event. Then a
    trickled 1 MiB file is paused (a second pause is `invalid_state`),
    resumed, cancelled and removed (reveal is then `not_found`), and a
    relative directory or prompt mode 1 is refused. Older engines log
    ABI-GAP lines instead. In the real shell, ⌘F on tab A shows "1 of 1",
    and the command bar offers the `/nav` visit as history.
17. Verifies every evaluation and profile request context was released
    (`live script contexts: 0, profile contexts: 0`), then shuts down cleanly.

With the mock keychain the run reaches `RESULT PASS`
(`selftest-chromium-mockkeychain.log`). The real-Keychain run is covered
below.

The self-test (only the self-test) passes
`--disable-backgrounding-occluded-windows`,
`--disable-renderer-backgrounding` and
`--disable-background-timer-throttling`. A run started from a terminal
leaves the app inactive, with its windows occluded or the screen locked.
Chromium then hides those pages and backgrounds their renderers. Wave 20
measured an editor-world evaluation at 9 ms, then at 1938 ms after five
idle seconds with the window occluded, and at 6 ms with it visible. Under
load, the 3 s deadline of the editor-pick fallback then failed
intermittently ("FAIL timeout" at about 19 s). The step now sends its
synthesized click only when the app is active and the window key and
visible (otherwise it logs a NOTE and posts the pick from the editor
world), and gives that fallback 15 s.

### Keychain

Chromium encrypts cookies with a key stored in the login keychain as
"ReArc Safe Storage" (engine branding, ABI 1.10; older engines use
"Chromium Safe Storage"). An ad-hoc signed development bundle gets a new
code hash on every build, so the keychain item's access list does not trust
it and macOS asks for authorization. Until the user answers, the async key read
(`os_crypt_async` `GetKeyTask` → `SecItemCopyMatching` → `securityd`) blocks
the cookie store, and the first `http(s)` load stays at progress 0.1.
`data:` still commits because it needs no cookies, and shutdown is clean.
The self-test logs `KEYCHAIN-STALL` and fails.
`selftest-chromium-keychain-stall.txt` has such a run's sampled stack,
signing identity and timeline. Since the stable signing identity below has
been granted access, `selftest-chromium.log` is a real-Keychain
`RESULT PASS` (wave 20) with no authorization prompt. To proceed, answer the prompt with Always
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
- the release BRANDING input with the real Team ID (the engine already
  builds bundle id `com.rearc.browser` with matching helper and framework
  ids, see `engine/docs/PACKAGING-MAC.md`);
- Safe Storage access granted to that identity: the app creates and owns its
  own Safe Storage item, so the item's access list matches the designated
  requirement across updates and no authorization prompt blocks startup.

### Chromium limits

- **Picture in Picture** is reported unsupported (`canPictureInPicture` is false).
- **No script evaluation on `file:` or WebUI pages** (the engine returns
  `unsupported`), so the boost editor does nothing there.
- **No SwiftUI scenes.** The Chromium path owns its NSWindows (`ChromiumShell`)
  and its own main menu. They show the same SwiftUI views as the WebKit scenes.
- **Popups and `target=_blank`** from a normal tab become today tabs in the
  active space, in the opener's engine profile. A private window's popup
  becomes another private window of the same session. Contents from a profile
  that is closing are not adopted.
- **Startup data goes to the first profile only.** The first shell profile
  opens `Default` in place (ABI 1.13). Other profiles, and a first profile
  that already had named data, do not see it, and the two are never merged.
- **Off-the-record zoom** starts from the parent's per-host zoom and is not
  saved (Chromium's private zoom map).
- **One live view per tab.** A tab shown in two windows renders in one, and
  the other shows a placeholder.
- **Hidden-tab loads can be slow.** A tab that was never attached sometimes
  takes several seconds to start its first network request, or to run script.

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
  - `Chromium/` — `ChromiumRuntime` (ABI callbacks, profile registry,
    startup/shutdown), `ChromiumEngine`, `ChromiumWebView` (attachment lease
    host), `ChromiumHost` (`ChromiumShell`: windows and menu),
    `ChromiumSelfTest`. Compiled only with `REARC_CHROMIUM`. The pure helpers
    `ChromiumProfiles`, `PageZoom` and `BoostEditorPageMessage` are
    unit-tested without Chromium.
  - `Private/` — `PrivateWindowModel` and `PrivateWindowView`, shared by
    both engines.
  - `Sidebar/` — navigation row and URL field (`SidebarToolbarView`),
    favorites row, space header, pinned/today sections with folders and drag
    and drop (`TabSectionView`), context menus, the Edit Space sheet, the
    Archive view, and the bottom bar (space switcher, archive, "+" menu,
    avatar).
  - `ShellMenus` — menu items and shortcuts shared by the WebKit `Commands`
    and the Chromium `NSMenu`.
  - `Engine/FaviconStore` — site icons by host, cached on disk next to
    `sidebar.json` (`Favicons/`).
  - `CommandBar/` — centered floating URL/search panel (tabs, visit
    history, commands, search).
  - `FindBar/` — the find-in-page bar and its model.
  - `Downloads/` — `DownloadsController`, the sidebar tray, and the
    `WKDownload` backend (`ChromiumDownloads.swift` is the Chromium one).
  - `BrowserViewModel` — glue between store, engines, overlay, and shortcuts.

## Sidebar (wave 17)

- **Navigation without a toolbar.** As in Arc, back, forward and reload/stop
  sit at the top of the sidebar next to the traffic lights. Below them, a URL
  field shows the page's domain and lock state (Chromium `security_state`;
  WebKit derives it from the scheme and `hasOnlySecureContent`) and opens the
  command bar when clicked. The same actions are in View (⌘[, ⌘], ⌘R, ⇧⌘R,
  ⌘.) and the command bar.
- **Folders.** New Folder ("+" menu, space menu, Tabs menu, command bar,
  "Move to Folder ▸ New Folder with Tab", or drop a tab on a tab) creates an
  expanded folder in Pinned and prompts for a name. Folders nest. Click a
  folder to collapse or expand it. A collapsed folder still shows its
  selected tab. Drop onto the middle of a folder row to move the item in,
  and near a row's top or bottom edge to place it before or after (an
  insertion line shows where). A folder's menu renames it, adds a folder
  inside, expands or collapses all, removes the folder while keeping its
  tabs, or deletes it with its tabs (they go to the Archive).
- **Pin, unpin, favorite.** Drag between Favorites, Pinned and Today (the end
  of each section is a drop zone, and an empty section shows one), use ⌘D
  (Pin/Unpin Tab), or use the context menu. ⌘W on a favorite unloads it: its
  engine is dropped and it stays in the strip. Remove from Favorites deletes
  it.
- **Context menus** on tabs, favorites, folders, split views, easels and the
  space header: pin/unpin, add to or remove from favorites, rename,
  duplicate, copy link, move to folder or space, open in Little Arc, edit
  boost, archive, close.
- **Spaces.** ⌃1…9 select the Nth space of the active profile, and ⌥⌘→ / ⌥⌘←
  go to the next or previous one. The space header and switcher menus rename
  the space, open Edit Theme and Icon (27 swatches, a custom color, SF Symbols
  or an emoji) or delete it after confirmation (its tabs go, its engines are
  dropped). The last space cannot be deleted.
- **Profiles.** Deleting a profile that owns spaces asks first, then deletes
  it along with them.
- **Auto-hide.** With the sidebar hidden (⌘S), moving the pointer to the
  window's leading edge floats it over the page, and it hides again once the
  pointer moves away. A local mouse-moved monitor drives this, so it works
  over WKWebView and the Chromium host view.
- **Archive.** Closing or archiving a pinned or Today tab keeps a full
  record (not blank tabs). View Archive (bottom bar, Tabs menu, command bar)
  groups records by time, searches them, restores one to the top of Today
  in its space, and clears them. Records older than 60 days are dropped
  (Arc's data shows about 59 days). Today tabs not selected for the active
  profile's threshold (12 hours by default, or 24 hours, 7 days, 30 days:
  profile menu or Archive view) are archived automatically, checked at
  launch and every five minutes. The selected tab is never archived.
- **Favicons.** Chromium tabs read icons through `ReArcFaviconGet` when the
  favicon event arrives. WebKit tabs fetch the page's `<link rel=icon>`
  (nearest 32 px) or `/favicon.ico` over an ephemeral `URLSession`, and
  private windows skip the fetch. Icons are cached by host on disk, so
  unloaded tabs keep theirs. Rows fall back to a letter.

## Sidebar (wave 19)

- **Pinned tabs keep their URL.** A tab saves its URL and title when it is
  pinned (`Tab.savedURL`). ⌘W, or the row's close button, unloads a pinned
  tab: its engine is dropped, it goes back to the saved URL and stays in
  Pinned. Delete Tab (context menu) removes it to the Archive. When a pinned
  tab has navigated away, its row shows "Back to the pinned URL" on hover,
  and the context menu has Reset to Pinned URL and Make This the Pinned URL.
  Tabs menu and command bar: Reset Tab to Original URL, Reset All Tabs in
  This Space.
- **⌘1…⌘8** select that row of the sidebar (favorites, pinned, Today; a
  split is one row) and **⌘9** the last one (Tabs > Tab 1…Last Tab).
- **Space bar.** The bottom bar shows every space of the window's profile.
  Click one to switch, drag it to reorder (also Spaces > Move Space
  Left/Right), or drop a tab, folder, split or easel on it to move it there.
  The item keeps its section (end of Pinned, top of Today). Hold a drag on a
  space for 0.7 s to switch to it and place the item precisely.
- **New Space dialog** (name, profile, theme, icon) from the "+" menu, the
  space list, the Spaces menu, the space menu and the command bar. Nothing
  is created until Create.
- **One space per window.** Each browser window shows its own space and
  that space's selection: sidebar, content, theme, URL field and favorites.
  The key window's space is the active one, so menus, shortcuts and the
  command bar act on it, and a window that becomes key brings its space
  back. Window spaces are not restored after relaunch.
- **Today** has a divider with Clear (archive every Today tab in the space,
  then Undo Clear) and ends with a "+ New Tab" row.
- The row speaker **toggles mute**; a muted tab shows a muted speaker.
- The sidebar **resizes** from its trailing edge (200–420 pt, remembered).
- **Splits.** Split with Current Tab (row context menu) joins that tab to
  the selected one, in its split when there is room. Add Split View inside
  a split adds a blank pane, up to four.

Limits: splits and easels cannot go into folders (folders hold tabs and
folders), and folders live only in Pinned. Folder expansion is shared by
all windows (Arc keeps it per window). The Archive and the auto-archive
threshold are local and not journaled for sync. An existing space cannot
change profile yet (the dialog picks it at creation).

## Model rules worth knowing

- Favorites belong to a **profile** and show in every space of that profile
  (Arc keys `topApps` by profile). Schema 10 moves the old global strip to
  the first (default) profile; other profiles start with no favorites.
  Pinned and today tabs are per space. New today tabs insert at the **top**
  of their section.
- Folders (`SidebarEntry.folder`) nest in a space's pinned section. Tabs
  inside a folder have kind `.pinned`, and lookup, update and removal recurse
  (`SidebarTree`). `displayEntries` lists folder contents inline, so
  selection cycling and Ctrl+Tab go through them.
- `moveItem(_:to:index:)` is the single placement path. Favorites hold plain
  tabs, Today holds no folders, split panes move only with their split, and
  a folder never goes inside itself. The tab kind follows the destination.
  `moveTab(_:to:)` still only reorders inside the item's own container.
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
| ⌘W | Close selected tab, or a private window (⌘W is stripped from File > Close Window) |
| ⇧⌘N | New private window |
| ⌘= / ⌘- / ⌘0 | Zoom in / out / actual size |
| ⌘S | Toggle sidebar (when hidden, point at the left edge to float it) |
| ⌘⇧] / ⌘⇧[ | Next / previous tab |
| ⌃⇥ | Next tab |
| ⌘[ / ⌘] | Back / forward |
| ⌘R / ⇧⌘R / ⌘. | Reload / reload ignoring cache / stop |
| ⌘D | Pin or unpin the selected tab |
| ⌘1 … ⌘8 / ⌘9 | Select that sidebar row / the last one |
| ⌘Y / ⌥⌘L | History / Downloads (Chromium with `webui_daily_pages`) |
| ⇧⌘C | Copy the page URL |
| ⌃1 … ⌃9 | Switch to space 1–9 of the active profile |
| ⌥⌘→ / ⌥⌘← | Next / previous space |

## Sync: not implemented

**Nothing syncs.** Sidebar state lives only in the local `sidebar.json`.
What exists is the local groundwork:

- A **mutation journal** records sidebar mutations with LexoRank ordering, a
  device id and a monotonic sequence. Folder placement is its own mutation,
  `placeItemInFolder`. `SyncOutboundPipeline` coalesces the journal and hands
  it to a `SyncEngine`, and `CloudKitRecordMapper` maps entries to CloudKit
  record fields (unit-tested). None of it reaches a server.
- `LocalSyncEngine` (SwiftPM dev builds) keeps everything on the machine,
  and the bottom-bar dot stays grey.
- `CloudKitSyncEngine` is a **stub**. It is used only when the bundle
  declares the iCloud container `iCloud.net.rearc.sidebar`. `push` maps
  the records and discards them, and `pull` returns nothing. It never
  creates the `com.rearc.sidebar.graph.v1` zone or calls a CloudKit
  operation. Since wave 19 it always reports
  `unavailable("CloudKit upload is not implemented; sidebar changes stay on
  this Mac")`, so the dot stays grey. `SyncOutboundPipeline` no longer sets
  a status itself, and `SyncStatusPresentation` shows green only for
  `idleSynced`, which only an engine with a confirmed upload may report.
  Without the entitlement, `makeEngine()` returns `unavailable(reason:)`.

Real sync (zone setup, record upload and fetch with change tokens, conflict
merge, then the end-to-end encryption in `docs/SYNC-DESIGN.md`) is future
work. The Archive, folder expansion and auto-archive thresholds are not in
the journal.
