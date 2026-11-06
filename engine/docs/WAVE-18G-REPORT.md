# Wave 18g implementation report

Chromium **156.0.8078.74**, upstream pin `d331de35ca8ab1358c7a17e4bd41627d55eaef51`.
Starting overlay HEAD `7e0cde3ec7`. Final ABI **1.39**, bridge **0.41.0**,
Configure major **1**. One engine writer,
no subagents, no pushes, no outer-repository commits. `shell/` is untouched;
its concurrent work and output-directory symlinks are preserved.

## Patch inventory and shell adoption

Each implemented concern has its own additive patch, ABI minor bump and feature.
Existing callback tables and ABI 1.17 layouts are unchanged. Public declarations
are in `chrome/browser/rearc_bridge/rearc_engine_abi.h`; C-ABI.md documents the
request ownership, numeric values and precise shell adoption sequence.

| Patch | Commit | ABI / bridge | Feature / new API |
|---|---|---|---|
| `tab/054-extension-shell-windows.patch` | `b236dccd15` | 1.36 / 0.38.0 | `extension_windows`; `ReArcTabSetExtensionWindow`, `ReArcTabGetExtensionState`, `ReArcEngineSetExtensionTabRequestCallback`, `ReArcExtensionTabRequestRespond` |
| `tab/055-local-autofill-save-offers.patch` | `ee5a2f288c` | 1.37 / 0.39.0 | `autofill_save_prompts`; `ReArcEngineSetAutofillSaveCallback`, `ReArcAutofillSaveRespond` |
| `tab/056-host-http-auth.patch` | `579c39be34` | 1.38 / 0.40.0 | `http_auth`; `ReArcEngineSetHttpAuthCallback`, `ReArcHttpAuthRespond` |
| `tab/057-modified-link-open-requests.patch` | `9739603b0f` | 1.39 / 0.41.0 | `link_open_requests`; `ReArcEngineSetLinkOpenCallback`, `ReArcLinkOpenRespond` |

### Extension tab/window routing

A small registry adapter supplies a logical shell-window model directly to the
requested extension APIs. It fabricates no BrowserWindowInterface, TabInterface
or WindowController. The host reports window membership, active tab and focus,
independently of native view visibility (split views can present several tabs).
Extension IDs remain Chromium SessionTabHelper IDs; bridge IDs stay opaque.

Creation/activation is a bounded asynchronous host request: validated URL,
extension ID, active flag, bridge opener ID, target window and profile. The
host creates a blank registry tab in its current space and reports membership;
response performs the validated extension-initiated navigation inside Chromium.
This internal path admits an extension's own options page without widening the
shell's general URL admission. Timeout (30 s), callback replacement, associated target/
opener close and profile release fail the extension Promise; no callback opens
no stock Browser. Response re-resolves the target at queued delivery.

Supported: tabs.query/get/getCurrent, create, update URL/active (including its
default active tab), remove one tab, runtime.openOptionsPage, single-URL normal
windows.create, windows.get/getAll/getCurrent/getLastFocused. Tab metadata keeps
Chromium's URL/title permission scrubbing and original/OTR visibility checks.
Removal uses the existing beforeunload/veto-aware close pipeline.

Remaining: windows mutations/geometry, multi-URL and popup/panel windows,
incognito-profile creation, tabs.move/group/highlight/pin/mute/auto-discardable
mutation, array removal, lifecycle event routing and generic WindowController
consumers. Current/last-focused falls back to a deterministic active tab in the
calling profile; last-focused is not separately retained after focus is cleared.

### Local card/address save offers

ChromePaymentsAutofillClient's local card offer and ChromeAutofillClient's
address import offer transfer their decision callback to a WebContents-owned
adapter. The host sees origin, update and a display summary. Card summaries
carry network/masked last four/expiry/name, never a PAN or CVC. Accept unchanged,
decline and ignore invoke Chromium callbacks; Chromium retains storage,
deduplication and eligibility rules. Address display uses en-US formatting.

One offer per contents, at most 64 globally. No callback ignores without a Views
bubble. Replacement, later navigation, discard/close and destruction cancel;
the form's submission navigation is preserved, since address import can offer
before that navigation starts. Account migration and cloud-save UI are ignored
for registry tabs. This does not disable production cloud eligibility preflight;
tests are unsigned-in local profiles under 18f's network isolation.

### HTTP auth

A LoginHandler subclass and the public `http_auth` request/response channel
retain Chromium's Basic/Digest auth cache, credential processing and
LoginTabHelper behavior. The host sees challenger, scheme, realm and proxy flag;
it replies with copied UTF-8 username/password or cancellation. No credentials
are emitted in events. Invalid input leaves the request pending; accepted,
cancelled or retired IDs cannot be used again. No callback cancels. Callback
replacement and handler/navigation/tab/profile/engine teardown withdraw once.
Subresource challenges can reach the registry handler without a modal-dialog
manager. Native Basic/Digest/cancel/replacement/pending-close validation passes;
proxy and subresource challenges are not separately generated by the fixture.

