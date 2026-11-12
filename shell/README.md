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

Settings → Advanced also offers **Auto-hide address bar** (off by default).
See [behavior and visual verification](../docs/AUTO-HIDE-ADDRESS-BAR.md).

Settings → Max holds scripted helpers, not AI: Tidy Tab Titles, Tidy
Downloads, Tidy Tabs and Instant Links follow fixed rules on this Mac and
send nothing, and the assistants are shortcuts to each company's own site
(all off by default; see [docs/FEATURE-SPECS/MAX.md](../docs/FEATURE-SPECS/MAX.md)).

## Engines

`WKEngine` (WKWebView) is the default. The Chromium engine (`ChromiumEngine`,
over the C ABI in `engine/docs/C-ABI.md`) is used only when **both**:

1. it is requested, with `--rearc-engine=chromium` or `REARC_ENGINE=chromium`
   (the flag wins; `--rearc-engine=webkit` forces WebKit), and
2. the binary was built with `REARC_CHROMIUM` and runs from a bundle that
   embeds `Chromium Framework.framework`.

Otherwise the request is ignored with a warning on stderr and the WebKit path
runs unchanged. `ReArcMain` makes this choice before `ReArcApp.main()`.

The Chromium bundle needs no argument: `scripts/bundle-chromium.sh` writes
`ReArcDefaultEngine=chromium` to its Info.plist, the lowest-precedence choice
(then `REARC_ENGINE`, then the flag), so Finder, the Dock, `open` and links
from other apps start Chromium. Its principal class is Chromium's
`BrowserCrApplication`, whose `+initialize` aborts unless ChromeMain set up
the command line, so the WebKit path can never run in that bundle: when that
class is present, `ReArcMain` uses Chromium even for `--rearc-engine=webkit`
(logged), and exits with status 70 rather than abort if Chromium cannot start.
`scripts/check-launch.sh [ReArc.app]` (or `bundle-chromium.sh --launch-check`)
launches the bundle with `open`, once plain and once with a link, under
`--rearc-launch-probe` (a throwaway profile, no sidebar model), and checks
that it reaches `ready` on Chromium with the link delivered.

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
"Keychain" below), `--launch-check` (see above).

Bundle layout (component build, see "Linking and startup" in C-ABI.md):

```
dist/chromium/
  ReArc.app/Contents/MacOS/ReArc                       shell executable, rpath @executable_path/../Frameworks
  ReArc.app/Contents/Frameworks/Chromium Framework.framework   physical copy (helpers, Info.plists, resources)
  *.dylib                                              component dylib closure next to the .app
```

Both bundle scripts install the ReArc icon (`Resources/ReArc.icns`, rendered
from `brand/app-icon.svg`) as `Contents/Resources/ReArc.icns` with
`CFBundleIconFile=ReArc`. The Chromium bundle also drops `CFBundleIconName`,
whose `AppIcon` in Chromium's `Assets.car` would otherwise win; `Assets.car`
stays for its other assets. After rebuilding an installed copy, `touch` it
and re-register it with `lsregister -f` so Finder and the Dock refresh.

The framework's `@loader_path/../../../../../..` rpath resolves to the
directory that contains `ReArc.app`, so the dylibs must stay beside it. The
script checks that every `@rpath` dependency of the executable, framework and
dylibs resolves.

Flags and environment:

| | |
|---|---|
| `--rearc-engine=chromium\|webkit`, `REARC_ENGINE` | engine selection |
| `--rearc-selftest` | Chromium runtime proof; exits 0 on success, nonzero on failure, 124 on the 300 s watchdog |
| `--rearc-launch-probe=PATH` | reach `ready` on a temp profile, write `ready=1 engine=… source=… links=…` to PATH, quit (`scripts/check-launch.sh`) |
| `--user-data-dir=PATH` | Chromium profile dir (default `~/Library/Application Support/ReArc/Chromium`; temp dir for the self-test) |
| `REARC_CHROMIUM_TRACE=1` | log every tab/service event and engine call (including script evaluations) to stderr; a shipped bundle ignores it |

### ABI 1.5 adoption

The shell still calls `ReArcEngineConfigure(1, …)`. After `ready` it probes
`ReArcEngineABIMinorVersion()`; the framework is weak-linked, so the symbol is
looked up with `dlsym` first and an engine that predates the export counts as
minor 0. `ChromiumCapabilities` enables a feature only when the minor version
is at least the one that introduced it (5 for the three below, 6–10 for the
ABI 1.10 features, 11–14 for the ABI 1.14 ones, 15–17 for the wave 20 ones,
18–22 for the wave 22 prompt channels, 23–27 for wave 23, 28–30 for
wave 24, 42 for wave 30's key verdicts)
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
- **Containers** (`SidebarStore+Containers.swift`, docs/SPACE-CONTAINERS.md)
  are a separate browsing session for one space inside a profile. Underneath
  a container is a `Profile` whose `containerOf` names its parent, so it has
  an engine profile of its own like any profile; `Space.profileID` stays the
  storage key. Listings and settings go through the owning profile
  (`spaces(listedIn:)`, `owningProfileID(of:)`, `listedProfiles`).
  `ContainerChip` shows the container of the engine a page runs in, in chrome only.
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
  ChromePasswordManagerClient fills saved credentials. Save offers arrive
  with ABI 1.22 (wave 22, below). Tabs present at
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
  not_found falls back to Finder / Launch Services. "Ask where to save"
  needs the ABI 1.19 file chooser (wave 22, below). On WebKit, attachments and
  main-frame responses WebKit cannot show become `WKDownload`s
  (`WebKitDownloadCenter`). Unless Ask where to save is on, they are saved
  without asking into the same folder, uniquified like Chromium ("name (1).ext"), and quarantined when
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

### ABI 1.18–1.22 adoption (wave 22)

Follows "Host prompt channels (wave 18c)" in `engine/docs/C-ABI.md` and
`engine/docs/WAVE-18C-REPORT.md`. Each channel is gated on its minor and
flag (`javascript_dialogs` 18, `file_chooser` 19, `permission_prompts` 20,
`context_menu` 21, `password_prompts` 22, which also needs
`password_autofill`); Configure still takes 1. `ChromiumRuntime` registers
every adopted callback at `ready`, before any tab
(`ChromiumPrompts.swift`). The callbacks copy the borrowed strings and
arrays, then route by tab ID to the engine. A request for a tab the shell
does not know gets the conservative answer at once (reject, cancel,
dismiss). Phase 1 events withdraw a request without a reply. Every reply
is one main-thread call that consumes the request, and a late reply is
`not_found`.

Both engines feed one `PagePromptCenter` per page (`Prompts/`). The
overlay is part of every engine view (tabs, split panes, peek, Little
Arc, private windows), so a prompt dims and blocks only its own page.
The sidebar, other tabs and other windows keep working.

- **JavaScript dialogs.** alert, confirm and prompt show as a sheet
  centered over the page: "<host> says", the page's text (plain and
  scrollable), the prompt field, and OK / Cancel with Return and Esc.
  From the second dialog on the same document, the sheet offers "Don't
  allow this page to create more dialogs". After that, alerts are
  acknowledged and confirms and prompts cancelled without UI until the
  next document (`JavaScriptDialogGuard`). Navigation, a closed frame or
  tab, and engine cancellation withdraw the sheet. Prompt text is clipped
  to the ABI's 64 KiB. Keyboard focus returns to the page after the last
  dialog.
- **Leave site?** Cmd+W and the row's close button go through
  `ReArcTabClose(tab, force: false)` (`PageClosing`). Chromium runs the
  page's beforeunload, and "Leave site?" (or "Reload site?") arrives as a
  dialog. The tab is shown first if it was in the background. Stay vetoes
  the close (completion OK, cancelled) and the tab stays. Navigation runs
  through the same prompt, and Stay puts the URL field and sidebar tab
  back on the committed page. Chromium shows the prompt only after the
  page had user activation. Other closes (Delete Tab, a closed split, a
  deleted space) still force-close.
- **File choosers.** NSOpenPanel or NSSavePanel opens as a sheet on the
  page's window, so only that window waits: open, open multiple, upload
  folder (the engine walks it, skipping symlinks), directory and save.
  The page's accept list becomes `allowedContentTypes` when macOS knows
  every type, and otherwise the advisory filter is dropped. Replies are
  checked against the ABI rules (absolute, no `..`, one path unless
  multiple, 4096 paths of 4096 bytes), because an invalid reply would
  leave the request pending. Engine cancellation closes the panel.
- **Ask where to save.** "Ask Where to Save Each File" in the downloads
  tray's folder menu is saved in `Downloads.json`. On Chromium it sets
  `ReArcDownloadSetPolicy(profile, directory, 1)` for every open profile.
  Chromium then asks for the path through the file chooser (save mode),
  and the shell answers with a save panel on the downloading tab's window
  (`ChromiumDownloadBackend` presents it in the key window when no live
  tab owns the request). The panel confirms replacing a file, and Cancel
  cancels the download. WebKit asks in `decideDestination`. The toggle is
  disabled on Chromium engines before 1.19.
