# Wave 18 implementation report

This pass implements **concern 1 only**, stopping at its validated commit boundary
under the task's budget rule. Concerns 2–9 remain open; none is represented as
implemented by a feature flag. The shell is untouched. No subagents, outer
repository commits or pushes. Chromium baseline `137a0dc3dc`; upstream pin
`d331de35ca` (156.0.8078.74). ABI **1.14**, bridge **0.16.0**, Configure major 1.

| Concern | Chromium commit | Patch | Build / validation |
|---|---|---|---|
| 1: WebUI admission | `b0cc7b4ec6` | `tab/032-audited-daily-webui-admission.patch` | p47/p48; full native suite, G1–G5, 4 stress processes / 16 shutdown tabs |
| 2–9 | Pending | None | No implementation claim |

## 1. Trusted WebUI admission

The `webui_daily_pages` feature admits **history, downloads, password-manager,
and extensions**, alongside settings and version. Create/Navigate and the
internal registration client's scheme-transition policy share one exact-host
predicate. No file/WebUI evaluation, capture, boost or renderer privileges are
added. Chromium controllers, data sources, profile services and handlers supply
the actual pages; the bridge does not implement replacement pages.

Audit of this Chromium pin:

| Host / action | Finding and disposition |
|---|---|
| history classic list/search/removal | BrowsingHistoryHandler uses Profile/HistoryService. Admitted. Native live query succeeds. |
| history Journeys | HistoryUI::CreatePageHandler unconditionally called TabInterface::GetFromContents; HistoryClustersHandler later dereferences BrowserWindowInterface for tab groups/open-all. Disable Journeys when no TabInterface exists and safely disconnect direct handler creation. Classic/grouped route loads without the unsafe feature. |
| history sign-in / clear data | BrowsingHistoryHandler and cross-device sign-in already guard null Browser. Browser-dependent actions can do nothing; shell opens settings/clearBrowserData directly. |
| history synced sessions | ForeignSessionHandler guards service/session availability; its TabStripModel path is side-panel-only. Full-page listing loads. Restoring remote sessions still delegates to SessionRestore's Chrome-window path, not ReArc's tab registry; not claimed as shell integration. |
| downloads | DownloadsUI/DownloadsDOMHandler and list tracker use Chromium DownloadManager. Browser warning-bubble and enhanced-protection paths already guard null Browser; open-file's TabInterface lookup is optional. Attached downloads list initialization succeeds. Admission alone adds no download lifecycle ABI, target-path policy or native tray. |
| password-manager | PasswordManagerUI/handler, PasswordsPrivateDelegate and factories use Chromium password stores. Existing share IPH/passkey-unlock paths guard missing Browser. Three remaining hazards are guarded below. Listing/settings/checkup and saved-password query succeed. OS authentication remains Chromium's. |
| password shortcut | PasswordsPrivateDelegateImpl::ShowAddShortcutDialog DCHECKed Browser and passed it to web-app install. Return without a Browser. Native host invokes the action. |
| password batch upload | SyncHandler passed unchecked GetLastActiveBrowser to BatchUploadService, which later uses browser UI. Only invoke with a Browser. Native host sends OpenBatchUpload. |
| password relaunch banner | NotificationCardsHandler called AttemptRestart directly. Only invoke for WebContents belonging to a Browser. Native host sends restartBrowser then successfully queries the handler again. Embedded process relaunch remains host-owned. |
| extensions | ExtensionsUI uses profile registry/data sources. developerPrivate list/profile APIs work; inspect's later Browser/TabStripModel activation already guards null Browser. File selection, native install/uninstall prompts, inspection windows, toolbar buttons and popups are not claimed by page admission. |
| settings / version | Existing hosts retained. Audit-listed content/siteDetails, search, clearBrowserData and importData remain paths under settings; no new host is needed. Existing Browser-dependent settings limits remain. |
| flags | **Rejected.** FlagsUIHandler::HandleRestartBrowser calls AttemptRestart. The bridge has terminal shutdown and no in-process restart/host relaunch ABI. Simply admitting it would expose an unsupported process lifecycle action. |
| other hosts | Rejected, including bookmarks (not added by this concern), crash, quit, restart, devtools and chrome-untrusted. Prefix lookalikes and view-source:chrome URLs remain rejected. |

