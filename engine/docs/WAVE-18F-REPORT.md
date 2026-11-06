# Wave 18f implementation report

Chromium **156.0.8078.74**, upstream pin `d331de35ca8ab1358c7a17e4bd41627d55eaef51`.
Starting overlay HEAD `5e59268cef`. Final ABI **1.35**, bridge **0.37.0**,
Configure major **1**. One writer, no subagents, no pushes, no outer-repository
commits. `shell/` was left untouched; concurrent shell (wave 24) work was not
staged or reverted. Existing output-directory symlinks were preserved.

## Patch inventory and shell adoption

Each concern has its own additive patch, minor bump and feature. Gate shell
adoption on both the minor and the feature string. Existing callback tables and
all ABI 1.17 structure layouts are unchanged. Public declarations are in
`chrome/browser/rearc_bridge/rearc_engine_abi.h`.
[C-ABI.md](C-ABI.md#extension-tab-helpers-131) documents ownership,
validation, numeric values and exact call semantics.

| Patch | Commit | ABI / bridge | Feature / new API |
|---|---|---|---|
| `tab/049-extension-tab-helpers.patch` | `36b60ad909` | 1.31 / 0.33.0 | `extension_tab_helpers`; no new symbols |
| `tab/050-extension-install-prompts.patch` | `758ca5e9a3` | 1.32 / 0.34.0 | `extension_install_prompts`; `ReArcEngineSetExtensionPromptCallback`, `ReArcExtensionPromptRespond`, `ReArcExtensionPromptEvent` |
| `tab/051-extension-actions-popups.patch` | `c734a32b96` | 1.33 / 0.35.0 | `extension_actions`; `ReArcTabGetExtensionActions`, `ReArcEngineSetExtensionActionCallback`, `ReArcTabRunExtensionAction`, `ReArcExtensionAction(List/Event)` |
| `tab/052-autofill-suggestions.patch` | `fdea5a4f6d` | 1.34 / 0.36.0 | `autofill_suggestions`; `ReArcEngineSetAutofillCallback`, `ReArcAutofillAccept/Select/Dismiss/Manage`, `ReArcAutofillEvent`, `ReArcAutofillSuggestion` |
| `tab/053-password-leak-detection-pref.patch` | `7e0cde3ec7` | 1.35 / 0.37.0 | `password_leak_detection`; `ReArcProfileGetPasswordLeakDetection`, `ReArcProfileSetPasswordLeakDetection` |

### Extensions: audit of what was already attached

ExtensionWebContentsObserver (ChromeExtensionWebContentsObserver) was already
on every registry tab, through Chromium's universal WebContents observers.
Several pieces were missing: the extension view type, extensions::TabHelper
(ScriptExecutor, ExtensionActionRunner, ActiveTabPermissionGranter),
SessionTabHelper (the extension tab ID) and WebNavigationTabObserver.
ExtensionTabUtil::GetTabById only searched Browser tab strips. Extension
installs and uninstalls showed Chromium Views dialogs over the shell window.
A successful install called ScopedTabbedBrowserDisplayer, which opens a
**stock Chromium Browser window**. Extension `tabs.create` and
`runtime.openOptionsPage` would also have created one.

### Extension tab helpers and content scripts (tab/049)

kTabContents registry tabs get the missing helpers in
AttachBrowserlessTabHelpers. SessionTabHelper is created without a
SessionService delegate, so registry tabs get extension tab IDs but no window
session state. GetTabById returns an open registry tab's contents only (no
WindowController, TAB_INDEX_NONE), the same shape Chromium already returns for
prerendered tabs. This makes the following reach registry tabs:

- content scripts
- runtime messaging, with `sender.tab` carrying the ID
- webNavigation
- `tabs.sendMessage`
- `scripting.executeScript` by tab ID
- activeTab

Registry tabs belong to no extension window. tabs.query and windows.* do not
list them.

### Extension prompts (tab/050)

