# Chromium bootstrap status — 2026-11-01

The shallow Chromium **156.0.8078.74** sync and hooks have completed. A detached
first dev component build is running; see **BUILD-STATUS** below for live IDs,
logs, early progress, repairs and monitor/resume commands. Build completion
and runtime behavior are not yet verified. P-APP-001 remains an implementation specification;
the patch series is empty, so the first build will be stock Chromium.

## Initial download (historical launch evidence)

- Fetch PID: **4627** (`/bin/bash engine/scripts/fetch.sh`).
- Initial detached supervisor: PID **4626**, launchd label
  `com.rearc.chromium-fetch`. Later inspection found **KeepAlive enabled**
  by `launchctl submit`; this was not a one-shot job (see BUILD-STATUS).
- Log: `/Users/uo/Projects/Imara/Code/Playground/t3code/.t3/projects/rearc/engine/fetch.log`.
- PID file: `engine/fetch.pid`.
- Start: **2026-11-01 10:46:42 UTC** (14:46:42 Asia/Dubai).
- At **10:49:00 UTC**, the fetch was alive after **2 minutes 18 seconds**;
  Git reported **13% (69,202/514,440) source objects, 70.17 MiB received**.
  No immediate errors appeared in this successful launch's log.

The script explicitly fetches the tag with `git fetch --progress --no-tags
--depth=1`, checks it out detached, then runs:

```sh
gclient sync --nohooks --no-history --revision "src@$REVISION" --jobs=8
```

`REVISION` is the fetched tag's commit. The audit resolved the tag to
`d331de35ca8ab1358c7a17e4bd41627d55eaef51`; the local fetch has not yet
finished resolving/checking out that commit. `.gclient` selects only macOS,
sets `managed=False`, and disables optional PGO profile downloads. Source
history is depth one; dependency history is reduced with `--no-history`.
There are no reset/force/delete-unversioned flags and no branch reset.

`engine/chromium/.rearc-sync-complete` is written only after successful sync
and source-HEAD verification. Hooks, overlay application and build are separate
explicit stages. Existing work at a different HEAD/pin is refused, not rebased.

## Exact install and launch commands

Working directory:

```sh
cd /Users/uo/Projects/Imara/Code/Playground/t3code/.t3/projects/rearc
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git engine/depot_tools
```

Installed depot_tools revision:
`a20039648c0de69d8156906b18052bd47e9bf230`.
The scripts set `DEPOT_TOOLS_UPDATE=0` and log this revision; future installations
must deliberately select the same revision for reproduction. The downloaded
compiler/dependency revisions come from Chromium's pinned DEPS and hooks.

Ordinary `nohup ... &` launches from this command runner did not survive its
process cleanup. A separate-session/double-fork attempt also ended early.
Those fetch PIDs are dead; the resulting stale `src/.git/shallow.lock` was
removed only after checking that no Git process held it. The successful launch
uses launchd to own the shell independently of the command runner. The exact
submitted command and arguments were equivalent to:

```sh
launchctl submit -l com.rearc.chromium-fetch -- /bin/bash -c 'cd /Users/uo/Projects/Imara/Code/Playground/t3code/.t3/projects/rearc
nohup /bin/bash /Users/uo/Projects/Imara/Code/Playground/t3code/.t3/projects/rearc/engine/scripts/fetch.sh > /Users/uo/Projects/Imara/Code/Playground/t3code/.t3/projects/rearc/engine/fetch.log 2>&1 < /dev/null &
FETCH_PID=$!
printf "%s\n" "$FETCH_PID" > /Users/uo/Projects/Imara/Code/Playground/t3code/.t3/projects/rearc/engine/fetch.pid
wait "$FETCH_PID"'
```

This was invoked with Python `subprocess.run([...])` to preserve argument
boundaries. It executes the requested `nohup` background command; the supervisor
waits for its exit. It survives this agent session, but is not a reboot-resume
service. **Correction:** `launchctl submit` enables KeepAlive on this machine;
its restart can overwrite the log because this original command uses `>`.
Use explicit `KeepAlive=false` launchd plists for new stage launches instead.
Keep the Mac awake/on power for the download.

## Monitor and resume

From the project root:

```sh
ps -p "$(cat engine/fetch.pid)" -o pid,ppid,etime,stat,command
tail -f engine/fetch.log
# Git progress uses carriage returns; this gives a readable snapshot:
tr '\r' '\n' < engine/fetch.log | tail -20
launchctl list com.rearc.chromium-fetch
test -f engine/chromium/.rearc-sync-complete && cat engine/chromium/.rearc-sync-complete
```

`gclient sync` is resumable. After an interruption, ensure the previous PID and
its Git/gclient children have exited, then rerun `engine/scripts/fetch.sh`.
It reuses the initial source repository and already downloaded dependencies.
An interrupted initial Git transfer may re-download its unfinished pack.

If the script reports `.rearc-fetch.lock`, inspect its `pid` and confirm the
process is dead before removing that stale lock directory. Never remove Git
lock files while a Git process still owns them. Partial overlay application
needs manual resolution; do not sync over it.

To resume detached from a normal interactive terminal, preserving the log:

```sh
nohup /bin/bash engine/scripts/fetch.sh >> engine/fetch.log 2>&1 < /dev/null &
printf '%s\n' "$!" > engine/fetch.pid
```

Do not reuse the historical `launchctl submit` command for new agent-runner
launches: it enabled KeepAlive and restarted the failed sync, overwriting its
log. Use a launchd plist with `RunAtLoad=true`, `KeepAlive=false`, and append
logging; BUILD-STATUS records the working hooks/build pattern. Only remove
a registered job after its child exits. Never run concurrent syncs.

## Machine, prerequisites and capacity

Observed macOS 27.2, arm64, APFS, **1.6 TiB free**. Full Xcode is selected at
`/Applications/Xcode.app/Contents/Developer`; Xcode is **27.2 (27B52)** with
macOS SDK **27.2**. Apple Git **2.54.0**, Python **3.15.0**, curl and depot_tools
are installed. depot_tools' gclient/vpython bootstrap completed and its CLI
responded. No public-source credentials were requested.

