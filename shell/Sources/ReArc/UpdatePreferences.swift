import Foundation

struct UpdatePreferences {
    static let betaKey = "rearc.receiveBetaUpdates"

    static func allowedChannels(in defaults: UserDefaults) -> Set<String> {
        defaults.bool(forKey: betaKey) ? ["beta"] : []
    }
}
