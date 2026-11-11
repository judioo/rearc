# ReArc macOS release build

How to produce a release-quality, hardened-runtime ReArc.app and DMG from this tree, what
was verified, and what only the account holder can do. Packaging background (branding,
helper IDs, Safe Storage naming) is in PACKAGING-MAC.md; the shell/engine linking contract
is in C-ABI.md, "Linking and startup".

Today the only missing input is a **Developer ID Application** certificate. Everything else
(engine, bundle, nested signing, entitlements, launch, self-test, DMG) is built and verified
with the Apple Development identity, which macOS accepts locally but Gatekeeper rejects for
distribution.

## Scripts (all in shell/scripts)

| Script | Does |
|---|---|
| `build-engine-release.sh` | Optimized non-component engine in `out/ReArc-release-arm64`. Same preflight as `engine/scripts/build.sh`; never touches `out/ReArc-dev-arm64`. `--gen-only` runs just `gn gen`. |
| `release.sh` | End to end from a built release engine: release shell build from committed HEAD, bundle, version stamp, nested signing, dSYMs, LaunchServices launch check, real-Keychain self-test, optional `--dmg`. Output `shell/dist/release`. |
| `bundle-chromium.sh` | Unchanged behavior for dev bundles. New: `--engine-out DIR` (same as `REARC_CHROMIUM_OUT`), and a monolithic engine build is accepted, with no dylib closure outside the bundle. Its build guard blocks only on a `siso ninja` of the out dir being bundled, so a release build no longer blocks dev bundles. |
| `sign-release.sh` | Inside-out signing of an assembled monolithic bundle with hardened runtime, secure timestamps and Chromium's per-role entitlements; verifies. |
| `make-dmg.sh` | Signed UDZO DMG: app, Applications link, volume icon, branded Finder background. |
| `notarize.sh` | `notarytool submit --keychain-profile rearc-notary --wait`, then `stapler staple`/`validate`. Refuses anything not Developer ID signed. **Not run yet.** |
| `release/BRANDING` | Release BRANDING input: the overlay's BRANDING. `build-engine-release.sh` appends `MAC_TEAM_ID` from `REARC_TEAM_ID` (environment or `shell/signing.local.env`) into `shell/.build-release/BRANDING`. |
| `release/entitlements/` | `app`, `helper-renderer`, `helper-gpu` entitlements, copied from `chrome/app/*-entitlements.plist` at the pin. |
| `release/VERSION` | ReArc marketing version (see Versioning). |
| `release/signing-env.sh` | Shared loader for `shell/signing.local.env`. Environment wins, and it never prints a value. |
| `release/dmg-background.swift` | Draws the DMG background (brand canvas and cobalt arrow). |

## Exact steps

```sh
# 0. Once: shell/signing.local.env has REARC_SIGN_IDENTITY, REARC_TEAM_ID and, for iCloud,
#    REARC_ICLOUD_CONTAINER + REARC_PROVISIONING_PROFILE (docs/ICLOUD-SETUP.md).
#    For distribution also REARC_RELEASE_IDENTITY="Developer ID Application: … (<TEAM_ID>)"
#    and REARC_RELEASE_PROVISIONING_PROFILE (a Developer ID profile, below).
# 1. Engine (3-4 h on first build, minutes incrementally). Start it when no other
#    `siso ninja` is active; it shows up in `pgrep -fl 'siso[ ]ninja'` while it runs.
shell/scripts/build-engine-release.sh
# 2. Commit the shell changes you want to ship, then:
shell/scripts/release.sh --dmg
# 3. With Developer ID only (never before):
shell/scripts/notarize.sh shell/dist/release/ReArc.app      # notarize + staple the app
shell/scripts/make-dmg.sh shell/dist/release/ReArc.app      # DMG from the stapled app
shell/scripts/notarize.sh shell/dist/release/ReArc-<version>.dmg
```

`release.sh --worktree` builds the uncommitted working tree for local testing; its
`ReArcSourceRevision` gets a `-dirty` suffix. Do not distribute such a build.

`release.sh --dmg` checks Chromiumdash's latest **Mac Stable and Extended Stable**
releases before packaging, and requires the engine output version to match
`engine/CHROMIUM_PIN`. The pin must be current on its supported milestone (156
currently uses Extended Stable); an unsupported milestone or unavailable release
data fails closed. `--allow-outdated-engine` explicitly bypasses the freshness
check with a prominent warning. It does not bypass the built-version check.

