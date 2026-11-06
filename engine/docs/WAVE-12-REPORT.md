# Wave 12 implementation report

Five Chromium commits, no push and no shell edits. ABI **1.5**, bridge
**0.7.0**, Chromium **156.0.8078.74**, pin `d331de35ca`. Major 1 and all existing
C structure layouts are unchanged; the wave-11 host still configures with 1.
The production first-load Keychain authorization dependency remains a packaging
item; no insecure fallback was added. Multi-profile support is specified as the
next complete ABI item in C-ABI.md, rather than partially implemented.

| Commit | Patch | Result | Build evidence |
|---|---|---|---|
| `715545163c` | `tab/019-trusted-navigation-schemes.patch` | data/file, audited settings/version WebUI, bounded view-source; null-safe SettingsUI autofill-dependent controls; minor query | `build-p29.log`, `build-p30.log` (attempt 2) |
| `0e3511018e` | `tab/020-script-evaluation-results.patch` | Isolated boost/editor or explicit main-world evaluation, Promise/JSON results, structured errors, timeout and cancellation | `build-p31.log` (attempt 2) |
| `89f94b7ae7` | `tab/021-media-metadata-snapshot-semantics.patch` | false means unchanged; every emitted media snapshot authoritatively replaces metadata, with empty strings clearing it | `build-p32.log` |
| `6d34fcb0a8` | `tab/022-initial-document-lazy-page-services.patch` | No synthetic blank load for null creation; lazy services; preserve scripts through admitted WebUI/file visits | `build-p33.log` |
| `6c6160cfc1` | `tab/023-keychain-authorization-shutdown.patch` | Key-read authorization cannot block ThreadPool/ChromeMain shutdown | `build-p34.log`, final `build-p36.log` |

`build-p35-regression-before.log` is a successful intentional rebuild with the
previous key-task shutdown behavior, used to obtain a failing deterministic
runtime regression before restoring the fix in p36. No such reversal remains
in the checkout. Each commit uses ReArc Overlay <overlay@rearc.invalid> and ends
with the requested Codex co-author trailer. Patches are appended to series;
C-ABI.md and P-TAB-001-SLICES.md §8 record policy and drift.

All five concerns have green G1–G5 logs (`smoke-tab019.log` through
`smoke-tab023.log`). Final G1–G5 took 10.4, 15.0, 11.5, 12.8 and 13.6 seconds,
respectively, with fresh profiles and the default sandbox. Native core, services,
URL policy, evaluation and scheme-return hosts pass. Final per-concern copies
are `runtime-abi-{core,services,urls,eval,scheme_return}-tab023.log`; earlier
concern copies are retained where applicable. Native disposable profiles use
Chromium's mock Keychain to avoid ambient authorization, without disabling the
sandbox. C11 syntax and Swift module/callback imports pass in
`abi-w12-import.log`; `nm-tab023.log` verifies all **39 ReArc exports** through
framework resolution. The release order/export lists include the additions.
No optimized or shipping-packaging validation is implied.

The evaluation host checks access to an installed boost's isolated globals,
main-world separation, JSON objects/arrays, resolved Promises, persistent
editor globals, undefined→null, exceptions, non-JSON BigInt, timeout, busy/input
rejection and exactly-once navigation/close cancellation. The services host
asserts authoritative metadata on every media event. The scheme-return host
proves HTTP→WebUI→HTTP→file→HTTP preserves acknowledged script/peek registration
and rejects host evaluation/capture on file/WebUI. Existing attachment ownership,
close ordering, favicon, security, CSS replacement/pageshow, snapshots and
trusted link peek tests remain green.

First-load timing is create→fixture-title against a loopback server. Each row
contains 30 fresh tabs, closed after the first load; watchdog is 20 seconds with
no retries. p95 is nearest-rank (ceil(0.95*N)). Values below are seconds.

| Build / Keychain | Mode | Min | Median | p95 | Max | Timeouts |
|---|---|---:|---:|---:|---:|---:|
| Original / real OS | Hidden | 0.109 | 1.342 | 2.656 | 12.174 | 0 |
| Original / real OS | Attached | 0.784 | 1.312 | 2.054 | 2.180 | 0 |
| Before / isolated mock | Hidden | 0.110 | 1.262 | 3.169 | 3.932 | 0 |
| Before / isolated mock | Attached | 0.121 | 1.260 | 2.476 | 2.553 | 0 |
| After tab/022 / isolated mock | Hidden | 0.074 | 1.273 | 2.575 | 3.585 | 0 |
| After tab/022 / isolated mock | Attached | 0.076 | 1.238 | 2.545 | 2.582 | 0 |

Logs: `runtime-abi-stress-{before,before-isolated,after-isolated}.log` and their
driver logs. The final comparison records **zero placeholder about:blank
commits**. The medians are essentially unchanged: the lifecycle cleanup does
not establish a large first-load latency improvement. tab/023 changes shutdown
only, not this navigation path. The inline/report figure is
`wave12-first-load.html` in engine/.

A separate real-Keychain URL run stalled past 120 seconds. NetLog locates its
network delay after COMPUTED_PRIVACY_MODE and before transaction start, while
cookie retrieval awaits encryption initialization. The process sample captures
OSCryptAsync GetKeyTask→KeychainPassword::GetPassword→SecItemCopyMatching→
SecurityServer::decrypt; main remains in its responsive application loop.
Evidence: `runtime-abi-urls-keychain-timeout.log`,
`runtime-abi-keychain-stall-sample.txt`, `runtime-abi-netlog.json` and the trace
logs. This reproduction is not a hidden-WebContents, boost barrier or initial
blank-commit deadlock. No visibility override, renderer priority change or
navigation retry was introduced. The shell currently ad-hoc signs its replaced
executable; a stable signing identity and authorized Safe Storage access remain
required for production. Authorization/ACL causation is an inference from that
setup; the blocking SecurityServer call itself is directly sampled.