- **Permission prompts.** A card at the page's top leading corner, next to
  the sidebar's URL field: "<host> wants to" with one line per request
  ("Use your camera and microphone" for a coalesced request), the
  embedding site for iframes, and a note when macOS also authorizes the
  device (camera, microphone, location). It offers Block, Allow, × to
  dismiss, and "Remember this decision" (on by default) as `persist`.
  Dismiss never persists. Every answer is recorded in `SitePermissions.json`
  (remembered answers of persistent profiles only; a private session's go
  with it). The URL field shows a permissions icon for sites with
  answers, orange when something is blocked. Its popover lists them.
  On Chromium, which keeps remembered settings itself, it links to Site
  Settings (`chrome://settings/content/siteDetails?site=<origin>`). On
  WebKit each answer resets in place. Both bundles declare the camera,
  microphone and location usage strings and sign with the device
  entitlements (`scripts/ReArc.entitlements`).
- **Page menu.** `PageContextMenuPlan` builds Chrome's variants from the
  event: link, image (Open Image in New Tab, Save Image As…, Copy Image,
  Copy Image Address), selection and editable (Cut / Copy / Paste with
  the page's edit flags, Select All), and the page (Back, Forward, Reload,
  Select All, View Page Source). Arc adds Open Link in Little Arc, Open
  Link in New Split (sidebar tabs only), Copy Link and Search for
  "<selection>". The NSMenu opens at the event's point after the callback
  returns. Engine items run as `ReArcContextMenuCommand`, and Arc items
  run in the shell and dismiss the request. Every menu ends with a
  command, closing without a choice included. A refused command (disabled,
  or Inspect) is followed by a dismiss. The engine answers Inspect with
  `unsupported`; since ABI 1.40 (wave 28) the shell's Inspect opens its own
  DevTools instead, and before it Inspect is listed disabled.
- **Password offers.** A card at the page's top trailing corner: "Save
  password for <host>?" (or Update) with the username, Never (not for
  updates), Not Now and Save. The answer goes back as
  `ReArcPasswordPromptRespond`. No password crosses the ABI and the shell
  stores nothing. Chromium saves, blocklists and encrypts, and
  chrome://password-manager manages the store.
- **WebKit.** WKUIDelegate drives the same center: alert, confirm and
  prompt panels, `runOpenPanelWith` (open, multiple, folder), and camera
  and microphone requests. Remembered answers are replayed from
  `SitePermissions.json`, since WebKit keeps none. `ReArcWebView` keeps
  WKWebView's own menu, which already has its variants and commands. It
  turns "Open … in New Window" into "Open … in New Tab", replaces the web
  search item with "Search for …", and adds Little Arc and New Split. A
  `contextmenu` listener reports the link, image and selection just
  before the menu opens. WebKit has no public beforeunload, geolocation
  or notification delegate, so pages leave without asking and location
  and notifications are unavailable there.

### ABI 1.23–1.27 adoption (wave 23)

Follows `engine/docs/C-ABI.md` (sections 1.23–1.25) and
`engine/docs/WAVE-18D-REPORT.md`, with the search and fullscreen contracts
from the header (1.26–1.27). Each feature is gated on its minor and flag
(`history_query` 23, `dangerous_downloads` 24, which also needs
`downloads`, `tab_discard` 25, `search_autocomplete` 26,
`html_fullscreen` 27). Configure still takes 1. Every call copies its
borrowed rows and strings, and a synchronous rejection releases its
context at once (the self-test checks that none is left).

- **Command-bar history.** On Chromium, `ChromiumCommandBarServices`
  (`Chromium/ChromiumCommandBar.swift`) asks the profile's HistoryService
  (`ReArcHistoryQuery`, 50 rows) for every keystroke. Its rows replace
  `History.json` for that text and are ranked by the same match quality
  and frecency (`CommandBarSearch`), so history from before the shell's
  own store shows too. WebKit keeps `History.json`. Off-the-record
  profiles are never asked.
- **Row actions.** Rows show Copy URL and, for history, Remove from
  History on hover, on the highlighted row and in their context menu.
  Shift+Delete removes the highlighted history row. Removal clears
  `History.json` and, on Chromium, calls `ReArcHistoryDeleteURL`, then
  asks again for the typed text.