In embedded mode, ShowExtensionInstallDialogImpl and
ExtensionUninstallDialog::Create send host requests. These cover install,
re-enable, permissions, external, remote and repair prompts, plus uninstall as
kind 100. They follow the 18c request/response conventions. The event carries
Chromium's localized title, labels, permission lines and an icon PNG.
ExtensionInstallUIDesktop reports success (phase 2) and failure (phase 3, with
Chromium's error) instead of opening a Browser window, bubble or infobar.
OpenTabHelper::CreateAndShowBrowser and ChromeRuntimeAPIDelegate::OpenOptionsPage
no longer create a Browser; the calls fail as if no window existed. Requests
cancel on tab close, profile release and callback replacement. With no
callback, install prompts abort and uninstall confirmations cancel.

**Web Store:** chromewebstore.google.com's webstorePrivate flow uses
Chromium's own path in a registry tab (Chromium download, CrxInstaller). The
tests never contact the real store. A loopback page on `localhost` becomes the
gallery through Chromium's `--apps-gallery-url` test override.

### Extension actions and popups (tab/051)

The host draws the toolbar from per-tab snapshots. Each snapshot has the
title, the display badge (including the DNR count), badge colors, visibility,
the popup flag, wants_to_run, and the icon at 1x–4x through
ExtensionActionIconFactory. Change events come from ExtensionActionDispatcher,
ExtensionRegistry and icon loads. Run is a toolbar click
(ExtensionActionRunner::RunAction, which grants activeTab).

**Popups use the preferred design: a hosted WebContents the shell attaches
like a tab.** A popup result creates a new registry tab (disposition popup,
opener = the clicked tab) with view type kExtensionPopup, loading the action's
popup URL in the extension's profile. Spanning-mode extensions use the
original profile, as ExtensionViewHostFactory does. The renderer auto-resizes
within Chromium's 25×25..800×600 popup bounds and reports each size (event
kind 3). `window.close()` closes the popup tab with reason 1 (page). Popups
record no history, get no tab identity, and are found by
`chrome.extension.getViews({type:'popup'})`.

ExtensionViewHost itself was not reused. Its delegate, keyboard and
modal-host integration assume a Browser or Views host. A registry tab already
has the attachment lease, visibility, close pipeline, prompts and services.

### Autofill suggestions (tab/052)

For registry tabs, AutofillPopupView::Create returns a host view. Chromium's
AutofillPopupControllerImpl keeps doing everything except drawing:

- show/hide decisions
- filling and previews
- keyboard routing (arrow keys, Enter, Tab, Escape mapped as PopupViewViews does)
- the 500 ms early-accept guard; host accepts inside it return `busy`

The event carries the field bounds in the tab view's DIP coordinates and rows
with value, minor text, label, an icon name and a kind. Password suggestions
use the same path, because PasswordAutofillManager calls ChromeAutofillClient.
Password rows carry the username and Chromium's masked label, never the
password. "Manage..." rows and ReArcAutofillManage ask the host to open
Chromium's settings page. ChromeAutofillClient::ShowAutofillSettings and
ChromePasswordManagerClient::NavigateToManagePasswordsPage are routed for
registry tabs. Chromium 156's address page is `chrome://settings/contactInfo`
(not `/addresses`). Before 1.34 Chromium's Views popup was shown; now there is
never a Chromium popup, and without a callback there is none at all.

### Password leak detection (tab/053)

Get/set of Chromium's `profile.password_manager_leak_detection` pref, default
on as in Chrome. Get reports whether policy manages it (Set is then
`invalid_state`). Off-the-record profiles never run leak checks and are
`unsupported`. The value persists in the profile Preferences. A detected leak
is not surfaced to the host yet (Chromium's leak dialog needs
ManagePasswordsUIController).

### Network audit of the test fixtures

Every native ABI process now writes `--log-net-log`.

**Baseline** (p85 HEAD with the new tests but no blocking,
`network-audit-w18f-baseline.log`, all 40 processes passing): **36 of 40
processes sent real traffic to Google**, measured as TCP connects or UDP DNS
sends. Every process looked up www.google.com. The hosts contacted were:

- `/async/folae`, an omnibox AI-mode eligibility fetch (www.google.com)
- GAIA `ListAccounts` (accounts.google.com)
- the component updater (update.googleapis.com, edgedl.me.gvt1.com)
- network time (clients2.google.com/time)
- autofill crowdsourcing queries (content-autofill.googleapis.com)
- Safe Browsing (sb-ssl.google.com)
- translate, csp.withgoogle.com and www.gstatic.com
- passwordsleakcheck-pa.googleapis.com, from the leak host's control phase
- example.com, a hover preconnect to the services fixture's peek link