`release.sh --dmg` also refuses an engine built without a real Google API key, because
Safe Browsing cannot work without one (next section). `--allow-no-safe-browsing` makes the
DMG anyway and prints a loud warning. Such a build shows Safe Browsing as unavailable in
Settings › Privacy. Never distribute it to users.

## Safe Browsing key

Safe Browsing puts the build's Google API key (`google_apis::GetAPIKey()`) on every list
update and hash lookup. With no key Chromium sends `dummytoken`. Google answers that with
HTTP 400 `API_KEY_INVALID`, the threat lists never download, and phishing and malware pages
load with no warning. The release engine therefore needs ReArc's own key:

- It comes from ReArc's Google Cloud project, with the key restricted to the **Safe Browsing
  API** only. ReArc does not use Google sign-in: leave `google_default_client_id` and
  `google_default_client_secret` unset.
- It lives outside the repository, in `~/.config/rearc/google-api-keys.gn` (mode 600),
  as one line: `google_api_key = "AIza…"`. `REARC_GOOGLE_API_KEYS_FILE` points elsewhere,
  and a `google_api_key` environment variable overrides the file. Never commit the key or
  paste it into a log or report.
- `build-engine-release.sh` writes `out/ReArc-release-arm64/args.gn` (mode 600) and appends
  the key with `engine/scripts/google-api-keys.py append`. That script refuses a key file
  inside the repo and accepts only quoted credential assignments. It prints a warning,
  never the key, when no real key (`AIza` plus 35 characters) is configured. The build
  still runs.
- `release.sh --dmg` runs `google-api-keys.py check`: the engine's `google_api_key` GN arg
  must be a real key, and the release framework must contain it. Otherwise it stops
  unless `--allow-no-safe-browsing` is given.
- At run time the shell asks the engine (`ReArcEngineSafeBrowsingAvailable`, ABI 1.57).
  Dev engines (`engine/scripts/build.sh`) are built without a key, so they show Safe
  Browsing as unavailable, like any keyless build.

The key passes to the compiler as a define on `google_apis` compiles only, so it appears in
the local `out/ReArc-release-arm64` build files and compiler command lines, which are never
committed. Filter `AIza` out of anything copied from a build log.

## Engine build

`out/ReArc-release-arm64` args (`gn args --list --short --overrides-only`):

```
target_os="mac" target_cpu="arm64" is_chrome_branded=false is_official_build=false
use_system_xcode=true use_remoteexec=false use_siso=true chrome_pgo_phase=0 disable_fieldtrial_testing_config=true
symbol_level=1 treat_warnings_as_errors=false
is_debug=false is_component_build=false dcheck_always_on=false
enable_dsyms=true enable_stripping=true
branding_file_path="<repo>/shell/.build-release/BRANDING"   (generated, carries MAC_TEAM_ID)
google_api_key="…"   (appended from ~/.config/rearc/google-api-keys.gn, "Safe Browsing key")
```

`disable_fieldtrial_testing_config=true` is required. Without it an unbranded build runs
Chromium's bot configuration, which switches on hundreds of unlaunched features. One of them
moves Safe Browsing to the v5 list protocol, which Google answers with 404 for our key, so no
threat list ever arrives (security review of 544, F-02 and N-01). `release.sh --dmg` refuses an
engine whose `gen/components/variations/service/buildflags.h` has the testing config on.


- These are the dev args, which set no other branding arguments, with the release
  changes. `engine/scripts/build.sh --release` cannot be used because its fixed argument
  set lacks `dcheck_always_on=false` (non-official builds default DCHECKs on,
  `build/config/dcheck_always_on.gni`) and `branding_file_path`. PACKAGING-MAC.md says a
  production pipeline must supply its own complete GN configuration.
- `is_component_build=false` gives a monolithic `Chromium Framework` with no
  `libchrome_dll.dylib` and no 500+ dylib closure. `Libraries/` keeps only the GL/Vulkan
  dylibs that Chromium always ships there.
- `symbol_level=1` with `enable_dsyms` and `enable_stripping`: line tables go into
  `*.dSYM` (copied to `dist/release/symbols/`), and the shipped binaries are stripped. This
  is what official builds do for symbols, without the rest of `is_official_build`.