- **Search.** The default search comes from the profile's
  TemplateURLService (`ReArcSearchGetDefaultProvider`, re-read whenever
  the command bar opens, so chrome://settings/search changes apply). It
  builds the search row, the private window's address field and the page
  menu's "Search for". `ReArcSearchClassifyInput` decides URL versus
  search for the typed text (so `localhost:3000` or an intranet host
  opens instead of searching). `ReArcAutocompleteStart` (inline
  autocompletion off) runs per keystroke. A new start supersedes the
  last, which ends cancelled, and closing the bar stops it. Its search
  matches show after history, four at most, minus the typed text itself.
  WebKit uses the ReArc > Search Engine preference (DuckDuckGo by
  default, or Google, Bing, Ecosia, Brave Search) and, unless Search
  Suggestions is off, asks the provider's OpenSearch suggest endpoint
  over an ephemeral session with no cookies, debounced and cancelled per
  keystroke. Private windows have no suggestions on either engine.
  Results for older text are dropped (`CommandBarQueryGate`), and the
  Tab-to-search pill (wave 21) still takes over the bar when chosen.
- **Dangerous downloads.** The tray asks `ReArcDownloadGetWarning` on
  each event of an unfinished item and uses its booleans, not the danger
  code, to offer Keep… (with a confirmation) and Discard. Keep calls
  `ReArcDownloadResolveDanger(keep)` and asks again, since an item with
  an insecure and a dangerous warning needs two decisions. Discard
  removes the item and its file through Chromium. "Review…" on
  chrome://downloads remains only for engines before 1.24.
- **Unload tabs.** Unload Tab (tab and favorite context menus), ⌘W on a
  pinned tab still on its saved URL and on a favorite, and the automatic
  unload (Archive > Unload Inactive Tabs: never, 30 minutes, 1, 4 (the
  default) or 12 hours unseen, checked with auto-archive every five
  minutes) call `ReArcTabDiscard`. The page goes, while its WebContents,
  back/forward list, boosts and lease stay, and the tab reloads when
  shown. The discard is retried while the view detaches. If Chromium
  keeps refusing (media, an unload handler), an explicit unload drops
  the engine and the automatic one leaves the tab loaded. Kinds 5 and 6
  of the tab event keep `ChromiumEngine.isDiscarded`. Unloaded rows show
  a greyed, dimmed icon until the tab is shown. WebKit drops the engine
  instead, and the tab loads its URL when shown.
- **HTML fullscreen.** With the callback registered at `ready`, a page's
  `requestFullscreen()` makes its window native fullscreen.
  `BrowserView` hides the sidebar and the page card's inset in that
  window, in the same view tree, because detaching the page would end
  fullscreen. The page leaving (its own exit, Escape, navigation, hiding,
  closing) restores the window and sidebar as they were. Leaving native
  fullscreen with the green button or ⌃⌘F calls `ReArcTabExitFullscreen`.
  A window already fullscreen stays so. The host keeps the state it
  wants and toggles once AppKit has finished a transition, since a toggle
  during one is ignored. WebKit enables `isElementFullscreenEnabled`, and
  WKWebView shows its own fullscreen window.
- **Inspect.** The wave 22 placeholder `devtools` gate is gone: through
  ABI 1.39 no engine advertises DevTools, so Inspect stays listed disabled.
  Engine wave 18h added the real `devtools` feature at ABI 1.40, which the
  shell adopts in wave 28 (`canInspect` follows it).

### ABI 1.28–1.30 adoption (wave 24)

Follows `engine/docs/C-ABI.md` (sections 1.28–1.30) and
`engine/docs/WAVE-18E-REPORT.md`. Each feature is gated on its minor and
flag (`printing` 28, `page_drops` 29, `picture_in_picture` 30). Configure
still takes 1. `ChromiumRuntime` registers the print and PiP callbacks
and sets the drop policy at `ready`, before any tab. Without them the
engine completes print requests silently, aborts every drop and refuses
PiP.

- **Printing.** File > Print… (⌘P), the command bar's "Print…" and a
  page's `window.print()` go through one `PagePrinter`
  (`Printing/PagePrinter.swift`). It allows one job per page: a request
  while that page's panel is open is dropped. On Chromium the page's
  request has already completed for the page (beforeprint and afterprint
  fire) when the print event arrives. The shell asks
  `ReArcTabPrintToPDF` for a PDF laid out on the paper the print panel
  starts with (`NSPrintInfo.shared`; Chromium's default margins). It
  prints that PDF through PDFKit's `NSPrintOperation`, shrinking it only
  when the chosen paper is smaller, with the native print panel as a
  sheet on the tab's window. File > Export as PDF… asks with a save
  panel sheet and writes the same paginated PDF. On WebKit, printing is
  `WKWebView.printOperation` and Export as PDF is `createPDF`: one page
  as tall as the document, like Safari's Export as PDF. WebKit has no
  public print delegate, so a page script forwards `window.print()` to
  the shell, and beforeprint and afterprint do not fire there.
- **Drops into pages.** The policy (`PageDropPolicy.shell`) accepts files,
  text, links and images, and blocks `com.rearc.sidebar-item`. Every
  sidebar drag (tabs, folders, splits, easels, favorites, space icons)
  now carries that type next to its UUID text (`SidebarDragPayload`).
  Chromium therefore never offers it to a page: no events, no
  operation. `ReArcWebView` declines it the same way on WebKit. The
  wave 21 drag-to-split target registers the private type and reads
  the ID from it first, and it still sits above the page only during a
  sidebar drag.

  **Unhandled drops: Chrome's and Arc's behaviour.** A page that
  takes a drop (a `dragover` it cancels) gets it. A file or link
  dropped where the page does not take it opens in that tab, as in
  Chrome and Arc (both Chromium, which navigates the frame) and in
  Safari. Back returns, and a page with unsaved work still asks "Leave
  site?" first. Plain text and raw image bytes dropped outside an
  editable field or drop target do nothing. The engine gives the host no
  veto over that navigation. A shell-side undo (going back after the
  fact) would reload the page and lose its state, so the shell does not
  try one. For a drop that leaves the page alone, use the sidebar, as in
  Arc: links and files dropped on a sidebar row or a section's end open
  as Today tabs at that position, and the first is shown
  (`SidebarURLDrop`: http, https and file URLs, once each, at most 20).
- **Picture in Picture.** View > Picture in Picture and the command bar's
  "Picture in Picture" put the selected tab's video in PiP, or bring it
  back. Chromium enters through the tab's media session
  (`ReArcTabSetPictureInPicture`) and shows its own floating overlay
  (play/pause, back to tab, close). Media events carry `pip_available`
  and `pip_active`, which map to `WebMediaState.canPictureInPicture` and
  `isPictureInPicture`. Chromium offers host-started PiP only for one
  normal player with unmuted audio: never WebRTC or canvas streams, or
  a video without sound. Document PiP is unsupported. The overlay's back
  to tab (phase 2) selects the tab, in its space, and brings its window
  forward. WebKit uses the standard PiP API (with
  `webkitSetPresentationMode` as fallback), which may want a recent user
  gesture. A sidebar row (and a favorite) in PiP shows a PiP badge.
  Clicking the row's badge brings the video back.
- **Automatic PiP.** Arc's automatic Picture in Picture, on by default
  (ReArc > Automatic Picture in Picture), saved in user defaults
  (`AutoPiPPolicy.tabSwitchPlan`). Switching away from a tab whose video
  plays puts it in PiP. Showing that tab again brings the video back. A
  PiP started by hand stays when you switch. Only one PiP window
  exists, so an audible video wins and a video already in PiP keeps the
  window. Snoozed and disabled sites are skipped. The wave 17 occlusion
  trigger follows the same setting. Chromium's own auto-PiP is not wired
  for registry tabs (WAVE-18E-REPORT), so the shell drives it. WebKit
  follows the same rules within its gesture limit.

### ABI 1.31–1.38 adoption (wave 27)

Follows `engine/docs/C-ABI.md` (sections 1.31–1.38),
`engine/docs/WAVE-18F-REPORT.md` and `engine/docs/WAVE-18G-REPORT.md`. Each
feature is gated on its minor and flag (`extension_tab_helpers` 31,
`extension_install_prompts` 32, `extension_actions` 33,
`autofill_suggestions` 34, `password_leak_detection` 35,
`extension_windows` 36, `autofill_save_prompts` 37, `http_auth` 38).
Configure still takes 1. `ChromiumRuntime` registers every adopted
callback at `ready`, before any tab (`ChromiumExtensions.swift`,
`ChromiumAutofill.swift`); a request for a tab the shell does not know gets
the conservative answer (cancel, decline, dismiss, ignore). WebKit has no
extensions or autofill, so those stay hidden there.

- **Extensions toolbar.** As in Arc, pinned actions sit in the sidebar's
  top row, beside the navigation buttons: icon, badge (Chromium's text and
  colors, four characters at most) and a dot when blocked scripts wait for
  a click. The puzzle button lists every extension of the tab (Chromium's
  registry order) with its pin, then Manage Extensions (chrome://extensions)
  and Chrome Web Store; View > Chrome Web Store opens the store too. Pins
  are the shell's (`ExtensionPins`, user defaults). Actions are per tab and
  re-read on every action event, which carries no state.
- **Popups.** A click calls `ReArcTabRunExtensionAction`. A popup result
  registers the popup tab before its created event, so it is never adopted
  as a sidebar tab. Its registry tab attaches in a borderless panel under
  the button (`ExtensionPopupPresenter`), sized by the renderer's resize
  events within 25×25–800×600. It closes on the page's `window.close()`,
  focus loss, Escape, a tab switch and a second click on its button. The
  panel is ordered out, never closed, so its engine window registration
  stays valid. Side-panel actions show a toast (unsupported by the engine).
- **Prompts.** Install, re-enable, permission and uninstall confirmations
  are NSAlert sheets on the tab's window (the key window for prompts that
  belong to no tab), with Chromium's localized title, buttons, permission
  lines and the extension's icon. A withdrawal closes the sheet without a
  reply. Installed and failed notices show as a toast.
- **Logical windows.** Arc has no tab strips, so each space is a window to
  extensions, and so is each Little Arc window; the key window's space is
  focused. `ExtensionWindowReporter` (pure, tested) diffs that model against
  the engine's side effects and sends only the changes, driven by
  observation of the store with a 2 s safety net. `tabs.create` and
  `runtime.openOptionsPage` get a blank today tab in the current space (or
  the window's space for an explicit window ID, never another profile's),
  which the engine then navigates; `windows.create` opens a Little Arc;
  activation selects the tab. Anything else is declined (answer 0).
- **Autofill suggestions.** Chromium decides when the list shows and hides,
  fills, previews and routes the field's keys (Up/Down select, Return and
  Tab accept, Escape hides; the selection arrives as phase 2). The shell
  draws address, card, password, IBAN, autocomplete and datalist rows with
  icons in a non-activating child panel anchored to the reported field
  bounds, below the field or above it near the screen's bottom
  (`AutofillPopupLayout`). The panel never becomes key, since Chromium hides
  the list when the page loses focus. A click accepts (an early accept that
  returns busy is retried after Chromium's 500 ms guard); hover previews.
  Password rows show fixed bullets, never the engine's label. Manage… opens
  the URL the engine returns (chrome://settings/contactInfo, /payments,
  /autofill or chrome://password-manager/passwords) as a tab.
- **Save offers.** Chromium's local card and address offers appear as a
  card at the page's top trailing corner, under a password offer: Save (or
  Update), No Thanks (decline), and the close button (ignore). Card
  summaries carry the network, last four, expiry and name only.
- **HTTP auth.** Basic and Digest challenges show a sign-in sheet over that
  tab only: challenger, the server's realm, a warning on plain http,
  username and password. Cancel shows the server's 401 page. The
  credentials go back once (`ReArcHttpAuthRespond`) and the fields are
  cleared; Chromium keeps its auth cache. WebKit's `didReceive challenge`
  uses the same sheet. Client certificates came at ABI 1.41 (wave 28).
- **Check Passwords for Leaks.** ReArc > Check Passwords for Leaks shows the
  default profile's `profile.password_manager_leak_detection` (on by
  default, as in Chrome) and sets it on every open persistent profile; an
  explicit choice is applied to profiles as they open. A managed (policy)
  profile keeps its policy; off-the-record profiles never check.

- **Modified link clicks (ABI 1.39 `link_open_requests`, which also needs
  `extension_windows`).** Chromium hands every gestured HTTP(S) open that
  is not a plain click to the shell (`ReArcEngineSetLinkOpenCallback`).
  The shell makes a blank tab in the link's profile, places it, reports it
  in the logical window and answers with `ReArcLinkOpenRespond`; Chromium
  then runs the original navigation (referrer, initiator, body), and the
  page itself stays put. `LinkOpenPlacement` maps the disposition:
  ⌘-click and middle-click (background) give a today tab under the
  source's space, left unselected; ⇧⌘-click (foreground) gives a selected
  one; ⇧-click (new window) opens Little Arc, Arc's one-page window, in
  pages without link peek (sidebar tabs peek on ⇧-click, which takes the
  click first); a
  split disposition puts a new pane next to the source tab (a new tab when
  the source is not a sidebar tab). ⌥⌘ held at the click keeps wave 26's
  rule, Little Arc, as on WebKit and for `target=_blank` links. At this
  pin Chromium reports ⌥⌘-click as the split disposition, so splits from a
  click come only from a future mapping or the page menu's Open Link in
  New Split. Chromium-created contents (`target=_blank`, `window.open`)
  still arrive through tab adoption.

Security interstitials need no shell work: Chromium renders them inside
the tab, with their own proceed and back controls. DevTools and client
certificates came with engine wave 18h (ABI 1.40–1.41, below).

### ABI 1.40–1.41 adoption (wave 28)

Follows "Shell adoption" in `engine/docs/WAVE-18H-REPORT.md`. Each is gated
on its minor and flag (`devtools`, `client_certificates`).

- **DevTools.** View > Developer > Developer Tools (⌥⌘I) toggles the
  selected tab's DevTools, and the page menu's Inspect opens them (the
  engine command Inspect stays `unsupported`, so the shell dismisses the
  request and calls `ReArcTabOpenDevTools` itself). The call returns a new
  registry tab with Chromium's bundled frontend. Its `tab.created` (opener =
  the page) is caught before tab adoption, so it never becomes a sidebar
  tab, and it is attached like any other tab. It shows docked as a pane on
  the right of the page, Arc's default, with a draggable divider, Open
  Developer Tools in a Window and Close. The window has Dock to Page, and
  closing it closes the frontend. The shell keeps one frontend per tab
  (`DevToolsSessions`); closing them explicitly closes the frontend registry
  tab, even while a view or caller retains its engine. The
  engine closes the frontend when its page goes, whatever closed it, and
  the shell then removes the pane or window. The docked pane shows for a
  tab on its own, not inside a split. WebKit has no DevTools: Inspect stays
  disabled there.