`xcodebuild -license check` returned **0**. The explicit first-launch check
returned **69**, so `xcodebuild -runFirstLaunch` was started to install required
components. It exited **0**, reported **Install Succeeded**, and a new
`xcodebuild -checkFirstLaunchStatus` returned **0** at 10:49 UTC.
No human agreement, admin password or source credential is currently blocked.
Full first-launch setup is
required before hooks/build, but is not a prerequisite for source-only sync.
The scripts unset `FORCE_MAC_TOOLCHAIN` and use system Xcode; no Google internal
Xcode credentials are intended or needed on this non-corporate Mac.

Budget **tens of GB of download**, roughly **50–100+ GB** for source/dependencies
and tools, and **100–300+ GB total** after a first component build, with more
space for additional configurations/symbols. These are planning allowances,
not measured output sizes for this pin. At least several hours is reasonable
for sync on this connection; it may take much longer. First local compilation
can also take hours. Available disk is ample for that allowance.

## After sync completes

From the project root, in this order:

```sh
engine/scripts/fetch.sh --runhooks
engine/scripts/fetch.sh --apply-overlay
# Absolute path is required by this depot_tools bootstrap implementation.
export PATH="$PWD/engine/depot_tools:$PATH"
DEPOT_TOOLS_UPDATE=0 "$PWD/engine/depot_tools/ensure_bootstrap"
engine/scripts/build.sh
```

`--runhooks` downloads/generates public build prerequisites. A matching hooks
completion marker is required before overlay/build. `--apply-overlay` checks
for collisions, stages only additive paths and `git apply --3way --index`
changes, then commits them if present. It does not create the missing bridge.

Default build arguments are macOS/host arm64, `is_debug=true`,
`is_component_build=true`, `is_chrome_branded=false`, `is_official_build=false`,
`use_system_xcode=true`, `use_remoteexec=false`, `use_siso=true`,
`chrome_pgo_phase=0`, `symbol_level=1`, `treat_warnings_as_errors=false`.
Debug DCHECK defaults are retained. `gn gen --fail-on-unused-args` rejects
undeclared args, then `autoninja` requests **chrome_framework and chrome**.
`--jobs=N` can cap local build parallelism. `--release` is optimized,
non-component, non-official development compilation; it does not imply signing,
notarization, release exports or shipping acceptance.

Expected output is `engine/chromium/src/out/ReArc-dev-arm64/`, including
`Chromium.app` and `Chromium Framework.framework/Versions/156.0.8078.74/`.
The framework owns all eight generated helper targets: default, renderer, gpu,
alerts, aperitif, aperitif_renderer, aperitif_gpu, aperitif_alerts. Their names
are `Chromium Helper`, `(Renderer)`, `(GPU)`, `(Alerts)`, `(Aperitif)`,
`(Aperitif Renderer)`, `(Aperitif GPU)`, `(Aperitif Alerts)` respectively,
with `.app` suffixes. The Helpers directory also receives the Crashpad handler,
app-mode loader and web-app shortcut copier. Component dylibs also live at the
output root. Keep the whole output directory and upstream layout for this spike;
no copy/rename into ReArcCore and no standalone framework packaging is attempted.

## Verified source rules and remaining assumptions

Inspected the exact tag's [chrome/BUILD.gn][build], [mac_helpers.gni][helpers],
[mac_sdk.gni][sdk], [Siso args][siso], [DEPS][deps], [mac build guide][guide]
and [Xcode selection helper][xcode]. In this source:

- `chrome_helper_app` is a template, not a Ninja target. `chrome_framework`
  includes the generated helper bundle dependencies. There is no Plugin helper.
- Framework version is the full Chromium version, not `A`; helpers differ in
  linkage/capabilities, and GPU/default do not have unique ID suffixes.
- Alerts is an on-demand notification helper, not a permanently running
  browser child. Build targets say nothing about fixed process counts.
- The SDK minimum is 15; the official SDK is 26.5. Installed 27.2 is newer.
  Local public system-Xcode compilation is the intended first attempt, not an
  assertion that the newer SDK compiles this entire pin successfully.

At initial download launch, the following items remained unverified.
BUILD-STATUS records the checks completed since then; packaging/runtime gates
remain open:

1. Confirm fetched tag commit/VERSION and every dependency/tool package is
   available and syncs successfully with no history. Particular dependencies
   may require a deeper fetch; do not silently turn this into full-history sync.
2. Complete hooks, then validate GN args/target graph on this machine. Source
   inspection confirms definitions, not generation/link success. Local Siso,
   bundled LLVM and the installed SDK combination have not compiled this pin.
3. Confirm generated bundle paths, resources, runtime dependency closure and
   helper signing/entitlements; source rules alone are not runtime validation.
4. Implement P-APP-001 and the remaining bridge/service overlays, including
   release symbol exports, before shell integration can work. No browser-process
   embedding, native event-loop integration, sandbox startup, renderer/GPU
   launch, Crashpad operation, or shutdown has been tested by this bootstrap.
5. Validate x64 cross builds and optimized non-component builds separately.
   Signing identity, Apple developer-account access and notarization are later
   distribution work, not fetch requirements.

Initial checks, before the implementation session: Bash syntax for both scripts; invalid CLI arguments refused;
fixture checks reject clean tracked/unowned overlay collisions, preserve unrelated
untracked files, stage only overlay files, and refuse to reset applied commits.
Mocked build-command checks also passed under macOS Bash 3.2 for default
component and optimized configurations, arm64 args, target selection and
`--jobs`. No Chromium compilation or runtime test had been run at that point.

## BUILD-STATUS — first dev component build

All times below are **2026-11-01 UTC**. Current detached build:

