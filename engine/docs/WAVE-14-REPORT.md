# Wave 14 implementation report

All five concerns are implemented and validated. No shell edits and no push.
Chromium base `6c6160cfc1`; pin `d331de35ca` = 156.0.8078.74. This implementation
commits only to the nested Chromium checkout. The outer shell branch
advanced independently from f86d288 to 7d2c0fd during this work; no outer or shell
commit was made by this implementation agent.

| Concern | Chromium commit | Patch | Build | Gates |
|---|---|---|---|---|
| Real named/OTR profiles | `4222b92728` | `tab/024-profile-lifecycle-isolation.patch` | p37 final green | Native hosts, G1–G5, 4 shutdown processes green |
| Evaluation document identity | `b97593bb6a` | `tab/025-evaluation-document-identity.patch` | p38 green | Native hosts + identity, G1–G5, 4 shutdown processes green |
| Chromium page zoom | `86b4181b82` | `tab/026-page-zoom-controller.patch` | p39 green | Native hosts + zoom/restart, G1–G5, 4 shutdown processes green |
| Isolated page messages | `d733c456f1` | `tab/027-isolated-world-page-messages.patch` | p40 final green | Full native hosts, G1–G5, 4 shutdown processes green |
| Build-time Safe Storage/bundle branding | `7f633822da` | `chrome/002-safe-storage-build-branding.patch` | p41 green | All 10 native hosts/12 runs, G1–G5, 4 shutdown processes green |

Current ABI 1.10, bridge 0.12.0. Existing ABI 1.5 layouts and signatures are
preserved; C11 size/alignment comparisons and Swift module/callback imports
pass in abi-w14-import.log. Configure still takes major 1. New features:
profiles, profile_off_the_record, script_evaluation_identity, page_zoom,
isolated_page_messages, rearc_safe_storage_branding.

Profiles use ProfileManager's asynchronous initialized callback and Chromium
named OTR contexts. Persistent keys use hex directory names to keep A/a distinct
on case-insensitive macOS filesystems. Close uses the existing sequential
close controller, retains parents until actual OTR BrowserContext destruction,
and guards the interval between session removal and WebContents destruction.
Default-profile close is refused; parent close with children is busy. Veto
restores availability without restoring already-closed tabs. Pending opens
cancel exactly once during engine shutdown. Additional profile-added hooks
cannot reacquire cancelled keepalives during shutdown.

The profile host passes same-origin cookie and localStorage isolation between
A, a, and two independent OTR children; private state is invisible to the other
contexts. Named state survives close/reopen with a new ID and a new process.
An OTR-only disk marker is absent from all persistent profile files. The final
profile runner first reads back `["private=secret","PRIVATE-ONLY-W14"]` inside
the OTR context, then queries every persisted cookie SQLite store; it finds zero
rows named `private`, the cookie set only in OTR. It also
checks isolated boost plans, favicon cache boundaries, adopted popup profile
identity, beforeunload veto recovery, live leases, pending evaluation
cancellation, reentrant teardown rejection and pending-open cancellation.

Evaluation identity is captured at acceptance and returned on success/errors/
cancellation. Cross-document commits, reload and BFCache return advance a
per-tab document generation; same-document commits retain it and update the
committed navigation ID. The host can query current identity directly. The
original evaluation callback remains intact. file/WebUI evaluation stays
refused: trusted navigation admission does not grant execution authority to
the internal DevTools client. PiP remains out of scope.

Zoom uses upstream ZoomController/HostZoomMap in default mode, with no Chrome
bubble. Same-host tabs in one profile share saved browser zoom; another profile
is independent. The zoom host checks navigation to an unsaved host and return,
and saved zoom survives a second process. This is not CSS/pinch zoom.

The message channel uses exact isolated-world bindings and a frozen wrapper
whose private raw sender is removed from global scope. Bounds apply before CDP
serialization and again in the browser: <=64 KiB JSON, <=60 attempts per fixed
second per tab across worlds, <=60 queued deliveries per tab. Callbacks carry
profile/tab/content/document/navigation identity and boost ID. Main-world page
code receives no binding. Native tests pass installed boost/editor messages,
malformed/oversized rejection, 57/500 flood delivery, disablement, reload and
navigation/close cancellation and aborted-navigation recovery.

