# Wave 18e implementation report

Chromium **156.0.8078.74**, upstream pin `d331de35ca8ab1358c7a17e4bd41627d55eaef51`.
Starting overlay HEAD `1434c7b833`. Final ABI **1.30**, bridge **0.32.0**,
Configure major **1**. One writer, no subagents, no pushes, no outer-repository
commits. `shell/` was left untouched; concurrent shell (wave 22) work was not
staged or reverted. Existing output-directory symlinks were preserved.

## Patch inventory and shell adoption

Each concern has its own additive patch, minor bump and feature. Gate shell
adoption on both the minor and the feature string. Existing callback tables and
all ABI 1.17 structure layouts are unchanged. Public declarations are in
`chrome/browser/rearc_bridge/rearc_engine_abi.h`.
[C-ABI.md](C-ABI.md#default-search-and-autocomplete-126) documents ownership,
validation, numeric values and exact call semantics.

| Patch | Commit | ABI / bridge | Feature / new API |
|---|---|---|---|
| `tab/044-default-search-autocomplete.patch` | `669d2bfe61` | 1.26 / 0.28.0 | `search_autocomplete`; `ReArcSearchGetDefaultProvider`, `ReArcSearchSetDefaultProvider`, `ReArcSearchClassifyInput`, `ReArcAutocompleteStart`, `ReArcAutocompleteStop` |
| `tab/045-html-fullscreen.patch` | `8dc537d8c0` | 1.27 / 0.29.0 | `html_fullscreen`; `ReArcEngineSetFullscreenCallback`, `ReArcTabExitFullscreen`, `ReArcTabGetFullscreenState`, `ReArcFullscreenEvent` |
| `tab/046-host-pdf-printing.patch` | `3cf2236a0c` | 1.28 / 0.30.0 | `printing`; `ReArcEngineSetPrintCallback`, `ReArcTabPrintToPDF`, `ReArcPrintOptions`, `ReArcPrintRequestEvent` |
| `tab/047-page-drop-policy.patch` | `5a857e2ca6` | 1.29 / 0.31.0 | `page_drops`; `ReArcEngineSetDropPolicy`, `REARC_DROP_*` |
| `tab/048-video-picture-in-picture.patch` | `5e59268cef` | 1.30 / 0.32.0 | `picture_in_picture` (P-PIP-001); `ReArcEngineSetPictureInPictureCallback`, `ReArcPictureInPictureEvent`; `ReArcTabSetPictureInPicture` becomes functional |

### Default search and autocomplete

The default-provider query reads the addressed profile's TemplateURLService.
The search and suggest URLs come back ready to use: Chromium parameters are
resolved and `%s` marks the terms. SetDefaultProvider adds (or reuses) a user
engine and makes it the user-selected default. It is rejected for OTR IDs and
for policy-managed search (`invalid_state`). Classification uses a per-profile
AutocompleteClassifier (synchronous providers, no network), returning URL or
search with the navigable destination.

Autocomplete runs one Chromium AutocompleteController query per profile. It
gives zero or more `done=false` updates, then exactly one `done=true` result
per accepted query ID. That result is OK, or `cancelled` when superseded by the
next Start, Stop or profile release. Matches carry kind, match type, relevance,
contents, description, destination, fill-into-edit and inline completion. The
provider set is local (history quick/URL/fuzzy, bookmarks, shortcuts, keyword,
builtin, calculator) plus SearchProvider. Zero-suggest, document, on-device,
ML, open-tab, cluster/embedding and contextual providers are not constructed.

**OTR:** Chromium's CanSendSuggestRequest already refuses remote suggest for
OTR. In addition, OTR IDs get a provider client that returns no history,
URL index, bookmarks or shortcuts. Chromium would otherwise resolve those to the
original profile, and 18d's history ABI deliberately prevents that access.
OTR results are therefore what-you-typed, verbatim search, keyword and builtin
matches only. The native fixture's suggest server recorded zero OTR requests.

### HTML fullscreen

The browser-less tab delegate implements CanEnter/Enter/Exit/IsFullscreen and
handles Escape in PreHandleKeyboardEvent, as Chrome's FullscreenController
does. Entry requires a registered callback and a presented (visibility-intent,
non-hidden) tab. Entry resynchronizes the renderer's visual properties so the
page's `requestFullscreen()` resolves. The host receives the entered event, puts
the window into native fullscreen, hides the sidebar and resizes the view. Each
entry has exactly one exit event, with reason 0 page/engine, 1 host, 2 Escape,
3 closed or 4 hidden. Without a callback page requests are refused, as before.
The close pipeline hides the view before destroying contents, so the hidden
handler consults close state and reports reason 3.

### Printing — choice and rationale

**Chosen: generate a PDF in the engine and render the print UI in the host.**
Chromium's print preview is a WebUI constrained dialog. It needs a Browser and
a WebContentsModalDialogManager, neither of which a registry tab has. Its
system-dialog path would run a Chromium-owned modal NSPrintPanel on the shell's
window. PDF generation (PrintViewManagerBase::PrintToPdf → PdfPrintJob, the
Page.printToPDF path) needs only the renderer, works for hidden tabs and leaves
all UI in the shell. The shell passes the bytes to PDFKit/NSPrintOperation for
Cmd+P, or writes them for Save as PDF.

Browser-less tabs now attach Chromium's printing helpers. PrintViewManager's
scripted-preview, requested-preview and ScriptedPrint system-dialog entry points
recognize registry tabs. They complete the renderer request immediately, so
`window.print()` returns and beforeprint/afterprint fire, then post a host
request event. One PDF job per tab. Navigation, discard, close and
frame-teardown failures report `cancelled`. Results above 256 MiB are
`too_large`, and bad page ranges are `invalid_argument`. Known semantic: the
page is printed in its post-afterprint DOM state.

### Drop audit and policy

**Audit:** the S1 view delegate aborted every drop in OnPerformingDrop.
WebDragDest still forwarded dragenter/dragover first, so pages saw drag types,
including the shell's own sidebar drags, but never received a drop. The shell's
current sidebar drags carry only a UUID string (NSItemProvider/NSString). Its
split overlay intercepts them when present.

**Policy:** `ReArcEngineSetDropPolicy(accept, blocked_types, count)` selects
files, text (plain/HTML/RTF/web custom data), URLs and promised image data.
`CanDragEnter` refuses a drag with no accepted part before any page event, and
the drop is filtered before Chromium completes its normal drop. That keeps
FilterDropData and per-file renderer read grants. Exact blocked UTIs are
rejected in WebContentsViewCocoa (the NSDraggingDestination) before WebDragDest.
Such drags yield no operation and no page events.
**Shell action:** add a private UTI to sidebar drags and register it here.
Chromium only exposes raw image bytes as a File when a source URL or
Content-Disposition accompanies them; image files and URLs use those kinds.
Without a policy drops stay aborted.

### Picture in Picture

Registering the PiP callback enables the delegate's EnterPictureInPicture /
ExitPictureInPicture through Chromium's PictureInPictureWindowManager and
Views overlay window. On macOS this needs no Browser. `video.requestPictureInPicture()`
works with user activation. `ReArcTabSetPictureInPicture(tab, true)` uses the
tab's MediaSession `EnterPictureInPicture`, the Global Media Controls path, and
its availability is reported as media-event `pip_available`. Media events now
carry real `pip_active`. Phase 2 tells the host to present the tab after the
overlay's Back-to-tab button. It is derived from the activation that Chromium
issues synchronously after the PiP exit; page `window.focus()` stays ignored.

Two Chromium rules shape the host path and were found natively. MediaStream
players are one-shot, so they are never offered browser-initiated PiP. Only
players with unmuted audio join the media session. The fixture therefore uses a
silent (zero-gain) recorded WebM for the host path.

**Document PiP: not supported, documented.** Chromium opens it through
AddNewContents with `NEW_PICTURE_IN_PICTURE` into a Browser of type
PICTURE_IN_PICTURE, which tab adoption rejects. Supporting it needs a
registry- or shell-owned always-on-top WebContents window with its own
lifetime/close/focus/opener rules. That is not cheap, so no partial support is
shipped. Auto-PiP and Meet integration are unchanged.

## Validation

Final build **p77** passes in `out/ReArc-dev-arm64` and is the HEAD tree (no
source changes after p77). Concern builds p70–p76 also pass. p69 failed on a
`ASCIIToUTF16` char-array static assertion and was corrected before the
tab/044 commit. Before each build the raw `pgrep -fl "siso ninja"` probe was
required to be empty. Builds waited for the concurrent shell self-test, whose
bundle symlinks this output directory and whose wrapper quotes the probe text.

**Final run:** `run_w18e_gates.py` → **ALL WAVE 18E GATES PASS**
(`gates-w18e.log`). 30 native ABI hosts / 36 process runs pass, including the
five new hosts. Smoke G1–G5 pass (`smoke-w18e.log`; 10.9–15.8 s each). Ordinary
shutdown stress: 4 processes / 16 tabs, 2487–4523 ms (median 3502 ms).
Pending-prompt stress: 4 processes / 16 tabs, 288–328 ms (median 308 ms).
Named-profile blocked-TCC stress: 1 process / 4 tabs, 372.288 ms, with the
actual `TEST TCC preflight blocked` marker in `runtime-abi-stress-w18e-tcc.log`.

| New native host | Evidence |
|---|---|
| search | Initial Google provider read; local provider set and read back; `example.com` → URL `http://example.com/`; `hello world` → local search URL; superseded query cancelled exactly once; history matches for typed visits; remote suggestions from the fixture suggest endpoint; Stop and named-profile close cancel; OTR shares the engine, rejects Set, returns no history matches; fixture recorded no OTR suggest request. |
| fullscreen | No-callback request refused; five trusted-click entries; exits by host call (1), native Escape keyDown (2), `document.exitFullscreen` (0), hiding the view (4) and close (3); page `fullscreenElement` agrees each time. |
| print | Default PDF 3 pages; landscape/background/0.5 in margins/range "2" → 1 page; busy second job; out-of-range "9" → invalid_argument; `window.print()` returns with beforeprint+afterprint and posts one source-0 request that prints; navigation and close cancel. |
| drops | Real WebContentsViewCocoa NSDraggingDestination with synthetic NSDraggingInfo over unique pasteboards: legacy abort; text+URL, Finder file (content readable), raw PNG bytes (not a File, per Chromium), promised PNG with Content-Disposition, PNG file; private-UTI drag invisible (no events, no operation); text-only policy refuses a files-only drag and strips the file from a mixed one; accept 0 refuses. |
| pip | No-callback page request NotSupportedError and host `unsupported`; page entry on trusted click; host exit; MediaStream not offered; recorded file → `pip_available`, host entry; native click on the overlay's Back-to-tab button → exit then phase 2; close while active → exit; `pip_active` observed. |
| prior 25 hosts | History, danger, discard, passwords, context, permissions, files, dialogs, helpers, find, downloads, WebUI, migration, shutdown (3 modes), shutdown veto, core, services, URLs, eval, scheme return, profiles (+reopen), identity, zoom (+reopen), messages and branding pass. |

`check_w18e_imports.py` preserves all **13 ABI 1.17 struct size/alignment
pairs**. It typechecks gated Swift adoption of every new API plus all
18b–18d examples (`imports-w18e.log`). `check_c_abi_exports.py` resolves all
**85 public symbols** through the framework and confirms loaded ABI 1.30 /
bridge 0.32.0 / Chromium 156.0.8078.74 (`exports-w18e.log`, `nm-w18e.log`).
`run_compat_w18e.py` compiles the unmodified core, downloads, shutdown and
shutdown-veto hosts against the exact ABI 1.17 headers from `1708e96dbe`. It
gives **ABI 1.17 HEADER RUNTIME PASS: 4 hosts / 6 process runs**
(`compat-w18e.log`, `runtime-abi-*-legacy117e.log`). This is a representative
set, not every historical header revision.

All native, smoke and stress processes use **--use-mock-keychain** and
disposable profiles. No real Keychain was touched. Fullscreen and PiP hosts use
the existing test-only loopback CDP focus emulation and Browser.close cleanup.
The drop host never writes the general or system drag pasteboard. The PiP
fixture's audio is zero-gain and runs with `--autoplay-policy=no-user-gesture-required`.
No production focus, autoplay or keychain privilege was added.

Pilot evidence (retained, not counted as passing):
- Fixture errors corrected before final evidence: fullscreen double evaluation
  and the hidden-vs-closed reason (an engine fix, p73); print's empty
  incremental-update URL, a size threshold, and close reporting `internal`
  (an engine fix, p75); drops' nested-JSON assertions; PiP's MediaStream,
  muted-player and transient (2.5 s) file attempts and the AX-tree Back-to-tab
  search, replaced by a native click.
- `gates-w18e-pilot-profiles-timeout.log`: the first full run, started right
  after a shell fullscreen self-test, timed out PiP's first click (window not
  key). The PiP host now uses CDP focus emulation like the other click-driven
  hosts and then passed 2/2 alone.
