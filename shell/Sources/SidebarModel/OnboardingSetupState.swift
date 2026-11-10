import Foundation

/// Only an explicit “Onboard later” opts into the reminder. No deferred
/// marker means either onboarding is pending, completed, or predates it.
public enum OnboardingSetupState: String, Codable, Equatable, Sendable {
    case notDeferred
    case deferred
    case dismissed

    public var showsCard: Bool { self == .deferred }
    public var showsMenuItem: Bool { self != .notDeferred }
}
