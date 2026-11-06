# Wave 18h implementation report

Chromium **156.0.8078.74**, upstream pin `d331de35ca8ab1358c7a17e4bd41627d55eaef51`.
Starting overlay HEAD `9739603b0f` (end of 18g). Final ABI **1.41**, bridge
**0.43.0**, Configure major **1**. One engine writer at a time: Codex wrote
tab/058 and started client certificates, then hit its usage limit. Claude
reviewed 058, finished and committed tab/059, and ran the validation. No
subagents, no pushes, no outer-repository commits. `shell/` is untouched; its
concurrent wave-27 work and output-directory symlinks are preserved.

## Patch inventory and shell adoption

Each concern has its own additive patch, ABI minor bump and feature. Existing
callback tables and ABI 1.17 layouts are unchanged. Public declarations are in
`chrome/browser/rearc_bridge/rearc_engine_abi.h`; C-ABI.md documents ownership,
statuses and the shell adoption sequence.

| Patch | Commit | ABI / bridge | Feature / new API |
|---|---|---|---|
| `tab/058-hosted-devtools.patch` | `a95beb7f31` | 1.40 / 0.42.0 | `devtools`; `ReArcTabOpenDevTools` |
| `tab/059-host-client-certificates.patch` | `e1bb6df2aa` | 1.41 / 0.43.0 | `client_certificates`; `ReArcEngineSetClientCertificateCallback`, `ReArcClientCertificateRespond` |

Shell adoption: gate on minor >=40 and `devtools`, then call
`ReArcTabOpenDevTools(target, &frontend)` and attach/place the returned tab
like any other (this also implements context-menu Inspect, which stays an
unsupported engine command). Gate on minor >=41 and `client_certificates`,
register the callback before loading HTTPS pages, show the identity list for
the event's origin, and reply with the chosen fingerprint or nullptr.

### Hosted DevTools (tab/058)

`ReArcTabOpenDevTools` creates a new registry WebContents (view type
kDeveloperTools) in the target's profile and space and emits `tab.created`
(foreground, opener = target). It then loads
`devtools://devtools/bundled/devtools_app.html?targetType=tab&panel=elements`.
DevToolsUI configures its bindings in hosted mode, with a delegate that holds
only bridge IDs, and attaches them to the target's tab agent host. No Browser,
DevToolsWindow, native window or keepalive exists.

Bindings: the embedder-message allowlist covers protocol dispatch, load
completion, preferences, host config, reattach/ready, inspected-URL/bounds
reports, window activate/close, zoom and HTTP(S) `loadNetworkResource`.
`requestFileSystems` returns an empty list. Save, addFileSystem and every other
method reply `unsupported`, including workspace, open-in-new-tab, device/port
forwarding, AI services and remote pages. The agent client is untrusted and
may not read or write local files. DevTools extensions are not added. The
protocol filter refuses `Browser.*`, every `Target.*` except `setAutoAttach`
and target-less `getTargetInfo`, and `Page.setDownloadBehavior`.

URL policy: general ABI admission already rejects `devtools` and
`chrome://devtools`. A navigation throttle on every registry tab also cancels
both for non-frontend tabs, including renderer-initiated navigations. A
frontend tab admits only its exact bundled URL (fragments aside). Its
OpenURLFromTab and AddNewContents are refused, and it cannot open DevTools on
itself or be discarded.

Lifetime and veto: `RequestTabClose` on a frontend schedules destruction
immediately, so a frontend has no veto and dispatches no beforeunload, its
target's included. Closing the target never consults the frontend; Chromium's
DevToolsWindow beforeunload interception does not exist on this route. Target
WebContents destruction (TargetWatch) and agent-host closure force-close the
frontend. Profile close and shutdown walk tab IDs in ascending order and stop
at the first veto. IDs are monotonic and a frontend is always created after
its target, so the target is reached first. A target veto therefore cancels
with the frontend still open; otherwise the frontend is gone before profile or
shutdown completion. `ReArcTabOpenDevTools` goes through ABICheckTab, so it is
refused while the engine stops, the profile closes or the target is closing.

