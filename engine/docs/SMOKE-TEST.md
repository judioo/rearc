# ReArc engine — headless smoke test (runtime validation gate)

Date: 2026-11-02
Binary: `engine/chromium/src/out/ReArc-dev-arm64/Chromium.app/Contents/MacOS/Chromium`
Pin: Chromium 156.0.8078.74 (`engine/CHROMIUM_PIN`)
Overlay HEAD at matrix time: `effa0af07b` — 5 overlay commits applied
(`chrome/001-rearc-about-branding`, `app/002-app-host-runloop`,
`app/003-app-delegate-menu-install`, `app/004-main-loop-end-finalization`,
`app/005-readiness-keepalive-profile-seams`).
Since extended by waves 6–7 (`tab/006`…`tab/009`, HEAD `620cb7c68b`) with
G1/G2/G4/G5 re-validated green per slice; G3's check was amended to
`grep -qa` (BSD grep marks the 0x89 PNG magic binary and `-q` alone
suppresses the match).
Host: macOS (Darwin 27.2, arm64), logged-in GUI session, run from a terminal.

This document is the runtime validation gate for engine waves. It records a
72-cell headless matrix run against the **existing built binary** (no builds,
no tree mutations), the known-good minimal invocations that become the
CI-style gate, and the disposition of the historical wave-3 headless hang.

## Build-gate rule (hard)

Before **every** test run, no Chromium builder may be active. The historical
matrix used `pgrep -fl "siso ninja"`. Wave 16 refines the executable gate to
`pgrep -lx 'siso|ninja|autoninja'` and inspects any old full-command matches:
shell wrappers merely quoting that text are ignored; every non-shell match
still blocks. This avoids false positives from another agent's shell command
while retaining rejection of actual builders. `run_c_abi.build_gate` is shared
by smoke, native, stress and compatibility runners. If a compile gate owns the
tree, wait until it finishes; do not run tests against an active build.
Wave 18d additionally requires the raw `pgrep -fl "siso ninja"` output to be
empty, including quoted shell wrappers. The shared gate now enforces both
checks. Wait for such wrappers as well as builders to finish. Run test runners
sequentially: simultaneous raw pgrep probes can detect each other.
Wave 18e reruns G1–G5 against the 49-patch overlay as part of
`run_w18e_gates.py` (`smoke-w18e.log`). The new native hosts exercise the
embedded (non-headless) engine; G4 still covers the headless print path. The
`printing` ABI uses PdfPrintJob instead, so it does not depend on headless.
Before each build the shared gate was also checked, and builds waited for
concurrent shell self-test wrappers that quote the probe text: the shell's
self-test bundle symlinks this output directory.
Wave 18f reruns G1–G5 against the 54-patch overlay in `run_w18f_gates.py`
(`smoke-w18f.log`). Since this wave `run_smoke_gate.py` adds the test-only
no-outside-network switches to each gate:
`--disable-background-networking --disable-component-update
--host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost"`.
It also writes `--log-net-log` into the gate's fresh profile and fails the
gate on any TCP connect or UDP send to a non-loopback address. Each gate's
profile starts with secure DNS off (`Local State`). The native ABI and
stress runners use the same switches. The commands in §1 remain the minimal
manual form; add the three switches to keep a manual run off the network.
Every historical cell below passed its original check.

Wave 18g uses `pgrep -fl 'siso[ ]ninja'` in the shared guard and the older
wave-18c wrapper, per the task owner's correction. The bracket matches the
actual builder text and avoids matching the probe's own argv; executable-name
checks remain. Old shell wrappers containing literal `siso ninja` still match
and are awaited. Native, smoke and stress runs remain sequential, with the
same mock Keychain, throwaway profiles, secure-DNS-off Local State,
no-outside-network switches and native/smoke net-log failure on non-loopback
TCP connect or UDP send. `run_w18g_gates.py` adds save offers, HTTP auth and
local certificate/Safe Browsing interstitial fixtures to the prior hosts.