The helpers and passwords hosts, which submit sign-ins, would also have
triggered leak checks.

**Fix (tests only):**

- Sign-in hosts (passwords, helpers) set leak detection off when the minor is ≥35.
- Every native, smoke and stress process gets `NO_OUTSIDE_NETWORK`
  (`--disable-background-networking --disable-component-update
  --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost"`).
- Every test profile starts with secure DNS off in `Local State`. Automatic
  DoH dials Google Public DNS by IP literal, found in the first gate pilot.
- Native and smoke runs fail if a net log shows a TCP connect, or a UDP send,
  to a non-loopback address. HostResolver's IPv6 reachability probe makes a
  bare UDP `connect()` to 2001:4860:4860::8888 that sends nothing; it is
  allowed.

**Result:** all 40 native processes and all 5 smoke gates show no outside
connect. The switches do not stop every attempt. Lookups of www.google.com,
accounts, clients2, update.googleapis, content-autofill, gstatic and sb-ssl
still occur, and all fail locally at resolution (`network-audit-w18f.log`).
Stress processes get the same switches and secure-DNS state but are not
net-logged.

## Validation

Final build **p85** passes in `out/ReArc-dev-arm64` and is the HEAD tree; no
source changes followed p85. Concern builds p78, p80, p82 and p83 also pass,
and p84 rebuilt 052 with header comments only. p79 failed on `IDS_CANCEL`
(fixed: `IDS_APP_CANCEL`). p81 failed on the unqualified
`kExtensionPopupMinSize` (fixed: `extensions::`). Before each build a guard
waited until both `pgrep -fl "siso ninja"` and the shell's
`rearc-selftest`/`bundle-chromium.sh` processes were absent, because the
shell's self-test bundle symlinks this output directory.

**Final run:** `run_w18f_gates.py` → **ALL WAVE 18F GATES PASS**
(`gates-w18f.log`). 33 native ABI hosts / 40 process runs pass, including the
three new hosts (leak ×2, autofill, extensions). Smoke G1–G5 pass
(`smoke-w18f.log`; 11.5–17.0 s each, each `no-outside-connect`). Ordinary
shutdown stress: 4 processes / 16 tabs, 3097–4734 ms (median 3677 ms).
Pending-prompt stress: 4 processes / 16 tabs, 289–745 ms (median 532 ms).
Named-profile blocked-TCC stress: 1 process / 4 tabs, 460.742 ms, with the
actual `TEST TCC preflight blocked` marker in `runtime-abi-stress-w18f-tcc.log`.
Network audit: 40 of 40 processes looked up outside names, and none connected
outside (`network-audit-w18f.log`: `NO OUTSIDE CONNECT PASS`).