### Client certificate selection audit and disposition

Not implemented; no client-certificate feature is advertised. The relevant seam
is ChromeContentBrowserClient::SelectClientCertificate: it applies enterprise
auto-selection policy, then transfers ClientCertIdentityList and the
ClientCertificateDelegate to ShowSSLClientCertificateSelector. A correct host
adapter must retain each identity and delegate, expose only certificate metadata,
validate a selected index, acquire its SSLPrivateKey asynchronously through
ClientCertIdentity::SelfOwningAcquirePrivateKey, and join cancellation while key
acquisition is in flight. Dropping a delegate cancels; continuing with null
certificate is a distinct, cached choice and must not substitute for cancellation.

On macOS ProfileNetworkContextService::CreateClientCertStore returns
ClientCertStoreMac (possibly an enterprise wrapper). `--use-mock-keychain` mocks
OSCrypt, not that TLS identity/key provider. A meaningful accepted-certificate
test therefore requires a separate test ClientCertStore/identity/private-key
factory (the service has a testing factory seam), loopback mutual TLS and
cancellation-during-signing tests. Empty-list/cancel-only coverage would not prove
selection or asynchronous lifetime safety. No real Keychain identity was used,
and no unvalidated selector or private-key import ABI is shipped in this wave.

### Security interstitials

No production fix was needed. SecurityInterstitialTabHelper::AssociateBlockingPage
lazily creates its helper on registry contents. The native loopback fixture
renders an untrusted self-signed certificate warning and Safe Browsing's
`--mark_as_phishing` test-blocklist warning. It captures four native PNGs and
exercises the rendered page's actual proceed/back controls. Both proceed paths
load the target; both back paths restore the preceding navigation entry.
Certificate and Safe Browsing PNGs were visually inspected. The second Safe
Browsing warning uses another loopback host, because proceeding allowlists the
first origin. No certificate-ignore switch, Keychain trust install, real blocklist
fetch or new native interstitial UI/action API is used. Verification alone adds
no patch, ABI bump or feature string.

### Modified link opening (tab/057)

Registry OpenURLFromTab now routes foreground/background tabs and window/split
intents to the host. A separate link event preserves ABI 1.36 extension layouts
while reusing the same bounded request queue, deadline and profile/source
cancellation machinery. The event carries the URL, disposition, bridge source/
opener, generation, user gesture and Chromium-sanitized referrer/policy. The
host creates a distinct blank tab in that profile/current space, reports logical
membership/selection and responds. Chromium retains the full OpenURLParams,
including initiator/site instance, transition, original referrer/policy,
headers/body and navigation callback; the shell never reconstructs them.

Command-click and middle-click are background (2), Command-Shift foreground
(1), Shift new window (4), and Option-Command split (5) at this pin. The shell
owns native focus, window creation and split placement. Existing CURRENT_TAB
and Chromium-created AddNewContents/target=_blank adoption are unchanged.
Only gestured/context-menu HTTP(S) URL-only requests are admitted; explicit
rel=opener and the other unsupported dispositions remain refused. The bridge
opener is grouping/source metadata and grants no script window.opener access.

The first native pilot exposed a queued about:blank load overwriting the
accepted target navigation. The common response now retires the queued initial
load before applying retained parameters, protecting extension creation too.
p96 plus the native mouse fixture pass all five modifier/button mappings,
noreferrer suppression in event/document/HTTP headers, source URL unchanged,
foreign-profile/source/nonblank-target rejection, callback replacement and
pending-source-close withdrawal. The middle-click fixture follows Chromium's
CGEvent center-button synthesis; NSEvent's ordinary factory cannot set its
buttonNumber. No extra production input/focus override was introduced.

### DevTools reconsideration and disposition

Skipped; `devtools` remains unadvertised. Stock undocked hosting is possible,
so browser-less frontend ownership is not a prerequisite. The proposed stock
route was audited again against the actual pin:

