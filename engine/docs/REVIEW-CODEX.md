# Codex adversarial engine review

Review date: 2026-11-01. Scope: every file originally under `engine/`;
`docs/RECON.md` and `docs/SIDEBAR-SPEC.md` read first as supplied context.
No shell/docs/analysis/vendor files were changed, no Arc executable was run,
and no Arc code, assets or strings were copied. No Chromium checkout was
fetched. Original findings below concern ReArc's proposed implementation.

**Verdict:** the fixed architecture is feasible in principle, but the previous
baseline substantially understated its application lifecycle and browser-service
integration work. Nothing in this repository yet demonstrates a working engine:
the inventory is two design documents, a pin, artifact `.gitignore`, overlay
instructions/empty series and two explicitly untested scripts. Treat the
main-loop/content-host spike as
a prerequisite to feature implementation, not a minor follow-up patch.

## Evidence and limits

Verified selected individual upstream files remotely at **the exact pin**
[`156.0.8078.74`][tag], resolved to commit
`d331de35ca8ab1358c7a17e4bd41627d55eaef51`; `chrome/VERSION` agrees. Source
inspection is stronger than approximate M156 recollection, but does not prove
compilation, service dependency completeness, SwiftUI compatibility or runtime
behavior in ReArc. Neither build/fetch workflow was executed; `bash -n` passes
both scripts. The artifact `.gitignore` covers the intended depot_tools and
Chromium trees; it adds no engine implementation or build proof.

Source map (all links are to the pin, not moving main):

- Application: [main delegate][main-delegate], [mac main parts][mac-parts],
  [BrowserCrApplication][application], [AppController][app-controller],
  [generic Chrome main parts][main-parts], [content browser runner][runner],
  [BrowserMainLoop][loop], [Apple message pump][pump].
- Tab/services: [TabStripModel][strip], [desktop TabModel][tab-model],
  [TabInterface][tab-interface], [TabFeatures][tab-features],
  [legacy TabHelpers][tab-helpers], [Chrome content browser client][client],
  [WebContents][contents], [delegate][delegate], [observer][observer],
  [discard lifecycle][discard], [favicon helper][favicon],
  [security utility][security], [per-content MediaSession][media],
  [PiP manager][pip].
- View/compositor: [WebContentsViewMac][mac-view],
  [RenderWidgetHostViewMac][rwhv], [BrowserCompositorMac][compositor],
  [AcceleratedWidgetMac][widget], [render-widget NSView bridge][view-bridge].
- Build: [Chrome GN rules][build], [helper definitions][helpers],
  [framework exports][exports].

## Findings: application lifecycle and architecture

### R1 — Blocking: P-APP-001 is not “early ChromeMain without the delegate”

**Claim:** shell app startup calls ReArcEngineStart, performs content main,
creates no Chrome Browser window and does not run Chromium's app delegate.

**Constraint:** `ChromeMainDelegate::PreBrowserMain()` registers
BrowserCrApplication. `RegisterBrowserCrApp()` and sharedApplication CHECK
the singleton class/pump suitability. `ChromeBrowserMainPartsMac::PreCreateThreads`
CHECKs that NSApp.delegate is nil, obtains AppController.sharedController,
then builds the Chrome menu. sharedController sets and CHECKs delegate identity.
A SwiftUI-created plain NSApplication/delegate cannot simply coexist with this
path. Removing AppController also removes keepalive, launch/menu/open-event
and termination behavior, not merely visible chrome. BrowserCrApplication's
terminate/cancel paths and mac main-parts teardown can call sharedController
again and reinstall it.

**Correction applied:** ENGINE now requires a coordinated singleton/delegate
and identifies the exact seams; no promise of an ordinary nonblocking startup
call. [P-APP-001](patches/P-APP-001.md) covers construction order, missing
application glue and shutdown. It does not assume shell launch has been audited.

### R2 — Blocking: “host-driven pump” is an unimplemented mechanism

