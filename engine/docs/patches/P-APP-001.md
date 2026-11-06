# P-APP-001 — Shared macOS application and browser lifecycle

Status: implementation specification for the first integration spike; no patch
or runtime proof yet. Required. Rebase risk: **high**. Dependencies: framework
bridge exports/packaging and the tab registry shutdown hook in P-TAB-001.

## Evidence and version boundary

Paths/symbols below were inspected remotely at Chromium tag
`156.0.8078.74`, commit `d331de35ca8ab1358c7a17e4bd41627d55eaef51`.
No checkout was fetched. They are exact for that source inspection, not a
claim that an overlay has compiled. Re-check overloads, visibility and GN
ownership in the engineer's checkout. In particular,
`content/browser/browser_main_loop_mac.mm` does **not** exist at this tag;
the relevant generic code is `browser_main_loop.cc`, with macOS application
integration in `chrome_browser_main_mac.mm` and `message_pump_apple.mm`.

## Invariants and proposed spike

Keep browser UI and AppKit on the process **main thread**. One NSApplication,
one delegate owner, one top-level loop. Preserve Chromium browser services,
profile initialization, renderer/GPU/utility startup and shutdown ordering.
Never run `ChromeMain` on a worker to evade the NSApplication singleton.

Reference implementation **A** leaves Chromium's `base::RunLoop::Run()` on
the stack so its native pump enters `[NSApp run]`. Shell-owned NSWindows host
SwiftUI through AppKit/NSHostingView, including NSViewRepresentable content.
The engine's run entry point is blocking until shutdown. A ready callback
creates the shell UI only after browser services/profile startup. This keeps
the upstream task pump and nested-loop behavior rather than inventing an
external pump.

This is an implementation candidate within the fixed framework/native-shell
architecture. The product decision between A and a shell-owned outer loop is
open (review Q1); current `shell/` bootstrap compatibility has not been audited
or changed. If a SwiftUI `@main App` must own launch, prototype **B** first:
a real external-pump adapter, attached task delegate, nesting bookkeeping,
shutdown and scheduler integration. A CFRunLoop observer/timer calling
RunUntilIdle, or simply calling Initialize without Run, is not B. At this pin,
the Attach/Detach machinery visible in `message_pump_apple.mm` is iOS-gated;
it is not a ready-made macOS external-loop API. B changes the scope and LOC
estimate below and must earn its own runtime evidence.

## Upstream patch map

Links target the exact pin. “Patch” means a deliberate hunk; “audit” means
reuse/inspect without a speculative source edit.