Native test `engine/tests/c_abi_webui_host.mm` uses an attached browser-less tab
and tests 11 routes: history root/grouped/syncedTabs, downloads, password-manager
root/settings/checkup, extensions root/shortcuts, settings/content and version.
It checks custom-element shadow DOM and Chromium history, download-list,
password-store and extension-handler responses. Each route rejects evaluation
and snapshot capture through the shipping ABI. An installed isolated HTTP script
still returns 42 after all those scheme transitions. The test covers rejected
hosts through Create; existing URL-policy hosts cover Create/Navigate semantics.

The test's separate loopback DevTools socket is **test-only**. Chromium's
no-startup-window + remote-debugging-port mode deliberately registers a
REMOTE_DEBUGGING keepalive. The initial test reached successful tab closure and
accepted ABI shutdown but timed out with only that keepalive outstanding (sample
and verbose pilot logs retained). The corrected host sends Browser.close to
release its own automation keepalive after ABI closure/shutdown. Production
shutdown was not changed. A previous harness pilot also waited on an exact root
URL after password-manager replaced it with /passwords; the final host tracks
commits and accepts that Chromium route canonicalization. Neither pilot is
passing gate evidence.

### Exact Swift adoption — concern 1

No new C symbols or callback structs. Keep Configure(1), existing profile IDs,
window registration, attachment, and navigation event handling. Gate the four
new hosts before adding native menu commands or admitting them in the shell's
NavigationURLPolicy (the shell is read-only in this pass):

```swift
func openHistory(_ profile: UInt64, _ space: UInt64,
                 _ tab: UnsafeMutablePointer<UInt64>) -> ReArcStatus {
    guard ReArcEngineABIMinorVersion() >= 14,
          ReArcEngineHasFeature("webui_daily_pages") else {
        return ReArcStatus(REARC_UNSUPPORTED)
    }
    return "chrome://history/".withCString {
        ReArcTabCreate(profile, space, $0, tab)
    }
}
```

The same call accepts chrome://downloads/, chrome://password-manager/ and
chrome://extensions/; existing tabs use ReArcTabNavigate(tab, url, 0).
Attach/present the tab normally and copy callback strings before returning.
Check committed/error events; admission is not a successful-load promise.
Do not enable flags, imply Journeys support, forward untrusted page messages as
navigation, or advertise native download/password/permission UI from this flag.
The example is typechecked by check_w18_imports.py. ABI 1.13 clients retain
all previous struct layouts, function signatures and valid operations.

## 2. Browser-less tab helpers — pending

No helpers were attached in this pass. Runtime evidence at the concern-1
boundary: after the native host loads its real HTTP /test fixture and shuts down,
the disposable Default/History database contains **zero URL rows**
(`engine/history-w18-before.log`). History is not recorded on this path today.

Source trap for the next implementation: HistoryTabHelper::ShouldAddNavigationToHistory
explicitly returns false on desktop unless FindBrowserWithTab succeeds.
Attaching it alone will not fix recording. Its Browser type annotation already
supports unknown when no Browser exists. The eventual exception must identify
actual ReArc-owned contents, preserve profile/OTR policy, and retain Chromium's
history URL/transition/redirect rules.

ChromePasswordManagerClient requires an existing ContentAutofillClient and
creates ContentPasswordManagerDriverFactory. Its save/update entry returns
false without a PasswordsClientUIDelegate. Desktop UI helper attachment must
respect browser core → UI target layering; do not use AttachTabHelpers,
TabFeatures or testing bypasses indiscriminately. These are inspected constraints,
not verified browser-less autofill support.

### Exact Swift adoption — concern 2