- **Client certificates.** The callback is registered at `ready`, before
  any HTTPS page loads. A request opens a sheet over that tab only: the
  server (`https://host:port` of the challenger), then each identity's
  subject, issuer and expiry (valid ones first; the SHA-256 fingerprint is
  in the row's help). OK (or a double-click) sends the fingerprint with
  `ReArcClientCertificateRespond`, Cancel sends none: the page shows
  Chromium's error, nothing is cached and the page is not asked again until
  it is loaded again. Chromium caches a choice per host and port. A
  withdrawal (navigation, close, the 30-second deadline) closes the sheet
  without a reply. WebKit keeps WKWebView's default handling.

### ABI 1.42 adoption (wave 30)

- **`key_equivalent_events`: page verdicts on shortcuts.** Engine patch
  `tab/061-host-key-equivalent-events` observes every widget of a tab and
  posts each Command or Control key-down the page acknowledges to
  `ReArcEngineSetKeyEquivalentCallback`, with `consumed` set when the page
  took it. `ChromiumShell` hands verdicts to `ShortcutRouter.pageVerdict`.
  An unconsumed key runs its menu item; a consumed website-first key shows
  Arc's "again" prompt (docs/SHORTCUTS.md "Routing"). Below ABI 1.42 only
  Arc-wins keys work while a page has focus, as the monitor runs them before
  the page.

### ABI 1.43 adoption (wave 32)

- **Arc's media strip.** `MediaControlsStackView` replaces `MiniPlayerView`
  at the bottom of the sidebar, 8 pt above the bottom bar (where Arc's
  update pill would sit) with 8 pt side insets. Each strip is 33 pt tall at
  the sidebar's width less 16 (212 pt in Arc's 228 pt sidebar), radius 8, an
  opaque `#FDFDFF` fill (an elevated `#2B2B30` in dark mode) and a soft
  all-round shadow. It has five equal slots: favicon (back to tab), previous,
  play/pause, next and volume. Glyphs use `PlaybackControlForeground`, black at
  50 % (white at 66 % in dark mode); disabled previous and next are at 35 % of
  that. Hover draws a round highlight behind a glyph. Hovering the card
  expands it upward with a title row (favicon, title, site, "Close Mini
  Player") over grouped transport controls, "Open Picture in Picture" when it
  applies, and the speaker. It collapses 350 ms after the pointer leaves.
- **When strips show** (`SidebarModel.MediaControlsModel`, MINI-PLAYER.md
  §3.2). A tab gets an entry when it starts playing, and its strip shows while
  the tab is not on screen in that window (its space's selection, or any pane
  of its split). A paused strip stays. The entry goes when the session ends
  (no playback, pause or sound), when the tab closes, or after Close; a closed
  strip comes back the next time the tab starts playing. Several sources stack
  newest first, three at most: collapsed, the front card with two peeking
  behind it; on hover, a list.
- **Track state.** `ReArcTabGetMediaActions` (ABI 1.43) gives the media
  session's actions on every media event, so previous and next are enabled
  only when the page handles them. Below 1.43 both stay enabled and the engine
  rejects an unsupported skip. WebKit reports paused media but no track
  actions.
- **Live video (`pip_embedded`).** Engine patch `tab/062-embedded-video-overlay`
  renders Chromium's video-PiP surface into an engine NSView
  (`ReArcEngineSetVideoOverlayCallback`) instead of Chromium's floating
  window. `ChromiumRuntime` keeps a `ChromiumVideoOverlay` per overlay and
  `ChromiumEngine.liveVideo` exposes the shown one (`LiveVideoHandle`). The
  same view moves between hosts, and the video keeps its native frame rate
  while its tab is hidden.
  - **Video in Sidebar** (ReArc > Video in Sidebar, on by default; a ReArc
    addition the user asked for): the video sits in the sidebar above its
    strip row in one 8 pt card, 16:9 at the sidebar's width (height from the
    video's aspect, clamped to 90–160 pt). Hover shows play/pause, back to tab,
    pop out, close and a scrubber. A click on the video goes to the tab. With
    the setting on, switching away from a playing video enters PiP even when
    Automatic Picture in Picture is off, since that is how the video gets to
    the sidebar. With the sidebar hidden, the video uses the panel.
  - **Arc mode** (Video in Sidebar off): the video plays in a floating panel
    (`LiveVideoPanelController`, a non-activating panel above other windows)
    and its strip is hidden. The panel's minimize collapses it into the strip,
    whose "Open Picture in Picture" pops it back out. A video popped out from
    the sidebar gets a "Back to Sidebar" button instead of minimize.
  - Close (×) ends PiP and pauses; the paused strip stays. Ending the media
    or closing the tab removes the video. Back to tab ends the session through
    the engine (PiP phase 2) and selects the tab.

### ABI 1.44 adoption and the bench (perf-0)

`perf_metrics` (ABI 1.44) is measurement only, and only `--rearc-bench`
installs its callbacks (`Chromium/ChromiumPerfMetrics.swift`): page timing
(FCP, LCP, load) per navigation, presentation feedback for shown and resized
views, histogram snapshots and the process list with footprints.

- **Signposts** are always compiled in (`Perf/PerfSignposts.swift`,
  `SidebarModel/ModelSignposts.swift`, subsystem `net.rearc.shell`):
  `interaction` intervals at the model entry points, `launch` events,
  `engine-calls` around the ABI calls on the interaction paths, `model` and
  `persistence` intervals. The engine adds `net.rearc.engine`. Record them
  with Instruments or `log stream --signpost`.
- **`--rearc-bench`** (`Chromium/ChromiumBench.swift`) drives the real
  `ChromiumShell` over a seeded `BenchFixture` sidebar and the loopback page
  set (`BenchPages`). It reuses the self-test's fixture server
  (`LoopbackFixtureServer`) and input driver (`ShellInput`), never its
  anti-throttling switches. Each measurement ends on an event: a presented
  frame (`Perf/PresentationProbe.swift`, markers in `Perf/ProbeMarkers.swift`),
  an engine event, or an animation's completion. Each sample records whether
  its input was posted to AppKit or went to the shortcut handler's entry
  point.
- **Scripts:** `scripts/bench.sh` (load guards, the input lock, display kept
  awake, cold launches, `--chrome` reference), `scripts/bench_finalize.py`
  (bench.json, statistics, net-log audit), `scripts/bench-gate.py`
  (regression gate), `scripts/bench_chrome.py`. Budgets are in
  `bench/budgets.json`, baselines in `bench/baselines/`, and results go to
  `bench/results/` (git-ignored).
- Results and how to read them: docs/PERF-BASELINE.md.
- **Arc vs ReArc from outside:** `scripts/arc-vs-rearc.sh` (the
  `arc-vs-rearc` product, `Sources/ArcBench` and `Sources/ArcBenchCore`)
  posts the same keys to Arc and to a throwaway ReArc and times each app's
  window pixels, captured one window at a time. Method, privacy rules and
  usage: docs/ARC-VS-REARC-BENCH.md.


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
6. Goes back and forward, and checks mute and PiP (a page without video:
   `invalid_state` from ABI 1.30, `unsupported` before it).
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
    relative directory is refused. With `file_chooser`, prompt mode 1 is
    accepted, and Ask where to save sends the save-path request through
    the tab's prompt center. The chosen path gets the file, and a cancelled
    panel cancels the download. Older engines log ABI-GAP lines instead.
    In the real shell, ⌘F on tab A shows "1 of 1", and the command bar
    offers the `/nav` visit as history.
17. Prompt channels (ABI 1.18–1.22), each gated on its minor and flag,
    through the tab's `PagePromptCenter` (the calls its buttons make; the
    file panels and the menu are replaced by recorders, since an NSMenu's
    tracking loop would block the run):
    - `<input type=file multiple accept=.txt,text/plain>` opens an
      open-multiple chooser with that filter, and the two files reach the
      page. `webkitdirectory` uploads a folder's two files, skipping a
      symlink. Navigation closes a held panel.
    - The link menu (dismissed) and the page menu, whose Reload runs in
      the engine. Inspect is `unsupported` and is then dismissed.
    - Typed sign-in gives a save offer for the username, answered Not Now.
    - "Leave site?": Stay keeps the page on navigation and vetoes a normal
      close; Leave continues.
    - alert, confirm (false), prompt (default text, typed reply), the
      dialog limit on the second dialog, and a suppressed confirm answered
      without UI. Navigation withdraws a pending alert, and its late reply
      is `not_found`.
    - Notifications allowed this time (asked again), then blocked and
      remembered (no further prompt). Geolocation dismissed
      (`PERMISSION_DENIED`), and navigation withdraws a pending request.

    The input-driven steps (file input, menu, typing, beforeunload's
    activation) use synthesized events. Each focuses the page and retries.
    When input still cannot reach the page (app inactive), a step logs a
    NOTE instead of failing.
