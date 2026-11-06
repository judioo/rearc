# ReArc Engine — Architecture

Status: design baseline, corrected by the [engine review](REVIEW-CODEX.md).
No Chromium integration has been built. Static Arc bundle inspection supports
framework/helper packaging and a native shell; it does not establish Arc's
runloop, IPC transport, patch size, or WebContents ownership strategy.

## 1. What the engine is

ReArc uses vanilla Chromium pinned by `engine/CHROMIUM_PIN` to
`156.0.8078.74`, with a minimal patch overlay in `engine/patches/`. The
browser process runs inside the Swift shell process, with standard isolated
renderer, GPU, and utility processes. An ObjC/ObjC++ bridge exposes
[rearc.ipc.v1](IPC-CONTRACT.md). All browser chrome belongs to the shell.

Design rules:

1. Keep upstream modifications small and measurable. A one-day rebase is a
   goal, not an established maintenance cost.
2. Prefer additive bridge files under `chrome/browser/rearc_bridge/`.
   Additive code still depends on unstable Chromium APIs and must be compiled
   and tested at every bump.
3. Keep product UI in Swift. Browser-side services, delegates, security
   decisions, and native content-view lifecycle remain engine responsibilities.

The pinned source is publicly readable at [the exact tag][upstream], resolved
for this review to commit `d331de35ca8ab1358c7a17e4bd41627d55eaef51`.
Implementation must re-check the symbols against its checkout.

## 2. Process model and packaging

| Process | Role | ReArc consequence |
|---|---|---|
| Browser, one per app/user-data-dir instance | Profiles, WebContents, privileged policy and child-process orchestration | Shares the shell's address space and main/UI thread. A browser-process crash kills the shell. Network service normally lives in a utility process. |
| GPU, normally one, restartable | Viz/GPU compositing, raster/video work according to platform and configuration | Standard helper and sandbox; do not promise a permanent process or a particular rendering backend. |
| Renderers, zero or more | Blink/V8, site-isolated frames | WebContents, SiteInstance and renderer processes are not 1:1. Multiple tabs can share a process; one tab can involve several processes. |
| Utility processes, zero or more | Network, audio, storage and other services | Upstream process policy; service failures are not necessarily process crashes. |
| Alerts helper, on demand | macOS alert-style notification identity | Separate application launch path; not a permanent `--type=alerts` process. |

Use upstream bundle-generation rules as the packaging authority:
[`chrome/BUILD.gn`][build] and
[`content/public/app/mac_helpers.gni`][helpers]. Upstream M156 uses a
version-numbered framework directory (`Versions/156.0.8078.74` with
`Versions/Current`), not a required `Versions/A` layout. Helpers include the
base, Renderer, GPU and Alerts variants, and upstream Apéritif variants.
There is no Plugin helper in this pin's helper list. Apéritif is present in
upstream Chromium; its name in Arc's bundle alone does not prove custom Arc
engine behavior.

The framework's `Helpers/` also includes `chrome_crashpad_handler` and
`app_mode_loader`. Variants have different entitlement requirements and can
have different executable/linkage paths; do not assume identical binaries or
unique bundle IDs for every variant. Preserve upstream relative paths,
resources, dylib install names, helper lookup and signing requirements.
Renaming a built `.framework` with `cp` is insufficient.

`//chrome:chrome_framework` is a real upstream target. `chrome_helper_app`
is a GN **template**, not a build target: generated labels include
`//chrome:chrome_helper_app_default`, `_renderer`, `_gpu` and `_alerts`.
The framework bundle includes helper dependencies. Component-build dylibs
are not all packaged inside it; a standalone shell must collect and resolve
its runtime dependency closure. `build.sh` now requests `chrome_framework`
and `chrome` with stock Chromium names; the latter supplies a runnable baseline.
The component build still needs its entire output directory. See
[FETCH-STATUS.md](FETCH-STATUS.md) for execution status and unverified build
assumptions.

Brand display names can remain Chromium in a development spike. A bridge
export list, correct bundle/resource discovery, executable/helper layout and
valid entitlements are required integration work even without branding.
Never disable sandboxing or site isolation to make embedding work.

## 3. Framework embedding

The fixed architecture is a linked Chromium framework and native SwiftUI
chrome. Neither a new UI toolkit nor a different Chromium distribution is
required by this review.

### Startup and the single main thread

