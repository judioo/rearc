import Foundation

/// Browser-process argv for `ReArcEngineRun`.
///
/// `--use-mock-keychain` makes Chromium encrypt cookies and other Safe Storage
/// data with a fixed in-process key instead of the macOS Keychain item: stored
/// cookies are then effectively unencrypted. It exists only so ad-hoc signed
/// development bundles (whose executable identity changes on every build) do
/// not stall first loads and shutdown on Keychain authorization. It is enabled
/// only by `scripts/bundle-chromium.sh --dev-mock-keychain`, which writes
/// `ReArcDevUseMockKeychain` into a debug bundle's Info.plist, and is refused
/// in release builds of the shell even if the key is present.
enum ChromiumLaunchArguments {
    static let userDataDirFlag = "--user-data-dir="
    static let profileDirectoryFlag = "--profile-directory="
    static let mockKeychainSwitch = "--use-mock-keychain"
    static let devMockKeychainInfoKey = "ReArcDevUseMockKeychain"
    /// Engine features that must stay on in every build. Builds 500 to 564 ran Chromium's
    /// field-trial testing config, which switched these on and recorded that in each profile's
    /// keyword database. With the mark present and the feature off, Chromium treats the profile
    /// as rolled back and aborts while loading search engines (build 602 did, on every profile
    /// an earlier build had made). Never remove a feature from this list.
    static let persistedProfileFeatures = "--enable-features=PrepopulatedEnginesMigration,ApplySearchEngineTypeMigration"

    enum KeychainMode: Equatable {
        /// The macOS Keychain ("Chromium Safe Storage"); the only production mode.
        case system
        /// Development bundle opted in to Chromium's mock keychain.
        case devMock
        /// The bundle requested the mock keychain but this is a release build.
        case devMockRefused
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func keychainMode(infoDictionary: [String: Any]?, isDebugBuild: Bool) -> KeychainMode {
        guard infoDictionary?[devMockKeychainInfoKey] as? Bool == true else { return .system }
        return isDebugBuild ? .devMock : .devMockRefused
    }

    static func browserArguments(
        _ arguments: [String],
        defaultUserDataDir: () -> String,
        keychain: KeychainMode,
        isRelease: Bool = Bundle.main.object(forInfoDictionaryKey: "ReArcRelease") as? Bool == true
    ) -> [String] {
        var result = isRelease ? releaseArguments(arguments) : arguments
        if !result.contains(where: { $0.hasPrefix(userDataDirFlag) }) {
            result.append(userDataDirFlag + defaultUserDataDir())
        }
        if keychain == .devMock, !result.contains(mockKeychainSwitch) {
            result.append(mockKeychainSwitch)
        }
        return result
    }

    /// LaunchServices arguments are untrusted in shipping bundles. Only profile
    /// selection crosses this boundary; feature switches and test fixtures are
    /// appended by shell code after filtering, never accepted from argv.
    static func releaseArguments(_ arguments: [String]) -> [String] {
        var result = Array(arguments.prefix(1))
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            for prefix in [userDataDirFlag, profileDirectoryFlag] {
                if argument.hasPrefix(prefix), argument.count > prefix.count {
                    result.append(argument)
                } else if argument == String(prefix.dropLast()), index + 1 < arguments.count,
                          !arguments[index + 1].isEmpty, !arguments[index + 1].hasPrefix("-") {
                    index += 1
                    result.append(prefix + arguments[index])
                    break
                }
            }
            index += 1
        }
        return result
    }

    /// Self-test only, never the product: Chromium hides the pages of occluded
    /// windows and backgrounds their renderers (lower process priority, timer
    /// throttling). A run launched from a terminal leaves the app inactive with
    /// its windows occluded or the screen locked; under machine load a
    /// backgrounded renderer then answered trivial evaluations in about 2 s
    /// instead of under 10 ms, and the 3 s evaluation deadline failed
    /// intermittently. These switches keep self-test pages foreground.
    static let selfTestForegroundSwitches = [
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding",
        "--disable-background-timer-throttling",
    ]