**Claim:** a small mac-startup patch lets Chromium be pumped by the app runloop.

**Constraint:** `MessagePumpCFRunLoopBase::Run` installs its delegate for the
lifetime of Run. `MessagePumpNSApplication::DoRun` enters NSApp.run or runs
an event loop if NSApp is already running. Existing CFRunLoop sources by
themselves do not establish an externally attached scheduler; native nesting,
autorelease pools, application-task allowances and quit behavior matter. The
Attach/Detach implementation in this source is iOS-gated, not a public macOS
embedding solution. Timer polling is not equivalent to scheduler integration.

**Correction applied:** ENGINE removes the “small host-driven mode” certainty.
P-APP's reference spike keeps the normal Chromium RunLoop on the stack while
shell windows host SwiftUI. Whether to ship that bootstrap or build a true
external-pump adapter remains **Q1**, not an architecture reversal.

### R3 — Blocking: browser UI on a separate worker is not a fallback

**Claim:** dedicated engine UI thread with its own loop; only embedding crosses
to main, supposedly simpler.

**Constraint:** AppKit view/window operations are main-thread-bound, and Chromium
mac browser/UI initialization, native event handling, screen/accessibility and
content-view code assume that same UI/main thread. A sequence of marshalled
NSView operations does not repair those assumptions.

**Correction applied:** removed this option; UI and native operations share main.

### R4 — High: runner initialization and startup suppression are not isolation

**Claim:** run content main, suppress startup windows, return to the host.

**Constraint:** BrowserMain owns BrowserMainRunner Initialize → Run → Shutdown;
return from normal Run means teardown. Keeping only BrowserMainRunner is not
the whole ContentMain/ChromeMain lifetime. In ChromeBrowserMainParts,
`browser_creator_->Start` success also creates GetMainRunLoopInstance and
installs BrowserProcess's quit closure. Removing Start without retaining that
work causes ShouldInterceptMainMessageLoopRun to skip Run. First-run/profile
selection, relaunch URLs, already-running process events and later session
restore paths are not all disabled by one preference.

**Correction applied:** ENGINE and P-APP specify preserved profile/services,
runloop/quit ownership and teardown; startup-only flags are no longer described
as complete UI suppression. Exact quit/service behavior is a spike exit gate.

### R5 — High: static bundle structure is not proof of hidden implementation

**Claim:** Arc's bundle proves this precise framework embedding/runloop strategy,
IPC, small patch size, CEF comparison and cheap Chromium bumps.

**Constraint:** bundle layout and native-shell types support a two-layer product;
they do not establish the runtime boundary or maintenance cost. Upstream
Chromium itself already builds a framework. Apéritif helpers also appear in
this pin's upstream helper definitions, so their presence alone is not Arc
custom engine behavior. Unverified CEF release/API comparisons do not establish
ReArc's integration cost and are unnecessary given the fixed architecture.

**Correction applied:** ENGINE treats the architecture as a ReArc decision,
removes unsupported “production proof”/alternative-distribution claims, and
makes the cheap-bump target measurable. Context recon files were left untouched.

## Findings: tabs, native embedding and browser features

### R6 — Blocking: P-TAB-001 understates the modern desktop tab dependencies

**Claim:** a browser-less WebContents model needs mostly additive code and a few
one-line hooks; implied tab-strip patch area.

**Constraint:** TabStripModel remains a backend in `chrome/browser/ui/tabs/`.
Desktop `tabs::TabModel` owns WebContents and implements
`components/tabs/public/tab_interface.h`; it references TabStripModel and
TabFeatures. `TabFeatures::Init` CHECKs BrowserWindowInterface, with a large
browser-window feature surface. Removing visible browser chrome does not
itself require replacing TabStripModel; choosing standalone WebContents does
mean explicitly replacing the service glue. A top-level `tabs/` or visual
strip-only patch is the wrong map. Legacy TabHelpers lives at
`chrome/browser/ui/tab_helpers.cc` and warns against desktop use.