| New native host | Evidence |
|---|---|
| extensions — content scripts (049) | `--load-extension` MV3 fixture: content script ran; runtime.sendMessage reply with `sender.tab.id` (not -1); webNavigation onCommitted for the registry tab's URL; tabs.sendMessage reached the content script; scripting.executeScript by tab ID wrote a DOM marker; OTR tab of a non-incognito extension got no script. |
| extensions — Browser windows (050) | From the extension: `tabs.create` → "No current window", `runtime.openOptionsPage` → error; no window besides the test's own (macOS menu-bar status items excepted). |
| extensions — prompts (050) | Fake gallery (`--apps-gallery-url=http://localhost:PORT/`), Chromium's webstore_private fixture: no callback → abort, no event, no dialog; prompt (kind 0, tab = store tab, title "Add '…'?", "Add extension"/"Cancel", "Read your browsing history", 8387-byte icon) cancelled → `User cancelled install`; replacement while pending → withdrawn, no event, stale ID not_found; accepted → completeInstall downloads, the CRX has no publisher proof → phase 3 `CRX_REQUIRED_PROOF_MISSING`. A per-run self-signed CRX3 dropped (real NSDraggingDestination, synthetic NSDraggingInfo) on chrome://extensions in developer mode → prompt with tab → accepted → phase 2 installed with icon; management.uninstall with confirm → kind 100 cancel (`uninstall canceled by user`), then accept → removed. No Chromium window at any point. |
| extensions — actions (051) | Popup fixture: title "ReArc popup", badge "7", background 0xffff0000, popup, 32-px icon at scale 2; click fixture (activeTab + scripting only): run → result 0 and `action.onClicked` scripted the tab; popup run → result 1, popup tab created (disposition 3, opener tab), attached, popup tab rejects action calls (unsupported), `getViews({type:'popup'})` = 1, kind 3 resize 320×180, `window.close()` → closed reason 1. Invalid ID → invalid_argument, unknown → not_found. Install/uninstall produced kind 1/2 events. |
| autofill (052) | Address and card saved via autofillPrivate, credential via passwordsPrivate; form on loopback HTTPS (per-run cert, `--ignore-certificate-errors-spki-list`). Name field click → product 1, bounds exactly 10,10 300×30, rows "Rearc Tester"/"1 Test Way" (account icon), separator, "Manage addresses…"; immediate accept → busy; native Down keyDown → phase 2 row 0; accept → fields "Rearc Tester\|1 Test Way\|Testville\|94043\|tester@example.com"; dismiss → hidden, stale ID not_found; "Manage addresses…" row and ReArcAutofillManage → `chrome://settings/contactInfo`; card field → product 2, `card_visa` row, fill "Rearc Tester\|4111111111111111\|12/2031"; login field → product 6, `rearc-w18f` with masked label, "Manage passwords…" → `chrome://password-manager/passwords`; replacement hides with no delivered events. |
| leak (053) ×2 | Phase 1: default on, not managed, set/get round trip, invalid/unknown/OTR rejected; sign-in submitted with the check on → net log shows a `passwordsleakcheck-pa.googleapis.com` attempt, resolution blackholed; turned off before shutdown. Phase 2 (reopen): reads off; sign-in → no leak-check attempt. |
| prior 30 hosts | PiP, drops, print, fullscreen, search, history, danger, discard (2 phases), passwords, context, permissions, files, dialogs, helpers, find, downloads, WebUI, migration (+reopen), shutdown (3 modes), shutdown veto, core, services, URLs, eval, scheme return, profiles (+reopen), identity, zoom (+reopen), messages and branding pass with the no-outside-network switches; their runner post-checks (suggest, danger file, Login Data, content settings, History DB, OTR disk) pass. |

`check_w18f_imports.py` preserves all **13 ABI 1.17 struct size/alignment
pairs**. It typechecks gated Swift adoption of every new API plus the 18b–18e
examples (`imports-w18f.log`). `check_c_abi_exports.py` resolves all
**97 public symbols** (85 + 12) through the framework and confirms loaded ABI
1.35 / bridge 0.37.0 / Chromium 156.0.8078.74 (`exports-w18f.log`,
`nm-w18f.log`). `run_compat_w18f.py` compiles the unmodified core, downloads,
shutdown and shutdown-veto hosts against the exact ABI 1.17 headers from
`1708e96dbe`. It gives **ABI 1.17 HEADER RUNTIME PASS: 4 hosts / 6 process
runs** (`compat-w18f.log`, `runtime-abi-*-legacy117f.log`). This is a
representative set, not every historical header revision.

All native, smoke and stress processes use **--use-mock-keychain** and
disposable profiles. No real Keychain was touched. Nothing was installed from
the real Web Store: the store is a loopback override, its CRXs are Chromium's
own test data or signed per run with a fresh local key, and the HTTPS
certificate is per run, accepted only through the SPKI-list switch. These
switches are test-only and production gets none of them:

- loopback DevTools (user gestures, focus emulation) and
  `--disable-backgrounding-occluded-windows`, as in earlier waves
- `--disable-features=RWHVMacHasFocusReturnsFalseForNonKeyWindow` (autofill
  only; the locked session never makes the window key)
- `--apps-gallery-url`/`--apps-gallery-update-url` (extensions only)

Pilot evidence (retained, not counted as passing):

- **Extensions.**
  - Update events carry a URL only when it changed, so the fixture tracks the
    commit URL.
  - webNavigation missed a commit made before the new service worker
    registered its listener; the fixture reloads (bounded, 0–1 reloads seen).
  - Visible `NSStatusBarWindow`s (system menu-bar items, present before any
    extension loads) are excluded from the no-window check.
  - Chromium's webstore_private `extension.crx` has no publisher proof. It is
    kept as the failure case.
  - `components/test/data/crx_file/valid_test_publisher.crx3` is MV2, which
    ManifestV2Handler refuses ("unsupported manifest version"); MV2 installs
    are blocked in 156. It was dropped.
