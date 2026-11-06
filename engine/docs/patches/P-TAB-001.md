# P-TAB-001 — Browser-less tab registry and native content hosts

Status: implementation spec, not an existing patch. Required. Rebase risk:
**medium for registry code, high for Chrome service integration**. Depends on
P-APP-001 for main-thread lifecycle and startup-profile ownership.

Paths/symbols were checked remotely at Chromium `156.0.8078.74`, commit
`d331de35ca8ab1358c7a17e4bd41627d55eaef51`. No compilation/runtime validation
has occurred. Confirm signatures, keyed-service availability and GN ownership
against the engineer's checkout before authoring hunks.

## Model boundary

All browser chrome remains native. The existing engine design also chooses
not to create Chrome `Browser`/`BrowserView`: implement a bridge registry of
owned `content::WebContents`. Do not treat this as “replace TabStripModel's
visual tab strip.” TabStripModel is a backend model and can exist without a
horizontal strip, but its modern desktop tab/features pipeline has additional
window interfaces. This spec does not silently reintroduce that pipeline.

At this pin the relevant upstream map is:

| Exact path / symbol | Relevance; planned change |
|---|---|
| [`chrome/browser/ui/tabs/tab_strip_model.{h,cc}`][strip], `TabStripModel::{InsertWebContentsAt,CloseWebContentsAt,MoveWebContentsAt,DetachWebContentsAtForInsertion}` | Backend ownership/selection/close and collection behavior; inspect for semantics, **do not patch or instantiate** for the registry route. |
| [`chrome/browser/ui/tabs/tab_model.{h,cc}`][tabmodel], `tabs::TabModel`, `DiscardContents`, `DestroyAndTakeWebContents` | Desktop TabInterface implementation owns WebContents and refers to TabStripModel. Not a stand-alone content container. No hunk planned. |
| [`components/tabs/public/tab_interface.h`][interface], `tabs::TabInterface::{GetContents,GetBrowserWindowInterface,RegisterWillDiscardContents}` | Shared tab interface, including content replacement semantics. Does not erase browser-window dependencies. No hunk planned. |
| [`chrome/browser/ui/tabs/tab_features.cc`][features], `tabs::TabFeatures::Init` and `WillDiscardContents` | Init CHECKs a BrowserWindowInterface and installs many Chrome features. Do not bypass CHECK or use testing suppression as a production implementation. |
| [`chrome/browser/ui/tab_helpers.{h,cc}`][helpers], `TabHelpers::AttachTabHelpers` | Legacy helper entry point is outside `ui/tabs/`; warns desktop Chrome should use TabFeatures. Audit helpers individually rather than attach everything. |
| [`content/public/browser/web_contents.h`][contents], `WebContents::Create`, `CreateParams`, `SetDelegate`, `GetNativeView`, `DispatchBeforeUnload`, `ClosePage`, visibility and discard APIs | Use public content APIs; no native-view accessor patch is necessary. |
| [`content/public/browser/web_contents_delegate.h`][delegate], `WebContentsDelegate` | Implement required browser behavior in additive delegate class. Critical overrides below. |
| [`content/public/browser/web_contents_observer.h`][observer], `WebContentsObserver` | Additive observation only; lifecycle/main-frame and async-generation filters below. |
| [`chrome/browser/chrome_content_browser_client.cc`][client], `ChromeContentBrowserClient::GetWebContentsViewDelegate` | Add one embedded-mode branch returning an additive ReArc WebContentsViewDelegate rather than blindly using `CreateWebContentsViewDelegate`. This factory is consulted during content construction; a post-Create tab tag is too late for that decision. |
| `chrome/browser/ui/tab_contents/chrome_web_contents_view_delegate.h`, `CreateWebContentsViewDelegate`; [`content/public/browser/web_contents_view_delegate.h`][viewdelegate] | Audit Chrome factory and implement native window, responder/focus and context-menu integration through the content view-delegate seam. Follow implementation from the pinned checkout; mac implementation filenames may differ. |
| [`content/browser/web_contents/web_contents_view_mac.mm`][macview], `WebContentsViewMac::{GetNativeView,GetContentNativeView,CreateView,CreateViewForWidget}` | Reuse container and native widget lifecycle, no hunk initially. GetContentNativeView is a render-widget view and may be nil/change; GetNativeView is the content container. |
| [`content/browser/renderer_host/render_widget_host_view_mac.mm`][rwhv], `RenderWidgetHostViewMac::{GetNativeView,SetBounds,Focus}` | Reuse renderer input/screen/accessibility integration; do not expose this object/layer as the shell's lifetime anchor. |
| [`chrome/browser/favicon/favicon_utils.{h,cc}`][favicon], `favicon::CreateContentFaviconDriverForWebContents`; [`components/favicon/content/content_favicon_driver.h`][driver] | Explicit per-WebContents favicon adapter; observe driver completion, encode decoded bitmap as PNG. No modification expected. |
| [`chrome/browser/ssl/chrome_security_state_util.h`][security], `chrome_security_state::{GetVisibleSecurityState,GetSecurityLevel}` | Audit dependencies and security adapters for browser-less content. Report unknown until valid, not HTTPS-derived secure. No speculative old SecurityStateTabHelper filename. |
| [`content/public/browser/media_session.h`][media], `content::MediaSession::Get`, `AddObserver`, `Resume`, `Suspend` | Per-tab media adapter; no new mojom required for observation. |
| [`chrome/browser/resource_coordinator/tab_lifecycle_unit.cc`][discard], `TabLifecycleUnitSource::TabLifecycleUnit::{Discard,FinishDiscard,FinishDiscardAndPreserveWebContents}` | Chrome policy has TabStripModel dependencies and both replacement and stable-content discard paths. Do not call it with a null TabStripModel. Optional registry discard needs its own tested adapter/policy. |
| `chrome/browser/BUILD.gn`; `chrome/browser/rearc_bridge/BUILD.gn` (new) | Add bridge source-set dependency to the target owning browser code; confirm exact target in the checkout. New per-area GN ownership may differ from this monolithic source list on a later pin. |