18. Wave 23, each gated on its minor and flag:
    - Dangerous downloads (1.24): with Chromium's manual hash blocklist
      naming 64 KiB of inert "a" bytes (self-test switch only), two `.sh`
      downloads started with a link transition arrive as dangerous. The
      tray's Keep validates one to completion, and Discard removes the
      other and its file. Nothing opens either file.
    - Command bar (1.23, 1.26) in the real shell: first a loopback default
      search (`ReArcSearchSetDefaultProvider`), so no typed text reaches
      a real search engine. Then HistoryService lists `/nav`, the
      command bar shows it as an engine history row, and Shift+Delete
      removes it from HistoryService and `History.json`. Typed words
      classify as a search on the loopback provider with suggestion rows
      from its suggest endpoint, a `host:port/path` classifies as a URL,
      and a superseded autocomplete query ends `cancelled`.
    - Discard (1.25): the shown tab is refused. Unload Tab on the hidden
      tab B discards it (kind 5, engine and content generation kept, row
      dimmed). Selecting B restores it as a new document.
    - HTML fullscreen (1.27): a click on the fixture's button requests
      fullscreen, and the window goes native fullscreen without its
      sidebar. The page's `exitFullscreen()`, Escape and leaving native
      fullscreen each restore the window. Without input (app inactive)
      it logs a NOTE.
19. Wave 24, each gated on its minor and flag:
    - Printing (1.28): `ReArcTabPrintToPDF` gives a 3-page `%PDF` for the
      fixture, page range 2 on A4 landscape gives one landscape page, and
      range 9 is `invalid_argument`. The page's `window.print()` sends a
      print request, its title shows beforeprint+afterprint, and
      `PagePrinter` builds the print operation from the PDF for the tab's
      window. A recorder stands in for the panel, so no real print panel
      opens. A second print while it is open is dropped, then ⌘P prints
      again. Export as PDF writes a valid PDF to a temporary file in
      place of the save panel.
    - Drops (1.29): a synthetic `NSDraggingInfo` over private pasteboards
      drives Chromium's real `WebContentsViewCocoa`. Dropped text and a
      Finder file (name, size and contents) reach the fixture's drop
      handler. A sidebar drag (private type plus UUID text) gets no
      operation and no page event, and the tab stays on its page.
    - PiP (1.30), in the real shell: the fixture plays a MediaRecorder
      WebM of a canvas and a silent oscillator (a normal player with
      audio; a self-test-only `--autoplay-policy` switch lets it play).
      The command enters and leaves PiP (sidebar badge, the page's PiP
      events, Chromium's overlay window). Switching to tab B puts it in
      PiP automatically and switching back ends it. The overlay's back to
      tab (synthesized click) selects the tab again. Without the click a
      NOTE is logged.

    Before the input-driven steps (prompt channels, fullscreen) the
    self-test brings ReArc to the front: `NSApp.activate`, then one
    retry. If it still cannot (a terminal launch under cooperative
    activation, a locked screen), it logs a NOTE with the reason, and
    the steps keep their NOTE fallbacks.
20. Wave 26, on the shell's own model and tab A: Collapse and Expand
    Pinned Section; Copy URL as Markdown and Copy as Quote (the page's
    selection, read in the editor world); the loading ring on a held-back
    load, then Stop; a synthesized `is_crashed` event shows the sad tab
    and the next commit after Reload clears it; a background title change
    on a pinned tab sets the unread dot and selecting it clears it; ⌘↩ in
    the command bar opens a new tab and Ctrl+Tab (MRU switcher) goes back;
    Split View flip and Expand Current Split; the Little Arc address field
    and Back on the key Little Arc; ⌥⌘-click on a `target=_blank` link
    adopted as a Little Arc; an Air Traffic Control rule sending a GetURL
    link to a Little Arc; and the Site Control Center's zoom.
21. Wave 27, each gated on its minor and flag. Before any sign-in the
    leak check is read (on, not managed), turned off and kept off for every
    self-test profile, so no sign-in reaches Google's leak service. In the
    real shell, with two local unpacked MV3 fixtures written per run
    (`--load-extension`, never the Web Store): the popup action's title,
    badge "7" in red and icon; pinning; the popup attached in its panel,
    resized to its 320×180 content, `getViews({type:'popup'})` = 1, no
    sidebar tab, then closed by its own `window.close()` (one retry if the
    popup loads without running its script, seen once); a shell dismiss; the
    click fixture's `tabs.create` answered with a today tab in the current
    space, where the extension saw tab A active in the space's window; its
    `management.uninstallSelf` confirmation as a host prompt, cancelled.
    On an ordinary link (ABI 1.39): ⌘-click opens a background tab on the
    link, ⇧⌘-click a selected one, ⌥⌘-click a Little Arc, and the page
    stays where it was. A
    datalist field shows the suggestion panel under it without taking the
    keyboard; Down moves the selection, a click fills the value, Manage…
    opens chrome://settings/autofill. A typed address form gives a save
    offer, declined. HTTP Basic against the loopback fixture: Cancel shows
    the 401 page, Sign In loads it. Input-driven steps log NOTEs when the
    app cannot become active. Self-test runs also get engine/tests'
    no-outside-network switches (no background networking or component
    updates, every non-loopback name unresolvable), secure DNS off in the
    fresh profile, and the autofill focus test switch.
22. Wave 28, in the real shell on tab A: View > View Media opens the
    Library over the key window's page and selecting the tab closes it; a
    gradient theme with Dark appearance turns the window `darkAqua`, its
    style is in its own sync record, and back to Automatic the window
    follows the Mac; a visual boost (dark mode, a zap of `<p>`, 125% text)
    compiled into its stylesheet applies on Chromium and goes with the
    boost; Capture starts over tab A, and a region and the clicked `<h1>`
    (measured in the editor world) crop the viewport snapshot, and portrait
    frames it (nothing is saved to the captures folder). In the trusted
    navigation step, `chrome://settings/importData` commits and keeps its
    route (WebUI refuses script and snapshots, so the dialog itself is not
    observable). No import runs, since that would read this Mac's real browser
    data. With `devtools`: View > Developer > Developer Tools is ⌥⌘I; ⌥⌘I
    attaches the bundled frontend docked beside tab A in its window (same
    engine profile, no sidebar tab), it moves to its own window and back,
    and ⌥⌘I closes it while the page stays; the page menu's Inspect path
    opens one for a second tab, and closing that page closes its frontend in
    the engine and the shell. With `client_certificates`, in the mock
    keychain run only: the bundle script points
    `REARC_SELFTEST_CLIENT_CERT_DIR` at the engine's `net/data` certificates,
    the self-test starts a loopback mutual-TLS server (Python, a per-run
    server key accepted by its SPKI exception) and launches Chromium with
    `--rearc-test-client-cert-dir`, so the debug engine's test-only store
    offers net/data's client_1 and client_2 and the real Keychain is never
    listed. The sheet lists Client Cert A and D for the server's origin;
    Cancel loads nothing and does not ask again; after a reload, D reaches
    the server, and the next page on that host and port reuses it without
    asking.
23. Verifies every evaluation, profile request and command-bar call
    context was released (`live script contexts: 0, profile contexts: 0`),
    then shuts down cleanly.

Wave 29 (2026-11-04): both development logs
(`selftest-chromium-mockkeychain.log`, `selftest-chromium.log`) reach
`RESULT PASS` against ABI 1.41, in 175.10 s and 171.43 s respectively. The
real-Keychain run completed without a prompt or stall. The wave 28 profile
timeouts did not recur on the idle machine. Library, gradient appearance,
Boosts v2, capture, DevTools open/pop-out/dock/close and Inspect all pass;
the mock run also verifies client certificates against the loopback mTLS
fixture. DevTools close now explicitly closes the registry tab even while
its engine is retained. Autocomplete publishes suggestions only after the
current query completes, since partial updates can contain the preceding
query's cached rows. After closing the certificate tab, the test selects
tab A before the private-window and final reopen checks.

The screen was locked for the passing dev runs. NOTE-only input checks:
the trusted editor pick (editor-world fallback passed), file input,
password save offer, beforeunload activation, HTML fullscreen, ⌥⌘-click,
autofill dropdown/Manage and address save offer, modified link clicks, and
key-private-window zoom routing. Client certificates are intentionally
skipped with the real Keychain; only the mock/debug fixture enumerates test
identities. A passing result does not verify those skipped input paths.

The signed release from `bc480620` also reaches `RESULT PASS` in 59.98 s
with the real Keychain and no prompt or stall (`selftest-release.log`,
mirrored from `dist/release/selftest-release.log`). Its input steps pass,
except that the ordinary-link ⇧⌘-click and ⌥⌘-click variants remain NOTE-only;
⌘-click passes. Client identities are intentionally skipped. Both
LaunchServices launch probes pass. `scripts/release.sh --dmg` rebuilt the
signed `dist/release/ReArc-0.1.0.dmg`; its embedded app signature and source
revision, Applications link, background, Finder layout and volume icon
were checked from a read-only mount. Unit tests remain green: 638 cases.

Wave 28's earlier runs timed out at the profile step under the concurrent
release engine build's heavy load. For that reason, the first `data:` commit
allows 45 s (a cold
renderer) and hidden-tab cookie reads 30 s. The real-Keychain run is covered
below. In both wave 24 runs the app was active for the input-driven steps.
For the first time, HTML fullscreen was exercised end to end: enter,
the page's exit, Escape, and leaving native fullscreen as the green
button and ⌃⌘F do (`toggleFullScreen`). So were the file input, password
offer, beforeunload and PiP back to tab.

The password step types a field only after the page reports it
focused, and submits only when both fields hold what was typed
(retyping up to four times). Input reaches the renderer asynchronously,
and a fresh page can drop its first synthesized click. In wave 25 that
once left the username empty in the save offer. With the app inactive
it makes one try and logs a NOTE.

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

- **Picture in Picture** is video only (no Document PiP). Host-started PiP
  needs a normal player with unmuted audio (no WebRTC or canvas streams), so
  the live video in the sidebar is limited to those players; other media get
  the strip only. The strip's volume control is mute only (no per-tab volume
  slider), and there are no camera or microphone controls for capture tabs.