| Path and exact symbol | Action |
|---|---|
| [`chrome/app/chrome_main.cc`][main], `ChromeMain` | Audit full content/chrome bootstrap and cleanup. Add a dedicated bridge export in a new ObjC++ file; do not pretend ChromeMain returns after startup. Forward helper invocations to upstream process dispatch. |
| [`chrome/app/chrome_main_delegate.cc`][delegate], `ChromeMainDelegate::PreBrowserMain()` | Preserve resource/locale and platform setup. For A, call the bridge bootstrap to create the chosen application singleton before `RegisterBrowserCrApp()` and before browser task-pump creation; its application must pass the existing BrowserCrApplication checks. Never replace the singleton after creation. |
| [`chrome/browser/chrome_browser_application_mac.mm`][application], `RegisterBrowserCrApp()`, `+[BrowserCrApplication sharedApplication]`, `-terminate:`, `-cancelTerminate:` | Retain the subclass and pump checks. Create an additive `ReArcApplication : BrowserCrApplication` before registration; override termination/cancellation to bridge lifecycle, bypassing the inherited AppController-based quit path. Audit all remaining AppController references in this class, including menu/quit behavior. Do not remove sendEvent/accessibility behavior merely to remove chrome. |
| [`chrome/browser/chrome_browser_main_mac.mm`][macparts], `ChromeBrowserMainPartsMac::PreCreateThreads()` | After the POSIX/base initialization, replace the nil-delegate/AppController/BuildMainMenu/mainMenuCreated block with bridge delegate/menu installation. AppController must not be instantiated by another hook. |
| Same file, `ChromeBrowserMainPartsMac::PreCreateMainMessageLoop()` and `PreEarlyInitialization()` | Suppress install-from-DMG UI through the appropriate startup policy; audit inherited state restoration, login-item behavior and Services-menu swizzle. Preserve resource/security/toolkit setup. Do not return early from the whole stage. |
| Same file, `ChromeBrowserMainPartsMac::DidEndMainMessageLoop()` | Replace its call to AppController.sharedController with bridge finalization. A teardown-only call to sharedController would recreate/replace the delegate. |
| [`chrome/browser/chrome_browser_main.cc`][parts], `ChromeBrowserMainParts::PreMainMessageLoopRunImpl()` | Separate profile/service startup from `browser_creator_->Start(...)`. In embedded mode use bridge readiness instead of Chrome startup-window creation, **while preserving** GetMainRunLoopInstance creation, BrowserProcess quit closure, async profile unblocking and PostBrowserStart. Do not skip the function wholesale. |
| Same file, `ShouldInterceptMainMessageLoopRun()`, `WillRunMainMessageLoop()`, `PostMainMessageLoopRun()` | Audit/reuse normal RunLoop ownership and cleanup. If the Start call is bypassed without creating its success-path runloop, ShouldInterceptMainMessageLoopRun returns false and the process tears down immediately. |
| Same file, `ChromeBrowserMainParts::Create()` | Optional construction seam if an additive `ReArcBrowserMainPartsMac` subclass is needed. Reuse the extra-parts registration in this factory; do not replace it with a bare mac main-parts object. |
| [`chrome/browser/chrome_content_browser_client.cc`][client], `ChromeContentBrowserClient::CreateBrowserMainParts()` | Audit the factory caller and its threads-ready callback; normally no hunk needed if ChromeBrowserMainParts::Create is the seam. |
| [`chrome/browser/app_controller_mac.mm`][controller], `+[AppController sharedController]`, `-init`, `-applicationDidFinishLaunching:`, `-tryToTerminateApplication`, `-didEndMainMessageLoop` | Audit, do not create a second delegate/proxy that violates sharedController's identity CHECK. Identify services lost with AppController: keepalive, open/reopen/URL events, menus, launch completion and quit. Reimplement required application glue additively. |
| [`chrome/browser/lifetime/application_lifetime_mac.mm`][lifetime], `chrome::HandleAppExitingForPlatform()` | Audit its termination notification and compositor cleanup against a browser-less host. Reach equivalent cleanup exactly once; guard only genuinely Chrome-window-specific behavior. |
| [`chrome/BUILD.gn`][build], `chrome_dll`, `chrome_framework`; [`chrome/app/framework.exports`][exports], `framework.order` | Wire bridge source/deps and exported C ABI. Update symbol-order verification inputs if required by the added exports. Keep exports available in non-component stripped release builds, not only debug. |

Do not patch `base/message_loop/message_pump_apple.mm`,
`content/browser/browser_main_loop.cc`, `browser_main_runner_impl.cc` or
`content/app/content_main_runner_impl.cc` for A without a demonstrated need.
They define the lifecycle A preserves. B would need explicit design against
`MessagePumpCFRunLoopBase::Run`, `MessagePumpNSApplication::DoRun/DoQuit`,
`BrowserMainLoop::RunMainMessageLoop` and runner/context lifetimes.

## Additive code and sequence

Proposed new files under `chrome/browser/rearc_bridge/`:
`rearc_application_mac.{h,mm}`, `rearc_app_delegate_mac.{h,mm}`,
`rearc_engine_lifecycle.{h,cc}` and `rearc_engine_entry_mac.mm`; a source-set
BUILD.gn and public ObjC/C header. These names are ReArc design, not upstream
symbols. Keep Swift independent of Chromium C++ ABI.

1. Entry runs on main before NSApplication/SwiftUI launch. Initialize the
   command line, Chromium main delegate/content context and normal process
   bootstrap exactly once. Create ReArcApplication at the PreBrowserMain
   seam, when required Chromium globals exist. Do not use two AtExitManagers
   or separate duplicate Mojo/ThreadPool initialization.
