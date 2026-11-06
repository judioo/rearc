# Wave 16 implementation report

All four concerns are implemented or measured, committed and validated. No shell edits by this implementation,
outer repository commits, subagents or pushes. Chromium baseline `7f633822da`, upstream pin `d331de35ca`
(156.0.8078.74). Current ABI **1.13**, bridge **0.15.0**; Configure still takes 1.

| Concern | Chromium commit | Patch | Build / validation |
|---|---|---|---|
| Pending OS reads at shutdown | `367324a510` | tab/028-os-permission-shutdown.patch | p42; full native hosts, G1–G5, 4 shutdown processes |
| Pending standalone tab closes | `6201151b27` | tab/029-shutdown-pending-closes.patch | p43; full hosts plus close/veto hosts, G1–G5, 4 shutdown processes |
| Existing Default directory | `52406c2b93` | tab/030-existing-profile-directory.patch | p44/p45; full hosts plus restart migration, G1–G5, 4 shutdown processes |
| Hidden-tab policy evidence | `137a0dc3dc` | tab/031-hidden-tab-policy-evidence.patch | p46 no-op green; full native hosts, G1–G5, 30 shutdown processes; no policy change |

## 1. Shutdown with named profiles and OS authorization pending

The reproduced wait is **not ProfileDestroyer or cookie-store initialization**.
Main is in ThreadPoolImpl::Shutdown → TaskTracker::CompleteShutdown. The task
holding shutdown is a running SKIP_ON_SHUTDOWN media-permission cache refresh:
SystemMediaPermissionCache → CheckSystemAudioCapturePermission → AVCaptureDevice
→ macOS TCC preflight. The separately blocked OSCrypt GetKeyTask already has
CONTINUE_ON_SHUTDOWN. A SKIP task that has started must finish before shutdown.

Evidence: runtime-abi-stall-w16-named-late-before-sample.txt and the associated
named-profile reproduction. The shell's saved sample was taken during loading,
so it cannot establish that its original 24.0-second shutdown was exclusively
TCC. The new shutdown sample and controlled indefinite regression establish the
defect fixed here. Timing of the background OS task explains why startup-only
and longer named-profile workflows need not exhibit the same wait.

The production macOS media-cache task runner now uses CONTINUE_ON_SHUTDOWN for
these read-only status queries. Worker callbacks are process-lifetime functions;
replies hold weak cache references. Borrowed test authorization wrappers retain
SKIP semantics. No encryption, stored key, cookie/database flush, data-writing
task trait or permission result changes. Profile/context destruction and upstream
ChromeMain cleanup still run. The framework must remain loaded until process exit.

Matching early-shutdown runs use four attached tabs, a permanently blocked
Keychain lookup, a 1500 ms shutdown delay, and normal then forced shutdown in
fresh processes. No retries:

| Profile | Before normal / force (ms) | After normal / force (ms) |
|---|---:|---:|
| Named | 6794.861 / 15719.008 | 2566.728 / 3281.552 |
| OTR under named | 3659.822 / 2940.094 | 2382.669 / 1112.168 |

Logs: runtime-abi-stress-w16-{named,otr}-{before,after}.log. These include startup
and renderer work and vary with OS state; they do not isolate TCC alone. Another
late natural named baseline was 6126.507 / 352.191 ms.

The optional TCC interposer makes the actual status query wait forever alongside
the Keychain interposer. On the old build, w16-tcc-late-before reaches both
blockers and requests shutdown, then exceeds the **65-second process watchdog**
without completing. That is a censored failure, not a measured 65-second shutdown.
The harness terminates only its own child. After the fix, both reads remain
blocked through successful exit:

| Profile | Last tab.closed (ms) | Terminal completion (ms) | After last tab (ms) |
|---|---:|---:|---:|
| Named | 513.822 | 917.177 | 403.355 |
| OTR under named | 1330.101 | 1923.506 | 593.405 |
| Default | 907.048 | 2984.954 | 2077.906 |

Logs: runtime-abi-stress-w16-{named,otr,default}-os-blocked-after.log and the
os-after driver. No real Keychain secret was read or modified. First-load access
still requires signing and OS authorization. Neither mock keychain nor either
interposer is a production fix or a shipping option.

## 2. Shutdown subsumes standalone pending closes

`shutdown_pending_closes` (ABI 1.12) joins an existing close-controller request
and preserves its original completion. Normal shutdown honors a joined veto;
force promotes pending cleanup. Both accepted requests complete exactly once.
A veto resumes service; already-closed tabs stay closed. Live-content counting
also covers the registry-removal / posted-destructor interval. Terminal successful
shutdown completion remains the last callback, immediately before Run returns.