- **Unhandled drops navigate.** A file or link dropped outside a page's drop
  target opens in that tab, as in Chrome; the engine gives the host no veto.
- **No print preview.** Printing shows the native print panel over the
  engine's PDF. Chromium's preview, its page-range field and its
  header/footer options are not shown. NSPrintOperation's panel has its
  own range and scale.
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
- **DevTools.** No nested DevTools, remote targets, workspaces, saving to
  disk or DevTools extensions (WAVE-18H-REPORT); the frontend cannot open
  new tabs or windows. Client certificates: no "continue without a
  certificate" and no certificate viewer.
- **Discard refusals.** Chromium will not discard a page that is shown,
  loading, playing, captured, in PiP or fullscreen, or has unload
  handlers. The automatic unload leaves those loaded.
- **Remote suggestions** go to the profile's default search engine as
  Chromium sends them. History deletion is local (no synced delete).
- **Password leak check.** When a sign-in is submitted, Chromium's password
  manager runs its leak check against Google's endpoint (the self-test logs
  its 400 for the fixture's credentials). Turning it off is engine or prefs
  work.
- **Prompts Chromium does not route here.** File System Access pickers,
  screen and tab sharing, device choosers and extension prompts are not part
  of these channels.
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
  - `Sidebar/ProfileAvatarView` — every profile avatar and the profile
    menus' rows; pictures chosen in the profile editor are normalised and
    kept in `ProfileAvatars/` next to `sidebar.json`
    (`ProfileAvatarImageStore`, FEATURE-SPECS/PROFILES.md §9).
  - `CommandBar/` — centered floating URL/search panel (tabs, visit
    history, commands, search).
  - `FindBar/` — the find-in-page bar and its model.
  - `Downloads/` — `DownloadsController`, the sidebar tray, and the
    `WKDownload` backend (`ChromiumDownloads.swift` is the Chromium one).
  - `Prompts/` — `PagePromptCenter` (one per page), the dialog sheet and
    the permission and password cards, the file panel and NSMenu presenters,
    `SitePermissionsController`, and the view model's link routing and
    close-through-page (`ChromiumPrompts.swift` and `WKEngine+PagePrompts`
    are the engines' sides).
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
  it along with them, and with its containers, which the dialog names.
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
threshold are local and not journaled for sync. Since wave 21 an existing
space can change profile.

## Wave 21: spaces, splits, command bar, boosts, links

- **Swipe between spaces.** A two-finger horizontal swipe on the sidebar
  pages through the spaces of the window's profile (Arc
  `SidebarPagingContainer`). The first few points decide the axis, so
  vertical scrolling still scrolls. The page follows the fingers,
  rubber-bands past the first and last space, and on release settles on a
  spring that keeps the release velocity (`SpacePaging`, closed form, so a
  new swipe grabs the page mid-spring with no jump). One swipe moves at
  most one space. Clicks, ⌃1…9 and ⌥⌘←/→ spring the page too. With Reduce
  Motion a swipe switches on release with a crossfade and nothing slides.
  Swipes are read in the key window only.
- **Themed window.** The window background is the focused space's theme
  blended into a gradient (`SpaceThemePalette`: lighter toward the top in
  light mode, deep in dark mode). The sidebar sits on it with light or dark
  text by the background's brightness, and the page is an inset rounded
  card. During a swipe the colour moves with the page; other switches
  crossfade in 0.3 s. Gradient stops, grain and per-space appearance are
  still not modelled.
- **Change a space's profile**: Change Profile in the space menu, the
  Profile row of Edit Space, or the Move Space to <profile> command. It asks
  first. The space keeps its tabs, folders and splits, moves to the end of
  the new profile's spaces and stays on screen (the active profile follows
  it). Engines on the old profile close and the tabs reload on the new
  profile's storage, so sign-ins, cookies and back/forward history stay
  behind. A profile keeps at least one space.
- **Drag to split.** Drag a sidebar tab over the page: the half it would
  take (nearest edge: left, right, top or bottom) is highlighted, and a drop
  makes the split with the page's tab, or adds a pane to the split on
  screen (up to four) and turns it to the drop's axis. The drop target is an
  AppKit view above the engine view that exists only during a sidebar drag
  of a tab that can split there, so drops from other apps still reach the
  page. Dropping on a sidebar tab row still makes a folder.
- **Tab to search.** Type the start of a site's name, alias or domain
  ("you", "yt", "github.com"): the field shows "Search YouTube  Tab". Tab
  turns it into a pill in the site's colour and Enter searches that site
  (an empty query opens it). Delete on an empty query removes the pill and
  restores the text. Thirteen seeded sites (`SiteSearchCatalog`).
- **Boosts library.** View Boosts (command bar, Tabs menu, the sidebar's +
  menu) lists the active profile's boosts with a master switch, a switch per
  boost, script consent for script boosts, and New (a typed site or the
  page on screen), Edit on This Page, Open Site, Rename, Duplicate and
  Delete. Changes reinstall the boosts of open tabs.
- **Default browser and external links.** ReArc > Set ReArc as Default
  Browser… (or the command) asks macOS through
  `NSWorkspace.setDefaultApplication` for http and https; macOS confirms
  with the user. It only works from an app bundle and says so otherwise.
  Links from other apps arrive as `GetURL` Apple Events on both engines
  (`ExternalLinkRouter`; the link that launches the app waits for the
  model). They open in Little Arc (the default) or a new tab in the space in
  front, chosen under ReArc > External Links (remembered). A page already
  open is focused instead. `bundle-chromium.sh` declares the http/https URL
  types, and `scripts/bundle-webkit-dev.sh` builds `dist/webkit/ReArc Dev.app`,
  a WebKit-only bundle (id `com.rearc.browser.webkit-dev`) that can receive
  links: `open -a "dist/webkit/ReArc Dev.app" https://example.com` sends one
  without changing the default browser. Tests use a fake service and never
  touch LaunchServices.

## Wave 26: sidebar polish, split, command bar, Little Arc, links, sites

- **Pinned section.** Hover the space name for a chevron, or use Expand /
  Collapse Pinned Section (Tabs menu, space header menu, command bar). The
  flag is per window and per space and is not saved. A collapsed section
  keeps the selected pinned tab visible, as a collapsed folder does.
- **+ menu.** New Tab, New Folder, New Space…, New Note, New Easel, New
  Boost (the page on screen in the editor with the picker, else the Boosts
  library) and Split View right or bottom, with Arc's icons.
- **Copy URL.** ⇧⌘C plain, ⌥⇧⌘C as Markdown (`[title](url)`, brackets
  and parentheses escaped), Copy as Quote (the page's selection as a
  Markdown quote with the source link, or the link alone). Each shows a
  "Copied" toast at the bottom of the page.
- **Unread dot.** A pinned tab or favorite that is not on screen and
  changes its title more than 3 s after its last load (Gmail "(3) Inbox")
  gets the dot (`UnreadActivityPolicy`). The row title follows the page.
  Selecting the tab clears it.
