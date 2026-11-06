# Wave perf-0 engine report

Chromium **156.0.8078.74**, upstream pin `d331de35ca8ab1358c7a17e4bd41627d55eaef51`.
Starting overlay HEAD `106077933f` (wave 32, ABI 1.43). Final ABI **1.44**,
bridge **0.46.0**, Configure major **1**. One writer (Claude), no subagents, no
pushes. The shell side (signposts, presentation probe, `--rearc-bench`,
scripts) is committed in the outer repository on `wave-11-chromium-engine`;
nothing under `engine/` was committed there. Plan: docs/PERFORMANCE-PLAN.md
(its §2.3 names this ABI 1.42; 1.42 and 1.43 shipped first, so it is 1.44).
Results and their reading: docs/PERF-BASELINE.md.

## Patch and ABI

| Patch | Commit | ABI / bridge | Feature / new API |
|---|---|---|---|
| `tab/063-host-perf-metrics.patch` | `09332ffebe` | 1.44 / 0.46.0 | `perf_metrics`; `ReArcEngineSetPageTimingCallback`, `ReArcEngineSetViewPresentationCallback`, `ReArcMetricsGetHistogram`, `ReArcEngineGetProcesses` |

Measurement only. With no callback set nothing is attached or observed, and
the normal shell never sets them; only `--rearc-bench` does. Every time is
microseconds on `mach_absolute_time`'s clock (`base::TimeTicks` on macOS), the
clock of `CACurrentMediaTime()` and `NSEvent.timestamp`, so shell and engine
times line up without conversion. Contract: engine/docs/C-ABI.md
"Performance metrics (1.44)".

- **Page timing** (`rearc_perf_metrics.cc`). With the callback set before a
  tab exists, `ABIInitializeTab` attaches
  `page_load_metrics::MetricsWebContentsObserver` with a bridge embedder
  (`PageLoadMetricsEmbedderBase`) that registers Chromium's
  `UmaPageLoadMetricsObserver` and a forwarder. That is not Chrome's full
  set: no UKM, performance_manager or chrome/ observers, which registry tabs
  lack the services for. The forwarder reports, per committed main-frame
  navigation: response start, first paint, FCP, DCL and load event start
  once each, and every new LCP candidate (main frame and subframes merged).
  Because the UMA observer runs, `PageLoad.PaintTiming.*` are recorded as in
  Chrome and can be compared through the histogram reader.
- **View presentation.** Shown: `AttachmentLeaseRegistry::SetViewVisible`
  calls `WebContents::SetTabSwitchStartTime(now, !IsLoading(),
  HasSavedCompositorFrame(), false)` before VISIBLE, as Chrome's tab strip
  does, and a `ScopedHistogramSampleObserver` on
  `Browser.Tabs.TotalSwitchDuration3` (and its Incomplete twin) turns
  Chromium's own measurement into the event (1 ms resolution). Samples carry
  no tab, so each one goes to the pending show whose elapsed time it matches
  best. Resized: after `ResizeView`, a per-tab watcher on the widget's
  `RenderFrameMetadataProvider` takes the first activation whose
  `viewport_size_in_pixels` is the new size, then asks the view's
  `ui::Compositor` for its next successful presentation and forces a frame
  (`ScheduleFullRedraw`; `ScheduleDraw` produced no frame in the first build,
  so the event timed out). These use content/browser internals
  (`RenderWidgetHostImpl`, `RenderFrameMetadataProviderImpl`,
  `RenderWidgetHostViewBase`), all `CONTENT_EXPORT`, so the component build
  links too.
- **Histograms.** `content::FetchHistogramsAsynchronously` (2 s bound), then
  `StatisticsRecorder::FindHistogram` → `SnapshotSamples()`.