## Additive implementation

Suggested original files in `chrome/browser/rearc_bridge/`:
`tab_registry.{h,cc}`, `tab_session.{h,cc}`, `tab_delegate.{h,cc}`,
`tab_observer.{h,cc}`, `web_contents_view_delegate_mac.{h,mm}`,
`content_host_mac.{h,mm}`, and favicon/media/security adapters. These are
proposed names, not Chromium symbols. P-NAV can share the observer but should
remain a separate logical adapter.

`TabRegistry` owns monotonic IDs and `TabSession`s on UI/main. A TabSession
owns its WebContents, delegate, observer/subscriptions, profile keepalive,
shell space/order metadata, close state, content-generation counter and at
most one native attachment. Do not expose a WebContents pointer to Swift.
Hold a loaded `Profile*` through its proper manager/keepalive lifetime, not
an NSView retain. Destroy every session before releasing that profile.

### Create, navigate, adopt and close

1. Validate readiness/profile/window/opener IDs and URL/scheme policy before
   allocation. Reserve tab ID, create content from that BrowserContext,
   install delegate and audited services, then reply and emit tab.created
   before initial updates/navigation. Start hidden; no active window is
   inferred from a space ID. Explicit shell-created opener semantics need
   a supported SiteInstance/opener path; until verified reject nontrivial
   script-opener requests rather than create false window.opener relationships.
2. Implement `WebContentsDelegate::OpenURLFromTab`, `AddNewContents`,
   `ActivateContents`, `IsContentsActive`, `CloseContents`,
   `BeforeUnloadFired`, `NavigationStateChanged`, `LoadingStateChanged`,
   `TakeFocus` and `GetJavaScriptDialogManager`. `AddNewContents` adopts the
   Chromium-created unique_ptr rather than recreating a tab from its URL;
   preserve opener, BrowserContext, disposition and security policy. Renderer
   activation requests must obey focus/gesture policy, not steal focus.
3. Before returning from AddNewContents, establish a valid native host/view
   parent or a deliberate hidden staging state consistent with upstream's
   reparenting requirement. A later SwiftUI update is not synchronous
   reparenting. Block unsupported window dispositions predictably. Popup
   blocking/permissions and shell placement need the review Q4 decision; do
   not advertise full popup fidelity on a URL-only recreation implementation.
4. For ordinary close, serialize one pending close; dispatch beforeunload,
   honor cancellation, then run ClosePage and await CloseContents/unload
   completion with an explicit unresponsive-page policy. Forced close can
   skip page veto but must still detach native children and cancel observers.
   If confirmation UI is absent, a custom JavaScriptDialogManager cancels a
   requested beforeunload confirmation conservatively; returning null alone
   is not proof of that policy. Do not destroy the session from inside a
   delegate/observer callback that Chromium is still using: schedule final
   destruction after that callback unwinds, with close state idempotence.