Review result: the frontend's lifetime ordering, veto semantics, URL policy and
binding denial match the brief. No engine fix was needed and 058 is unchanged.
The series entry, which Codex had appended below the planned inventory without
a comment, now sits after 057 with one. The native host gained a URL-lockdown
proof, and C-ABI, SMOKE-TEST, §8 and 18d's disposition are updated. Nested
DevTools, remote targets, workspaces, docking and frontend reuse are host or
future concerns.

### Client certificate selection (tab/059)

ChromeContentBrowserClient::SelectClientCertificate first applies Chromium's
enterprise auto-selection policy and the no-WebContents paths. Registry
contents then go to `SelectHostClientCertificate`, which keeps the
ClientCertIdentityList and ClientCertificateDelegate in a Request (at most 64)
and publishes origin plus per-identity subject, issuer, expiry (Unix µs) and
SHA-256 leaf fingerprint. A listed fingerprint marks the request answered and
returns OK; acquisition then runs in a posted task through
`SelfOwningAcquirePrivateKey` and calls `ContinueWithCertificate`, which
Chromium caches per host and port. nullptr, no callback, the 30-second
deadline, primary main-frame navigation, WebContents destruction,
ABIDetachServices (tab, profile and shutdown close), the SSL handler's
cancellation closure, a failed acquisition and callback replacement each
retire the request. Retirement removes it from the map before destroying it,
and destruction drops the delegate, which aborts with
ERR_SSL_CLIENT_AUTH_CERT_NEEDED. No null-certificate choice is cached. A
host's own reply emits no withdrawal, and withdrawals queued by a replacement
are suppressed, both as in `http_auth`.

The WIP review (backup in `engine/wip/wave18h/`, untouched) kept Codex's design
and fixed three things:

- **Host cancel was echoed as a withdrawal.** It now emits none, matching the
  http_auth contract.
- **Use after destruction.** `Acquired` and the nullptr reply destroyed the
  Request through the map while still inside its member function. Retirement
  now moves the Request out first, and only locals are used afterwards.
- **Re-prompts after every abort.** The first native pilot showed Chromium's
  error-page auto-reload retrying ERR_SSL_CLIENT_AUTH_CERT_NEEDED after about
  1 s, then with backoff. `net::IsClientCertificateError` does not include
  -110, because stock Chrome's Cancel continues without a certificate. 059
  adds one exclusion to `ShouldAutoReload` in
  `components/error_page/content/browser/net_error_auto_reloader.cc`.

The expiry computation was also simplified and the test-store gate tightened
(below).

**Test-only store.** macOS uses ClientCertStoreMac (Keychain identities), and
`--use-mock-keychain` does not mock it. `rearc_client_cert_test_store.cc`
installs ProfileNetworkContextService's testing factory for each bridge
profile. It returns `client_1` (CN Client Cert A / B CA) and `client_2`
(Client Cert D / E CA) from net/data PEM, CA and PKCS#8 files, with BoringSSL
memory keys and no SecIdentity, SecKey or Keychain call. Acquisition is held
500 ms and signing 1000 ms so tests can cancel inside each. It compiles only
when `!defined(NDEBUG) && !defined(OFFICIAL_BUILD)`; release (`build.sh
--release`, `is_debug=false`) and official builds get a no-op stub. At runtime
it also needs embedded mode, `--rearc-test-client-cert-dir=<dir>` and
`--use-mock-keychain`, so production never reaches it. This is documented in
C-ABI.md and SMOKE-TEST.md.

Not offered: "continue without a certificate", certificate details/viewer
bytes, enterprise auto-select configuration and identities from real
Keychain, smart cards or PKCS#11. The 30-second deadline is implemented but
not exercised natively, since it would add 30 s to the run.

## Validation