**Correction applied:** ENGINE names the real components; P-TAB specifies the
existing browser-less route without pretending these backend objects are freely
reusable or require visual-strip edits. No production null-check/test-only
TabFeatures bypass is proposed. Service reuse limits remain Q2.

### R7 — High: observation alone does not produce a usable browser tab

**Claim:** WebContentsObserver title/favicon/load/crash events essentially cover
the bridge's tab work.

**Constraint:** WebContentsDelegate controls popup adoption, OpenURLFromTab,
activation, close/unload and other browser behaviors. Chrome's
GetWebContentsViewDelegate also supplies native focus/context-menu behavior
through a separate view-delegate factory. Required services span JavaScript
dialogs, security/interstitials, permissions, file chooser, downloads and
external protocols. Saying these product UIs are “out of scope” does not
complete their engine callbacks or make Chrome's browser-bound helpers usable.

**Correction applied:** ENGINE/P-TAB identify both delegate seams and require an
audited helper subset plus explicit safe rejection/cancellation for unsupported
operations. The full native UI protocol remains Q4. Browser feature parity is
not included in the “few hooks” estimate.

### R8 — High: the view is a native container, not the GPU layer or renderer view

**Claim:** hand the shell a WebContentsViewCocoa NSView and resize through messages;
native handoff is trivial.

**Constraint:** public WebContents::GetNativeView exposes the mac content
container; GetContentNativeView/RenderWidgetHostViewMac exposes changing widget
content. Blink submits compositor frames; Viz/GPU compositing is presented via
CALayerParams/BrowserCompositorMac/AcceleratedWidgetMac and the native-view
bridge's DisplayCALayerTree. Remote CA context/IOSurface hosting is not a GPU
process handing an owned CALayer object to Swift. Caching render-widget native
views across process swaps/crashes breaks lifetime. No accessor patch is needed.

**Correction applied:** ENGINE explains the presentation chain and recommends a
stable host/attachment lease around public GetNativeView. P-TAB identifies
actual implementation symbols, avoiding private Cocoa casts/layer extraction.

### R9 — High: NSViewRepresentable is sound conditionally, not a complete integration

**Claim:** native embedding plus resize/visible messages solves presentation.

**Constraint:** wrapper identity, dismantle/close races, single-superview ownership,
window registration, first responder, IME, accessibility, drag/drop, popups,
backing scale and screen coordinates all matter. A single live tab cannot be
placed in two native windows. Multiple split panes can be visible while one is
keyboard-focused. SwiftUI snapshots or offscreen layers do not supply these
native behaviors.

**Correction applied:** IPC has native window registration, attachment IDs,
detach/invalidation and retained-empty-host semantics; stale commands fail.
Points and authoritative AppKit scale replace blind application of caller
scale. Native behavior remains an explicit prototype/test gate, not a runtime
claim.

### R10 — High: visibility is not renderer parking, freezing or media gating

**Claim:** space.focus/tab.activate park or unpark renderers; view visibility drives
IntersectionObserver and video pause.

**Constraint:** hiding WebContents applies Chromium visibility/background policy,
not process suspension, freezing, discard, forced media pause or a CSS viewport
intersection. Tabs share renderer processes and a page can have multiple site
processes. Space membership/order is unrelated to display visibility until a
view/window presents it; hidden audible/capturing tabs may keep running.

**Correction applied:** one reconciler combines presented panes, attachment,
view intent and native window occlusion; focus is separate. No process parking
or unconditional media policy is promised. Auto-freeze/discard policy stays Q5.

### R11 — High: discard and pin guarantees need policy and content-generation handling

**Claim:** tab.discard unloads “its renderer,” reloads on activate, pinned means
ineligible for all automatic discard, and each tab always maps 1:1 to one
WebContents.