An accepted ProfileClose still serializes separately and makes Shutdown busy
until its completion, including OTR destruction. Another accepted Shutdown is
busy. A second TabClose for the same tab remains busy. Pending profile opens
are cancelled once by accepted shutdown. C-ABI.md records exact rejection,
post-run and callback-order semantics. ABI 1.10 hosts can retain their existing
wait-before-Shutdown strategy.

Native shutdown hosts prove normal and forced joins, reentrant shutdown during
view invalidation, exactly-once close replies after tab.closed, and an activated
beforeunload veto followed by service recovery and forced retry. Full original
hosts, G1–G5 and 4 shutdown processes pass in gates-tab029.log.

## 3. Existing Default data is opened in place

`profile_directory` (ABI 1.13) adds:

```c
ReArcProfileOpenDirectory("Default", callback, context);
```

This opens the existing directory under the configured user-data-dir and returns
its actual BrowserContext identity. It copies, moves, merges and deletes no
databases. Opening the startup directory returns the startup ID; its lifetime
still belongs to shutdown and ProfileClose still returns invalid_state.

Directory tokens are exact ASCII basenames (1–128 bytes; letters, digits,
underscore, hyphen, interior spaces). Invalid syntax rejects synchronously.
Existing-directory validation is asynchronous: missing/wrong-case/non-directory
is not_found, symlink is invalid_argument, nonregular profile is unsupported.
Failures return ID 0 / off_the_record=false. Accepted callbacks remain deferred
and exactly once. Directory validation has a separate pending key until success,
so a racing create-if-missing ProfileOpen still creates its named profile. Both
then converge on the directory-keyed initialization registry. Named-key hex
paths and case-sensitive identity are unchanged.

The migration host writes a persistent cookie and localStorage through the old
Default API, shuts down, and in a second process reads
`["legacy=kept","DEFAULT-DATA-W16"]` using OpenDirectory. It checks duplicate
opens reuse the startup ID, traversal/absolute/empty syntax rejection, missing
and wrong-case directories, a symlink alias, a concurrent named creation and
cancellation of two pending directory opens exactly once during shutdown.
The additional cancellation run passes in runtime-abi-migration-w16-final-driver.log.
The full suite passes in gates-tab030.log.

Directory adoption requires the same authorized Safe Storage key as the data.
It does **not** convert pre-wave-14 Chromium Safe Storage ciphertext to the ReArc
key. Keep an offline backup and perform any older key-brand migration as a
separate authorized operation before opening that data with a differently
branded build; see PACKAGING-MAC.md. No silent key fallback is introduced.

## 4. Hidden-tab measurements

Production visibility and scheduler policy are unchanged. Four fresh-process
controls use disposable mock-keychain profiles and the default sandbox. The
script experiment alternates six hidden and six attached tabs per control:
48 loopback loads and 192 evaluations. All 48 visibility observations agree
with the native presentation state.

| Diagnostic control | Warm `42` hidden / attached (ms) | Eight 5 ms timers hidden / attached (ms) |
|---|---:|---:|
| Default | 4.112 / 6.060 | 10670.734 / 54.915 |
| Timer throttling disabled | 3.845 / 4.172 | 53.506 / 54.578 |
| Renderer backgrounding disabled | 3.686 / 4.637 | 7323.323 / 52.793 |
| Frame-rate cap disabled | 4.312 / 6.380 | 7450.831 / 54.096 |

The cold isolated call includes CDP/world setup: default medians are
45.651 / 64.089 ms, hidden maximum 198.132 ms. Immediate evaluation is not
generally held for seconds. Ordinary hidden timer wake-up/budget policy does
cause timer-dependent evaluation slowness: the default hidden chain has a
26.240-second maximum, while diagnostic timer disablement keeps the document
hidden and reduces its median to 53.506 ms. The pilot's 12-second assertion
was too short for this tail; the final harness records timeouts with a
30-second maximum and all final timer chains complete. The pilot logs remain
as diagnostics, not a passing measurement.

All 24 hidden rAF Promises hit the 350 ms deadline; all 24 attached ones finish
(per-control medians 5.242–6.362 ms). Removing the frame-rate cap does not give
hidden pages frames. Fresh tabs are younger than this pin's intensive-throttling
grace periods (60 seconds loaded / 5 minutes loading); this is not evidence of
aged intensive throttling. Source: PageSchedulerImpl's wake-up/budget policy
and scheduler common/features.h grace constants.

The evaluation loop's long timer waits affect the next tab's startup interval,
so first-load conclusions use a separate load-only stress run: ten hidden and
ten attached loads per control, 80 total, zero watchdog timeouts and no retries.