Final build **p106** passes in `out/ReArc-dev-arm64` and matches the final
Chromium source tree; no engine source change followed it. Concern builds p104
(adapter rework) and p105 (auto-reload exclusion) also pass. Chromium HEAD is
`e1bb6df2aa8ddf2255d24389c2533e0620a4e3ce` and its worktree is clean. No
outer-repository commit or push was run.

**Final run:** `run_w18h_gates.py` → **ALL WAVE 18H GATES PASS**
(`gates-w18h.log`, `gates-w18h.stdout`). **39 native hosts / 49 process runs**
pass. Smoke G1–G5 pass (`smoke-w18h.log`; 10.8–19.2 s each), each with
`no-outside-connect`. Ordinary shutdown stress: 4 processes / 16 tabs,
2387.475–4431.430 ms (median 3539.070 ms). Pending-prompt stress:
4 processes / 16 tabs, 327.909–6089.626 ms (median 2029.855 ms).
Named-profile blocked-TCC stress: 1 process / 4 tabs, 1910.051 ms, with
the actual `TEST TCC preflight blocked` marker in
`runtime-abi-stress-w18h-tcc.log`.

| New / expanded native host | Evidence |
|---|---|
| devtools (4 modes) | Every mode: invalid/unknown/nested open rejected; devtools:// create/navigate rejected; frontend found over loopback CDP; console evaluation returns 42 and sets the target title; Elements reveals and selects `#pick`; `connectAutomaticFileSystem` and `Target.createTarget` return unsupported; browser- and frontend-initiated navigation away leaves the bundled app connected; no frontend commit outside `devtools://devtools/bundled/`. Mode 0: frontend-first close leaves the target open and its DOM intact, reopen, then target-first force close destroys the frontend, then forced shutdown. Mode 1: frontend-first close, reopen, nonforced shutdown destroys both before completion. Mode 2: native click arms beforeunload, target close plus nonforced shutdown are vetoed with the frontend still open, then forced shutdown. Mode 3: OTR profile close destroys target and frontend before completion. |
| client_certificates | No callback aborts. Request lists exactly Client Cert A/B CA and D/E CA, expiry 2040-12-31T23:59:59Z, fingerprints equal to the harness's SHA-256 of DER, origin `https://127.0.0.1:P1`. All-zero and short fingerprints return invalid_argument; cancel aborts with no withdrawal and no re-prompt for 1.5 s; repeat reply not_found. Selecting D reaches the server (CN echoed) after delayed acquisition/signing, and Chromium reuses it on the next load without asking. Navigation while pending withdraws once. Tab close during key acquisition withdraws, and the aborted acquisition cached nothing (asked again and selected A). Tab close during signing (log ordering verified by the harness) then a new tab loads with the cached selection. Callback replacement aborts, the stale reply is not_found and neither registration gets events. Nonforced shutdown with a pending request withdraws before completion. The server saw only `/select`, `/cached`, `/after-acquire`, `/after-sign`. The net log shows -110 aborts and the memory-store marker is present. |
| prior hosts | All 37 prior hosts pass, including their reopen/mode variants and database/content-settings/OTR post-checks. |

**Network audit:** all 49 native processes looked up outside names; **none
connected outside** (`network-audit-w18h.log`, `NO OUTSIDE CONNECT PASS`). Every
native and smoke process is net-logged and fails on a non-loopback TCP connect
or UDP send, as in 18f. Stress keeps the same isolation switches and secure
DNS state. All native, smoke and stress processes use **--use-mock-keychain**
and throwaway profiles. No real Keychain identity was read: client identities
come only from the test-only memory store over net/data files. The mTLS server
key is generated per run and accepted only by its SPKI exception. Production
receives none of the fixture switches.

