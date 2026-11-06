# ReArc Shell ↔ Engine IPC Contract

Contract: **rearc.ipc.v1**, major **1**. Status: corrected, unimplemented
design baseline. This revision changes the earlier draft before any engine
implementation exists; it does not claim wire compatibility with that draft.
A shipped implementation would need a major-version migration for equivalent
field, enum and request/reply changes.

S = native Swift shell; E = Chromium browser process linked in the same
process. The data messages are asynchronous. Native view handoff is a
separate, **in-process-only** typed bridge facility, specified below.

v1 covers tabs, navigation, shell spaces/windows, a startup Chromium
profile, favicon/title and media observation. The implemented native adapter
adds optional profile, script, zoom and isolated-message capabilities below.
Downloads and history UI remain deferred. The engine still needs
safe browser-service policies for page requests involving those facilities;
absence of UI is not authorization to bypass policy.

## 1. Envelope, compatibility and dispatch

| Field | Type | Meaning |
|---|---|---|
| `contract_version` | u32 | Selected major; 1 for the initial hello. |
| `message_id` | u64 | Nonzero sender-local monotonic ID, never reused on this connection. |
| `correlation_id` | u64, optional | Reply/error references the initiating request or command's `message_id`. Events omit it. |
| `type` | string | Message name. |
| `payload` | table | Message-specific data. |

Types: string, u32, u64, i32, f64, bool, bytes, enum, table, array<T>.
`time` is f64 Unix seconds. Sizes are finite, nonnegative f64 values in
AppKit points; scale factors are finite positive hints. ID 0 is invalid.
A JSON adapter must preserve u64 precision, e.g. with decimal strings under
an explicit adapter rule; never pass IDs through an IEEE-754 JSON number.

Adding optional data/messages is a minor extension. Removing fields,
changing types, closed enum values or established semantics is a major
change. Ignore unknown optional fields. An unknown request/command receives
`error{unsupported}` with correlation; unknown events may be logged/dropped.
Do not silently drop a request and strand its completion.

`engine.hello` offers `supported_versions`; E chooses the highest major it
also implements, or returns `version_mismatch`. A lower number is not
implicitly backwards-compatible. The hello envelope/payload shape above is
the v1 bootstrap format. No tab commands are served before hello succeeds.
Capability strings gate optional commands/events. Repeated hello is an error.

Messages marked request/reply receive exactly one `*.reply` or `error` while
the host process is alive. Command success has no reply; command rejection
produces a correlated `error`. A process crash terminates all guarantees.
Connection closure fails outstanding completions locally; it is not an engine
message. No synchronous waits or callbacks into shell code while a Chromium
mutation/delegate stack is active.

S→E calls are marshalled to the **main Chromium UI thread**, FIFO per bridge
connection. E→S messages are delivered asynchronously on main in a serialized
emission order. Chromium work uses its UI task runner; main-queue dispatch
alone is not a replacement for Chromium scheduler integration. Coalescing
must flush before lifecycle terminal events. Reentrant shell callbacks must
be deferred until the originating mutation finishes.

**Identity ownership:** E allocates `tab_id`, `profile_id`, `attachment_id`
and the connection's `session_id`. S allocates nonzero `space_id` and
`window_id` values for this session and persists its own UUID mapping.
All IDs are session-scoped and never reused by their allocator. Space IDs
are shell grouping labels, accepted on first use; no engine space-creation
API is implied. Window IDs must first be registered with `window.created`.
`client_ref` is opaque shell data echoed with the corresponding creation.
Stale IDs from a previous session are rejected, not rebound.

## 2. Engine lifecycle