| Diagnostic control | Hidden p50 / max (ms) | Attached p50 / max (ms) |
|---|---:|---:|
| Default | 1277.564 / 3993.049 | 1261.942 / 3403.571 |
| Timer throttling disabled | 1268.745 / 4021.423 | 1265.106 / 2678.631 |
| Renderer backgrounding disabled | 1305.996 / 3753.998 | 1259.717 / 2509.024 |
| Frame-rate cap disabled | 1288.858 / 3365.803 | 1509.423 / 5624.783 |

No control supplies a first-load improvement that justifies an engine policy
change. Cold component/debug startup remains variable in both states. These
are diagnostic samples from one fresh process per control, not a release-build
benchmark or proof that no other background scheduling cost exists.

Under IPC-CONTRACT §5/§6, never attached does not mean attached-pending; the
engine has no such host intent. A blanket exemption would affect genuine
background tabs and contradict current hidden-page policy. Present a real
foreground host early, avoid awaiting rAF before attachment, and use direct
evaluation / isolated events rather than timer polling. A future preparation
capability would need explicit bounded intent and a separate contract. No
scheduler switch, fake visibility, ABI bump or feature flag is added for this
concern. PiP and file/WebUI evaluation remain unchanged.

Evidence: runtime-abi-latency-w16-driver.log, latency-w16-summary.json,
runtime-abi-stress-w16-latency-*.log, runtime-abi-load-controls-w16-driver.log,
load-w16-summary.json and runtime-abi-stress-w16-load-*.log. The load summary
parser was corrected after its completed baseline; that successful baseline
was read back, not rerun. A compact chart is in latency-w16.html.


## Exact Swift adoption

No shell changes are applied in this engine-only wave.

1. Rebuild/copy the headers, module map, framework, physical helpers and full
   dependency closure. Keep `ReArcEngineConfigure(1,...)`. Extend
   ChromiumCapabilities with `os_permission_shutdown:11`,
   `shutdown_pending_closes:12`, and `profile_directory:13`, each requiring both
   the minor and HasFeature. All existing ABI 1.10 layouts and calls are retained.
2. The TCC fix needs no Swift call change. Preserve stable signing, authorized
   ReArc Safe Storage access, retained callbacks through Run return and the
   existing prohibition on unloading/restarting the framework in process.
3. In ChromiumRuntime.shutdown/startDeferredShutdownIfIdle, the feature permits
   removing **only** `tabClosesInFlight > 0` from the deferral condition. Continue
   to defer for `closeInFlight` (ProfileClose). Keep every outstanding tab-close
   box and counter alive: its callback still arrives once, before terminal
   shutdown completion. Preserve normal-veto recovery and the forced retry path.
   Leaving the existing deferral logic unchanged also remains correct.
4. Persist a storage reference separately from ChromiumProfileKey's shell UUID:
   `.named(lowercasedUUID)` for current named profiles, or `.directory("Default")`
   for exactly one selected legacy owner. Never persist engine IDs. On an
   explicit successful adoption, atomically store that mapping; on each later
   launch open it before creating the profile's tabs. Do not silently replace
   existing named state or merge two profiles. Keep all directories intact.
5. Extend ChromiumRuntime.startOpen's `.persistent` branch to choose ProfileOpen
   for `.named`, and the new directory function for `.directory`. Reuse its
   existing `callProfile(finish)` and ProfileRequestBox: synchronous rejection
   releases the retain there and invokes finish with ID 0; an accepted callback
   balances the retain once. Keep the lifecycle queue/coalescing and error paths.
   Resolve the new symbol before calling against a weak-linked older framework.
   The following direct-import and dlsym types pass swiftc in abi-w16-import.log:

```swift
import Darwin
import ReArcEngine

typealias ProfileDirectoryOpen = @convention(c) (
    UnsafePointer<CChar>?, ReArcProfileCallback?, UnsafeMutableRawPointer?
) -> ReArcStatus

func openLegacyDefault(_ callback: ReArcProfileCallback,
                       _ context: UnsafeMutableRawPointer?) -> ReArcStatus {
    guard ReArcEngineABIMinorVersion() >= 13,
          ReArcEngineHasFeature("profile_directory"),
          let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                             "ReArcProfileOpenDirectory") else {
        return ReArcStatus(REARC_UNSUPPORTED)
    }
    let open = unsafeBitCast(symbol, to: ProfileDirectoryOpen.self)
    return "Default".withCString { open($0, callback, context) }
}
```

6. For other directory mappings pass their persisted token through the same
   resolved function. On older engines report unsupported rather than silently
   opening a fresh named profile. If the host independently knows its startup
   directory is Default, its existing DefaultProfile ID can represent that
   explicit mapping on ABI 1.10; this is a host fallback, not directory discovery.
