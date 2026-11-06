# Wave launch engine report

Chromium **156.0.8078.74**, upstream pin `d331de35ca8ab1358c7a17e4bd41627d55eaef51`.
Starting overlay HEAD `09332ffebe` (perf-0, ABI 1.44). Final ABI **1.45**,
bridge **0.47.0**, Configure major **1**. One writer (Claude), no subagents, no
pushes. The shell side is committed in the outer repository on
`wave-11-chromium-engine` (`1f752991`, `4308f9db`). Nothing under `engine/`
was committed there. Results and their reading: docs/PERF-BASELINE.md,
"launch: early window (ABI 1.45)".

## What blocked the window

The shell could build no window before `ready`. `ready` is
`ChromeBrowserMainPartsMac::PostBrowserStart`, at the end of
`PreMainMessageLoopRunImpl`, and the ABI posts it to the main loop, so it is
delivered only once `RunMainMessageLoop` starts. Before that, ChromeMain
holds the main thread and runs, in order:

- `ContentMain`, with `RegisterBrowserCrApp()` creating `ReArcApplication`;
- `PreEarlyInitialization` and the main message loop's creation;
- `PreCreateThreads`: `PreCreateThreadsImpl` (Local State, field trials,
  browser process), then the ReArc branch, which installs the
  `ReArcAppDelegate` and the placeholder menu;
- thread creation;
- `PreMainMessageLoopRun`: profile, services, extensions, `PostBrowserStart`.

perf-3 had already moved the shell's own disk work (sidebar, history,
downloads, permissions, sync) onto a worker that overlaps ChromeMain. What
remained serial was AppKit: the window, the SwiftUI sidebar's first layout
and the Core Animation commit all waited for `ready`.

AppKit windows are legal once the NSApplication exists. The earliest point
where the bridge already runs ReArc code, with the application, its delegate
and a menu in place, is the end of `InstallReArcAppDelegateAndMenu`.

## Patch and ABI

| Patch | Commit | ABI / bridge | Feature / new API |
|---|---|---|---|
| `tab/064-host-early-window.patch` | `35631c50f5` | 1.45 / 0.47.0 | `early_window`; `ReArcEngineSetEarlyWindowCallback` |

- **Setting it.** The callback can be set only between Configure and Run;
  otherwise the call returns `invalid_state`.
- **When it runs.** Run calls it once, synchronously on the main thread, at
  the end of `InstallReArcAppDelegateAndMenu`, inside `PreCreateThreads`.
  That is before browser threads, profiles and services, and before the
  main loop runs.
- **What the host may do there.** Create, order front, lay out and display
  windows, and flush the CA transaction itself. Every other ABI call answers
  as it does before ready.
- **Upgrade surface.** The hook is a function pointer
  (`rearc::SetApplicationReadyHook`) in the `rearc_bridge` source set. The
  ABI sets it in Configure. The only upstream files touched are
  `framework.exports` and `framework.order`, which list the new function
  after `_ReArcEngineGetProcesses`, as tab/060 requires.
- **Why not `rearc_readiness`.** A first draft put the signal there. That is
  `chrome/browser` code, which depends on `rearc_bridge`, so calling it from
  the delegate would have made a dependency cycle.
- **Signpost.** An `abi` interval, `EarlyWindow`, covers the callback.
- **Contract.** engine/docs/C-ABI.md, "Early window (1.45)".

## Validation

All builds were sequential, each preceded by `pgrep -fl 'siso[ ]ninja'`
printing nothing. Every native or UI run held the input lock, with the UI
gate present. The machine's 1-minute load average stayed between 14 and 22
the whole time.

- **Dev build.** `engine/scripts/build.sh` into `out/ReArc-dev-arm64`
  (`build-launch-p1.log`, exit 0). Its sources match HEAD `35631c50f5`.
- **New native host** `c_abi_launch_host.mm` (`runtime-abi-launch.log`):
  - before Configure, setting the callback returns `invalid_state`; after
    Configure, null and a callback are accepted;
  - in the callback, NSApp, its delegate and menu exist;
    `ReArcEngineDefaultProfile()` is 0; `ReArcTabCreate` returns
    `engine_not_ready`; setting the callback again returns `invalid_state`;
  - a window is ordered front and flushed there. In this debug build that
    was 1144 ms after main;
  - ready came 979 ms later, with the window still up. The window registers
    and hosts an attached tab, and Run returns 0 after exactly one call.

  `run_c_abi.py` now runs `launch` first and links QuartzCore for every host.
- **Regression hosts.** `core` passes. **`perf` fails** at step 1, twice:
  "PERF timeout at step 1", no `shown` presentation event within the host's
  30 s budget after a 3.4 s page load, at load average 22. tab/064 does not
  touch that path, and the perf host sets no early callback. It was not
  re-run on a quiet machine, so the cause is still open. The full 41-host
  gate (`run_perf0_gates.py`), smoke and network audit were **not** re-run.
- **Replay.** `replay_overlay.py` (`replay-launch.log`): **REPLAY PASS 65/65**
  reverse and forward; the forward tree `a4c9807abf` matches HEAD
  `35631c50f5`.
- **Release engine.** `shell/scripts/build-engine-release.sh`, incremental
  in `out/ReArc-release-arm64` (`build-release-launch.log`, exit 0). The
  script's export check passed. `nm -gU` lists 122 `_ReArc*` symbols,
  including `_ReArcEngineSetEarlyWindowCallback`.
- **Release bundle.** `shell/scripts/release.sh --no-verify` at shell
  `1f752991`, then `4308f9db` (`shell/dist/release-launch{,2}.log`). Signed
  Apple Development. `check-launch` and the real-Keychain self-test were
  skipped (`--no-verify`).
- **Self-test.** `bundle-chromium.sh --selftest --dev-mock-keychain` on the
  dev engine, shell `4308f9db`: **RESULT PASS**, with "PASS early_window
  callback ran once, 970 ms before ready". An earlier run at `1f752991`
  sources also passed (694 ms).
- **Launch bench.** See docs/PERF-BASELINE.md: window visible 1413 → 934 ms
  p50, first usable 1630 → 1581 ms.

## Open

- Chromium's own startup looks about 200–280 ms longer when the window goes
  up early. This is by subtraction: main → ready, minus the callback's time,
  is about 640 ms against perf-5's 355 ms main → ready. Candidates are the
  first SwiftUI frame and WindowServer work competing with Chromium,
  activation before `finishLaunching`, or the bench fixture's worker build.
  It needs an Instruments trace with the `net.rearc.engine` and
  `net.rearc.shell` signposts in a UI session.
- The hook sits at the end of `PreCreateThreads`, about 275 ms after main
  in release. An earlier point (right after `RegisterBrowserCrApp`, before
  Local State) would need an upstream hunk in `chrome_main_delegate.cc`; it
  was left out to keep the patch bridge-only.
- The normal (non-bench) launch path, `ChromiumShellStartup.earlyWindow`,
  has not run in a UI session; the bench's launch child covers the same
  `ChromiumShell` methods.
- The `perf` native host failure above.

LAUNCH engine head=35631c50f563bc20bcd01987ebcf8441d867b21d abi=1.45 replay=pass