    /// Self-test only: Chromium's manual Safe Browsing hash blocklist names
    /// the fixture's inert download (65536 bytes of "a"), so it arrives as
    /// dangerous content for Keep and Discard (engine/tests/run_c_abi.py
    /// "danger"). Nothing opens or runs the file.
    static let selfTestDangerousDownloadSize = 65536
    static let selfTestDangerousDownloadSHA256 = "bf718b6f653bebc184e1479f1935b8da974d701b893afcf49e701f3e2f9f9c5a"
    static var selfTestDangerSwitch: String {
        "--safebrowsing-manual-download-blacklist=" + selfTestDangerousDownloadSHA256
    }

    /// Self-test only: the PiP fixture's video plays with sound without a user
    /// gesture (synthesized clicks cannot activate a page while the app is inactive).
    static let selfTestAutoplaySwitch = "--autoplay-policy=no-user-gesture-required"

    /// Self-test only (engine/tests NO_OUTSIDE_NETWORK, wave 18f): no
    /// background services, and every non-loopback name fails to resolve, so
    /// the run reaches no outside service (Google or otherwise). The leak
    /// check is also turned off by the test before any sign-in.
    static let selfTestNoOutsideNetworkSwitches = [
        "--disable-background-networking",
        "--disable-component-update",
        "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost",
    ]

    /// Self-test only: Chromium shows autofill suggestions only while the
    /// tab's view has focus in a key window; a run from a terminal often
    /// cannot make its window key (as in engine/tests autofill).
    static let selfTestAutofillFocusSwitch = "--disable-features=RWHVMacHasFocusReturnsFalseForNonKeyWindow"

    /// `extensionDirs`: the self-test's local unpacked fixtures (`--load-extension`).
    static func selfTestArguments(_ arguments: [String], extensionDirs: [String] = []) -> [String] {
        var extra = selfTestForegroundSwitches + [selfTestDangerSwitch, selfTestAutoplaySwitch]
            + selfTestNoOutsideNetworkSwitches + [selfTestAutofillFocusSwitch]
        if !extensionDirs.isEmpty { extra.append("--load-extension=" + extensionDirs.joined(separator: ",")) }
        return arguments + extra.filter { !arguments.contains($0) }
    }

    /// `--rearc-bench`: only the no-outside-network switches. Never the
    /// foreground switches (a user's pages background and throttle), never
    /// the self-test's danger, autoplay or focus switches.
    static func benchArguments(_ arguments: [String]) -> [String] {
        arguments + selfTestNoOutsideNetworkSwitches.filter { !arguments.contains($0) }
    }

    /// Secure DNS off in a fresh self-test profile: automatic DoH dials its
    /// resolver's IP literal, which resolver rules cannot map (wave 18f).
    static func prepareSelfTestUserDataDir(_ directory: URL) {
        let localState = directory.appendingPathComponent("Local State")
        guard !FileManager.default.fileExists(atPath: localState.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(#"{"dns_over_https":{"mode":"off"}}"#.utf8).write(to: localState)
    }

    /// The `--user-data-dir` the engine runs with (last occurrence wins, as in Chromium).
    static func userDataDir(in arguments: [String]) -> String? {
        arguments.last { $0.hasPrefix(userDataDirFlag) }.map { String($0.dropFirst(userDataDirFlag.count)) }
    }

    /// The startup profile directory: `ReArcEngineRun` adds
    /// `--profile-directory=Default` unless one was supplied.
    static func startupProfileDirectory(in arguments: [String]) -> String {
        arguments.last { $0.hasPrefix(profileDirectoryFlag) }
            .map { String($0.dropFirst(profileDirectoryFlag.count)) } ?? ChromiumProfileStorageMap.defaultDirectory
    }
}