- Build PID **50586**, launchd supervisor **50583**, started **13:00:42**.
- Log: `/Users/uo/Projects/Imara/Code/Playground/t3code/.t3/projects/rearc/engine/build.log`.
- PID file: `engine/build.pid`; exit status: `engine/build.exit` (written only
  when the supervisor's child exits; absent while this attempt runs).
- Output: `engine/chromium/src/out/ReArc-dev-arm64/`.
- At **13:11:00**, PID 50586 was alive after **10 minutes 18 seconds**.
  The current attempt generated **36,187 targets from 5,026 files** in
  **5,255 ms**, then reached Siso step **7,954 / 80,878**. The latest completed
  compile was `obj/net/net/sql_shared_cache_index_database.o`; C/C++/Objective-C++
  and archive steps have completed. ANGLE's Metal shader action passed and
  generated a 150,720-byte `.air` output. This attempt contains **0 `FAILED:`**
  and **0 `Build Failure:`** markers; `build.exit` is absent. The total step
  count changes as Siso resolves the graph, so this is progress evidence,
  not a completion estimate. Build/link/runtime completion is not yet verified.

### Fetch, integrity, hooks and overlay outcome

The initial fetch PID 4627's sync exited **1** by **12:32:49**. The inherited
`launchctl submit` job had **KeepAlive enabled**, despite the initial notes:
`launchctl print` showed `runs = 2`, `last exit code = 1` and
`properties = keepalive`. Its automatic restart overwrote the original log;
the final original error is unavailable. Earlier samples recorded individual
Git fetch retry warnings. This automatic restart was the **single resume
attempt**; no further gclient sync was started in this session.

Resume PID **28103** (gclient 28168), started **12:32:49**, reused the checkout
and dependencies and completed sync at **12:38:27**. Its marker matches the
pin. Around **12:35**, only waiting supervisor PID 28102 was suspended with
`kill -STOP 28102` to prevent a third run/log overwrite; fetch/gclient kept
running. After the child completed, `launchctl remove com.rearc.chromium-fetch`
removed that stopped supervisor. No fetch job remains registered.

Verified locally:

```text
git -C engine/chromium/src describe --tags: 156.0.8078.74
HEAD / sync marker / hooks marker: d331de35ca8ab1358c7a17e4bd41627d55eaef51
chrome/VERSION: 156.0.8078.74
Source history: shallow
GN: 2578 (510ec7992c30); Ninja: 1.12.1; Siso: v1.6.3
Xcode: 27.2 (27B52); macOS SDK: 27.2; first-launch check: exit 0
```

`engine/scripts/fetch.sh --runhooks` completed with **exit 0 at 12:45:30**.
After the LiteRT repair below, it ran again and completed with **exit 0 at
12:54:20**. Logs: `engine/hooks.log`, `engine/hooks.exit`. System Xcode was
selected; no license/admin/credential input was required.

`engine/scripts/fetch.sh --apply-overlay` applied **0 patches** at 12:46:21,
and again after the hook refresh. `engine/patches/series` contains comments
only; no additive overlay exists. A synthetic additive patch passed
`git -C engine/chromium/src apply --check --index -`; its probe file was never
created, and source/index remained clean. Evidence: `engine/overlay.log`.
This validates the dry-run plumbing, not a real ReArc patch or three-way rebase.
P-APP-001 and the embedding ABI remain unimplemented; this is stock Chromium.

### Repairs before the current build

1. The **12:46:32** build exited 1 before GN because depot_tools' wrapper lacked
   `python3_bin_reldir.txt`. gclient's vpython bootstrap alone did not initialize
   the separate gn/autoninja Python shim. The following completed successfully
   and installed pinned Python **3.11.8**, without changing depot_tools HEAD:

   ```sh
   export PATH="$PWD/engine/depot_tools:$PATH"
   DEPOT_TOOLS_UPDATE=0 "$PWD/engine/depot_tools/ensure_bootstrap" >> engine/bootstrap.log 2>&1
   engine/depot_tools/python-bin/python3 --version
   ```

   A relative-path invocation of `ensure_bootstrap` failed because it changes
   directories internally; use the absolute path. This script can exit 0 despite
   bootstrap errors, so also verify the shim above. depot_tools remains at
   `a20039648c0de69d8156906b18052bd47e9bf230` with no tracked changes.

2. The **12:48:22** attempt passed GN but exited 1 during scheduling, before
   compilation: LiteRT's `tflite/converter/schema/schema.fbs` was missing.
   A full audit of **150 Git dependencies** from `.gclient_entries` found one
   mismatch: LiteRT had the pinned commit downloaded but an unborn HEAD,
   absent index and **6,402 missing files**. Checkout reproduced
   `git-lfs filter-process: git-lfs: command not found`.

   All existing files were compared against commit
   `4dac1538b76bc20bb7f2ba314bcc89dc57c0ee2b` using a temporary index; only missing
   files were found, with no modified files or untracked extras. Only this
   repository's `.git/config` was given these overrides:

   ```sh
   git -C engine/chromium/src/third_party/litert/src config --local filter.lfs.required false
   git -C engine/chromium/src/third_party/litert/src config --local filter.lfs.process ''
   git -C engine/chromium/src/third_party/litert/src config --local filter.lfs.smudge ''
   git -C engine/chromium/src/third_party/litert/src config --local filter.lfs.clean ''
   ```

   `git read-tree` into a temporary index and `git checkout-index -z --stdin`
   restored the verified missing paths only. The verified index was installed,
   then `git update-ref --no-deref HEAD 4dac1538b76bc20bb7f2ba314bcc89dc57c0ee2b`
   established the detached pin. No existing source was overwritten, no files
   were deleted, no new download/sync was needed, and LiteRT is now clean.
   A repeat audit found **150/150 matching pins**. Evidence:
   `engine/dependency-repair.log`. Hooks were refreshed afterward.

   LiteRT prebuilt library files remain Git LFS **pointers**, not downloaded
   libraries. This pin's Chromium `third_party/litert/BUILD.gn` builds source
   and has no prebuilt-library references; the current build is testing that
   assumption. Workflows consuming those separate prebuilts need Git LFS setup.

3. The **12:55:12** attempt completed **1,141 steps** before exiting 1 at
   **12:56:41**. ANGLE's Metal shader action reported that `metal` could not
   execute because the optional **Metal Toolchain** was missing, despite the
   Xcode first-launch check passing. This command completed with exit 0:

   ```sh
   xcodebuild -downloadComponent MetalToolchain > engine/metal-toolchain.log 2>&1
   xcrun metal --version
   ```

   It installed **Metal Toolchain 27B47** (838.9 MB download); `metal` reports
   **32023.922 (metalfe-32023.922.4)**, target `air64-apple-darwin27.2.0`.
   No human input was required. The current build reuses completed outputs.

### Exact build and detached supervision

From the project root, the build command is:

```sh
engine/scripts/build.sh --jobs=8
```

It generates `out/ReArc-dev-arm64` with `--fail-on-unused-args` and these args:

```gn
target_os="mac" target_cpu="arm64"
is_chrome_branded=false is_official_build=false
use_system_xcode=true use_remoteexec=false use_siso=true
chrome_pgo_phase=0 symbol_level=1 treat_warnings_as_errors=false
is_debug=true is_component_build=true
```

Then `autoninja -j 8 -C out/ReArc-dev-arm64 chrome_framework chrome` compiles
locally through Siso. `chrome_framework` owns the helper dependencies; no
invalid `chrome_helper_app` target is requested. The full output directory
is retained, including component dylibs outside the framework.

Saved local definitions: `engine/hooks.launchd.plist` and
`engine/build.launchd.plist` (ignored runtime files). Both explicitly set
`RunAtLoad=true`, `KeepAlive=false`. The build plist's `/bin/bash -c` supervisor
changes to this project root, then executes the equivalent of:

```sh
printf '\n=== %s | detached dev build --jobs=8 ===\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> engine/build.log
nohup /bin/bash "$PWD/engine/scripts/build.sh" --jobs=8 >> engine/build.log 2>&1 < /dev/null &
BUILD_PID=$!
printf '%s\n' "$BUILD_PID" > engine/build.pid
wait "$BUILD_PID"
BUILD_STATUS=$?
printf '%s\n' "$BUILD_STATUS" > engine/build.exit
printf '\n=== %s | build exit %s ===\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$BUILD_STATUS" >> engine/build.log
exit "$BUILD_STATUS"
```

The actual plist contains absolute paths. Submission (also used for the current
relaunch, after removing the completed previous job) is:

```sh
launchctl bootstrap "gui/$(id -u)" "$PWD/engine/build.launchd.plist"
```

The one-shot supervisor survives command-runner cleanup, appends logs across
attempts, writes the child's exit status and does not automatically restart.
It is not a reboot-resume service. No compiler/build script or Chromium source
patch was needed for these machine/checkout repairs.

### Monitor and resume

From this project root:

```sh
ps -p "$(cat engine/build.pid)" -o pid,ppid,etime,stat,command
tail -f engine/build.log
# Readable snapshot of carriage-return progress:
tr '\r' '\n' < engine/build.log | tail -30
launchctl print "gui/$(id -u)/com.rearc.chromium-build"
# Absent until this attempt exits; 0 means successful build-script completion.
test ! -f engine/build.exit || cat engine/build.exit
```

**Only after confirming the build PID and its compiler/Siso children have
exited**, inspect/fix the final error. Resume incrementally without refetching,
reapplying overlays or deleting output:

```sh
launchctl bootout "gui/$(id -u)/com.rearc.chromium-build"
rm -f engine/build.exit
launchctl bootstrap "gui/$(id -u)" "$PWD/engine/build.launchd.plist"
```

This reuses the saved `nohup ... >> engine/build.log` supervisor and updates
`build.pid`. From an ordinary terminal, an alternative is
`engine/scripts/build.sh --jobs=8` in the foreground, or `nohup` with append
logging; don't run it alongside the active build. Keep the Mac awake/on power.

### Remaining assumptions and unverified acceptance

- **No current blocker** after the repairs above; the detached build is still
  running. Do not wait for or claim final compilation/link completion from
  this early observation alone.
- GN accepts the requested args and system SDK, and compilation has started.
  Full SDK 27.2 compatibility, framework/helper links and final build success
  remain unverified until compilation completes. Eight local jobs cap load on
  this 10-core/64 GiB Mac; the full build may take hours.
- Complete bundles/resources, component runtime dependency closure, helper
  signing/entitlements, browser launch and shutdown have not been verified.
- No ReArc bridge/lifecycle implementation, branding, shell integration,
  optimized/non-component build, x64 build or distribution acceptance is implied.
- The original sync's final error was lost by its inherited KeepAlive restart.
  The later LiteRT checkout issue is diagnosed; it cannot be proved to be the
  sole cause of that original exit from the overwritten log.

[build]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/chrome/BUILD.gn
[helpers]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/content/public/app/mac_helpers.gni
[sdk]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/build/config/mac/mac_sdk.gni
[siso]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/build/toolchain/siso.gni
[deps]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/DEPS
[guide]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/docs/mac_build_instructions.md
[xcode]: https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.74/build/mac/should_use_hermetic_xcode.py

## PATCH-LOG — first real patches (2026-11-01, all times UTC)

Overlay commit `a646aadea9` ("rearc overlay @ 156.0.8078.74", author
ReArc Overlay) was created by the scripted `fetch.sh --apply-overlay` flow for
patch 001. Patch 002 was committed on top as `e8a1859972` via manual
`git apply --3way --index` + commit, because `--apply-overlay` deliberately
refuses to run once HEAD differs from the synced base (fetch.sh:88) — the
scripted one-shot flow covers a full series application, not per-patch
incremental commits. Note: two implementation sessions worked the same
checkout concurrently this wave; the state below is the converged result,
and the first build-p1 attempt interleaved with the other session's build
(kept for reference as `engine/build-p1.concurrent-interleave.log`); the
authoritative build-p1 result comes from the rerun after that race.

### chrome/001-rearc-about-branding.patch — P-BUILD-001 (warm-up)

- Content: UA product token `"Chrome/" → "ReArc/"` in
  `components/version_info/version_info_with_user_agent.cc` (both full and
  reduced forms), plus UA-CH brand list `"Chromium" → "ReArc"` in
  `components/embedder_support/user_agent_utils.cc`.
- Applied: cleanly via `git apply --3way --index` (`apply --check` clean
  first; no fuzz, no rejects).
- Build: incremental `build.sh --jobs=8` → **exit 0**, 0 `FAILED:` markers
  (`engine/build-p1.log`, `engine/build-p1.exit`).
- Validation: literal `ReArc/` present in
  `out/ReArc-dev-arm64/libchrome_dll.dylib` and in the compiled
  `version_info_with_user_agent.o`; `Chromium --version` →
  `Chromium 156.0.8078.74`, exit 0 (pre-existing component-build ObjC
  duplicate-class warnings unrelated).

### app/002-app-host-runloop.patch — P-APP-001 slice 1

- Content: additive `chrome/browser/rearc_bridge/` source set
  (`ReArcApplication : BrowserCrApplication` with host-routed
  `terminate:`/`cancelTerminate:`, `EngineLifecycleHost` interface,
  `ReArcAppDelegate` scaffolding, exported C ABI
  `ReArcEngineBridgeVersion`/`ReArcEngineSetLifecycleCallbacks`), plus
  upstream hunks in `chrome/browser/chrome_browser_application_mac.mm`
  (singleton now `ReArcApplication`), `chrome/browser/BUILD.gn`
  (`rearc_bridge` dep), `chrome/app/framework.exports` (the two C ABI
  symbols) and `chrome/browser/ui/webui/version/version_ui.cc`
  (about:version shows `ReArc <version>`).
- Applied: cleanly via `git apply --3way --index` on top of the overlay
  commit; new files took the documented 3-way→direct fallback. On-disk patch
  verified identical to the tree via `git apply --check -R`.
- Build: gate history across `engine/build-p1.log` (bridge code was already
  in the tree during the later p1 attempts) and `engine/build-p2.log`:
  1. **exit 1** — `rearc_engine_entry_mac.mm`: `[chromium-rawptr]` plugin
     error, raw `void*` member. Fixed: `raw_ptr<void>`.
  2. exit 0 but bridge C ABI symbols hidden (`-fvisibility=hidden` tree
     default). Fixed: `REARC_ENGINE_EXPORT
     __attribute__((visibility("default")))`, ChromeMain's convention.
  3. **exit 0**, 0 `FAILED:` markers — authoritative gate on the committed
     patch (`engine/build-p2.log`, `engine/build-p2.exit`, commit
     `e8a1859972`).
- Validation: `nm -gU libchrome_dll.dylib` shows
  `T _ReArcEngineBridgeVersion` and `T _ReArcEngineSetLifecycleCallbacks`;
  ObjC classes `ReArcApplication`/`ReArcAppDelegate` and strings
  `ReArc/`, `ReArc ` (about:version) present in the dylib;
  `Chromium --version` exit 0. No runtime launch test beyond `--version`
  per wave constraints.

### app/003-app-delegate-menu-install.patch — P-APP-001 wave-5 slice 1

- Content: two rearc includes in `chrome/browser/chrome_browser_main_mac.mm`
  plus a gate at `ChromeBrowserMainPartsMac::PreCreateThreads()`: when an
  engine lifecycle host is registered, `rearc::InstallReArcAppDelegateAndMenu()`
  installs the retained `ReArcAppDelegate` and placeholder menu, and the
  function returns before the AppController/`BuildMainMenu`/`mainMenuCreated`
  block so AppController is never instantiated. Gate off → stock path
  bit-identical. No BUILD.gn change (002 wired the dep).
- Applied: prototype edits gated first; the on-disk patch was then applied to
  the pristine base via `git apply --3way --index` and verified byte-identical
  to the gated prototype before commit. Committed as `89beaef995`.
- Build: incremental `build.sh --jobs=8` → **exit 0**, 0 `FAILED:` markers
  (`engine/build-p3.log`, `engine/build-p3.exit`).
- Validation: `nm` on `obj/chrome/browser/core/chrome_browser_main_mac.o`
  shows undefined refs to `rearc::GetEngineLifecycleHost` and
  `rearc::InstallReArcAppDelegateAndMenu`; `libchrome_dll.dylib` keeps both
  exported C ABI symbols and the `ReArcApplication`/`ReArcAppDelegate` ObjC
  classes; strings `ReArc/`, `ReArc ` and the delegate warning string present;
  `Chromium --version` exit 0 (same pre-existing component-build ObjC
  duplicate-class warnings). `git apply --check -R` passes for 001+002+003.

### app/004-main-loop-end-finalization.patch — P-APP-001 wave-5 slice 2

- Content: gate in `ChromeBrowserMainPartsMac::DidEndMainMessageLoop()`: with
  an engine lifecycle host registered, finalizes through
  `rearc::FinalizeReArcAppDelegate()` and returns; the stock
  `AppController.sharedController` call (which would recreate the delegate
  during teardown) is unreachable under the gate and unchanged without a host.
  No new includes (003 already imported the bridge headers).
- Applied: prototype gated first; patch applied to the pristine base via
  `git apply --3way --index`, verified byte-identical to the gated prototype.
  Committed as `9806bf8a4f`.
- Build: incremental `build.sh --jobs=8` → **exit 0**, 0 `FAILED:` markers
  (`engine/build-p4.log`, `engine/build-p4.exit`).
- Validation: `nm` on `chrome_browser_main_mac.o` now references
  `rearc::FinalizeReArcAppDelegate` alongside the 003 symbols; both C ABI
  exports intact in `libchrome_dll.dylib`; `Chromium --version` exit 0.
  `git apply --check -R` passes for 001+002+003+004.

### app/005-readiness-keepalive-profile-seams.patch — P-APP-001 wave-5 slice 3

- Content: additive readiness/keepalive/profile-registration seams, all gated
  on `rearc::GetEngineLifecycleHost()`:
  - `rearc_readiness.{h,cc}`: `EngineReadinessSink` +
    `SetEngineReadinessSink()` + `SignalEngineReady()`; a new
    `ChromeBrowserMainPartsMac::PostBrowserStart()` override signals after
    the stock startup tail (`chrome_browser_main.cc:2165`).
  - `rearc_keep_alive.{h,cc}`: `ScopedKeepAlive` wrapper
    (`APP_CONTROLLER`/`DISABLED`, mirroring AppController); no call sites
    yet.
  - `rearc_profile_registry.{h,cc}`: opaque `Profile` handle registry; a
    gated call in `PostProfileInit()` registers profiles as they come up. No
    real profile work.
  - Build wiring: the six seam sources join `source_set("core")`'s `is_mac`
    block in `chrome/browser/BUILD.gn` (plus `//components/keep_alive_registry`
    in deps), **not** app/002's `rearc_bridge` target.
- Why the restructure: gate attempt 1 (compiled green, superseded) extended
  002's `rearc_engine_lifecycle.*` and `rearc_bridge/BUILD.gn` directly —
  which broke `git apply --check -R` for 002 (a new-file patch cannot
  reverse-apply once its files carry later modifications). The shipped patch
  never touches a 002 file; both BUILD.gn hunks sit >10 lines from 002's deps
  hunk, and the `.mm` hunks keep the disjoint-context placement used by
  003/004 (documented in the patch header).
- Applied: prototype gated first (attempt 2); patch applied to the pristine
  base via `git apply --3way --index` (new files took the documented
  3-way→direct fallback), verified byte-identical to the gated prototype.
  Committed as `effa0af07b`. The superseded attempt-1 commit `f5361301bf`
  was dropped via `git reset --hard 9806bf8a4f` before the restructure; both
  compile logs are kept in `engine/build-p5.log`.
- Build: incremental `build.sh --jobs=8` → **exit 0**, 0 `FAILED:` markers
  (`engine/build-p5.log` attempt 2, `engine/build-p5.exit`).
- Validation: seam objects compiled under `obj/chrome/browser/core/`
  (`rearc_keep_alive.o`, `rearc_profile_registry.o`, `rearc_readiness.o`);
  `nm` on `chrome_browser_main_mac.o` references `SignalEngineReady` and
  `RegisterBridgeProfile`; seam symbols present in `libchrome_dll.dylib` as
  local (`t`) symbols — **no new exported symbols**, exactly the two 002 C
  ABI exports remain (`framework.exports`/`framework.order` untouched per
  wave scope); `Chromium --version` exit 0. `git apply --check -R` passes for
  the whole series (001+002+003+004+005) against the final tree.

## PATCH-LOG — wave 6, P-TAB-001 slices (2026-11-02, all times UTC)

### tab/006-embedded-mode-view-delegate.patch — P-TAB-001 wave-6 slice S1

- Content: the browser-less tab model's first (and only) upstream seam.
  - `engine_mode.{h,cc}`: `rearc::IsEngineEmbeddedMode()` — ambient,
    process-wide predicate. Content consults
    `ChromeContentBrowserClient::GetWebContentsViewDelegate` synchronously
    inside `WebContents::Create` (`web_contents_impl.cc:4537`) plus four
    later call sites, so the decision cannot be per-tab or post-Create.
  - `web_contents_view_delegate_mac.{h,mm}`:
    `ReArcWebContentsViewDelegate : content::WebContentsViewDelegate`
    (C++ class, not ObjC — plan §6 assumed ObjC; recorded as drift) with a
    `ReArcNativeWindowProvider` registration seam so S4's attachment lease
    wires `GetNativeWindow()` additively. Day-one: `GetNativeWindow()` nil
    (documented "not in any window"), context menus suppressed,
    `OnPerformingDrop` aborted with `std::nullopt` (content's default
    *performs* the drop) — callbacks always complete, never hang (R7).
  - Upstream hunks: guarded (`#if BUILDFLAG(IS_MAC)`) include block +
    embedded-mode branch in `chrome_content_browser_client.cc`
    (`GetWebContentsViewDelegate` body, :1846-1850 at pin — plan said
    :1848-1852, ±2 drift), and a sources block in
    `chrome/browser/BUILD.gn`'s `is_mac` list.
- Deviations recorded (full detail in P-TAB-001-SLICES.md drift log):
  derived predicate instead of the plan's `std::atomic<bool>` + setter (the
  only legal setter site lives in app/002's frozen
  `rearc_engine_entry_mac.mm`); platform guards add ~4 LOC over the ~5-LOC
  sketch; BUILD.gn sources placed between `icon_loader_mac.mm` and
  `memory_details_mac.cc` — not the alphabetical position — to keep the -U3
  window disjoint from app/005's hunk; new area dir `tab/` per the wave-6
  brief's area-deviation allowance.