| Message | Dir | Payload / result | Semantics |
|---|---|---|---|
| `engine.hello` | S→E request/reply | `supported_versions: array<u32>`, `shell_version: string`, `client_name: string` | First message; may await startup readiness. |
| `engine.hello.reply` | E→S | `contract_version: u32`, `engine_version: string`, `engine_build: string`, `session_id: u64`, `default_profile_id: u64`, `max_blob_bytes: u32`, `features: array<string>` | Sent only when startup profile and browser services are ready. `engine_version` reports the compiled version, not an assumed pin. `max_blob_bytes` advertises a nonzero encoded-blob limit; its deployment value remains policy. |
| `engine.shutdown` | S→E request/reply | `reason: enum("user_quit","update","crash_recovery")`, `force: bool` | Stop accepting new work and close tabs. Nonforced beforeunload may cancel shutdown; `crash_recovery` is an orderly host-relaunch reason, not browser hot restart. |
| `engine.shutdown.reply` | E→S | `outcome: enum("stopped","cancelled")` | `stopped` follows view invalidation and all `tab.closed` events, after browser teardown. Delivered by the host lifecycle completion once the run entry point returns; do not depend on a destroyed Chromium task runner. Last message on success. `cancelled` resumes serving. |
| `engine.ping` | S→E request/reply | — | Reply name is the exception `engine.pong`. |
| `engine.pong` | E→S | `engine_time: time` | Measures response only; cannot detect a stalled main thread from that same thread. |
| `engine.crashed` | E→S event | `component: enum("gpu","utility")`, `detail: string` | Best-effort observed child-process crash. No browser-crash event is possible from a dead shared process. Renderer loss uses tab state. |

A cancelled shutdown is not a transaction rollback: tabs already closed stay
closed unless the shell explicitly restores them.

Without `profiles`, v1 uses `default_profile_id` for all tabs. Startup parameters choose the
user-data directory/profile before hello, and E retains it until all its
WebContents are destroyed. The native `profiles`/`profile_off_the_record` extension below adds creation,
release and private contexts; persistent deletion is not implemented. No same-process Chromium restart or framework
unload/reload is promised; browser-process recovery relaunches the application.

## 3. Tabs

| Message | Dir | Payload / result | Semantics |
|---|---|---|---|
| `tab.create` | S→E request/reply | `space_id: u64`, `profile_id: u64`, `url: string` optional, `background: bool`, `window_id: u64` optional, `opener_tab_id: u64` optional, `client_ref: string` optional | Foreground requests require a registered `window_id`. Omitted URL creates `about:blank`; shell new-tab chrome is separate. Unknown profiles fail. Opener must be live in the same profile; nontrivial script-opener semantics are capability-gated (`script_opener`). |
| `tab.create.reply` | E→S | `tab_id: u64` | Emitted before `tab.created`; no other event for this ID precedes `tab.created`. |
| `tab.close` | S→E request/reply | `tab_id: u64`, `force: bool` | Nonforced close runs Chromium's beforeunload/unload pipeline and may be cancelled. Forced close skips page veto, not content/view cleanup. |
| `tab.close.reply` | E→S | `outcome: enum("closed","cancelled")` | `closed` follows `tab.closed`; cancellation leaves the tab alive. Pending close per tab is unique; concurrent close fails `busy`. |
| `tab.activate` | S→E command | `tab_id: u64`, `window_id: u64` | Selects the focused tab. Only focus an attached visible content view in the key window; otherwise retain selection intent until attachment/window activation. Does not discard other panes or steal focus from shell UI. |
| `tab.move` | S→E command | `tab_id: u64`, `space_id: u64`, `index: u32` | Shell order/membership metadata; zero-based index after removal from the source. Does not change BrowserContext/profile, reparent a view or change page visibility by itself. |
| `tab.set_pinned` | S→E command | `tab_id: u64`, `pinned: bool` | Bridge policy metadata. Exclude pins from any bridge automatic-discard policy. Chromium pinning alone is not a universal never-discard guarantee. |
| `tab.discard` | S→E request/reply | `tab_id: u64` | Optional `tab_discard` capability. No renderer-process kill: that can destroy unrelated tabs/frames. May refuse visible, pinned, capturing or otherwise protected tabs. |
| `tab.discard.reply` | E→S | `discarded: bool`, `reason: string` optional | Successful unload preserves tab ID and navigation state, invalidates/rebinds any replaced content/view generation, and reports `is_discarded=true`. Refusal explains why; unsupported engines return `error`. No automatic discard is promised in baseline v1. |
| `tab.created` | E→S event | `tab_id`, `space_id`, `profile_id`: u64; `url: string`, `client_ref: string` optional; `opener_tab_id`, `window_id`: u64 optional; `disposition: enum("shell","foreground_tab","background_tab","popup")` | Also used for adopted page-created content, preserving Chromium-created SiteInstance/opener state. No implicit Chrome session restore; S restores with `tab.create`. A popup disposition requests shell placement; it does not imply an attached native window. |
| `tab.closed` | E→S event | `tab_id: u64`, `reason: enum("shell","page","engine")` | Final **tab event** after host views are emptied. A renderer crash leaves the tab alive with `is_crashed=true`. Correlated replies may follow. |
| `tab.updated` | E→S event | `tab_id: u64`, `changes: table` | Fields below; coalesced, generation-checked, never emitted after `tab.closed`. |