## Exact Swift adoption

Shell adoption is intentionally not applied in this engine-only wave.

1. Rebuild/copy the new public headers, module map and complete framework/helper
   dependency closure. Keep ReArcEngineConfigure(1,...). Gate each addition with
   ReArcEngineHasFeature; ReArcEngineABIMinorVersion() is 10 and bridge is 0.12.0. Never
   require a new major or append fields to the old
   callback structs. Existing ABI 1.5 shell call sites keep working.
2. Persist a stable ASCII storage key per Space (a lowercased UUID is suitable).
   Call ReArcProfileOpen(key,callback,context) and map its returned session-local
   ID to the Space. Never persist engine IDs. Use the default profile for the
   legacy/default Space if desired. The callback is
   `(context,status,profile_id,off_the_record)` and is deferred, even for an
   already-open profile; same-key opens coalesce. Rejected calls invoke no callback.
3. For a private Space call ReArcProfileCreateOffTheRecord(parentID,...); every
   accepted call yields a unique in-memory context. Pass its ID to TabCreate.
   Tabs keep their BrowserContext when moved between shell Spaces. Changing a
   Space's profile requires recreating affected tabs, not relabeling their IDs.
4. ReArcProfileClose(profileID,force,completion,context) closes its tabs in order.
   Close OTR children first. Keep native view leases/contexts alive until their
   invalidation and close callbacks; remove already-closed tabs even if a later
   tab vetoes. OK/cancelled=true resumes that profile. Reopen after successful
   close to obtain a new ID. Engine shutdown owns the startup profile lifetime.
5. Replace editor/picker result calls with ReArcTabEvaluateScript2. Its callback
   receives borrowed ReArcScriptResult: copy status, document and JSON/error
   strings on main. Retain a per-request context until its one accepted
   completion; on synchronous rejection release it immediately. Both evaluation
   APIs share one pending slot per tab. Use world=0/boostID=null for editor,
   world=0/lowercased boost UUID for that package, world=1/null for intentional
   main-world evaluation. Keep existing timeout/cancellation handling.
6. Before applying a retained result call ReArcTabGetDocumentIdentity. Compare
   profile_id, tab_id, content_generation, document_generation and, when the
   operation is navigation-specific, navigation_id. Discard on mismatch or query
   failure. Do not count navigation events to manufacture an identity. A navigation
   attempt can cancel an evaluation without advancing document generation.
7. Add a static ReArcZoomCallback with ReArcEngineSetZoomCallback. Copy its
   document/factor and update the addressed tab. Query ReArcTabGetZoomFactor
   when selecting a tab; set percent/100 with ReArcTabSetZoomFactor. Bounds are
   0.25–5.0 and must be finite. Expect events for sibling same-host tabs in the
   same profile. Let Chromium persist its per-host map.
8. Register a static ReArcPageMessageCallback with
   ReArcEngineSetPageMessageCallback before installing/evaluating boost/editor
   code. Copy message.document, boost_id and json before returning; decode JSON
   and validate expected message kinds. In the editor world install DOM/input
   event handlers that call e.g.
   `rearcPostMessage(JSON.stringify({kind:'picker.changed',selection}))`.
   Coalesce frequent updates. Remove the polling timer and use explicit evaluation
   only for initial/explicit snapshots. Main-world scripts cannot call this
   channel. Messages are data, not trusted shell commands; the channel can drop
   excess/stale messages and has no host acknowledgement.