Wave-18g final validation: build p96 / ABI 1.39 / bridge 0.41.0, 37 native
hosts / 44 process runs, G1–G5, ordinary and pending-prompt stress (4 processes /
16 tabs each), and an actually blocked-TCC shutdown all pass. All 44 native and
five smoke processes have no outside connection. The 13 legacy ABI 1.17 and
38 ABI 1.38 struct layouts, Swift imports, 107 framework exports and
4-host/6-process exact-1.17 compatibility run pass. Replay 58/58 matches HEAD
`9739603b0f3fee4985c18d7407f3f3c4de05d865`. The modifier-click fixture proves background,
foreground, window and split intent plus actual referrer/noreferrer behavior.
See WAVE-18G-REPORT.md for logs and explicit client-certificate/DevTools deferrals.

Wave 18h adds the hosted DevTools host (four modes: frontend/target close
orders, nonforced shutdown, shutdown during a target veto, OTR profile close)
and a loopback mutual-TLS client-certificate host. The certificate host passes
`--ignore-certificate-errors-spki-list` for its per-run server key and the
test-only `--rearc-test-client-cert-dir=<src>/net/data/ssl/certificates`. That
memory ClientCertStore exists only in debug, non-official builds and needs
`--use-mock-keychain`; no Keychain identity is read. Set
`REARC_WAVE_LABEL` to name the network-audit file (default `w18h`).

Wave-18h final validation: build p106 / ABI 1.41 / bridge 0.43.0, 39 native
hosts / 49 process runs, G1–G5, ordinary and pending-prompt stress (4 processes /
16 tabs each), and an actually blocked-TCC shutdown all pass. All 49 native and
five smoke processes have no outside connection. The 13 legacy ABI 1.17 and
39 ABI 1.40 struct layouts, Swift imports, 110 framework exports and
4-host/6-process exact-1.17 compatibility run pass. Replay 60/60 matches HEAD
`e1bb6df2aa8ddf2255d24389c2533e0620a4e3ce`. See WAVE-18H-REPORT.md.

## 1. Known-good gate commands (CI-style runtime gate)

All of the following exit 0 with the **default sandbox** (no `--no-sandbox`
needed) in 7.5–19.1 s wall each (matrix avg 11.2 s). Use a fresh
`--user-data-dir` per run to stay hermetic; `timeout -k 5 45` is the watchdog.

```sh
CHROMIUM="engine/chromium/src/out/ReArc-dev-arm64/Chromium.app/Contents/MacOS/Chromium"
UDD="$(mktemp -d /tmp/rearc-gate.XXXXXX)"

# G1: browser-process boot + render, minimal page
timeout -k 5 45 "$CHROMIUM" --user-data-dir="$UDD" --headless \
  --dump-dom about:blank | grep -qi "<html"

# G2: render real markup
timeout -k 5 45 "$CHROMIUM" --user-data-dir="$UDD" --headless \
  --dump-dom 'data:text/html,<p>rearc</p>' | grep -q "<p>rearc</p>"

# G3: raster path (screenshot)
timeout -k 5 45 "$CHROMIUM" --user-data-dir="$UDD" --headless \
  --screenshot="$UDD/s.png" --window-size=800,600 about:blank
head -c4 "$UDD/s.png" | LC_ALL=C grep -qa PNG

# G4: print path (PDF)
timeout -k 5 45 "$CHROMIUM" --user-data-dir="$UDD" --headless \
  --print-to-pdf="$UDD/p.pdf" --no-pdf-header-footer about:blank
head -c4 "$UDD/p.pdf" | grep -q "%PDF"

# G5: overlay branding alive (patch 001 UA brand token)
timeout -k 5 45 "$CHROMIUM" --user-data-dir="$UDD" --headless \
  --dump-dom 'data:text/html,<script>document.write(navigator.userAgent)</script>' \
  | grep -q "HeadlessReArc/156"
```

Pass criteria: each command exits 0 inside the 45 s watchdog and its sanity
grep matches. G1–G4 prove browser-process boot + render; G5 proves the ReArc
overlay is the binary under test. Observed UA:
`Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessReArc/156.0.0.0 Safari/537.36`.

