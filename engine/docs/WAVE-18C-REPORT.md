# Wave 18c implementation report

Chromium **156.0.8078.74**, upstream pin `d331de35ca8ab1358c7a17e4bd41627d55eaef51`.
Starting overlay HEAD `1708e96dbe`. Final ABI **1.22**, bridge **0.24.0**,
Configure major **1**. One writer, no subagents, no pushes, no outer-repository
commits. `shell/` was left untouched; concurrent shell work was not staged or
reverted. Existing output-directory symlinks were preserved.

## Patch inventory and shell adoption

Every capability is additive. The shell must check both the ABI minor and the
feature string before registering its callback or offering its UI. Existing
`ReArcCallbacks` and all ABI 1.17 structs retain their layouts. Public declarations
and numeric actions are in `chrome/browser/rearc_bridge/rearc_engine_abi.h`;
[the C ABI contract](C-ABI.md#host-prompt-channels-wave-18c) describes ownership,
cancellation, reply validation and the exact mode/action numbers.

| Patch | Commit | ABI / bridge | Feature / new API |
|---|---|---|---|
| `tab/036-javascript-dialog-requests.patch` | `4c2fa8c0bd` | 1.18 / 0.20.0 | `javascript_dialogs`; `ReArcEngineSetJavaScriptDialogCallback`, `ReArcJavaScriptDialogRespond`, `ReArcJavaScriptDialogEvent` |
| `tab/037-file-chooser-requests.patch` | `5d6a80867c` | 1.19 / 0.21.0 | `file_chooser`; `ReArcEngineSetFileChooserCallback`, `ReArcFileChooserRespond`, `ReArcFileChooserEvent` |
| `tab/038-permission-prompt-requests.patch` | `7fe0314f32` | 1.20 / 0.22.0 | `permission_prompts`; `ReArcEngineSetPermissionCallback`, `ReArcPermissionRespond`, `ReArcPermissionEvent` |
| `tab/039-page-context-menu.patch` | `72067026d0` | 1.21 / 0.23.0 | `context_menu`; `ReArcEngineSetContextMenuCallback`, `ReArcContextMenuCommand`, `ReArcContextMenuEvent` |
| `tab/040-password-prompt-requests.patch` | 3be2bd6fdb | 1.22 / 0.24.0 | `password_prompts`; `ReArcEngineSetPasswordPromptCallback`, `ReArcPasswordPromptRespond`, `ReArcPasswordPromptEvent` |

All five channels use deferred Chromium UI tasks and borrowed strings/arrays.
Each includes profile/tab/content-generation/request identity and a phase:
0 request, 1 cancellation. A reply consumes the request; late/repeated replies
return `not_found`. Callback replacement cancels old requests and invalidates
old queued deliveries. Without a registered callback, the bridge retains safe
cancellation/dismissal and creates no Chromium prompt/menu UI. Host contexts
must survive until unregistration or Run returns. A shell response does not
imply a password-store write or download has completed.

### JavaScript dialogs

The existing WebContentsUserData-owned JavaScriptDialogManager now retains the
Chromium callback for alert, confirm, prompt and beforeunload. Events carry the
requesting frame's serialized origin, message, default text and reload flag.
A boolean/text response completes that same Chromium callback. Beforeunload
therefore joins the existing close/navigation controller, including veto, rather
than introducing another close pipeline. Primary cross-document navigation,
originating-frame deletion, close and host replacement cancel pending requests.
No host retains the earlier conservative beforeunload veto.

### File selection

ReArcTabDelegate::RunFileChooser forwards Chromium's mode, title, default path,
accept MIME types/extensions and trusted frame origin. Host-selected paths
complete FileSelectListener. Open, multiple, upload folder, directory and save
mode values are represented. Upload folders enumerate regular descendants on a
bounded ThreadPool task without traversing symlinks. Invalid path syntax leaves
the request pending; filesystem/enumeration failure cancels it. A worker reply
checks its still-pending ID before accessing the listener.

ChromeDownloadManagerDelegate's embedded confirmation branch now uses this same
host channel for save paths. Download policy prompt=1 is supported when a host
chooser is registered. No Chromium file picker/confirmation UI is constructed;
the no-host 1.17 download fallback remains. The shell's save panel must handle
overwrite confirmation.

### Permissions

Selective tab-helper attachment now includes PermissionRequestManager.
ChromePermissionsClient's production CreatePrompt seam returns a host adapter
for registry-owned contents. The adapter renders nothing; Chromium retains
eligibility, grouping, origin, policy, gesture and embargo logic. Events carry
requesting/embedding origins and all coalesced PermissionKeyForRequestType
strings. One response covers the group, including camera+microphone.

A default-true `PermissionPromptDecision.persist` flag is set by the host adapter,
propagated to duplicate requests, and respected by PermissionContextBase. This
avoids writing then undoing a durable setting. Persistent allow/deny uses
Chromium's normal HostContentSettingsMap path. Nonpersistent allow/deny resolves
the current request without storing a site setting. Dismiss never stores an
allow/block. Chromium's ordinary desktop prompts keep the default behavior.

Camera/microphone delegates additionally forward to MediaCaptureDevicesDispatcher:
content's default would otherwise reject them before any permission request.
Screen/tab capture stays rejected. Permission follow-up infobars and surveys
are suppressed for registry-owned tabs. macOS TCC authorization is independent;
wave 16's media-permission cache and shutdown task traits are unchanged.

### Page context menus

The embedded view delegate forwards browser-validated ContextMenuParams to a
per-WebContents adapter. The event includes link/source/page/frame URLs,
selection, editable/image flags, Blink media type/edit flags and RenderView-local
DIP coordinates. The shell maps coordinates and renders its menu. Commands use
Chromium's WebContents edit operations, existing ABI navigation, renderer image
copy and SaveFrameWithHeaders for image downloads. Referrer sanitation and the
image Accept header follow RenderViewContextMenu's logic. A weak-document
pointer and cancellation prevent commands from using a replaced document.

Open link means current-tab navigation through the existing ABI URL policy;
the shell can use the event URL with TabCreate for a new tab. Inspect is
explicitly `unsupported`: the Chromium DevToolsWindow/inspection path creates
Browser UI and no safe browser-less DevTools frontend is wired here. The
command leaves the request pending so the shell can dismiss it.

### Password offers

ChromePasswordManagerClient's browser-less save/update branch transfers its
PasswordFormManagerForUI to a per-WebContents offer adapter. The event contains
only submitted-form origin, username and update flag; no password crosses the
ABI. Save/update, never and dismiss call Save, OnNeverClicked and OnNoInteraction
on that same manager. Chromium owns detection, matching, blocklisting,
encryption and password-store writes. Navigation after the offer, tab close
and callback replacement cancel the pending offer. The existing password-manager
WebUI remains the management surface.

## Validation

Final build **p62** passes in `out/ReArc-dev-arm64`. Concern builds p54 and
p56–p61 also pass. p55 failed on an incomplete FileSelectListener type/include
and was corrected before the file-selection commit. No production-source
changes followed p62.

**22 native ABI hosts / 27 process runs, G1–G5 and nine stress processes /
36 attached shutdown tabs pass.** Evidence: `gates-w18c.log`,
`smoke-w18c.log`, `runtime-abi-*-w18c.log`, and the three
`runtime-abi-stress-w18c*.log` files. The first three native hosts passed in
`gates-w18c-pilot.log`; a shared fixture-directory collision then stopped the
runner before the file host. After assigning each host its own fixture
directory, the suite resumed from files and completed all remaining hosts.
The runner now supports a fresh complete run without that collision.

| Native host | Evidence |
|---|---|
| dialogs | Alert accepted; confirm rejected; prompt receives default text and returns supplied text; real activated beforeunload veto and accept; pending navigation/close cancellation and late replies. Seven requests, two cancellation events. |
| files | Single/multiple paths reach FileList; accept extensions/MIME types; folder relative paths exclude a symlink escape; a 64-KiB download uses the chosen save path; explicit cancel/navigation/close retire requests. Seven requests, three cancellations. |
| permissions | Nonpersistent then durable notification allow, nonpersistent clipboard deny, durable MIDI deny, grouped camera/microphone deny, nonpersistent geolocation deny, navigation/close cancellation. Eight requests, two cancellations. Navigator permission queries and shutdown-written Preferences confirm durable settings versus absent transient settings. |
| context | Validated link/source/selection/editable/coordinate data; copy link/open/back/forward/reload; copy/cut/paste/select-all; copy-image command accepted; HTTP-image download completes; unsupported Inspect and invalid commands; navigation/close make IDs stale. |
| passwords | Real trusted input/submission generates save, update, dismiss, two cancelled offers and never-save. Six offers, two cancellations. Login Data contains one saved username with a newer password-modification timestamp and an encrypted value, plus one blocklist row; dismissed/cancelled credentials are absent. |
| prior 17 hosts | History/autofill usage, find, downloads, WebUI, migration/reopen, shutdown/join/veto, core, services, URL policy, evaluation, scheme return, profiles/reopen/OTR, identity, zoom/reopen, page messages and branding pass. |

All native fixtures and smoke/stress processes use **--use-mock-keychain** and
disposable profiles. The native permission host uses fake media devices and
rejects capture; no physical camera/microphone authorization is granted.
Permission and password tests use a separate test-only loopback DevTools socket
for focus emulation/trusted text input on the locked desktop. Like earlier
WebUI/helpers hosts, they release its REMOTE_DEBUGGING keepalive with
Browser.close after ABI tab closure/shutdown. This adds no production focus,
visibility, keychain or script privilege.

Ordinary shutdown stress: four processes / sixteen tabs, 3091–4260 ms elapsed
(median 3623 ms). Pending-dialog stress: four processes / sixteen tabs and
sixteen unanswered alerts; every ID cancels exactly once, 272–1510 ms elapsed
(median 408 ms). Named-profile **blocked TCC preflight**: one process / four
tabs, actual `TEST TCC preflight blocked` marker and successful shutdown in
**1735.718 ms**. The interposer blocks only test OS reads; mock Keychain stays
enabled. The first TCC pilot exited normally but never started the queued read,
so it was rejected. The corrected diagnostic enables Chromium's existing
ImprovedStartupBestEffortDelay feature with a one-second startup failsafe and
zero visible-tab wait, only in that test, to start the queued preflight before
shutdown. Production startup scheduling and wave-16 task traits are unchanged.
The rejected probe remains in `gates-w18c-tcc-pilot.log` and
`runtime-abi-stress-w18c-tcc-pilot.log`.

File-test pilots assumed an accept-filter order and redeclared a top-level JS
variable; password-test pilots used script-assigned autofill values and one
async test helper retained a temporary prefix by reference. These were test
errors, corrected before the final passing evidence; their pilot logs are
retained. Trusted typing is necessary to replace Chromium's autofill user-input
state. No production bypass was added for those fixtures.

`check_w18c_imports.py` preserves all **13 ABI 1.17 struct size/alignment pairs**
and typechecks all five exact gated Swift callback/reply examples.
`check_c_abi_exports.py` resolves all **66 public symbols** through the framework
and confirms loaded ABI 1.22 / bridge 0.24.0 / Chromium 156.0.8078.74. Logs:
`imports-w18c.log`, `exports-w18c.log`, `nm-w18c.log`.

`run_compat_w18c.py` compiles unmodified core, downloads, shutdown and activated
beforeunload-veto hosts against the exact pre-wave ABI 1.17 headers from
`1708e96dbe`. All **four hosts / six process runs pass** against the new binary.
Evidence: `compat-w18c.log` and `runtime-abi-*-legacy117c.log`. This is a
representative runtime compatibility set, not a claim that every historical
header revision/host was rerun in this wave.

The raw `pgrep -fl "siso ninja"` check was empty before each wave runner;
the shared build guard also runs before individual process tests. Testing
waited for concurrent shell wrappers containing that pattern to finish.
No Chromium builder was active during runtime validation.

Reproduction from the project root (no active builder):

```sh
engine/scripts/build.sh
python3 engine/tests/run_w18c_gates.py
python3 engine/tests/check_w18c_imports.py
python3 engine/tests/check_c_abi_exports.py engine/nm-w18c.log
python3 engine/tests/run_compat_w18c.py
python3 engine/tests/replay_overlay.py > engine/replay-w18c.log
```

## Replay

`replay_overlay.py` passes **41/41 reverse and forward** patches using a
fresh temporary `GIT_INDEX_FILE`. It reverse-applies every series entry newest
first, then applies every entry forward using Python argument arrays (no zsh
word-splitting dependency).

- Reverse tree `ffe41d3ec78c520fbe20a43802869358d3e18961` exactly matches
  pin `d331de35ca8ab1358c7a17e4bd41627d55eaef51`.
- Forward tree `c26c7f96b4404aa263e25a3b6f2c5a18caada695` exactly matches
  final HEAD `3be2bd6fdb544b592cdbfa3703c6c263c3291042`.
- The final worktree comparison passes, HEAD is unchanged, and the real index
  and worktree remain clean. Log: `replay-w18c.log`.

Series entries, patch headers, C-ABI.md, IPC-CONTRACT.md and §8 of
P-TAB-001-SLICES.md are updated. All five commits carry the overlay author,
rebase-pin header and Codex co-author trailer. No push was run.

## What was not done

- Browser-less DevTools frontend/Inspect. The command explicitly returns
  unsupported; chrome://devtools was not broadly admitted.
- Desktop File System Access API panels, drag/drop directory enumeration,
  camera-capture file inputs, screen/tab sharing, audio-output/device choosers,
  extension-specific prompts and embedded permission-element flow variants.
  These do not become supported merely because PermissionRequestManager or
  RunFileChooser is present.
- Real Keychain access, real OS/TCC authorization interaction, granted physical
  camera/microphone capture, and production packaging/signing/notarization.
  Native fixtures use disposable profiles and --use-mock-keychain.
- Shell UI implementation or validation of its concurrent edits. The engine
  supplies requests and commands; no Chromium dialog/menu UI is used for these
  channels. OS permission UI remains the OS's responsibility.

WAVE 18C DONE head=3be2bd6fdb544b592cdbfa3703c6c263c3291042 abi=1.22 replay=pass
