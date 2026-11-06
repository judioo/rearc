# Wave 18d implementation report

Chromium **156.0.8078.74**, upstream pin `d331de35ca8ab1358c7a17e4bd41627d55eaef51`.
Starting overlay HEAD `3be2bd6fdb`. Final ABI **1.25**, bridge **0.27.0**,
Configure major **1**. One writer, no subagents, no pushes, no outer-repository
commits. `shell/` was left untouched; concurrent shell work was not staged or
reverted. Existing output-directory symlinks were preserved.

## Patch inventory and shell adoption

Each implemented concern has its own additive patch, minor bump and feature.
Gate shell adoption on both the minor and feature string. Existing callback
and ABI 1.17/1.22 structure layouts remain unchanged. Public declarations are
in `chrome/browser/rearc_bridge/rearc_engine_abi.h`; [C-ABI.md](C-ABI.md#profile-history-query-and-deletion-123)
documents ownership, validation, numeric states and exact call semantics.

| Patch | Commit | ABI / bridge | Feature / new API |
|---|---|---|---|
| `tab/041-profile-history-query.patch` | `0638fbe4ec` | 1.23 / 0.25.0 | `history_query`; `ReArcHistoryQuery`, `ReArcHistoryDeleteURL`, `ReArcHistoryDeleteRange`, `ReArcHistoryEntry` |
| `tab/042-dangerous-download-actions.patch` | `164051a14b` | 1.24 / 0.26.0 | `dangerous_downloads`; `ReArcDownloadGetWarning`, `ReArcDownloadResolveDanger`, `ReArcDownloadWarning` |
| `tab/043-preserving-tab-discard.patch` | `1434c7b833` | 1.25 / 0.27.0 | `tab_discard`; `ReArcTabDiscard`, `ReArcTabGetDiscardState`, tab-event kinds 5/6 |

### Profile history

The new per-call async channel queries the addressed profile's HistoryService.
Empty text returns recent unique URLs, newest first; nonempty text uses
Chromium's title/URL matching. Rows contain borrowed title/URL strings, visit
time in Unix microseconds and the total URL visit count. Limit 1..1000, text
<=4096 UTF-8 bytes, result strings <=8 MiB, <=64 pending operations. Host
contexts can carry a command-bar request generation to ignore older results.

Deletion uses DeleteURLs or ExpireHistoryBetween for a local [begin,end) range.
A zero endpoint is unbounded; (0,0) is all local history. DeleteURLs has no
completion callback, so a bounded query on the same sequenced backend acts as
its completion barrier. OTR rejection precedes the EXPLICIT_ACCESS factory
lookup, preventing access to the original profile through an OTR ID. Profile
release cancels outstanding observation exactly once, before close completion;
a deletion already dispatched can still take effect. No SQLite implementation
or remote-history deletion is added.

### Download warning decisions

Wave 18b already exposes danger_type. Its event layout and action numbers 0..5
remain unchanged, including action 6 being invalid for legacy hosts. A separate
warning query supplies current dangerous/insecure booleans and Chromium's
insecure status; a separate action maps 0 keep / 1 discard to DownloadItem.
Keep validates insecure first, then dangerous on another explicit user decision
if that warning remains. Discard removes the item and file through Chromium.
Neither action opens the downloaded content. Calls never access an item after
validation/removal, which may delete it synchronously.

Danger 4 means a pending scan and 6 means user-validated; neither alone means
there is a keepable warning. Use the warning booleans. Queued event snapshots
can outlive item removal, so a warning query can return not_found before the
removed event is delivered. The shell continues using the existing event stream
for lifecycle/progress and gates only its new decision controls on 1.24.

### S7 tab discard

Embedded Run merges WebContentsDiscard into enabled features; desktop Chromium's
stock/headless default is unchanged. An explicit disable switch still wins.
The bridge calls the preserving WebContents::Discard path directly, without
TabLifecycleUnit, TabStripModel, replacement contents or process termination.
It rejects presented/loading/protected tabs and script/peek installation.
This preserves the same WebContents, profile/tab/content-generation, navigation
entries, helper/script registrations and native lease. No view invalidation or
reattachment is needed. Evaluation/snapshot and prompt/menu work cancels; find
ends with reason 5 discarded. Visibility and valid activation reload through
Chromium's controller, and the restored document advances document identity.

Kind 5 in the original ReArcTabEvent means discarded and kind 6 means discard
cleared. Both carry URL/title and the normal identity; creation/state refresh
includes the current state after the updated snapshot. The shell maintains its
bool from these kinds or queries it directly. Legacy structure layouts and
updated-event bitmask fields are unchanged. Hiding alone does not discard.

Logical discard is immediate; renderer resource release is asynchronous. The
operation does not wait on a renderer, allocate replacement contents or kill a
potentially shared renderer process. Chromium flushes BFCache. There is no new
automatic pressure scheduler, pinned-tab policy or footprint guarantee. The
shell can explicitly discard a hidden pin to reclaim its document.

The first runtime attempt found PerformanceManager's TabPageDecorator assumed
every discarded PageNode was a TabStripModel tab. It now ignores same-node
preserving discards of non-tab pages, which have no TabHandle, and retains all
real-tab invariants. Other PageNode observers still receive the discard.
No fake tab identity or BrowserWindowInterface was introduced.

### DevTools audit and disposition

Wave 18g reconsidered the stock **engine-owned undocked Browser window** route.
It remains skipped: target detach uses asynchronous frontend ClosePage; bridge
profile/shutdown completion does not join that lifetime, and close_controller
lacks Chromium's frontend-before-target beforeunload interception/veto protocol.
The global embedded view delegate also has no native-window provider for a
stock frontend. The expanded source audit and required runtime matrix are in
[WAVE-18G-REPORT.md](WAVE-18G-REPORT.md#devtools-reconsideration-and-disposition).
No `devtools` feature or stock-window opener is advertised.

**Skipped; Inspect remains unsupported and no DevTools feature is advertised.**
The existing entry point can identify a browser-less inspected target, but the
frontend/window lifetime is not integrated with ReArc. This is a scope decision,
not a claim that Chromium cannot debug these contents.

| Pin source / seam | Exact finding / work needed |
|---|---|
| `chrome/browser/devtools/devtools_window.cc`: ToggleDevToolsWindow → Create | Creates a frontend WebContents and DevToolsUIBindings. Without an inspected Browser, Create disables docking; the fallback is an undocked DevTools window. |
| `DevToolsWindow::Show` → CreateDevToolsBrowser | Calls CreateBrowserWindow(CreateForDevTools) and inserts frontend contents into that Browser's TabStripModel. This is a separate Browser/native-window/keepalive ownership domain, outside the bridge's registry. It is not a hosted shell tab. |
| `rearc_engine_abi.mm`: ContinueShutdown / FinishShutdown; profile registry | Bridge shutdown joins registry tabs and releases registered profiles/shell keepalive. It does not own, await or explicitly force-close an auxiliary DevTools Browser; profile close similarly does not track its frontend. A one-line OpenDevToolsWindow call would add unreviewed close/veto/OTR/profile/shutdown interactions. |
| `web_contents_view_delegate_mac.mm`: embedded native-window provider | Embedded contents resolve their native window through the bridge attachment provider. A stock auxiliary Browser frontend has no bridge lease/provider. Engine-owned window support needs explicit native-window/focus/closure integration and runtime validation. |
| `devtools_ui_bindings.h/.cc`: Delegate and DefaultBindingsDelegate | A browser-less hosted frontend needs an owned delegate for activation/closure, inspected target identity, docking refusal, inspected-target close and auxiliary actions. The default search-results action dereferences FindBrowserWithTab without a null check. Reusing the default delegate unchanged is unsafe. |
| DevToolsUIBindings local frontend operations; bridge URL policy | Frontend bindings include local file/workspace/save operations and privileged target attachment. The current trusted-tab URL policy rejects devtools and chrome://devtools. A hosted implementation needs an internal bundled-frontend creation route, explicit binding capabilities, target/lifetime ownership and a policy for file/window actions; broad URL admission is insufficient. |

A follow-up can either integrate the stock engine-owned DevTools Browser into
native-window/profile/shutdown ownership, or add a registry-owned bundled
frontend with a dedicated bindings delegate and restricted creation route.
It must prove repeat open/reuse, inspect-element targeting, target navigation,
frontend/target close in either order, OTR isolation and forced/nonforced
profile/engine teardown. No broad DevTools URL admission, remote-debugging
listener or partial UI is shipped by this wave.

*Superseded in wave 18h:* tab/058 (`a95beb7f31`, ABI 1.40, `devtools`) takes
the registry-owned route: `ReArcTabOpenDevTools` creates a bundled frontend
registry tab with restricted bindings and its own URL throttle. No Browser or
DevToolsWindow is used. Native tests cover each close order, OTR profile close,
shutdown and shutdown during a target veto. See WAVE-18H-REPORT.md.

## Validation

Final build **p68** passes in `out/ReArc-dev-arm64`. History builds p64/p65,
download build p66 and discard build p67 also pass. p63 failed on Chromium's
raw_ptr annotation requirement and was corrected. No executable-source changes
followed p68; the final S7 commit additionally corrects comments.

Final validation (run by the orchestrator after the Codex session hit its usage limit, sequentially, no builder active): `run_w18d_gates.py` → ALL WAVE 18D GATES PASS (`gates-w18d-final.log`); `check_w18d_imports.py` → ABI 1.17 layouts preserved PASS, Swift gated adoption PASS (`imports-w18d.log`); `run_compat_w18d.py` → ABI 1.17 HEADER RUNTIME PASS, 4 hosts / 6 process runs (`compat-w18d.log`).

All native ABI, smoke and stress processes use **--use-mock-keychain** and
disposable profiles. The dangerous-download fixture uses Chromium's existing
manual hash blocklist and inert .sh bytes; no file is opened/executed. Discard's
fixture uses process-per-site so its sibling-state check covers a shared
renderer. Prior permission/password/WebUI/helpers tests retain their isolated
test-only loopback CDP setup and Browser.close keepalive cleanup; no new
production debugging listener is added.

History's first runtime pilot hit Chromium's all-time restricted-expiration
DCHECK; the implementation now uses DeleteURLs and the backend barrier.
Download's typed-address-bar .dmg pilot was allowed by Chromium and timed out
waiting for a warning; link-transition .sh avoids that allow rule. A subsequent
pilot queried a retired item from its queued cancellation event; the fixture
now accepts that event ordering. S7's p67 runtime pilot hit the non-tab
PerformanceManager CHECK, corrected before p68. Pilot evidence is retained and
is not counted as passing validation. Three parallel static-check launches also
stopped at the raw build guard because their pgrep probes matched one another;
no tests ran in those attempts. The final checks run sequentially.

The shared build guard now requires the raw `pgrep -fl "siso ninja"` result to
be empty before every runner/process test, in addition to the executable-name
check. An initial danger run was held by a concurrent shell self-test wrapper
quoting that pattern; validation waited for it to finish. No builder was active
during runtime validation, and no real Keychain access was used.

Reproduction from the project root (no active builder or matching wrapper):

```sh
engine/scripts/build.sh
python3 engine/tests/run_w18d_gates.py
python3 engine/tests/check_w18d_imports.py
python3 engine/tests/check_c_abi_exports.py engine/nm-w18d.log
python3 engine/tests/run_compat_w18d.py
python3 engine/tests/replay_overlay.py > engine/replay-w18d.log
```

Run the commands sequentially, checking the build guard before standalone
export/replay invocations as well.

## Replay

REPLAY PASS 44/44 reverse and forward; forward tree `4d3b2d2c7fa9619f7458e4a43c10b06e25a6d121` matches HEAD `1434c7b8338ed1fb094ed604c341a8583db1e607`; real index/worktree untouched. Log: `replay-w18d.log`.

Series entries, patch headers, C-ABI.md, IPC-CONTRACT.md, SMOKE-TEST.md and §8 of
P-TAB-001-SLICES.md are updated. All three commits carry the overlay author,
rebase-pin header and Codex co-author trailer. No push was run.

## What was not done

- Browser-less DevTools frontend/Inspect, for the concrete ownership/bindings
  reasons above. No feature or ABI bump is claimed for the skipped concern.
- Remote/synced history deletion, pagination, all-visit duplicate rows or a
  replacement history database. Recent query returns the latest visit per URL.
- An independently generated insecure or uncommon download verdict; their
  production actions share Chromium's existing validation/removal methods.
  No download scanner/policy bypass or downloaded-file execution is added.
- Automatic memory-pressure/pin scheduling, aggressive discards of protected
  tabs, renderer-process kills, or a measured RSS-reduction guarantee. Discard
  is asynchronous and preserves WebContents; renderer reclamation can wait for
  an unresponsive renderer without blocking the bridge's API/shutdown.
- Real Keychain access, physical camera/microphone authorization, production
  packaging/signing/notarization, or shell UI edits/validation.

WAVE 18D DONE head=1434c7b8338ed1fb094ed604c341a8583db1e607 abi=1.25 replay=pass
