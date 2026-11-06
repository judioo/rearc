# Wave 32 implementation report

Chromium **156.0.8078.74**, upstream pin `d331de35ca8ab1358c7a17e4bd41627d55eaef51`.
Starting overlay HEAD `768b683832` (wave 30, ABI 1.42). Final ABI **1.43**,
bridge **0.45.0**, Configure major **1**. One writer (Claude), no subagents, no
pushes. The shell work is committed in the outer repository on branch
`wave-11-chromium-engine`; nothing under `engine/` was committed there.

## Patch and ABI

| Patch | Commit | ABI / bridge | Feature / new API |
|---|---|---|---|
| `tab/062-embedded-video-overlay.patch` | `106077933f` | 1.43 / 0.45.0 | `pip_embedded`; `ReArcTabGetMediaActions`, `ReArcEngineSetVideoOverlayCallback`, `ReArcVideoOverlayAction`, `ReArcVideoOverlaySeek`, `ReArcVideoOverlaySetBounds`, `ReArcVideoOverlayReadPixel` |

This is MINI-PLAYER.md's option (b), Arc's own design: Chromium creates the
PiP controller and the video surface as usual, and the bridge supplies the
`content::VideoOverlayWindow`, which is a view rather than a window.

- **Routing.** `ChromeContentBrowserClient::CreateWindowForVideoPictureInPicture`
  asks `rearc::CreateHostVideoOverlay(controller)` first. It returns a
  `HostVideoOverlay` only when a video overlay callback is set and the
  controller's WebContents entered PiP through the bridge (tab/048's `State`
  holds its IDs, through the new `HostPictureInPictureIds`). Otherwise
  Chromium's `VideoOverlayWindowViews` is used, unchanged (the `pip` native
  host still passes against it).