`changes` contains any of: `url`, `title`: string; `favicon`: table;
`is_loading`, `can_go_back`, `can_go_forward`, `is_crashed`, `is_discarded`,
`is_audible`, `is_muted`: bool; `load_progress`: f64 in [0,1];
`security_state`: enum("secure","insecure","dangerous","none","unknown").

The adapter publishes a full initial presentation snapshot after
`tab.created`. `url` is Chromium's validated visible URL, not an untrusted
renderer string. `security_state` comes from Chromium's visible-security-state
machinery; never infer secure from an `https` prefix. Until its adapter is
implemented, report `unknown`. A renderer crash is not a tab close. Clear
crash/discard flags when the corresponding recovery transition succeeds.

Normal close requires `WebContentsDelegate` and a JavaScript-dialog policy.
Until native confirmation UI is implemented, a beforeunload prompt is
cancelled conservatively and `tab.close.reply{cancelled}` is emitted. Never
silently approve it or wait forever. Unresponsive-page timeout policy remains
an open implementation question in the review.

## 4. Navigation

| Message | Dir | Payload / result | Semantics |
|---|---|---|---|
| `tab.navigate` | S→E command | `tab_id: u64`, `url: string`, `transition: enum("typed","link","generated")` | Shell resolves search-vs-URL; E validates GURL, allowed schemes and trusted navigation policy. `link` is classification, not a renderer initiator or user-activation grant. Reload has a separate command. |
| `tab.go_back` / `tab.go_forward` | S→E command | `tab_id: u64` | No-op if unavailable. |
| `tab.reload` | S→E command | `tab_id: u64`, `ignore_cache: bool` | NavigationController reload; safe recovery for a crashed tab. |
| `tab.stop` | S→E command | `tab_id: u64` | Stop current loading. |
| `navigation.committed` | E→S event | `tab_id: u64`, `navigation_id: u64`, `url: string`, `is_main_frame: bool`, `is_same_document: bool`, `is_error_page: bool`, `transition: enum("typed","link","reload","generated","other")`, `transition_flags: u32` | Emit only for `IsInPrimaryMainFrame() && HasCommitted()`. `is_main_frame` is therefore true in v1. Filter prerender/other frame-tree commits. `transition_flags` preserves Chromium PageTransition qualifiers; unknown core values map to `other`. Not every commit adds a history entry. |
| `navigation.failed` | E→S event | `tab_id: u64`, `navigation_id: u64`, `url: string`, `error_code: i32`, `error_text: string`, `is_main_frame: bool` | Primary-main-frame attempt finished with a net error. Error-page commits can also emit committed with `is_error_page=true`. `ERR_ABORTED` is cancellation, not a page to replace with shell error UI. Deduplicate against `DidFailLoad`. |

`navigation_id` maps a session-stable bridge ID to a NavigationHandle lifetime;
E must not expose a raw pointer or retain the handle after DidFinishNavigation.
Same-document commits and error-page commits are explicit so S cannot mistake
a subframe/prerender update for the current page. Back/forward state comes
from NavigationController. Downloads and HTTP 204 do not imply a new commit.

## 5. Spaces, windows and effective visibility

| Message | Dir | Payload | Semantics |
|---|---|---|---|
| `window.created` | S→E command | `window_id: u64`, `client_ref: string` optional | Registers a shell-owned session ID. The typed native bridge registers the corresponding NSWindow on main before view attachment; no NSWindow pointer travels in data messages. Duplicate live IDs are errors. |
| `window.closed` | S→E command | `window_id: u64` | Invalidate/detach attachments and clear this window's selection/visible set; tabs persist, becoming hidden if not otherwise displayed. |
| `space.focus` | S→E command | `space_id: u64`, `window_id: u64`, `tab_ids: array<u64>` | Full set of panes actually presented in that window, not every tab in its sidebar/space. Empty set is valid. Records desired presentation; reconciliation below determines actual visibility. |
| `space.tab_assigned` | S→E command | `tab_id: u64`, `space_id: u64` | Membership update without an ordering index, profile migration or visibility change. |