None yet. There is no tab-helper capability to gate or new Swift API to call.
Do not mark history recording or page password filling supported from
webui_daily_pages. HistoryService/AutocompleteController command-bar suggestions
(the audit's separate P0) also have no query ABI yet.

## 3. JavaScript dialogs — pending

Conservative auto-cancel remains. No dialog request/reply API, host registration,
request cancellation or new timeout policy was shipped. Existing close/shutdown
veto and exactly-once guarantees are preserved and covered by the original hosts.

### Exact Swift adoption — concern 3

None. Do not register a host callback that does not exist. Keep existing
TabClose/EngineShutdown callback lifetime and veto handling.

## 4. File chooser — pending

RunFileChooser still uses the content default. No open/save/multiple/accept-type/
directory request or reply ABI exists.

### Exact Swift adoption — concern 4

None; no new capability or callback. Native NSOpenPanel/NSSavePanel wiring waits
for the engine request/reply concern.

## 5. Permission prompts — pending

No PermissionRequestManager/native prompt bridge was attached. Existing defaults
remain; admission of settings/content is not a grant. Chromium permission storage
and native OS authorization were not modified.

### Exact Swift adoption — concern 5

None; no allow/deny/dismiss/persist API exists. Continue using settings/content
for Chromium's existing stored site settings, without claiming page prompt UI.

## 6. Page context menu — pending

The view delegate still suppresses the context menu. No context request or
standard-command execution ABI was added.

### Exact Swift adoption — concern 6

None. No engine command IDs/callback surface is available for a native NSMenu.

## 7. Find in page — pending

No FindTabHelper or start/next/previous/stop/result-event ABI was added.

### Exact Swift adoption — concern 7

None. Cmd+F and a native find bar still need the later capability/API.

## 8. Downloads — pending beyond WebUI

Chromium's downloads page is reachable after concern 1. No created/updated/
completed events, native actions or default save-location policy were added or
verified by this pass. The Chromium download manager remains authoritative.

### Exact Swift adoption — concern 8

Use the concern-1 feature gate and Create/Navigate to open chrome://downloads/.
There is no lifecycle callback or pause/resume/cancel/open/reveal ABI to adopt.
Do not advertise a native download tray from this flag.

## 9. Password manager — pending beyond WebUI

The real password-manager page and saved-password listing are reachable.
Browser-less save/update bubbles and page autofill remain unimplemented and
unverified. Page admission is not a substitute for attaching the clients and
surfacing their prompt delegate.

### Exact Swift adoption — concern 9

Use the concern-1 gate to open chrome://password-manager/. No save/update prompt
request or password-fill callback was shipped; do not infer either from that
page or its Chromium-owned settings.

## Validation and reproduction

Builds p47 and p48 are green. gates-tab032.log passes **14 native hosts / 19
process runs**, **G1–G5**, and **4 stress processes / 16 shutdown tabs**. Native
logs are preserved with the -tab032 suffix. check_w18_imports.py preserves all
11 ABI 1.13 struct size/alignment pairs and typechecks the exact Swift snippet.
All 49 public symbols resolve through the framework; loaded ABI 1.14/bridge
0.16.0/Chromium 156.0.8078.74 match the headers.

`runtime-abi-compat-w18-driver.log` passes all **13 legacy native hosts / 18
process runs** compiled against the unmodified ABI 1.13 headers from 137a0dc3dc.
Their logs are preserved with the -legacy113 suffix. No source changes followed
the green build/gates.

`replay-w18.log` passes **33/33 reverse and forward** patches with a disposable
index. Reverse tree `ffe41d3ec78c520fbe20a43802869358d3e18961` exactly matches
upstream pin `d331de35ca8ab1358c7a17e4bd41627d55eaef51`; forward tree
`91744df2fb591d162a237a1a51722d3c00082609` exactly matches final HEAD
`b0cc7b4ec6f884a1e8921673a43f22878c8e96c4`. The real Chromium index/worktree are
clean. Commit author and requested Codex trailer are verified. Series, C-ABI.md,
IPC-CONTRACT.md and the §8 drift log are updated. Final evidence summary:
`engine/final-validation-w18.log`. No Chromium builder remains active.


```sh
engine/scripts/build.sh > engine/build-p48.log 2>&1
python3 engine/tests/run_w18_gates.py tab032 4
python3 engine/tests/check_w18_imports.py
python3 engine/tests/check_c_abi_exports.py engine/nm-w18.log
python3 engine/tests/run_compat_w18.py
python3 engine/tests/replay_overlay.py > engine/replay-w18.log
```

No production signing, optimized build, package/notarization, authenticated account
flow, extension installation/popup, password OS reauthentication, or full WebUI
action coverage is claimed. Fixtures use disposable profiles, mock Keychain and
the default sandbox. G1–G5 use the existing smoke harness's default sandbox.

# Wave 18b

Wave 18b implements three concerns, with one Chromium commit and one patch
each. Concerns 3–6 above (dialogs, file chooser, permissions, context menu) and
password save/update prompts remain open; nothing here claims them. The shell is
untouched. No subagents, outer-repository commits or pushes. Builds p49–p53 (p49
failed on a missing include, fixed in p50). A duplicate session briefly
edited `history_tab_helper.{h,cc}` around 15:44–15:45 and reverted its own
change. p51 recompiled that object after the revert (15:47:05), and all gate
and commit evidence comes from p51 or later.

| Concern | Chromium commit | Patch | ABI / bridge | Gates |
|---|---|---|---|---|
| A: browser-less tab helpers | `6c227521ff` | `tab/033-browserless-tab-helpers.patch` | 1.15 / 0.17.0 (`history_recording`, `password_autofill`) | p51; gates-tab033.log |
| B: find in page | `e45a33863d` | `tab/034-find-in-page.patch` | 1.16 / 0.18.0 (`find_in_page`) | p52; gates-tab034.log |
| C: downloads | `1708e96dbe` | `tab/035-download-events-actions.patch` | 1.17 / 0.19.0 (`downloads`) | p53; gates-tab035.log |

Principle: Chromium's services and helpers do the work: HistoryTabHelper and
HistoryService, ChromeAutofillClient and ChromePasswordManagerClient with the
password stores, FindTabHelper, DownloadManager with AllDownloadItemNotifier.
The bridge adds attachment, two browser-less eligibility and embedding hunks,
and thin ABI adapters.

## A. Browser-less tab helpers

`browserless_tab_helpers.cc` attaches the following, in TabHelpers' relative
order: ZoomController, `AutofillClientProviderFactory`'s client
(ChromeAutofillClient → ContentAutofillDriverFactory),
ChromePasswordManagerClient (→ ContentPasswordManagerDriverFactory),
HistoryTabHelper (non-OTR only, as stock), FindTabHelper and a bridge-owned
DownloadNavigationObserver (a TabFeatures member on desktop). It is called from
the TabSession constructor (create and adopt) and from the new
`ReArcTabDelegate::WebContentsCreated`, which mirrors
`Browser::WebContentsCreated`. Without that, renderer-created contents would
drop their autofill and password driver bindings. It is idempotent through a
WebContentsUserData marker.

Audit at this pin:

| Helper | Browser/TabStripModel/TabInterface finding | Disposition |
|---|---|---|
| TabHelpers::AttachTabHelpers | Header warns against desktop use. Attaches PermissionRequestManager, ManagePasswordsUIController, TabDialogs, TabModalDialogManager, BookmarkTabHelper and similar, whose prompts assume a Browser window. | Not used; selective attachment instead. |
| HistoryTabHelper | `IsEligibleTab` on desktop requires `FindBrowserWithTab`. `GetBrowserType` already returns unknown without a Browser. Session/task IDs use static lookups that tolerate missing helpers. | One hunk: on Mac, contents owned by a live bridge TabSession are eligible. Popup visits that commit before adoption are not recorded. |
| ChromeAutofillClient | Browser lookups use `MaybeGetFromContents` or guarded `FindBrowserWithTab`. The popup (`CanShowRootPopup`) supports the Mac Cocoa parent without a views Widget and cancels without a window. | Attached. Popup interaction is audited, not runtime-tested. |
| ChromePasswordManagerClient | `NavigateToManagePasswordsPage` and the actor checks use nullable TabInterface. Save/update returns false without a PasswordsClientUIDelegate. | Attached without ManagePasswordsUIController. Prompts are out of scope. |
| FindTabHelper | No Browser dependency. Needs `FindReply` forwarding. | Attached in A, wired in B. |
| Download helpers | DownloadNavigationObserver is a TabFeatures member. DownloadRequestLimiter tab state is created on demand. | Observer owned by the bridge. Limiter unchanged. |

Evidence: `c_abi_helpers_host.mm` plus post-run database checks in
run_c_abi.py. Two HTTP visits are found through Chromium's history page
handler, in the rendered chrome://history list, and as History DB `urls` rows
with titles. Before this wave, `history-w18-before.log` had zero rows. A
credential added through `chrome.passwordsPrivate.addPassword` fills on load
(`:-webkit-autofill`). A real injected click releases Chromium's value
gatekeeper, and the submitted URL carries the filled username and password.
Login Data then shows `times_used=1` from PasswordManager's prompt-free save of
a used credential. Test-only: the loopback DevTools socket, as in the WebUI
host. Also `--disable-backgrounding-occluded-windows`, because this session's
screen was locked (`CGSSessionScreenIsLocked=1`), every window was occluded,
and Chromium hides the page and drops input.

Not shipped or claimed: save/update prompts for new credentials (no UI
delegate, so nothing is saved), generation, manual-fallback popup interaction,
HistoryService/AutocompleteController command-bar queries (P0.1), and session
restore integration.

### Exact Swift adoption — concern A

No new C symbols, callbacks or struct changes. Keep Configure(1), profiles,
attachment and navigation unchanged. Steps:

1. Gate claims on `ReArcEngineABIMinorVersion() >= 15 &&
   ReArcEngineHasFeature("history_recording") &&
   ReArcEngineHasFeature("password_autofill")` (`browserlessHelpersAvailable()`
   in `engine/tests/w18b_adoption.swift`, typechecked by check_w18b_imports.py).
2. When it holds, the shell's History UI can rely on chrome://history and
   Chromium's HistoryService recording every non-OTR tab. Do not write a
   parallel Swift visit store for Chromium tabs.
3. Remove any shell-side "password filling unsupported" warning for Chromium
   tabs on ≥1.15. Keep any "save password" UI disabled, because no prompt
   callback exists.
4. Present tabs at their real size (normal attach). Do not add a
   `--disable-backgrounding-occluded-windows` switch in production.

## B. Find in page

`ReArcTabDelegate::FindReply` forwards to `FindTabHelper::HandleFindReply`. The
new `rearc_find_abi.cc` keeps one `FindSession` per tab (attached and detached
with the services hooks). See the C-ABI.md "Find in page (1.16)" section for
the full contract. In short: `ReArcTabFindStart(tab, text, options,
&session_id)` (options forward=1, match_case=2; 1..16384 bytes of UTF-8;
always a new session), `ReArcTabFindNext(tab, forward)` and
`ReArcTabFindStop(tab, action)` (0 clear, 1 keep, 2 activate). Result events
carry match count, 1-based active ordinal and the final flag. Each session gets
exactly one terminal event: 1 navigated, 2 closed (before `tab.closed`),
3 stopped, 4 replaced.

Evidence: `c_abi_find_host.mm` runs the invalid-argument matrix and finds 4
case-insensitive matches, with ordinals 1→2→1→4 (backward wrap) and 2
case-sensitive matches. It sees replace, stop, navigation and close terminals
exactly once each, close before `tab.closed`. Finding: an unattached tab has a
0×0 view and Chromium reports 0 matches, so the host presents the tab.

### Exact Swift adoption — concern B

1. Gate: `ReArcEngineABIMinorVersion() >= 16 &&
   ReArcEngineHasFeature("find_in_page")`.
2. Install once before use: `ReArcEngineSetFindCallback(cb, ctx)` with an
   unretained context that outlives registration (`FindController.install()`
   in w18b_adoption.swift). The callback runs on main. Copy the fields and
   compare `event.session_id` with the current session before acting.
3. Cmd+F / typing: `ReArcTabFindStart(tab, text, forward | matchCase, &id)` and
   store `id`. Each keystroke can restart; the old session's `replaced`
   terminal arrives first.
4. Return / Shift-Return: `ReArcTabFindNext(tab, true/false)`. Show
   `match_count` and `active_ordinal` only from events with
   `final_update == true` and `reason == 0`.
5. Esc / closing the bar: `ReArcTabFindStop(tab, 1)` (keep selection), or 2 to
   activate a found link. A terminal reason > 0 hides the bar's count
   (navigation, close or stop). invalid_state from Next/Stop means the session
   already ended.

## C. Downloads

`rearc_downloads_abi.cc` keeps one Chromium `AllDownloadItemNotifier` per
registered bridge profile. The registry hooks create it on register and
destroy it on unregister, before profile destruction, and only in embedded
mode. Item state transitions map to created/updated/completed/interrupted/
cancelled/removed events. Actions call DownloadItem's own Pause, Resume,
Cancel, OpenDownload, ShowDownloadInShell and Remove. `ReArcDownloadSetPolicy`
writes Chromium's DownloadPrefs directory and `kPromptForDownload=false`.
Two hunks keep embedded mode window- and picker-free: OpenDownload uses the
platform handler instead of `ScopedTabbedBrowserDisplayer`, and
RequestConfirmation continues at the suggested path for preference/save-as and
cancels otherwise. Audit: DownloadUIController's bubble delegate only
notifies existing Browser windows, so it is inert. Its close-empty-tab path
requires a Browser. The CRX installer creates a Browser only for downloads
without contents, and extension installation is not claimed. See C-ABI.md
"Downloads (1.17)".

Evidence: `c_abi_downloads_host.mm` validates the policy and action argument
matrix. A 64 KiB file lands in the policy directory (size checked on disk;
reveal invoked once, which opens one Finder window in the test's temporary
directory). A 1 MiB trickle goes pause → resume → progress → cancel → remove →
not_found. A truncated response auto-resumes inside Chromium and ends
interrupted with a reason, and cancelling it succeeds. An OTR download, where
Chromium would otherwise force the picker, completes as
`rearc-small (1).bin`. Open's success path is not invoked, to avoid
launching an application; its state validation is.

### Exact Swift adoption — concern C

1. Gate: `ReArcEngineABIMinorVersion() >= 17 &&
   ReArcEngineHasFeature("downloads")`.
2. After `ready`, before creating tabs: `ReArcEngineSetDownloadCallback(cb,
   ctx)`, then `ReArcDownloadSetPolicy(profile, downloadsURL.path, 0)` for
   each profile the shell opens, OTR included
   (`DownloadsController.install` in w18b_adoption.swift). The directory
   persists in Chromium's prefs.
3. In the callback (main thread), copy every string immediately. Key rows by
   `guid` (or by `profile_id` plus `download_id`). Drop the row on kind 5.
   Treat kind-0 rows with state 1/2/3 as history restored at launch.
4. Tray buttons map to `ReArcDownloadAction(profile, id, a)`: 0 pause,
   1 resume (only when `can_resume`), 2 cancel, 3 open, 4 reveal in Finder,
   5 remove. Expect invalid_state when the item changed state since the last
   event, and not_found after removal.
5. Show a danger badge when `danger_type != 0` and the state is in progress.
   Offer cancel/remove, or link to chrome://downloads (gated by
   `webui_daily_pages`) for Chromium's keep-dangerous flow. No native accept
   action exists yet.