- A second run was stopped by the raw build gate when a shell self-test started
  mid-run (`gates-w18e-interrupted1.log`). `run_c_abi.build_gate` now waits up
  to 30 minutes for the raw probe to clear instead of aborting. The probe must
  still be empty before every process, and executable builders still fail
  immediately.
- A third run's `profiles` host hit a hidden-tab evaluation deadline (status 18)
  while the shell self-test loaded the machine. This is the load sensitivity
  documented in wave 16. `profiles` then passed 2/2 alone (both phases), and the
  final complete run passed every host.

Reproduction from the project root (no active builder or quoting wrapper):

```sh
engine/scripts/build.sh
python3 engine/tests/run_w18e_gates.py
python3 engine/tests/check_w18e_imports.py
python3 engine/tests/check_c_abi_exports.py engine/nm-w18e.log
python3 engine/tests/run_compat_w18e.py
python3 engine/tests/replay_overlay.py > engine/replay-w18e.log
```

Run the commands sequentially, checking the build guard before the standalone
export/replay invocations as well.

## Replay

REPLAY PASS 49/49 reverse and forward. The reverse tree
`ffe41d3ec78c520fbe20a43802869358d3e18961` matches the pin. The forward tree
`8fe550667f9e5e442e0bb3bfce2ebcb673ae66f1` matches HEAD
`5e59268cef7faddcf4ebee39c162e7d52197eb12`. The real index and worktree are
untouched and the Chromium checkout is clean. Log: `replay-w18e.log`.