`check_w18h_imports.py` preserves all **13 ABI 1.17 struct size/alignment
pairs** and all **39 ABI 1.40 struct layouts**, and typechecks gated Swift
adoption of `ReArcTabOpenDevTools` and the client-certificate callback/respond
plus the prior 18b–18g examples (`imports-w18h.log`). `check_c_abi_exports.py`
resolves all **110 public symbols** (107 + 3) through the framework and confirms
loaded ABI **1.41 / bridge 0.43.0 / Chromium 156.0.8078.74** (`exports-w18h.log`,
`nm-w18h.log`). `run_compat_w18h.py` compiles the unmodified core, downloads,
shutdown and shutdown-veto hosts against exact ABI 1.17 headers from
`1708e96dbe`: **ABI 1.17 HEADER RUNTIME PASS: 4 hosts / 6 process runs**
(`compat-w18h.log`, `runtime-abi-*-legacy117h.log`). Those six processes also
pass the no-outside-connect audit
(`network-audit-w18h-core-downloads-shutdown-shutdown_veto.log`). This is
representative compatibility, not coverage of every historical header revision.

Every test, gate, import, export, compat and replay run was preceded by
`pgrep -fl 'siso[ ]ninja'` printing nothing, and all ran sequentially. The
shared harness guard also uses the bracketed form. The network-audit filename
now follows `REARC_WAVE_LABEL` (default `w18h`) instead of a hard-coded `w18g`.

Pilot evidence (not counted as passing):

- Codex's DevTools builds p97–p102 and native pilots p98–p102 preceded commit
  `a95beb7f31`; `native-w18h-devtools-p102.log` was its passing 4-mode run.
  p103 compiled the uncommitted client-certificate WIP but had no native test.
- First client-certificate pilot on p104: a harness fingerprint parse error
  (net/data PEMs carry a text dump; DER now comes from openssl). Second pilot:
  all selection/lifecycle stages passed, but exposed the auto-reload
  re-prompt, which then reached the replacement callback; fixed in p105. The
  third pilot asserted an error code on commit events, which carry none at
  this ABI, so the check moved to the net log. The fourth pilot passes.
- First full gate run: the links host timed out because the client-certificate
  post-check loop variable shadowed the harness's shared HTTP `server`, so
  later hosts got a closed port. That was fixture-only; the rerun passes all
  gates.

Reproduction from the project root, sequentially with no active builder:

```sh
engine/scripts/build.sh
python3 engine/tests/run_w18h_gates.py
python3 engine/tests/check_w18h_imports.py
python3 engine/tests/check_c_abi_exports.py engine/nm-w18h.log
python3 engine/tests/run_compat_w18h.py
python3 engine/tests/replay_overlay.py > engine/replay-w18h.log
```

Check the builder guard before standalone export invocation too. `openssl`
(system LibreSSL) is required by the per-run CRX/HTTPS/mTLS fixtures.

## Replay

**REPLAY PASS 60/60 reverse and forward** (`replay-w18h.log`). The reverse
tree `ffe41d3ec78c520fbe20a43802869358d3e18961` matches the upstream pin.
The forward tree `f5a15f3af0d83a1fa744388bfc2c93dcb5472bc0` matches final HEAD
`e1bb6df2aa8ddf2255d24389c2533e0620a4e3ce`. The disposable-index replay leaves the real
index/worktree untouched and verifies the checkout is clean.

Updated: series 058 (moved after 057, commented) and 059, the 059 patch header
(overlay author, rebase-pin line, co-author trailers; `git format-patch` output
identical to the commit, as for 057/058), C-ABI.md, SMOKE-TEST.md, §8 of
P-TAB-001-SLICES.md and 18d's DevTools disposition. No shell file or
outer-repository commit was made.

## What was not done

Shell adoption, production signing/packaging and real Keychain or smart-card
identity validation are outside this engine-only task. The client-certificate
30-second deadline is implemented but not exercised natively.
"Continue without a certificate", certificate viewing and DevTools
docking/reuse/nested inspection/remote targets/workspaces stay unsupported, as
documented above.

WAVE 18H DONE head=e1bb6df2aa8ddf2255d24389c2533e0620a4e3ce abi=1.41 replay=pass