5. Renderer crash reports `PrimaryMainFrameRenderProcessGone` as tab.updated
   is_crashed; keep the tab/content model and allow reload. Window.close only
   detaches/hides tabs. No BrowserList auto-close or session-restore service is
   assumed. Destroy content exactly once, including page-requested close and
   shutdown/force-close races.

### Observation and service policy

Use TitleWasSet, DidStartLoading/DidStopLoading, LoadProgressChanged,
OnAudioStateChanged, DidChangeVisibleSecurityState, DidFinishNavigation and
WebContentsDestroyed. Observe primary main-frame commits/error outcomes as
specified by IPC-CONTRACT; prerenders/subframes/BFCache are not interchangeable
with the currently presented page. `DidUpdateFaviconURL` gives candidate URLs;
ContentFaviconDriver/service completion supplies decoded image data. Clear
stale icons on page changes and reject late completions by generation.

The minimum service audit covers JavaScript dialogs/beforeunload, context
menus, select popups, focus traversal/keyboard shortcuts, file chooser,
download callback completion, TLS interstitials, safe browsing/security state,
media/capture permissions, fullscreen and external protocols. Inventory
whether each needs Profile services, TabInterface, BrowserWindowInterface,
Browser or Views. For baseline unsupported operations, explicitly cancel/deny
through the upstream callback without hanging or bypassing checks. General
permission UI is a separate contract decision; it does not justify silently
allowing requests or weakening navigation/TLS policy.

Whitelist browser-independent helpers. Do not mass-copy upstream helper
initialization or add null checks until CHECKs stop firing: that does not
establish correct lifecycle or a working security boundary. Some features
will need more than a one-line hook; record each justified upstream hunk.

### Content hosts and pixels

A bridge-owned stable NSView host embeds
`web_contents->GetNativeView().GetNativeNSView()` on main. The shell wraps
that host in NSViewRepresentable and holds an attachment lease, not ownership
of the WebContents or RenderWidgetHostView. Install child autoresizing/layout
without overwriting its layers. The content container handles renderer-view
replacement; generation-check a genuine WebContents replacement separately.

The rendering chain is Blink compositor frames → Viz/GPU → browser-side
BrowserCompositorMac/ui::AcceleratedWidgetMac → gfx::CALayerParams →
RenderWidgetHostNSViewBridge/DisplayCALayerTree → native-layer presentation.
Remote CA contexts/IOSurfaces represent pixels; a CALayer pointer from the GPU
process is not an NSView ownership transfer. The shell does not extract or
re-composite those layers.

Manage native-window registration and one live attachment per tab. On detach,
window closure, content replacement or engine shutdown, remove the child and
invalidate the lease before content destruction. A retained empty host remains
safe until SwiftUI dismantles. Reattach for cross-window moves; never add one
live view to two parents. Match IPC event order even if close races a pending
attach reply.

Use AppKit point bounds and the real window's backing scale/screen. Preserve
content/view screen-coordinate, window-key/first-responder, IME, accessibility,
context menu, drag/drop and popup paths. Resize via host layout/content APIs;
do not set a scale on a GPU layer to simulate a display change. Reconcile
window visible panes, requested presentation and occlusion in one path;
WasHidden is not renderer freezing, discard or automatic media pause.

### Discard and pin scope

No baseline automatic-discard promise. `tab.set_pinned` is bridge metadata and
an eligibility rule for any future bridge policy, not a universal Chrome
pinning property. M156 has `WebContents::Discard(base::OnceClosure)` and a
feature-controlled preserving path as well as Chrome's replacement path.
If implementing `tab_discard`, test feature configuration, eligibility,
history/reload state, wasDiscarded semantics, observers and view generation.
A fallback replacement must invalidate leases, retain tab ID/navigation state,
reattach helpers and restore on activation. Do not kill a RenderProcessHost:
process sharing/site-isolated frames make that the wrong unit of ownership.

## Estimated size and rebase risk

Budget **30–120 upstream changed LOC in 2–4 factory/build/service hook files**
and **1,600–3,000 additive engine LOC**, with **700–1,200 test/harness LOC**
for the baseline registry/delegates, native leases and favicon/media adapters.
These are planning estimates, excluding navigation's full adapter, optional
discard/PiP and broad browser feature parity. Service audits may invalidate
that range. Optional discard adds roughly **250–600 LOC** plus tests.

Registry logic is medium risk; Chrome helper migrations from WebContents to
TabInterface/TabFeatures/BrowserWindowInterface make service integration high
risk. New files do not eliminate API rebase work. Audit those migrations and
content discard/replacement behavior on every Chromium bump.

## Test plan and exit criteria