Updated: series entries, patch headers (overlay author, rebase-pin line,
co-author trailer), C-ABI.md, IPC-CONTRACT.md (PiP note), SMOKE-TEST.md and §8
of P-TAB-001-SLICES.md. No push was run.

## What was not done

- Document Picture-in-Picture, auto-PiP and Meet controls (see above). Only
  video PiP is advertised.
- Shell adoption: no shell edits. Adoption needs these changes in the shell:
  - sidebar drags must carry and register a private UTI;
  - the shell must call `ReArcEngineSetDropPolicy` before pages can receive drops;
  - a print callback, plus a PDFKit/NSPrintOperation and save panel;
  - fullscreen window/sidebar handling;
  - a PiP callback that handles phase 2;
  - command-bar use of the autocomplete/classification ABI.
- Engine-rendered print preview or Chromium system print dialogs for registry
  tabs; page-range/printer selection belongs to the host UI.
- Remote suggestions for OTR, zero-suggest/on-focus suggestions, document/Drive,
  on-device or ML-scored providers, deleting autocomplete matches, and
  OpenSearch learned engines. Callback replacement for fullscreen/PiP is
  implemented but not exercised by a native fixture.
- DevTools, extensions and the autofill popup (out of scope). Real Keychain
  access, production packaging/signing/notarization.

WAVE 18E DONE head=5e59268cef7faddcf4ebee39c162e7d52197eb12 abi=1.30 replay=pass