9. Apply PACKAGING-MAC.md in the packaging pipeline: select the actual Apple
   MAC_TEAM_ID in the release BRANDING input and set the outer app's
   CFBundleIdentifier to com.rearc.browser (or rebuild all engine assumptions
   with the distributor's chosen root). Helpers use `<app>.helper`,
   `<app>.helper.renderer`, and `<app>.framework.AlertNotificationService` for
   both alert variants; framework uses `<app>.framework`. Keep generated role
   entitlements, nested physical names/paths and the full dependency closure.
   Sign the final contents with the stable production identity. Supply a
   dedicated ReArc user-data directory before Run. The default keychain names
   are now ReArc Safe Storage/ReArc; old Chromium-encrypted profiles need an
   explicit migration plan. No production authorization, release signing or
   notarization claim follows from these development gates.

The final C11 layout/Swift import audit passes, all 48 symbols resolve through
Chromium Framework, and the loaded binary reports ABI 1.10, bridge 0.12.0,
Chromium 156.0.8078.74. All five original hosts also run green when compiled
against the exact ABI 1.5 headers from 6c6160cfc1 (runtime-abi-*-legacy15.log).

Replay is complete in replay-w14.log: **28/28 reverse and forward patches**.
The reverse tree is ffe41d3ec78c520fbe20a43802869358d3e18961, exactly upstream
pin d331de35ca8ab1358c7a17e4bd41627d55eaef51. The forward tree is
b989e6bf6356725bd9e9cf0d74b289d509c0f443, exactly final Chromium HEAD
7f633822daaf11210b60dfcc6add3ddfd7c6be93. Replay uses a disposable index;
the real Chromium index/worktree remains clean. Every commit has the requested
ReArc Overlay author and Codex co-author trailer; series includes all five new
patches. No build remains active.

## Final validation evidence

- `gates-tab024.log`, `gates-tab025.log`, `gates-tab026.log`,
  `gates-tab027.log`, `gates-chrome002.log`: build green before every test,
  native hosts plus G1–G5 with fresh profiles/default sandbox, and 4 shutdown
  processes/16 tabs per concern. Final suite has 10 distinct native hosts and
  12 process runs (profile and zoom persistence each use two processes).
- `runtime-abi-profiles-w14-positive.log`,
  `runtime-abi-profiles-reopen-w14-positive.log` and their driver: positive OTR
  cookie/storage readback, cross-context invisibility, named restart persistence,
  OTR teardown/recreation, zero disk marker/private-cookie rows, lifecycle/veto,
  cache/boost identity and popup checks. Deterministic native fixtures use Chromium's
  test mock keychain only in disposable profiles, never a sandbox bypass.
- `abi-w14-import.log`, `nm-w14.log`, `nm-w14-driver.log` and
  `runtime-abi-legacy15-driver.log`: preserved C layouts/alignment, Swift module
  and callback imports, 48 framework-resolved exports, loaded version queries,
  and all five original native hosts compiled against unmodified ABI 1.5 headers.
- `runtime-abi-stress-w14-final.log`: **30/30 fresh processes, 120 attached
  tabs**, alternating normal/force shutdown and 0/25/250/1500 ms delays, all pass.
- `runtime-abi-stress-w14-load.log`: **30 hidden + 30 attached first loads**,
  zero watchdog timeouts and zero placeholder about:blank commits. No latency
  improvement relative to an earlier wave is claimed.
- `runtime-abi-stress-w14-blocked.log`: **2/2 processes, 8 tabs**, normal and
  force shutdown pass while Safe Storage lookup is permanently blocked. The
  interposer verifies the actual query service/account are ReArc Safe Storage/
  ReArc without reading or modifying a real key. Both shutdown completions
  finish within 300 ms after the request.
- `branding-w14.log`: generated Safe Storage constants, compiled implementation,
  and app/framework/eight helper bundle identifiers match the selected branding.
- `final-validation-w14.log`: extended validation pipeline PASS;
  `replay-w14.log`: complete 28-patch reverse/forward replay PASS.

All builds use build.sh's macOS arm64 debug/component configuration and stock
sandbox, framework/executable filenames. No optimized/non-component packaging,
production certificate/ACL, notarization or clean-machine distribution test is
claimed. Stable production signing and Keychain authorization remain packaging
responsibilities; no encryption bypass, insecure fallback or mock keychain is
introduced in production code.