- Registry tests with a Chromium task environment: unique IDs, validation,
  same-profile opener restrictions, create/reply/event order, stale IDs,
  FIFO commands, reorder/membership, observers cancelled on close and late
  favicon/media completions. Use lower-level tests for state machines, not
  mocks that merely mirror call order.
- Integration/browser tests use the real loaded Profile and BrowserContext
  with **no Browser/BrowserView/TabStripModel**. Create/navigate/background and
  activate tabs, same-document/back-forward/error commits, site/process swaps,
  cross-site frames, prerender activation/BFCache and primary-page filtering.
- beforeunload absent/accept/cancel; unload completion; page window.close;
  unresponsive renderer; simultaneous close/force/shutdown; confirmation UI
  unavailable. No orphaned completion, premature destruction or duplicate close.
- window.open/target=_blank/link dispositions: adopt exact created content,
  preserve opener/SiteInstance policy, obey popup block and user-gesture rules,
  support hidden staging/placement or reject predictably. Cross-profile move
  must not mutate BrowserContext or leak cookies/storage.
- Cocoa harness in the actual shell bundle: resize at 1×/2×, move across
  displays/windows, split panes, detach/reattach, minimize/occlude, view
  dismantle and tab.close/attach races. Verify renderer pixels, scale/input
  coordinates, no stale frames/UAF, focus traversal, IME, Cmd keys, drag/drop,
  select popups and VoiceOver. A screenshot alone cannot validate input or
  native lifetime.
- Favicon redirect/no-icon/cache-miss/large icon and late completion after
  navigation/close; correct PNG/ref/profile scoping. Security state must not
  claim secure for certificate errors, mixed/unsafe state or an uninitialized
  adapter. Cancel unsupported dialogs, downloads, file/media permissions and
  external protocol requests without bypasses or hung callbacks.
- Independent media sessions in two tabs; audibility vs playback vs mute;
  no globally focused-session control by mistake. Hidden audible/capture tabs
  continue according to Chromium policy. Renderer crash leaves a reloadable
  tab; GPU restart redraws every live host without recreating shell tabs.
- If discard capability is advertised: both applicable discard configurations,
  protected/pinned/visible/capturing refusal, history preservation, same-ID
  activation reload, wasDiscarded and native view/observer replacement. Verify
  discarding one tab never kills a shared renderer's other tabs.
- Release assembly: teardown native hosts/compositors before Profile and
  browser threads, no content callbacks after terminal events, valid signed
  helper launches/sandbox and exported ObjC/C API. Run under ASan where
  practical, with DCHECK assertions enabled in the integration configuration.

[strip]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/ui/tabs/tab_strip_model.h
[tabmodel]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/ui/tabs/tab_model.h
[interface]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/components/tabs/public/tab_interface.h
[features]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/ui/tabs/tab_features.cc
[helpers]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/ui/tab_helpers.cc
[contents]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/public/browser/web_contents.h
[delegate]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/public/browser/web_contents_delegate.h
[observer]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/public/browser/web_contents_observer.h
[client]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/chrome_content_browser_client.cc
[viewdelegate]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/public/browser/web_contents_view_delegate.h
[macview]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/browser/web_contents/web_contents_view_mac.mm
[rwhv]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/browser/renderer_host/render_widget_host_view_mac.mm
[favicon]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/favicon/favicon_utils.h
[driver]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/components/favicon/content/content_favicon_driver.h
[security]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/ssl/chrome_security_state_util.h
[media]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/public/browser/media_session.h
[discard]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/browser/resource_coordinator/tab_lifecycle_unit.cc

---

## Drift log (implementation waves append here, newest last)

### 2026-11-02 — S1 landed (`tab/006`, commit `526c989d9c`)

- **Filename drift confirmed (the "mac implementation filenames may differ"
  caveat in the seam map above):** there is no
  `chrome_web_contents_view_delegate.cc` under
  `chrome/browser/ui/tab_contents/` at this pin. Desktop (including macOS)
  uses the Views implementation,
  `chrome/browser/ui/views/tab_contents/chrome_web_contents_view_delegate_views.cc`
  — unusable browser-lessly: it resolves
  `GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(...)` (always
  null in registry mode) and its context-menu path is Views-based. Android
  has its own. ReArc's replacement is the additive
  `chrome/browser/rearc_bridge/web_contents_view_delegate_mac.{h,mm}`.
- All other S1 deviations (derived engine-mode predicate, provider seam,
  platform guards, GN placement) are recorded in
  [P-TAB-001-SLICES](P-TAB-001-SLICES.md) §8.