**Constraint:** renderer kill is not per-tab unload. Chrome's lifecycle policy
uses TabStripModel and has both feature-controlled stable-WebContents discard
and replacement paths at M156. `WebContents::Discard` exists, but does not
supply a complete registry policy, activation flow or service integration.
Pin state alone is not a universal upstream never-discard invariant. A tab ID
must survive content replacement; native leases/observers must not retain old
content. Shared processes and protected media/capture also constrain policy.

**Correction applied:** optional tab_discard capability, explicit outcome,
bridge pin policy and stable tab IDs with content generation. No unconditional
baseline discard/1:1-lifetime or renderer-kill promise. Q5 covers policy scope.

### R12 — Medium: new renderer Mojo APIs are not prerequisite for the listed features

**Claim:** find, capture and CSS/boost actions require P-MOJO-001 renderer binders.

**Constraint:** existing WebContents find, capture/render-surface APIs and existing
script/devtools/renderer interfaces supply relevant primitives. A new binder
may eventually be justified, but adds frame/world/lifetime/security validation
work and does not make v1 “read-only” by its absence.

**Correction applied:** P-MOJO is deferred pending actual need. Future injection
must choose trusted frame/world scope without bypassing renderer isolation.

### R13 — Medium: per-space StoragePartition is not an evidenced profile requirement

**Claim:** true within-profile per-space storage partitioning is Arc-like and an
obvious medium patch in content_settings/profiles.

**Constraint:** supplied sidebar evidence assigns profiles to spaces. Spaces
need not imply distinct storage or a new profile each. StoragePartition does
not independently isolate every Profile-keyed service (history, settings,
credentials, extensions, etc.); partition choice affects SiteInstances/storage
and needs a separate design. Moving metadata cannot migrate BrowserContext.

**Correction applied:** ENGINE separates grouping/profile assignment from optional
within-profile partitioning. No asserted Arc behavior or patch-surface estimate.
General profile and isolation policy remains Q3.

## Findings: original IPC messages that could not work as written

The following corrections are in [IPC-CONTRACT.md](IPC-CONTRACT.md). This was
an unimplemented draft; changed schemas/closed enums/reply modes would require
a migration if any consumer already implemented the old version. No shell
protocol implementation was inspected or changed.

