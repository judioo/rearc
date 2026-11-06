# P-TAB-001-SLICES — Slice-by-slice implementation plan for the browser-less tab model

Status: implementation plan, docs only (authored under a strict read-only
constraint against the Chromium tree: no mutations under
`engine/chromium/src`, no builds, no patch files). Ready to hand to wave 6.

Pin: Chromium `156.0.8078.74`, commit `d331de35ca8ab1358c7a17e4bd41627d55eaef51`,
with overlay commits `a646aadea9` (patch 001) and `e8a1859972` (patch 002,
P-APP-001 slice 1) on top. Every `file:line` below was verified against this
checkout on 2026-11-01.

Sources: [P-TAB-001](P-TAB-001.md) (spec being decomposed),
[P-APP-001](P-APP-001.md) (lifecycle dependency), [ENGINE](../ENGINE.md),
[IPC-CONTRACT](../IPC-CONTRACT.md) (`rearc.ipc.v1`),
[REVIEW-CODEX](../REVIEW-CODEX.md) R6–R8,
`docs/SIDEBAR-SPEC.md` (shell tab-model needs),
`shell/Sources/ReArc/Engine/WebEngine.swift` (shell seam).

---

## 0. Executive summary

Seven compile-gatable slices (S1–S7), each independently landable with the
overlay compile gate green. Total upstream surface stays inside P-TAB-001's
budget: **one ~5-line upstream hunk** (S1) plus GN wiring already shipped in
patch 002; everything else is additive under `chrome/browser/rearc_bridge/`.

The centerpiece decision — **browser-less registry, not a BrowserWindowInterface
adapter** — is justified in §2: `TabFeatures::Init` CHECKs a
BrowserWindowInterface, and reaching that code path at all requires
instantiating `tabs::TabModel` via `TabStripModel`, which drags in ~69 virtual
methods of browser-window semantics we do not have. The registry route never
reaches the CHECK. The first seam (S1) is the embedded-mode branch in
`ChromeContentBrowserClient::GetWebContentsViewDelegate`, which must be an
ambient engine-mode decision because content consults the factory
synchronously inside `WebContents::Create`.

---

## 1. Slice decomposition

Each slice: exact upstream anchors at the pin, additive files, LOC estimate
(additive / upstream-hunk), rebase risk, and its compile gate. Slices are
ordered so each compiles against the previous tip; none requires a later
slice's symbols.

| Slice | Name | Additive files (`chrome/browser/rearc_bridge/`) | Upstream hunks | Est. LOC (add/hunk) | Rebase risk |
|---|---|---|---|---|---|
| S1 | Embedded-mode flag + view-delegate factory branch | `engine_mode.{h,cc}`, `web_contents_view_delegate_mac.{h,mm}` | `chrome_content_browser_client.cc` (~5) | 250 / 5 | medium |
| S2 | TabRegistry + TabSession core + delegate skeleton | `tab_registry.{h,cc}`, `tab_session.{h,cc}`, `tab_delegate.{h,cc}` | none | 800 / 0 | low |
| S3 | Observer + navigation event surface | `tab_observer.{h,cc}`, `ipc_tab_events.{h,cc}` | none | 450 / 0 | low |
| S4 | Native content host + attachment lease | `content_host_mac.{h,mm}`, `attachment_lease.{h,cc}` | none | 500 / 0 | low-medium |
| S5 | Service adapters (favicon, media, security, JS-dialog) | `favicon_adapter.{h,cc}`, `media_adapter.{h,cc}`, `security_adapter.{h,cc}`, `rearc_javascript_dialog_manager.{h,cc}` | none | 600 / 0 | medium |
| S6 | Adoption + close/disposition policy | `tab_adoption.{h,cc}`, `close_controller.{h,cc}` | none | 450 / 0 | medium-high |
| S7 | (deferred, optional) Discard adapter | `discard_adapter.{h,cc}` | none | 400 / 0 | high |

Sum: ~3,450 additive LOC upper bound (P-TAB-001 budgets 1,600–3,000 + tests;
S7 is explicitly out of the baseline budget, and S2/S5 carry the audit
contingency). Upstream-hunk total: ~5 LOC in one file, well inside the
30–120 budget with headroom for service-hook findings during S5 audits.

### S1 — Embedded-mode flag + `GetWebContentsViewDelegate` branch (the first seam)

**Upstream anchors (verified):**
- `chrome/browser/chrome_content_browser_client.cc:1848-1852` —
  `ChromeContentBrowserClient::GetWebContentsViewDelegate(content::WebContents*)`
  currently just `return CreateWebContentsViewDelegate(web_contents);`.
  Override declared at `chrome/browser/chrome_content_browser_client.h:202`.
- Call sites in content (why the decision must be ambient, §3):
  `content/browser/web_contents/web_contents_impl.cc:4537` (inside
  `WebContentsImpl::Init`, function starts at 4459 — i.e. synchronously during
  `WebContents::Create`), plus 3476, 3629, 3662, 3775 (inner-WebContents
  attach/detach, plugin-guest embedding, view recreation).
- Stock desktop implementation (proof it is unusable browser-lessly):
  `chrome/browser/ui/views/tab_contents/chrome_web_contents_view_delegate_views.cc:40-43`
  resolves `GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(...)`
  → always null in registry mode; its context-menu path (same file, :104) is
  Views-based.
- Factory declaration we keep for the stock path:
  `chrome/browser/ui/tab_contents/chrome_web_contents_view_delegate.h:15`.
  **Drift note for the spec:** P-TAB-001's map warns "mac implementation
  filenames may differ" — confirmed: there is no
  `chrome_web_contents_view_delegate.cc` under `chrome/browser/ui/tab_contents/`
  at this pin; desktop (incl. macOS) uses the Views implementation above,
  Android has its own. Record in P-TAB-001 drift log when S1 lands.

**Additive:**
- `engine_mode.{h,cc}` — `rearc::SetEngineEmbeddedMode(bool)` /
  `rearc::IsEngineEmbeddedMode()` over a `std::atomic<bool>` defaulting to
  false (stock behavior preserved for upstream tests). Set true from the
  bridge lifecycle entry point established by P-APP-001 slice 1
  (`rearc_engine_entry_mac.mm`); cleared during bridge shutdown.