E combines the current window visible set, attachment state,
`view.set_visible` and actual AppKit window visibility/occlusion. One
reconciliation path calls WebContents visibility APIs: initial
`UpdateWebContentsVisibility`, subsequent WasShown/WasHidden/WasOccluded as
appropriate. An unattached tab is not rendered as visible merely because a
space contains it. All split panes can be visible; one per window is selected
for keyboard focus. Window miniaturization/occlusion is distinct from changing
spaces. A move transfers the attachment; a tab cannot be live in two windows.

Hidden pages remain subject to Chromium background throttling; hidden does
not mean frozen, discarded, muted, stopped or suspended. No process-wide
parking is allowed. Visibility is not an instruction to pause media or an
IntersectionObserver intersection rectangle. Freezing/discard policy needs a
separate capability and media/capture safeguards.

## 6. Native view attachments (v1 in-process extension)

| Message | Dir | Payload / result | Semantics |
|---|---|---|---|
| `view.attach` | S→E request/reply | `tab_id: u64`, `window_id: u64`, `initial_size: {width: f64,height: f64}`, `scale_factor: f64` | Requires native window registration. One live attachment per tab. Second attachment fails `already_attached`; detach before cross-window transfer. Starts hidden until presentation is reconciled. |
| `view.attach.reply` | E→S | `attachment_id: u64`, `native_view_ref: string` | Callback carries a typed, strongly retained bridge host `NSView*` alongside the data envelope. The token is only a registry cross-check, never a serialized pointer. |
| `view.resize` | S→E command | `tab_id: u64`, `attachment_id: u64`, `size: {width: f64,height: f64}`, `scale_factor: f64` | Points, rounded by the bridge to Chromium DIP bounds. Host AppKit layout is authoritative; update screen/scale through native window notifications. Hints cannot override the destination display. |
| `view.set_visible` | S→E command | `tab_id: u64`, `attachment_id: u64`, `visible: bool` | Content presentation intent, combined with §5. Does not control page script/media policy. |
| `view.detach` | S→E request/reply | `tab_id: u64`, `attachment_id: u64` | Remove/empty host on main, clear native references and recompute visibility. Does not destroy the tab. |
| `view.detach.reply` | E→S | `attachment_id: u64` | Lease invalid; host can be released by S. |
| `view.invalidated` | E→S event | `tab_id: u64`, `attachment_id: u64`, `reason: enum("tab_closed","window_closed","content_replaced","engine_stopped")` | Engine has already emptied the stable host. S can safely retain the empty NSView until its representable dismantles, but cannot use the token again. |

The engine owns WebContents and its `GetNativeView()` child. The bridge host
is a stable wrapper suitable for `NSViewRepresentable`; Swift never owns or
caches `RenderWidgetHostViewMac` or GPU layers. Chromium reparents/swaps render
widgets within its container. A WebContents replacement that changes the
leased container invalidates that attachment before replacement and requires
reattachment. Stable-WebContents discard paths need not invalidate the lease.

Every native view, focus, size, host-child removal and lifetime operation is
main-thread-only. Empty the host before WebContents destruction, even when a
close races an undelivered attach reply; suppress that stale reply with a
correlated error or deliver it before invalidation under the serialized
ordering rule. Commands with expired attachment IDs fail `stale_attachment`.
SwiftUI identity changes/dismantle call detach; layout updates do not create
new WebContents. A lease does not grant a second superview.

This native side channel is required in v1. XPC cannot transport NSView or
NSWindow; a future remote surface/input/accessibility protocol changes the
shell embedding adapter and is outside rearc.ipc.v1.

## 7. Favicons and media