| ID / severity | Original claim or hole | Actual constraint and applied correction |
|---|---|---|
| R14 / High | All IDs engine-assigned, yet no profile/space creation replies; window.created supplies the assigned window ID from S. Foreground tab.create has no target window. | v1 hello returns a real startup profile ID; engine assigns tab/profile/attachment/session IDs, shell assigns grouping/window IDs and registers windows. Foreground create specifies a window. Future profile management remains out of scope. |
| R15 / High | Version negotiation is min(major), unknown messages always log/drop, but requests must receive exactly one reply. Errors only cover request/reply while unsupported example is a command. | Advertise supported majors, choose a common implemented major, error unknown requests/commands with correlation; unknown events may drop. Command errors and request completion rules now agree. |
| R16 / High | tab.close lets beforeunload run and “closes when it yields,” with no cancellation/UI/timeout result. | Page can veto or hang; delegate and JavaScriptDialogManager are required. Close is request/reply with closed/cancelled, one pending close, no UI confirmation silently approved. Timeout policy remains Q4. |
| R17 / High | tab.closed reason=crash, no distinction from sad-tab update; engine restores tabs on startup without any restore policy. | Renderer loss retains tab ID/content state and emits is_crashed. Engine-created tabs carry disposition/opener; v1 restoration is explicit shell creates. No silent BrowserList/session-restore dependency. |
| R18 / High | Native view token has no detach, lifetime, size units or stale generation; future XPC needs no shell changes. | Explicit in-process typed host lease, attach/detach/invalidation, main-only lifetime and actual native window/scale. Empty host before content destruction. XPC needs a new surface/input/accessibility adapter; native pointers cannot cross it. |
| R19 / High | tab.navigate transition includes reload; engine navigates any supplied string; committed transition limited to four values and is_main_frame may be false. | Reload uses NavigationController. Validate allowed URL/scheme policy. Filter IsInPrimaryMainFrame/HasCommitted, preserve qualifiers and map other transition cores; identify attempts, same-document/error commits and cancellation. An error-page commit need not mean ordinary success/new history entry. |
| R20 / High | navigation.failed has no frame/attempt identity; favicon candidates assumed icon bytes; security enum appears automatic. | Scope failures to primary navigation IDs and distinguish ERR_ABORTED/error-page commit. Use favicon service/driver; PNG encode decoded images, clear stale icons, bound data and scope refs to profile/session. Security must use real Chromium state or unknown. |
| R21 / High | Browser crash could be an engine.crashed message or connection drop with surviving shell; engine.shutdown/hot recovery implied ordinary service teardown. | Browser and shell share a process; browser crash kills both. Child crash observation only; orderly shutdown finishes before host exit, may cancel for beforeunload; no same-process hot restart or framework reload guarantee. |
| R22 / High | media.set_pip always opens default PiP; native pip_requested only carries video_size. | Video dimensions contain no surface/controller; document PiP needs child content ownership. Upstream delegate default is unsupported; default Chrome PiP requires explicit manager/controller glue. Native message removed pending a real protocol; control capability-gated, observed state authoritative, no closing another tab's global PiP. |
| R23 / Medium | MediaSession service yields per-tab playback/audibility/mute and arbitrary media.start; artwork_ref exists but no fetch. | Observe content::MediaSession for the addressed WebContents, independently read audibility/mute, validate available actions. Existing-session resume is not autoplay bypass. Omit unusable artwork refs until fetch exists; distinguish unknown session state. |
| R24 / Medium | Per-tab event order, created after reply, closed last, and any-queue S→E are underspecified under async coalescing/native callbacks; u64 JSON IDs implicitly safe. | Serialized UI/main dispatch, lifecycle barriers and generation checks; no mutation-stack callbacks; close is last tab event but its correlated completion may follow. Preserve u64 in adapters. Async main queue is not a separate browser UI thread. |

The corrected contract intentionally does not promise complete popup/native
permission UI, discard, PiP or artwork support. These need capability gates and
observable rejection, not success-shaped no-ops.

## Findings: packaging, process and build scaffolds

### R25 — High: actual bundle/target assumptions are wrong at this pin

**Claim:** required Versions/A, Plugin helper, all variants identical binaries
with distinct IDs, permanent Alerts process, arbitrary rename after build,
component dylibs already in Libraries, and `chrome_helper_app` ninja target.

**Constraint:** chrome/BUILD.gn uses the version number as framework_version;
its helper app name is a **template**, instantiated as `_default`, `_renderer`,
`_gpu`, `_alerts` and Apéritif targets. content_mac_helpers has no Plugin entry.
GPU/default helper bundle-ID suffixes are not all unique. Helper variants
provide different entitlements/linkage; Alerts is on-demand application behavior,
not a universal content `--type` path. Framework includes helper dependencies,
resources, crashpad handler and app loader; component-library runtime closure
is not packaged entirely inside it. Install names, exports, resource and helper
lookup must match the app's layout. Framework rename alone is insufficient.

**Correction applied:** ENGINE now states actual upstream rules and highlights
that build.sh's `chrome_helper_app` target is invalid. Branding is optional for
the dev spike; bridge exports/correct paths/entitlements are required. **The
script remains unmodified and unvalidated**: fixing it is separate implementation
work, not achieved by editing an architecture document. Both engine patch specs
include release export/packaging validation.

### R26 — Medium: process/security terminology and maintenance certainty mislead

**Claim:** browser owns network service, one renderer per site instance, process-
per-site policy unchanged, fixed process counts, crash reporting merely runtime
config, additive code does not conflict and therefore bumps take one day.