| Pin source / seam | Finding and required ownership work |
|---|---|
| DevToolsWindow::Create/Show/CreateDevToolsBrowser | An inspected registry tab disables docking. CreateDevToolsBrowser creates a real CreateForDevTools Browser and transfers frontend ownership into its TabStripModel. Native Browser/profile keepalives are independent of bridge registry tabs. |
| DevToolsWindow::InspectedContentsClosing | Target detach calls frontend ClosePage, which is asynchronous. Registry/profile close completion currently does not await frontend destruction or its Browser window. Target destruction alone therefore does not establish the ABI's all-contents-destroyed barrier. |
| DevToolsWindow::InterceptPageBeforeUnload/HandleBeforeUnload/OnPageCloseCanceled | The undocked frontend's delegate is Browser. Chromium proxies frontend beforeunload into the target and back; a frontend veto must roll the target close state back. ReArc's close_controller directly dispatches target beforeunload and does not participate in this protocol. Closing the frontend first would also break target-close-veto semantics. |
| ReArc native view delegate | Embedded mode selects the bridge view delegate globally. A stock DevTools frontend has no registry attachment lease/native-window provider. Native window/focus handling must explicitly distinguish engine-owned Browser contents, including frontend reloads and nested DevTools. |
| ContinueShutdown / profile close | A separate tracked window/contents set must be joined before completion, with forced close that cannot leave a frontend veto or Browser keepalive alive. Tracking only Browser removal misses a frontend still loading before Browser creation. |

Safe implementation needs a frontend lifetime observer from creation through
Browser insertion/destruction, explicit profile ownership, the close-controller
interception protocol and forced teardown barriers. The minimum runtime matrix
is repeated open/reuse, target navigation, frontend/target close in either order,
frontend and target veto, OTR, close while frontend loads, profile close and
engine forced/nonforced shutdown. No one-line stock-window opener is shipped.

## Validation

Final build **p96** passes in `out/ReArc-dev-arm64` and matches the final
Chromium source tree. No engine source change followed p96. Concern builds p89
and p91 pass. Chromium HEAD is `9739603b0f3fee4985c18d7407f3f3c4de05d865` and
its worktree is clean. No outer-repository commit or push was run.

**Final run:** `run_w18g_gates.py` → **ALL WAVE 18G GATES PASS**
(`gates-w18g.log`, `gates-w18g.stdout`). **37 native hosts / 44 process runs**
pass. Smoke G1–G5 pass (`smoke-w18g.log`; 11.1–13.7 s each), each with
`no-outside-connect`. Ordinary shutdown stress: 4 processes / 16 tabs,
2077.150–4034.913 ms (median 3351.817 ms). Pending-prompt stress:
4 processes / 16 tabs, 287.784–657.917 ms (median 370.496 ms).
Named-profile blocked-TCC stress: 1 process / 4 tabs, 333.033 ms, with
the actual `TEST TCC preflight blocked` marker in
`runtime-abi-stress-w18g-tcc.log`.

| New / expanded native host | Evidence |
|---|---|
| links | Native synthesized Command, Command-Shift, center-button, Shift and Option-Command clicks produce background/foreground/window/split intents. All six created targets load; five retain the source referrer in document and HTTP header, noreferrer suppresses both. Source URL stays unchanged. Foreign-profile/source/nonblank targets reject; callback replacement and pending-source close withdraw; stale/cross-channel IDs reject. |
| extensions | Local MV3 extension queries the active registry tab/current populated window; host creates inactive tab with bridge opener; tabs.get sees it; update navigates and activates through host; runtime.openOptionsPage creates its extension page; windows.create creates a second logical window; get/getAll/getLastFocused/populated/filter queries agree; remove closes and get rejects retired ID; declined creation fails; no-callback cases open no Chromium window. Existing content-script, messaging, action/popup and local install/uninstall regression passes. |
| save | Native text input submits address/card forms on loopback HTTPS. Accept persists one local address; declined Visa 1111 is absent; accepted Visa 0002 is the only stored card. Host summary has masked last four, no PAN/CVC. Navigation, callback replacement and pending close withdraw; stale responses are rejected. |
| auth | No callback cancels to the server's 401 page; Basic wrong password prompts again, correct credentials reach success; local server validates the Digest response; cancel and callback replacement reach 401; close with a request pending emits withdrawal and rejects the stale reply. |
| interstitials | Self-signed certificate warning and Safe Browsing test-blocklist warning render in registry tabs; four native PNG captures; visually inspected certificate and Safe Browsing PNGs; actual page proceed/back controls reach the target/previous entry for both warnings. No production source change needed. |
| prior hosts | All 33 prior hosts pass, including their reopen/mode variants and database/content-settings/OTR post-checks. |

**Network audit:** all 44 native processes looked up outside names; **none
connected outside** (`network-audit-w18g.log`, `NO OUTSIDE CONNECT PASS`). Every
native and smoke process is net-logged and fails on a non-loopback TCP connect
or UDP send, as in 18f. Stress retains the same isolation switches and secure
DNS state. All native/smoke/stress processes use **--use-mock-keychain** and
throwaway profiles. No real Google, Web Store or Payments connection occurred.
Card/address fixtures are local and unsigned-in; the HTTPS key/certificate and
extension CRX key are generated per run. No client Keychain identity was used.
Production receives none of the fixture overrides, focus switches, certificate
SPKI exceptions, gallery override or test Safe Browsing blocklist.