6. Do not show a "Save as…" or "Ask where to save" option yet: prompt mode 1
   returns unsupported until the file chooser ABI exists.

## Wave 18b validation and reproduction

Per-concern gates (each one is all native hosts, then G1–G5, then 4 stress
processes / 16 shutdown tabs, with logs preserved under that label's suffix):

| Gate | Build | Native hosts / process runs | G1–G5 | Stress |
|---|---|---|---|---|
| gates-tab033.log (A) | p51 | 15 / 20 | pass | 4 / 16 pass |
| gates-tab034.log (B) | p52 | 16 / 21 | pass | 4 / 16 pass |
| gates-tab035.log (C) | p53 | 17 / 22 | pass | 4 / 16 pass |

B's first gate run failed in the profiles reopen host: a main-world evaluation
hit its 10 s deadline while the machine's load average was about 350, from
other processes. That evidence is kept as `gates-tab034-fail1.log` and
`runtime-abi-profiles-reopen-tab034-fail1.log`. The host passed in 2/2
isolated reruns with no code change, and the full B rerun passed. The other
pilots (a dangling C++ capture in the helpers host, a history result-shape
bug, the 0×0 unattached find view, and the locked-screen occlusion that hid the
page) were test-harness fixes, not product changes, and none of them is passing
evidence.

Final checks at HEAD `1708e96dbe`, with no builder active:
`abi-w18b-import.log` keeps all 11 struct layouts and all 47 header symbols
against both the ABI 1.13 (`137a0dc3dc`) and ABI 1.14 (`b0cc7b4ec6`) headers.
It adds 7 symbols and typechecks `tests/w18b_adoption.swift`. `nm-w18b.log`
resolves all 56 public symbols through the framework, and the loaded binary
reports ABI 1.17 / bridge 0.19.0 / Chromium 156.0.8078.74.
`runtime-abi-compat-w18b-driver.log` runs the unmodified-header hosts: 13
legacy hosts / 18 processes against 1.13 (`-legacy113b` logs) and 14 hosts / 19
processes against 1.14, including the WebUI host (`-legacy114` logs).
`replay-w18b.log` passes 36/36 patches, reversed newest-first in a disposable
index. The reverse tree `ffe41d3ec7` equals the upstream pin tree, and the
forward tree `2f49e47fed` equals HEAD `1708e96dbe`. The real Chromium
index/worktree are clean. Commits carry the ReArc Overlay author and the Claude
trailer. Summary: `engine/final-validation-w18b.log`.

Not claimed: production signing or packaging, an optimized build, autofill
popup interaction, password save/update prompts, the download keep-dangerous
action, Chromium's download location picker, opening a downloaded file
(audited only), CRX installation, command-bar history queries, or any concern
3–6 surface.

```sh
engine/scripts/build.sh > engine/build-p53.log 2>&1
python3 engine/tests/run_w18b_gates.py tab035 4
python3 engine/tests/check_w18b_imports.py > engine/abi-w18b-import.log
python3 engine/tests/check_c_abi_exports.py engine/nm-w18b.log
python3 engine/tests/run_compat_w18b.py > engine/runtime-abi-compat-w18b-driver.log
python3 engine/tests/replay_overlay.py > engine/replay-w18b.log
```