**Constraint:** network service normally runs in utility; process allocation is
not simple per-tab/per-SiteInstance identity; GPU/helpers can restart and process
policies vary. Crashpad requires packaged handler/configuration/symbols. Additive
code still calls unstable APIs and can fail to build/rebehave. Stock framework
packaging is not a public stable embedding ABI.

**Correction applied:** ENGINE removes hard cardinality/maintenance and trivial
Crashpad assumptions. Startup/delegate and desktop-service rebase risk is high.

### R27 — High: fetch.sh is destructive scratch-checkout tooling, not safe reusable rebase tooling

**Code findings (not run):** `checkout -B rearc-overlay`, gclient `--reset`,
`--force` and `--delete_unversioned_trees` lack a preflight ensuring a disposable
clean checkout. The overlay collision condition tests “exists and has a diff,”
so it permits overwriting a **clean tracked upstream file**, violating its own
new-files-only rule. Full-history fetch omits --depth but does not unshallow
an already-shallow clone. Depot_tools auto-update is disabled but its initial
revision is not pinned. Broad final git add -A can sweep unrelated local work.

**Proposed correction:** guard/refuse dirty or unowned checkouts; test tracked
path existence with git ls-files --error-unmatch (and reject existing unowned
files), stage only an enumerated overlay/patch set; explicitly unshallow when
requested; pin/log toolchain/depot_tools revisions. Confirm DEPS sync remains
at the requested src revision and verify the generated checkout before build.
No need to download a checkout to see these shell logic defects.

**Disposition:** recorded here; scripts left untouched per requested correction
scope. Do not run against a checkout containing work worth keeping.

### R28 — Medium: overlay instructions/series are plans, not checked mechanics

**Claim:** README's git commit -am records additive overlay; additive files never
conflict; 3-way resolves most bumps; rebase workflow is ready.

**Constraint:** commit -am omits new files (actual fetch.sh uses add -A instead).
New files can collide with newly introduced upstream paths and API drift.
Patches touching copied but unstaged new files need index handling for --3way.
Empty series means no bridge/startup patch exists at all. Layout's proposed
webcontents-view-accessor patch is unnecessary because GetNativeView is public.
Build.sh TODOs for target names/renaming and packaging are material blockers,
not incidental comments. Disk/toolchain/codec and signing assumptions are not
validated by syntax checks or an is_official_build flag.

**Proposed correction:** reconcile README/script application/index rules,
remove unnecessary accessor patch, replace the invalid target, inspect actual
runtime dependency closure/export list, then test in a disposable pinned
checkout. Never claim successful build/rebase before that run.

**Disposition:** captured in review and corrected authoritative ENGINE; README,
series and scripts unchanged. They must be refreshed when patches land.

## Open questions — decisions and evidence still required

1. **Q1, launch/runloop ownership:** can the native shell use an AppKit bootstrap
   with Chromium RunLoop driving the shared app, or must SwiftUI App.main own
   the outer lifecycle? Prototype the chosen approach before committing to a
   pump patch. P-APP A is a concrete spike, not an approved shell rewrite.
   Validate AppController-free quit state, early launch events and modal loops.
2. **Q2, Chrome service reuse:** for a browser-less registry, which required
   helpers are genuinely browser-independent at this pin? Does full product
   scope eventually require a backend BrowserWindowInterface adapter or larger
   service extraction? Suppressing visual chrome does not resolve that choice.
   P-TAB's registry path must pass security/delegate tests before its LOC range
   is trusted; do not quietly convert null-window CHECKs to no-ops.
3. **Q3, profiles:** startup exposes one loaded profile so v1 IDs are usable.
   Which space-to-profile mapping/private mode/migration should the later
   protocol support? One profile per space and within-profile partitions are
   policy choices, not findings established by static Arc metadata.