- **Rendering** (`chrome/browser/rearc_bridge/rearc_video_overlay.mm`,
  modelled on `content/browser/renderer_host/unbounded_surface_window_mac.mm`).
  A layer-hosting `ReArcVideoOverlayView` (flipped, `hitTest:` nil, so the
  host's views take clicks) owns a `ui::DisplayCALayerTree`. A
  `ui::RecyclableCompositorMac` from `content::GetContextFactory()` draws a
  black `LayerSolidColor` root with one `LayerSurface`. `SetSurfaceId` does
  `AddChildFrameSink` plus `SetShowSurface(stretch)` in an aspect-fit rect, as
  `VideoOverlayWindowViews::SetSurfaceId` does. Size, scale, display ID,
  colour spaces and refresh rate are re-read on every view move, resize,
  hide, occlusion, screen and backing change. The compositor is suspended
  unless a session is shown and the view is in a window, unhidden and
  non-empty.
- **Window semantics in the host.** `ShowInactive`/`Hide`/`Close` post
  shown/hidden. Destroying the overlay with its controller posts closed.
  `GetBounds` returns the host-reported screen rect (`SetBounds`), which
  `UpdateLayerBounds` uses to size the renderer's PiP video. Playback,
  buttons, mute, microphone and camera collapse into one state event per task,
  deduplicated. Position, natural size and source title have their own
  events.
- **Actions** go to the controller, and closes go through
  `PictureInPictureWindowManager::ExitPictureInPictureViaWindowUi` as
  Chromium's own buttons do. Back to tab produces tab/048's phase-2 event.
- **Media actions.** `MediaAdapter` publishes a media event whenever the
  session's action bits change, and `ReArcTabGetMediaActions` reads them. The
  shell's strip uses them to dim previous and next.
- **Release linking.** `framework.exports` and `framework.order` list the six
  new functions after `_ReArcEngineSetKeyEquivalentCallback`. All 117 header
  functions are listed in both files, as tab/060 requires.

Full contract: engine/docs/C-ABI.md "Embedded video Picture in Picture and
media actions (1.43)".

**A dead end, recorded in C-ABI.md.** The first version counted compositor
frames in `AcceleratedWidgetCALayerParamsUpdated`. In the shell self-test that
count stayed at 1 while the page's `requestVideoFrameCallback` advanced at
20 fps. The cause is that viz forwards CALayer params only when they change
(`root_compositor_frame_sink_impl.cc:937`): the display redraws into the same
remote CAContext. The counter was replaced before commit with
`ReArcVideoOverlayReadPixel`. It is a `viz::CopyOutputRequest` read-back of the
overlay's composited root, so it works with the screen locked.

A second fix before commit: the first build also required `[window
isVisible]`. A host can order its window in after parenting the view, and no
view notification reports that, so the overlay never drew in the native host.
Hosts take the view out of windows they hide instead.

## Shell adoption

Gate on minor >= 43 and `pip_embedded`, which also needs
`picture_in_picture`. Register `ReArcEngineSetVideoOverlayCallback` next to the
PiP callback, before any tab. Take the `created` view with a retained
transfer, parent it, and report its screen rect with `SetBounds`. Read
`ReArcTabGetMediaActions` on each media event. Shell details are in
shell/README.md "ABI 1.43 adoption (wave 32)": Arc's strip, Video in Sidebar
(on by default) and Arc-mode PiP with minimize into the strip.

## Validation

All runs were sequential, each preceded by `pgrep -fl 'siso[ ]ninja'`
printing nothing. Builds `build-w32-p1` (first version), `p2` (ReadPixel) and
`p3` (draw without window visibility) all exited 0 in
`out/ReArc-dev-arm64`. Its sources match HEAD `106077933f`; the commit
followed p3. `out/ReArc-release-arm64` was not touched.

- **Gates.** `REARC_WAVE_LABEL=w32 python3 engine/tests/run_w32_gates.py`
  reports **ALL WAVE 32 GATES PASS** (`gates-w32.log`): **40 native hosts / 50
  process runs** (wave 18h's 39 plus `pip_embedded`); smoke G1–G5
  (`smoke-w32.log`, 10.7–13.2 s each, all no-outside-connect); shutdown stress
  4 processes / 16 tabs (median 2925.6 ms); pending-prompt stress 4 / 16
  (median 252.5 ms); named-profile blocked-TCC stress 1 / 4 (804.2 ms) with the
  `TEST TCC preflight blocked` marker. **Network audit:** 50 of 50 processes
  looked up outside names and none connected outside
  (`network-audit-w32.log`). Every run used `--use-mock-keychain` and
  throwaway profiles.
- **New native host** `c_abi_pip_embedded_host.mm`
  (`runtime-abi-pip_embedded-w32.log`), with no synthesized input:
  - Unknown tab gives `tab_not_found`, null output `invalid_argument`. The
    recorded WebM's actions include Picture in Picture and pause but no
    tracks.
  - Host entry gives created (+1 view) then shown. Bounds validation:
    invalid, `not_found`, OK. An unknown action is `invalid_argument`.
  - With the tab's own view hidden, four read-backs of the overlay's
    composited centre pixel 0.5 s apart were all video colours and all
    different (`181ADCFF, D1355FFF, 99E34AFF, 5CC1E1FF` in the standalone run).
  - Pause and play through overlay actions (state events 1 then 0).
  - Back to tab gives hidden, PiP phase 1, then phase 2. An action while hidden
    is `invalid_state`. Re-entering reuses the same overlay ID.
  - Tab close gives hidden then closed; after closed, actions are
    `not_found`. Then orderly shutdown.
  - The first gate run exposed a race in the host's own sequencing:
    `pip_available` can arrive before the `toFile()` result. The host now
    enters on whichever comes second (three standalone passes, then the full
    gate run). No engine change.
- **Imports.** `check_w32_imports.py` (`imports-w32.log`) preserves the ABI 1.17
  layouts, the 39 ABI 1.40 layouts and all **42 ABI 1.42 layouts**
  (ReArcServiceEvent included, so no earlier struct changed). It typechecks
  gated Swift adoption of the 1.43 calls and callback, plus every earlier
  wave's examples.
- **Exports.** `check_c_abi_exports.py engine/nm-w32.log` (`exports-w32.log`)
  resolves **117 symbols** (110 + 1 from tab/061 + 6) through the framework.
  It reports `LOADED ABI 1.43 bridge 0.45.0 Chromium 156.0.8078.74 PASS`.
- **Compatibility.** `run_compat_w18h.py` (`compat-w32.log`) compiles the
  unmodified core, downloads, shutdown and shutdown-veto hosts against the
  exact ABI 1.17 headers: **ABI 1.17 HEADER RUNTIME PASS: 4 hosts / 6 process
  runs**, none connected outside.
- **Replay.** `replay_overlay.py` (`replay-w32.log`): **REPLAY PASS 63/63
  reverse and forward**. The forward tree `3163e72e2c` matches HEAD
  `106077933f`, and the reverse tree matches the pin.

Shell evidence (outer repository):

- `swift test`: 708 XCTest cases, zero failures (`shell/swift-test.log`).
- `scripts/bundle-chromium.sh --dev-mock-keychain --selftest` reaches
  `RESULT PASS` (`shell/selftest-chromium-mockkeychain.log:3348`), and so does
  `scripts/bundle-chromium.sh --selftest` (`shell/selftest-chromium.log:3250`).
  Each ran under the shared input lock.
- In both, `PASS live video and media strip (ABI 1.43)` (:2450 and :2452)
  covers:
  - the strip and a 212×119 sidebar video after switching away from a looping
    video;
  - the hidden tab at 19.9–20.0 fps (`requestVideoFrameCallback`), with four
    read-back pixels of the view all different;
  - pause and play through the strip, which keeps the strip;
  - pop-out, minimize, Open Picture in Picture and dock, all on the same
    overlay ID with no hidden or closed event;
  - tab close removing the video and the strip.
- The wave 24 PiP step now asserts the embedded overlay, and Chromium's
  window does not open.

The screen was locked throughout, so the input-based steps of other checks
logged NOTEs as in earlier waves. The new checks need no input.

## What was not done

- WebKit has no embeddable PiP surface: it gets the strip, and system PiP
  stays as it was.
- Not implemented:
  - per-tab volume (`MediaSessionImpl` multiplier);
  - camera and microphone strip controls for capture tabs;
  - the source-rect morph (`GetSourceBounds`);
  - drag-to-dock;
  - Arc's PiP chrome extras (±15 s, Keep Window on Top, Open automatically).
- Arc's strip and stack timings remain unobserved; ReArc's values come from
  MINI-PLAYER.md §3.5.
- Document PiP is still unsupported.

WAVE 32 engine head=106077933fdbfbc712135e6df3d27c3db3735aed abi=1.43 replay=pass