`check_w18g_imports.py` preserves all **13 ABI 1.17 struct size/alignment
pairs** and all **38 ABI 1.38 struct layouts**, including the extension
request/state types. It typechecks gated Swift adoption of every new API plus the prior
18b–18f examples (`imports-w18g.log`). `check_c_abi_exports.py` resolves all
**107 public symbols** (97 + 10) through the framework and confirms loaded ABI
**1.39 / bridge 0.41.0 / Chromium 156.0.8078.74** (`exports-w18g.log`,
`nm-w18g.log`). `run_compat_w18g.py` compiles the unmodified core, downloads,
shutdown and shutdown-veto hosts against exact ABI 1.17 headers from
`1708e96dbe`: **ABI 1.17 HEADER RUNTIME PASS: 4 hosts / 6 process runs**
(`compat-w18g.log`, `runtime-abi-*-legacy117g.log`). Those six processes also
pass the no-outside-connect audit. This is representative compatibility, not
coverage of every historical header revision.

The task owner corrected probes to `pgrep -fl 'siso[ ]ninja'` to avoid probes
matching their own argv. Shared run_c_abi and the older 18c wrapper now use it,
with the executable builder check retained. Old shell wrappers with literal
text were awaited and never killed. One initial waiting auth runner was
cancelled through its own captured tool session and restarted with the corrected
probe; no native process ran in that cancelled attempt. All checks run
sequentially. The replay now invokes the shared guard too.

Pilot evidence (not counted as passing):

- p94/p95 link builds pass, but p95's native pilot exposed the queued initial
  about:blank navigation overwriting the retained target URL. p96 retires that
  initial load. Its first native pilot reached both Command cases, then exposed
  NSEvent's mouse factory assigning the wrong middle-button number; the fixture
  now follows Chromium's center-button CGEvent construction. Final
  `native-w18g-links-p96b.log` and the full gates pass, with no outside connect.

- p86/p87 extension builds failed on integration errors (URLPatternSet namespace,
  instance response helpers and an insertion in TabsMove), corrected in p88.
  The p88 native pilot exposed options URLs rejected by general ABI admission;
  p89 adds internal extension-initiated navigation and passes.
- p90 save pilot exposed cancellation by the submission navigation before host
  delivery; p91 preserves that submission and passes. Extended lifecycle fixture's
  first pilot scheduled work against a navigated document; delayed actions now
  check stage/document identity (`native-w18g-save-lifecycle2.log` passes).
- The p92 setup script stopped before inserting the platform factory hook; p93
  includes it and the subresource routing hook. Native auth passes in
  `native-w18g-auth-p93.log` and the full gates.
- Interstitial fixture pilots used an outdated DOM selector, expected hidden
  error-code text in innerText, reused an allowlisted origin, and had an incorrect
  snapshot callback type. Fixture-only corrections pass in
  `native-w18g-interstitials-p93e.log` and the full gates.

Reproduction from the project root, sequentially with no active builder:

```sh
engine/scripts/build.sh
python3 engine/tests/run_w18g_gates.py
python3 engine/tests/check_w18g_imports.py
python3 engine/tests/check_c_abi_exports.py engine/nm-w18g.log
python3 engine/tests/run_compat_w18g.py
python3 engine/tests/replay_overlay.py > engine/replay-w18g.log
```

Check the builder guard before standalone export invocation too. `openssl`
(system LibreSSL) is required by the per-run CRX/HTTPS fixtures.

## Replay

**REPLAY PASS 58/58 reverse and forward** (`replay-w18g.log`). The reverse
tree `ffe41d3ec78c520fbe20a43802869358d3e18961` matches the upstream pin.
The forward tree `58b2a3cd92f0e9c477107691e3a206d5878d928d` matches final HEAD
`9739603b0f3fee4985c18d7407f3f3c4de05d865`. The disposable-index replay leaves the real
index/worktree untouched and verifies the checkout is clean.

Updated: series 054–057 and patch headers (overlay author, rebase-pin line,
co-author trailer), C-ABI.md, SMOKE-TEST.md, §8 of P-TAB-001-SLICES.md and
18d's DevTools disposition. No shell file or outer-repository commit was made.

## What was not done

Client certificate selection and DevTools are skipped for the ownership/testing
reasons above. Shell adoption, production signing/packaging and real Keychain or
real-store/Payments validation are outside this engine-only task. Extension
window operations remain intentionally limited as documented above.

WAVE 18G DONE head=9739603b0f3fee4985c18d7407f3f3c4de05d865 abi=1.39 replay=pass