- Applied: prototype gated first; patch applied to the pristine base via
  `git apply --3way --index` (new files took the documented 3-way→direct
  fallback), verified byte-identical to the gated prototype. Committed as
  `526c989d9c`.
- Build: incremental `build.sh --jobs=8` → **exit 0** on attempt 4
  (`engine/build-p6.log`, `engine/build-p6.exit`). Attempts 1–3 were
  header-completeness fixes in the new files (`ui/gfx/native_ui_types.h`
  not `native_widget_types.h`; `content/public/common/drop_data.h`;
  `base/functional/callback.h` for the forward-declared `OnceCallback`).
- Validation: `nm -m` on `libchrome_dll.dylib` shows
  `rearc::IsEngineEmbeddedMode()`,
  `rearc::CreateReArcWebContentsViewDelegate(content::WebContents*)`,
  `SetReArcNativeWindowProvider`/`ClearReArcNativeWindowProvider`, and
  `ReArcWebContentsViewDelegate::GetNativeWindow()` as local (`t`) symbols;
  `ChromeContentBrowserClient::GetWebContentsViewDelegate(content::WebContents*)`
  signature unchanged; **no new exported symbols** (dyld_info cross-check);
  `Chromium --version` → 156.0.8078.74. `git apply --check -R` passes for
  the whole series (001+002+003+004+005+006) against the final tree.