2. Replace the mac application-delegate/menu block only. Install one retained
   ReArc delegate. Shell supplies menu/window callbacks; forwarding ordinary
   application events must not call back into the missing AppController.
3. Complete profile lock, prefs, policy, resources and browser service startup.
   Embedded startup skips browser-window/session-restore/default-browser/first
   run presentation, not service initialization. Verify clean and existing
   user-data directories, not just `--no-first-run` on a developer profile.
   Hold a `ScopedKeepAlive` (`components/keep_alive_registry/`) while shell
   lifetime is active. Chrome BrowserList is not the tab registry.
4. Preserve creation/transfer of the main RunLoop and quit closure. Register
   the default profile with the bridge. Post ready/UI construction after
   startup on Chromium UI. A's entry calls the ordinary run path and blocks;
   no second NSApplicationMain or SwiftUI App.main is entered.
5. Handle reopen/open URLs/second-instance events through shell policy after
   readiness, queueing early events safely. The platform process singleton
   and profile directory lock remain enforced. Audit
   `StartupBrowserCreator::ProcessCommandLineAlreadyRunning` and AppController
   call sites: launch suppression is not just initial-window suppression.
6. On quit, stop new requests and resolve/cancel in-flight work. Run P-TAB's
   close state machine; beforeunload cancellation resumes the app. Empty
   content hosts and destroy tabs before profile teardown. Cancel pending
   native UI and observers. Release the keepalive and request the upstream
   quit closure, retaining the existing shutdown/quit state invariants.
7. Return from Run only when content is safe to tear down; let BrowserMain
   and ContentMain unwind their runner, service/thread and process cleanup.
   Deliver terminal lifecycle completion from the host after run return.
   Do not call exit() from a Cocoa terminate callback or unload the framework
   with live tasks. Browser-process restart means application relaunch.

The exact replacement for Chrome's BrowserList-driven quit orchestration
must be proven in the spike; copying only the quit closure is not proof that
BrowserProcess shutdown state/profile keepalives have been satisfied.

## Size estimate and rebase cost

For A, budget **120–300 changed upstream LOC across 5–8 implementation/build
files**, **700–1,300 additive engine LOC**, and **400–800 test/harness LOC**.
These are planning ranges, exclude P-TAB and packaging/signing work, and are
not measured diffs. Factory vs direct seam may alter the file count. B adds
roughly **300–800 LOC** of pump/scheduler work plus a substantially larger
nested-loop test burden; estimate confidence is low until prototyped.

Risk remains high even if the final hunks are short: pre-browser initialization,
mac app/delegate semantics, startup-profile policy and shutdown change often.
No guarantee of a one-day rebase. Re-check AppController references and
GetMainRunLoopInstance ownership at every pin bump.

## Acceptance tests (must run in a built app at the pin)

- Main-thread assertions for startup, BrowserThread::UI, delegate callbacks,
  tab operations and content views. Assert one expected NSApp/subclass and
  delegate before/after launch, reopen and shutdown; fail early if a plain
  SwiftUI/NSApplication singleton was created first.
- Fresh profile, existing profile, no saved windows, closed-last-window and
  second-instance launches. No Chromium Browser/BrowserView, menu takeover,
  profile picker, install, first-run, restore or default-browser UI. Required
  services/profile still initialize; lock conflicts fail or route correctly.
- Native menu tracking, drag tracking, NSOpenPanel/sheet and nested modal loop:
  immediate/delayed Chromium tasks, IPC replies and renderer frame presentation
  continue without a polling timer, busy spin, starvation or reentrancy crash.
  Verify application tasks are allowed only in appropriate nested scopes.
- Navigate two pages in native hosts; exercise IME, copy/paste, command key-up,
  VoiceOver and accessibility focus. Verify SwiftUI state updates alongside
  Chromium UI tasks and early/open-URL/reopen event delivery.
