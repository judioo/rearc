import Foundation

struct UpdatePreferences {
    static let betaKey = "rearc.receiveBetaUpdates"

    static func allowedChannels(in defaults: UserDefaults) -> Set<String> {
        defaults.bool(forKey: betaKey) ? ["beta"] : []
    }
}

struct UpdateMenuState: Equatable {
    var updateAvailable = false
    var title: String { updateAvailable ? "Update Available…" : "Check for Updates…" }
    var badgeCount: Int { updateAvailable ? 1 : 0 }
}