- **Loading and crashed tabs.** The row's icon shows a progress ring while
  the page loads, and the page a glowing bar on its top edge (Chromium
  `load_progress`, WebKit `estimatedProgress`). A crashed renderer
  (Chromium `is_crashed` from PrimaryMainFrameRenderProcessGone, WebKit
  `webViewWebContentProcessDidTerminate`) keeps the tab. The row shows a
  warning icon and the page "This page crashed" with Reload. Chromium
  reports the crash but not the recovery, so the next main-frame commit
  clears it. The self-test cannot crash a renderer (`chrome://crash` is
  not admitted), so it feeds the engine's event shape.
- **Split View.** Flip Split Orientation and Expand Current Split (Tabs
  menu, the split's context menu, command bar). An expanded pane fills the
  content area and its siblings stay open. A pill shows the split again,
  and so does focusing another pane. It is window state and not saved.
- **Command bar.** A typed domain completes inline in grey, from the hosts
  you visit most, then a bundled list of about 200 popular sites
  (`TopDomains`, ReArc's own list; Arc's ships 458). → takes it, Return
  opens it, and deleting turns it off until the next character.
  ⌘↩ opens the result in a new tab, ⌥↩ in a split next to the page (with
  ⌘T, next to the tab shown before), ⇧↩ in Little Arc (⌘T's empty tab is
  removed). The spec evidences ⌘-key force routing but not the keys
  (COMMAND-BAR §9.3), so these are ReArc's choice, shown in the bar's
  footer.
- **Ctrl+Tab.** A recent-tab switcher (Arc `ModalItemSwitcher`): tabs of
  the active profile across its spaces and favorites, most recently shown
  first (`lastActiveAt`), a split once. ⌃⇥ steps forward, ⌃⇧⇥ back, and
  releasing ⌃ switches. Esc cancels. The menu item (no ⌃ held) switches to
  the previous tab at once. An app-wide key monitor handles it before the
  page does, in browser windows only.
- **Little Arc.** The window has back, forward, reload or stop, an address
  placeholder (the host) that becomes its mini command bar (URL or search,
  inline completion, loads in that window), the profile indicator with a
  menu to change profile (the page reloads on the other profile's
  storage), Open in ReArc and Close. ⌘L and Back/Forward act on a key
  Little Arc. File > New Little Arc Window is ⌥⌘N. ReArc > Open Little Arc
  from Anywhere registers ⌥⌘N system-wide through Carbon
  `RegisterEventHotKey` (no Accessibility permission). It is off by default
  because the spec does not give Arc's combination. ⌥⌘-click on a link
  opens it in Little Arc: WebKit sees the modifiers on the navigation
  action. On Chromium the shell notes the keys at mouse-down and adopts
  the engine's new contents as a Little Arc. Since ABI 1.39 (wave 27)
  ordinary links reach the shell too, so ⌘-, ⇧⌘-, ⌥⌘- and middle-clicks
  work on Chromium (see "Modified link clicks" under the wave 27
  adoption).
- **Air Traffic Control.** ReArc > Air Traffic Control… (or the command)
  edits ordered rules: Domain is (subdomains too), URL contains, or URL
  matches a `*` pattern over the URL without its scheme. Each rule sends
  links from other apps to a space (a new tab there, or the tab already
  showing it) or to a Little Arc in a profile. The first enabled rule
  whose space or profile still exists wins. Everything else follows
  External Links. A tester shows where a typed link would go. Rules are
  saved in user defaults (`ReArcLinkRoutingRules`).
- **Site Control Center.** The URL field's site icon (and the permission
  indicator) opens one panel per site: connection, the wave 22
  permissions (reset on WebKit, Site Settings on Chromium), the site's
  boosts with switches plus New Boost and Edit, zoom −/+/Reset for that
  page, and cookies and site data. WebKit counts the site's record types
  in its data store and Clear Site Data removes them and reloads. Chromium
  opens `chrome://settings/content/siteDetails`, which lists and clears
  them. Also the Site Controls command.

## Wave 28: Library, gradient themes, Boosts v2, capture, notes, import

Both engines unless noted.

- **Library.** The sidebar's Home button (bottom bar, `archivebox`), View >
  View Library and the View Spaces / Downloads / Media / Easels & Notes /
  Archive / Boosts items (and the View Library, View Media, View Easels &
  Notes commands) open Arc's Library over the window's page: a page list on
  the left, the page on the right. Spaces groups the spaces by profile as
  theme cards (click to switch, the space menu, New Space…). Downloads is
  the tray's list, plus Chromium's page on Chromium. Media lists every
  capture newest first with the easels it is on (filter, search, Copy, Add
  to Easel, Open Page, Delete). Easels & Notes lists both kinds with a
  filter, search, New Note, New Easel, Rename and Delete. Archive and Boosts
  are the former sheets. The Library is per window (`LibraryPresentation`).
  Esc, the close button or showing any sidebar item in that window closes
  it, and the Home button reopens the last page.
- **Gradient themes.** Edit Space and New Space share Arc's style editor
  (`SpaceStyleEditor`): up to three colour stops (one colour is a plain
  theme, more are a gradient running corner to corner), the swatch pads
  and six gradient presets, a grain slider, and Automatic / Light / Dark.
  The grain is a procedural tile blended over the background (Arc's
  textures are Metal bitmaps, not copied). Appearance sets the window's
  `NSAppearance`, so pages (WebKit follows the view; Chromium pages follow
  macOS), easels and notes follow it. Spaces > Appearance: … and the
  Appearance commands set it for the active space. A plain theme encodes as
  before. The gradient, grain and appearance sync in their own
  `SidebarSpaceStyleRecord` (`docs/SYNC-RECORDS.md`), because Macs on a
  wave 25–27 build rewrite every field of a space record they know.
- **Boosts v2.** The boost drawer has Colour (Arc's eight colours, a hue
  slider, intensity, Single / Analogous / Complementary), Dark Mode, Font
  (four presets or an installed family) and Text Size, and Zaps (Zap an
  Element picks and hides it at once, Zap / Zap Similar for the selected
  element; each zap is listed and removable). Custom CSS holds the
  hand-written rest. The settings compile into a marked block at the top
  of the boost's stylesheet, headed by a one-line settings comment
  (`BoostVisualStyle`), so they sync and export as CSS and every older
  ReArc keeps them. New Legacy Boost (Advanced) (Tabs menu, command, the
  Boosts page) makes a CSS and JavaScript boost for the page's site and
  opens its code editor. Its script runs only after "Allow this boost's
  script to run". Boosts export as `.rearcboost` files (JSON, the
  interchange format) and import from them (Import Boosts…). An imported
  script boost arrives off, with its script not allowed, whatever the file
  says. Arc shares boosts as links to its server; ReArc has no server.
- **Capture.** File > Capture (⇧⌘2) or the Capture command dims the page:
  drag a region, or click an element (widened to the nearest picture,
  block or 48×24-point ancestor), Esc cancels. Both crop the engine's
  viewport snapshot (`snapshot_viewport` on Chromium); the element is
  measured in an isolated world (Chromium's editor world, WebKit's
  `.defaultClient`). Capture in Portrait Mode frames the visible page on
  the space's theme with rounded corners, a shadow and a "ReArc"
  watermark (Portrait Capture Watermark On/Off). Every capture goes to the
  Library's Media page and shows its card: Copy, Add to Easel (any easel or
  a new one), Delete. The capture's kind is a new optional `detail` field,
  so older builds still read the index.
- **Notes.** A note opens as a document, not a canvas (`NoteEditorView`):
  a title, then text with Body / Heading 1–3, bold (⌘B), italic (⌘I),
  underline (⌘U), strikethrough (⇧⌘X), code, links (⌘K; http, https and
  mailto, opened in a new tab), bulleted (⇧⌘8), numbered (⇧⌘7) and
  checklist (⇧⌘L) items and quotes. Return continues a list and ends it on
  an empty item, Delete at the start of a line clears its style, "# ",
  "## ", "- ", "1. ", "[] " and "> " format the line, and a click on a box
  checks it. Paste keeps the note's styles. Copy as Markdown is in the ⋯
  menu. The note is `EaselDocument.note`, and its plain text is also kept
  in the old text block so a build before wave 28 still shows it. Notes,
  like easels, are per Mac: the sync design keeps easels local.
- **Import.** File > Import Bookmarks from HTML File… reads the file any
  browser exports (Safari, Chrome, Firefox, Edge, Arc) into a new space:
  folders become pinned folders (closed), links pinned tabs, in file
  order; only http and https links, at most 2000, folders at most 6 deep.
  On Chromium, File > Import from Safari or Firefox… (and the command) opens
  Chromium's own importer, `chrome://settings/importData`, in the settings
  tab. It imports into the engine profile: passwords and history appear in
  Chromium's pages and the command bar's history, and imported bookmarks
  go into Chromium's bookmark model, which ReArc does not show, so use the
  HTML file for bookmarks.