There must be one `NSApplication` singleton and one coordinated macOS main
loop. Chromium's `BrowserThread::UI` and all AppKit content-view operations
run on the process main thread. Moving the browser UI thread to a worker
and forwarding only view operations to main is not a supported alternative.

Upstream startup is not an embeddable, nonblocking `ChromeMain` call:

- `ChromeMainDelegate::PreBrowserMain()` calls `RegisterBrowserCrApp()`.
  The latter requires `NSApp` to be a `BrowserCrApplication`, with Chromium's
  event-dispatch and accessibility behavior in place before pump creation.
- `ChromeBrowserMainPartsMac::PreCreateThreads()` requires a nil application
  delegate, obtains `AppController.sharedController`, and builds Chrome's
  menu. `AppController.sharedController` installs and checks delegate identity.
  Keeping a SwiftUI-installed delegate and merely skipping a browser window
  will hit these assumptions.
- `BrowserMainRunnerImpl` separates Initialize, Run and Shutdown, but the
  higher content/chrome startup context and services must stay alive too.
  Returning from the ordinary `BrowserMain` path starts teardown.
- `MessagePumpNSApplication::DoRun()` calls `[NSApp run]` when the application
  is not already running. `MessagePumpCFRunLoopBase::Run()` installs the task
  delegate only while Run is active. A foreign AppKit loop plus an initialized
  Chromium task runner does not establish a host-driven pump.

The first integration spike should evaluate Chromium's normal `base::RunLoop`
driving the shared AppKit loop, while shell-owned windows host SwiftUI. A
shell-owned outer loop is possible only with an explicit external-pump design
covering scheduler attachment, nested loops and shutdown. Which bootstrap to
ship remains open; neither can be described as a proven one-line hook.
[P-APP-001](patches/P-APP-001.md) specifies the reference spike, exact upstream
seams, delegate replacement and acceptance tests. No shell changes are made
in this documentation task.

### Tab ownership and browser services

The current design targets a bridge-owned registry of `WebContents` without
constructing Chrome `Browser`/`BrowserView`. That bypasses Chrome's desktop
tab pipeline rather than customizing its horizontal tab strip.

At M156, `TabStripModel` remains in `chrome/browser/ui/tabs/`; desktop
`tabs::TabModel` implements `components/tabs/public/tab_interface.h` and owns
WebContents. `tabs::TabFeatures::Init()` requires a `BrowserWindowInterface`.
Suppressing visual chrome alone does not require abandoning these backend
objects, but reusing them in a browser-less registry is not automatic.

[P-TAB-001](patches/P-TAB-001.md) defines the registry/delegate route and its
service audit. Do not bulk-attach `TabHelpers` or instantiate `TabFeatures`
with null browser/window assumptions. Navigation, popup adoption, beforeunload,
favicon fetching, security state, permissions, file dialogs and media each
need explicit integration or an explicit unsupported result. Native dialogs
and browser services cannot be silently omitted because their product UI is
out of v1 scope.

### Native content-view handoff

Use `content::WebContents::GetNativeView()` through ObjC++, not a private
`WebContentsViewCocoa` cast or a cached render-widget view. The macOS content
container is implemented by `WebContentsViewMac`/`WebContentsViewCocoa`;
its renderer-facing `RenderWidgetHostViewMac` and `RenderWidgetHostViewCocoa`
children can change during navigation and renderer recovery.

Blink produces compositor frames, Viz/GPU performs compositing, and the macOS
presentation path carries `gfx::CALayerParams` through
`BrowserCompositorMac`, `ui::AcceleratedWidgetMac` and
`RenderWidgetHostNSViewBridge` to `ui::DisplayCALayerTree`. Remote Core
Animation contexts and/or IOSurface-backed content are hosted in native
layers. The shell embeds the native container; it does not take ownership of
GPU layers or paint a bitmap every frame.

`NSViewRepresentable` is a sound wrapper for an in-process AppKit host view,
subject to a prototype. Use a bridge-owned stable container and an attachment
lease. Keep WebContents and its child view owned by the engine; detach/empty
the host before destroying content. Layout uses AppKit points; actual backing
scale and screen information come from the destination `NSWindow`/screen.
Coordinate resize, first responder, IME, accessibility, drag/drop, popups,
visibility, occlusion and cross-window moves on main. A native view can have
only one superview; a single live tab cannot be embedded in two windows at
once. Multiple split panes can be visible while only one has keyboard focus.

The message API can retain data semantics in a future transport. Native view
leases, input, accessibility and process lifetime would require a new design
for XPC; this is not a transport swap with no shell changes.