### tab/007-tab-registry-session-delegate.patch — P-TAB-001 wave-6 slice S2

- Content: the browser-less tab model's core, additive only (no upstream
  hunks beyond the BUILD.gn sources block).
  - `tab_registry.{h,cc}`: `TabRegistry` singleton — engine-side monotonic
    uint64 `tab_id` allocation (IPC-CONTRACT §3), session map, FIFO command
    envelope + strictly in-order `DrainCommands()` (producers arrive with
    S3's IPC layer; day-one nothing posts), idempotent `DestroySession`
    with **deferred** destruction (posted via the current sequenced task
    runner so delegate/observer callbacks unwind first — P-TAB-001's
    destruction-from-callback prohibition), and `DestroyAllSessions()` as
    the teardown-ordering primitive (sessions die before profile release).
  - `tab_session.{h,cc}`: one `std::unique_ptr<content::WebContents>` via
    `WebContents::Create` (no TabStripModel / TabModel / TabFeatures /
    BrowserWindowInterface adapter — the registry route never reaches
    `tab_features.cc:276`'s CHECK), one per-session delegate, space/order
    metadata, guarded close-state machine (`kOpen → kCloseRequested →
    kUnloadPending → kClosed` + veto paths), monotonic content-generation
    counter, start-hidden policy. `web_contents()` is bridge-internal only.
  - `tab_delegate.{h,cc}`: `ReArcTabDelegate :
    content::WebContentsDelegate` with exactly the day-one override set
    P-TAB-001 lists — `OpenURLFromTab` (CURRENT_TAB routed for real via the
    content-shell `LoadURLWithParams` pattern; NEW_*/SINGLETON/others
    rejected nullptr + VLOG), `AddNewContents` (predictable rejection,
    `*was_blocked = true`), `ActivateContents` (no focus stealing),
    `IsContentsActive` (true — content's browser-less semantic),
    `CloseContents` (shell owns lifetime), `BeforeUnloadFired`
    (conservative cancel: `*proceed_to_fire_unload = false`),
    `NavigationStateChanged`/`LoadingStateChanged` (quiet — S3 owns
    events), `TakeFocus` (false), `GetJavaScriptDialogManager` (nullptr —
    audited: callbacks complete, beforeunload vetoed; S5 ships the real
    conservative-cancel manager). R7: everything cancels through upstream
    callbacks; nothing hangs.
- Recorded decisions (full detail in the patch header and
  P-TAB-001-SLICES.md §8 drift log): R6 helper whitelist EMPTY day-one
  (CoreTabHelper lives in //chrome/browser/ui/tab_contents/ and :core
  cannot dep on //chrome/browser/ui; decision moves to the S5 audits);
  BrowserContext stored borrowed with the ScopedProfileKeepAlive wiring
  deferred to the embedded-startup wave; S4's attachment lease will
  associate via its own tab_id-keyed map (tab/007's files freeze at
  landing).
- Applied: prototype gated first; patch applied to the pristine base via
  `git apply --3way --index` (new files took the documented 3-way→direct
  fallback), verified byte-identical to the gated prototype. Committed as
  `72e0da4ad3`.
- Build: incremental `build.sh --jobs=8` → **exit 0** on attempt 2
  (`engine/build-p7.log`, `engine/build-p7.exit`); attempt 1 added the
  `base::NoDestructor` friend declaration. No upstream-file changes
  resulted.
- Validation: `nm -m` on `libchrome_dll.dylib` shows the full
  `rearc::TabRegistry` API, `rearc::TabSession` (CreateArgs / SetCloseState
  / NoteContentsReplaced / …), and `rearc::ReArcTabDelegate`'s day-one
  override set as local (`t`) symbols; safe-deny VLOG strings present;
  **no new exported symbols** (dyld_info: only the two 002 C ABI exports
  remain); `Chromium --version` → 156.0.8078.74. `git apply --check -R`
  passes for the whole series (001…007) against the final tree.

### tab/008-tab-events-observer.patch — P-TAB-001 wave-7 slice S3

- Content: the typed tab/navigation event surface, additive only (no
  upstream hunks beyond the BUILD.gn sources block).
  - `ipc_tab_events.{h,cc}`: `TabEvent` struct (sparse `has_*` change
    fields per rearc.ipc.v1 §3 `tab.updated`; navigation fields per §4),
    `TabEventKindName()` returning the wire-name literals (`tab.created`,
    `tab.updated`, `tab.closed`, `navigation.committed`,
    `navigation.failed` — the slice-plan §6 strings gate keys on them),
    `TabEventSink` registration seam, generation-stamped `EmitTabEvent`
    (unknown/destroyed sessions drop with a VLOG EXCEPT `kTabClosed`,
    which races session teardown and carries the caller's last-known
    generation), `EmitTabCreatedEvent` / `EmitInitialSnapshotEvent` (§3:
    `tab.created` first, then a fully-populated `tab.updated` baseline).
    `profile_id` stays 0 day-one with an explicit never-ship-unstamped
    note; the wire envelope arrives with the transport slice.
  - `tab_observer.{h,cc}`: one `TabObserver : content::WebContentsObserver`
    per session, attached via `AttachTabObserver` only after `tab.created`
    (§3 ordering). `navigation.*` filtered to `IsInPrimaryMainFrame()`;
    committed vs failed splits on `HasCommitted()`; `net::ERR_ABORTED`
    still emits `navigation.failed` (cancellation, not a silent drop);
    `navigation_id` maps the session-stable bridge ID from
    `NavigationHandle::GetNavigationId()` — never a raw pointer, the
    handle is never retained (§4). Renderer crash emits `is_crashed=true`
    and is NOT a close (§3). `WebContentsDestroyed` emits `tab.closed`
    (always the final event) and self-detaches via a POSTED task — no
    destruction inside a content callback.
  - No call sites wired: `AttachTabObserver` / `EmitTabCreatedEvent` are
    integration seams for the later IPC wiring, because
    `TabRegistry::CreateSession` lives in tab/007's frozen file.
  - BUILD.gn hunk placement: between `"file_select_helper_mac.mm"` and
    `"fullscreen_mac.mm"` — the -U3 context overlaps tab/007's
    after-context only on lines neither patch changes (series-mechanics:
    context-only overlap permitted).
- Applied: prototype gated first; patch applied to the pristine base via
  `git apply --3way --index`, verified byte-identical to the gated
  prototype. Committed as `5de707451d`.
- Build: incremental `build.sh --jobs=8` → **exit 0** on attempt 2
  (`engine/build-p8.log`, `engine/build-p8.exit`); attempt 1 fixed three
  compile errors (`base::NoDestructor<TabEventSink*>` static_assert on a
  trivial type → plain function-local static; `NavigationController::
  CanGoBack/CanGoForward` are non-const). No upstream-file changes
  resulted.
- Validation: `nm -m` on `libchrome_dll.dylib` shows `EmitTabEvent`,
  `SetTabEventSink`, `TabEventKindName`, `AttachTabObserver`,
  `DetachTabObserver`, `EmitTabCreatedEvent`, `EmitInitialSnapshotEvent`
  as local symbols; all five event-name literals present exactly once in
  `strings`; `Chromium --version` → 156.0.8078.74.
- Smoke (engine/docs/SMOKE-TEST.md — first wave the gate exists):
  G1 PASS, G2 PASS, G4 PASS, G5 PASS (one transient FAIL in a
  back-to-back invocation; 4/4 PASS on isolated reruns).
  **G3 gate-command defect (NOT a slice regression):** the documented
  check `head -c4 s.png | LC_ALL=C grep -q PNG` returns 1 on this
  machine's BSD grep — the 0x89 byte marks the 4-byte input binary and
  `-q` suppresses the match even under LC_ALL=C (reproduced against a
  synthetic file; build-independent). Gate INTENT verified green: a
  valid 800×600 PNG is produced (`\x89PNG\r\n\x1a\n` magic via xxd;
  `LC_ALL=C grep -qa PNG` PASS, consistent across reruns). Reported to
  the orchestrator for a SMOKE-TEST.md command fix (BSD grep needs
  `-a`).
- `git apply --check -R` passes for the whole series (001…008) against
  the final tree.

### tab/009-content-host-attachment-lease.patch — P-TAB-001 wave-7 slice S4

- Content: the native attachment surface, additive only (no upstream
  hunks beyond the BUILD.gn sources block).
  - `content_host_mac.{h,mm}`: `ReArcContentHostView`, a deliberately
    layerless plain NSView owning exactly one content view — the tab's
    WebContentsView container, anchored via
    `WebContents::GetNativeView()` (R8's stable anchor; never
    `GetContentNativeView()`/RWHVMac). The header is pure C++ (opaque
    `ReArcContentHostRef` = void*, plus `gfx::NativeView`/`NativeWindow`
    values, both C++ classes usable outside ObjC TUs); every AppKit
    touch is in the .mm. `ReArcContentHostCreate` retains via
    `CFBridgingRetain`; `ReArcContentHostRelease` drops ONLY the
    engine's retain (IPC-CONTRACT §6: the shell may retain the emptied
    NSView until it dismantles its scaffolding). DIP→points rounding,
    scale recorded as a hint.
  - `attachment_lease.{h,cc}`: `AttachmentLeaseRegistry` singleton
    (NoDestructor friend pattern per tab/007). §6 rules enforced:
    at most one live attachment per tab (`kAlreadyAttached`; a lease
    never grants a second superview); attachments start hidden and
    `WasShown`/`WasHidden` fire only on visibility transitions;
    engine-allocated monotonic `attachment_id` from 1 (§1);
    shell-initiated `DetachView` empties the host on the main thread
    and invalidates the id with NO event; engine-initiated
    `InvalidateLeasesForTab` empties the host FIRST, releases the
    engine's retain, then reports `view.invalidated` to the
    `AttachmentEventSink` with the wire-literal reason names
    (`tab_closed`, `window_closed`, `content_replaced`,
    `engine_stopped`); expired ids fail stale with a VLOG.
    `LeaseWindowProvider` wires tab/006's S1 seam: content's
    `GetNativeWindow()` consults resolve to the host's window while a
    lease is live.
  - No call sites wired: the registry's verbs are the transport slice's
    handlers; invalidation triggers (S6 close, S7 discard, engine
    teardown, window lifecycle) live in frozen files and arrive via
    later seams.
  - BUILD.gn hunk placement: after `"shutdown_watchdog_mac.h"` at the
    end of the is_mac sources list — a -U3 window fully disjoint from
    app/005's block (three unchanged lines between them).
- Applied: prototype gated first; patch applied to the pristine base via
  `git apply --3way --index`, verified byte-identical to the gated
  prototype. Committed as `620cb7c68b`.
- Build: incremental `build.sh --jobs=8` → **exit 0** on attempt 3
  (`engine/build-p9.log`, `engine/build-p9.exit`); attempt 1 was a Cocoa
  import typo, attempt 2 moved the ObjC class out of the C++ namespace
  (ObjC declarations are global-scope-only). No upstream-file changes
  resulted.
- Validation: `nm -m` on `libchrome_dll.dylib` shows the full
  `AttachmentLeaseRegistry` API and all nine `ReArcContentHost*` entry
  points as non-external symbols; all four invalidation-reason literals
  present exactly once in `strings`; `Chromium --version` →
  156.0.8078.74.
- Smoke (engine/docs/SMOKE-TEST.md): G1 PASS, G2 PASS, G4 PASS, G5 PASS
  (isolated runs, no transient failures this slice). G3 unchanged: the
  documented command still trips the BSD grep `-q` defect reported with
  tab/008 (build-independent); gate intent green (valid PNG produced;
  `LC_ALL=C grep -qa PNG` PASS).
- `git apply --check -R` passes for the whole series (001…009) against
  the final tree.

### Series state

`engine/patches/series` now applies: `chrome/001-rearc-about-branding.patch`,
then `app/002-app-host-runloop.patch`,
`app/003-app-delegate-menu-install.patch`,
`app/004-main-loop-end-finalization.patch`,
`app/005-readiness-keepalive-profile-seams.patch`,
`tab/006-embedded-mode-view-delegate.patch`,
`tab/007-tab-registry-session-delegate.patch`, and
`tab/008-tab-events-observer.patch`, and
`tab/009-content-host-attachment-lease.patch`. Wave 7 is complete: P-TAB-001
slices S3 and S4 landed with green gates and smoke results as recorded
above, and `git apply --check -R` passes for every patch file against the
final tree. The stale planned-inventory
line for P-TAB-001 under `chrome/` was replaced by the `tab/` entries.
Wave 5 completed all three remaining P-APP-001 lifecycle slices. Deferred to
later waves: embedded-startup restructuring of `PreMainMessageLoopRunImpl`
(the spec's `browser_creator_->Start(...)` separation), shell-owned menu
construction, the readiness/keepalive C ABI surface (a `framework.exports`
hunt at that point), ordered teardown + keepalive release, and real profile
registration work. `framework.exports` shipped in 002; `framework.order`
needed no hunk (unlisted symbols are tolerated; no ordering constraint on the
new exports).


## PATCH-LOG — wave 8, P-TAB-001 S5 (2026-11-02)

Service adapters landed as four separate Chromium commits after S4
`620cb7c68b`. Full behavior, dependency audit and drift are recorded in
[P-TAB-001-SLICES, S5](patches/P-TAB-001-SLICES.md#s5--service-adapters).

| Patch | Commit | Green build log (under engine/) | G1–G5 |
|---|---|---|---|
| `tab/010-service-events-favicon-adapter.patch` | `412dcd8253` | `build-p10.log` attempt 1; final `build-p11.log` attempt 2 | PASS |
| `tab/011-media-session-adapter.patch` | `b104f5157b` | `build-p12.log` attempt 1 | PASS |
| `tab/012-visible-security-state-adapter.patch` | `39b9d30e12` | `build-p13.log` attempt 1 | PASS |
| `tab/013-conservative-javascript-dialog-manager.patch` | `f80b69720d` | `build-p14.log` attempt 1; final `build-p15.log` attempt 2 | PASS |

All commits use `ReArc Overlay <overlay@rearc.invalid>` and the Codex
co-author trailer. No failed compile attempts. All final binaries passed
G1–G5 (G3 `grep -qa`); smoke logs are `smoke-tab010-final.log` and
`smoke-tab011.log` through `smoke-tab013.log`. The adapters remain dormant
except the planned JavaScript-dialog delegate hook; service attachment and
transport advertisement await integration. No S6 changes or push.

All 13 series entries passed sequential reverse checks in a temporary index,
reversed to the exact Chromium 156.0.8078.74 tree, and replayed forward to
HEAD (`replay-s5.log`). This preserves earlier patch files and accounts for
S5's planned edit of the delegate introduced by tab/007. Chromium worktree
clean after the four commits; overlay patches/series and S5 documentation
are updated outside that nested repository.
