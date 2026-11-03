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
        keychain: KeychainMode
    ) -> [String] {
        var result = arguments
        if !result.contains(where: { $0.hasPrefix(userDataDirFlag) }) {
            result.append(userDataDirFlag + defaultUserDataDir())
        }
        if keychain == .devMock, !result.contains(mockKeychainSwitch) {
            result.append(mockKeychainSwitch)
        }
        return result
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