- **Not `is_official_build`.** PACKAGING-MAC.md does not require it. On Mac it turns on
  ThinLTO and the official-build optimizations, which would take many hours on this 10-core
  machine, and expects PGO profiles (`chrome_pgo_phase`). It also selects Google
  official-build behavior that this unbranded overlay neither needs nor has validated.
  `is_debug=false` already gives `NDEBUG`, which is what the overlay's test-only code keys on.
  Revisit for performance tuning, not correctness.
- `MAC_TEAM_ID=<TEAM_ID>` is compiled into `MAC_TEAM_IDENTIFIER_STRING`, which Chromium
  uses for keychain access groups (WebAuthn, payments, device trust). The dev BRANDING
  leaves it empty. Developer ID certificates belong to the same Individual team, so the
  value does not change when that certificate arrives. The bundle ID stays
  `com.rearc.browser` (the script refuses a mismatch with the overlay's BRANDING).
- **Client-certificate test store**: `rearc_client_cert_test_store.cc` is guarded by
  `#if !defined(NDEBUG) && !defined(OFFICIAL_BUILD)` (WAVE-18H-REPORT.md). The release
  build defines `NDEBUG`, so it compiles to the empty `InstallTestClientCertStore` stub.
  Verified in R1: `obj/chrome/browser/core/rearc_client_cert_test_store.o` defines only
  `rearc::InstallTestClientCertStore(Profile*)`, and the
  `rearc-test-client-cert-dir` switch string is absent from the release framework.
- **Release-only defect fixed in overlay patch tab/060**
  (`tab/060-release-framework-exports.patch`, overlay commit `f511949e6b`). A
  non-component framework exports only what `chrome/app/framework.exports` lists. Waves
  after tab/018 added ABI functions to the header without listing most of them, so the
  first release framework exported 52 of the 110 header functions, and the release shell
  could not link against it. Component builds export everything from
  `libchrome_dll.dylib`, which hid the gap. tab/060 adds the 58 missing functions to
  `framework.exports` and to `framework.order` before `_ChromeMain`, so
  `verify_chrome_framework_order` still passes. Replay: `REPLAY PASS 61/61` reverse and
  forward (`engine/replay-r1.log`). `build-engine-release.sh` now fails if any function
  declared in `rearc_engine_abi.h` or `rearc_engine_entry_mac.h` is missing from
  `nm -gU` of the framework. **When adding an ABI function, add it to both files.**
- First build: 12,098 s (3 h 22 min) on 10 cores with other agents active
  (`engine/build-release-r1.log`). The tab/060 relink took 122 s.

## Signing

`sign-release.sh` mirrors `chrome/installer/mac/signing/parts.py` at the pin, inside-out:

| Code object | Options | Entitlements |
|---|---|---|
| `Libraries/*.dylib` | none (library) | none |
| `Chromium Helper (Renderer).app`, `(Aperitif Renderer)` | `restrict,kill,runtime` | `helper-renderer` (allow-jit) |
| `Chromium Helper (GPU).app`, `(Aperitif GPU)` | `restrict,kill,runtime` | `helper-gpu` (allow-jit) |
| `Chromium Helper.app`, `(Aperitif)`, `(Alerts)`, `(Aperitif Alerts)` | `restrict,library,runtime,kill` | none |
| `chrome_crashpad_handler`, `app_mode_loader`, `web_app_shortcut_copier` | `restrict,library,runtime,kill` | none |
| `Chromium Framework.framework` | none (framework) | none |
| `ReArc.app` (identifier `com.rearc.browser`) | `restrict,library,runtime,kill` | `app` + iCloud (below) |

- Each signature gets `--timestamp` (Apple's timestamp server). `REARC_TIMESTAMP=none`
  is for offline signing only, and notarization rejects it.
- JIT helpers are signed without `library`: Chromium does the same, because library
  validation conflicts with the JIT entitlement there. All code is signed by the same team,
  so library validation in the other processes passes.
- **Renderer entitlements**: at this pin Chromium's renderer and GPU helpers carry only
  `com.apple.security.cs.allow-jit`. V8 allocates JIT pages with `MAP_JIT`.
  `allow-unsigned-executable-memory` was dropped upstream and is **not** added, because it
  would weaken the hardened runtime for no gain. The self-test loads and runs JavaScript in
  hardened-runtime renderers with only allow-jit (Verification). Add it only if a renderer
  is ever killed with a code-signing exception.
- The app entitlements are Chromium's `app-entitlements.plist` (camera, microphone,
  Bluetooth, print, USB, location, photos). That is a superset of
  `scripts/ReArc.entitlements`, and the usage strings stay in Info.plist. With
  `REARC_ICLOUD_CONTAINER`, `icloud_prepare` (icloud-signing.sh) merges in
  application-identifier, team-identifier, the iCloud container, CloudKit and, when the
  profile allows it, `icloud-container-environment`. It also embeds the profile and the
  `ReArcICloudContainer` marker. `REARC_RELEASE_PROVISIONING_PROFILE` takes precedence over
  the development `REARC_PROVISIONING_PROFILE`.
- The script refuses component bundles, ad-hoc identities and any Mach-O it does not sign
  on purpose. It checks the team, timestamp and runtime flag on every object it signed, and
  allow-jit on the renderer and GPU helpers. Then it runs `codesign --verify --deep --strict`
  and prints `spctl -a -vv`.
- The Safe Storage Keychain item ("ReArc Safe Storage" / "ReArc") trusts the designated
  requirement: identifier `com.rearc.browser` plus the signing certificate. A release
  bundle signed with the same Apple Development identity matches the item that the
  development iCloud bundle created, so it does not prompt. After the switch to Developer
  ID, the requirement changes, and macOS asks once on first launch ("Always Allow"). Users
  of a distributed build only ever see the Developer ID requirement.

## Versioning

- `CFBundleShortVersionString` = `shell/scripts/release/VERSION`, semantic
  `MAJOR.MINOR.PATCH` (starts at 0.1.0). Bump it in a commit before each release.
- `CFBundleVersion` = `git rev-list --count HEAD` of the outer repo. It increases with
  every commit on the release branch, which is what LaunchServices and Sparkle compare.
  Cut releases from one branch (main).
- `ReArcEngineVersion` = the Chromium version (156.0.8078.96), `ReArcEngineRevision` = the
  overlay commit, `ReArcSourceRevision` = the outer commit (`-dirty` for `--worktree`).
- The framework keeps `Versions/156.0.8078.96` and its own plist. Never rename it.
- Constraint: Chromium's upgrade detector (`updater::CurrentlyInstalledVersion`) compares
  the outer `CFBundleShortVersionString` with the running Chromium version and reports an
  update only when the outer one is **higher**. Keep the ReArc version below the Chromium
  major (156) and this stays inert. Crash reports (crashpad `ver`) carry the ReArc version.
- DMG name: `ReArc-<CFBundleShortVersionString>.dmg`.

## Release notes

`RELEASES.md` at the repo root records every distributed build, newest first. Each entry is
headed `## ReArc <VERSION> (<build>) — <YYYY-MM-DD>` and lists, for ReArc's users, all the
features and fixes since the previous release. `release.sh --dmg` (and `--appcast`) stops
before building when the committed `RELEASES.md` at HEAD lacks the heading for the build
being made.

The build number is the commit count, so the notes commit has to carry its own number. Add
the entry as the last commit before the release, numbered
`$(( $(git rev-list --count HEAD) + 1 ))`, and build from that commit.

## Verification (this machine, Apple Development identity)

R1 run: shell HEAD `667658d9`, overlay `f511949e6b`, version 0.1.0 (98).
Logs are in `shell/dist/release/` (`sign-release.log`, `selftest-release*.log`) and
`shell/dist/release-r{1,2}.log`.

| Check | Result |
|---|---|
| `codesign --verify --deep --strict --verbose=2 ReArc.app` | **pass**: valid on disk, satisfies its Designated Requirement. Sixteen code objects, each with team <TEAM_ID> and a secure timestamp. |
| Flags | app, Helper, Alerts, crashpad: `kill,restrict,library-validation,runtime`. Renderer, GPU: `kill,restrict,runtime` + allow-jit. |
| App entitlements | Chromium app set + `<TEAM_ID>.com.rearc.browser`, `iCloud.com.rearc.browser`, CloudKit, environment Development (development profile) |
| `spctl -a -vv -t exec ReArc.app` | `rejected` / `origin=Apple Development: <Your Name> (<CERT_ID>)`, as expected without Developer ID and notarization |
| `spctl -a -t open --context context:primary-signature -vv ReArc-0.1.0.dmg` | `rejected` / `origin=Apple Development: <Your Name> (<CERT_ID>)`, as expected |
| `check-launch.sh` (LaunchServices `open`, plain and with a link) | **PASS**: `ready=1 engine=chromium source=infoPlist abi_minor=41`, GetURL link delivered, no crash reports |
| Self-test, real Keychain (`--rearc-selftest`, no `--use-mock-keychain`) | `keychain: macOS Keychain ('ReArc Safe Storage')`, **no prompt and no stall**. Ninety-seven PASS lines in about 70 s, including page script evaluation in hardened-runtime renderers with only allow-jit. **RESULT FAIL, 1 failure:** `timed out waiting for ⌥⌘I closed the frontend tab`. See below. |
| `notarize.sh ReArc-0.1.0.dmg` | Refuses before any network call: "not signed with a Developer ID Application certificate" |
| DMG | UDZO, 160 MB, signed; app inside verifies; Applications link, custom volume icon, Retina background and Finder layout |

**Self-test failure: a shell bug, not a release defect.** A dev bundle (component, debug,
mock Keychain) built from the same HEAD fails the same step in the same way. No earlier
wave-28 dev run reached it, because those runs timed out sooner under the release build's
load. Release runs 2 and 3 failed earlier, at the omnibox step, with a stale row from the
previous query (`suggestion row nav suggestion one`). That is a race in the shell
self-test. Probable cause of the DevTools failure:
`BrowserViewModel.closeDevTools` closes the frontend tab only through
`ChromiumEngine.deinit` (`devToolsEngines[tabID] = nil`). The self-test, and possibly the
docked view, still holds a reference (`let frontend`), so the tab never closes. The
shell's owner should close the frontend explicitly and fix the suggestion race. Then the
release self-test is expected to pass, since every engine-backed step before it does.

Size and launch, release vs a dev bundle of the same HEAD:

| | Release (`dist/release`) | Dev (component, debug) |
|---|---|---|
| ReArc.app | 382 MB, self-contained | 191 MB app + 518 dylibs (6.6 GB) outside the bundle, 7.1 GB total |
| Chromium Framework binary | 256 MB, stripped | reexport stub + `libchrome_dll.dylib` and closure |
| Shell executable | 20.7 MB | 30.2 MB |
| DMG | 160 MB | — |
| dSYMs (`dist/release/symbols`, not shipped) | 2.0 GB (16, incl. ReArc.dSYM) | — |
| LaunchServices probe (launch → ready → shutdown), 2 runs | 4.6 s, 4.6 s | 8.2 s, 7.2 s |
| Self-test to the DevTools step | ~70 s | ~160 s |
| `release.sh` with a built engine | 125–146 s to a signed bundle | — |

## What the account holder must do

1. **Developer ID Application certificate**: in Xcode → Settings → Accounts → Manage
   Certificates → "+" → Developer ID Application, or on developer.apple.com →
   Certificates. Only the Account Holder of team <TEAM_ID> can create it. It then shows up
   in `security find-identity -v -p codesigning`. Put
   `REARC_RELEASE_IDENTITY="Developer ID Application: <name> (<TEAM_ID>)"` in
   `shell/signing.local.env`.
2. **Notary credentials**, stored in your keychain (never in a file in this repo):
   `xcrun notarytool store-credentials rearc-notary --apple-id <apple-id> --team-id <TEAM_ID>`,
   with an app-specific password from appleid.apple.com. `notarize.sh` only names the
   profile.
3. **iCloud for distribution**:
   - Before **every release**, import `shell/cloudkit/schema.ckdb` into
     **Development**, then deploy the schema to **Production** for
     `iCloud.com.rearc.browser`. From the repo root:
     `xcrun cktool import-schema --team-id <TEAM_ID> --container-id iCloud.com.rearc.browser --environment development --validate --file shell/cloudkit/schema.ckdb`.
     Or use CloudKit Console > Development > Schema > Import Schema, then
     Deploy Schema Changes to Production. Export/back up the current schema
     first and review changes (docs/ICLOUD-SETUP.md §7). Confirm all five types,
     especially `SidebarBoostRecord` and `SidebarSpaceStyleRecord`, plus encrypted
     payload and the six integer indexes per type. A just-in-time Development
     schema can omit types the developer's profile never saved; importing the
     committed file is mandatory even when that Mac already syncs successfully.
     Distributed builds cannot create missing types or fields in Production.
   - Create a **Developer ID provisioning profile** for App ID `com.rearc.browser` with
     iCloud/CloudKit and the container. Developer ID profiles list no devices. Set
     `REARC_RELEASE_PROVISIONING_PROFILE=<path>` and `REARC_ICLOUD_ENVIRONMENT=Production`.
     The development profile only runs on registered Macs.
4. Run the exact steps above. `spctl -a -vv` must then report
   `source=Notarized Developer ID`. Test on a clean Mac or user account: first launch from
   the DMG, the Keychain prompt for Safe Storage, camera/microphone/location TCC prompts,
   and iCloud sign-in.

## Known limits

- No universal (x64) build: run
  `build-engine-release.sh --target-cpu=x64` into its own out dir. Lipo/universal packaging
  is not scripted.
- No clean-machine test has been done yet. That needs the notarized build.
- **Build into a normal folder, not an agent's `/private/tmp/claude-*` scratchpad.** On
  2026-11-10 release candidate 481 failed `check-launch.sh` with "the probe did not shut down
  cleanly" and `Teardown watchdog expired` in the probe log. The code was not at fault: the
  same signed bundle passed once copied to `~/Library/Caches`. Copies of the shipped build 476
  passed from `$TMPDIR`, `shell/dist` and a 303-character path, and failed the same way in the
  scratchpad. In that tree Little Snitch
  reported the helpers as having "no code signature", did not apply ReArc's existing rule,
  and held the network service's connections behind a connection alert. DNS got no answer,
  and at shutdown each `close()` of a held UDP socket blocked in the kernel content filter
  for about 3 s. So the network process outlived the 10 s that
  `BrowserProcessIOThread::ProcessHostCleanUp` waits for it, and the 10 s teardown watchdog
  fired first. If the watchdog fires, look for a pending firewall alert and sample the
  network-service helper before suspecting the engine.


## Sparkle updates (DMG distribution)

The Chromium shell pins Sparkle **2.10.1** exactly in SwiftPM. WebKit builds have no
Sparkle dependency. Only bundles stamped `ReArcRelease = YES` by `bundle-chromium.sh
--release` start the updater or show its menu/settings. ReArc ships outside the Mac
App Store as a Developer ID signed, notarized DMG.

Release packaging stamps `SUFeedURL` from `REARC_APPCAST_URL` (default
`https://rearc.imara.ae/updates/appcast.xml`, the alpha host), `SUPublicEDKey` from
`shell/scripts/release/sparkle-public-key.txt`, automatic checks/download/install defaults
on, and a daily (86400 second) check interval. The feed URL is fixed in each build, so
installed copies only ever look there: keep serving `appcast.xml` at that address, or ship
an update whose `SUFeedURL` points at the new host before moving (for example to
rearc.net). The download URL prefix for generated enclosures is `REARC_UPDATE_DOWNLOAD_URL`
(default `https://rearc.imara.ae/updates/`); set both when using another host.

Sparkle compares appcast `sparkle:version` against **CFBundleVersion**, the increasing
commit count; `sparkle:shortVersionString` is display only. Keep release history linear
and never reuse a build number. Rollback means rebuilding the old code with a **higher
build number**, then publishing it as a new release, never serving a downgrade.

### Keychain and preparing archives

The EdDSA private key was created with Sparkle's `generate_keys --account ReArc`. It lives
only in this Mac's login Keychain; `generate_keys --account ReArc` reuses it. To retrieve
only the public key, use `generate_keys --account ReArc -p`. Never use `-x`, put private
key material in files/environment variables, or commit it. Losing this Keychain item
requires planning a key rotation before signing further updates.

Download the [2.10.1 distribution](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1)
and set `REARC_SPARKLE_TOOLS` to its `bin` directory. The helper verifies that the
Keychain public key matches the committed public key before generating signatures.

```sh
# Local development signing verification, no launch and no notarization:
REARC_SPARKLE_TOOLS=/path/to/Sparkle-2.10.1/bin \
  shell/scripts/release.sh --dist /tmp/rearc-release --no-verify \
  --appcast /tmp/rearc-updates --channel beta

# Distribution, ONLY after Developer ID + notary profile setup:
REARC_SPARKLE_TOOLS=/path/to/Sparkle-2.10.1/bin \
  shell/scripts/release.sh --dist /path/to/release --notarize \
  --appcast /path/to/update-archives
```

`--appcast DIR` implies `--dmg`, copies a version/build-named DMG into the persistent
archive directory, then runs `generate_appcast --account ReArc`. Keep this directory
outside `--dist`, which packaging replaces. `--channel beta` affects newly generated
items; stable releases omit it. No command uploads. `--notarize` first notarizes/staples
the app, makes the DMG, notarizes/staples the DMG, then generates the appcast. Any failure
stops the pipeline. Without that flag, notarization is never attempted. If notarizing
manually, finish it before generating the appcast: stapling changes the signed archive.
For example, after `notarize.sh /path/ReArc.dmg` succeeds, copy that final DMG into the
archives directory and run `shell/scripts/release/generate-appcast.sh DIR [beta]`.

Upload the final DMG, appcast.xml, release notes and generated delta files to their HTTPS
locations yourself. Do not upload `old_updates/`. The Apple Development test artifacts
are not distributable: obtain a Developer ID Application certificate and configure
`rearc-notary` (or `REARC_NOTARY_PROFILE`) first.

### Appcast policy examples

Use the following XML within an RSS feed declaring
`xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"`. Let
`generate_appcast` produce real enclosure signatures and lengths; the placeholders below
must be replaced. Each example below is an independent item policy, not a combined policy.
See Sparkle's [publishing guide](https://sparkle-project.org/documentation/publishing/).

A normal item (build 500, display version 0.2.0):

```xml
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ReArc</title>
    <item>
      <title>ReArc 0.2.0</title>
      <sparkle:version>500</sparkle:version>
      <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
      <pubDate>Mon, 09 Nov 2026 12:00:00 +0000</pubDate>
      <enclosure url="https://rearc.net/updates/ReArc-0.2.0-500.dmg"
                 sparkle:edSignature="REPLACE_WITH_GENERATED_SIGNATURE"
                 length="REPLACE_WITH_BYTE_LENGTH" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
```

Add one of these directly under `<item>` (alongside version/enclosure):

```xml
<!-- Critical for every older build: prompt promptly; no Skip button. -->
<sparkle:criticalUpdate/>
```

```xml
<!-- Critical only for installed builds below 450 (exclusive). -->
<sparkle:criticalUpdate sparkle:version="450"/>
```

```xml
<!-- Installed builds below 450 require the update UI, even with auto-download on. -->
<sparkle:minimumAutoupdateVersion>450</sparkle:minimumAutoupdateVersion>
```

```xml
<!-- Seen by users who enable Receive beta updates (stable remains eligible too). -->
<sparkle:channel>beta</sparkle:channel>
```

```xml
<!-- Seven rollout groups, one day between groups; pubDate is required. -->
<pubDate>Mon, 09 Nov 2026 12:00:00 +0000</pubDate>
<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>
```

```xml
<!-- Show a website action instead of installing, for all installed builds. -->
<sparkle:informationalUpdate/>
<link>https://rearc.net/updates/important-notice</link>
```

```xml
<!-- Informational only for builds below 450; other builds can install enclosure. -->
<sparkle:informationalUpdate>
  <sparkle:belowVersion>450</sparkle:belowVersion>
</sparkle:informationalUpdate>
<link>https://rearc.net/updates/important-notice</link>
```

Critical updates bypass phased rollout; manual checks also bypass rollout. Critical does
not forcibly terminate the browser or defeat user consent: Sparkle removes skipping and
uses prominent reminders. ReArc defers ordinary scheduled update alerts to the menu's
“Update Available…” / “1 update” badge, but leaves critical alerts to Sparkle. Automatic
downloads install on quit when eligible; Sparkle may remind a long-running app after its
impatient interval. `minimumAutoupdateVersion` requires UI below the threshold; it does
not establish a minimum supported build or force installation. Beta opt-in is stored in
UserDefaults and supplied by `allowedChannels(for:)` on subsequent checks.

Signing follows Sparkle's [manual signing recipe](https://sparkle-project.org/documentation/sandboxing/):
Installer.xpc, Downloader.xpc, Autoupdate, Updater.app, then Sparkle.framework, all with
hardened runtime and secure timestamps and no inherited development entitlements. Both
XPC services remain sealed but their sandbox-only opt-in keys are unset (ReArc is not
sandboxed). The release signer rejects `get-task-allow`, unexpected executables, missing
team/timestamps/runtime flags, and finishes with `codesign --verify --deep --strict`.