Note the `LC_ALL=C` on the PNG magic-byte check: BSD grep under a UTF-8
locale refuses to match across the `0x89` byte of the PNG signature and
false-negatives. (This bit the first version of the matrix harness itself.)

## 2. Matrix (72 cells, 45 s watchdog each)

Dimensions: headless mode {`--headless`, `--headless=old`, `--headless=shell`}
× GPU {default, `--disable-gpu`} × sandbox {default, `--no-sandbox
--disable-zygote`} × output {`--dump-dom`, `--screenshot`, `--print-to-pdf`}
× URL {`about:blank`, `data:text/html,<p>rearc</p>`}.

**Result: 72/72 exit 0, 0 timeouts, 0 invalid artifacts.** Wall time
min 7.5 s / max 19.1 s / avg 11.2 s. Sanity per cell: DOM contains expected
markup; PNG has valid signature and is 2727 B (blank) / 3655 B (data); PDF
has `%PDF` header and is 863 B (blank) / 7486 B (data). Identical artifact
sizes across all flag combinations — output is flag-independent, as expected.

| Group (mode × gpu × sandbox) | dom blank | dom data | shot blank | shot data | pdf blank | pdf data |
|---|---|---|---|---|---|---|
| new, gpu, sandbox | 0 / 7.5s | 0 / 10.7s | 0 / 9.7s | 0 / 11.7s | 0 / 11.8s | 0 / 14.9s |
| new, gpu, nosandbox | 0 / 9.7s | 0 / 10.7s | 0 / 10.7s | 0 / 11.8s | 0 / 10.7s | 0 / 13.8s |
| new, nogpu, sandbox | 0 / 8.7s | 0 / 11.8s | 0 / 9.7s | 0 / 10.7s | 0 / 10.7s | 0 / 13.8s |
| new, nogpu, nosandbox | 0 / 8.5s | 0 / 10.7s | 0 / 9.6s | 0 / 10.7s | 0 / 10.7s | 0 / 13.9s |
| old, gpu, sandbox | 0 / 8.5s | 0 / 10.6s | 0 / 9.7s | 0 / 10.7s | 0 / 10.7s | 0 / 13.9s |
| old, gpu, nosandbox | 0 / 8.6s | 0 / 10.8s | 0 / 9.7s | 0 / 10.7s | 0 / 10.7s | 0 / 12.7s |
| old, nogpu, sandbox | 0 / 8.6s | 0 / 10.6s | 0 / 9.7s | 0 / 10.7s | 0 / 10.7s | 0 / 12.8s |
| old, nogpu, nosandbox | 0 / 8.6s | 0 / 10.7s | 0 / 9.7s | 0 / 11.7s | 0 / 10.7s | 0 / 13.9s |
| shell, gpu, sandbox | 0 / 8.6s | 0 / 14.2s | 0 / 14.9s | 0 / 10.7s | 0 / 10.7s | 0 / 13.9s |
| shell, gpu, nosandbox | 0 / 8.5s | 0 / 11.8s | 0 / 9.7s | 0 / 11.8s | 0 / 10.7s | 0 / 16.2s |
| shell, nogpu, sandbox | 0 / 8.6s | 0 / 15.2s | 0 / 19.1s | 0 / 10.6s | 0 / 10.8s | 0 / 13.8s |
| shell, nogpu, nosandbox | 0 / 8.6s | 0 / 12.9s | 0 / 9.6s | 0 / 10.8s | 0 / 14.3s | 0 / 13.9s |

(Each cell is rc / wall. Full per-cell artifacts: `/tmp/rearc-smoke/cells/`;
TSV: `/tmp/rearc-smoke/results.fixed.tsv` — /tmp is ephemeral, regenerate
with the harness at `/tmp/rearc-smoke/matrix.sh` if needed.)

## 3. Hang analysis

No cell hung. No `sample` captures were needed (none exist — no process
reached the 45 s watchdog). The previous session's finding is confirmed and
extended from a probe to the full matrix: the historical wave-3 120 s
`--headless --dump-dom about:blank` hang **does not reproduce** at the
current 5-patch overlay HEAD.