| Message | Dir | Payload / result | Semantics |
|---|---|---|---|
| `favicon.get` | S→E request/reply | `icon_ref: string` | Fetch decoded/re-encoded favicon, not an arbitrary URL fetch. Ref is opaque and profile/session-scoped. |
| `favicon.get.reply` | E→S | `format: enum("png")`, `data: bytes` | PNG from Chromium's decoded bitmap; original ICO/SVG bytes are not guaranteed by favicon APIs. Stale/unavailable refs return `not_found`. |
| `media.state_changed` | E→S event | `tab_id: u64`, `playback: enum("playing","paused","stopped","unknown")`, `audible: bool`, `muted: bool`, `pip_available: bool`, `pip_active: bool`, `metadata: table` optional (`title`, `artist`, `album`: string; `artwork_ref: string` optional) | Requires `media_session`; per-WebContents session plus independent WebContents audibility/mute. `stopped` means no active playback session; metadata clears with an empty table. Artwork refs are reserved/omitted until a retrieval capability is defined. |
| `media.set_playback` | S→E command | `tab_id: u64`, `action: enum("play","pause","toggle")` | Requires `media_session`. Resume/suspend the addressed tab's existing session; no promise to start an arbitrary HTML media element or bypass autoplay policy. Reject unavailable actions/session with `unsupported`/`invalid_state`. |
| `media.set_muted` | S→E command | `tab_id: u64`, `muted: bool` | WebContents::SetAudioMuted; independent of MediaSession availability. |
| `media.set_pip` | S→E request/reply | `tab_id: u64`, `active: bool` | Optional `pip_control`. Enter only an eligible upstream video PiP session via its supported action/controller. Exit only the addressed tab's owned PiP session; never another tab's global PiP. |
| `media.set_pip.reply` | E→S | `accepted: bool` | Acknowledges the action; observed PiP state is authoritative. Unsupported default in baseline v1 until controller/delegate integration is tested. |

`tab.updated.changes.favicon` is one of `{page_url,format:"png",data}`,
`{page_url,icon_ref}`, or `{page_url,cleared:true}`. `page_url` is a string;
refs identify immutable cache entries for this session and enforce the tab's
profile boundary. Inline icons are at most the smaller of 64 KiB and
`max_blob_bytes`; fetched PNGs also respect `max_blob_bytes`. Reject larger
payloads with `too_large`; no recursive ref indirection
or unbounded image decode. Cancel/generation-check fetches on close or profile
shutdown. A renderer favicon-URL event supplies candidates, not icon bytes.

Native PiP is **not specified** by the old `media.pip_requested{video_size}`:
dimensions carry no video surface or document WebContents. That draft message
is removed. Do not advertise `pip_native` until a surface/controller lifetime
protocol exists. Default Chrome PiP also requires delegate integration in a
browser-less embedder. `pip_available` is false unless that actionable support
is present. PiP state is distinct from session playback/audibility.
Wave 18e (C ABI 1.30, `picture_in_picture`) provides that delegate integration
for **video** PiP using Chromium's own overlay window, so no surface crosses
the boundary. `media.set_pip` maps to `ReArcTabSetPictureInPicture`. Real
`pip_available`/`pip_active` values are reported once the host registers its
PiP callback. `pip_native` (a shell-owned surface) stays unadvertised, as does
Document PiP. See C-ABI.md.

## 8. Errors and implementation boundaries

`error` carries `code: enum`, `message: string` and envelope correlation.
Codes: `tab_not_found`, `window_not_found`, `profile_not_found`, `not_found`,
`invalid_url`, `invalid_argument`, `invalid_state`, `engine_not_ready`,
`version_mismatch`, `unsupported`, `busy`, `already_attached`,
`stale_attachment`, `too_large`, `cancelled`, `internal`.

Async work captures IDs/generations and weak engine references, not raw
WebContents/profile/view pointers across queues. Fail invalid input without
partially changing ownership. Mutations and events serialize on main.
Never infer a page's permission, origin, user activation or BrowserContext
from shell metadata. Host-rendered page prompt channels are exposed by the
additive native ABI 1.18–1.22 capabilities below. Arbitrary renderer-side
integration remains constrained by the isolated-world/native capability rules.

The ObjC++ API must freeze its C/ObjC types and ownership annotations separately
from Chromium C++ ABI, export symbols in release builds, retain async buffers,
and specify cancellation when the host exits. In-process calls avoid wire
encoding; they still incur validation, copying/retention and scheduling.

## Additive native capabilities (wave 14)

Profile lifecycle is exposed by the C ABI's `profiles` and
`profile_off_the_record`: named persistent keys, unique Chromium OTR children,
sequential tab closure with veto, and child-before-parent teardown. All existing
tab/view/service envelopes retain the actual BrowserContext's profile_id;
Space labels do not migrate storage or live tabs.

`script_evaluation_identity` results include profile/tab/content identity plus a
committed document generation and navigation id. Generation advances only for
primary cross-document commits; same-document commits update navigation id.
The host can query current identity to reject stale retained results directly.
The C ABI keeps its original evaluation callback for ABI 1.5 clients. Privileged
file/WebUI evaluation and PiP remain outside this capability.