- **Processes.** `RenderProcessHost::AllHostsIterator` (profile, extension
  through `ProcessMap`, tabs through each registry tab's frames) and
  `BrowserChildProcessHostIterator`, with `proc_pid_rusage(RUSAGE_INFO_V4)`
  footprint, resident size and CPU (mach ticks converted with the timebase,
  checked against `getrusage`).
- **Signposts** (`rearc_perf.{h,cc}`, subsystem `net.rearc.engine`): `abi`
  intervals on TabCreate, TabClose, TabNavigate, ViewAttach, ViewDetach,
  ViewResize, ViewSetVisible, HistoryQuery, AutocompleteStart and every
  event or completion delivery (`Dispatch`, in `ABI::Drain`); `profile`
  ProfileOpen; `view` TabSwitchPresentation and ResizeToPresentation; `tab`
  events per page milestone. The plan's "each exported entry point" became
  the hot ones: an interval per call on all 121 would be noise, and these
  are the calls the shell makes on the interaction paths.
- **A build failure on the way.** The first version included
  `<os/signpost.h>` from `rearc_perf.h`. It pulls in `mach-o/loader.h`,
  whose `PLATFORM_IOS` macro broke the generated `cast_logs.pb.h` in
  `rearc_search_abi.cc`. The header now exposes only enums and an RAII type,
  and the os_signpost calls live in `rearc_perf.cc`.
- **A use-after-free found by the bench, fixed in the same patch.** The
  first commit (`fd3e2ad797`) crashed at the end of the release bench runs
  (SIGSEGV on `0xefef…`, symbolicated with the release dSYM to
  `ResizeWatcher::~ResizeWatcher`): a WebContents destroys its widget, and
  with it the widget's `RenderFrameMetadataProvider`, before its user data,
  so the watcher's destructor removed itself from a freed provider. The
  watcher now also observes the widget (`RenderWidgetHostObserver`) and lets
  go of both in `RenderWidgetHostDestroyed`, which the widget sends from
  `Destroy()` before its members go. The commit was amended and the patch
  regenerated; later bench runs shut down cleanly.
- **Release linking.** `framework.exports` and `framework.order` list the
  four functions after `_ReArcVideoOverlayReadPixel`: all 121 header
  functions are in both, as tab/060 requires.

## Validation

All runs were sequential, each preceded by `pgrep -fl 'siso[ ]ninja'`
printing nothing, and every native or self-test run held the shared input
lock with the display kept awake (`caffeinate -u`). The screen was locked
throughout.

- **Dev build.** `engine/scripts/build.sh` into `out/ReArc-dev-arm64`:
  `build-perf0-p1.log` failed on the `PLATFORM_IOS` collision above;
  `build-perf0-p2.log` passed; incremental builds followed the
  `ScheduleFullRedraw` and `ResizeWatcher` fixes. Its sources match HEAD
  `09332ffebe`.
- **New native host** `c_abi_perf_host.mm` (`runtime-abi-perf-perf0.log`),
  on a new loopback `/perf` page (text and an inline image), no input:
  - ABI ≥ 1.44 and `perf_metrics`; invalid arguments are rejected
    (`invalid_argument` for null and empty names and callbacks);
  - one navigation reports response start, first paint, FCP, DCL, load and
    LCP (size > 0), all on one navigation start, values never in the future;
  - hide then show: a `shown` event, status 0, Chromium's
    TotalSwitchDuration3 10 ms after the show;
  - resize to 500 × 350 pt: a `resized` event, status 0, 1000 × 700 px,
    activated after 18.6 ms and presented after 44.7 ms in the gate run
    (21.0 / 42.0 ms in the re-run after the fix);
  - histograms: `PageLoad.PaintTiming.NavigationToFirstContentfulPaint` and
    `Browser.Tabs.TotalSwitchDuration3` each with one sample whose buckets
    sum to the count; an unknown name is `not_found`;
  - processes: the browser first with its own pid, the tab's renderer with
    the right profile, footprint and CPU, plus GPU, network and storage
    services.
- **Gates** (on `fd3e2ad797`; after the `ResizeWatcher` fix the perf host,
  replay, imports and exports were re-run and pass, see below).
  `REARC_WAVE_LABEL=perf0 python3 engine/tests/run_perf0_gates.py`
  reported **ALL PERF-0 GATES PASS** (`gates-perf0.log`): **41 native hosts**
  (wave 32's 40 plus `perf`); smoke G1–G5 (`smoke-perf0.log`, 11.0–13.3 s
  each, all no-outside-connect); shutdown stress 4 processes / 16 tabs
  (median 3701.4 ms); pending-prompt stress 4 / 16 (median 395.0 ms);
  named-profile blocked-TCC stress 1 / 4 (758.7 ms). **Network audit:** 51 of
  51 processes looked up outside names and none connected outside
  (`network-audit-perf0.log`). Every run used `--use-mock-keychain` and
  throwaway profiles.
- **Imports.** `check_perf0_imports.py` (`imports-perf0.log`) preserves the
  ABI 1.17, the 39 ABI 1.40, the 42 ABI 1.42 and all **43 ABI 1.43 layouts**,
  and typechecks gated Swift adoption of the 1.44 calls and callbacks plus
  every earlier wave's examples.
- **Exports.** `check_c_abi_exports.py engine/nm-perf0.log`
  (`exports-perf0.log`) resolves **121 symbols** (117 + 4) through the
  framework: `LOADED ABI 1.44 bridge 0.46.0 Chromium 156.0.8078.74 PASS`
  (re-run on `09332ffebe`).
- **Replay.** `replay_overlay.py` (`replay-perf0.log`, re-run on the amended
  commit): **REPLAY PASS 64/64 reverse and forward**. The forward tree
  `70e9954867` matches HEAD `09332ffebe`, and the reverse tree matches the pin.
- **Release engine.** `shell/scripts/build-engine-release.sh`, incremental in
  `out/ReArc-release-arm64` from the tab/060 build: first to `fd3e2ad797`
  (tab/061, tab/062, tab/063; `build-release-perf0.log`), then to
  `09332ffebe` after the fix (115 s, `build-release-perf0b.log`). Both times
  the script's export check (every header function in `nm -gU` of the
  monolithic framework) passed. Nothing else heavy ran during them.
- **Release bundle.** `shell/scripts/release.sh` into `shell/dist/release`
  (`shell/dist/release-perf0.log`), last at shell `2eebe734` on engine
  `09332ffebe`: signed (Apple Development), `check-launch` PASS plain and
  with a link (`abi_minor=44`), real-Keychain self-test **RESULT PASS** in
  102 s. The bench baseline was measured on this bundle.

The ABI 1.17 compatibility run (`run_compat_w18h.py`) was not repeated: no
pre-1.44 struct or function changed, and the import check covers the layouts.

## What was not done

- Not every exported entry point has an `abi` interval (see above).
- No `c_abi_perf_host` step for the incomplete (hidden-before-presented) or
  superseded-resize statuses; they are exercised only by the bench.
- The plan's R1 reference (stock Chromium with the same release args) was not
  built: it costs about 3.5 h. R2 (installed Google Chrome) is used instead;
  see docs/PERF-BASELINE.md.
- page_load_metrics stays off for normal use: attaching it always (with
  `LoadingPredictorTabHelper`, H11) is perf-5's parity work.

PERF-0 engine head=09332ffebeb20f9a6899b0251881270b1228be85 abi=1.44 replay=pass