- **Autofill.**
  - With the locked session's non-key window, Chromium suppressed suggestions
    (rwhv HasFocus); the fix is the test switch above plus making the view
    first responder.
  - DevTools key events without a native key code set `skip_if_unhandled`, so
    browser key listeners never see them; a native NSEvent keyDown is used.
  - The login field is content-box (308 px).
- **Network.** `gates-w18f-pilot-doh.log`: the first full gate run stopped at
  the leak host on a DoH connect (2001:4860:4860::8888:443). The fix is secure
  DNS off in `Local State` and the refined TCP/UDP-send check. The shell
  agent's self-test wrappers quoting the probe text held several runs at the
  build gate; they waited, as designed.

Reproduction from the project root (no active builder or quoting wrapper):

```sh
engine/scripts/build.sh
python3 engine/tests/run_w18f_gates.py
python3 engine/tests/check_w18f_imports.py
python3 engine/tests/check_c_abi_exports.py engine/nm-w18f.log
python3 engine/tests/run_compat_w18f.py
python3 engine/tests/replay_overlay.py > engine/replay-w18f.log
```

Run the commands sequentially, checking the build guard before the standalone
export/replay invocations as well. `openssl` (system LibreSSL) is required for
the per-run CRX and HTTPS fixtures.

## Replay

REPLAY PASS 54/54 reverse and forward. The reverse tree
`ffe41d3ec78c520fbe20a43802869358d3e18961` matches the pin. The forward tree
`8fa98d583a43c6f7139f1afbe122fa3ef4101cc7` matches HEAD
`7e0cde3ec7d457fec4f7c1f1f43293477a16c854`. The real index and worktree are
untouched and the Chromium checkout is clean. Log: `replay-w18f.log`.

Updated: series entries (049–053), patch headers (overlay author, rebase-pin
line, co-author trailer), C-ABI.md (1.31–1.35), SMOKE-TEST.md (no-outside-
network gates) and §8 of P-TAB-001-SLICES.md. No push was run.

## What was not done

- **A completed install from the real Web Store, natively.** The route is
  wired: prompt routing, webstorePrivate, CRX download and the
  installed/failed notifications are all proven. Production store CRXs need
  Google's publisher proof, which no local fixture can carry, and test-key
  CRXs in the tree are MV2, which 156 refuses. The real store was deliberately
  not contacted.
- **The extension tabs/windows model.** Registry tabs are not listed by
  tabs.query or windows.*. tabs.create and openOptionsPage fail rather than
  opening a tab: routing them would need a host tab-creation request and a
  browser-less WindowController. A follow-up can map them onto the 1.x
  adoption events.
- **chrome.action.openPopup, side-panel actions and the extension toolbar
  context menu.** openPopup needs a Browser window; side panels have no
  browser-less container (run result 2 is reported). The context menu is
  shell UI over chrome://extensions. Popup dismissal on focus loss and Escape
  is the shell's job.
- **Some extension dialogs still use Views.** These are the reload-page bubble
  after an "on click" site-access grant, the ESB install-friction dialog, the
  policy-blocked dialog and the supervised-user ask-parent dialog. They are
  conditional paths not reached by default settings.
- **Autofill gaps.** Not done:
  - sub-popups (expandable rows show without children)
  - the search-bar and pay-now/later tabbed popup variants
  - Shift+Delete removal
  - save-address/save-card/IBAN offers
  - surfacing a detected password leak to the host
- **Some test subsystems still make lookups.** GAIA ListAccounts, omnibox
  AI-mode, the component and extension updater, network time, autofill
  crowdsourcing and Safe Browsing still attempt lookups in tests even with
  `--disable-background-networking`. They fail locally, but disabling each one
  at the source was not attempted.
- **Out of scope.** Shell adoption (no shell edits), DevTools, real Keychain
  access, and production packaging, signing and notarization.

WAVE 18F DONE head=7e0cde3ec7d457fec4f7c1f1f43293477a16c854 abi=1.35 replay=pass