4. **Q4, page-driven UI:** decide native dialogs, popup creation/blocking,
   permission/capture prompts, file chooser, external protocols, fullscreen,
   security interstitial presentation and unresponsive-close timeout behavior.
   Baseline rejection/cancellation prevents false success; it is not browser
   feature parity. Choose the synchronous popup-staging/placement strategy.
5. **Q5, resource policy:** is tab discard in the first usable engine? Validate
   the actual kWebContentsDiscard configuration and stable/replacement paths,
   pin/capture/media safeguards, persistence and memory-pressure integration.
   No process-level park/kill shortcuts. Cross-window mirroring would need a
   separate design; one NSView lease supports moves, not duplicate embedding.
6. **Q6, PiP/artwork:** define native video surface/controller and document PiP
   child ownership before advertising pip_native. Decide artwork retrieval,
   payload limits/cache eviction and precise UI mapping of media/security
   states. These cannot be inferred from a boolean or image size.
7. **Q7, build proof:** fix fetch safety, targets, exports and runtime closure;
   choose toolchain/signing/bundle identifiers and resource paths. Demonstrate
   both component dev and non-component release app launch. No current script
   output proves an engine artifact exists.

## Applied work and verification

Updated [ENGINE.md](ENGINE.md) and [IPC-CONTRACT.md](IPC-CONTRACT.md) with the
confirmed constraints and explicit unsupported/lifetime behavior. Added precise
[P-APP-001](patches/P-APP-001.md) and [P-TAB-001](patches/P-TAB-001.md)
implementation specs, estimates, risk ratings and test plans. No patch or engine
implementation is claimed. Review findings on scripts/overlay instructions are
recorded above rather than silently extending this documentation task into
build-tool implementation.

Checks: read all original engine files; verified selected pin-specific source
paths/symbols; `bash -n` passed both scripts; checked local document links and
edited-file scope. Integration acceptance tests in the specs remain **unrun**
because there is no Chromium checkout/build or native engine harness.

**Top three risks:** (1) main-thread application/delegate/quit integration;
(2) underestimated browser-less Chrome service dependencies; (3) native content
view/compositor/input lifetime under SwiftUI, navigation swaps and teardown.

[tag]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/
[main-delegate]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/app/chrome_main_delegate.cc
[mac-parts]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/chrome_browser_main_mac.mm
[application]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/chrome_browser_application_mac.mm
[app-controller]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/app_controller_mac.mm
[main-parts]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/chrome_browser_main.cc
[runner]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/browser/browser_main_runner_impl.cc
[loop]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/browser/browser_main_loop.cc
[pump]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/base/message_loop/message_pump_apple.mm
[strip]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/ui/tabs/tab_strip_model.h
[tab-model]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/ui/tabs/tab_model.h
[tab-interface]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/components/tabs/public/tab_interface.h
[tab-features]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/ui/tabs/tab_features.cc
[tab-helpers]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/ui/tab_helpers.cc
[client]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/chrome_content_browser_client.cc
[contents]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/public/browser/web_contents.h
[delegate]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/public/browser/web_contents_delegate.h
[observer]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/public/browser/web_contents_observer.h
[discard]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/resource_coordinator/tab_lifecycle_unit.cc
[favicon]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/favicon/favicon_utils.h
[security]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/ssl/chrome_security_state_util.h
[media]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/public/browser/media_session.h
[pip]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/picture_in_picture/picture_in_picture_window_manager.h
[mac-view]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/browser/web_contents/web_contents_view_mac.mm
[rwhv]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/browser/renderer_host/render_widget_host_view_mac.mm
[compositor]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/browser/renderer_host/browser_compositor_view_mac.mm
[widget]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/ui/accelerated_widget_mac/accelerated_widget_mac.mm
[view-bridge]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/app_shim_remote_cocoa/render_widget_host_ns_view_bridge.mm
[build]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/BUILD.gn
[helpers]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/public/app/mac_helpers.gni
[exports]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/app/framework.exports
