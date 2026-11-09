# ReArc engine C ABI

ABI **1.55** (major remains 1 for existing hosts), bridge **0.58.0**, compiled Chromium **156.0.8078.74**. Public header:
`chrome/browser/rearc_bridge/rearc_engine_abi.h`; adjacent `module.modulemap`
imports it as `ReArcEngine`. This is an in-process typed adapter for
[IPC-CONTRACT](IPC-CONTRACT.md), not a JSON connection. Synchronous return
values replace command rejection messages; returned IDs/attachments replace
create/attach replies. Events and accepted asynchronous completions preserve
the contract's serialized order. No C++ or ObjC types cross this interface.

Every call, including queries and frees, must run on the process main thread;
entry points CHECK this. Chromium's UI scheduler delivers callbacks on main,
after mutation/delegate stacks unwind. No main-queue polling pump is involved.
From bridge 0.51.0 one task delivers callbacks for at most about 8 ms; a longer
burst (a history slice's created events) continues in a later task, in the
same order (from 0.52.0 a delayed one, 1 ms later, so the host's run loop has
a turn first). The final flush after ChromeMain returns is not budgeted.
Inputs are borrowed for the call and copied if needed afterward. Callback
structs and UTF-8 strings are borrowed until the callback returns: Swift must
copy them immediately. Registered callback contexts remain host-owned and must
survive until unregistered/replaced, or until `ReArcEngineRun` returns for the
Configure callback table. One-shot request contexts survive through their one
accepted completion; synchronous rejection retains nothing. A successful
shutdown completion is the last callback, delivered after ChromeMain has unwound and immediately before
ReArcEngineRun returns.

## Linking and startup

Expose the two public headers and module map in an include directory and add
that directory to Swift's import search path. Link `Chromium Framework` using
its existing framework name, framework search path and runtime search path.
The component dev build reexports `libchrome_dll.dylib` and requires its entire
output dylib dependency closure; copying just the framework is insufficient.
The framework's `nm -gU` output in this configuration is the small reexport
stub, so verify definitions with `nm -gU libchrome_dll.dylib` and resolve every
symbol through the framework with `dlsym`. The non-component export list and
symbol-order list explicitly include the ABI, before `_ChromeMain` in the
order list (complete since tab/060; `shell/scripts/build-engine-release.sh` fails
when a header function is missing from `nm -gU` of the framework). Release
packaging and its validation are in RELEASE.md.

Use the upstream `.app/Contents/Frameworks/Chromium Framework.framework/Versions/
156.0.8078.74` layout, including resources and all helper bundles and their
Info.plists. Preserve helper `LSUIElement`, executable names, entitlements,
sandbox and framework-relative paths. The shell's executable must be in an
app bundle; pass its real argv, selecting `--user-data-dir` before startup.

1. Call `ReArcEngineConfigure(1, &callbacks, context)` before any
   `NSApplication`, SwiftUI `App.main`, or application delegate is created.
2. Call `ReArcEngineRun(argc, argv)` on main. It calls upstream `ChromeMain`
   once and blocks. It adds `--no-startup-window`, `--no-first-run`,
   `--no-default-browser-check` and `--profile-directory=Default` unless a
   directory was supplied. Browser helpers invoke upstream `ChromeMain`
   directly, never configure/run the host ABI. Headless, guest and incognito
   invocation through this wrapper is unsupported.
3. In `ready`, create shell NSWindows/NSHostingViews. Do not start another
   AppKit loop. Use `default_profile_id` for the startup Space, or open a named/OTR profile. Shell UUIDs map to
   these session-local uint64 IDs; neither the shell nor JSON numbers allocate
   engine IDs. Profile APIs below provide real storage isolation.
4. `terminate_requested` is an asynchronous Cocoa quit notification. Call
   `ReArcEngineShutdown` to honor it. Keep contexts and native scaffolding
   alive until terminal completion and run return. Do not unload/restart the
   framework; browser recovery means process relaunch.

## Core functions

All `ReArcStatus` functions return `REARC_OK` on acceptance. Rejected async
operations invoke no completion. Accepted async operations invoke exactly one.
Null required output/callback pointers and invalid arguments are rejected
before ownership changes. The header is authoritative for C signatures.

| Function | Semantics |
|---|---|
| `ReArcEngineABIVersion()` / `ReArcEngineABIMinorVersion()` | Static ABI major 1 / additive minor 13. Configure still takes major 1. |
| `ReArcEngineBridgeVersion()` | Static bridge implementation version string. |
| `ReArcEngineVersion()` | Static compiled Chromium version string. |
| `ReArcEngineHasFeature(feature)` | Exact capability-name lookup; unknown/null is false. |
| `ReArcStatusName(status)` | Static IPC error spelling; unknown maps to `internal`. |
| `ReArcEngineConfigure(version, callbacks, context)` | Copies callback table; one registration, before NSApplication. Requires ready callback. |
| `ReArcEngineRun(argc, argv)` | Blocking single browser invocation; returns upstream exit code. Preflight failures return negative ReArcStatus. |
| `ReArcEngineDefaultProfile()` | Current startup profile ID, or 0 before ready/after stopping. |
| `ReArcEngineShutdown(force, completion, context)` | Stops new work, closes live tabs sequentially through close_controller, releases profiles only after actual contents destruction, then shell keepalive and upstream quit. A veto completes with cancelled=true and resumes service; earlier closed tabs stay closed. Existing standalone tab closes are joined (and promoted by force); concurrent shutdown or an accepted ProfileClose still fails busy. |
| `ReArcEngineSetLifecycleCallbacks(request, cancel, context)` | Legacy low-level bootstrap; Configure installs its own adapter. Do not replace it while using the ABI. |
| `ReArcTabCreate(profile, space, url, out_tab)` | Any live initialized profile, nonzero shell space label; null URL keeps the initial empty about:blank document without synthetic navigation. Explicit URLs queue their initial load; an immediate Navigate supersedes it. Returns ID before tab.created; tab starts hidden. |
| `ReArcTabClose(tab, force, completion, context)` | Normal close honors beforeunload; conservative dialog policy vetoes confirmation. Force skips veto, retains cleanup. Unique pending close; closed completion follows tab.closed. |
| `ReArcTabNavigate(tab, url, transition)` | Valid UTF-8/GURL and allowed scheme required: http, https, data, file, audited chrome:// hosts below, exact about:blank, or view-source wrapping http(s)/file. transition 0 typed, 1 link, 3 generated; no renderer initiator/user gesture is synthesized. |
| `ReArcTabReload(tab, ignore_cache)` | NavigationController normal/bypass-cache reload. |
| `ReArcTabGoBack(tab)` / `ReArcTabGoForward(tab)` | NavigationController history; no-op if unavailable. |
| `ReArcTabStop(tab)` | Stops loading. |
| `ReArcTabRefreshState(tab)` | Queues complete core presentation snapshot. |
| `ReArcTabActivate(tab)` | Focuses only an attached presented tab in its registered key, visible, nonminiaturized window; otherwise invalid_state. |
| `ReArcWindowRegister(window, ns_window)` | Nonzero shell ID and +0 NSWindow pointer; engine retains registration; duplicate live ID rejected. |
| `ReArcWindowClosed(window)` | Invalidates this window's leases with window_closed, releases window registration; tabs persist. Native will-close notification invokes this too. |
| `ReArcViewAttach(tab, window, width, height, scale, out_attachment)` | Returns unique lease and **+1 NSView** handle, starts hidden. Registered window required. One attachment per tab. |
| `ReArcViewDetach(tab, attachment)` | Empties host and invalidates lease, no event; does not release the host's +1 returned retain. |
| `ReArcViewResize(tab, attachment, width, height, scale)` | Finite nonnegative DIP up to 32768 per dimension; finite scale in (0,16]. Host rounds to AppKit points; display scale remains authoritative. |
| `ReArcViewSetVisible(tab, attachment, visible)` | After parenting NSView into registered window, combines pane intent with native visibility/miniaturization/occlusion. Wrong destination window is invalid_state. |
| `ReArcViewRelease(view)` | Releases exactly one ABI-returned NSView retain; null allowed. Detach/dismantle first. |
| `ReArcBufferFree(buffer)` | Frees an engine-allocated binary result, null allowed. Never free callback strings. |

### Trusted navigation admission (1.1)

Create and Navigate share the same valid UTF-8/GURL admission policy. The host
is trusted browser UI: `data:` is admitted as a browser-initiated top-level
navigation, `file:` uses Chromium local-file handling, and the audited hosts
`chrome://settings`, `chrome://version`, `chrome://history`,
`chrome://downloads`, `chrome://password-manager`, `chrome://extensions`,
and `chrome://credits` use Chromium WebUI. The four daily-use hosts require `webui_daily_pages`
(ABI 1.14); Credits requires `webui_credits` (ABI 1.52). The original two
remain available to earlier hosts. Paths, queries
and fragments stay under the same exact host. Other WebUI hosts are rejected
until their browser-tab helper dependencies are audited. Settings
omits pay-over-time controls when no autofill client exists; browser-window
actions in WebUI are not a replacement for a BrowserWindow integration.
`view-source:` admits exactly one wrapper around a valid http(s) or file URL.
Exact `about:blank` is admitted. javascript, blob, chrome-untrusted, devtools,
other chrome hosts, external protocol handlers, other about URLs and nested view-source are rejected
with invalid_url. Accepted means dispatched, not guaranteed to commit; Chromium
retains redirects, WebUI access, file security and renderer navigation policy.
A link transition is classification only: it grants neither renderer identity
nor user activation. The shell must not forward arbitrary page messages as
trusted navigation commands. Installed boosts/link peek remain scoped to
http(s); opening WebUI or files does not grant expression evaluation or capture privileges.
The internal page client stays attached across admitted scheme changes to retain
future-document registrations. Boost source scope and link-peek listeners reject
non-http(s) documents; explicit evaluation/capture reject file and WebUI.
Returning to an eligible page preserves the acknowledged plan.

## Core callbacks and ownership

`ReArcCallbacks.ready(context, default_profile_id)` fires after profile and
browser services initialize. The registry holds a `ScopedProfileKeepAlive`;
the shell holds an application keepalive until orderly shutdown. All tabs and
adopted contents carry the engine-assigned profile ID. `tab_event` receives
`ReArcTabEvent`: kind 0 created, 1 updated, 2 closed, 3 navigation committed,
4 navigation failed. ABI 1.25 (`tab_discard`) adds kind 5 discarded and kind 6
discard cleared; see the S7 section below. Every event carries nonzero profile_id, tab_id and
content_generation. Compare generations before applying asynchronous results.
Created includes space/opener/disposition. Disposition 0 shell, 1 foreground
tab, 2 background tab, 3 popup; it requests placement without focus or a new
native window. Chromium-created contents are adopted intact.

For updated, `changes` is a bitmask: 1 URL, 2 title, 4 loading, 8 progress,
16 crashed, 32 canGoBack, 64 canGoForward. Only marked fields apply. Creation
is followed by a full snapshot. Visible URL comes from Chromium; security is
never inferred from it. History state refreshes after navigation. Navigation
events carry navigation_id, URL and main-frame flags; transition 0 typed,
1 link, 2 reload, 3 generated, 4 other, plus original qualifier bits. Failure
error_code/error_text are Chromium net errors, distinct from ABI errors.
`ERR_ABORTED` is cancellation. Closed reason 0 shell, 1 page, 2 engine.
`tab.closed` is the final tab event; correlated close completion may follow.

`view_invalidated(context, ReArcViewEvent*)` carries the same identity plus
attachment_id and reason 0 tab_closed, 1 window_closed, 2 content_replaced,
3 engine_stopped. The engine has already emptied the stable NSView host and
released its own retain. Swift may keep its +1 until NSViewRepresentable
teardown, then calls ReArcViewRelease; expired IDs fail stale_attachment.
Never cache or own Chromium's renderer widgets, layers or child views.

For SwiftUI, bridge `attachment.native_view` to NSView with
`Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()`, keep the ABI
retain until dismantle, call detach on dismantle/identity change, then release
through ReArcViewRelease. Layout calls resize; it does not recreate tabs.
All displayed split panes receive visibility intent. Native window observers
reconcile occlusion separately from hidden. Lease transitions use
`UpdateWebContentsVisibility`, whose pin implementation handles the first
VISIBLE transition before using WasShown/WasHidden/WasOccluded internally.
No media pause, freeze or discard is implied by hiding.

## Errors (IPC-CONTRACT §8)

| Value | Name |
|---|---|
| 0 | ok |
| 1–4 | tab_not_found, window_not_found, profile_not_found, not_found |
| 5–9 | invalid_url, invalid_argument, invalid_state, engine_not_ready, version_mismatch |
| 10–13 | unsupported, busy, already_attached, stale_attachment |
| 14–16 | too_large, cancelled, internal |
| 17–18 | script_error, timeout (evaluation) |

These are the contract spellings. Synchronous validation uses these returns;
async failures use the completion status. Beforeunload veto uses OK with
cancelled=true, matching close/shutdown reply outcome rather than an error.
No callback may synchronously wait for Chromium to make progress.

## Services functions and callbacks

Advertised features: `native_view`, `navigation`, `navigation_extended`, `media_session`, `favicon`,
`security_state`, `user_scripts`, `link_peek`, `snapshot_viewport`,
`snapshot_full_page`, `script_evaluation`, `script_evaluation_identity`,
`profiles`, `profile_off_the_record`, `page_zoom`, `isolated_page_messages`,
`rearc_safe_storage_branding`, `webui_daily_pages`, `history_recording`,
`password_autofill` (1.15), `find_in_page` (1.16), `downloads` (1.17),
`javascript_dialogs` (1.18), `file_chooser` (1.19), `permission_prompts` (1.20),
`context_menu` (1.21), `password_prompts` (1.22), `history_query` (1.23),
`dangerous_downloads` (1.24), `tab_discard` (1.25), `search_autocomplete`
(1.26), `html_fullscreen` (1.27), `printing` (1.28), `page_drops` (1.29),
`picture_in_picture` (1.30, video PiP; see below), `extension_tab_helpers`
(1.31), `extension_install_prompts` (1.32), `extension_actions` (1.33),
`autofill_suggestions` (1.34), `password_leak_detection` (1.35),
`extension_windows` (1.36), `autofill_save_prompts` (1.37), `http_auth`
(1.38), `link_open_requests` (1.39), `devtools` (1.40),
`client_certificates` (1.41), `key_equivalent_events` (1.42),
`pip_embedded` (1.43), `perf_metrics` (1.44), `early_window` (1.45),
`media_capture` and `search_engines` (1.46) and `extension_side_panels`
(1.47). `pip_control`, `pip_native`
and `script_opener` remain unadvertised names. Unknown optional operations are unsupported.

| Function | Semantics |
|---|---|
| `ReArcEngineSetServiceCallback(callback, context)` | Installs/replaces service callback, null disables it. Register before creating tabs to receive initial state. Context is borrowed; queued service events consult the current registration. |
| `ReArcTabMediaAction(tab, action)` | 0 play, 1 pause, 2 toggle, 3 next, 4 previous, 5 pause-all in this tab. First five require the addressed controllable session and advertised action; absent session is invalid_state, unavailable action unsupported. Pause-all suspends registered players in this WebContents and succeeds if none exist. |
| `ReArcTabSetMuted(tab, muted)` | WebContents mute, independent of media-session availability; observed state follows. |
| `ReArcEnginePauseAllMedia()` | Applies per-tab pause-all to the registry's live tabs, never a global focused system session. |
| `ReArcTabSetPictureInPicture(tab, active)` | Before 1.30, or without a `picture_in_picture` callback: unsupported, and pip_available/pip_active stay false. With it, see [video PiP](#video-picture-in-picture-130). |
| `ReArcFaviconGet(tab, icon_ref, out_data, out_size)` | Returns decoded/re-encoded PNG from the adapter cache, scoped to tab/profile/session. No URL fetch. Stale ref is not_found. Output is +1 malloc storage; free using ReArcBufferFree. On rejection outputs are null/0. Cache entries are bounded to 64 KiB by the favicon adapter. |
| `ReArcTabSetScripts(tab, entries, count, completion, context)` | Replaces the ordered document script/CSS plan. Copies all inputs. Empty plan removes registrations/styles. At most one install per tab: concurrent call busy. Completion means registrations are acknowledged; navigate afterward for document-start guarantees. |
| `ReArcTabRefreshStyles(tab)` | Reapplies CSS to current primary document in isolated worlds; no script rerun. Asynchronous best effort, not an evaluation-result API. Busy during plan replacement. |
| `ReArcTabSetLinkPeek(tab, enabled, completion, context)` | Registers/removes an isolated host-world trusted shift-click listener in future and current primary documents. One change pending per tab. Completion acknowledges future-document registration; current listener application is asynchronous. |
| `ReArcTabCaptureSnapshot(tab, scope, completion, context)` | 0 viewport, 1 full scrollable primary page. One pending capture per tab. Native Chromium PNG encoding, no shell bitmap painting. PNG transferred as +1 malloc storage to completion, free with ReArcBufferFree. |

`service_callback(context, ReArcServiceEvent*)` receives borrowed strings and
struct, plus nonzero profile_id/tab_id/content_generation. Kind 0 is favicon:
page_url identifies the committed document; favicon_cleared removes the icon,
otherwise icon_ref is immutable until eviction/navigation/teardown. Kind 1 is
media: playback 0 playing, 1 paused, 2 stopped, 3 unknown; audible and muted
come independently from WebContents. For media kind 1, has_metadata=false
means metadata is unchanged, never cleared; ignore its title/artist/album.
has_metadata=true replaces all three fields together; empty title, artist and
album explicitly clear metadata. This engine emits full media snapshots with
has_metadata=true on every media event, including initial, mute-only, absent
metadata and observer-disconnect snapshots. On non-media kinds these fields
are inapplicable. `media_metadata_snapshot` advertises this emitter guarantee. PiP flags are false. Kind 2 is security:
0 secure, 1 insecure, 2 dangerous, 3 none, 4 unknown. It uses Chromium's
visible-security-state machinery, including pending navigation, Safe Browsing
and HTTPS-First precedence. Kind 3 is link peek: href is a validated http(s)
anchor URL; do not treat it as a navigation authorization or origin assertion.

All service adapters attach after tab.created for shell-created and adopted
tabs, so their initial events cannot precede creation. Teardown passes through
close_controller: cancel script/snapshot work, detach typed adapters/observer,
empty leases, destroy contents, emit tab.closed, then complete close. In-flight
script/link registrations and snapshots receive cancellation on teardown;
no late service event follows tab.closed. No Chromium pointer crosses a queue.

### Boost plan semantics

`ReArcScript` contains id, an array of `ReArcScriptScope`, run_at (0 document
start, 1 DOMContentLoaded/document end), UTF-8 source and CSS. id is a unique
1–128 character ASCII alphanumeric/underscore/hyphen key. Supply empty source
or CSS strings when unused. Each ID gets its own `rearc.boost.<id>` isolated
world; the page and other packages cannot read its JS globals. Source is
trusted host-supplied code, never page-provided bridge commands. No user
activation or universal cross-origin access is granted. Installed plans always
use isolated worlds; explicit host evaluation can opt into the main world.

Scopes within one entry are OR-ed, so overlapping scopes never execute the
script twice. Each scope has canonical ASCII host, path_prefix, an
include_subdomains bool and scheme_mask (HTTP=1, HTTPS=2, both=3). Exact hosts
may be subdomains or IPs. include_subdomains requires a registrable host under
Chromium's PSL including private registries; public/private suffixes are
rejected. A path matches exactly or at a slash boundary. Only primary-frame
http(s) documents are eligible; about:blank, internal pages and subframes
receive no boost. Limit 128 entries, 32 scopes per entry, 1 MiB total UTF-8.
Invalid input changes nothing. A protocol failure during acknowledged plan
replacement can leave a partial plan: retry the complete replacement; existing
registration IDs are retained for cleanup. There is no rollback of script
side effects.

CSS is applied in array order, refreshed on pageshow, same-document SPA
navigation and explicit refresh, and removed when scope no longer matches.
Replacement removes orphan style nodes and prevents old pageshow listeners
from recreating them. Existing-document JS is not rerun on replacement;
executed IDs remain once per document, matching the shell's revision guard.
New registrations take effect on the next navigation. An empty plan on a fresh
tab is acknowledged without a DevTools attachment or synthetic navigation;
nonempty script/peek registration bootstraps a blank renderer only when needed. Await the install
completion before load/reload; CSS refresh completion is intentionally not a
barrier for painting.

To map `BoostRuntimeEntry`, sort by order, use lowercased package UUID as id,
copy all hostScope rules into one entry, map exact/registrableDomain matching
to include_subdomains, preserve schemes/pathPrefix, concatenate validated CSS
rule blocks in order, and pass JS only when scriptUserEnabled. Swift retains
its validation and per-profile selection policy; the ABI applies that plan
only to the addressed tab. Raw WKContentWorld/message-handler wrappers are
not required. The ABI already supplies isolated worlds, once-per-document
execution and pageshow/SPA CSS refresh. `refreshBoostsOnPage` calls
ReArcTabRefreshStyles.

### Link peek and snapshots

The internal per-tab DevTools client installs the shift-click listener and
binding in `rearc.host`, never the page's main JS world. Delivery requires a
trusted shift-left-click and a top-frame isolated execution context matching
the current frame. Page JS cannot manufacture a trusted click or call the
isolated binding. While enabled the eligible click's normal navigation is
suppressed. Disable with SetLinkPeek(false) when the Swift handler is nil.
There is no renderer browser-target/debugging connection exposed by this ABI.

Scope 2 (ABI 1.51, `page_theme_color`) is the top edge: see "Page theme
colour (1.51)".

Snapshot callback `(context, status, tab_id, content_generation, data, size)`
receives null/0 on failure; success transfers a PNG buffer to the host. The
host must free it even if it rejects a stale generation. Full-page capture
uses Chromium's content bounds plus captureBeyondViewport. Maximum encoded
PNG is 16 MiB (`REARC_MAX_BLOB_BYTES`), 64 million CSS pixels and 16384 per
side. Larger documents return too_large; missing compositor/protocol support
returns unsupported/invalid_state. Navigation cancels a pending capture even
when content_generation has not changed. Internal requests have a 30-second
deadline; teardown cancels remaining work. Full-page capture is supported,
but cross-origin child frames, fixed/sticky layers and lazy content follow
Chromium's screenshot behavior; it does not scroll to trigger page loaders.

For `WebEngine`, navigation/state come from core callbacks; build a Combine
publisher from media kind 1 (`isPlaying = playback == 0`, isAudible, title,
artist, canPictureInPicture=false). Native view comes from the retained
attachment. Media methods map to actions 2/3/4/5; mute is independent.
`captureSnapshot` maps visible/fullPage to 0/1 and resumes the Swift continuation
from the completion, copying PNG into Data before freeing it.

### Script evaluation (1.2)

`ReArcTabEvaluateScript(tab, source, world, boost_id, timeout_ms, completion,
context)` evaluates a UTF-8 expression in the current primary document and
awaits Promises. world=0 uses `rearc.boost.<boost_id>`; a null boost_id chooses
`editor`. Pass the same id as an installed boost to inspect its globals.
world=1 explicitly selects the main world and requires null boost_id. Other
world values or invalid ids return invalid_argument. No user activation,
command-line API, universal access, remote debugging port or browser target
is granted. File/WebUI evaluation is unsupported; http(s), data and committed
about:blank are eligible. The call is trusted host code, never a page bridge.

A pending primary navigation is invalid_state; wait for its commit before
evaluating. One evaluation may be pending per tab (otherwise busy). The deadline is
1–30000 ms for the entire operation including context lookup. Source is at
most 1 MiB UTF-8 and returned JSON at most 16 MiB. A successful accepted call
returns exactly one callback `(context,status,tab_id,content_generation,json,
error_json)` on main through the serialized delivery queue. Rejection has no
callback. Copy both strings before returning; neither is BufferFree storage.
Success has JSON and null error; undefined maps to JSON null. Non-JSON values
such as BigInt or nonfinite numbers fail serialization. Error has null JSON
and an object `{code,message,details}`; exception details carry Chromium's
line/column/exception information. New statuses are script_error=17 and
timeout=18. A thrown/rejected Promise reports script_error; a deadline reports
timeout; cross-document navigation, tab close and target loss report cancelled.
Content generation identifies the original contents, even if its document has
changed. Cancellation and timeout stop observing; they do not roll back JS or
stop already running page side effects. Never synchronously wait on main.

Swift adoption: check `script_evaluation` before enabling the editor/picker.
Wrap the C completion in a retained context/continuation; release it exactly
once on callback, or immediately on synchronous rejection. Use world=0 with
the lowercased package UUID to inspect a boost, or null id for a shared editor
world. Use world=1 only for intentional page-world interaction. JSON-decode the
copied result (String JSON is quoted); preserve the structured error and
status. Set a finite timeout, and treat cancelled as an obsolete document.
Statements should be wrapped in an IIFE returning the desired value.

## Native verification

After a green build, `python3 engine/tests/run_c_abi.py` builds small native
hosts against the public header/framework, physically assembles the upstream
app layout and runs real Chromium with a fresh profile/default sandbox. Disposable native test profiles use
`--use-mock-keychain` to avoid authorization of a different temporary
executable identity on every build; production never receives this switch. It
checks callback deferral and identity, attachment ownership/invalidation,
close ordering, orderly shutdown, isolated boost timing and CSS, favicon
retrieval, mute/security events, viewport/full-page PNGs and native trusted
shift-click delivery. The build-gate rule applies before each invocation.
Logs: `runtime-abi-core.log` and `runtime-abi-services.log`.

The native host also mirrors visibility to the public `GetNativeView()`
container. At this pin `WebContentsViewMac::CreateView` hides that container
when initially_hidden=true; `UpdateWebContentsVisibility` changes the renderer
widget but does not replace Chrome's ViewsHostableSetVisible responsibility.
Showing only the wrapper leaves the page hidden and unable to receive mouse
input. The wrapper now toggles that stable container as well, resigning a
content first responder before hiding, while Chromium still owns its children.

Wave-10 validation: core first green `build-p21.log` (attempt 2), final core
`build-p22.log`; services first green `build-p24.log` (attempt 2), integration
refinements green in p25–p27, final export-order audit green `build-p28.log`.
G1–G5 pass in `smoke-tab017.log` and `smoke-tab018.log`. Native core/services,
CSS replacement/pageshow, overlapping scopes, navigation cancellation and
trusted link peek pass in `runtime-abi-core.log` / `runtime-abi-services.log`.
Pure C syntax and Clang module import pass. `nm-tab017.log` verifies 27 C ABI
symbols; `nm-tab018.log` verifies 37 definitions plus framework resolution.
All 40 public exports (including upstream entries) are covered by the release
order list with ChromeMain last. No optimized/non-component build, Swift
integration or standalone signing/packaging claim is made by these checks.
Full patch replay evidence is in `replay-abi.log`.

## Profiles (1.6)

`profiles` and `profile_off_the_record` advertise these additive functions.
The startup profile stays available to existing ABI 1.5 hosts.

- `ReArcProfileOpen(name, completion, context)`: asynchronous persistent
  create/open; name is a case-sensitive ASCII `[A-Za-z0-9_-]{1,64}` storage key,
  not a display name or a filesystem path. Map to a dedicated directory below
  user-data-dir (`ReArcProfile-` plus uppercase hex of the ASCII key, so A/a remain distinct on case-insensitive macOS filesystems). Chromium ProfileManager owns
  creation and initialization. Concurrent opens of the same key coalesce;
  initialized live opens return the same engine id through deferred callbacks.
- `ReArcProfileCreateOffTheRecord(parent_id, completion, context)`:
  asynchronous unique OTR profile per accepted call, using Chromium's named
  OTRProfileID machinery. Require an initialized persistent parent. Its disk
  backing must remain in-memory/OTR; never simulate it with a temporary normal
  profile. Hold the original profile alive until its last OTR child is gone.
- Both creation completions use `(context,status,profile_id,is_off_the_record)`;
  rejected calls have no completion; accepted calls complete exactly once.
  IDs are monotonic per engine run, never persisted or reused. Callback status
  is OK only after ProfileManager initialization and the bridge keepalive exist.
- Existing `ReArcTabCreate(profile_id,...)` then accepts any live initialized
  profile. Stamp that id on every created/adopted tab and every service event;
  popups inherit the source BrowserContext. No cookie/storage or tab migration
  occurs when a Space changes its selected profile.
- `ReArcProfileClose(profile_id,force,completion,context)` closes its tabs
  sequentially using the existing close controller. Profile lifecycle closes serialize globally; reject a close during another
  close or any open-in-progress with busy. Opens during a close are busy. Mark it closing before accepting work, so
  new tabs are rejected. A beforeunload veto returns OK/cancelled=true and
  restores availability; tabs already closed remain closed. Its tab/service
  callbacks, leases and accepted async operations must terminate before the
  profile-close completion. Close OTR children explicitly first (parent close
  with live children is busy). Default-profile close is invalid_state; engine
  shutdown owns that lifetime. Closing a persistent profile releases it without
  deleting the directory; reopening keeps cookies/storage but gets a new id.
  Closing OTR invokes Chromium's OTR destruction and erases its volatile data.
- Shutdown cancels pending opens exactly once, closes tabs in every profile,
  destroys OTR profiles before releasing parent keepalives, and retains the
  existing successful-shutdown-last-callback guarantee. No profile pointer
  may cross an asynchronous boundary without managed lifetime protection.

The native profiles host verifies two named profiles + two OTR children show separate cookies,
localStorage, service ids, boost plans, favicon caches and adopted-tab profiles
against the same loopback origin; named state survives close/reopen and a new
process; OTR state does not. Exercise close veto, concurrent opens, pending
initialization during shutdown, parent-before-child rejection and live leases.
ProfileManager owns persistent initialization. OTR teardown uses ProfileDestroyer,
with a BrowserContext destruction sentinel retaining the original keepalive
until cleanup completes. Named-profile close releases the bridge identity and
keepalive, never deletes files or promises immediate ProfileManager unloading.
No profile events were added: existing tab/view/service identities carry the
profile; accepted profile calls return lifecycle state through completions.

## First-load and Keychain findings (wave 12)

The loopback stress host creates 30 hidden and 30 attached tabs, navigates each
once, waits for a fixture title, then closes it; per-load watchdog is 20 s,
without retries. `runtime-abi-stress-before.log` records the original real
Keychain run (hidden maximum 12.174 s). A subsequent real-Keychain URL run
stalled past 120 s. NetLog locates the gap between COMPUTED_PRIVACY_MODE and
NETWORK_DELEGATE_BEFORE_START_TRANSACTION: cookie retrieval waits for its crypto
initializer. `runtime-abi-keychain-stall-sample.txt` captures the worker in
OSCryptAsync GetKeyTask → KeychainPassword::GetPassword → SecItemCopyMatching →
SecurityServer::decrypt; the browser UI thread remains responsive. This rules
out an about:blank commit/visibility/boost-install wait for that reproduction.

The shell bundle script ad-hoc signs the replaced executable. Temporary native
hosts also have changing executable identities. A fresh user-data-dir does not
isolate the macOS `Chromium Safe Storage` Keychain item. Stable application
signing and authorized Keychain access are required for production cookie
persistence; replacing the binary can trigger authorization again. The sample
proves a SecurityServer wait; interpreting its authorization/ACL cause is an
inference from the signing setup. Do not pass mock-keychain or weaken cookie
encryption in production to hide it. The engine cannot grant that OS access.

The first-document change removes redundant work: null creation no longer
submits a real about:blank navigation, and DevTools attaches only when a page
service is used. A fresh empty boost plan/disabled peek is already satisfied.
Nonempty script/peek installation still creates a renderer to acknowledge
future-document registration before navigating, as required by the existing
contract. Effective visibility, occlusion and Chromium throttling are unchanged.
In the matched mock-Keychain comparison, 60/60 loads pass both before and after;
medians remain about 1.25 s, so this is not evidence of a large latency reduction.
No synthetic blank commits occur in the final 60-load run. Slow render-process
startup in this component debug build is distinct from the Keychain stall.

Swift adoption: keep the native visibility/boost-install rules. Create an empty
tab with a null URL, then navigate to its actual destination; there is no need
to await a placeholder commit or add a retry. Continue awaiting a nonempty
boost-plan acknowledgement. Update the shell self-test's old data:-rejection
assertion to verify a successful data: commit. Keep the existing conditional
media metadata update: false means unchanged, true plus empty strings clears.
The picker can bootstrap BoostPickerScript in the default editor isolated
world and evaluate `__rearcBoostPicker.snapshotAt(x,y)` from its native overlay,
returning the object directly. WebKit's messageHandlers are not installed by
this ABI; use native hit coordinates plus evaluation results, and JSON-decode
returned objects rather than assuming an unquoted JavaScript String.

### Shutdown while authorization is pending (1.5)

The shutdown reproduction has main in ThreadPoolImpl::Shutdown waiting for the
already-started default SKIP_ON_SHUTDOWN key-loading task, and its worker in
SecurityServer decrypt. The production keychain and password-name storage are
process-lifetime singletons. The read task now uses CONTINUE_ON_SHUTDOWN so an
unanswered OS authorization cannot keep ChromeMain (and the ABI's last shutdown
completion) waiting. Explicitly injected borrowed test keychains retain SKIP
semantics. This does not grant authorization, disable encryption, change the
stored key, force-close profile databases or interrupt user-data writes.
The framework still must stay loaded until process exit, as required by ABI 1.

The native stress runner supports a test-only Safe Storage interposer using
`--block-keychain`; it makes lookup wait forever without accessing a real key.
It runs the host directly because the SIP-protected `/usr/bin/timeout` strips
DYLD injection variables. The runner owns and terminates only its own child on
watchdog failure. `--mock-keychain` is mutually exclusive and is for disposable
profiles in normal deterministic tests. Neither option is a production fix.
Swift requires no shutdown-call change: retain callback contexts until Run
returns and keep the existing completion-driven teardown. Production first-load
Keychain access still requires stable signing/authorization; this fix bounds
teardown responsibility, not authorization latency.

## Evaluation identity (1.7)

`script_evaluation_identity` adds ReArcTabEvaluateScript2 and
ReArcTabGetDocumentIdentity. Original EvaluateScript and its callback keep their
ABI 1.5 signatures. The new callback receives a borrowed ReArcScriptResult with
status, document identity and JSON/error strings. Copy it and strings on main.
The identity includes profile_id, tab_id, content_generation,
document_generation and navigation_id, captured when the evaluation is accepted.
It is also returned unchanged for cancellation, timeout or script errors.

Document generation starts at 1 for the initial document and advances on every
primary cross-document commit, including reload and BFCache restoration.
Same-document commits retain document generation and update navigation_id.
Navigation id is Chromium NavigationHandle::GetNavigationId for the last primary
commit; it is 0 before a first commit (and when adopting an already committed
contents before any bridge-observed navigation). Compare against a fresh
GetDocumentIdentity before applying a retained result; no commit-event counting
is needed. Both evaluation APIs share the same per-tab busy slot and all prior
policy/timeouts. A navigation attempt still cancels pending evaluation even if
that attempt ultimately fails, while a new generation requires an actual commit.
file/WebUI evaluation stays refused: admitted navigation does not grant the
internal DevTools client local-file or privileged WebUI execution authority.

## Page zoom (1.8)

`page_zoom` adds ReArcTabGetZoomFactor(tab,&factor),
ReArcTabSetZoomFactor(tab,factor) and ReArcEngineSetZoomCallback(callback,context).
Callbacks receive borrowed ReArcZoomEvent with document identity and factor;
copy it on main. Null callback disables delivery. Initial state and upstream
ZoomController changes are delivered asynchronously; closing tabs cannot emit
late zoom events. Factors are finite and in Chromium's [0.25,5.0] browser range.
Setting before a live render frame exists returns invalid_state.

The factor is browser page zoom (1.0 = 100%), distinct from CSS or pinch zoom.
The bridge creates an upstream ZoomController, suppresses its Chrome UI bubble,
and retains ZOOM_MODE_DEFAULT. HostZoomMap shares per-host settings across tabs
in the same profile, and ChromeZoomLevelPrefs persists them. Navigating to a
host with no saved zoom uses the profile default; returning restores its saved
zoom. This follows Chromium's host/scheme rules rather than inventing a shell
per-tab override. Normal profiles have separate maps. Chromium's OTR zoom map
inherits initial parent settings and retains its upstream private-map behavior;
OTR zoom is not a durable shell preference.

Swift should query the factor when selecting a tab, set preset factors directly,
and consume zoom callbacks for all affected tabs. Do not assume only the tab
passed to SetZoomFactor will change, or maintain a competing persisted zoom map.

## Isolated page messages (1.9)

`isolated_page_messages` adds
ReArcEngineSetPageMessageCallback(callback,context). Register on main before
installing boosts/evaluating the editor. Installed boost sources and explicit
isolated evaluation can call `rearcPostMessage(JSON.stringify(value))` on the
primary http(s) document. Main-world and iframe page scripts cannot access the
function. Internally CDP bindings are limited to exact isolated context names
or the host-selected isolated executionContextId; there is no global binding.
The raw CDP function is retained in a closure and removed from the isolated
global. A frozen wrapper bounds size/rate before CDP serialization, with an
independent browser-side validator and budget.

The borrowed ReArcPageMessage contains captured document identity, boost_id
(`editor` for the default editor world), and UTF-8 JSON. Copy strings before
returning, JSON-decode and handle them as data. Never forward arbitrary payloads
as trusted shell commands. No user activation, cross-origin permission, file
or WebUI execution authority is granted. Registering a callback does not run
host code in a document; the normal install/evaluation APIs supply that code.
Installed JavaScript effects, including its isolated channel, can persist until
navigation after a plan is removed, as with other boost side effects.

Limits: 64 KiB of UTF-8 JSON, 60 attempts per fixed one-second window per tab
across worlds, and at most 60 queued deliveries per tab. The renderer wrapper
also limits each world to 60 attempts/second. Malformed, oversized, over-budget,
non-primary and stale-document messages are silently dropped. The wrapper
returns false when it rejects locally, true after invoking its sender; true is
not a host acknowledgement. JSON must be RFC JSON within Chromium's parser
nesting limit. Navigation attempts invalidate queued old-document deliveries
immediately, even before a new commit. Close prevents late delivery. Null
callback disables queued and future host delivery, preserving registrations.
Use DOM/input event handlers (and coalesce frequent selection changes) instead
of shell polling; evaluation remains available for explicit initial snapshots.

## macOS build-time branding (1.10)

`rearc_safe_storage_branding` advertises the selected BRANDING-based Safe Storage
naming mechanism. The supported build selects PRODUCT_SHORTNAME=ReArc and
MAC_BUNDLE_ID=com.rearc.browser in chrome/app/theme/chromium/BRANDING. A generated
os_crypt header derives service `ReArc Safe Storage` and account `ReArc` from that
short name; no ReArc literal is hardcoded in os_crypt. Generated app, framework
and helper bundle identifiers use the ReArc root. Full product/executable names
remain Chromium for this minimal overlay. See [PACKAGING-MAC.md](PACKAGING-MAC.md)
for the required Team ID, outer app/helper IDs, signing/entitlements and release
BRANDING input. Naming does not grant Keychain authorization or migrate old
Chromium-encrypted state. Configure(1), persistence encryption and existing
shutdown/callback semantics are unchanged.

## OS permission reads and shutdown (1.11)

`os_permission_shutdown` advertises non-blocking teardown for the production
macOS media-permission cache's read-only TCC status query. A named-profile
blocked-Keychain reproduction samples main in ThreadPoolImpl::Shutdown and
an active SKIP_ON_SHUTDOWN task in SystemMediaPermissionCache →
CheckSystemAudioCapturePermission → AVCaptureDevice → TCC preflight. The
OSCrypt read is already CONTINUE_ON_SHUTDOWN; ProfileDestroyer and cookie
writes are not the wait in that sample. Starting a SKIP task makes shutdown
wait for it. Production TCC status reads now continue without holding shutdown;
they capture only process-lifetime function callbacks, and replies use weak
cache references. Borrowed test authorization wrappers retain SKIP semantics.
No authorization is granted or requested by this change. Cookie encryption,
profile database shutdown, and all data-writing task traits are unchanged.
Keep the framework loaded until process exit, including after Run returns.

## Shutdown with pending tab closes (1.12)

`shutdown_pending_closes` allows Shutdown while standalone TabClose or page
closes are in flight, including the interval after registry removal and before
actual WebContents destruction. Each accepted TabClose still completes exactly
once, after tab.closed and before successful terminal shutdown completion.
Normal shutdown joins an existing close and honors its veto; forced shutdown
promotes it to forced cleanup, preserving the original reply. A normal joined
veto completes both requests with OK/cancelled=true and resumes engine service;
previously closed tabs stay closed. The existing 30-second close deadline still
bounds an unresponsive normal unload. Force bypasses veto, not data cleanup.

The exact remaining busy cases are another accepted Shutdown (until completion,
including profile release and ChromeMain unwind), or an accepted ProfileClose
(until its completion, including OTR destruction). A pending ProfileOpen is
cancelled once by accepted shutdown. A second TabClose on the same tab still
returns busy. Calls rejected synchronously receive no completion. Null shutdown
completion is invalid_argument even while busy; before ready/after stopping
without a pending shutdown is engine_not_ready. An existing successful pending
shutdown remains busy even after its terminal completion because this engine
run cannot restart. ABI 1.10 hosts may keep their wait-before-Shutdown strategy.

## Existing profile directories and Default adoption (1.13)

`profile_directory` adds `ReArcProfileOpenDirectory(directory,completion,context)`.
It opens an existing regular profile **in place** under the configured
user-data-dir. Use `"Default"` for the legacy startup data, then associate the
returned profile ID with the chosen shell profile. It never moves, copies,
renames, merges or deletes databases. Persist the directory token in the host's
profile metadata; persist no engine ID. Other shell profiles continue to call
ProfileOpen with their stable keys, whose hex directory mapping is unchanged.

The token is one ASCII basename, 1–128 bytes, using letters, digits, underscore,
hyphen or interior spaces. Paths, dots, Unicode, leading/trailing spaces and
null required arguments reject synchronously as invalid_argument. Validation
of the existing directory happens asynchronously: missing/wrong-case/non-directory
is not_found; a symlink is invalid_argument; a non-regular Chromium profile is
unsupported. Failures return profile ID 0 / off_the_record=false. Rejected calls
receive no callback; every accepted call receives one deferred callback. Normal
shutdown cancels pending validation/initialization once with cancelled.

An exact on-disk spelling check prevents duplicate database contexts on macOS
case-folded filesystems. A duplicate open (including a named-key open that maps
to the same directory) coalesces and returns the existing identity. Opening the
startup directory returns DefaultProfile's ID and does not transfer its
lifetime: ProfileClose for that ID still returns invalid_state. Keep it through
engine shutdown and close its OTR children normally. An independently opened
non-startup profile follows the ordinary ProfileClose rules.

Swift adoption: gate minor >=13 and profile_directory, resolve the new symbol
before calling on a weak-linked older framework, and use the same retained
one-shot ProfileRequest callback as ProfileOpen. On successful completion,
persist `.directory("Default")` for exactly one selected shell profile UUID;
open that mapping on every later launch before creating its tabs. Leave other
profiles as `.named(lowercasedUUID)`. Commit the mapping only on success. Do not
create a fresh named directory and copy files while Chromium is running. This
preserves existing data in its original BrowserContext and allows ordinary
private children under the adopted ID.

Directory adoption requires the same authorized Safe Storage key as the stored
data. It does not convert pre-wave-14 Chromium Safe Storage ciphertext to the
ReArc key. Preserve an offline backup and perform any old-key migration as a
separate authorized operation before opening such data with a differently
branded engine; see PACKAGING-MAC.md. No silent key fallback is introduced.

## Hidden loading and evaluation findings (wave 16)

Production policy is unchanged. In the matched mock-keychain load-only controls,
10 hidden / 10 attached loads per control have zero timeouts. Baseline medians
are 1277.564 / 1261.942 ms; disabling timer throttling gives 1268.745 / 1265.106,
renderer backgrounding 1305.996 / 1259.717, frame-rate cap 1288.858 / 1509.423.
No first-load gain justifies a blanket hidden/attached-pending exemption.

Direct warm hidden evaluation has a 4.112 ms median. An awaited eight-timer
chain has a 10670.734 ms hidden median versus 54.915 attached; diagnostic timer
disablement reduces hidden to 53.506 without making it visible. All 24 hidden
rAF requests time out at 350 ms; all 24 attached complete. These fresh tabs do
not reach intensive-throttling grace age. Thus timer/frame-dependent Promises
can be slow while the evaluation request itself starts promptly. Preserve
IPC-CONTRACT §5/§6; use direct evaluation/events and real foreground attachment,
not timer polling or fake visibility. Full controls and limitations are in
WAVE-16-REPORT.md and the bridge README. No production diagnostic flag is added.

## Daily-use WebUI admission (1.14)

`webui_daily_pages` adds history, downloads, password-manager and extensions to
Create/Navigate's exact-host allowlist. Configure still takes 1, all ABI 1.13
layouts and symbols remain unchanged, and there are no new exported functions.
The internal DevTools registration client uses the same allowlist so installed
http(s) scripts survive a round trip through every new host. This grants no
WebUI evaluation, capture or boost privileges.

| Host | Browser-less policy / limits |
|---|---|
| history | Chromium browsing-history query, search and removal handlers use Profile/HistoryService. Classic history and synced-tabs pages are admitted. Journeys is disabled without a TabInterface: its handler requires a Browser for grouping/open-all. A direct request for that handler disconnects safely. Browser-dependent clear-data/sign-in actions already guard null Browser; open settings/clearBrowserData directly from the shell. Synced-session restore remains a Chrome window action, not a shell-tab implementation. |
| downloads | Chromium DownloadManager/list tracker, search and item actions. Browser-dependent warning-bubble and enhanced-protection actions already guard missing Browser. Native drag and OS actions require a real attached window; admission alone adds no download events or path policy. |
| password-manager | Chromium password stores, listing, checkup/settings and OS authentication remain authoritative. Shortcut creation, batch upload and relaunch safely do nothing without a Browser; passkey unlock and share IPH already guard null. Save/update prompts and page autofill require the later tab-helper concern. |
| extensions | Chromium extension registry, profile configuration, enable/disable and detail UI. Inspection's Browser/TabStripModel activation already guards missing Browser. File selection, installation prompts, toolbar actions and popups are not supplied by admission. |
| settings, version | Existing admission retained; settings content/siteDetails, search, clearBrowserData and importData paths do not need additional hosts. Browser-dependent actions retain their existing limitations. |
| flags | Rejected: FlagsUIHandler::HandleRestartBrowser calls AttemptRestart, outside the host's terminal shutdown/relaunch contract. No in-process restart is supported. |
| all others | Rejected, including bookmarks, restart, quit, crash, devtools and chrome-untrusted. No wildcard or prefix match. |

Native `c_abi_webui_host.mm` loads 11 real routes in an attached browser-less tab,
checks rendered shadow DOM and live Chromium history/password/extension handlers,
invokes guarded password actions, rejects WebUI evaluation/capture through the
ABI, and returns to HTTP to verify the acknowledged script plan. Its separate
loopback DevTools socket exists only in this test with a disposable profile;
production ABI policy is unchanged. The test releases Chromium's separate
REMOTE_DEBUGGING automation keepalive using Browser.close after ABI tab closure
and accepted shutdown. See WAVE-18-REPORT.md for evidence and Swift
adoption.

## Browser-less tab helpers (1.15)

`history_recording` and `password_autofill` add no symbols and change no
layouts. Every bridge tab (created, adopted, or renderer-created through
`WebContentsCreated`) gets an audited subset of Chromium's own helpers before
its first navigation: ZoomController, the profile's autofill client
(`ContentAutofillClient`/`ContentAutofillDriverFactory`),
`ChromePasswordManagerClient` (`ContentPasswordManagerDriverFactory`),
`HistoryTabHelper` (non-OTR profiles only, as in stock Chrome), `FindTabHelper`
and the download `NavigationMonitor` observer that TabFeatures owns on
desktop. `TabHelpers::AttachTabHelpers` and TabFeatures are not used: both
assume a TabInterface/TabStripModel and attach prompt helpers
(PermissionRequestManager, ManagePasswordsUIController, TabDialogs) that
belong to later concerns.

| Helper | Browser-less audit and disposition |
|---|---|
| HistoryTabHelper | `IsEligibleTab` required `FindBrowserWithTab` on desktop. One upstream hunk accepts contents owned by a live bridge `TabSession` (`rearc::IsBrowserlessTabContents`). Chromium keeps its URL, transition, redirect, title, 404 and prefetch rules. Browser type annotates as unknown. Popup visits that commit before adoption are not recorded. |
| ChromeAutofillClient / ContentAutofillDriverFactory | Constructed through `AutofillClientProviderFactory`. Browser lookups are nullable (`MaybeGetFromContents`, guarded `FindBrowserWithTab`). The suggestion popup supports a non-views Cocoa parent and declines when the view has no window. |
| ChromePasswordManagerClient | Filling, credential-usage bookkeeping, leak checks and the password stores are Chromium's. Without a `PasswordsClientUIDelegate` (ManagePasswordsUIController is not attached), `PromptUserToSaveOrUpdatePassword` returns false. New or updated credentials are therefore not saved until a prompt concern exists. "Manage passwords" from a suggestion should open chrome://password-manager in the shell, not a Browser. |
| FindTabHelper | Inert until the 1.16 ABI. Requires the delegate's `FindReply` forwarding (1.16). |
| DownloadNavigationObserver | Feeds the profile NavigationMonitor (download scheduling), as TabFeatures does. Owned per tab by the bridge. |

Native `c_abi_helpers_host.mm` (with run_c_abi.py post-checks) visits two
HTTP pages and reads them back through Chromium's history page handler. It
then checks the rendered chrome://history list, adds a credential with
`chrome.passwordsPrivate.addPassword`, and loads a login form that
ChromePasswordManagerClient fills on load (`:-webkit-autofill`). A real
DevTools-injected click releases Chromium's value gatekeeper, and the
submitted URL carries the filled credential. After shutdown, the History DB
has both rows with titles and Login Data shows `times_used=1`. The test uses
loopback DevTools and Chromium's `--disable-backgrounding-occluded-windows`
test switch only because the session's locked screen occludes every window.
Neither is production policy.

## Find in page (1.16)

`find_in_page` adds `ReArcEngineSetFindCallback`, `ReArcTabFindStart`,
`ReArcTabFindNext`, `ReArcTabFindStop` and `ReArcFindEvent`. It is a thin
adapter over Chromium's FindTabHelper: the helper owns renderer requests,
stale-reply filtering and highlighting.

| Function | Semantics |
|---|---|
| `ReArcEngineSetFindCallback(cb, ctx)` | Installs/replaces delivery; null disables, including queued events. |
| `ReArcTabFindStart(tab, text, options, &session)` | options: `REARC_FIND_FORWARD`=1, `REARC_FIND_MATCH_CASE`=2, other bits invalid_argument. text: 1..16384 bytes of valid UTF-8. Always starts a new session and returns its nonzero, monotonically increasing ID. An active session first ends with terminal reason 4 replaced. |
| `ReArcTabFindNext(tab, forward)` | Next/previous match of the active session (wraps); invalid_state without one. |
| `ReArcTabFindStop(tab, action)` | 0 clear selection, 1 keep selection, 2 activate selection (e.g. follow a found link); terminal reason 3. invalid_state without a session. |

`ReArcFindEvent`: profile/tab/content_generation, `session_id`, `match_count`,
1-based `active_ordinal` (0 = none), `final_update`, `reason`. Reason 0 is a
result; Chromium sends several partial results per request, so act on
`final_update` and ignore other session IDs. Every session gets exactly one
terminal event (final, counts -1): 1 navigated (primary-frame cross-document
commit), 2 closed (delivered before `tab.closed`), 3 stopped, 4 replaced. A
partial result for the old document may arrive just before its navigation
terminal. Find needs laid-out content: an unattached tab has a 0×0 view and
reports 0 matches, so present the tab at a real size. Find runs on WebUI and
file pages too; it grants no script privileges.

Native `c_abi_find_host.mm` checks invalid arguments, 4 case-insensitive
matches with ordinals 1→2→1→4 (backward wrap), 2 case-sensitive matches, and
each terminal reason exactly once, including close before `tab.closed`.

## Downloads (1.17)

`downloads` adds `ReArcEngineSetDownloadCallback`, `ReArcDownloadSetPolicy`,
`ReArcDownloadAction` and `ReArcDownloadEvent`. Chromium's DownloadManager stays
the source of truth: target determination, danger checks, download history,
auto-resumption and chrome://downloads all keep working, and the bridge only
observes them (Chromium's `AllDownloadItemNotifier`, one per registered bridge
profile, OTR included).

| Event field | Meaning |
|---|---|
| kind | 0 created (including items restored from history at profile load, with their current state), 1 updated, 2 completed, 3 interrupted, 4 cancelled, 5 removed. Kinds 2–4 mark state transitions; later updates of the same state are kind 1. |
| profile_id, download_id | Bridge profile and Chromium's per-profile item ID (actions take both). `guid` is Chromium's stable GUID. |
| tab_id | Initiating live bridge tab, else 0. |
| url, target_path, mime_type | Borrowed UTF-8. target_path is empty until Chromium determines it. |
| received_bytes, total_bytes | total 0 = unknown. |
| state | 0 in_progress, 1 complete, 2 cancelled, 3 interrupted. |
| danger_type, interrupt_reason | Chromium `download::DownloadDangerType` / `DownloadInterruptReason` values (0 none). Danger 4 (maybe dangerous content) is normal while Chromium's check is pending; a clean item completes with 0. |
| paused, can_resume | DownloadItem state. |

| Function | Semantics |
|---|---|
| `ReArcDownloadSetPolicy(profile, directory, prompt)` | directory: absolute UTF-8 without `..`, ≤4096 bytes, or null to keep the current one. It is written to the profile's Chromium DownloadPrefs and persists. Chromium creates a missing directory on first use. prompt 0 saves without asking (the only mode); 1 is unsupported until the file chooser ABI; other values invalid_argument. |
| `ReArcDownloadAction(profile, id, action)` | 0 pause (in progress, not paused), 1 resume (`CanResume`), 2 cancel (not done), 3 open (complete and openable), 4 reveal in Finder (target known), 5 remove from Chromium's list/history (cancels an active item; emits removed). Wrong state: invalid_state. Unknown/transient/removed: not_found. |

Two upstream hunks keep embedded mode window- and picker-free.
ChromeDownloadManagerDelegate::OpenDownload uses the macOS platform handler
instead of `ScopedTabbedBrowserDisplayer`, which would otherwise create a
Chrome window for types Chromium prefers to open in the browser (PDF, HTML,
images). RequestConfirmation never shows Chromium's file picker: preference and
save-as confirmations continue at the suggested path, and everything else
(conflict, unwritable, no space, too long) cancels, which the host sees as kind
4. This is what lets OTR profiles download at all, because Chromium forces
"ask where to save" for them. The bubble UI controller finds no browser windows
and does nothing. Dangerous items stay in progress, with their danger type, until
the host cancels or removes them. ABI 1.24 adds the explicit native warning actions described below; older hosts
can continue using chrome://downloads for keeping an item. CRX/extension
installation from a download is not claimed.

Native `c_abi_downloads_host.mm` checks policy validation, then a 64 KiB
download into the policy directory (byte size on disk, reveal invoked once). A
1 MiB trickle exercises pause → paused/can_resume → resume → progress →
cancel → remove → not_found. A truncated response auto-resumes inside Chromium
and ends interrupted; cancelling it then succeeds. An OTR-profile download
completes uniquified (`rearc-small (1).bin`) with no picker. The success path of
open is not invoked in tests, to avoid launching an application. Its state
validation is.

Wave 18b evidence: gates-tab033/034/035.log (all native hosts, G1–G5, and 4
stress processes / 16 shutdown tabs per concern); unmodified ABI 1.13 and 1.14
header hosts pass; replay-w18b.log 36/36. Exact Swift adoption steps are in
WAVE-18-REPORT.md "Wave 18b".

## Host prompt channels (wave 18c)

These are additive callback channels. Gate each before registering or exposing
its shell UI: `ReArcEngineABIMinorVersion() >= N` **and**
`ReArcEngineHasFeature(feature)`. Configure still takes major 1. Do not extend
`ReArcCallbacks` or any preexisting structure. All callbacks run on deferred
Chromium UI tasks. Copy event strings/arrays before returning. IDs are nonzero,
monotonic within their channel and never pointers. Respond on the main thread.
A response consumes the request; a late/repeated response returns `not_found`.
No callback means conservative cancellation/dismissal, never Chromium prompt UI.
Register callbacks before creating tabs. Replacing/unregistering cancels pending
requests and invalidates queued events belonging to the previous registration.

| Minor | Feature | Registration | Reply |
|---|---|---|---|
| 18 | javascript_dialogs | ReArcEngineSetJavaScriptDialogCallback | ReArcJavaScriptDialogRespond(id, accept, text) |
| 19 | file_chooser | ReArcEngineSetFileChooserCallback | ReArcFileChooserRespond(id, cancel, paths, count) |
| 20 | permission_prompts | ReArcEngineSetPermissionCallback | ReArcPermissionRespond(id, decision, persist) |
| 21 | context_menu | ReArcEngineSetContextMenuCallback | ReArcContextMenuCommand(id, action) |
| 22 | password_prompts | ReArcEngineSetPasswordPromptCallback | ReArcPasswordPromptRespond(id, action) |

Each event includes profile/tab/content-generation/request identity and phase
0 request or 1 cancellation. Navigation to a new primary document, tab teardown
and replacement cancel outstanding requests; file/dialog requests also cancel
when their originating frame dies. Context commands check the originating
Chromium weak-document identity. Cancellation events let the shell dismiss UI;
they require no response. Completion of an accepted engine command does not
promise that an OS operation, download or password-store write has finished.

JavaScript kinds are 0 alert, 1 confirm, 2 prompt, 3 beforeunload. Message,
default text, serialized requesting-frame origin and reload flag are supplied.
Beforeunload accept continues the existing close/navigation pipeline and reject
vetoes it; there is no parallel shell close pipeline. Prompt reply text is
UTF-8, at most 64 KiB (null means empty). Chromium still controls user-activation
requirements and suppression. No timeout auto-accepts a pending request.

File modes are 0 open, 1 multiple, 2 upload folder, 3 directory, 4 save. Filters
are Chromium's page-supplied accept extensions/MIME types in Chromium order.
The shell presents the panel and handles save overwrite confirmation. Replies
use absolute UTF-8 paths with no parent references, at most 4096 paths and
4096 bytes per path. Only multiple mode accepts more than one. Upload folder
accepts one root: the engine enumerates regular descendants off-thread,
excluding symlinks, with 10k-file/8-MiB-path limits. Enumeration or filesystem
failure cancels. Media-capture file inputs cancel instead of invoking an OS
camera UI. Directory drag-and-drop enumeration and desktop File System Access
panels are not part of this delegate channel. Download policy prompt=1 now
requires a registered host file chooser; Chromium's confirmation callback uses
the chosen path. Without a host, the 1.17 download fallback remains.

Permission events contain requesting and embedding origins plus an array of
Chromium `PermissionKeyForRequestType` strings. Chromium can coalesce camera
and microphone; one response resolves that group. Decisions: 0 allow, 1 deny,
2 dismiss. Persistent decisions use Chromium's normal permission contexts and
HostContentSettingsMap. `persist=false` resolves only the current request,
without writing a site setting; future requests may prompt again. Dismiss
never stores an allow/block. This is distinct from Chromium's one-time grant,
which may remain valid for the origin until its tabs close. Device permission,
secure-context, permissions-policy, gesture, embargo and enterprise rules stay
Chromium's. Camera/microphone requests go through MediaCaptureDevicesDispatcher;
screen/tab capture and audio-output selection remain unsupported. A site grant
does not grant macOS TCC access. Wave 16's shutdown traits are unchanged.

Context events contain sanitized link/source URLs, page/frame URLs, selection,
editable/image flags, Blink media type/edit flags and RenderView-local DIP
coordinates. The shell maps them into its view/window coordinates and builds
its NSMenu. Commands: 0 open link in current tab, 1 copy link, 2 copy, 3 paste,
4 cut, 5 select all, 6 save image, 7 copy image, 8 inspect (unsupported), 9 back,
10 forward, 11 reload, 12 dismiss. Disabled commands return invalid_state and
leave the ID pending. Unsupported Inspect does likewise: Chromium's
DevToolsWindow opens Browser UI and is not suitable for browser-less tabs.
With `devtools` (1.40) the shell implements Inspect itself: dismiss the menu
and call `ReArcTabOpenDevTools` for the source tab.
The shell can open a separate tab with the event's link URL via TabCreate.
Image actions use RenderFrameHost's renderer operations and downloads retain
Chromium's target/safety policy. URLs/selection are untrusted page data.

Password events contain the submitted form origin, username and update flag;
password values never leave Chromium through this API. Actions are 0 save or
update, 1 never, 2 dismiss. They call PasswordFormManagerForUI's Save,
OnNeverClicked and OnNoInteraction respectively. Successful submission detection,
credential matching/encryption, blocklisting and store writes stay Chromium's.
The offer owns the form manager until reply/cancellation, and only subsequent
navigation cancels it. The shell can continue using the admitted
chrome://password-manager page for management and store changes.


## Profile history query and deletion (1.23)

Gate on minor >=23 and `history_query`. These use the addressed profile's
Chromium HistoryService; they do not query the WebUI or read SQLite directly.
All three reject OTR profiles with `unsupported` **before** consulting the
service factory, including deletion. They never resolve an OTR request to its
original profile. Unknown profiles return `profile_not_found`; unavailable or
stopping engines return `engine_not_ready`. A disabled/unavailable history
service is `unsupported`.

| Function | Contract |
|---|---|
| `ReArcHistoryQuery(profile, text, limit, callback, context)` | Non-null valid UTF-8, <=4096 bytes; limit 1..1000. Empty text lists recent unique URLs; nonempty text uses HistoryService's title/URL matching. Newest visit first, one row per URL, excluding 404 visits. |
| `ReArcHistoryDeleteURL(profile, url, completion, context)` | Non-null valid UTF-8/GURL <=65536 bytes. DeleteURLs removes that URL's visits and metadata. A bounded query on the same sequenced backend provides the completion barrier. |
| `ReArcHistoryDeleteRange(profile, begin_us, end_us, completion, context)` | Local history visits in [begin,end), microseconds since Unix epoch. Zero means unbounded in that direction; (0,0) deletes all local history. Nonzero end must exceed begin. Nonnegative endpoints up to 253402300799999999 (year 9999). Chromium updates URL counts and associated data. |

Query callback receives status, profile ID, borrowed `ReArcHistoryEntry[]` and
count. Each row has UTF-8 title/URL, `visit_time_us` (Unix microseconds) and
Chromium's total URL `visit_count`. Empty/error results have null rows/count 0.
Copy rows and strings before returning; do not BufferFree them. Serialized
result strings are bounded to 8 MiB; larger output completes `too_large`.
A host request token in `context` can reject results for older command-bar text.
Debounce input and respect `busy`: at most 64 query/deletion requests are pending
across profiles. No cross-request completion ordering is promised.

Accepted operations invoke their non-null callback once on a deferred UI task;
synchronous rejection invokes none. Profile release cancels pending observation
with `cancelled` before close completion. Already dispatched deletions can still
take effect after observation is cancelled. A deletion completion has
`cancelled=false`; cancellation is expressed in its status. Deletion is local;
no server-history deletion or synced-delete directive is claimed. The native
history fixture checks text/recent/limit/counts, exact range boundaries,
URL removal, profile isolation, OTR rejection and close cancellation.

## Dangerous download actions (1.24)

Gate on minor >=24 and `dangerous_downloads`. The 1.17 event **already contains**
`danger_type`; its layout and `ReArcDownloadAction` numbers 0..5 stay intact.
Action 6 remains invalid for legacy hosts.

| Function | Contract |
|---|---|
| `ReArcDownloadGetWarning(profile, id, out_warning)` | Current item snapshot: Chromium `danger_type`, `insecure_status`, `is_dangerous`, `is_insecure`. Non-null output is zeroed on rejection. |
| `ReArcDownloadResolveDanger(profile, id, action)` | 0 keep, 1 discard. Requires an unfinished item that is dangerous or insecure. Keep calls ValidateInsecureDownload first when insecure, otherwise ValidateDangerousDownload, as chrome://downloads does. If both warnings exist, one explicit keep can leave the other pending: re-query before another user decision. Discard calls DownloadItem::Remove, cancelling and removing the item and its file through Chromium. |

Use `is_dangerous`/`is_insecure` to offer a decision. A nonzero danger code alone
is insufficient: 4 is a pending check, and 6 means user-validated. Insecure
status values at this pin: 0 unknown, 1 safe, 2 validated, 3 warn, 4 block,
5 silent block. Wrong state returns `invalid_state`; retired/transient/unknown
items return `not_found`; unknown profile is `profile_not_found`; action >1 is
`invalid_argument`. No auto-open, safety-policy mutation or scanner bypass is
introduced. Success means dispatched; final file completion/deletion follows
Chromium. Queued item snapshots can outlive item removal; a fresh warning query
can already return not_found before the queued removed event arrives.

The native fixture uses Chromium's existing manual Safe Browsing hash blocklist
with inert 64-KiB bytes and link-transition .sh downloads. It receives dangerous
content (3), explicitly keeps one to completion (user-validated 6), discards the
other, and checks the retained file and absence of discarded temporary/final
files. No test opens/executes the downloaded content. The insecure-first branch
and uncommon-warning path use the same stock item validation methods but were
not independently generated in the native fixture.

## Preserving tab discard, S7 (1.25)

Gate on minor >=25 and `tab_discard`.
`ReArcTabDiscard(tab)` uses WebContents::Discard; `ReArcTabGetDiscardState(tab,
&bool)` queries its logical WasDiscarded state. No completion callback or
renderer wait is needed. OK means logically discarded; document resources are
released asynchronously. A refusal changes no tab identity. Unknown tab returns
tab_not_found; invalid query output is invalid_argument and a provided output
is reset to false before validation.

Embedded Run merges WebContentsDiscard into enabled features, leaving the
stock/headless feature default untouched. An explicit host
`--disable-features=WebContentsDiscard` wins: discard returns unsupported.
Discard rejects visibility intent (even an occluded/minimized window), any
non-hidden contents, loading/pending navigation, absent committed entry,
crashed/non-live frame, capture, audible media, either PiP kind, fullscreen and
beforeunload/unload handlers with invalid_state. Script/peek plan installation
returns busy. These conservative checks also avoid content's speculative
pending-commit refusal. A refusal still detected by content returns busy.
There is no bypass of unsaved-document protection.

This path retains the **same WebContents**, profile/tab/content-generation,
navigation entries, audited helpers, installed scripts and stable NSView lease.
No view.invalidated or reattachment is required for discard. The document is
recreated on presentation (view visible / effective visibility becoming visible),
a valid TabActivate, or explicit navigation/reload/back/forward. Chromium's
controller LoadIfNecessary handles visibility; TabActivate also requests it.
The usual focus preconditions still apply to TabActivate. Restored document
identity advances on commit, and document.wasDiscarded is Chromium's flag.
Evaluation/snapshot work cancels; pending prompts/menus cancel; active find
ends once with new reason **5 discarded**. Script/peek registrations survive.
Document operations reject invalid_state while discarded. Hiding alone still
never discards.

The existing `ReArcTabEvent` layout is unchanged. New kind **5** means discarded
and **6** means discard cleared, with URL/title and the normal identity. Creation
and RefreshState include the current discard-state kind after the full updated
snapshot; navigation clears a discarded state. Ignore these kinds on hosts
without the feature. The shell maintains its own bool from these kinds or the
query. Updated event bitmask fields retain their original meanings.

No TabLifecycleUnit or null TabStripModel is used, no replacement contents are
allocated, and no RenderProcessHost is killed: a sibling sharing a renderer
must survive. BFCache is flushed by Chromium. PerformanceManager's
TabPageDecorator now ignores preserving discards of non-tab pages, because
these have no TabHandle; its existing real-tab invariants remain. This is a
bounded, explicit host memory-reclamation operation, with no synchronous wait
for a renderer. It adds no automatic memory-pressure scheduler, pin policy,
freeze policy, footprint guarantee or process-wide kill. Pins remain shell
metadata; the host may explicitly discard a hidden pin.

The native fixture runs with process-per-site to share a renderer: five
logical discards, four restores, retained back/forward entries and boost,
unchanged content/lease identity, sibling JavaScript state, evaluation/find
cancellation, protected-state rejection and shutdown while discarded. A second
process verifies explicit feature disable. See WAVE-18D-REPORT.md for gates and
known limits. A hosted frontend tab cannot be discarded (unsupported). Context-menu
Inspect remains unsupported; use `ReArcTabOpenDevTools` (1.40).

## Default search and autocomplete (1.26)

Gate on minor >=26 and `search_autocomplete`. All calls address a live bridge
profile, wait for that profile's TemplateURLService to load, and complete on a
deferred UI task exactly once (synchronous rejection completes nothing). Text
is non-empty UTF-8 <=4096 bytes. Unknown profile `profile_not_found`, stopping
engine `engine_not_ready`. At most 64 calls may wait for keyword loading
(`busy`). Profile release completes waiting calls and the active query
`cancelled` before close completion.

| Function | Contract |
|---|---|
| `ReArcSearchGetDefaultProvider(profile, cb, ctx)` | Default engine: name, keyword, `search_url` and `suggest_url` as ready-to-use URLs with Chromium's template parameters resolved and `%s` for the terms (`suggest_url` empty when none), `is_managed` (policy), `is_prepopulated`. No default: `not_found`, null provider. |
| `ReArcSearchSetDefaultProvider(profile, provider, completion, ctx)` | Non-empty name, keyword without whitespace, http(s) templates containing `%s`; null/empty suggest URL means none. Reuses an identical normal engine for the keyword, otherwise adds a user engine, and makes it the user-selected default (Chromium persists it). Policy-managed default search: `invalid_state`. OTR profile: `unsupported`. |
| `ReArcSearchClassifyInput(profile, text, cb, ctx)` | Chromium's AutocompleteClassifier over synchronous providers (no network, no inline autocompletion): kind 1 URL with the navigable destination, kind 2 search with the default engine's results URL, kind 0 none. `match_type` is AutocompleteMatchType. |
| `ReArcAutocompleteStart(profile, text, options, cb, ctx, &query_id)` | Starts the profile's single AutocompleteController query; returns a nonzero ID. options bit 1 prevents inline autocompletion. |
| `ReArcAutocompleteStop(profile)` | Ends the active query (cancelled terminal result). Idle: OK, no callback. |

Query results arrive as zero or more `done=false` updates and exactly one
`done=true` result per accepted ID: OK (complete, or Chromium's 1.5 s stop
timer), or `cancelled` when superseded by the next Start, Stop or profile
release. Updates of a superseded query are dropped; its cancellation is
delivered. Each `ReArcAutocompleteMatch` has kind (1 URL, 2 search),
`match_type`, relevance, `allowed_to_be_default`, `deletable`, contents,
description, destination URL, `fill_into_edit` and `inline_autocompletion`, in
Chromium's result order (grouped, not strictly by relevance). Copy rows and
strings before returning.

Providers: regular profiles use bookmark, builtin, history quick/URL/fuzzy,
shortcuts, keyword, calculator and search. Zero-suggest, document, on-device,
ML scoring, open-tab, history-cluster/embedding and contextual providers are
not constructed. Remote suggestions come only from SearchProvider, under
Chromium's CanSendSuggestRequest rules (suggest pref on, not OTR, suggest URL
distinct from search URL). OTR IDs share their original's keyword service, as
Chromium does, but use a provider client that returns no history, in-memory
URL index, bookmarks or shortcuts: results are what-you-typed, verbatim
search, keyword and builtin matches only. Consistent with `history_query`,
an OTR ID never reveals the original profile's browsing data, and SearchProvider
never issues a suggest request for it.

## HTML fullscreen (1.27)

Gate on minor >=27 and `html_fullscreen`. The tab delegate implements
`CanEnterFullscreenModeForTab`, `EnterFullscreenModeForTab`,
`ExitFullscreenModeForTab`, `IsFullscreenForTabOrPending` and Escape in
`PreHandleKeyboardEvent`. A request is admitted only when a fullscreen callback
is registered and the tab has visibility intent and non-hidden contents; Blink's
own user-activation and focus rules still apply. Without a callback the page's
request is refused (pre-1.27 behavior). Entering resynchronizes renderer visual
properties so `requestFullscreen()` resolves inside the current view; the host
then makes its window natively fullscreen, hides sidebar/toolbar and resizes the
view as usual.

`ReArcFullscreenEvent` carries profile/tab/content-generation identity captured
at entry, phase 0 entered / 1 exited, the page-requested `display_id` (-1 none)
and an exit reason: 0 page or engine (document.exitFullscreen, navigation,
Chromium security drops), 1 host (`ReArcTabExitFullscreen` or callback
replacement), 2 Escape key, 3 tab closed, 4 view hidden. Each entry has exactly
one exit event. `ReArcTabExitFullscreen(tab)` returns `invalid_state` when not
fullscreen. `ReArcTabGetFullscreenState(tab, &bool)` resets its output, then
reports state. Callback replacement exits every fullscreen tab; those exits are
not delivered to the old or new host. Discard still refuses fullscreen tabs.

## Printing (1.28)

Gate on minor >=28 and `printing`. **Choice: PDF generation, host print UI.**
Browser-less tabs now carry Chromium's printing helpers
(`InitializePrintingForWebContents`: PrintViewManager, PdfNupConverterClient,
PrintCompositeClient). `ReArcTabPrintToPDF` uses PrintViewManagerBase's
`PrintToPdf`/PdfPrintJob, the path behind Page.printToPDF, and returns +1 PDF
bytes (free with `ReArcBufferFree`). The host shows NSPrintOperation over
PDFKit for Cmd+P, or writes the bytes for Save as PDF. Chromium's print preview
is a WebUI constrained dialog that needs a Browser and WebContentsModalDialogManager,
and its system dialog would attach a Chromium-run modal NSPrintPanel to the
shell's window; neither is used. PDF generation needs only the tab's renderer,
works for hidden tabs, and keeps all print UI in the shell.

PrintViewManager's scripted-preview, requested-preview and system-dialog
(`ScriptedPrint`) entry points recognize registry tabs: they complete the
renderer's request immediately, so `window.print()` returns and
beforeprint/afterprint fire, and post a `ReArcPrintRequestEvent` (source 0
window.print, 1 other page request) when a print callback is registered.
The page's DOM is printed in its post-afterprint state. Chromium's renderer
throttling of repeated script prints applies.

`ReArcPrintOptions` (null for defaults): landscape, print_background,
header_footer (Chromium's default header/footer), prefer_css_page_size, scale
(0 default, else 0.1..2), paper size in inches (0 default, Letter), margins in
inches (negative default, about 0.39 in), page_ranges (null/empty all, ASCII
<=4096, Chromium syntax). One job per tab (`busy`). Results: OK with bytes;
`invalid_argument` for malformed or out-of-range ranges; `too_large` above
256 MiB; `cancelled` on primary cross-document navigation, discard, close or
frame teardown; `internal` for other print failures. Discarded/crashed tabs:
`invalid_state`. Completions carry tab and content generation.

## Drops into pages (1.29)

Gate on minor >=29 and `page_drops`. **Audit of the previous policy:** the
embedded view delegate's `OnPerformingDrop` aborted every drop, so pages could
not receive dropped content. The renderer still received dragenter/dragover,
because WebDragDest forwards those before the delegate is consulted. Shell
drags reached the page in the same way.

`ReArcEngineSetDropPolicy(accept, blocked_types, count)` replaces the policy.
accept bits: `REARC_DROP_FILES` 1, `REARC_DROP_TEXT` 2 (plain/HTML/RTF and web
custom data), `REARC_DROP_URLS` 4, `REARC_DROP_IMAGES` 8 (promised image bytes).
`WebContentsDelegate::CanDragEnter` refuses a drag with no accepted part before
the page sees any event. At drop the delegate strips unaccepted parts and
completes Chromium's normal drop, which keeps `RenderWidgetHost::FilterDropData`
and per-file renderer read grants. Unaccepted kinds can still appear in
dragenter/dragover `types`, which is protected mode with no data, but never
reach the drop. Chromium only exposes raw image bytes as a File when a source
URL or Content-Disposition accompanies them (web-to-web and file-promise
drags); image files and image URLs use the file/URL kinds. Unhandled drops
follow Chromium. For example, a dropped link or file can navigate the frame.

blocked_types holds exact pasteboard UTIs (<=32, ASCII, 1..256 bytes, no
whitespace). WebContentsViewCocoa, the NSDraggingDestination, returns no
operation and forwards nothing for any drag carrying one. Pages receive no
dragenter/dragover/drop, so AppKit can deliver the drag to the shell's own
targets. **The shell's sidebar drags must add a private UTI and register it.**
Today they carry only a UUID string, which the shell's split overlay intercepts
when present; without the private type they would otherwise be offered to the page as text.
Invalid input changes nothing. Before the first call, drops stay aborted (pre-1.29).

## Video Picture in Picture (1.30)

Gate on minor >=30 and `picture_in_picture`. Registering
`ReArcEngineSetPictureInPictureCallback` enables the tab delegate's
`EnterPictureInPicture`/`ExitPictureInPicture`. They use Chromium's
PictureInPictureWindowManager and its Views VideoOverlayWindowViews: one
floating, frameless overlay window process-wide, with play/pause, back to tab
and close. A new PiP replaces the previous one. The overlay needs no Browser on
macOS; its placement uses the tab's attached NSWindow display.

Entry points: page `video.requestPictureInPicture()` (Blink activation rules),
and `ReArcTabSetPictureInPicture(tab, true)`, which calls the tab's
MediaSession `EnterPictureInPicture`. This is Chromium's Global Media Controls
path: it requires Chromium's availability (exactly one normal player with
unmuted audio that is PiP-eligible, or a page `enterpictureinpicture` handler),
exposed as media-event `pip_available`; otherwise `invalid_state`. MediaStream
(WebRTC/canvas) players are Chromium one-shot players and are not offered.
Already in PiP returns OK. `false` exits through MediaSession, or returns
`invalid_state` when not in PiP. Without a callback both page and host requests
fail as before (`unsupported` for the host call).

`ReArcPictureInPictureEvent` phases: 0 entered, 1 exited (page, overlay close,
host, navigation, tab close, callback replacement), 2 back-to-tab. The host
should present and focus the tab. Phase 2 is derived from the activation that
Chromium's CloseAndFocusInitiator issues in the same task as the exit;
page-initiated `window.focus()` and other ActivateContents calls are still
ignored. Media events now carry `pip_active`, plus `pip_available` while a
callback is registered. Callback replacement exits an active PiP.
**Document PiP is not supported:** Chromium opens it as an AddNewContents
`NEW_PICTURE_IN_PICTURE` Browser window, and tab adoption rejects it. Hosting
it needs a separate always-on-top WebContents window owned by the
registry/shell, which is out of this wave's scope. Auto-PiP and
Meet integration are unchanged.


## Extension tab helpers (1.31)

Gate on minor >=31 and `extension_tab_helpers`; no symbols are added.
**Audit of what earlier waves attached:** ExtensionWebContentsObserver
(ChromeExtensionWebContentsObserver) was already on every WebContents through
Chromium's universal observers. The extension view type, extensions::TabHelper
(ScriptExecutor, ExtensionActionRunner, ActiveTabPermissionGranter),
SessionTabHelper and WebNavigationTabObserver were not. Registry tabs had no
extension tab ID, and ExtensionTabUtil::GetTabById only searched Browser tab
strips, so tab-ID APIs could not reach them.

Every kTabContents registry tab (created, adopted and renderer-created) now
gets those helpers before its first navigation. SessionTabHelper is created
without a SessionService delegate, so it provides the extension tab ID and
writes no window session state. ExtensionTabUtil::GetTabById returns an open
registry tab's contents with no WindowController and TAB_INDEX_NONE, which is
what Chromium already returns for prerendered tabs. Declarative content
scripts, runtime messaging (sender.tab with the tab ID), webNavigation events,
tabs.sendMessage, scripting.executeScript by tab ID and activeTab therefore
work. Incognito rules are Chromium's: an off-the-record registry tab gets
scripts only from incognito-enabled extensions.

Before ABI 1.36 registry tabs belong to no extension window; tabs.query and
windows.* do not list them. See extension_windows below for opt-in membership.
Before 1.36, or without its host creation callback, tabs.create returns "No
current window" and runtime.openOptionsPage fails (tab/050). ABI 1.36 routes
creation to the host; the shell's tab model remains the source of truth.

## Extension prompts (1.32)

Gate on minor >=32 and `extension_install_prompts`. This follows the 18c
channel rules: register before tabs, respond on the main thread, single-use
IDs, and replacement withdraws pending requests and their queued events. In
the embedded engine, every ExtensionInstallPrompt confirmation goes to the
host. That covers Web Store webstorePrivate installs, CRX installs (including
CRXs dropped on chrome://extensions in developer mode), re-enable, permission
increase, external, remote and repair prompts. ExtensionUninstallDialog
confirmations, for example chrome://extensions "Remove" or
management.uninstall with showConfirmDialog, go to the host as kind 100.
Chromium's Views dialogs are never created.

The event carries Chromium's localized title, accept and cancel labels and
permission warning lines, the extension ID and name, and a borrowed PNG icon.
tab_id is set when the prompt is parented to a registry tab (Web Store page,
chrome://extensions drop); window-parented and background prompts carry 0.
Accept maps to ACCEPTED (or ACCEPTED_WITH_WITHHELD_PERMISSIONS, as Chromium's
dialog decides) and cancel to USER_CANCELED. For uninstall they map to
remove and cancel. Tab close, profile release and callback replacement cancel
pending requests (phase 1). Install prompts then report ABORTED to Chromium.
Without a callback, install prompts abort immediately and uninstall
confirmations cancel.

ExtensionInstallUIDesktop no longer opens a Browser window, installed bubble
or error infobar. Phase 2 (installed: ID, name, icon) and phase 3 (install
failed: Chromium's error text) are notifications instead. OpenTabHelper and
ChromeRuntimeAPIDelegate::OpenOptionsPage no longer create a Browser window
in embedded mode.

**Web Store reachability:** chromewebstore.google.com loads in a registry
tab. Its webstorePrivate calls, CRX download (Chromium's DownloadManager,
reported by the 1.17 download events) and install use Chromium's own path.
Production Web Store CRXs carry Google's publisher proof. The native fixture
cannot sign one, so it shows the store flow up to a real publisher-proof
failure (`CRX_REQUIRED_PROOF_MISSING`, phase 3), and a full install through a
locally signed CRX dropped on chrome://extensions. Still Views (not routed):
Enhanced Safe Browsing's install-friction dialog, the policy-blocked and
supervised-user (ask-parent) dialogs, and the reload-page bubble that follows
an "on click" site-access grant.

## Extension actions and popups (1.33)

Gate on minor >=33 and `extension_actions`. The host draws the toolbar.
ReArcTabGetExtensionActions returns one entry per enabled extension with an
action, for one tab, delivered deferred. OTR tabs list incognito-enabled
extensions only. Each entry has title, display badge text (including the
declarativeNetRequest count), badge text and background colors (SkColor,
0 = Chromium default), visibility (disabled for this tab when false), popup
flag, wants_to_run (blocked scripts or requests are waiting for a click) and
the icon at 1x-4x through ExtensionActionIconFactory. The icon can be
Chromium's placeholder until the extension's icon loads; a kind 0 event
follows. Events carry no state; re-query after any of them. Kind 0 is
changed (tab 0 means the default or icon for all tabs), 1 added, 2 removed,
3 popup resized. Order is ExtensionRegistry order, and pinning is the shell's.

ReArcTabRunExtensionAction is a toolbar click:
ExtensionActionRunner::RunAction grants activeTab and runs blocked actions.
Result 0 means the extension handled it (action.onClicked dispatched or a
blocked action ran). Result 2 means a side-panel action
(setPanelBehavior openPanelOnActionClick): with `extension_side_panels`
(1.47) the host toggles the extension's panel, before it nothing is shown.
Result 1 means a popup: popup_tab_id is a new
registry tab (created event with disposition 3 popup and opener = the clicked
tab) whose WebContents has view type kExtensionPopup and loads the action's
popup URL in the extension's profile. Spanning-mode extensions use the
original profile, as ExtensionViewHostFactory does. The shell attaches,
presents and closes it like a tab (ReArcViewAttach, ReArcTabClose). The
renderer auto-resizes within Chromium's 25x25..800x600 popup bounds, and each
size arrives as a kind 3 event for the shell to apply. window.close() closes
it (tab closed, reason 1). Popups get no tab identity or history.
chrome.extension.getViews({type:'popup'}) finds them. Popup contents reject
the action calls (unsupported).

**What the host must still do:** Chromium's ExtensionPopup closes on focus
loss, Escape and tab switch, and so must the shell. chrome.action.openPopup()
needs a Browser window and fails. Toolbar context menus (pin, options,
remove) and the extensions menu's site-access controls are shell UI over
chrome://extensions.

## Autofill suggestions (1.34)

Gate on minor >=34 and `autofill_suggestions`. AutofillPopupView::Create
returns a host view for registry tabs. Chromium's AutofillPopupControllerImpl
still decides when to show and hide (field focus, typing, navigation, focus
loss, pointer lock). It still owns filling, previews and its 500 ms early
accept guard, and it routes field keyboard input. Only the rendering is the
host's. Address, card, IBAN, autocomplete, datalist and password suggestions
all take this path. PasswordAutofillManager uses the same ChromeAutofillClient
(ChromePasswordManagerClient attached in 1.15). Without a callback no
suggestions UI is shown. Before 1.34, Chromium's Views popup was shown over
the shell window.

Phase 0 (shown or updated) carries the field bounds in the tab view's DIP
coordinates, with a top-left origin. Chromium's screen-space element bounds
minus the WebContents container origin give the same values. It also carries
the main filling product and the rows. Each row has value, first minor text,
first label line, an icon name, a kind (0 fill entry, 1 manage footer,
2 separator, 3 other, for example "Undo autofill") and an acceptable flag.
Password rows carry the username and Chromium's masked label, never the
password. Phase 1 is hidden (identity only) and phase 2 is the keyboard
selection: arrow keys in the field move it, Enter/Tab accept and Escape
hides, as in PopupViewViews.

ReArcAutofillAccept fills or runs a row. Within 550 ms of showing it returns
busy, because Chromium would drop the accept. ReArcAutofillSelect previews a
row or clears the preview. ReArcAutofillDismiss hides.
ReArcAutofillManage hides and posts phase 3 with Chromium's settings page for
the product: chrome://settings/contactInfo (Chromium 156's address page),
/payments, /autofill or chrome://password-manager/passwords. Accepting a
"Manage..." row has the same effect, because ChromeAutofillClient::
ShowAutofillSettings and ChromePasswordManagerClient::
NavigateToManagePasswordsPage are routed to the host instead of needing a
Browser. The host opens the URL as a tab.

The host's popup must not take key focus. Chromium hides the suggestions when
the tab's view loses focus, and shows them only while that view is first
responder in a key window (RWHVMacHasFocusReturnsFalseForNonKeyWindow).
Not supported: sub-popups (expandable rows show without children), the
search bar and tabbed (pay now/later) popup variants, deleting entries with
Shift+Delete, and the save-address/save-card bubbles (save offers are a
separate concern).

## Password leak detection (1.35)

Gate on minor >=35 and `password_leak_detection`. This is get/set for
Chromium's `profile.password_manager_leak_detection` pref, which defaults to
on as in Chrome. When on, ChromePasswordManagerClient's LeakDetectionDelegate
checks a successfully submitted sign-in against Google's leak service
(passwordsleakcheck-pa.googleapis.com). The request carries a hashed prefix
and an encrypted payload, never the plain password. When off, no check is
started. The value persists in the profile's Preferences. managed reports
enterprise policy; Set then returns invalid_state. Off-the-record profiles
never run leak checks and return unsupported. A detected leak is not yet
surfaced to the host: Chromium's leak dialog needs ManagePasswordsUIController.

**Tests:** hosts that submit sign-ins (passwords, helpers, leak phase 2)
turn it off. Since wave 18f, every native, smoke and stress process also runs
with Chromium's background services switched off
(`--disable-background-networking --disable-component-update`). Every
non-loopback name resolves to NOTFOUND
(`--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE
localhost`). Each test user-data dir starts with secure DNS off
(`Local State` `dns_over_https.mode = "off"`), because automatic DoH dials the
resolver's IP literal, which resolver rules cannot map. The run fails if any
process's net log shows a TCP connect, or a UDP socket sending data, to a
non-loopback address. A bare UDP connect() from HostResolver's IPv6
reachability probe sends nothing and is allowed. See WAVE-18F-REPORT.md for
the audit.

## Extension shell windows (1.36)

Gate on `extension_windows` and minor >=36. `ReArcTabSetExtensionWindow(tab,
window_id, active, focused)` reports the shell's logical model independently
of native attachment/visibility: split views may present several tabs. IDs are
positive signed 32-bit shell window IDs; 0 removes membership (active/focused
must then be false). A window may contain only one bridge profile. Selecting a
tab clears the other active flags in its window; focused=true focuses that
window globally, focused=false clears focus if that window was focused. Hidden
spaces can still have logical membership. Order follows tab order metadata,
then bridge tab ID. Report every tab the extensions should see; unmapped tabs
remain addressable by extension tab ID but absent from lists.

`ReArcTabGetExtensionState(tab, &state)` reports Chromium's extension tab ID
(distinct from the bridge tab ID), logical window ID, active and focused. It
zeros output on error. Ordinary registry tabs only; action popups are
unsupported. Unknown tab, closing tab, negative window, null output and a
cross-profile window assignment return the usual validation errors.

`ReArcEngineSetExtensionTabRequestCallback` registers a separate request channel.
The borrowed event carries request/profile IDs, bridge target/opener IDs,
window ID, kind, phase, active, validated URL and extension ID. Kind 0 creates a
tab, 1 creates a normal window with one tab, 2 opens an options page, 3 activates
an existing tab. window_id=0 selects the current space/window. A positive
window_id is an explicit window request. phase 0 is requested, 1 withdrawn.
There are at most 64 requests and a 30-second deadline. No callback means API
failure and no Chromium Browser window. Callback replacement withdraws old
requests without delivering them to either registration. Tab/opener close,
profile release and timeout cancel the matching request and fail its extension
Promise. Request IDs are monotonic and session-local.

For creation, the host calls `ReArcTabCreate(profile, current_space,
"about:blank", &tab)`, adopts/presents it, reports its logical window/active
state, then calls `ReArcExtensionTabRequestRespond(request, tab)`. The engine
performs Chromium renderer-initiated navigation to the validated request URL
with the extension initiator. An extension's own options/resource URL is
admitted only on this internal path; general ABI URL admission is unchanged.
For activation the host selects/presents the addressed tab and reports active
before responding with that same bridge ID. Respond with 0 to decline.
Wrong profile, target/window or missing active/membership state rejects without
consuming the request. A stale ID is not_found. The response re-resolves the
tab at queued completion, preventing a close between reply and delivery from
exposing a freed WebContents.

Supported: tabs.query/get/getCurrent, update URL/active (including default active
tab), remove one tab (waits for the existing close pipeline; veto fails the
Promise), create, runtime.openOptionsPage, windows.get/getAll/getCurrent/
getLastFocused and single-URL normal windows.create. Queries preserve
Chromium URL/title permission scrubbing and original/OTR visibility rules.
Window type is normal; state is normal; geometry is not supplied. Filters for
active, selection, window, index, status, audible/muted, title/URL, discarded,
no-group/no-split and normal window type are applied. No BrowserWindowInterface,
TabInterface or WindowController is fabricated.

Remaining: windows.remove, multi-URL window creation, panel window type,
geometry/state/incognito-profile creation, tabs.move/highlight/pin/mute/
auto-discardable mutation, array remove, window lifecycle events,
action.openPopup and generic WindowController consumers. Tab groups, tab
events, windows.update focus and popup windows came in 1.50 (below). Current and
last-focused lookups use the focused active tab for the calling profile, then
a deterministic active-tab fallback; last-focused is not separately retained
when focus is cleared. Existing action toolbar/popups still use ABI 1.33.

## Local autofill save offers (1.37)

Gate on `autofill_save_prompts` and minor >=37. Register
`ReArcEngineSetAutofillSaveCallback` for Chromium's local card and address
import offers. `ReArcAutofillSaveEvent` carries profile/tab/content-generation,
request ID, phase (0 request, 1 withdrawn), kind (0 card, 1 address), update,
origin and a display summary. Strings are borrowed during the callback. Card
summaries include only network, masked last four, expiry and name, never PAN or
CVC; address summaries include name/address/email/phone. Address display uses
en-US formatting. The host edits no imported fields in this API.

`ReArcAutofillSaveRespond(request, action)` accepts unchanged (0), declines (1)
or ignores/dismisses (2), invoking Chromium's corresponding import callback.
Invalid action returns invalid_argument; retired IDs return not_found. One offer
per WebContents, at most 64 globally. No callback means ignored, with no Views
bubble. Replacement, subsequent navigation, discard/close and destruction
cancel once; the submitting form navigation is preserved because import can
offer before that navigation starts. Callback replacement suppresses old
queued events. Chromium retains ownership of storage, deduplication and save
rules. Local card acceptance persists only locally. Account migration and
cloud-save UI are ignored for registry tabs; cloud preflight eligibility is
not disabled in production. Native tests use unsigned-in disposable profiles,
loopback HTTPS and 18f network isolation, so no Payments upload is possible.

## HTTP authentication (1.38)

Gate on `http_auth` and minor >=38. Registry tabs use a LoginHandler subclass
through Chromium's normal HttpAuthCoordinator/LoginTabHelper path. The handler
sends `ReArcHttpAuthEvent` via `ReArcEngineSetHttpAuthCallback`, with borrowed
challenger (scheme/host/port), Basic/Digest scheme, realm, proxy flag and
profile/tab/generation/request identity. phase 0 requests; phase 1 withdraws.
No password is emitted. Subresource challenges can reach this handler without
a WebContentsModalDialogManager. No Chromium login dialog is created.

`ReArcHttpAuthRespond(id, cancel, username, password)` copies UTF-8 credentials
(each <=4096 bytes, empty allowed) and calls LoginHandler::SetAuth, retaining
Chromium's auth cache, digest computation and password-manager bookkeeping.
With cancel=true strings are ignored and CancelAuth(false) runs. Invalid UTF-8,
null credentials on accept or overlong strings return invalid_argument without
consuming. Stale IDs return not_found. Absent callback cancels; registration
replacement, LoginHandler teardown/navigation and tab/profile/engine close
withdraw once. Requests are bounded to 64. A normal HTTP challenge can remain
pending until a decision or lifecycle cancellation. Proxy and subresource
paths share the adapter but only top-level Basic/Digest are natively exercised.
Client certificate selection is not part of `http_auth`; see
`client_certificates` (1.41).

## Registry security interstitials (wave 18g verification)

No new ABI or feature is needed. Chromium's SecurityInterstitialTabHelper is
created lazily by AssociateBlockingPage, even for a registry WebContents. Native
loopback tests verify an untrusted self-signed certificate warning and the Safe
Browsing `--mark_as_phishing` test blocklist, capture native rendered PNGs, and
exercise the page's actual proceed and back controls. Certificate proceed loads
the target; certificate back returns to the previous entry. Safe Browsing does
the same. Use different loopback hosts for separate decisions: proceeding
allowlists that origin, so another path on the same origin is not a fresh
warning. The fixtures never bypass certificate checks, trust a certificate in
the Keychain, or contact a Safe Browsing server. No new native interstitial
replacement UI or proceed API is exposed; the rendered Chromium page owns its
commands and policy.

## Modified link opening (1.39)

Gate on `link_open_requests` and minor >=39. `ReArcEngineSetLinkOpenCallback`
opts into registry OpenURLFromTab requests for HTTP(S) links with a user gesture
or explicit context-menu action. The existing extension queue supplies the
64-request bound, 30-second deadline and source/profile cancellation hooks, but
the callback/event layout is separate. All ABI 1.36–1.38 structs remain unchanged.
Extension callback registration/replacement and link callback registration/
replacement are independent. No callback retains the previous refusal behavior.

`ReArcLinkOpenEvent` carries profile, bridge opener/source ID, source content
generation, request ID, phase (0 requested, 1 withdrawn), disposition, user gesture,
URL and Chromium-sanitized referrer plus policy. Disposition is **1 foreground
tab, 2 background tab, 4 new window, 5 split view**. On macOS Chromium 156 maps
Command-click and middle-click to 2, Command-Shift-click to 1, Shift-click to 4,
and Option-Command-click to 5. Split UI and actual window creation belong to the
shell. The referrer is a borrowed display value; policy is this pin's
network::mojom::ReferrerPolicy numeric value. The engine retains OpenURLParams
itself, including the original referrer/policy, initiator state, source site
instance, transition, headers/body and navigation-handle callback. It never asks
the shell to rebuild a renderer-initiated navigation.

The host creates a distinct blank tab in the event's profile/current space,
reports its logical membership with `ReArcTabSetExtensionWindow`, and replies
with `ReArcLinkOpenRespond(request, new_tab)`. Use active=false for background;
active=true is required for foreground/window/split. The host controls native
presentation and focus. Response validates profile, membership/selection and
blankness, retires any queued initial blank load, then navigates the new tab's
primary frame with the original Chromium parameters and invokes the original
navigation-handle callback when a handle exists. The source tab does not
navigate. The same initial-load retirement also protects extension creation.
Passing the source, a nonblank tab, a wrong profile or an unmapped/unselected
target rejects; repeated IDs are not_found. The extension and link response
functions reject each other's request IDs. Reply with 0 to decline. If starting
navigation fails after a request is consumed, invalid_state is returned and the
host owns cleanup of its created tab.

Source/profile close, callback replacement and timeout withdraw. Replacement
suppresses withdrawn events to both registrations, as in the other prompt
channels. The opener ID is shell grouping/source identity and does not grant
script window.opener access. Explicit rel=opener, non-HTTP(S), ungestured page
opens, singleton/popup/download/off-the-record dispositions remain unsupported
on this URL-only route. Chromium-created target=_blank/window.open contents
continue through the existing AddNewContents adoption path unchanged.

## Hosted DevTools (1.40)

Gate on `devtools` and minor >=40. `ReArcTabOpenDevTools(target, &frontend)`
creates a **new** registry tab that loads Chromium's bundled frontend
(`devtools://devtools/bundled/devtools_app.html?targetType=tab&panel=elements`)
attached to the target's tab DevTools agent. The frontend ID is written before
its `tab.created` event (foreground disposition, opener = target, target's
profile and space). Attach, size, show, focus and close it like any registry
tab; placement and docking are the shell's. No Browser, DevToolsWindow, native
window or keepalive is created. Each call creates another frontend; reuse is
the shell's choice. null out => invalid_argument; unknown target => tab_not_found;
a closing target/profile or stopping engine => its usual status; a frontend
target, or one Chromium's DevTools availability policy refuses => unsupported.

URL policy: `devtools://` and `chrome://devtools` remain rejected by general
admission and are cancelled by a navigation throttle in every other registry
tab. A frontend tab admits only its exact bundled URL (reload, same-document
fragments); browser- or frontend-initiated navigation elsewhere is cancelled,
and its window.open/OpenURLFromTab requests are refused. Bindings are a
restricted allowlist: protocol dispatch to the attached target and its
auto-attached children, preferences, zoom, load completion and HTTP(S)
`loadNetworkResource`. Workspace/file-system, save, open-in-new-tab, remote
target discovery, port forwarding, AI services, extensions and window controls
reply `unsupported`. The protocol filter refuses `Browser.*`, every `Target.*`
except `setAutoAttach` and target-less `getTargetInfo`, and
`Page.setDownloadBehavior`. The client is untrusted and may not read or write
local files. No history is recorded for frontend contents.

Lifetime: closing the frontend only detaches; it never dispatches the target's
beforeunload, and a frontend close is always immediate (no veto, no deadline).
The target's close (including veto) never consults the frontend. Target
destruction, whatever its cause (shell close, window.close, deadline), force-closes
its frontends (`closed_reason` engine). Profile close and engine shutdown walk
tabs sequentially in creation order, so a target is always reached before its
frontends: a target veto cancels shutdown/profile close with the frontend still
open, otherwise the frontend is destroyed before completion. Native tests prove
open, console evaluation, Elements selection, binding/protocol denial, URL
lockdown, frontend-first close, target-first close, OTR profile close,
nonforced and forced shutdown, and nonforced shutdown during a target veto.

## Client certificates (1.41)

Gate on `client_certificates` and minor >=41. For registry tabs,
ChromeContentBrowserClient::SelectClientCertificate runs Chromium's enterprise
auto-select policy first, then hands the identity list and delegate to
`ReArcEngineSetClientCertificateCallback`. `ReArcClientCertificateEvent`
carries profile, tab, content generation, request ID, phase (0 request,
1 withdrawn), the challenger `origin` (`https://host:port`, not the page URL)
and 0..256 borrowed identities: display subject, issuer, expiry (Unix µs) and
the SHA-256 leaf-DER fingerprint as 64 uppercase hex digits. No certificate
or key bytes cross the ABI. Pointers are valid only during the callback.

`ReArcClientCertificateRespond(id, fingerprint)` with a listed fingerprint
selects that identity and returns before private-key acquisition, which runs
asynchronously through ClientCertIdentity::SelfOwningAcquirePrivateKey; Chromium
then caches the selection for that host and port. A non-64-character or
unlisted fingerprint returns invalid_argument and leaves the request pending.
nullptr cancels: the delegate is dropped, the request aborts with
ERR_SSL_CLIENT_AUTH_CERT_NEEDED and **no** no-certificate choice is cached.
That error page is not auto-reloaded (tab/059 excludes it from Chromium's
error-page auto-reload), so the host is not asked again until the page is
loaded again. Answered or retired IDs are not_found; other channels' IDs never
resolve. A host's own answer emits no withdrawal.

No callback aborts without UI. Requests are bounded to 64. Navigation of the
tab's primary main frame, tab close, profile close, engine shutdown, SSL-handler
cancellation, a failed key acquisition and a 30-second deadline withdraw once,
including while acquisition is in flight. Callback replacement or unregistering
aborts every pending request; its withdrawals are suppressed for both
registrations, as in `http_auth`. "Continue without a certificate" is not
offered. Requests without a WebContents (service workers, background fetches)
keep Chromium's behavior: abort, or continue only for an extension with no
identities.

Testing: macOS normally uses ClientCertStoreMac (Keychain identities), which
`--use-mock-keychain` does not mock. Debug, non-official builds include a
test-only memory ClientCertStore that reads `client_1`/`client_2` PEM, CA and
PKCS#8 files from net/data. It is installed only in embedded mode when both
`--rearc-test-client-cert-dir=<dir>` and `--use-mock-keychain` are present.
It is compiled out of release (`NDEBUG`) and official builds; production never
reaches it. Its key acquisition (500 ms) and signing (1000 ms) are delayed so
tests can cancel inside each.

## Page key-equivalent verdicts (1.42)

Patch `tab/061-host-key-equivalent-events`, bridge 0.44.0, feature
`key_equivalent_events`. While the page view is first responder,
`RenderWidgetHostViewCocoa` takes every Command key from the host's menu
(`performKeyEquivalent:` returns YES). Without a host route, a key the page
did not consume reached `WebContentsDelegate::HandleKeyboardEvent` and was
dropped.

`ReArcEngineSetKeyEquivalentCallback(callback, context)` (main thread;
replacing or clearing the callback drops verdicts still queued for the old
one) reports each Command or Control `RawKeyDown` that a tab's page
acknowledges, exactly once and after the page saw it:

| Field | Meaning |
|---|---|
| `profile_id`, `tab_id` | the tab whose widget (main frame or out-of-process iframe) took the key |
| `modifiers` | NSEventModifierFlags bits: shift 1<<17, control 1<<18, option 1<<19, command 1<<20 |
| `key_code` | macOS virtual key code |
| `consumed` | the ack was `kConsumed`: a keydown handler's `preventDefault`, or an editing command |
| `characters` | the key's text ignoring modifiers, borrowed UTF-8 |

Delivery is posted, never synchronous, because a host shortcut such as ⌘W
may close the tab whose widget is still notifying. The engine runs no
shortcut of its own: the host decides what an unconsumed key does. Widgets
are observed from `PreHandleKeyboardEvent` (before the key is forwarded) and
dropped when they are destroyed. Existing layouts are unchanged.

## Embedded video Picture in Picture and media actions (1.43)

Patch `tab/062-embedded-video-overlay`, bridge 0.45.0, feature
`pip_embedded`. It is only meaningful with `picture_in_picture` (1.30)
registered too: that callback is what admits page and host PiP requests.

**Media actions.** `ReArcTabGetMediaActions(tab, &bits)` returns the tab's
current Chromium media-session actions as `REARC_MEDIA_ACTION_*` bits (play,
pause, previous track, next track, seek, Picture in Picture, skip ad); 0
without a controllable session. A media service event now follows every change
of these bits, so a host reads them on the event (Arc's strip dims previous
and next without them). Unknown tab: `tab_not_found`; null output:
`invalid_argument`.

**Embedded overlay.** With `ReArcEngineSetVideoOverlayCallback` set,
`ChromeContentBrowserClient::CreateWindowForVideoPictureInPicture` returns a
`HostVideoOverlay` (`chrome/browser/rearc_bridge/rearc_video_overlay.mm`) for a
tab that entered PiP through the bridge, instead of Chromium's
`VideoOverlayWindowViews`. Without the callback, or for any other contents,
tab/048's floating window is used unchanged. The overlay is a
`content::VideoOverlayWindow` that owns a layer-hosting NSView, a
`ui::RecyclableCompositorMac` from `content::GetContextFactory()` and a
`ui::DisplayCALayerTree`. Its root is a black solid-colour layer with one
`ui::LayerSurface` child; `SetSurfaceId` adds the video's frame sink as a
child of the overlay compositor (`AddChildFrameSink`) and shows the surface,
stretched into an aspect-fit rect. The media pipeline's `VideoFrameSubmitter`
submits to that surface whether or not the tab's own view is shown, so the
video keeps its native frame rate in a hidden tab. The compositor draws only
while a session is shown and the view is in a window, unhidden and non-empty;
otherwise it is suspended. Take the view out of a window you hide.

`ReArcVideoOverlayEvent` kinds (posted, main thread; IDs are the tab's at
entry):

| Kind | Meaning | Fields |
|---|---|---|
| 0 created | once per overlay; `view` is +1, release with `ReArcViewRelease` (or a bridging transfer) after `closed` | `view` |
| 1 shown | a PiP session started (Chromium `ShowInactive`) | — |
| 2 hidden | the session ended (exit, close, back to tab, navigation, tab close); the view stays valid for a later `shown` | — |
| 3 closed | the overlay was destroyed with its controller (tab closed); no later event | — |
| 4 natural size | the video's pixel size | `width`, `height` |
| 5 state | one coalesced event per task | `playback` 0 playing, 1 paused, 2 ended; `buttons` `REARC_VIDEO_OVERLAY_BUTTON_*`; `muted`, `microphone_muted`, `camera_on` |
| 6 position | Chromium's media position | `duration` (−1 live), `position`, `rate` (seconds) |
| 7 source title | | `title` (borrowed) |
| 8 first frame | the first CALayer tree update after `shown` | — |

One overlay exists per tab controller and is reused across sessions; Chromium
keeps one PiP session process-wide, so a second tab's PiP ends the first's
(`hidden`). `ReArcVideoOverlayAction(overlay, action)`: 0 toggle play/pause,
1 next, 2 previous track, 3 skip ad, 4 microphone, 5 camera, 6 hang up, 7 back
to tab (ends the session through PictureInPictureWindowManager; PiP phase 2
follows, as for tab/048's button), 8 close, 9 close and pause, 10 play,
11 pause, 12 mute, 13 unmute. Unknown overlay `not_found`, unknown action
`invalid_argument`, not shown `invalid_state`. `ReArcVideoOverlaySeek`
(finite, non-negative seconds) seeks. `ReArcVideoOverlaySetBounds(overlay, x,
y, w, h)` reports the view's screen rect in points with a top-left origin;
Chromium sizes the renderer's PiP video to it (`UpdateLayerBounds`). Without
host reports the overlay uses the view's own window rect.
`ReArcVideoOverlayReadPixel(overlay, callback, context)` reads back the centre
pixel of the view's composited output through a `viz::CopyOutputRequest` on the
overlay's root layer, so it works with the screen locked. The callback runs once
with OK and `0xRRGGBBAA`, `invalid_state` (empty result), or `timeout` after
5 s; an overlay that is not shown or drawing returns `invalid_state` and never
calls back. A frame counter was tried first and dropped: viz forwards
CALayer params only when they change, so it counts CALayer tree updates, not
presented frames. Replacing or clearing the callback ends a shown
session first. The host may move the one view between its own windows and
panels; each move re-reads the window, scale and display. Existing layouts are
unchanged; no struct from an earlier ABI changed.

## Performance metrics (1.44)

Patch `tab/063-host-perf-metrics`, bridge 0.46.0, feature `perf_metrics`.
Measurement only: with no callback set, nothing is attached, observed or
changed, and the normal shell never sets them (only `--rearc-bench` does).
Every `*_us` time is microseconds on `mach_absolute_time`'s clock, which is
`base::TimeTicks` on macOS and the clock of `CACurrentMediaTime()` and
`NSEvent.timestamp` in the host: multiply the host's seconds by 1e6.

**Page timing.** `ReArcEngineSetPageTimingCallback` must be set before the
tabs it should measure exist: tab initialization then attaches Chromium's
`page_load_metrics::MetricsWebContentsObserver` with a bridge embedder that
registers `UmaPageLoadMetricsObserver` (so `PageLoad.PaintTiming.*` are
recorded as in Chrome) and a forwarder; no UKM, performance_manager or other
chrome/ observers. Each committed main-frame navigation reports kind 0
response start, 1 first paint, 2 first contentful paint, 3 DOMContentLoaded
event start, 4 load event start, each once, and kind 5 for every new largest
contentful paint candidate (main frame and subframes merged, `size` in
pixels). `value_us = navigation_start_us + offset`; `navigation_id` is the
tab event's; `url` is the committed URL (borrowed). Chromium batches the
renderer's timing updates, so an event can arrive well after its value.
Hidden or occluded pages do not paint: no FCP/LCP until they are shown.

**View presentation.** With `ReArcEngineSetViewPresentationCallback` set:
- kind 0 `shown`: a lease's hidden-to-visible transition (with a live
  renderer and view) first calls `WebContents::SetTabSwitchStartTime(now,
  !IsLoading(), HasSavedCompositorFrame(), false)`, as Chrome's tab strip
  does. The event carries Chromium's `Browser.Tabs.TotalSwitchDuration3`
  sample (status 0) or `TotalIncompleteSwitchDuration3` (status 1, hidden
  again first), observed with a `ScopedHistogramSampleObserver`:
  `presented_us = start_us + sample` (1 ms resolution). Samples name no tab,
  so each goes to the pending show whose elapsed time matches it best; shows
  Chromium never measures expire after 5 s.
- kind 1 `resized`: a `ResizeView` that changes the view's compositor
  viewport pixel size starts a measurement. `activated_us` is the first
  renderer frame activated at that size (`RenderFrameMetadataProvider`,
  `viewport_size_in_pixels`); then the browser compositor is asked for its
  next successful presentation (`RequestSuccessfulPresentationTimeForNextFrame`
  plus `ScheduleFullRedraw`), `presented_us`, an upper bound within one
  frame, 0 without a compositor. Status 2 superseded by a newer resize, 3 no
  frame within 2 s. `width`/`height` are pixels.

**Histograms.** `ReArcMetricsGetHistogram(name, cb, ctx)`: name UTF-8,
1..256 bytes, else `invalid_argument`. Child-process deltas are merged first
(`content::FetchHistogramsAsynchronously`, 2 s bound), then the browser's
`StatisticsRecorder` snapshot is delivered: count, sum, `[min, max)` buckets
(borrowed); `not_found` when nothing was recorded under that name. Deferred,
exactly once.

**Processes.** `ReArcEngineGetProcesses(cb, ctx)`, deferred and exactly
once: the browser (the host's own process) first, then every live renderer
(profile ID or 0, `is_extension` from the profile's `ProcessMap`, the
registry tabs with any frame in it) and browser child process (2 GPU, 3
utility with its service name, 4 other). `phys_footprint` (Activity
Monitor's Memory column), `resident_size` and user+system `cpu_time_us`
come from `proc_pid_rusage(RUSAGE_INFO_V4)`; `ri_*_time` are mach ticks and
are converted with the timebase.

**Signposts.** `rearc_perf.{h,cc}` (subsystem `net.rearc.engine`): category
`abi` intervals around TabCreate, TabClose, TabNavigate, ViewAttach,
ViewDetach, ViewResize, ViewSetVisible, HistoryQuery, AutocompleteStart and
every event or completion delivery (`Dispatch`); `profile` ProfileOpen (first
request to completion); `view` TabSwitchPresentation and
ResizeToPresentation (the two feedback measurements); `tab` events for each
page milestone. `<os/signpost.h>` stays out of the header: it brings mach-o
macros (`PLATFORM_IOS`) that break generated protobuf code.

## Early window (1.45)

Patch `tab/064-host-early-window`, bridge 0.47.0, feature `early_window`.
One function, `ReArcEngineSetEarlyWindowCallback(callback, context)`:

- Settable only after `ReArcEngineConfigure` and before `ReArcEngineRun`;
  otherwise `invalid_state`. Null clears it.
- `ReArcEngineRun` calls it once, synchronously, on the main thread, at the
  end of `InstallReArcAppDelegateAndMenu` (the ReArc branch of
  `ChromeBrowserMainPartsMac::PreCreateThreads`). At that point
  `ReArcApplication`, its delegate and the placeholder main menu exist.
  The named browser threads (IO and the rest), profiles and browser
  services do not, and the main message loop has not started.
- It is for AppKit only. The host may create, lay out, order front and
  display windows. It must flush the Core Animation transaction itself
  (`displayIfNeeded` + `CATransaction.flush()`), because no run-loop turn
  commits it. Main-queue blocks, timers, display links and input wait until
  Run reaches its loop, which is after ready. Every ABI call except
  `ReArcEngineABIVersion`, `ReArcEngineABIMinorVersion`, `ReArcEngineVersion`,
  `ReArcEngineBridgeVersion`, `ReArcEngineHasFeature` and `ReArcStatusName`
  behaves as before ready: `engine_not_ready`, 0, or a no-op. Windows made
  there can be registered and host tabs after ready.
- Time spent in the callback delays Chromium's startup and ready by the same
  amount, because it is the main thread. The point is to put pixels up
  sooner, not to make ready sooner.
- A run that fails before the application exists never calls it.

The hook is a function pointer in the `rearc_bridge` source set
(`SetApplicationReadyHook`, set by Configure). So the patch changes no
upstream file besides `framework.exports` and `framework.order`, which list
the new function after `_ReArcEngineGetProcesses`. The `abi` signpost
category has an `EarlyWindow` interval around the callback. Native host:
`c_abi_launch_host.mm`.

## Media capture and search engines (1.46)

Patch `tab/065-host-media-capture-search-engines`, bridge 0.48.0, features
`media_capture` and `search_engines`. No struct from an earlier ABI changed
(`engine/tests/check_abi146_imports.py` compares every 1.45 layout).
`framework.exports` and `framework.order` list the five new functions after
`_ReArcEngineSetEarlyWindowCallback`.

**Media capture** (`rearc_media_capture.cc`). Every registry tab gets a
watcher when its services attach (`ABIAttachServices`), removed before
teardown (`ABIDetachServices`). `ReArcMediaCaptureState` carries:

| Field | Source |
|---|---|
| `capturing_video`, `capturing_audio` | `MediaStreamCaptureIndicator::IsCapturingVideo/Audio`: the page holds a live camera / microphone stream. The indicator is the one behind Chrome's tab recording indicators; registry tabs reach it because their media requests go through `MediaCaptureDevicesDispatcher` (permission_prompts, 1.20). |
| `capturing_display` | `IsCapturingTab`, `IsCapturingWindow` or `IsCapturingDisplay` (getDisplayMedia). |
| `camera`, `microphone` | `MediaSessionInfo::camera_state` / `microphone_state`: what the page reports with `navigator.mediaSession.setCameraActive()` / `setMicrophoneActive()`. `REARC_CAPTURE_DEVICE_UNKNOWN` (0) when the page reports nothing, 1 on, 2 off. |
| `can_toggle_camera`, `can_toggle_microphone` | The session's actions include `kToggleCamera` / `kToggleMicrophone`: the page set "togglecamera" / "togglemicrophone" handlers. |

The two sources are independent. A page that mutes its microphone usually
keeps the stream live (`capturing_audio` true, `microphone` off); a page
that turns its camera off may stop that stream (`capturing_video` false,
`camera` off). Neither was observed against a real call in this change. One indicator observer is registered while any tab is watched, so the
indicator's `check_empty` list is empty when the dispatcher singleton
releases it at exit.

`ReArcEngineSetMediaCaptureCallback` registers the host. Events are posted on
main, one per change of any field (deduplicated per tab), dropped when the
tab is gone or its content generation changed, so none follows `tab.closed`.
Registering (or replacing) the callback first posts the current state of
every tab that is not idle; replaced registrations get nothing further.
`ReArcTabGetMediaCapture(tab, &state)` reads the current state
synchronously; a tab whose services are not attached is `invalid_state`.

**What mute means.** `ReArcTabSetCaptureMuted(tab, device, muted)` (device 0
camera, 1 microphone) is a request to the page, not a track operation. When
the requested state differs from the reported one, the engine calls
`content::MediaSession::ToggleCamera()` / `ToggleMicrophone()`, which runs the
page's own "togglecamera" / "togglemicrophone" action handler, the same path
as Chrome's video-conferencing Picture-in-Picture buttons. What happens next
is the page's decision: a conferencing page typically disables or stops its
own track and reports the new state with setMicrophoneActive/setCameraActive,
which arrives as an event. The engine never disables, mutes or stops a
`MediaStreamTrack` itself, and a page can ignore the action. Results: OK when
sent or already in the requested state; `unsupported` without a page handler;
`invalid_state` with a handler but no reported state (toggling an unknown
state could invert it); `invalid_argument` for device > 1. Pages without
media session handlers (most getUserMedia demos) cannot be muted through
this call. Stopping capture outright (`MediaStreamCaptureIndicator::
StopMediaCapturing`) and content-layer pause of device streams were
considered and left out: the first is irreversible, the second covers
display capture only.

**Search engines** (`rearc_search_abi.cc`, next to 1.26). Same rules as the
1.26 calls: live bridge profile, wait for TemplateURLService loading (at most
64 waiting calls, `busy`), deferred completion exactly once, profile release
completes waiting calls `cancelled`.

| Function | Contract |
|---|---|
| `ReArcSearchListEngines(profile, cb, ctx)` | The engines Chrome's settings offer as default (`TemplateURLService::ShowInDefaultList`: the current default, prepopulated and default-policy engines), in the service's order. Each row: `id` (TemplateURLID, stable for the profile), name, keyword, `search_url` (resolved, `%s` for the terms), `favicon_url` (empty when unknown), `is_default`, `is_prepopulated`, `can_make_default` (`CanMakeDefault`, and false on every row while `default_is_managed`). OTR IDs list their original's engines. |
| `ReArcSearchSetDefaultEngine(profile, id, completion, ctx)` | `SetUserSelectedDefaultSearchProvider` on that engine (Chromium persists it). id <= 0 `invalid_argument`; unknown id `not_found`; policy-managed default or an engine that cannot be default `invalid_state`; OTR `unsupported`. |

`ReArcSearchGetDefaultProvider` and `ReArcSearchSetDefaultProvider` (1.26)
are unchanged; the new pair selects among existing engines by ID instead of
adding one from templates.

Not run here: no native host exercises these calls yet (the hosts take over
the screen). Built and checked: the dev engine, `check_c_abi_exports.py`
(127 symbols, loaded ABI 1.46 / bridge 0.48.0) and `check_abi146_imports.py`.

## Extension side panels (1.47)

Patch `tab/066-extension-side-panels`, bridge 0.49.0, feature
`extension_side_panels`. No struct from an earlier ABI changed
(`engine/tests/check_abi147_imports.py` compares every 1.46 layout).
`framework.exports` and `framework.order` list the four new functions after
`_ReArcSearchSetDefaultEngine`.

`chrome.sidePanel` without Chrome's side panel UI. Chrome shows a panel in
its Views side panel (ExtensionSidePanelCoordinator, an ExtensionViewHost in
a Browser window); registry tabs and logical shell windows have neither, so
before 1.47 a toolbar click only returned run result 2 and `sidePanel.open`
failed with "Tab not found". Options are still Chromium's
`extensions::SidePanelService`: the manifest's `side_panel.default_path`,
`sidePanel.setOptions` globally or per tab (`tabId`), `setPanelBehavior`.
Only extensions with the `sidePanel` permission have panels.
(`rearc_extension_side_panels.cc`.)

| Function | Contract |
|---|---|
| `ReArcTabGetSidePanel(tab, extension_id, &info)` | For a page tab (popups, panels, DevTools: `unsupported`): `available` (enabled with a path, the tab's own options first, else the global ones), `contextual` (the tab has its own enabled options), `open_on_action_click`. Unknown or disabled extension, or not incognito-enabled for an OTR tab: `not_found`; no permission: OK, all false. |
| `ReArcTabOpenSidePanel(tab, extension_id, &contextual, &panel_tab)` | A new registry tab for the tab's options, created like an action popup: created event disposition 3, opener the page tab, view type `kExtensionSidePanel`, loading the resolved URL (an http(s) path as is, else the extension's resource, as ExtensionSidePanelCoordinator does) in the extension's profile (spanning extensions: the original profile). No tab identity, no history helper, `chrome.extension.getViews` and `runtime.getContexts` see a side panel. `contextual` reports the scope. Not available: `invalid_state`. The host attaches, sizes and closes it like a tab; `window.close()` in the panel closes it (tab closed, reason 1). |
| `ReArcSidePanelSetShown(panel_tab, owner_tab, shown)` | The host showed or hid the panel beside `owner_tab` (the window's page tab; 0 allowed when hiding). One `sidePanel.onOpened` / `onClosed` per change, with the owner's logical window (`ReArcTabSetExtensionWindow`), the tab for contextual panels and the panel's path. Showing an already shown panel beside another tab only updates its window. Not a panel: `invalid_argument`. |
| `ReArcEngineSetSidePanelCallback(cb, ctx)` | Host requests, posted on main, `extension_id` borrowed: kind 0 open requested, 1 close requested, 2 options changed. Null clears; a replaced registration gets nothing queued for the old one. |

**sidePanel.open / close.** In the embedded engine `side_panel_api.cc`
hands both to the bridge after Chromium's own argument checks (user gesture,
one of `tabId` / `windowId`). The bridge keeps Chromium's validation and
error strings: an unknown tab is "No tab with id", a tab outside the given
window is "The specified tab does not belong to the specified window.", no
enabled options "No active side panel for tabId" (close: "No active
tab-specific side panel for tabId", as Chrome closes only contextual panels
by tab). `windowId` is a logical window; `WINDOW_ID_CURRENT` is the focused
one (as `tabs.query` resolves `currentWindow`); a window with no tab is "No
window with id". Without a callback the call fails with "No browser window
for tabId/windowId", as Chrome does without a window. On success the event
carries the bridge `tab_id` (the window's active tab for `windowId` alone,
or 0) and `window_id`; the engine opens nothing itself.

**Options changes.** The first panel created in a profile observes its
SidePanelService. A change for a panel's scope (its tab, or global) navigates
a panel whose resolved URL changed, and posts kind 1 with `panel_tab_id` for
one that is now disabled. Every change then posts kind 2 (`tab_id` the bridge
tab for tab-specific options, 0 for global) so the host re-checks what it
shows: a tab may have gained its own panel, or lost one.

**What the host does.** Show the panel beside the page; on a tab switch ask
`ReArcTabGetSidePanel` for the new tab and keep a global panel (the same
contents), show the tab's contextual panel, or close. Toggle on run result 2.
Close a panel by releasing its tab. Chrome's panel header (the extension's
name and icon) and its resize handle are host UI.

Not run here: no native host exercises these calls (the hosts take over the
screen). Built and checked: the dev and release engines,
`check_abi147_imports.py`. A real extension's panel is a manual check
(docs/arc-recordings/2026-11-06-side-panel.md §5).

## User-Agent and client hints (chrome/003)

Not an ABI change. Patch `chrome/003-chrome-user-agent-identity` makes the
engine report itself as Google Chrome, as Arc does: the User-Agent's product
token is `Chrome/156.0.0.0` (reduced) and the `Sec-CH-UA` /
`navigator.userAgentData` brands are Chrome 156's, `Google Chrome`,
`Chromium` and the GREASE brand in Chromium's stable order. It supersedes
chrome/001's `ReArc/` token and `ReArc` brand, which made the Chrome Web
Store show "Switch to Chrome to install extensions and themes".

## Chrome's browser identity headers (chrome/007)

Not an ABI change. Patch `chrome/007-chrome-browser-identity-headers`
finishes what chrome/003 started. The Web Store's install-state controller
shows "Switch to Chrome" when the page's `IJ_values[24]` is false. The server
sets it only for a request carrying Google Chrome's `X-Browser-Copyright` and
`X-Browser-Year` headers (with a Google Chrome `Sec-CH-UA` brand), and refuses
a Google Chrome full version it does not know (156 today).
`variations::AppendBrowserIdentityHeaders`
(`components/variations/net/variations_http_headers.cc`) adds
`X-Browser-Channel: stable`, `X-Browser-Copyright` (Chromium's own line) and
`X-Browser-Year` (the build year) to the requests that may carry
`X-Client-Data`: HTTPS Google-associated URLs, not incognito. It does so from
`VariationsURLLoaderThrottle`, so navigations and browser-side requests carry
them with or without variation IDs (renderer subresources only where the
renderer has variation IDs). They are CORS-exempt like `X-Client-Data` and
removed on a redirect away from Google. `X-Browser-Validation` (a hash with
Google's API key) is not sent; the store does not check it. The full version
list (`Sec-CH-UA-Full-Version-List`, `getHighEntropyValues` `fullVersionList`)
no longer has the Google Chrome brand; the major-version brands still do.

**To undo when Google ships Chrome 156 to stable.** The store refuses 156 only
because Google hasn't released it: in testing on 2026-11-07, 143 and below
passed and 144 and above failed. Once Chrome stable reaches the engine's major
version, put the Google Chrome brand back in the full version list (the one
removal in chrome/007), so the short and full lists agree again. Check first by
sending the store a request with `Sec-CH-UA-Full-Version-List` naming Google
Chrome at the engine's version, and confirming `IJ_values[24]` comes back true.
Don't report an older version instead: that misstates the engine to every site.

## Download history at scale (1.48)

Patch `tab/067-download-history-at-scale`, bridge 0.50.0, feature
`download_history`. No struct from an earlier ABI changed
(`engine/tests/check_abi148_imports.py` compares every 1.47 layout).
`framework.exports` and `framework.order` list the seven new functions after
`_ReArcEngineSetSidePanelCallback`. Measurements and the design are in
`docs/DOWNLOADS-AT-SCALE.md`.

Chromium loads a persistent profile's download history once, lazily: on the
first download, chrome://downloads, the downloads extension API, clearing
download history, or `ReArcDownloadLoadHistory`. Before 1.48 one UI task made a
`DownloadItem` for every History DB row, and the host got one created event per
row (39,413 rows: one ~0.5 s task, then ~250 MB that stays). From 1.48, for
every host and without a policy, `DownloadHistory` (upstream file, patched):

- prepares the rows on a worker: the rows Chromium forgets (overwritten
  files) are still decided in database order, the rest are ordered newest
  first (start time, then ID);
- creates the items on the UI thread in slices of about 8 ms, newest first, so
  restored items arrive newest first; each slice's created events (kind 0) are
  drained before the next slice;
- frees the rows on a worker.

| Function | Contract |
|---|---|
| `ReArcDownloadSetHistoryPolicy(profile, live_limit)` | 0 (the default): every row becomes an item. Otherwise only the newest `live_limit` complete rows become items, plus every unfinished, cancelled or interrupted row, every row the in-progress DB still holds and every row without a URL (Chromium deletes those). Older complete rows stay in the History DB as archived rows. Read when the load starts: after it (the profile's `DownloadHistory` exists), `invalid_state`. OTR: `unsupported`. |
| `ReArcDownloadLoadHistory(profile)` | Starts the load now (trigger `kDownloadsPage`); a no-op once started. OTR: `unsupported`. |
| `ReArcEngineSetDownloadHistoryCallback(cb, ctx)` | `ReArcDownloadHistoryInfo{profile_id, rows, live_rows, archived_rows}`, posted on main once per load, after every live item's created event. `rows` is what the database held; rows Chromium dropped are in neither count. Null clears. |
| `ReArcDownloadGetHistoryInfo(profile, &info)` | The same, synchronously; before the load completed `invalid_state`. |
| `ReArcDownloadQueryArchived(profile, offset, limit, cb, ctx)` | Archived rows newest first, `limit` 1..5000, copied from the load's immutable snapshot on a worker, completion posted on main with `(status, rows, count, total)`; an offset past the end completes with count 0. Before the load completed `invalid_state`; 64 outstanding `busy`; the profile closing first completes `cancelled`. Rows are always complete; `history_id` is the History DB ID, not a `download_id`. |
| `ReArcDownloadRemoveArchived(profile, guids, count, &removed)` | Deletes archived rows from the History DB (`HistoryService::RemoveDownloads`) and the snapshot; unknown GUIDs are skipped; count 1..100000. |
| `ReArcDownloadGetTimes(profile, id, &start_us, &end_us)` | A live item's start and end, microseconds since the Unix epoch (end 0 until it finishes). The download event carries no times, and an item restored from history keeps its own. |

**What archived rows lose.** They have no `DownloadItem`, so nothing in
Chromium sees them: chrome://downloads, `chrome.downloads.search`, the
download bubble and the in-progress reconciliation only know live items.
Resumption and danger warnings are unaffected: every row that can resume or
warn (anything not complete) stays live. Open and reveal need no item (the
host uses Launch Services and Finder on the path); removal is
`ReArcDownloadRemoveArchived`. Clearing download history
(`ChromeBrowsingDataRemoverDelegate`, patched) deletes the archived rows
that match its time range and URL filter, after the load if it is still
running. Chromium's own clean-ups that run at item creation (an overwritten
file's older rows, expired interrupted rows) only ever applied to rows that
are not archived.

Native host: none takes this path (the downloads host would need a seeded
History DB). Exercised by a scratch host on the release engine at 0, 2,173 and
39,413 rows and by the shell's `downloads.engine_first_download` bench
scenario; built and checked: the dev and release engines,
`check_abi148_imports.py`, `check_c_abi_exports.py`.

### Follow-up (bridge 0.51.0, patch `tab/068-download-history-follow-up`)

No ABI addition: the 1.48 layouts and functions are unchanged. Behaviour:

- **Archived rows reach Chromium's own surfaces on demand.** Before
  chrome://downloads (`DownloadsUI::CreatePageHandler`) or any downloads
  extension function except `downloads.download` uses the history, every
  archived row becomes an item: `DownloadHistory::RestoreArchivedRows` reads the
  rows again from the History DB (archived rows keep a summary only), keeps
  those still archived, and creates them newest first in the same ~8 ms slices,
  each with a created event (kind 0). The extension function waits
  (`RespondLater`) and then runs on the full history, so `search`, `erase`,
  `open`/`show` by an old ID and the documented `startedAfter` paging see every
  row; if the history goes away first it fails as a queued function does when
  the manager goes down. The live limit is lifted for the rest of the session.
  The history callback is posted again afterwards, with `archived_rows` 0.
  Archived rows the host removes while a restore runs are not restored; one
  already made an item is removed as an item.
  chrome://downloads' `DownloadsListTracker::InsertItem` now walks only as
  far as the rows the page holds: its full `std::distance` per created item
  made a restore under an open page quadratic (~9 s at 39,413 rows).
- **Callbacks are drained under a time budget** (see the top of this file).
- **The Dock tile** (`DownloadStatusUpdater`, `DockIcon`) is drawn one 5 Hz
  period after the change that needs it, coalesced, instead of inside the
  download's first task, and its count no longer builds an `NSNumberFormatter`
  per draw.
- **`CancelAllEphemeralWarnings`** (when the history load completes) skips
  complete items, for which `Cancel` is a no-op, before building a
  `DownloadItemModel` for each.

Measurements and the decision are in `docs/DOWNLOADS-AT-SCALE.md`
("Follow-up").

## Download event batches (1.49)

Patch `tab/069-download-event-batches`, bridge 0.52.0, feature
`download_event_batches`. No struct from an earlier ABI changed
(`engine/tests/check_abi149_imports.py` compares every 1.48 layout).
`framework.exports` and `framework.order` list the new function after
`_ReArcEngineSetDownloadCallback`. Measurements are in
`docs/DOWNLOADS-AT-SCALE.md` ("Second follow-up").

| Function | Contract |
|---|---|
| `ReArcEngineSetDownloadBatchCallback(cb, ctx)` | `cb(ctx, events, times, count)`. While set, every download event goes to it instead of the 1.17 per-event callback, in the same order relative to each other and to every other host callback. Events queued back to back (a history slice's created events) arrive in one call, at most 1024 per call; others usually alone. `times[i]` is `events[i]`'s item start and end (`ReArcDownloadTimes`, microseconds since the Unix epoch, end 0 until it finishes), so a restored item's dates need no `ReArcDownloadGetTimes`. Both arrays are borrowed for the call. Null returns to per-event delivery; a batch already queued then goes to the per-event callback one event at a time. |

A host that never sets it sees no change: one task per event, as before.

Behaviour changes for every host (bridge 0.52.0):

- **History slices yield to the run loop.** `DownloadHistory` creates items
  in slices of about 4 ms (8 ms before) and posts the next slice as a task
  4 ms later instead of at once, for the initial load and for a restore. The
  slice's created events are delivered in between, and the host's run loop
  then runs out of work and commits a frame before the next slice. Before, the
  next slice was immediate (or, with a 1 ms delay, came due while the events
  were delivered), and slices, events and the host's layout ran as one stall.
- **Archived pages yield too.** A `ReArcDownloadQueryArchived` completion is
  posted 1 ms after the worker's copy returns, so a host that asks for the
  next page from a page's callback no longer gets every page in one burst.
- **An over-budget drain** continues in a task 1 ms later (above).

## Extension tab groups (1.50)

Patch `tab/070-extension-tab-groups`, bridge 0.53.0, feature
`extension_tab_groups`. No new function or struct; no earlier struct changed
(`engine/tests/check_abi150_imports.py` compares every 1.49 layout). It makes
Claude in Chrome work: the extension anchors each session in a tab group
(`tabs.group` on the side panel's tab, then `tabGroups.update` with its title
and colour) and acts on the group's tabs through `chrome.debugger`.

Groups live in the bridge, beside the 1.36 logical windows, for tabs the host
has mapped with `ReArcTabSetExtensionWindow`. The host keeps no group model:
it shows grouped tabs as ordinary tabs, because Arc shows no Chrome tab groups.

| API | Behaviour |
|---|---|
| `tabs.group` | New group (in `createProperties.windowId`, or the first tab's window) or an existing `groupId`. Every tab must already be in that window: the host owns placement, so the engine never moves a tab. A new group takes Chromium's first unused colour (grey, blue, red, …) and no title. |
| `tabs.ungroup` | Removes each tab from its group. |
| `tabGroups.get`, `query`, `update` | As Chromium, `shared` always false. `query` filters by collapsed, colour, title pattern, window (−2 current) and shared. `collapsed` is stored and reported only. |
| `tabGroups.move` | The group stays put: a move within its window succeeds unchanged, to another window is an error. |
| `tabs` `groupId`, `tabs.query({groupId})` | The tab's group or −1. |

A tab that the host moves to another window, unmaps (window 0) or closes
leaves its group; the last tab out removes the group (`tabGroups.onRemoved`).
Releasing a profile drops its groups without events. Group IDs are
session-local, from 1.

Events now reach extensions for mapped tabs (they had none before):
`tabGroups.onCreated`, `onUpdated` (only when something changed), `onRemoved`;
`tabs.onUpdated` with `groupId`, and, after `TabsEventRouter::TabEntry`,
`status` on commit and on the first stop after it, `url`, `title` and
`mutedInfo`; `tabs.onCreated` when the host first maps a tab;
`tabs.onActivated` when a mapped tab becomes its window's active tab;
`tabs.onRemoved` (`isWindowClosing` false) when a mapped tab closes. Each
listener's tab object is built at dispatch from the tab's ID, with Chromium's
permission scrubbing, so a lazy listener that wakes after the tab closed gets
nothing.

Window changes in the same patch:

- `windows.update` with `focused: true` asks the host to activate the
  window's active tab (an extension tab request of kind 3, which brings its
  space forward) and answers with the window once the host replies. Already
  focused, `focused: false` and `drawAttention` answer at once. Geometry and
  any state but normal are errors.
- `windows.create` accepts `type: "popup"` and ignores `left`, `top`,
  `width` and `height`: the host opens it as it opens every extension window
  (a Little Arc). Claude's sign-in and permission prompts use it.
- `chrome://newtab` (and `chrome://new-tab-page`) in `tabs.create` and
  `windows.create` becomes the host's blank tab (`about:blank`); the URL is
  not admitted otherwise.

Checked with Claude in Chrome 1.0.105 (Web Store ID, loaded unpacked with its
own key) in a throwaway profile over DevTools, without signing in: the
extension's own `createGroup` and `isolateTab` (the anchor), `tabs_context`,
`tabs_create`, the MCP group in a new window, and its `computer` tool's
screenshot, click, scroll and key all succeed; `navigate` and the permission
manager need a signed-in account. `docs/QA-2026-11-07.md` has the manual check.

## Page theme colour (1.51)

Patch `tab/071-page-theme-color`, bridge 0.54.0, feature `page_theme_color`.
No earlier struct changed (`engine/tests/check_abi151_imports.py` compares
every 1.50 layout). `framework.exports` and `framework.order` list the two new
functions after `_ReArcTabGetZoomFactor`. For the host's toolbar, which Arc
draws in the page's colour.

| Function | Contract |
|---|---|
| `ReArcEngineSetThemeColorCallback(cb, ctx)` | `cb(ctx, const ReArcThemeColorEvent*)`, borrowed for the call: `document` (`ReArcDocumentIdentity`), `has_color`, `argb` (0xAARRGGBB, `WebContents::GetThemeColor`: the last matching `<meta name="theme-color">`, media queries applied). Posted once when the tab's services attach, on each change (`DidChangeThemeColor`), and once per new primary document even when unchanged, so the host can key it by document; never twice in a row with the same value for one document. A tag a script adds later arrives as a change. Null disables delivery. |
| `ReArcTabGetThemeColor(tab, &has_color, &argb)` | The current value. Null outputs are invalid_argument; outputs are zeroed on error. |
| `ReArcTabCaptureSnapshot(tab, 2, …)` | Scope 2: the visible viewport's top 4 CSS px at its scroll offset (`cssVisualViewport.pageX/pageY`), so a sticky header is what a capture after a scroll sees. Same path, limits, busy rule and cancellation as scope 0; the PNG is a few rows (800 pt at 2x: 1600×8, about 0.5 KB). Scope 3 and up are invalid_argument. |

The shell uses the theme colour when there is one, else samples scope 2
rarely: on a new document, at the load's end, after a scroll settles and when
the page comes on screen, only while it is attached in a visible window (a
hidden page's capture would wait for a frame), decoding off the main thread
(`shell/Sources/ReArc/Engine/PageColorTracking.swift`).

`engine/tests/run_c_abi.py theme` (`c_abi_theme_host.mm`) checks the declared
colour, none on a new document without one, a colour added by script, that
events come only on change, the getter, scope 3's rejection and that scope 2
of a page with a `#1f2023` top bar is that colour. Its window is far off
screen, ordered back and never key.

### Credits admission (ABI 1.52)

`webui_credits` admits the exact `chrome://credits` host through the shared
`ABIIsTrustedWebUI` predicate. The pinned macOS `AboutUI` only registers
`ThemeSource` and `AboutUIHTMLSource`; it installs no message or Mojo handlers
and needs no Browser or TabInterface. Credits HTML, CSS and JavaScript are
compiled resources; the dev and release engine builds enable
`generate_about_credits=true` so Chromium generates the real licences instead
of its sample placeholder. Licence toggles and homepage anchors are ordinary DOM;
the Print link invokes `window.print()` through the existing print delegate.
Privileged evaluation and capture remain denied.

### Approved extension imports (ABI 1.53)

Patch `tab/073-bulk-extension-install`, bridge 0.56.0, advertises
`extension_bulk_install`. `ReArcProfileInstallExtensions(profile, ids, count,
callback, context)` copies and validates up to 512 unique Web Store IDs.
`ReArcProfileLoadUnpackedExtension(profile, absolute_path, callback, context)`
loads one developer extension through `UnpackedInstaller`. Both require a
registered persistent profile and the host's prior import consent. No external
extension preferences or JSON installation mechanism is used.

Callbacks are deferred to the host drain, once per input, in completion order:
`(context, id, result, reason, completed, total)`. Strings are borrowed through
the callback; `completed == total` releases the host's context. Non-OK synchronous
returns produce no callbacks. Results: 0 installed, 1 already installed,
2 not in store (metadata HTTP 404/410), 3 failed with reason, 4 unavailable
(retired manifest, policy, blocklist or unmet requirements). Network failures
remain failures, never evidence that a listing has been removed.

Only one operation per profile is admitted. Store batches run up to three
installers concurrently, skip already registered IDs, fetch metadata, reject
MV2, and check Chromium's blocklist and management policy before downloading.
`WebstoreStandaloneInstaller` creates Chromium's strict manifest-matching
no-prompt `InstallApproval`, then invokes `WebstoreInstaller` with its normal
CRX signature and policy checks. The shell substitutes import consent only
for the per-extension prompt and suppresses post-install bubbles. Explicit
profile close and engine shutdown return BUSY while work is active.

Small upstream seams preserve HTTP status on metadata failure and propagate
store download 204/404/410 through an appended installer result. Existing
metadata consumers retain their default behavior; enum values are appended.
Transport errors remain distinct from removed or unavailable listings.
The shell dynamically resolves both optional exports after checking ABI minor,
feature and profile support. Older engines keep store links in import details.

Run `python3 engine/tests/run_bulk_extensions.py` after building. This harness
opens no windows and uses temporary profiles, a mock keychain and loopback
metadata, exercising unpacked success/failure, already-installed, removed
listings, HTTP failure, retired manifests, deferred completion, concurrency,
and close/shutdown guards. It never contacts the real Chrome Web Store.

### Dockable DevTools (ABI 1.54)

Patch `tab/074-dockable-hosted-devtools`, bridge 0.57.0, advertises
`devtools_docking`. `ReArcEngineSetDevToolsDockCallback(callback, context)`
opts in: frontends opened while it is set carry `can_dock=true`, as
`DevToolsWindow::GetDevToolsURL` adds it, so the frontend's menu offers Dock
side (right, bottom, left, undocked), the device toolbar (⌘⇧M) and
toggle-dock (⌘⇧D). Without a callback the URL and behaviour stay 1.40's.

The frontend persists the side itself (`currentDockState` in the profile's
DevTools preferences) and calls `setIsDocked` on load and on every change,
then `setInspectedPageBounds`. Each posts a `ReArcDevToolsDockEvent`:
`frontend_tab_id`, `target_tab_id`, `in_tab_tab_id`, `dock_side` (0 undocked,
1 right, 2 bottom, 3 left, read with `DevToolsSettings::GetDockSide`),
`has_bounds` and the bounds in DIP. Docked, `in_tab_tab_id` is the frontend:
the host lays it over the whole content area and the inspected page above it
at the bounds (Chrome's `ApplyDevToolsContentsResizingStrategy`). Undocked,
the frontend goes in its own window and `in_tab_tab_id` is the device-mode
toolbox, laid out the same way (0 until the frontend opens it). Before the
first event the frontend has not chosen a side; Chrome does not show it yet.

The toolbox (`device_mode_emulation_frame.html` with the frontend's query) is
recognised in `WebContentsCreated`, before its WebUI bindings exist, so they
are hosted and never attached. It is adopted as a registry tab (created event
with opener = frontend, popup disposition), kept rendering with a capturer
count as `DevToolsWindow` does, locked to its URL like the frontend, and
force-closed with it. Only the frontend's own toolbox is adopted; a reloaded
frontend's new toolbox replaces (force-closes) the old one, as in Chrome.

The toolbox's renderer forks its own `devtools://` navigation, the first one
included, to the browser through `OpenURLFromTab`. Patch
`tab/076-devtools-toolbox-navigation` loads it in place, as Chrome's
`DevToolsToolboxDelegate` does. Before 076 it was dropped: the toolbox stayed
blank, the undocked device toolbar had nowhere to show, and the page kept its
docked bounds. A frontend's own `OpenURLFromTab` still opens nothing.

Run `python3 engine/tests/run_devtools_docking.py` after building. The views
sit in a transparent borderless window ordered in far off screen without
activation, so no input is posted and focus never moves. It proves the
non-dockable default, `can_dock`, the registered device-toolbar and
toggle-dock actions with their shortcuts, right/left/bottom/undocked
round-trips with bounds, responsive emulation (`screen.width` 375) docked
and undocked, the toolbox committing its page, the device-mode action
undocked (the page fills the toolbox with it off and sits below the device
toolbar with it on), toolbox replacement after a frontend reload, toggle-dock
returning to the last side, the toolbox closing with its frontend, and, in a
second run on the same profile, the persisted side. Mobile device emulation
is avoided there only because a debug-only Blink DCHECK
(`scrollable_area.cc`, `BlinkControlsOverlayVisibility`) fires on Mac when a
mobile-emulated page resizes; release builds have DCHECKs off.

The shell (dockable engines only) drops its own docked pane, "Dock to Page"
strip and dock menu items: Chrome's ⋮ › Dock side drives placement, and the
frontend's splitter resizes the page. Older engines keep the 1.40 shell pane.

### Extension tabs in the background (ABI 1.55)

Patch `tab/077-extension-background-tabs`, bridge 0.58.0, advertises
`extension_background_tabs`. `ReArcExtensionTabRequestRespondInBackground(request,
tab)` answers a tab request (1.36) as `ReArcExtensionTabRequestRespond` does,
except that a request with `active` set may be answered with a tab that is not
its logical window's active one. The engine loads the extension's URL there and
the extension's `tabs.Tab` reports `active: false`. Every other check stays:
the tab must be open, mapped, in the request's profile and in the requested
window. The shell uses it only for extensions an import is installing, so
their welcome pages collect as unselected Today tabs instead of taking the
window. Chrome installs synced extensions silently (`PendingExtensionManager::
AddFromSync`, no prompt or bubble) but has no such rule for the tabs they open
from `runtime.onInstalled`: those open, and take the window, as any `tabs.create`.