`page_zoom` exposes default Chromium HostZoomMap semantics: factors are queried
or set for a tab, and typed asynchronous events report affected tabs. Same-host
tabs in one profile share saved zoom; profile maps remain distinct. This is
browser page zoom, not CSS transforms or pinch scale.

`isolated_page_messages` is a one-way data channel from trusted installed boost
or editor code in isolated worlds. Main-world page code is never given a
binding. Every message carries profile/tab/content/document/navigation identity
and an isolated-world id. Top-frame http(s) only; valid UTF-8 RFC JSON <=64 KiB,
60 attempts per fixed second per tab, <=60 queued deliveries. Invalid/excess
messages are dropped; navigation/close cancels stale deliveries. See C-ABI.md
for the native callback and exact renderer/bootstrap semantics.

`os_permission_shutdown` (native ABI 1.11) keeps read-only macOS TCC preflight
from holding terminal engine teardown. It conveys no permission or encryption
change. The host still retains callback contexts until Run returns and keeps
the framework loaded for the lifetime of the process.

`shutdown_pending_closes` (native ABI 1.12) joins standalone pending tab closes,
retaining their replies and the successful-shutdown-last-callback guarantee.
Normal shutdown preserves veto; force promotes pending cleanup. ProfileClose
continues to serialize separately and must complete before Shutdown is accepted.

`profile_directory` (native ABI 1.13) opens an existing regular profile directory
under the configured user-data-dir in place. The host can assign Default to one
shell profile and persist that directory mapping. It does not migrate live tabs,
copy databases, merge profiles, change startup-profile lifetime or convert keys.

Wave 16 measurements preserve §5/§6: "never attached" does not imply an
attached-pending scheduling exemption. Direct evaluation may complete promptly
while a returned Promise waits for ordinary hidden timers or unavailable rAF.
Use real foreground attachment and explicit document/input events; no global
scheduler switch or inferred visibility change is part of ABI 1.13.

`webui_daily_pages` (native ABI 1.14) admits the audited history, downloads,
password-manager and extensions hosts through the existing trusted navigation
API. Chromium WebUI and profile services supply those pages. It adds no wire
messages, page evaluation/capture privileges, tab helpers or native prompts.
Journeys requires desktop tab integration and remains disabled in browser-less
history; flags remains rejected because its relaunch bypasses host lifecycle.
See C-ABI.md for the per-host action audit and limitations.


## Host prompt channels (wave 18c, native ABI 1.18–1.22)

`javascript_dialogs`, `file_chooser`, `permission_prompts`, `context_menu` and
`password_prompts` are independent additive C callback/reply channels, gated by
minor version and feature query. They do not change any existing message or
native callback layout. Every request carries profile/tab/content-generation
and an engine-allocated request ID. The host copies borrowed page data, draws
its own UI and replies once. Navigation/close/replacement cancels stale
requests; a late reply is `not_found`. Chromium remains authoritative for
origins, permission/storage policy, successful password submission, file grants,
editing and download behavior. No renderer-provided URL/message is a trusted
shell command. Inspect/DevTools remains unsupported in browser-less mode.
See [C-ABI.md](C-ABI.md#host-prompt-channels-wave-18c) for precise event fields,
action/mode enums, nonpersistent permission semantics and cancellation rules.


## Wave 18d native capabilities (ABI 1.23–1.25)

`history_query` provides bounded HistoryService recent/text queries and local
URL/time-range deletion, with explicit OTR rejection and deferred per-call
completions. `dangerous_downloads` adds current warning snapshots and explicit
keep/discard through Chromium validation/removal; the 1.17 download event and
actions retain their layouts/numbers. The existing event already has danger_type.

`tab_discard` implements S7 through preserving WebContents::Discard. The native
adapter maps logical state to new tab-event kinds 5 discarded / 6 discard cleared
without extending the original C structure. Navigation entries, contents
generation and stable view lease survive. Document work cancels, visibility or
activation reloads, and pending find ends with reason 5. No automatic discard,
pin policy, null TabStripModel or renderer-process kill is involved. Unlike a
replacement path, this requires no view.invalidated. The generic design tables
above remain the wire vocabulary; these capabilities are the in-process C ABI.
See [C-ABI.md](C-ABI.md#preserving-tab-discard-s7-125) and
[WAVE-18D-REPORT.md](WAVE-18D-REPORT.md). Browser-less DevTools remains unsupported.