The shutdown hang also reproduced with four attached navigating tabs and a
35-second watchdog: main waits in ThreadPoolImpl::Shutdown, while the key-read
worker waits in SecurityServer. See `runtime-abi-stress-shutdown-keychain-before.log`
and `runtime-abi-shutdown-keychain-before-sample.txt`. The key task's default
SKIP_ON_SHUTDOWN waits for an already-running task. Production Keychain/name
storage has process lifetime, so tab/023 uses CONTINUE_ON_SHUTDOWN for that read;
explicitly injected borrowed test keychains retain SKIP behavior. Encryption,
authorization, profile-write and C callback teardown contracts remain intact.

The regression interposer in tests/block_keychain.mm blocks only Safe Storage
lookup, without reading or modifying a real key. Against the restored old
behavior the host again times out at 35 seconds, recording the blocked marker
and a shutdown request (`runtime-abi-stress-shutdown-blocked-before.log`). Against
the final build, both normal and force shutdown complete, closing all four tabs,
in **362.521 ms / 296.683 ms** while the lookup is permanently blocked
(`runtime-abi-stress-shutdown-blocked-final.log`). The ordinary stress loop passes
**30/30 fresh processes, 120 attached tabs**, alternating normal/force shutdown
and delays of 0/25/250/1500 ms against four-second response fixtures. Shutdown
completion min/median/max: **1.212 / 2.949 / 9.639 s**
(`runtime-abi-stress-shutdown-final.log`). A real-Keychain retest also passed.

Swift adoption is concrete and leaves the major-1 host setup intact:

1. Rebuild against the updated header/module/framework. Keep Configure(1).
   `ReArcEngineABIMinorVersion()` is 5. New features are navigation_extended,
   script_evaluation and media_metadata_snapshot. New statuses are
   REARC_SCRIPT_ERROR=17 and REARC_TIMEOUT=18.
2. ChromiumEngine.navigateNow can pass trusted data:, file:, chrome://settings,
   chrome://version and one view-source: wrapper around http(s)/file. Other
   chrome hosts and javascript/blob/external protocols remain rejected. Change
   the old self-test's data:-rejection assertion to a successful commit/title
   assertion; update the old http-only documentation/comment. Settings remains
   Chromium WebUI, with controls requiring a missing autofill client omitted.
3. Add a retained asynchronous evaluation context and static ReArcScriptCallback
   in ChromiumRuntime. Call ReArcTabEvaluateScript(tab,source,world,boostID,
   timeoutMS,callback,context). On synchronous rejection release the context and
   fail immediately; accepted calls complete once. Copy JSON/error strings in
   the callback, JSON-decode them, then release/resume exactly once. Never free
   callback strings with ReArcBufferFree. Check generation and the shell's
   current navigation identity before applying results; handle cancelled/timeout.
4. world=0, boostID=null uses rearc.boost.editor; use the installed lowercased
   package UUID to inspect that boost's globals. world=1 with null boostID is
   intentional page-world evaluation. Use e.g. 3000 ms (valid range 1–30000).
   Wait for a primary commit if invalid_state reports a pending navigation.
   Statements can use an IIFE; undefined is JSON null. The picker can bootstrap
   BoostPickerScript in the editor world and return snapshotAt(x,y) objects from
   native overlay hit coordinates. Replace WK-only dispatch in the editor paths;
   WebKit messageHandlers are not provided. Return scan arrays/objects directly,
   rather than JSON.stringify and then accidentally decoding a quoted string.
5. Keep ChromiumEngine.handle(.media)'s existing `if hasMetadata` update:
   false means unchanged; true replaces all fields; empty strings clear them.
   The final emitter always sends true for media events. No workaround clearing
   metadata on unrelated service-event kinds is needed.
6. Empty-tab creation should use null URL and then its actual destination; do
   not wait for a synthetic blank commit or add first-load retries/visibility
   hacks. Continue waiting for nonempty boost-plan acknowledgement. Registration
   may need a blank renderer to acknowledge pre-navigation installation.
7. Shutdown call sites require no API change. Retain contexts/native scaffolding
   until Run returns; do not unload/restart the framework. Stable application
   signing and Keychain authorization must be addressed in shell packaging for
   production first-load persistence; never add mock-keychain to production.
8. Spaces still share the startup profile. Do not expose working private/profile
   isolation based on this wave. C-ABI.md precisely specifies ProfileOpen,
   ProfileCreateOffTheRecord, ProfileClose, lifetime/veto/shutdown ordering and
   isolation/persistence gates for the next implementation.

Replay: see engine/replay-w12.log for the full newest-first reverse to the pin
and forward application back to the final HEAD using a temporary GIT_INDEX_FILE.

Replay completed: **23/23 reverse and forward patches pass**. The reverse tree
matches `d331de35ca8ab1358c7a17e4bd41627d55eaef51`; the forward tree matches final
HEAD `6c6160cfc104c7f9a8a9a1537e7d604abd04ec04`. Chromium's real index/worktree
are clean; no build remains active.