- Quit from menu, Dock, update path and OS termination request with zero,
  one and several tabs. Test beforeunload accept/cancel, unresponsive tab,
  active native modal UI and an in-flight view attach/favicon request. Tabs
  and compositors die before profiles/thread services; no leaked keepalive,
  double termination notification, UAF or teardown tasks on destroyed runners.
- GPU/renderer crash recovery works; browser-process crash terminates the
  whole app and external app relaunch recovers. No in-process restart test
  may pass by accidentally retaining old globals.
- Test assembled non-component release as well as component debug: exported
  bridge symbols, resource loading, helpers/sandbox, codesigning and clean
  app exit. Debug-only linkage is not acceptance.

[main]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/app/chrome_main.cc
[delegate]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/app/chrome_main_delegate.cc
[application]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/chrome_browser_application_mac.mm
[macparts]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/chrome_browser_main_mac.mm
[parts]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/chrome_browser_main.cc
[client]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/chrome_content_browser_client.cc
[controller]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/app_controller_mac.mm
[lifetime]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/lifetime/application_lifetime_mac.mm
[build]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/BUILD.gn
[exports]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/app/framework.exports

## Drift log

### 2026-11-01 @ 156.0.8078.74 (slice 1 implementation, patch app/002)

No drift. Every seam in the patch map above was verified in the fetched
checkout before slice 1 was authored:

- `chrome/browser/chrome_browser_application_mac.mm`: `RegisterBrowserCrApp()`
  (line 39), `+[BrowserCrApplication sharedApplication]` CHECKs (line 165),
  `-terminate:`/`-cancelTerminate:` via AppController (lines 318/323) — all as
  spec'd. Slice 1 redirects singleton creation to `ReArcApplication` here.
- `chrome/app/chrome_main_delegate.cc`: `PreBrowserMain()` calls
  `RegisterBrowserCrApp()` at line 1939, as spec'd.
- `chrome/browser/chrome_browser_main_mac.mm`:
  `PreCreateThreads()` nil-delegate/AppController/BuildMainMenu/mainMenuCreated
  block at lines 151–166; `DidEndMainMessageLoop()` AppController call at
  line 185. Not yet hooked — delegate/menu installation is a later slice.
- `base/message_loop/message_pump_apple.mm`: `Attach`/`Detach` and `OnAttach`
  remain `BUILDFLAG(IS_IOS)`-gated; approach A needs none of it.
  `message_pump_apple::Create()` selects `MessagePumpCrApplication` via
  `conformsToProtocol:@protocol(CrAppProtocol)`, so the subclass singleton
  keeps the correct pump.
- `content/browser/browser_main_loop_mac.mm` confirmed absent, as spec'd.
- `chrome/browser/BUILD.gn` hosts the mac browser sources in
  `source_set("browser")`'s `is_mac` block (sources ~line 1520, deps ~line
  1538); the spec's build row cited `chrome/BUILD.gn` `chrome_dll` —
  equivalent wiring point for this pin, hunk placed in `chrome/browser/BUILD.gn`.

Implementation findings recorded for later slices (not spec drift, but not in
the spec text either):

1. Chromium's `raw_ptr` clang plugin rejects raw-pointer class members in
   bridge code (`void* user_data` → `raw_ptr<void>`).
2. The tree builds with `-fvisibility=hidden`; the exported bridge C ABI must
   carry `__attribute__((visibility("default")))`, the same convention
   `ChromeMain` uses in `chrome/app/chrome_main.cc`. Slice 1 ships both
   halves of the export story: `REARC_ENGINE_EXPORT` on the C ABI (required
   in every configuration, including this component dev build) and the two
   symbols in `chrome/app/framework.exports` (consulted only for
   non-component/non-sanitizer links, chrome/BUILD.gn:1365,1418).
   `framework.order` needed no hunk: an order file tolerates unlisted
   symbols, and no ordering constraint applies to the new exports.
3. `chrome/browser/ui/webui/version/version_ui.cc` about:version branding rode
   along in patch 002 via concurrent authorship; it belongs to P-BUILD-001
   bookkeeping-wise.