## 4. Patch and bridge work

| ID / area | Purpose and actual constraint | Classification |
|---|---|---|
| `P-APP-001`: `chrome/app/chrome_main_delegate.cc`, `chrome/browser/chrome_browser_main.cc`, `chrome/browser/chrome_browser_main_mac.mm`, application/delegate seams | Single main-loop startup, shell menus/delegate, startup-window suppression, keepalive and ordered shutdown. Exact paths in the spec; high rebase risk. | REQUIRED |
| `P-TAB-001`: additive `chrome/browser/rearc_bridge/`, GN wiring and audited service hooks | Browser-less tab registry, delegates/observers, native host leases; not a TabStripModel UI patch. Service dependencies determine upstream edits. | REQUIRED |
| `P-NAV-001`: additive bridge | NavigationController and observer adapter, primary-page filtering and security policy. | REQUIRED |
| `P-MOJO-001`: additive, only if justified | A new renderer interface is not required merely for find, capture or script/CSS execution: existing Chromium APIs/protocols already provide primitives. Audit privilege and world/frame targeting before adding binders. | Deferred v1.1; need for a patch unproven |
| `P-PIP-001`: `chrome/browser/picture_in_picture/` plus delegate/controller integration | Native PiP requires video surface or child-WebContents ownership, controls and lifetime. Default Chrome PiP also needs the WebContents delegate integration; dimensions alone cannot supply a native PiP surface. | NICE-TO-HAVE; capability-gated |
| `P-PROF-001`: profile/storage services | Spaces are shell grouping, with profiles assigned to spaces. Within-profile storage partitioning is a separate optional policy, not an established Arc requirement or a full substitute for profile isolation. | NICE-TO-HAVE; policy open |
| `P-BUILD-001`: `chrome/BUILD.gn`, bundle paths/exports/signing | Branding optional in dev; bridge ABI exports, resource/helper paths and entitlement-correct packaging required. | REQUIRED integration subset; optional branding |
| Media observation | Observe `content::MediaSession` and its Mojo observer per WebContents; combine with audibility and mute from WebContents. Observe available actions; do not control the globally active session for an arbitrary tab. | Additive bridge |
| Space switching | Shell membership/order and explicit content visibility; hidden is not frozen, discarded, muted or guaranteed stopped. | Shell + bridge |
| Updates / crash reporting | Sparkle delivers the whole app. Crashpad needs handler packaging, paths, startup configuration and symbols. Browser crash recovery requires relaunch of the host process. | Shell + engine packaging/startup |

No patch files or bridge implementation exist yet. LOC estimates and test
plans are in the two implementation specs; these are estimates, not measured
patch sizes. Patch conventions remain in `engine/patches/README.md`; its
inventory/layout examples predate this review.

## 5. Responsibilities and build gates

| Concern | Owner |
|---|---|
| Rendering, JS, network/storage isolation, sandbox/security mechanisms | Chromium engine; bridge must preserve their policy and required delegates |
| Tab lifetime, content views, navigation execution, favicon/media/security adapters | Engine bridge |
| Sidebar graph, space UUIDs, ordering, profile-assignment policy, native chrome | Swift shell |
| Content visibility and focus | Shell intent, engine reconciliation with AppKit window state |
| Profiles and session restoration | Engine profile lifetime; shell restore policy. v1 exposes one startup profile; no implicit Chrome session restoration. |
| App delivery | Shell updater, with engine and helper signing/packaging |

`engine/scripts/{fetch,build}.sh` are untested scaffolds, not release tooling.
Dev arguments intend a component/debug build; release arguments intend an
unbranded non-component official/optimized build with PGO disabled. Neither
flag set proves hermeticity or a shippable bundle. Do not infer that component
dylibs live in the framework, that renaming preserves linkage, or that
`is_official_build` grants codec/CDM distribution rights.

Before the first engine milestone: validate GN targets/args and dependency
closure, exports, bundle lookup, profile lock, helper sandbox/entitlements,
code signing and launch on the actual pin. Then exercise the P-APP/P-TAB
acceptance tests in an assembled shell app. No checkout/build/runtime test
was performed for this review; `bash -n` only checks script syntax.

Version bumps remain: change pin, sync, refresh overlay, build, test and land
as one coherent change. Treat a cheap rebase as an outcome to measure.

[upstream]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/
[build]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/BUILD.gn
[helpers]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/public/app/mac_helpers.gni