- `web_contents_view_delegate_mac.{h,mm}` — `ReArcWebContentsViewDelegate :
  content::WebContentsViewDelegate` (interface:
  `content/public/browser/web_contents_view_delegate.h`, full surface audited
  — 14 virtuals, all with safe defaults). Initial implementation:
  `GetNativeWindow()` → consults TabRegistry attachment lease (returns nil
  until S4 wires the lease; a null NativeWindow is the documented "not in any
  window" state); `StoreFocus`/`RestoreFocus`/`Focus`/`TakeFocus` → AppKit
  first-responder routing via the lease; `ShowContextMenu` → forward to shell
  over the in-process side channel (IPC-CONTRACT §6 typed channel), fallback
  dismiss; `GetDelegateForHost` → nil (audited: responder-chain extras, not
  required for presentation); `GetDragDestDelegate` → nullptr (content
  default); drop callbacks deny politely.

**Hunk (sketch, ~5 LOC):**
```cpp
  if (rearc::IsEngineEmbeddedMode()) {
    return rearc::CreateReArcWebContentsViewDelegate(web_contents);
  }
  return CreateWebContentsViewDelegate(web_contents);
```

**Rebase risk: medium.** `chrome_content_browser_client.cc` is a hot file,
but the hunk sits inside a 4-line function body with a stable signature;
conflict probability per bump is low, semantic drift risk is the real cost
(re-verify the five content call sites each bump).

**Compile gate:** incremental build exit 0; §6 nm checks.

### S2 — TabRegistry + TabSession core + delegate skeleton

**Upstream anchors (verified):**
- `content/public/browser/web_contents.h:409` — `WebContents::Create(const
  CreateParams&)`; `CreateParams` same header. `:484` `SetDelegate`;
  `:1031/:1032` `WasShown`/`WasHidden`; `:1040` `GetVisibility`;
  `:672` `ClosePage`; `:1071` `DispatchBeforeUnload(bool auto_cancel)`.
- `content/public/browser/web_contents_delegate.h` — full interface; the
  skeleton implements the safe-deny subset below.

**Additive:**
- `tab_registry.{h,cc}` — owns monotonic `tab_id` allocation (engine-side per
  IPC-CONTRACT §3), `TabSession` map, FIFO command application, teardown
  ordering (all sessions destroyed before profile release — P-TAB-001 §
  "Additive implementation"). UI-thread only.
- `tab_session.{h,cc}` — owns one `std::unique_ptr<content::WebContents>`,
  its delegate/observer/subscriptions, profile keepalive reference, shell
  space/order metadata, close-state machine, content-generation counter, and
  at most one attachment lease. Never exposes a `WebContents*` across the
  bridge boundary (opaque `tab_id` only).
- `tab_delegate.{h,cc}` — `ReArcTabDelegate : content::WebContentsDelegate`
  skeleton: every override P-TAB-001 lists is present from day one with an
  audited safe default (deny/cancel/no-op-with-explicit-policy), upgraded to
  real routing in S3/S6. This satisfies R7: observation alone is not a tab —
  the delegate surface exists before any observer ships, so unsupported
  operations are cancelled through upstream callbacks rather than hanging.

**Helper policy (R6):** no `TabHelpers::AttachTabHelpers`
(`chrome/browser/ui/tab_helpers.cc` — legacy, warns against desktop use), no
`TabFeatures`. Whitelisted helpers get individual `CreateForWebContents` calls
in `tab_session.cc`, each recorded in the patch header. First whitelist
candidate: `CoreTabHelper` (`chrome/browser/ui/tab_contents/core_tab_helper.h`).
The 110 `TabLookupFromWebContents` references in `chrome/browser` (predominantly
tests and browser-bound helpers) are the audit filter: any helper that
resolves a `TabInterface` from the WebContents is excluded unless §2's
contingency adapter lands.

**Rebase risk: low** (additive only; public content API is the most stable
surface in the tree).

### S3 — Observer + navigation event surface

**Upstream anchors (verified):**
- `content/public/browser/web_contents_observer.h` — `TitleWasSet`,
  `DidStartLoading`/`DidStopLoading`, `LoadProgressChanged`,
  `DidFinishNavigation`, `PrimaryMainFrameRenderProcessGone`,
  `WebContentsDestroyed`, `OnAudioStateChanged`,
  `DidChangeVisibleSecurityState`, `DidUpdateFaviconURL`.
- Navigation filter per IPC-CONTRACT §4:
  `NavigationHandle::IsInPrimaryMainFrame() && HasCommitted()`.

**Additive:** `tab_observer.{h,cc}` (per-session `WebContentsObserver`),
`ipc_tab_events.{h,cc}` (serialization of `tab.created`/`tab.updated`/
`tab.closed`, `navigation.committed`/`navigation.failed` per IPC-CONTRACT
§§3–4, generation-counter rejection of late completions).

**Rebase risk: low.**

### S4 — Native content host + attachment lease

**Upstream anchors (verified — no accessor patch needed, R8):**
- `content/public/browser/web_contents.h:1241` — `virtual gfx::NativeView
  GetNativeView() = 0;` public, CONTENT_EXPORT.
- `content/browser/web_contents/web_contents_view_mac.h:71-72` —
  `GetNativeView()` (stable content container) vs `GetContentNativeView()`
  (render-widget view; nil-able, changing — never a lifetime anchor).
- `gfx::NativeView::GetNativeNSView()` — public accessor for the NSView.
- `WebContents::Discard(base::OnceClosure)` at `web_contents.h:870` (S7 only).

**Additive:**
- `content_host_mac.{h,mm}` — `ReArcContentHostView : NSView`, the stable
  bridge-owned wrapper the shell embeds via `NSViewRepresentable`
  (`WebEngine.makeView()`). Installs `GetNativeView()`'s NSView as an
  autoresized child without touching its layers; applies AppKit point bounds
  and the real window's backing scale.
- `attachment_lease.{h,cc}` — implements IPC-CONTRACT §6: one live attachment
  per tab, `attachment_id` allocation, `view.attach/detach/resize/set_visible/
  invalidated` semantics, lease invalidation before content destruction or
  replacement, retained-empty-host safety for SwiftUI dismantle races.

**Rebase risk: low-medium** (additive; the only upstream coupling is the
documented public `GetNativeView` contract).

### S5 — Service adapters

**Upstream anchors (verified):**
- Favicon: `chrome/browser/favicon/favicon_utils.h:29`
  `CreateContentFaviconDriverForWebContents`;
  `components/favicon/content/content_favicon_driver.h` (completion
  observation; PNG encode per IPC-CONTRACT §7).
- Media: `content/public/browser/media_session.h:33`
  `MediaSession::Get(WebContents*)`, `:37` `GetIfExists`, `:141` `AddObserver`
  — per-tab sessions, no new mojom.
- Security: `chrome/browser/ssl/chrome_security_state_util.h:23`
  `GetVisibleSecurityState`, `:27` `GetSecurityLevel` — report unknown until
  valid; never derive "secure" from the URL scheme.
- JS dialogs: `WebContentsDelegate::GetJavaScriptDialogManager` override in
  `tab_delegate.cc` returning `rearc_javascript_dialog_manager` — conservative
  beforeunload confirmation cancellation until native UI exists (IPC-CONTRACT
  §3 close policy; P-TAB-001: "returning null alone is not proof of that
  policy").

Each adapter is a separate commit inside the slice so a failed service audit
reverts cleanly. **Rebase risk: medium** — favicon/security util dependencies
migrate between milestones; audit per bump.

**Landed in wave 8 (2026-11-02), Chromium 156.0.8078.74:**

| Patch | Commit | Green build log (under engine/) | G1–G5 |
|---|---|---|---|
| `tab/010-service-events-favicon-adapter.patch` | `412dcd8253` | `build-p10.log` attempt 1; final `build-p11.log` attempt 2 | PASS |
| `tab/011-media-session-adapter.patch` | `b104f5157b` | `build-p12.log` attempt 1 | PASS |
| `tab/012-visible-security-state-adapter.patch` | `39b9d30e12` | `build-p13.log` attempt 1 | PASS |
| `tab/013-conservative-javascript-dialog-manager.patch` | `f80b69720d` | `build-p14.log` attempt 1; final `build-p15.log` attempt 2 | PASS |

No compile failures. Favicon's second green build adds teardown guards and
formatting; the dialog second build only corrects include order. Every final
binary passed all five smoke gates with a fresh profile per gate, the 45 s
watchdog, default sandbox, and `pgrep -fl "siso ninja"` empty before each run.
G3 uses `LC_ALL=C grep -qa PNG`. Logs: `smoke-tab010-final.log`,
`smoke-tab011.log`, `smoke-tab012.log`, `smoke-tab013.log`. Symbols and pinned
`--version` verified. These smoke gates exercise the built browser, **not**
browser-less service attachment; real-profile service/Cocoa integration tests
remain for the integration wave. No S6 work landed.

Implementation and drift from the estimate/previous untracked attempt:

- Added `ipc_service_events.{h,cc}` because tab/008's event files are frozen.
  Favicon/security map to `tab.updated` changes; media maps to
  `media.state_changed`. The sink rejects unknown, closed, destroying and
  stale-generation sessions using the generation captured at attachment,
  rather than restamping a late completion. This remains typed scaffolding;
  wire serialization/capability advertisement is not installed.
- Favicon admits only `ContentFaviconDriver` through the profile-backed
  `CreateContentFaviconDriverForWebContents`; no mass helper initialization.
  Verified the exact five-argument `FaviconDriverObserver::OnFaviconUpdated`
  and `PNGCodec::EncodeBGRASkBitmap(const SkBitmap&, bool)` returning optional
  bytes. The previous URL-only deduplication was incorrect: unchanged URLs
  can carry refreshed pixels. It is removed. Primary-page changes clear the
  presentation/cache before the driver starts the new navigation fetch; the
  upstream handler cancels old-page requests. PNGs use decoded bitmaps only.
  A 16-entry cache, <=64 KiB per PNG, <=256x256 encode input and random opaque
  refs replace the unbounded cache/ref counter. Evicted/stale/foreign refs
  return `not_found`; retrieval checks `max_blob_bytes` and returns
  `too_large`; oversized/failed observer encodes emit the cleared form.
- Adapter ownership uses `WebContentsUserData` plus teardown observation,
  avoiding a global map and deferred tab-id cleanup. Favicon unregisters its
  driver before user-data deletion; media resets its Mojo receiver, dropping
  queued callbacks; security removes observation. Attach/detach seams are
  idempotent and **dormant**: frozen registry/session files are unchanged.
- Media uses the existing five-method `MediaSessionObserver` interface, no
  new mojom. Inactive sessions report stopped; other playback uses the
  upstream playback enum; null/disconnected state is unknown. WebContents
  audibility/mute are independent. Null metadata emits an empty table.
  Per-tab Resume/Suspend use kUI and controllable/action checks; mute uses
  WebContents directly. Artwork and native PiP remain unsupported with both
  PiP flags false; no globally focused session is controlled.
- Security maps `chrome_security_state::GetSecurityLevel` only:
  NONE→none, SECURE→secure, WARNING→insecure, DANGEROUS→dangerous;
  unrecognized/sentinel→unknown. Missing/initial visible entries and
  uninitialized connection info are unknown, conservatively including early
  verdicts until initialization. The util's optional helper reads were
  audited; no helper or browser/window object is instantiated. No URL-scheme
  inference appears in the adapter.
- The planned `tab_delegate.cc` override now returns a per-WebContents
  `ReArcJavaScriptDialogManager`. Ordinary dialogs complete cancellation
  exactly once (`did_suppress_message=false` prevents content synthesizing
  another response). Beforeunload/reload confirmations complete false/stay.
  No pending callback or dialog survives cancellation/teardown. Close replies,
  unload sequencing and S6's controller remain deferred; this slice does not
  implement `tab.close.reply`.
- GN sources remain in mac `:core`, keeping app/002's bridge BUILD.gn frozen.
  The shared service-event surface and explicit lifecycle/cache/command
  policies bring the slice above the original ~600 LOC estimate. The only
  existing bridge implementation edited is the explicitly planned dialog
  override (one include + body); its header and frozen session/registry/event
  files stay unchanged.
- Patch integrity uses the permitted **sequential** newest-first reverse
  check/application in a temporary Git index, then forward replay. All 13
  patches reverse to the exact pinned upstream tree and replay to the exact
  final HEAD tree (`replay-s5.log`); the real working tree/index are untouched.
  Sequential reversal is required because adapter 013 intentionally edits
  tab/007's additive delegate implementation. Do not interpret an isolated
  reverse check of tab/007 against the fully applied tree as this replay test.

### S6 — Adoption + close/disposition policy

**Additive:** `tab_adoption.{h,cc}` (`AddNewContents` adoption of the
Chromium-created `unique_ptr` — preserving opener, BrowserContext,
disposition; hidden-staging or predictable rejection of unsupported window
dispositions), `close_controller.{h,cc}` (one pending close per tab;
`DispatchBeforeUnload` → honor veto → `ClosePage` → await `CloseContents`;
forced-close path that still detaches native children and cancels observers;
deferred destruction scheduled after delegate/observer callbacks unwind —
P-TAB-001's destruction-from-callback prohibition).

**Rebase risk: medium-high** — behavior semantics (dispositions, popup policy)
evolve even though the delegate API surface is stable.

**Landed in wave 9 (2026-11-02), Chromium 156.0.8078.74:**

| Patch | Commit | Green build log (under engine/) | G1–G5 |
|---|---|---|---|
| `tab/014-adopt-created-tab-contents.patch` | `44f65e0a21` | `build-p17.log` attempt 2 | PASS |
| `tab/015-serialized-close-controller.patch` | `47a9442a50` | `build-p18.log` attempt 1 | PASS |

Adoption's first attempt (`build-p16.log`) found a default `unique_ptr`
argument requiring a complete WebContents type in the header; moving it into
the implementation fixed the build. Final smoke logs: `smoke-tab014.log`,
`smoke-tab015.log`. Every gate used a fresh profile, default sandbox, the
45-second watchdog and an empty `pgrep -fl "siso ninja"` result. G3 uses
`LC_ALL=C grep -qa PNG`. The initial adoption smoke run stopped before G3
because pgrep matched a reviewer's command line containing the build pattern;
`smoke-tab014-initial.log` preserves it. A fresh complete run passed. Linked
adoption/close symbols and close-policy strings were verified; upstream API
grep evidence is in `api-s6.log`.

Implementation and drift:

- Adoption transfers the exact Chromium-created unique_ptr into a new session,
  retaining BrowserContext, SiteInstance, renderer state and opener suppression.
  Foreground/background tabs and popups require content-supplied user gesture
  and stage hidden synchronously, with no inferred native window or focus.
  NEW_WINDOW, PiP/split, profile changes and other dispositions are rejected
  with `was_blocked=true`; accepted contents set it false. Popup bounds are
  deliberately not applied while staged. URL-only OpenURLFromTab creation
  remains rejected rather than fabricating script-opener semantics.
- Typed `tab.created` gains opener/disposition fields; suppressed openers are
  omitted. Creation precedes observation and the initial snapshot. Profile ID
  stamping, transport/correlation and capability advertisement remain the
  integration wave's responsibility, as in S3/S5; internal profile_id=0 events
  must not be sent directly on the wire. S5 service attachment remains dormant.
- One pending close per tab, including force requests: concurrent requests
  return busy. A normal close dispatches beforeunload with auto_cancel=false;
  S5's false/stay result posts exactly one cancelled callback. On acceptance,
  the controller posts ClosePage and waits for CloseContents. At this pin,
  returning true in BeforeUnloadFired would make RenderFrameHostManager call
  ClosePage too, so the delegate suppresses that automatic path. Replies are
  typed callbacks for the future transport, with closed following tab.closed.
- **Unresponsive policy chosen explicitly:** Chromium's built-in timeouts
  apply (BeforeUnloadTimeout simulates proceed=true); a 30-second total
  deadline forces cleanup if completion never arrives. A requested S5
  confirmation still cancels immediately. This resolves the implementation
  policy left open by the contract/review without adding native dialog UI.
- Forced/raw registry destruction and shutdown races use a posted finalizer,
  retaining a pending close's callback and initiating reason. It cancels S3
  observation, S5 service subscriptions and dialogs, invalidates the native
  lease with `tab_closed`, clears the delegate, destroys contents, then emits
  one final tab.closed (shell/page/engine reason) before replying. Renderer
  window.close closes a tab with page reason; shell window.closed remains the
  distinct detach/hide operation. Posted work carries only IDs/generations.
- **Minimal frozen-file exceptions, justified in each patch header:** 014 adds
  the missing session/registry unique_ptr adoption seam and typed creation
  fields; explicit initially_hidden corrects S2's assumption (the upstream
  default is false). 015 routes the registry/delegate lifecycle seams and adds
  one closed-state AttachView check so a reentrant invalidation sink cannot
  reinstall a native child. Deferring only content destruction would still
  delete an observer inside its callback, so cleanup/removal are deferred too.
  S1/S3/S5 implementations and app/002's bridge BUILD.gn remain unchanged;
  both source pairs have isolated mac :core GN blocks. No upstream C++ edits.
- All **15** patches sequentially reverse-check/apply to the exact pinned
  tree and forward-check/replay to HEAD `47a9442a50`, tree
  `1f488810db19daee27b429310b703568a69e0253` (`replay-s6.log`). The real index
  and working tree were untouched by replay.

G1–G5 exercise the linked browser, not browser-less adoption, beforeunload or
Cocoa race behavior. Focused real-profile/browser-less and native-host tests
remain integration requirements. Deferred destruction still requires the
caller to retain profiles and drain UI tasks before profile teardown; the
existing startup/shutdown transport wiring is unchanged. No S7 or shell work
was started.

### S7 — Discard adapter (optional; landed wave 18d)

Implemented by `tab/043-preserving-tab-discard.patch`; see §8 wave 18d.
The preserving path retains WebContents/lease/content generation and needs no
replacement fallback. Only if `tab_discard` is advertised. `WebContents::Discard(base::OnceClosure)`
(`web_contents.h:870`) and the feature-controlled preserving path — **never**
`TabLifecycleUnitSource::TabLifecycleUnit`
(`chrome/browser/resource_coordinator/tab_lifecycle_unit.cc`), which has
TabStripModel dependencies (P-TAB-001: "Do not call it with a null
TabStripModel"). Replacement fallbacks must invalidate leases (S4), retain
tab ID/navigation state, reattach helpers. ~250–600 LOC + tests per spec.
Do not schedule before S6 lands and its tests exist to reuse.

---

## 2. Centerpiece: BrowserWindowInterface — adapter vs browser-less registry

**Decision: browser-less registry. No `TabStripModel`, no `tabs::TabModel`,
no `TabFeatures`, no `BrowserWindowInterface` adapter.**

### The exact CHECK sites (verified at pin)

1. `chrome/browser/ui/tabs/tab_features.cc:276` —
   `CHECK(tab.GetBrowserWindowInterface());` inside
   `void TabFeatures::Init(TabInterface& tab, Profile* profile)` (function
   begins at :269). This is the hard gate.
2. `chrome/browser/ui/tabs/tab_model.cc:70-72` — `tab_features_->Init(*this,
   Profile::FromBrowserContext(contents_->GetBrowserContext()))` inside the
   `TabModel` constructor (:52), guarded only by
   `g_disable_tab_feature_initialization` (:47, test-only).
3. `chrome/browser/ui/tabs/tab_model.cc:310-315` —
   `TabModel::GetBrowserWindowInterface()` returns
   `GetModelForTabInterface()->delegate()->GetBrowserWindowInterface()` when
   owned, else nullptr. So the CHECK dereferences **through TabStripModel's
   delegate**.
4. `chrome/browser/ui/tabs/tab_strip_model.cc:356` and `:1711` —
   `std::make_unique<tabs::TabModel>(std::move(contents), this)`: any
   TabStripModel insertion constructs a TabModel, which fires (2), which
   reaches (1).
5. Further BrowserWindowInterface uses inside `TabFeatures::Init` itself:
   `tab_features.cc:312` (`GetActivePageActionIds(*tab.GetBrowserWindowInterface())`),
   :375-376 (`GetType() == TYPE_NORMAL`), :977/:987 (`GetProfile()`).

### Why the adapter route loses

Reaching `TabFeatures::Init` with a non-null BrowserWindowInterface requires:
- a `TabStripModel` (`tab_strip_model.h:216`, ctor takes
  `TabStripModelDelegate*`), whose delegate interface is **38 virtuals**
  (`chrome/browser/ui/tabs/tab_strip_model_delegate.h`, 255 lines), and
- that delegate's `GetBrowserWindowInterface()` returning an object
  implementing **31 virtuals** (`chrome/browser/ui/browser_window/public/
  browser_window_interface.h`, 342 lines): window type, tab strip model,
  features, profile, active/visible state, migration, exclusive-access…

That is ~69 virtual methods of *browser window* semantics to implement for an
architecture that has no browser window. The orchestrator's constraint — **no
null-CHECK no-ops** — rules out stubbing them; a honest implementation of most
of them is impossible without a Browser, and a dishonest one is exactly the
"fake window object" failure mode R6 warns about ("No production
null-check/test-only TabFeatures bypass is proposed"). The testing bypass
(`TabModel::PreventFeatureInitializationForTesting`, `tab_model.h:188`,
`tab_model.cc:370`) is explicitly test-only and equally forbidden in
production.

### Why the registry route wins against R6–R8

- **R6** demands we stop pretending the modern desktop tab pipeline is freely
  reusable and forbids CHECK bypasses. The registry complies by *never
  reaching the CHECK*: `TabSession` owns `content::WebContents` directly
  (`WebContents::Create`, `web_contents.h:409`), and the service glue is
  replaced explicitly — whitelisted per-helper `CreateForWebContents` calls
  (S2), our own delegate (S2/S6), our own view delegate (S1), our own
  adapters (S5). The spec's own map already marks TabStripModel/TabModel/
  TabInterface/TabFeatures as "inspect for semantics, do not patch or
  instantiate."
- **R7** demands real delegate/service behavior, which the adapter route
  would not provide either — TabFeatures gives us page-action controllers and
  side-panel registries for a toolbar that does not exist, while the actual
  required surface (JavaScript dialogs, security state, permissions, file
  chooser, downloads, external protocols) still needs per-service auditing.
  Registry + explicit whitelist is the same audit, without the fake window.
- **R8** is orthogonal and satisfied by S4: the lease anchors on public
  `WebContents::GetNativeView()` (`web_contents.h:1241`; container override at
  `web_contents_view_mac.h:71`), never on `GetContentNativeView()`/
  `RenderWidgetHostViewMac`. **No accessor patch is needed** — verified by
  reading the public headers at the pin.

### Cost accounting (what we give up, honestly)

`TabFeatures` instantiates ~30 controllers (page actions, side panel,
app-banner, translate/memory-saver/intent-picker chips, lens, …). ReArc's
shell replaces the visible surfaces of nearly all of them (SIDEBAR-SPEC: the
sidebar, not a toolbar, is the chrome). Features we *do* need — favicon,
media, security state, find-in-page later — are re-attached individually in
S5. Residual risk: a future needed service that hard-requires a `TabInterface`
(found via the 110-reference `TabLookupFromWebContents` audit). **Contingency
(R6-compliant):** an additive `tabs::TabInterface` implementation owned by
TabSession plus an additive lookup install — a real implementation of a public
interface, not a CHECK bypass. Decide per-service in S5 audits; do not build
speculatively.

---

## 3. First seam: `GetWebContentsViewDelegate` embedded-mode branch

### Why ambient mode, not per-tab tagging

`WebContentsImpl::Init` (`web_contents_impl.cc:4459`) fetches the view
delegate at :4537, synchronously inside `WebContents::Create`, before the
caller regains control. A post-Create tag (`SetUserData`, registry insert) is
too late (P-TAB-001 already warns this). The four later call sites
(:3476/:3629/:3662/:3775 — inner-WebContents and view-recreation paths) must
make the *same* decision, so the discriminator cannot be per-call-site either.
An ambient engine-mode flag is the only design that is correct at all five
sites without patching content/. ReArc never creates Chrome `Browser` windows,
so a process-wide flag loses nothing.

### What the shell's view delegate must provide

Mapped from `content/public/browser/web_contents_view_delegate.h` (full read
at pin) to the shell seam:

| Delegate method | ReArc behavior |
|---|---|
| `GetNativeWindow()` | NSWindow of the tab's live attachment lease (S4); nil = documented "not in any window" |
| `ShowContextMenu` / `DismissContextMenu` | Forward to shell over the typed in-process side channel (IPC-CONTRACT §6); shell renders AppKit menu per SIDEBAR-SPEC §4.9 vocabulary |
| `StoreFocus`/`RestoreFocus`/`ResetStoredFocus`/`Focus()`/`TakeFocus(reverse)` | AppKit first-responder round-trip through the lease's host view; composes with `WebEngine.makeView()`'s `NSViewRepresentable` |
| `GetDelegateForHost(rwh, is_popup)` | nil initially (responder-chain extras); audit before enabling |
| `GetDragDestDelegate()` | nullptr (content default drag handling); bookmark-handler interception is a Chrome-browser feature, out of scope |
| `OnPerformingDrop` / `WebContentsDragEnded` | Complete the callback with std::nullopt (abort) until shell drop policy exists — explicit cancellation, never a hung callback (R7) |

### Composition with `WebEngine.swift`

The shell protocol is per-tab (`One engine instance exists per tab`), with
`makeView() -> AnyView` as the presentation seam and
navigation/media/boosts/snapshot as the behavior surface. The mapping:

- One `WebEngine` conformance ⇔ one `TabSession` (S2) ⇔ one `tab_id`.
- `makeView()` ⇔ `NSViewRepresentable` wrapping the S4 bridge host view,
  keyed by `attachment_id`; the lease rules (one live attachment, invalidate
  before replacement) are exactly what `NSViewRepresentable.makeNSView/
  dismantleNSView` races require.
- `currentURL/pageTitle/isLoading/canGoBack/canGoForward` ⇔ S3 observer
  events (push) with the registry as source of truth (pull at attach).
- `mediaState`, `setMuted/togglePlayPause/...` ⇔ S5 media adapter
  (`content::MediaSession::Get` per WebContents).
- Context menus, focus traversal, link-peek (`linkPeekHandler`) ⇔ S1 view
  delegate + side channel.
- `captureSnapshot` ⇔ `WebContents::CaptureSnapshot` (content public API; no
  hunk), routed per-tab.

This keeps the protocol unchanged: the Chromium-backed `WebEngine`
implementation drops in without touching the chrome, as its doc comment
already promises.

---

## 4. WebContentsDelegate routing + native-view handoff

### Routing design (shell is the delegate of all tabs)

- **One `ReArcTabDelegate` instance per `TabSession`**, not a singleton: close
  serialization, generation counters and adoption state are per-tab
  (P-TAB-001 close ordering rules), and delegate callbacks carry no tab
  identity beyond the `WebContents*` — the owning session is the natural
  dispatch key. The *shell* is the logical delegate of every tab; the
  delegate objects are its per-tab transducers into `rearc.ipc.v1`.
- Day-one override set (S2 skeleton → S3/S6 upgrades):
  `OpenURLFromTab`, `AddNewContents`, `ActivateContents`, `IsContentsActive`,
  `CloseContents`, `BeforeUnloadFired`, `NavigationStateChanged`,
  `LoadingStateChanged`, `TakeFocus`, `GetJavaScriptDialogManager`.
- `ActivateContents` obeys focus/gesture policy (no focus stealing);
  `AddNewContents` adopts the created `unique_ptr` and establishes a valid
  native parent or a deliberate hidden staging state before returning —
  a later SwiftUI update is not synchronous reparenting (P-TAB-001 step 3).

### Native-view handoff (stable lease)

- The engine owns the WebContents and its `GetNativeView()` child; the shell
  leases a stable bridge host NSView (S4). IPC-CONTRACT §6 verbatim rules the
  lease implements: one live attachment per tab; empty the host before content
  destruction; a WebContents replacement invalidates the lease *before*
  replacement and requires reattachment; no NSView over XPC (typed in-process
  side channel).
- **Accessor verification (cite, R8):** `WebContents::GetNativeView` public
  pure virtual, `content/public/browser/web_contents.h:1241`; container
  override `content/browser/web_contents/web_contents_view_mac.h:71`;
  `gfx::NativeView::GetNativeNSView()` public. **No accessor patch needed.**
- Never cache renderer-side views (`GetContentNativeView`,
  `web_contents_view_mac.h:72`) across process swaps/crashes; the container
  handles renderer-view replacement internally; generation-check genuine
  WebContents replacement separately.

---

## 5. Dependency mapping: P-APP-001 slices → P-TAB slices

P-APP-001 remaining work (from its patch map, wave-5 numbering pending;
referenced by seam name):

| P-APP-001 work item | Upstream seam | Needed before |
|---|---|---|
| s2 — PreCreateThreads delegate/menu install (`InstallReArcAppDelegateAndMenu`) | `chrome/browser/chrome_browser_main_mac.mm:151-166` | P-TAB **S4** runtime (windows/first responder), **S1** runtime |
| s3 — PreMainMessageLoopRun embedded-mode readiness + profile startup/keepalive | `chrome/browser/chrome_browser_main.cc` (`PreMainMessageLoopRunImpl`) | P-TAB **S2** runtime (needs loaded `Profile*`/BrowserContext via proper keepalive) |
| s4 — DidEndMainMessageLoop finalization + keepalive release | `chrome/browser/chrome_browser_main_mac.mm:184-185` | P-TAB **S2** runtime (registry teardown hooks engine shutdown; sessions die before profile release) |

Compile-time, every P-TAB slice needs only what patch 002 already shipped
(the `rearc_bridge` GN target and its dep from `chrome/browser/BUILD.gn`).
Runtime validation of S1/S2/S4 additionally needs the P-APP-001 rows above;
wave 6 should not attempt live-tab validation against a tree where s2–s4 are
unlanded. S3/S5 adapters are test-harness-validatable (Chromium task
environment + real loaded Profile, no Browser/BrowserView/TabStripModel —
P-TAB-001 test plan) and can land ahead of s2 if scheduling requires.

---

## 6. Per-slice validation plan (nm / strings / --version level; no interactive runs)

All gates run against `out/ReArc-dev-arm64/libchrome_dll.dylib` (the real code
in this component build; the "Chromium Framework" binary is a 16 KB re-export
stub). Known toolchain caveat from wave 1: `nm -gU` has given false-empty
output on this dylib — cross-check with `nm -m` and `dyld_info -exports`.

| Slice | Compile gate | Symbol/static checks | Patch integrity |
|---|---|---|---|
| S1 | `autoninja -C out/ReArc-dev-arm64 chrome` exit 0 | `nm -m libchrome_dll.dylib \| grep -i rearc` shows `ReArcWebContentsViewDelegate` ObjC class + `rearc::IsEngineEmbeddedMode` T symbols; `nm -m ... \| grep GetWebContentsViewDelegate` unchanged signature | `git apply --check -R` on the new patch; PATCH-LOG entry |
| S2 | build exit 0 | `nm -m` shows `rearc::TabRegistry`/`TabSession`/`ReArcTabDelegate` T symbols | `--check -R`; series updated |
| S3 | build exit 0 | `strings libchrome_dll.dylib \| grep -c "tab.created\|navigation.committed"` > 0 (event names are literals); nm observer symbols | as above |
| S4 | build exit 0 | nm shows `ReArcContentHostView` ObjC class; strings lease-invalidation log tags | as above |
| S5 | build exit 0 | nm shows the four adapter symbols; strings favicon PNG/log tags | as above |
| S6 | build exit 0 | nm adoption/close-controller symbols; strings close-policy log tags | as above |
| All | `--version` runs on the app bundle; worktree clean; overlay commit by `ReArc Overlay <rearc-overlay@localhost>` | — | `engine/patches/series` appended in order; FETCH-STATUS PATCH-LOG per patch |

Deeper validation (registry unit tests with a Chromium task environment,
integration tests with a real loaded Profile and no Browser, Cocoa harness in
the shell bundle) is inherited verbatim from P-TAB-001's "Test plan and exit
criteria" and belongs to the implementation waves, not this plan.

---

## 7. Hand-off notes for wave 6

1. Land order: S1 → S2 → S3 → S4 → S5 → S6; S7 only by explicit orchestrator
   scheduling. S5's four adapters may be parallelized across workers; S6 must
   not start before S4 (close paths touch leases).
2. Record the `chrome_web_contents_view_delegate.cc` filename drift (§1/S1)
   in P-TAB-001's drift log when S1 lands.
3. The `PreventFeatureInitializationForTesting` bypass and any
   null-CHECK no-op remain forbidden (orchestrator constraint; R6).
4. Do not expose `content::WebContents*` across the bridge boundary at any
   slice; `tab_id`/`attachment_id` only (IPC-CONTRACT §1).
5. Never disable sandboxing or site isolation to make any slice compile or
   run (ENGINE invariants).
6. Coordinate on `engine/patches/series` and `engine/docs/FETCH-STATUS.md`:
   single writer per wave, PATCH-LOG appended per patch, both verified with
   `git apply --check -R` before hand-back (wave-1 protocol).

---

## 8. Drift log (implementation waves append here, newest last)

### S1 landed (2026-11-02) — `tab/006-embedded-mode-view-delegate.patch`, commit `526c989d9c`

- **Derived predicate instead of the atomic-flag sketch.** §1/S1 called for
  `rearc::SetEngineEmbeddedMode(bool)` over a `std::atomic<bool>`, set from
  `rearc_engine_entry_mac.mm` and cleared at bridge shutdown. That file is
  created by patch app/002 and is frozen by the wave-5 series-mechanics
  invariant (a new-file patch cannot reverse-apply once its files carry later
  modifications, so later patches never edit earlier patches' files) — no
  legal setter site exists. Shipped: `IsEngineEmbeddedMode()` derives the
  mode from `GetEngineLifecycleHost() != nullptr`, the same source of truth
  every P-APP-001 gate already uses. Semantics identical to the planned flag
  (host installed at entry ⇒ embedded for the process lifetime; absent ⇒
  standalone); stock behavior bit-identical when no host is installed. Main
  thread only, matching the lifecycle host's contract.
- **Provider seam in place of the direct TabRegistry consult.** §1/S1
  sketched `GetNativeWindow()` consulting "TabRegistry attachment lease".
  S1 compiles before S2 exists (slices must not require later slices'
  symbols), so the delegate answers through a registered
  `ReArcNativeWindowProvider` per WebContents; S4's lease registers
  providers additively without modifying S1's file. Nothing is registered
  day-one ⇒ nil "not in any window" state, as planned.
- **Platform guards.** `chrome_content_browser_client.cc` compiles on all
  platforms while the seam sources are mac-only; the include block and the
  branch are `#if BUILDFLAG(IS_MAC)`-guarded (~9 LOC vs the ~5-LOC unguarded
  sketch).
- **Anchor drift.** `GetWebContentsViewDelegate` body sits at
  `chrome_content_browser_client.cc:1846-1850` at the pin (plan: 1848-1852).
  Declaration verified at `chrome_content_browser_client.h:202`.
- **Class is C++, not ObjC.** §6's validation table expects a
  "`ReArcWebContentsViewDelegate` ObjC class"; the delegate is a plain C++
  class (in an anonymous namespace inside the `.mm`, which is ObjC++ only so
  AppKit touches remain legal later). nm evidence: local (`t`) text symbols
  `rearc::(anonymous namespace)::ReArcWebContentsViewDelegate::*`, plus
  `rearc::IsEngineEmbeddedMode()` and the factory/registration functions.
  No new exported symbols (dyld_info cross-check; `framework.exports`
  untouched).
- **GN placement.** The 006 sources block joins `source_set("core")`'s
  `is_mac` sources between `icon_loader_mac.mm` and `memory_details_mac.cc`
  — deliberately NOT the alphabetical position (after
  `process_singleton_mac.mm`), which app/005's hunk occupies; the -U3
  context windows of 005 and 006 are disjoint. `chrome/browser/BUILD.gn`
  `:core` deps needed no additions (002's `//chrome/browser/rearc_bridge`
  edge covers the include of `rearc_engine_lifecycle.h`).
- **Build attempts.** Gate `engine/build-p6.log` green on attempt 4;
  attempts 1–3 were include-completeness fixes in the new files only:
  `ui/gfx/native_ui_types.h` (not the pre-rename `native_widget_types.h`),
  `content/public/common/drop_data.h` (DropData completeness),
  `base/functional/callback.h` (OnceCallback is only forward-declared by
  `web_contents_view_delegate.h`). No upstream-file changes resulted.
- **Area deviation.** New `engine/patches/tab/` area dir (app/ precedent),
  per the wave-6 brief; recorded in the patch header. The stale
  planned-inventory line `# chrome/003-tab-strip-shell-model.patch` in the
  series file was replaced by the `tab/` entries.
- §7 item 2 (record the `chrome_web_contents_view_delegate.cc` filename
  drift in P-TAB-001's drift log): **done at landing** — see P-TAB-001.md.

### S2 landed (2026-11-02) — `tab/007-tab-registry-session-delegate.patch`, commit `72e0da4ad3`

- **Helper whitelist empty day-one (R6 decision recorded).** §1/S2 names
  `CoreTabHelper` as the first whitelist candidate. It lives in
  `//chrome/browser/ui/tab_contents/`, and `source_set("core")` — where the
  bridge sources compile — cannot dep on `//chrome/browser/ui` (layering
  runs ui → core; the reverse edge would be a cycle). Attaching zero
  helpers is R6-compliant as-is (no legacy `AttachTabHelpers`, no
  `TabFeatures`, no testing bypass); the whitelist decision moves to the S5
  service-adapter audits, which either re-home TabSession in a target that
  may see the helper or pick helpers that live below the ui layer. Recorded
  in tab/007's patch header per this plan's "each recorded in the patch
  header" rule.
- **Profile keepalive reference is a borrowed pointer day-one.** §1/S2
  lists "profile keepalive reference" among TabSession's owns. The correct
  owner is `ScopedProfileKeepAlive`
  (`chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h`), but
  the lifetime contract belongs to the embedded-startup integration wave
  (who hands the registry a loaded `Profile*`/BrowserContext and when
  keepalives are released at shutdown). S2 ships the borrowed
  `BrowserContext*` plus the explicit teardown ordering
  (`DestroyAllSessions` before profile release) and records the dependency
  instead of faking a keepalive it cannot correctly own yet.
- **Attachment lease is external, not a member.** §1/S2 lists "at most one
  attachment lease" among TabSession's owns. tab/007's files freeze at
  landing (series-mechanics invariant), so S4 associates the lease through
  its own tab_id-keyed map in `attachment_lease.cc` — the same additive
  pattern S1 used for the native-window provider seam. Documented in
  `tab_session.h`'s class comment.
- **Registry teardown call site deferred.** `DestroyAllSessions()` ships as
  the teardown-ordering primitive, but its call site
  (`DidEndMainMessageLoop` finalization) lives in app/002's frozen
  `rearc_engine_entry_mac.mm` — the wiring arrives with a later slice via a
  new seam, same as every cross-slice hookup this wave.
- **OpenURLFromTab disposition policy.** The day-one skeleton routes
  `CURRENT_TAB` for real (content-shell minimal-embedder pattern,
  `shell.cc:473-478`: `LoadURLWithParams`, navigation-handle callback,
  return source) and rejects `NEW_POPUP`/`NEW_WINDOW`/`NEW_BACKGROUND_TAB`/
  `NEW_FOREGROUND_TAB`/`SINGLETON_TAB` plus
  `OFF_THE_RECORD`/`SAVE_TO_DISK`/`IGNORE_ACTION` with nullptr + VLOG —
  predictable rejection per P-TAB-001's "block unsupported window
  dispositions predictably"; adoption (preserving opener, BrowserContext,
  disposition, with a real native parent or deliberate hidden staging
  before returning) is S6.
- **AddNewContents sets `*was_blocked = true`.** Rejecting via nullptr
  destroys the moved-in WebContents on scope exit; setting the out-param is
  the honest "no tab was created" signal. Re-audit when S6's adoption lands
  (adopted paths must not leave it set).
- **API drift absorbed at the pin:** `NavigationController::LoadURLWithParams`
  returns `base::WeakPtr<NavigationHandle>` (the shell pattern uses the
  return value, not a `LoadURLParams.navigation_handle` out-member);
  `LoadingStateChanged(WebContents*, bool should_show_loading_ui)` is the
  two-arg form; `content::InvalidateTypes` lives in
  `content/public/browser/invalidate_type.h`; `WebContents::CreateParams`
  takes an optional `base::Location`.
- **GN placement.** The 007 sources block joins `source_set("core")`'s
  `is_mac` list between `browser_process_platform_part_mac.mm` and
  `chrome_browser_application_mac.mm` — disjoint -U3 windows from tab/006's
  block and app/005's block. No new deps (`//base`, content already in
  :core).
- **Build attempts.** Gate `engine/build-p7.log` green on attempt 2;
  attempt 1 added the `base::NoDestructor` friend declaration (private ctor
  pattern). No upstream-file changes resulted.
- **Validation (§6 row S2):** `nm -m` shows `rearc::TabRegistry` (full
  command/teardown API), `rearc::TabSession`, and `rearc::ReArcTabDelegate`
  (complete day-one override set) as local (`t`) symbols; safe-deny VLOG
  strings present; no new exported symbols; `--version` 156.0.8078.74.

### S3 landed (2026-11-02) — `tab/008-tab-events-observer.patch`, commit `5de707451d`

- **Sink-based scaffolding, not a wire format.** §1/S3's "typed tab event
  surface" ships as a `TabEvent` struct + `TabEventSink` registration seam
  (events drop with a VLOG until a sink registers) — the same pattern as
  app/005's readiness sink and tab/006's provider seam. The wire envelope
  (message_id, correlation, serialization) is the transport slice's; what S3
  guarantees is the event VOCABULARY and its emission rules, with the five
  wire names as string literals so the §6 strings gate keys on them.
- **Emission seams are free functions, not registry callouts.** §3's "no
  event precedes tab.created" ordering is enforced by call order at the
  (later) integration seam — `EmitTabCreatedEvent` then
  `AttachTabObserver` — because `TabRegistry::CreateSession` lives in
  tab/007's frozen file and cannot emit. Same additive pattern as every
  cross-slice hookup so far.
- **`kTabClosed` bypasses the unknown-session drop.** `EmitTabEvent` stamps
  the session's current generation and drops events for unknown/destroyed
  sessions — except `tab.closed`, which by definition races
  `DestroySession` (deferred destruction) and so carries the observer's
  last-known generation through. Recorded in `ipc_tab_events.h`.
- **`navigation_id` maps `NavigationHandle::GetNavigationId()`.** §4's
  "session-stable bridge ID mapped to a NavigationHandle lifetime; never a
  raw pointer, never retained" is satisfied by the handle's own
  session-unique int64 — no bridge-side handle-lifetime map needed day-one.
- **Crash-is-not-a-close and ERR_ABORTED-still-emits are explicit.** §3's
  renderer-crash rule surfaces as `is_crashed=true` from
  `PrimaryMainFrameRenderProcessGone` (tab stays open for shell-driven
  recovery); §4's cancellation rule emits `navigation.failed` for
  `net::ERR_ABORTED` rather than dropping it.
- **Observer self-detaches via posted task.** `WebContentsDestroyed` emits
  `tab.closed` (always final) and posts `DetachTabObserver` — no observer
  destruction inside a content callback (P-TAB-001's
  destruction-from-callback prohibition, same rule 007's deferred
  `DestroySession` follows).
- **API drift absorbed at the pin:** `WebContentsObserver::TitleWasSet`
  takes a `NavigationEntry*` (title read via `WebContents::GetTitle()`);
  `NavigationController::CanGoBack/CanGoForward` are non-const;
  `base::NoDestructor<TabEventSink*>` trips the trivial-type static_assert
  (a plain function-local static pointer is the legal form).
- **GN placement.** The 008 sources block sits between
  `"file_select_helper_mac.mm"` and `"fullscreen_mac.mm"`; its -U3 context
  overlaps tab/007's after-context only on lines neither patch changes
  (series-mechanics: context-only overlap permitted). No new deps.
- **Build attempts.** Gate `engine/build-p8.log` green on attempt 2;
  attempt 1 was the three compile errors above (trivial NoDestructor,
  non-const CanGoBack/CanGoForward). No upstream-file changes resulted.
- **Validation (§6 row S3):** all five event-name literals present exactly
  once in `strings libchrome_dll.dylib`; the seven S3 symbols
  (`EmitTabEvent`, `SetTabEventSink`, `TabEventKindName`,
  `AttachTabObserver`, `DetachTabObserver`, `EmitTabCreatedEvent`,
  `EmitInitialSnapshotEvent`) present as local symbols; no new exports;
  `--version` 156.0.8078.74.
- **Smoke gate first run (new this wave):** G1/G2/G4 PASS; G5 PASS 4/4 on
  isolated reruns after one transient FAIL in a back-to-back invocation.
  **G3 gate-command defect (build-independent):** the documented
  `head -c4 s.png | LC_ALL=C grep -q PNG` fails on this machine's BSD grep
  (0x89 byte ⇒ binary input ⇒ `-q` suppresses the match even under
  LC_ALL=C; reproduced with a synthetic file). Gate INTENT green: valid
  800×600 PNG produced, `LC_ALL=C grep -qa PNG` PASS consistently.
  Reported to the orchestrator for a SMOKE-TEST.md fix (needs `-a`).

### S4 landed (2026-11-02) — `tab/009-content-host-attachment-lease.patch`, commit `620cb7c68b`

- **Host is a plain NSView, deliberately layerless.** §1/S4's "native host"
  ships as `ReArcContentHostView : NSView` with a strong `_contentView`
  ivar and autoresizing — no CALayer interposed between the shell's view
  hierarchy and the WebContentsView container; compositing stays entirely
  on content's side. The anchor is R8's `WebContents::GetNativeView()`
  (verified at web_contents.h:1241), never `GetContentNativeView()`/
  RWHVMac.
- **C++/ObjC split via an opaque retained handle.** The header is pure C++
  (`ReArcContentHostRef` = void*, `gfx::NativeView`/`NativeWindow` values —
  both C++ classes usable outside ObjC TUs: NativeView extends
  base::apple::WeakNSView, weak and auto-nulling, with only the NSView*
  accessors __OBJC__-guarded). The .mm holds every AppKit touch and the
  `CFBridgingRetain`/`CFBridgingRelease` pair implementing §6's ownership
  split: Release drops ONLY the engine's retain; the shell may retain the
  emptied NSView until it dismantles its scaffolding.
- **Lease registry is external to TabSession — as recorded in S2's drift
  entry** (tab/007's files froze at landing): `attachment_lease.cc` keeps
  its own tab_id-keyed map, at most one lease per tab, additive pattern
  identical to S1's provider seam.
- **The S1 provider seam is wired for real.** `LeaseWindowProvider`
  answers content's `GetNativeWindow()` consults (via tab/006's delegate)
  with the host's window; registration is per-WebContents and cleared
  before the provider dies (tab/006's contract). Day-one the host is
  shell-embedded only through the in-process typed bridge
  (`ReArcContentHostGetView` opaque handle) — §6's "no NSView over data
  messages".
- **§6 rules as shipped:** attach starts hidden (host created hidden; no
  `WasShown` until the first `SetViewVisible(true)`; transitions only);
  second attach fails `kAlreadyAttached`; shell `DetachView` empties the
  host on the main thread and invalidates the id with NO event;
  engine-initiated `InvalidateLeasesForTab` empties the host FIRST,
  releases the engine's retain, then reports `view.invalidated` with the
  wire-literal reason names; expired ids fail stale with a VLOG (the
  transport slice maps that onto the wire `stale_attachment` error);
  `attachment_id` is engine-allocated, monotonic from 1 (§1).
- **Invalidation call sites deferred.** kTabClosed (S6 close pipeline),
  kContentReplaced (S7 discard — invalidate BEFORE replacement, reattach
  required), kEngineStopped (teardown ordering with
  `TabRegistry::DestroyAllSessions`), kWindowClosed (shell window
  lifecycle integration) all live in frozen files; the registry ships the
  primitives, later slices wire the seams.
- **Raw-pointer-free members.** The Lease and LeaseWindowProvider store
  the host handle as `uintptr_t` (no raw pointer members anywhere; the
  clang plugin's check-raw-ptr-fields is active on this target).
- **API drift absorbed at the pin:** ObjC declarations may not appear
  inside a C++ namespace (the host class is file-scoped at global scope
  with method declarations on the @interface); `WebContents::WasShown`/
  `WasHidden` are the day-one visibility verbs (web_contents.h:1031-1043
  points richer control at `UpdateWebContentsVisibility` — an S5+ audit
  item, WasShown/WasHidden remain legal callers).
- **GN placement.** The 009 sources block sits after
  `"shutdown_watchdog_mac.h"` at the end of the is_mac sources list — a
  -U3 window fully disjoint from app/005's block (three unchanged lines
  between them). No new deps.
- **Build attempts.** Gate `engine/build-p9.log` green on attempt 3;
  attempt 1 was a Cocoa import typo, attempt 2 the namespace-scoped ObjC
  class. No upstream-file changes resulted.
- **Validation (§6 row S4):** the full `AttachmentLeaseRegistry` API and
  all nine `ReArcContentHost*` entry points present in
  `libchrome_dll.dylib` as non-external symbols; all four reason literals
  (`tab_closed`, `window_closed`, `content_replaced`, `engine_stopped`)
  present exactly once in strings; no new exports; `--version`
  156.0.8078.74.
- **Smoke:** G1/G2/G4/G5 PASS (isolated runs, no transient failures this
  slice). G3 unchanged: documented command still trips the BSD grep `-q`
  defect reported with tab/008; gate intent green (`LC_ALL=C grep -qa
  PNG` PASS on the produced screenshot).

### S5 landed (2026-11-02) — `tab/010`–`tab/013`, commits `412dcd8253`, `b104f5157b`, `39b9d30e12`, `f80b69720d`

- One patch per adapter: service events + favicon (010), media session
  (011), visible security state (012), conservative JS dialog manager (013).
- **Parallel event surface.** `ipc_service_events.{h,cc}` was added rather
  than extending S3's frozen `ipc_tab_events`; favicon/security serialize
  into `tab.updated` changes, media as `media.state_changed`.
- **Lifetimes.** Adapters are WebContentsUserData-owned (not registry maps);
  favicon cache is tab-bound, generation-checked, 64 KiB capped.
- **Dormant by design** at S5 (attached in wave 10, `tab/017`/`018`), except
  the dialog override, which auto-cancels beforeunload until native UI exists.
- Builds: p10/p11, p12, p13, p14/p15 green. G1–G5 PASS per adapter.
  Full replay `engine/replay-s5.log`. Details in the S5 section above.

### S6 landed (2026-11-02) — `tab/014`, `tab/015`, commits `44f65e0a21`, `47a9442a50`

- Adoption of Chromium-created contents stages hidden and requires a user
  gesture; unsupported window dispositions are rejected predictably.
- Close controller: one pending close per tab, beforeunload → ClosePage →
  CloseContents, Chromium hang timeouts plus a 30 s forced-cleanup deadline.
- Minimal frozen-file edits (registry/session/delegate ownership seams;
  attachment_lease rejects reattach on a closing tab), justified in the
  patch headers. Builds p17 (attempt 2), p18. Replay `engine/replay-s6.log`.

### S5 follow-up landed (2026-11-02) — `tab/016-s5-review-fixes.patch`, commit `8556e72bd1`

Independent review (Cursor/Claude Opus 5.5) of 010–013; no lifetime or
callback-contract defects. Three fixes:
- security: recompute on primary-main-frame DidStartNavigation and every
  DidFinishNavigation (GetVisibleEntry() may be pending) — fixed stale
  "secure" during pending nav and stuck "unknown" after non-commits.
- security: Safe Browsing / HTTPS-First verdicts precede the
  unknown-until-initialized rule (mirrors `security_state::GetSecurityLevel`).
- favicon: drop updates while an error page is committed (the driver never
  cancels the previous page's lookups for error pages).
Build p19 green attempt 1; G1–G5 PASS; replay `engine/replay-s6b.log`.

### Wave 10 landed (2026-11-02) — `tab/017`, `tab/018`, commits `a6a69b17d4`, `4dd48e5360`

- Exported C ABI (`rearc_engine_abi.h`, 37 symbols, module map for Swift);
  reference in `engine/docs/C-ABI.md`.
- Deferred S5 items closed: profile id stamped on tab/service events;
  visibility moved to `UpdateWebContentsVisibility` plus native container
  show/hide (needed for presentation and mouse input).
- Adapters now attached at tab creation/adoption; teardown via the close
  controller. Runtime ABI tests: `engine/runtime-abi-{core,services}.log`.

### Wave 12 — URL admission (`tab/019`)

- Additive ABI minor query; major remains 1. Trusted browser navigation now
  admits data/file, audited settings/version WebUI, and one view-source wrapper
  around http(s)/file. Other schemes remain rejected. Policy: C-ABI.md.
- Minimal upstream SettingsUI exception: embedded contents have no autofill
  client; omit controls requiring it instead of dereferencing null. No helper
  blanket initialization, TabFeatures bypass or shell feature duplication.
- Build p29 green; settings integration refinement p30 (attempt 2).
  G1–G5 and native URL/core/services evidence recorded per final wave report.

### Wave 12 — evaluation (`tab/020`)

- Additive `ReArcTabEvaluateScript`, isolated per-boost/editor world or explicit
  primary main world, JSON result/structured error, Promise awaiting, bounded
  deadline, navigation/close cancellation and exactly-once deferred completion.
- Major remains 1; minor 2 / bridge 0.4.0 / script_evaluation capability.
  No existing C structure grows; no page-facing bridge or gesture is granted.
- Profile lifecycle/isolation deferred as one complete follow-up; precise API,
  ownership, veto and shutdown requirements now in C-ABI.md.
- Build p31 attempt 2; native evaluation plus legacy core/services/URLs and
  G1–G5 logged in runtime-abi-*-tab020 / smoke-tab020; export audit nm-tab020.

### Wave 12 — media metadata (`tab/021`)

- Explicit patch semantics: has_metadata=false means unchanged; true replaces
  title/artist/album together, including empty strings for clear. Every emitted
  media event is a full snapshot and always sets true. Other event kinds ignore
  these fields. Retains the wave-11 shell's correct conditional-update behavior.
- ABI minor 3 / bridge 0.5.0; media_metadata_snapshot feature. Header/docs and
  disconnect emitter agree; runtime host asserts authoritative metadata on all
  media events. Build p32; smoke-tab021 / runtime-abi-*-tab021 / nm-tab021.

### Wave 12 — first document and service lifetime (`tab/022`)

- Null creation keeps Chromium's initial empty document; explicit initial URLs
  queue one task and can be superseded by Navigate/Stop. No retry or visibility
  override. PageServices attaches DevTools lazily; empty plans and disabled peek
  do not touch the initial document. Real script/peek registration bootstraps a
  blank renderer if needed to acknowledge a pre-navigation installation.
- Internal client retains future registrations across admitted file/WebUI
  visits; expression/capture and current-style policy reject those documents;
  peek rejects non-http(s). HTTP→WebUI→HTTP→file→HTTP registration test passes.
- ABI minor 4 / bridge 0.6.0. Build p33; G1–G5 smoke-tab022; native hosts and
  30 hidden + 30 attached first loads pass. Zero synthetic placeholder commits.
- Timing evidence does not support claiming a hidden-tab scheduler stall fix:
  with mock Keychain, median remains about 1.25 s before/after. Real Keychain
  baseline included a 12.174 s first load; the indefinite case was sampled in
  OSCryptAsync→KeychainPassword→SecItemCopyMatching→SecurityServer::decrypt.
  No renderer/visibility/boost retry was added. See C-ABI.md and wave report.

### Wave 12 — shutdown during Keychain authorization (`tab/023`)

- Reproduced the missing completion with four attached, navigating tabs:
  35 s watchdog; browser main thread in ThreadPoolImpl::Shutdown waiting for
  OSCryptAsync GetKeyTask, worker blocked in SecurityServer decrypt.
- The default SKIP_ON_SHUTDOWN key-read task blocks teardown once started.
  Production keychain/password-name storage has process lifetime; switch its
  task to CONTINUE_ON_SHUTDOWN, retaining SKIP for explicitly injected borrowed
  test keychains. No cookie encryption bypass, key replacement or credential
  authorization change; callbacks still terminate on main before Run returns.
- ABI minor 5 / bridge 0.7.0. Deterministic test interposes only Safe Storage
  lookup in a disposable native host (no real key is read), independently of
  ambient Keychain authorization. Full build/runtime/replay evidence is in the
  wave report; final series replay is engine/replay-w12.log.

Wave-12 final commit map: 019=`715545163c`, 020=`0e3511018e`,
021=`89f94b7ae7`, 022=`6d34fcb0a8`, 023=`6c6160cfc1`. Final p36,
smoke-tab023 G1–G5, all five native hosts, C/Swift imports and 39 exports pass.
The forced-blocked authorization regression fails under the old shutdown
behavior and passes normal/force shutdown in 363/297 ms with 023. The ordinary
shutdown stress passes 30 processes / 120 attached tabs. Full 23-patch reverse
and forward replay matches pin and HEAD in replay-w12.log; Chromium tree clean.
Complete measured distributions and Swift adoption: WAVE-12-REPORT.md.

### Wave 14 — profiles (`tab/024`, `4222b92728`)

ABI 1.6 adds ProfileOpen/CreateOffTheRecord/Close without changing any ABI 1.5
layout. ProfileManager creates persistent profiles; ASCII storage keys are hex
encoded to preserve case on macOS filesystems. Named OTR contexts use Chromium
memory-only storage and retain their original until ProfileDestroyer completes.
The BrowserContext destruction sentinel holds the parent through deferred
renderer cleanup. Only startup registers through PostProfileInit; cancelled
additional opens cannot reacquire a keepalive during shutdown. Profile close
serializes globally, rejects parents with children/default close, honors veto,
and drains tabs/services/leases before release. Per-profile live-content counts
cover the task between registry removal and actual contents destruction.

Build p37 final green. Native core/services/urls/eval/scheme_return/profiles
(including a second process), G1–G5, and 4 processes/16 shutdown tabs pass in
`gates-tab024.log` and associated `*-tab024.log` files. Profile tests cover
cookies/localStorage, A/a identity, two independent OTRs, disk-marker absence,
boost/cache boundaries, popup inheritance, veto recovery, reentrant teardown,
lease/evaluation cancellation and pending-open shutdown cancellation.

### Wave 14 — evaluation identity (`tab/025`, `b97593bb6a`)

ABI 1.7 adds EvaluateScript2/GetDocumentIdentity and a new result structure;
all old callbacks retain their exact signatures. PageServices observes primary
commits, retaining Chromium's navigation ID and advancing a document generation
on cross-document commits (including reload/BFCache return). Evaluation captures
that identity before asynchronous context lookup and retains it on all outcomes.
Both evaluation APIs share one busy slot. Build p38 green, full native suite,
identity checks, G1–G5 and 4 processes/16 shutdown tabs green in gates-tab025.log.
The identity host proves success/current-query agreement, cancellation retaining
the old identity, same-document stability and reload advancement without shell
commit counting. file/WebUI execution remains refused.

### Wave 14 — page zoom (`tab/026`, `86b4181b82`)

ABI 1.8 adds page_zoom factor get/set and a separate typed change callback,
leaving old service-event layouts intact. PageServices attaches the upstream
ZoomController with ZOOM_MODE_DEFAULT and suppresses its UI bubble. HostZoomMap
and ChromeZoomLevelPrefs own sharing/persistence. Add one core dependency on
//components/zoom; no TabHelpers/TabFeatures/BrowserWindow is introduced.
Build p39 green; native suite plus two zoom processes prove same-host sharing,
profile separation, host navigation/reset/return and disk persistence. G1–G5
and 4 processes/16 shutdown tabs pass (gates-tab026.log).

### Wave 14 — isolated page messages (`tab/027`, `d733c456f1`)

ABI 1.9 adds a separate page-message callback, preserving existing event
layouts. CDP binds only exact isolated names/host-selected isolated context IDs.
A frozen JS wrapper retains the raw sender privately and bounds payload/rate
before serialization. Native validation enforces top-frame http(s), isolated
context identity, <=64 KiB RFC JSON, 60 attempts/fixed second/tab and <=60 queued
messages. Delivery captures document identity and navigation-attempt epoch;
callback replacement invalidates queued registrations. Keep context identities
until CDP destruction so an aborted navigation can resume the original world;
pending navigation rejects sends. Build p40 final green. Native tests prove
boost/editor messages, absent main binding, malformed/oversize rejection,
57/500 flood delivery, disablement, reload, abort recovery and successful
navigation/close cancellation. Full hosts, G1–G5 and 4 processes/16 shutdown
tabs pass in gates-tab027.log. C11 ABI 1.5 layout checks, Swift callback imports
and all 48 public ReArc symbol definitions/framework resolutions pass.

### Wave 14 — build-time Safe Storage/bundle branding (`chrome/002`, `7f633822da`)

ABI 1.10/bridge 0.12.0 advertises rearc_safe_storage_branding. The selected
Chromium BRANDING now supplies ReArc short name and com.rearc.browser root.
A small process_version target generates keychain service/account macros from
PRODUCT_SHORTNAME; os_crypt contains no hardcoded ReArc service/account string.
Full names, executable/framework/helper filenames and encryption behavior remain
unchanged. Generated identifiers, not post-build plist edits, carry the new
root through app/framework/helper assumptions. Actual alert helper IDs are
`<app>.framework.AlertNotificationService`, including Aperitif Alerts.
PACKAGING-MAC.md specifies production Team ID, exact IDs, role entitlements,
release input selection, dependency/signing order and old-key migration limits.
Build p41 green (165 executed steps). All 10 native hosts (12 process runs),
G1–G5 and 4 processes/16 shutdown tabs pass in gates-chrome002.log. Generated
header, compiled keychain object and all 10 bundle plists pass branding-w14.log.
Final stress, ABI 1.5-header runtime, exported-symbol and replay evidence is
recorded in WAVE-14-REPORT.md.

### Wave 16 — read-only macOS permission shutdown (`tab/028`, `367324a510`)

ABI 1.11 / bridge 0.13.0 adds os_permission_shutdown. A named-profile stall
samples main in ThreadPool shutdown and a running SKIP task in the media
permission cache's read-only AVCaptureDevice/TCC preflight. OSCrypt's blocked
read already continues on shutdown; neither ProfileDestroyer nor a cookie
write owns that wait. Production macOS cache reads now continue on shutdown,
using process-lifetime function callbacks and weak replies. Borrowed test
wrappers retain SKIP semantics. Data-writing task traits and encryption are
unchanged. Build p42 is green. Native hosts, G1–G5 and stress evidence are
recorded in gates-tab028.log and WAVE-16-REPORT.md.

### Wave 16 — shutdown joins standalone tab closes (`tab/029`, `6201151b27`)

ABI 1.12 / bridge 0.14.0 adds shutdown_pending_closes. The shutdown controller
joins the close controller's pending request and retains its original reply.
Normal joins honor veto; force promotes the pending close without duplicate
callbacks. Live-content counts also cover the registry-removal/destructor gap.
ProfileClose still serializes as a separate lifecycle operation and remains
busy until its completion; exact rejection and callback order are in C-ABI.md.
The native shutdown hosts exercise normal/force joins, reentrant invalidation,
exactly-once replies, and a real activated beforeunload veto followed by force.

### Wave 16 — existing profile directory adoption (`tab/030`, `52406c2b93`)

ABI 1.13 / bridge 0.15.0 adds profile_directory / ProfileOpenDirectory and one
framework export. Existing Default storage can be assigned to one shell profile
without relocating databases. Host metadata persists the directory token; engine
IDs stay transient. Opens share a directory-keyed request registry with existing
named-key opens, whose hex paths are unchanged. Async directory validation
requires exact ASCII disk spelling, rejects symlinks, and uses no raw Profile
pointer across worker tasks. Missing/invalid/nonregular results and cancellation
complete once. Startup lifetime/close refusal is retained. Directory adoption
preserves storage placement; it is not a Safe Storage key-brand migration.

### Wave 16 — hidden-tab evidence and preserved policy (`tab/031`, `137a0dc3dc`)

No scheduling/visibility code or ABI change. The bridge README records four
script controls (48 tabs / 192 evaluations) and separate load-only controls
(80 loads). Direct hidden evaluation is milliseconds; chained timers are
seconds and hidden rAF stays paused. Disabling timer throttling changes that
timer latency but not first-load medians materially. Renderer-backgrounding and
frame-rate diagnostics do not justify a blanket exemption. Fresh documents do
not reach intensive grace age. IPC-CONTRACT §5/§6 remains authoritative: never
attached is not a bounded host declaration of pending foreground attachment.

Build p46 is green (no work); final native suite (13 hosts / 18 processes),
G1–G5 and 30 shutdown processes / 120 tabs pass in gates-tab031.log. The smoke
build guard was refined to reject actual builder executables and all non-shell
old-pattern matches while ignoring quoted shell text; positive rejection and
idle acceptance are verified in build-guard-w16.log. The raw interruption
before G3 is preserved separately and remaining gates were resumed.

### Wave 18 — audited daily-use WebUI admission (`tab/032`, `b0cc7b4ec6`)

ABI 1.14 / bridge 0.16.0 adds webui_daily_pages and no C symbols or layouts.
History, downloads, password-manager and extensions join the exact-host trusted
navigation allowlist; the internal registration client shares it, preserving
installed HTTP plans through WebUI transitions without granting privileged
execution/capture. Chromium WebUI/controllers/profile services supply the pages.

Pin audit found HistoryUI's unconditional TabInterface lookup and Journeys'
Browser/TabStripModel assumptions: disable Journeys without a desktop tab and
safely disconnect that handler. Password shortcut, batch-upload and relaunch
handlers now guard missing Browser. Existing nullable Browser actions remain
limited; flags stays rejected because AttemptRestart bypasses host relaunch.
The full per-host audit and exact Swift gate are in WAVE-18-REPORT.md.

Builds p47/p48, 14 native hosts / 19 process runs, G1–G5, and 4 stress processes /
16 shutdown tabs pass in gates-tab032.log. The new attached native host checks
11 WebUI routes, live Chromium handlers, guarded password actions, ABI privilege
rejection and preserved isolated HTTP registration after the round trip.
External test DevTools adds a REMOTE_DEBUGGING keepalive that must be explicitly
released by its Browser.close automation cleanup; production shutdown is unchanged.

This pass stops after concern 1 at a validated budget boundary. No tab helpers,
native dialogs/file chooser/permission/context menus/find/download-event ABI or
password prompt/fill support was shipped. Runtime Default/History remains empty
after the HTTP fixture visit. Attaching HistoryTabHelper alone would still skip
browser-less visits at this pin: ShouldAddNavigationToHistory requires a Browser.
That targeted exception and helper/layering audits belong to concern 2.

Final ABI 1.13-header compatibility passes all 13 legacy hosts / 18 processes;
11 struct layouts remain identical and all 49 public symbols resolve through
the framework. replay-w18.log passes 33/33 patches back to the exact upstream
pin tree and forward to b0cc7b4ec6, with the real Chromium index/worktree clean.

### Wave 18b — audited browser-less tab helpers (`tab/033`, `6c227521ff`)

- **R6 helper whitelist is no longer empty.** The S2 record (tab/007) kept the
  per-helper `CreateForWebContents` set empty because CoreTabHelper lives under
  `//chrome/browser/ui` and the layering seemed to forbid it. `:core` already
  depends on `//chrome/browser/ui` at this pin. The new
  `browserless_tab_helpers.cc` attaches ZoomController, the profile's
  autofill client, ChromePasswordManagerClient, HistoryTabHelper (non-OTR),
  FindTabHelper and the DownloadNavigationObserver. It runs from the
  TabSession constructor and from a new `WebContentsCreated` delegate
  override, so renderer-created contents bind their autofill and password
  drivers before the first navigation. `TabHelpers::AttachTabHelpers`,
  TabFeatures and the testing bypass stay unused.
- **One upstream hunk outside the bridge for history.**
  `HistoryTabHelper::IsEligibleTab` returned false on desktop without
  `FindBrowserWithTab`. On Mac it now also accepts contents owned by a live
  bridge TabSession (`rearc::IsBrowserlessTabContents`, a registry lookup).
  Every other history rule is Chromium's.
- **No prompt helpers.** ManagePasswordsUIController, PermissionRequestManager,
  TabDialogs and TabModalDialogManager are deliberately not attached. Their
  surfaces are the dialog, permission and password-prompt concerns.

### Wave 18b — find in page (`tab/034`, `e45a33863d`)

- **Delegate routing, not a reimplementation.** `ReArcTabDelegate::FindReply`
  forwards to `FindTabHelper::HandleFindReply`, as `Browser::FindReply` does.
  A per-tab `FindSession` (WebContentsObserver + FindResultObserver, in the
  new `rearc_find_abi.cc`) adds ABI session IDs and terminal events. It hooks
  in through `ABIAttachServices`/`ABIDetachServices`, so close-path
  cancellation runs while the session is still registered, before
  `tab.closed`.
- **Start always starts.** FindTabHelper treats an unchanged text and case as
  "find next". The ABI's Start stops the active session first
  (`SelectionAction::kKeep`), so every Start yields a new session and a
  `replaced` terminal for the previous one.

### Wave 18b — downloads (`tab/035`, `1708e96dbe`)

- **Observation hooks in the profile registry.** `RegisterBridgeProfile` and
  `UnregisterBridgeProfile` create and destroy one `AllDownloadItemNotifier`
  per bridge profile (OTR included), always before the profile can be
  destroyed. Registration only happens in embedded mode, so stock and headless
  runs are unchanged.
- **Two hunks in ChromeDownloadManagerDelegate.** `OpenDownload` would have
  created a Chrome window via `ScopedTabbedBrowserDisplayer` for
  browser-preferred types, and `RequestConfirmation` would have shown the
  file picker. OTR profiles always ask, because DownloadBubbleUIControllerDelegate
  sets `kPromptForDownload`. In embedded mode both take the platform or
  suggested-path route, or cancel. The picker returns with the file chooser
  concern.

### Wave 18c — JavaScript dialogs (`tab/036`, `4c2fa8c0bd`)

The existing per-WebContents JavaScriptDialogManager now owns an outstanding
Chromium callback and routes request/cancel events to a separately registered
ABI host. No Browser, TabDialogs or TabModalDialogManager is attached. Retains
conservative no-host cancellation and beforeunload veto, including legacy ABI
hosts. Navigation/frame destruction and the services detach hook retire IDs
before replying to Chromium. ABI 1.18 / bridge 0.20.0; p54/native dialogs pass.

### Wave 18c — file selection (`tab/037`, `5d6a80867c`)

RunFileChooser forwards to FileSelectListener through a host request. A bounded
ThreadPool task validates selections/enumerates upload roots, excluding symlink
traversal. The same adapter services ChromeDownloadManagerDelegate save-path
confirmations. No Chromium picker, FileSelectHelper confirmation dialog or
Browser is created. FileSystemAccess desktop dialogs and drag/drop enumeration
remain outside this delegate and unsupported. ABI 1.19 / bridge 0.21.0;
p56/native files pass (open/multiple/folder/save/cancel/navigation/close).

### Wave 18c — permissions (`tab/038`, `7fe0314f32`)

PermissionRequestManager is selectively attached; ChromePermissionsClient's
production CreatePrompt seam returns a non-rendering PermissionPrompt for
registry-owned contents. No testing factory or fake Browser is used. Chromium
retains grouping, origin/gesture/policy/embargo checks and HostContentSettingsMap.
An additive default-true decision persistence field propagates through
PermissionRequest (including duplicates) to PermissionContextBase; the host may
resolve allow/deny without writing a setting. Non-embedded prompts keep the
upstream default. Camera/microphone delegate routing had to be added explicitly:
content's default denied before the manager. Screen/tab capture remains denied.
Permission infobars and surveys are suppressed for registry contents. Wave 16's
TCC cache and shutdown task traits are unchanged. ABI 1.20 / bridge 0.22.0;
p57–p59 and the native permission host pass. Test-only CDP focus emulation is
necessary for Clipboard's focused-document check on the locked test desktop;
no production focus policy changes.

### Wave 18c — page context menus (`tab/039`, `72067026d0`)

The browser-less view delegate forwards browser-validated ContextMenuParams to
a per-WebContents ABI adapter. No RenderViewContextMenu/Views NSMenu is created.
A weak-document pointer plus navigation/close cancellation prevents commands
from using a replaced document. Open link shares the ABI URL validator; edit
commands use WebContents, copy image uses RenderFrameHost, HTTP image saving
uses SaveFrameWithHeaders with Chromium's referrer sanitation and image Accept
header (SaveImageAt only supports renderer/data-image cases). Back/forward/reload
reuse the existing ABI commands. Inspect is explicitly unsupported: Chromium's
DevToolsWindow path assumes Browser UI. ABI 1.21 / bridge 0.23.0; p60–p61 and
native link/edit/navigation/cancellation tests pass; final image tests are in
the wave report.

### Wave 18c — password offers (`tab/040`, `3be2bd6fdb`)

ChromePasswordManagerClient transfers browser-less save/update offers to a
WebContents-owned adapter, which owns PasswordFormManagerForUI until reply or
cancellation. The shell sees origin/username/update only, never a password.
Save, never and dismiss delegate to Chromium's Save, OnNeverClicked and
OnNoInteraction. ManagePasswordsUIController remains unattached. ABI 1.22 /
bridge 0.24.0; p62 and native save/update/dismiss/never/navigation/close cases
pass, including Login Data update timestamp and blocklist checks. Tests use
trusted test-only CDP text input because script .value assignment does not
replace Chromium's autofill user-input state. Final context-menu image copy and
HTTP-image download cases pass as well. Full regression, blocked-TCC and replay
results are recorded in WAVE-18C-REPORT.md.

Wave-18c final validation: p62; 22 native hosts / 27 process runs, G1–G5,
4 ordinary shutdown processes / 16 tabs, 4 pending-dialog processes / 16 tabs
and 16 exactly-once request cancellations, plus an actually blocked TCC
preflight shutdown (1735.718 ms) all pass. Representative ABI 1.17-header
compatibility passes 4 hosts / 6 processes; all 13 old struct layouts and
66 framework-resolved exports pass. Replay 41/41 reverse/forward reaches the
exact pin tree and HEAD `3be2bd6fdb544b592cdbfa3703c6c263c3291042`; the real
Chromium checkout is clean. Full evidence, rejected diagnostic pilots and
unsupported surfaces are in WAVE-18C-REPORT.md.


### Wave 18d — profile history (`tab/041`, `0638fbe4ec`)

ABI 1.23 / bridge 0.25.0, `history_query`. Adds bounded text/recent queries,
URL removal and [begin,end) local visit removal using the addressed
HistoryService. Reject OTR before EXPLICIT_ACCESS factory lookup so the original
profile cannot be queried or modified through a private identity. Track at most
64 pending operations and cancel observation on profile release. DeleteURLs
uses a bounded same-backend query as its completion barrier: all-time
ExpireHistoryBetween with restricted URLs violates this pin's DeletionInfo
invariant. Query rows expose title/URL, Unix microseconds and total visit count.

Build p65 and native history tests pass, including limits, repeated URL count,
ordering, text search, exact inclusive/exclusive range boundaries, isolation,
OTR rejection and cancellation. p63 failed on a missing raw_ptr annotation;
p64's native pilot found the expiration invariant. Those pilots are not
passing evidence. Full regression and replay are in WAVE-18D-REPORT.md.

### Wave 18d — dangerous downloads (`tab/042`, `164051a14b`)

ABI 1.24 / bridge 0.26.0, `dangerous_downloads`. ABI 1.17 already has danger_type;
its event layout and action values 0..5 are unchanged. Add current warning
snapshots and an independent ResolveDanger call: explicit keep invokes
ValidateInsecureDownload first when insecure, otherwise ValidateDangerousDownload;
discard uses Remove. These methods can delete the item synchronously, so the
bridge never accesses it afterward. Pending scanner state alone is not a
keepable warning. Queued cancellation/removal events can refer to retired IDs.

Build p66 and native dangerous-content keep/discard, file presence/removal and
legacy download tests pass. The fixture uses an existing Chromium hash-blocklist
switch with inert bytes. The initial typed-address-bar .dmg pilot was correctly
allowed by Chromium and timed out waiting for a warning; link-transition .sh
avoids that allow rule. A later test assertion incorrectly queried a removed
item from its queued cancellation event and was corrected. No test override or
scanner bypass was added to production. Insecure and uncommon warning sources
were not separately generated by the fixture.

### Wave 18d — S7 preserving discard (`tab/043`, `1434c7b833`)

ABI 1.25 / bridge 0.27.0, `tab_discard`. Embedded Run enables the pin's guarded
WebContentsDiscard feature by merging existing enable switches; explicit disable
still wins. No TabLifecycleUnit/TabStripModel adapter and no process kill.
Preserve contents, navigation entries, helper/script registrations and native
lease. Therefore no content-generation increment or view invalidation is needed.
Visibility and valid activation reload through NavigationController; discard
cancels document evaluation/snapshot/prompt work and ends find with reason 5.
New legacy-layout tab-event kinds 5/6 convey discarded/cleared, including state
refresh, with URL/title and normal identity. Protected/loading/presented tabs
are refused; script/peek installation is busy. Renderer reclamation is async;
logical discard never waits for a renderer, and introduces no automatic policy.

Native testing found PerformanceManager's TabPageDecorator CHECKed kTab for
browser-less PageNodes. Its tab-handle-specific notification now ignores
same-node preserving discards of non-tab pages and retains real-tab invariants.
No fake TabInterface, PM tab identity or per-tab browser window was introduced.
p67 built; its native pilot exposed that CHECK. Corrected p68 and the native
fixture pass: five discards/four reloads, document.wasDiscarded, retained boost
and navigation entries, stable identity/lease, shared-process sibling state,
evaluation/find cancellation, protected-state rejection, shutdown while
discarded and explicit feature disable. Inspect remains unsupported; the exact
stock Browser/DevTools binding/lifetime audit is in WAVE-18D-REPORT.md.


### Wave 18e — default search and autocomplete (`tab/044`, `669d2bfe61`)

ABI 1.26 / bridge 0.28.0, `search_autocomplete`. Reads and sets the profile's
TemplateURLService default (ready-to-use `%s` URLs) and classifies input with a
per-profile AutocompleteClassifier. Runs one cancellable AutocompleteController
query per profile with a curated local provider set plus SearchProvider.
Chromium's own CanSendSuggestRequest still gates remote suggest. Waits for
keyword loading (<=64 waiters). Supersede, Stop and profile release yield
exactly one cancelled terminal result. OTR IDs use a provider client with no
history/bookmarks/shortcuts, matching history_query's isolation, and never send
suggest. Setting the engine through OTR is rejected. Build p69 failed on a
u16 literal assertion; p70 and the native search host pass. That host covers
provider get/set, URL/search classification, history and remote-suggest
matches, cancellation, OTR isolation and a fixture-recorded absence of OTR
suggest requests.

### Wave 18e — HTML fullscreen (`tab/045`, `8dc537d8c0`)

ABI 1.27 / bridge 0.29.0, `html_fullscreen`. The tab delegate implements the
fullscreen contract with per-WebContents state, resynchronizes visual
properties and posts entered/exited events with an exit reason (page, host,
Escape, closed, hidden). Without a callback requests are refused. The Escape
key is handled in PreHandleKeyboardEvent as Chrome's FullscreenController does.
Close hides the view before destroying contents, so close-state is consulted to
report reason closed. Builds p71–p73. The first native pilots exposed a
fixture double-evaluation and the hidden-vs-closed reason, both corrected.
The final fixture passes refusal, entry and all five exit reasons.

### Wave 18e — printing (`tab/046`, `3cf2236a0c`)

ABI 1.28 / bridge 0.30.0, `printing`. Attach Chromium printing helpers and
generate PDF bytes through PrintViewManagerBase::PrintToPdf/PdfPrintJob. The
host does NSPrintOperation or Save as PDF. PrintViewManager's scripted preview,
requested preview and ScriptedPrint system dialog recognize registry tabs. They
complete the renderer request (afterprint fires) and post a host print request
instead of opening Browser-bound WebUI preview or a Chromium NSPrintPanel. A
navigation/discard/close or frame-teardown PdfPrintJob failure maps to
cancelled. Builds p74–p75. Fixture pilots used an update event's empty URL
and a PDF size threshold (test errors), and found close reporting internal,
fixed in p75. Native PDF pages/landscape range/invalid range/busy,
window.print request+afterprint and navigation/close cancellation pass.

### Wave 18e — drops (`tab/047`, `5a857e2ca6`)

ABI 1.29 / bridge 0.31.0, `page_drops`. The prior delegate aborted every drop
while dragenter/over still reached pages. A host policy now selects
files/text/URLs/promised images. CanDragEnter refuses drags with nothing
accepted, and OnPerformingDrop filters, then completes Chromium's normal drop.
Exact host-registered UTIs are rejected in WebContentsViewCocoa before
WebDragDest, so shell-private drags produce no page event. Build p76. The
native host drives the real NSDraggingDestination with synthetic
NSDraggingInfo over unique pasteboards: legacy abort, text/URL/file/image
file/promised image, raw image bytes without a source (Chromium does not expose
them as File), private-type invisibility, text-only refusal/filtering and
accept 0.

### Wave 18e — video PiP (`tab/048`, `5e59268cef`)

ABI 1.30 / bridge 0.32.0, `picture_in_picture` (P-PIP-001 manual video PiP).
The delegate's EnterPictureInPicture/ExitPictureInPicture go to
PictureInPictureWindowManager and the Views overlay window when a host callback
exists. `ReArcTabSetPictureInPicture` uses MediaSession, Chromium's eligibility
rule. Media events report real pip_available/pip_active. Back to tab is
recognized as the activation issued synchronously after the PiP exit;
window.focus() stays ignored. Build p77. The native host found MediaStream
players are one-shot (not offered for browser PiP) and that only unmuted audio
creates a session. Its page then records a silent 6.5 s WebM for the host path.
Refusal, page and host entry, host exit, a native Back-to-tab button click
and close while active pass. Document PiP is not supported (Browser
NEW_PICTURE_IN_PICTURE window); see C-ABI.md. Full regression, compatibility
and replay are in WAVE-18E-REPORT.md.

### Wave 18f — extension tab helpers (`tab/049`, `36b60ad909`)

ABI 1.31 / bridge 0.33.0, `extension_tab_helpers`. Audit: ExtensionWebContentsObserver was
already universal, while the extension view type, extensions::TabHelper,
SessionTabHelper and WebNavigationTabObserver were missing. ExtensionTabUtil::GetTabById
searched only Browser tab strips. Now kTabContents registry tabs get those helpers
(SessionTabHelper without SessionService) and GetTabById resolves them to
contents only, as it does for prerendered tabs. Build p78. A native `--load-extension`
fixture shows the content script, runtime messaging with sender.tab,
webNavigation, tabs.sendMessage, executeScript by tab ID and OTR
non-injection. webNavigation misses commits made before a freshly installed
service worker has registered its listener; the fixture reloads, bounded.

### Wave 18f — extension prompts (`tab/050`, `758ca5e9a3`)

ABI 1.32 / bridge 0.34.0, `extension_install_prompts`. ShowExtensionInstallDialogImpl and
ExtensionUninstallDialog::Create become host requests in embedded mode.
ExtensionInstallUIDesktop reports success and failure instead of opening a
Browser window, installed bubble or infobar. Extension tabs.create and
runtime.openOptionsPage no longer create a Browser. Builds p79 (an IDS_CANCEL
typo) and p80. Natively, through a loopback gallery override
(`--apps-gallery-url`): no-callback abort, host cancel, callback replacement,
and accept of a CRX without publisher proof, which produces the
install-failed notification. A locally signed CRX3 dropped on
chrome://extensions installs, with the installed notification. Uninstall
cancel and accept work, and no Chromium window opens. Pilots found that MV2
test CRXs can't be installed (ManifestV2Handler) and that production Web
Store installs need Google's publisher proof; see C-ABI.md.

### Wave 18f — extension actions and popups (`tab/051`, `c734a32b96`)

ABI 1.33 / bridge 0.35.0, `extension_actions`. Per-tab action snapshots (title, badge, colors,
visibility, popup, wants_to_run, scaled icon), change events, and a
toolbar-click run through ExtensionActionRunner. Popups are registry tabs with view
type kExtensionPopup; the renderer auto-resizes within Chromium's popup
bounds and window.close() closes them. Builds p81 (namespace) and p82. The
native fixtures show list/badge/2x icon, activeTab onClicked scripting,
popup attach, a 320x180 auto-resize event and self-close with reason 1.

### Wave 18f — autofill suggestions (`tab/052`, `fdea5a4f6d`)

ABI 1.34 / bridge 0.36.0, `autofill_suggestions`. A host AutofillPopupView behind Chromium's
AutofillPopupControllerImpl serves address, card, IBAN, autocomplete, datalist
and password suggestions. ShowAutofillSettings and
NavigateToManagePasswordsPage ask the host to open Chromium's settings page.
Builds p83 and p84 (comments). The native host saves an address and card
through autofillPrivate and a credential through passwordsPrivate, and uses
loopback HTTPS for cards. It shows exact field bounds, rows and icons,
native arrow-key selection, busy early accept, fills, dismiss, both manage
paths, password rows without passwords and replacement. Pilots: DevTools key
events skip browser key listeners (a native keyDown is used instead), and
the locked session never makes the window key (a test switch disables
Chromium's key-window focus rule).

### Wave 18f — password leak detection (`tab/053`, `7e0cde3ec7`)

ABI 1.35 / bridge 0.37.0, `password_leak_detection`. Get/set of Chromium's
`profile.password_manager_leak_detection` pref (default on, policy-managed
flag, OTR unsupported). Build p85. The native leak host's net log shows a
leak-check request attempted when the pref is on (resolution blackholed) and
none after it is turned off and the profile reopened. Sign-in hosts turn it
off. The wave's network audit then puts every test process on a
no-outside-network switch set with a net-log connect check. Full regression,
compatibility and replay are in WAVE-18F-REPORT.md.


### Wave 18g — extension shell windows (`tab/054`, `b236dccd15`)

ABI 1.36 / bridge 0.38.0, `extension_windows`. A registry model supplies the
requested tabs/read-only windows APIs without a fake BrowserWindowInterface,
TabInterface or WindowController. Host-reported logical membership/active/focus
is independent of view visibility. Host creation/activation requests carry URL,
profile, extension ID, active, bridge opener/target and logical window; the host
creates about:blank in its current space and responds after adoption. The engine
loads the validated URL with its extension initiator, including its own options
page, without broadening general ABI URL admission. Requests are bounded to 64,
time out at 30 s, and cancel on callback replacement, associated close or profile
release. Responses re-resolve contents at queued delivery. Chromium scrubs tab
metadata and enforces original/OTR visibility. Removal uses the veto-aware close
pipeline. p89 and the local MV3 fixture pass query/get/update/remove, host tab/
options/window creation, filtered/populated windows and active/focused state,
with no outside connection. See C-ABI.md for limited window/tab mutation scope.

### Wave 18g — local autofill save offers (`tab/055`, `ee5a2f288c`)

ABI 1.37 / bridge 0.39.0, `autofill_save_prompts`. WebContents-owned host offers
retain Chromium local-card/address decision callbacks. Accept unchanged,
decline and ignore drive Chromium storage; masked card summaries never include
PAN/CVC. Preserve the form submission navigation (address import can offer
before it starts); later navigation and teardown cancel once. No callback means
ignore and no Views bubble. Account migration/cloud-save UI is ignored for
registry tabs. p90 built; its pilot exposed submission cancellation. Corrected
p91 and local HTTPS address/card accept/decline/store verification pass, with no
outside connection. Production cloud eligibility is not disabled by this UI seam.

### Wave 18g — HTTP authentication (`tab/056`, `579c39be34`)

ABI 1.38 / bridge 0.40.0, `http_auth`. A LoginHandler subclass routes challenge
metadata and host-supplied credentials through the ordinary HttpAuthCoordinator
and LoginTabHelper flow, preserving Chromium's cache/digest/password behavior.
Registry subresources bypass only the absent modal-dialog-manager UI guard.
No callback cancels; replacement and handler/tab/profile/engine teardown withdraw.
p93 and local Basic wrong-password retry, Digest validation, cancel, callback
replacement and pending-close tests pass with no outside connection. Client TLS
certificate selection and engine-owned DevTools windows remain skipped; the
precise identity/key, frontend, native-window and close/veto ownership reasons
are recorded in WAVE-18G-REPORT.md.

### Wave 18g — security interstitial verification (no new patch)

SecurityInterstitialTabHelper::AssociateBlockingPage lazily creates its helper;
registry tabs need no extra attachment. A local self-signed TLS fixture and
Safe Browsing --mark_as_phishing blocklist prove rendered pages, native PNG
capture, proceed to the target and back to the prior entry for each warning.
Separate loopback hosts avoid a proceed decision allowlisting the next fixture
on the same origin. Native screenshots were visually inspected. Production
source is unchanged and no ABI bump/feature is claimed for this verification.
Full gate, compatibility and replay evidence is in WAVE-18G-REPORT.md.

Wave-18g final validation: p93 / ABI 1.38 / bridge 0.40.0; all 36 native hosts /
43 process runs, G1–G5, ordinary/pending-prompt shutdown stress and actual
blocked-TCC shutdown pass. Native/smoke net logs show no outside connection.
All 13 legacy layouts, Swift imports, 105 exports and exact-1.17 compatibility
(4 hosts / 6 processes) pass. Replay 57/57 matches pin and final HEAD
`579c39be3468214f5ed4aad6b1a0f49ff928e8d8`, with real index/worktree untouched.
The build guard uses the owner's corrected `siso[ ]ninja` pattern, plus executable
checks; tests remain sequential. Full evidence is in WAVE-18G-REPORT.md.


### Wave 18g — modifier link opening (`tab/057`, `9739603b0f`)

ABI 1.39 / bridge 0.41.0, `link_open_requests`. OpenURLFromTab routes gestured
HTTP(S) foreground/background/window/split creation to a separate host event,
reusing the extension queue's bounds/deadline/profile/source cancellation while
keeping prior structs unchanged. The engine retains full Chromium parameters
and navigation callback; the event exposes URL, disposition, source/opener and
sanitized referrer/policy. Host creates a distinct blank tab, maps/selects it,
and responds. Retire a queued initial blank load before navigation (also fixes
extension creation). The source remains unchanged; no script opener is granted.
Native p96 fixture passes Command, Command-Shift, center-button, Shift and
Option-Command cases (the latter is NEW_SPLIT_VIEW at this pin), noreferrer in
event/document/HTTP header, profile/target validation, replacement and source
close cancellation. Explicit rel=opener and non-HTTP URL-only requests remain
unsupported; AddNewContents adoption is unchanged. Final full validation and
58-patch replay are recorded in WAVE-18G-REPORT.md.

Wave-18g additional-item final validation: p96 / ABI 1.39 / bridge 0.41.0,
37 native hosts / 44 process runs, G1–G5 and all shutdown stress modes pass;
no native/smoke outside connection. All 13 legacy and 38 ABI 1.38
layouts, Swift imports, 107 exports and exact-1.17 compatibility pass. Replay
58/58 matches final HEAD `9739603b0f3fee4985c18d7407f3f3c4de05d865` and the pin, with the
real index/worktree untouched. See WAVE-18G-REPORT.md for full evidence.


### Wave 18h — hosted DevTools (`tab/058`, `a95beb7f31`)

ABI 1.40 / bridge 0.42.0, `devtools`. `ReArcTabOpenDevTools` creates a new
registry tab for Chromium's bundled frontend, attached to the target's tab
agent, in the target's profile and space. No Browser, DevToolsWindow or native
window is created. DevToolsUIBindings gains a hosted mode: an embedder-message
allowlist, an untrusted client with no local file access, a protocol filter
(no Browser.*, target discovery/creation or download behavior) and no
DevTools extensions. A navigation throttle admits `devtools://` only in
frontend tabs, and only the exact bundled URL there. Frontend close is
immediate and never touches the target's beforeunload; target destruction
force-closes its frontends. Profile close and shutdown are sequential in
creation order, so a target veto keeps its frontend open. Wave 18h review found
no engine defect; the native host gained frontend URL-lockdown checks.

### Wave 18h — client certificates (`tab/059`, `e1bb6df2aa`)

ABI 1.41 / bridge 0.43.0, `client_certificates`. Registry-tab
SelectClientCertificate requests reach the host after Chromium's auto-select
policy, with origin plus subject/issuer/expiry/SHA-256 fingerprint. Selection
acquires the key asynchronously; cancel and every lifecycle path drop the
delegate (abort), never a cached null certificate. Chromium's error-page
auto-reload now skips ERR_SSL_CLIENT_AUTH_CERT_NEEDED, which otherwise
re-asked the host after each abort. A debug-only memory ClientCertStore
behind `--rearc-test-client-cert-dir` + `--use-mock-keychain` supplies net/data
identities with delayed acquisition/signing for tests.

Wave-18h final validation: p106 / ABI 1.41 / bridge 0.43.0, 39 native hosts /
49 process runs, G1–G5 and all shutdown stress modes pass; no native/smoke
outside connection. All 13 legacy and 39 ABI 1.40 layouts, Swift imports,
110 exports and exact-1.17 compatibility pass. Replay 60/60 matches final HEAD
`e1bb6df2aa8ddf2255d24389c2533e0620a4e3ce` and the pin, with the real
index/worktree untouched. See WAVE-18H-REPORT.md for full evidence.


### Release R1 — non-component framework exports (`tab/060`, `f511949e6b`)

No ABI or bridge version change. A non-component framework exports only
`chrome/app/framework.exports`, and that list had stopped tracking the header
after tab/018: the first release build (`out/ReArc-release-arm64`) exported 52
of 110 ABI functions. tab/060 lists the 58 missing functions in
`framework.exports` and in `framework.order` ahead of `_ChromeMain`. The release
framework's `nm -gU` now matches the dev `libchrome_dll.dylib` (110), and
`verify_chrome_framework_order` passes. Replay 61/61 matches HEAD
`f511949e6b2f0910634df6b10e1f938018674496` and the pin (`engine/replay-r1.log`).
Component dev builds are unaffected. See RELEASE.md.