- **Import from Arc, Chrome or Brave** (File menu and command, both
  engines; docs/PROFILE-IMPORT.md). Chromium's importer has no source for
  another Chromium profile on macOS, so ReArc reads the files itself, read
  only. Arc's `StorableSidebar.json` becomes new spaces with their pinned
  tabs, folders, splits, renames, icons and themes, each Arc profile's
  favorites, and Arc profiles as existing or new ReArc profiles. A preview
  counts spaces, pinned tabs and favorites, with a checkbox per space. A
  Chrome, Brave or Arc profile's bookmarks become a space, its history
  (read from a temp copy) feeds the command bar, its search engine is
  matched by name, and its extensions reinstall one at a time from the
  Web Store (Chromium). Five Arc settings map onto ReArc's. Passwords,
  cookies and autofill are designed but not built: they need a Keychain
  prompt and engine import ABIs.

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
- Display order = favorites → pinned → today; Cmd+Shift+]/[ cycle through
  that order with wraparound. Ctrl+Tab goes by recency instead (wave 26).
- Submitting the command bar on a **favorite** spawns a today tab instead of
  mutating the favorite (favorites are launchpads).

## Shortcuts

Arc's own keys (wave 30). `docs/SHORTCUTS.md` has all 101 of Arc 1.171.0's
bindings with ReArc's status; `ArcShortcuts` (SidebarModel) holds the table.

While a page has keyboard focus, each key follows Arc's priority for it
(`ShortcutRouter`, run from the app-wide key monitor):

- **Arc wins** (⌘L, ⌘T, ⌘W, ⇧⌘C, ⌘[ / ⌘], ⌃⇥, ⌘1…9, ⌃1…9…): the menu runs
  it, and the page never sees the key.
- **Website first** (⌘S, ⌘D, ⌘P, ⌥⌘I…): the page sees it first. If the page
  takes it, a "Press ⌘S again to Show/Hide Sidebar" toast shows, and the
  second press within 2.5 s is ReArc's.
- **Website wins** (⌘R, ⌘F, the editing keys…): the page sees it first, and
  the menu runs it only if the page does not take it.

On Chromium the page's verdict comes from the engine (ABI 1.42
`key_equivalent_events`, `ReArcEngineSetKeyEquivalentCallback`). Before it,
`RenderWidgetHostViewCocoa` took every Command key from the menu and the
bridge dropped the ones the page did not handle. The Chromium menu bar
stores shifted shortcuts as their shifted character ("C" + ⌘ for ⇧⌘C),
which is the only form AppKit matches.

| Keys | Action |
|---|---|
| ⌘T | Command bar for a new tab; Esc leaves no tab |
| ⌘L | Command bar on the page's URL, selected; again closes it; the page gets focus back |
| ⌘W / ⇧⌘W | Close the selected tab (or a private / Little Arc window) / the window |
| ⇧⌘T | Reopen closed tab |
| ⌘N / ⌃⌘N / ⇧⌘N / ⌥⌘N | New window / blank window / private window / Little Arc window |
| ⌘S | Hide or show the sidebar (spring; when hidden, point at the left edge to float it); the page keeps focus |
| ⌥⌘↓ / ⌥⌘↑ | Next / previous tab in sidebar order |
| ⌃⌘← / ⌃⌘→ | Cycle back / forward through the tabs visited |
| ⌃⇥ / ⌃⇧⇥ | Recent-tab switcher forward / backward; release ⌃ to switch, Esc cancels |
| ⌘1 … ⌘8 / ⌘9 | Select that sidebar row / the last one |
| ⌃1 … ⌃9 | Switch to space 1–9 of the active profile |
| ⌥⌘→ / ⌥⌘← | Next / previous space |
| ⌘[ / ⌘] (⌘← / ⌘→) | Back / forward |
| ⌘R / ⇧⌘R / ⌘. | Reload / reload ignoring cache / stop |
| ⌘= (⌘+) / ⌘- / ⌘0 | Zoom in / out / actual size |
| ⇧⌘C / ⌥⇧⌘C / ⌃⇧⌘C | Copy the page URL, without trackers / as Markdown / as Quote ("Copied Current URL", or "Copied a clean link without trackers") |
| ⌘D | Pin or unpin the selected tab ("Pinned Tab to “Space”") |
| ⇧⌘K | Clear unpinned tabs |
| ⌃⇧= / ⌃⇧- | Add split view / close the focused split pane |
| ⌃⇧N / ⌃⇧E | New note / new easel |
| ⌘O | Move the key Little Arc into the active space |
| ⇧⌘L / ⇧⌘J | Library / downloads tray |
| ⌘F / ⌘G / ⇧⌘G / ⌘J | Find / next / previous / jump to selection |
| ⇧⌘V | Paste and match style |
| ⌘Y / ⌥⌘L | History / Downloads (Chromium with `webui_daily_pages`) |
| ⌥⌘I (F12) / ⌥⌘C / ⌥⌘J | Developer Tools, docked beside the tab (Chromium with `devtools`) |
| ⌥⌘U | View page source (Chromium) |
| ⌃⌘F | Enter / exit full screen |
| ⌘P | Print the page (native print panel as a sheet; File > Export as PDF… saves it) |
| ⇧⌘2 | Capture: drag a region or click an element (Esc cancels) |
| ⌥⌘-click a link | Open it in Little Arc |
| ⌘-click or middle-click a link / ⇧⌘-click | Open it in a background tab / a new selected tab (Chromium needs ABI 1.39) |
| ⇧-click a link | Peek in sidebar tabs; elsewhere on Chromium (ABI 1.39) Little Arc |
| → in the command bar | Take the grey domain completion |
| ⌘↩ / ⌥↩ / ⇧↩ in the command bar | Open the result in a new tab / a split / Little Arc |
| ⌘B / ⌘I / ⌘U / ⇧⌘X / ⌘K in a note | Bold / italic / underline / strikethrough / link |
| ⇧⌘8 / ⇧⌘7 / ⇧⌘L in a note | Bulleted list / numbered list / checklist |
| Two-finger swipe on the sidebar | Previous / next space |
| Tab / ⌫ in the command bar | Search the typed site / remove the site pill |
| ⇧⌫ in the command bar | Remove the highlighted history row |

## Sync: iCloud (wave 25; verified on one Mac against real iCloud in wave 28)

The sidebar syncs through CloudKit, but only in a build signed with an
iCloud container. Every other build (`swift run`, `swift test`, ad-hoc
bundles, and bundles made without `REARC_ICLOUD_CONTAINER`) gets the inert
`UnavailableSyncEngine`, never creates a `CKContainer`, and Settings says
"iCloud sync unavailable in this build". The account steps are in
`docs/ICLOUD-SETUP.md`; records, merge rules and how this differs from
SYNC-DESIGN are in `docs/SYNC-RECORDS.md`.

- **What syncs:** spaces with their themes and icons, profiles, Favorites,
  pinned tabs, folders, splits in Pinned, and Boosts with their per-space
  policy. Today tabs, easels, selection, the archive and Little Arc windows
  stay on each Mac.
- **How:** `SidebarSyncCoordinator` diffs the sidebar against the last merged
  records and stamps changed fields with a hybrid logical clock. It then
  fetches and merges (field-level last-writer-wins plus tombstones), rebuilds
  the sidebar, and uploads with optimistic concurrency, merging and retrying
  on conflicts. Lists are ordered by per-row LexoRank fields, repaired so
  that concurrent reorders converge. Orphans and folder cycles are rescued
  the same way on every Mac.
- **Transport:** `SidebarSyncTransport`. `CloudKitSyncTransport` uses
  CKSyncEngine (macOS 14) on the private database, zone
  `com.rearc.sidebar.graph.v1`, with payloads in `encryptedValues`.
  `InMemorySyncServer` is the test double: change tokens, stale tags, zone
  resets, account switches, and network, quota and rate-limit faults.
- **Offline:** unconfirmed writes stay `pending` in `sync-state.json` next to
  `sidebar.json`. They upload after reconnecting or relaunching. Transient
  errors back off: 5 s × 2ⁿ, at most 15 min, never sooner than `retryAfter`.
- **Settings:** the WebKit build has the standard Settings window (⌘,). On
  Chromium, ⌘, opens Chromium's settings, so use **ReArc > iCloud Sync…**.
  Both show the toggle (off by default; only the person turns it on), status, account, last synced time,
  queued changes and **Sync Now**. Turning it on looks at iCloud first: a sidebar already
  there gets a sheet (use it, replace it, merge, or cancel); the **Sidebar in iCloud**
  box shows what iCloud holds and can use, replace or delete it (docs/SYNC-RUNTIME.md). The bottom-bar dot turns green only after
  the server confirmed every pending write.
- **Signing opt-in:** `REARC_ICLOUD_CONTAINER` and
  `REARC_PROVISIONING_PROFILE` in `signing.local.env` (see
  `signing.example.env`). `scripts/icloud-signing.sh` checks the profile,
  merges the iCloud entitlements, embeds the profile and signs the bundle.

The mutation journal and `SyncOutboundPipeline` remain. They now only tell
the scheduler that something changed. Not done yet: ReArc's own end-to-end
encryption, recovery phrase and device pairing (SYNC-DESIGN P2), push
notifications, and a run on a second Mac against real iCloud. One Mac has
synced with real iCloud (Development environment, 2026-11-04: 11 records
uploaded, none pending; `docs/ICLOUD-SETUP.md`).