7. The adopted startup ID is pinned until engine shutdown. Update startClose /
   ChromiumProfileTeardown to close its OTR children and tabs normally, while
   retaining the startup context; do not call ProfileClose on that ID or treat
   invalid_state as successful deletion. Removing host metadata does not erase
   Chromium data. Private sessions still use CreateOffTheRecord(adoptedID,...).
8. Keep effective visibility and attachment rules. A never-attached tab is
   hidden. Do not add timer retries or a forced-visible state to adoption code.
   Hidden timers and rAF retain their normal policy; immediate evaluations remain available.

## Final validation and replay

- p42, p43, p44, p45 and p46 are green. p46 reports no work, as concern 4
  changes documentation only. Each concern has a full native/G1–G5/stress gate
  in gates-tab028.log through gates-tab031.log. Final suite: 13 hosts / 18
  process runs, including profile/zoom/migration restarts and three pending-close
  modes plus activated veto recovery.
- All 11 ABI 1.10 struct sizes/alignments match; Swift direct import and gated
  dlsym adoption pass (abi-w16-import.log). All 49 symbols resolve through
  Chromium Framework, whose loaded queries report ABI 1.13 / bridge 0.15.0 /
  Chromium 156.0.8078.74 (nm-w16.log and driver).
- All ten original hosts pass against the **unmodified ABI 1.10 headers** from
  7f633822da, in 12 process runs. See runtime-abi-legacy110-driver.log and
  runtime-abi-*-legacy110.log. This is native ABI compatibility evidence; no
  shell build or self-test was run by this implementation.
- Final shutdown stress: **30/30 fresh processes, 120 attached tabs**, alternating
  normal/force and 0/25/250/1500 ms delays. Min/median/max is
  2193.993 / 4239.815 / 7886.581 ms; no failures or watchdog timeouts.
- Script controls: 48 tabs / 192 evaluations, including 24 expected hidden-rAF
  timeouts. Separate load-only controls: 80 loads, no timeouts. Double-blocked
  OS-read runs pass for named, OTR and Default. Detailed timings and limitations
  are above; scheduler diagnostic flags are not production defaults.
- The final smoke run passed G1/G2, then its historical full-command guard
  matched another shell wrapper quoting `siso ninja` before G3. The raw
  interruption is preserved in gates-tab031-build-guard.log and its driver.
  The shared guard now detects actual builders and conservatively rejects all
  non-shell old-pattern matches. Active-executable rejection and idle acceptance
  pass in build-guard-w16.log. G3–G5 were resumed and passed; successful native
  and G1/G2 work was not rerun. SMOKE-TEST.md records this tooling refinement.
- **32/32 reverse and forward patches pass**, in replay-w16.log. Reverse tree
  `ffe41d3ec78c520fbe20a43802869358d3e18961` exactly matches upstream pin
  `d331de35ca8ab1358c7a17e4bd41627d55eaef51`. Forward tree
  `772c66615768937a6c456acda0d4ed3829110e5b` exactly matches final HEAD
  `137a0dc3dc503d1c6012faf6d7eac30bad12cff0`. Replay uses a disposable index;
  the real index/worktree are untouched and clean.
- All four commits have author ReArc Overlay <overlay@rearc.invalid> and the
  requested Codex co-author trailer. Series contains all four new patches.
  C-ABI.md, PACKAGING-MAC.md, IPC-CONTRACT.md and §8 drift log are updated.
  No Chromium build remains active. Unrelated shell changes appeared during
  validation and were left untouched; no outer commit or push was made here.

The final evidence summary is final-validation-w16.log.

## Reproduction commands

Run from the repository root, with no Chromium builder active:

```sh
bash engine/scripts/build.sh --jobs=6
python3 engine/tests/run_w16_gates.py tab031 30
python3 engine/tests/run_abi_stress.py --label os-probe --shutdown 2 \
  --profile-mode named --block-keychain --block-tcc --shutdown-delay-ms 25000
python3 engine/tests/run_abi_stress.py --label otr-probe --shutdown 2 \
  --profile-mode otr --block-keychain --shutdown-delay-ms 1500
python3 engine/tests/run_latency_w16.py
python3 engine/tests/run_load_controls_w16.py
python3 engine/tests/check_w16_imports.py
python3 engine/tests/run_compat_w16.py
python3 engine/tests/replay_overlay.py > engine/replay-w16.log
```

Build logs continue at p42 through p46. Test fixtures use fresh disposable
profiles, stock sandbox and physical helper bundles. Diagnostic mock-keychain,
TCC/Keychain interposers and scheduler flags stay in tests. No optimized build,
production signing/ACL grant, notarization, clean-machine package, PiP change,
file/WebUI evaluation extension or old-key migration is claimed.