**Root cause (one-liner):** the wave-3 hang was a partially-bridged P-APP-001
termination path — patch `app/002` had installed the `ReArcApplication`
NSApplication singleton (so Cocoa termination entry points routed through the
engine lifecycle host) before the wave-5 slices installed the matching
delegate/menu (`app/003`) and `DidEndMainMessageLoop` bridge finalization
(`app/004`); after the dump completed, the browser's main runloop therefore
never received its termination and the process sat idle in `-[NSApp run]`
until the watchdog. With 003+004 at HEAD the finalization path is complete
and every headless invocation exits cleanly. (Inference from the patch
record — the hang itself is no longer reproducible, so no live stack sample
exists.)

## 4. Overlay-vs-stock differences observed

* **Branding is live and headless-visible.** `chrome://version` (with
  `--allow-chrome-scheme-url`; headless otherwise redirects chrome:// to New
  Tab — stock M156 behavior, see `IsChromeSchemeUrlAllowed` in
  `chrome/browser/headless/headless_mode_util.cc`) renders **"ReArc
  156.0.8078.74"** (patch 002's folded `version_ui.cc` change), and the UA is
  `HeadlessReArc/156.0.0.0` (patch 001 brand token; "Headless" prefix is the
  stock headless UA marker).
* **ReArcApplication does not disturb headless.** Patch 002's
  `RegisterBrowserCrApp()` redirection instantiates the ReArcApplication
  singleton in headless mode too; all 72 cells behave stock. Consistent with
  the patch contract: with no lifecycle host registered, termination falls
  back to the AppController path.
* **`--headless=old` and `--headless=shell` are accepted but silently alias
  to new headless.** Old headless was removed upstream in M132; at this pin
  headless gating in the full binary is presence-based
  (`HasSwitch(switches::kHeadless)`), the switch *value* is not consulted,
  and `headless_shell` is a separate binary target that is not built in
  `out/ReArc-dev-arm64`. All three modes produce identical results — treat
  `old`/`shell` cells as duplicate coverage of new headless, not distinct
  modes. Stock expectation at M156, not an overlay effect.

## 5. Environmental notes (all benign; no workarounds required)

* **No seatbelt/TCC/launchd-context hangs.** Every cell passed with the
  **default sandbox** from a plain terminal session; `--no-sandbox
  --disable-zygote` is optional coverage, not a requirement. (`--disable-zygote`
  is a no-op on macOS.)
* `CVDisplayLinkCreateWithCGDisplay failed (CVReturn: -6670)` → viz falls
  back to `DelayBasedTimeSource`. Normal with no physical display driving
  headless; does not affect screenshots/PDF.
* `bootstrap_look_up org.chromium.Chromium.MachPortRendezvousServer.1:
  Permission denied` + `No rendezvous client, terminating process (parent
  died?)` appears only in teardown when the harness sweeps stray children
  with `pkill` — artifact of the harness, not the product.
* `objc: Class ANGLESwapCGLLayer / CrashpadHTTPBodyStreamTransport is
  implemented in both …` — duplicate-class warnings inherent to the component
  (shared-dylib) dev build; cosmetic.
* `code_sign_clone_manager: error removing quarantine attribute`,
  `trust_store_mac: Error parsing certificate`, OAuth client ID warning —
  stock first-run noise on a fresh `--user-data-dir`.
* First invocation against a cold profile costs ~2 s extra (one-time
  profile/GPU-cache init); matrix wall times include it.

## 6. Reproducing / extending

Harness (lives outside the tree, no src mutations):
`/tmp/rearc-smoke/matrix.sh` — per cell: build-gate check → fresh
`--user-data-dir` → background launch → 1 s poll → on 45 s timeout,
`sample <pid> 5` **before** TERM/KILL, then `pkill -f $UDD` sweep. Extend the
dimension loops in that script for new flags. If any future cell hangs, the
per-cell `sample.txt` and `tree.txt` land in
`/tmp/rearc-smoke/cells/<cell>/` — check whether the main thread is in the
runloop (termination-path regression), GPU service, zygote, or sandbox
before flagging a wave.