### 2026-11-01 @ 156.0.8078.74 (wave-5 slice 3, patch app/005)

No upstream drift; one **series-mechanics finding** recorded for all future
slices: every patch file must individually pass `git apply --check -R`
against the fully applied tree, and a new-file patch (002) cannot
reverse-apply once its created files carry later modifications. Slice 3's
first design extended 002's `rearc_engine_lifecycle.*` and
`rearc_bridge/BUILD.gn` and had to be restructured purely additive over 002:
readiness lives in standalone `rearc_readiness.{h,cc}`
(`EngineReadinessSink`; merges into the lifecycle host C ABI surface at the
shell-integration wave), and the six seam sources compile in
`source_set("core")`'s `is_mac` block rather than the `rearc_bridge` target.
Corollary for later slices: extend the bridge only through new files, and
keep every hunk outside other patches' `-U3` context windows (app/005's
includes and its `PostBrowserStart` override are deliberately placed out of
alphabetical/stage order for this; regroup at the next pin rebase).

Seam semantics verified in-tree before authoring: `PostBrowserStart` is
virtual public (`chrome_browser_main.h:115`), not overridden by
`ChromeBrowserMainPartsPosix`, invoked once from
`PreMainMessageLoopRunImpl` after `UnblockAsyncLoading()`
(`chrome_browser_main.cc:2163-2165`) — the spec's startup tail, so the mac
override is the correct readiness point without touching the high-churn
generic file. `ScopedKeepAlive` API and AppController's
`APP_CONTROLLER`/`DISABLED` parameters verified at
`components/keep_alive_registry/` and `app_controller_mac.mm:824`;
`keep_alive_registry` depends only on `//base` + crash_key (no cycle).
Readiness C ABI exports deliberately deferred (framework.exports untouched;
no new exported symbols — validated by nm). Gate: engine/build-p5.log
attempt 2, exit 0. Wave 5 completes the P-APP-001 scaffolding; the real
`PreMainMessageLoopRunImpl` embedded-startup restructuring, shell menu
construction, ordered teardown and real profile work remain ahead and are
NOT claimable from this wave.

### 2026-11-01 @ 156.0.8078.74 (wave-5 slice 2, patch app/004)

No drift. `ChromeBrowserMainPartsMac::DidEndMainMessageLoop()` now finalizes
through `rearc::FinalizeReArcAppDelegate()` when a lifecycle host is
registered; the teardown-only `AppController.sharedController` call the patch
map warned about is unreachable under the gate, so no delegate can be
recreated during teardown. The upstream call moved from line 185 (pre-003
recording) to line 203 after 003+004; rebase notes should target the gated
form. `FinalizeReArcAppDelegate()` remains the 002 scaffolding no-op; real
ordered teardown (P-TAB-001 close state machine, keepalive release) is still
ahead. Gate off → stock path bit-identical; validated with nm/strings +
`--version` only (build gate: engine/build-p4.log, exit 0).

### 2026-11-01 @ 156.0.8078.74 (wave-5 slice 1, patch app/003)

No drift. `ChromeBrowserMainPartsMac::PreCreateThreads()` now installs the
bridge delegate/menu when an engine lifecycle host is registered
(`rearc::GetEngineLifecycleHost()`), via
`rearc::InstallReArcAppDelegateAndMenu()` from patch 002, and returns before
the AppController/`BuildMainMenu`/`mainMenuCreated` block — the patch-map row
"replace the nil-delegate/AppController/BuildMainMenu/mainMenuCreated block
with bridge delegate/menu installation" is now implemented (gated). The block
moved from lines 151–166 (pre-003) to 159–174 (post-003); rebase notes should
target the gated form. `InstallReArcAppDelegateAndMenu()` deliberately keeps
the upstream `CHECK_EQ(nil, NSApp.delegate)` invariant. The menu surface is
still the 002 placeholder (empty `NSMenu` titled "ReArc"); shell-owned menu
construction remains a later slice. Gate off → stock path bit-identical;
validated with nm/strings + `--version` only (build gate: engine/build-p3.log,
exit 0).
