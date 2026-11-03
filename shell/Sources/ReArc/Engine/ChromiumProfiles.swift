import Foundation
import SidebarModel

/// The engine profile a Chromium tab is created in (C-ABI.md "Profiles").
///
/// A shell `Profile` owns its Spaces, and every Space uses its profile's
/// storage, so each shell profile maps onto one named persistent engine
/// profile. A private window maps onto one off-the-record engine profile
/// under the persistent profile it was opened from. Engine profile IDs are
/// session-local and never persisted; only the storage key is stable.
enum ChromiumProfileKey: Hashable, CustomStringConvertible {
    case persistent(Profile.ID)
    /// One in-memory context per private session; `parent` is the persistent profile.
    case offTheRecord(session: UUID, parent: Profile.ID)

    /// An ephemeral context maps to the off-the-record profile of
    /// `privateSession`; every engine of one private session shares it.
    init(context: EngineProfileContext, privateSession: UUID) {
        if context.isEphemeral {
            self = .offTheRecord(session: privateSession, parent: context.profileID)
        } else {
            self = .persistent(context.profileID)
        }
    }

    var parentProfileID: Profile.ID {
        switch self {
        case .persistent(let id): return id
        case .offTheRecord(_, let parent): return parent
        }
    }

    var isOffTheRecord: Bool {
        if case .offTheRecord = self { return true }
        return false
    }

    /// `ReArcProfileOpen` name for a persistent profile: the lowercased shell
    /// profile UUID (36 ASCII characters, `[a-f0-9-]`).
    var storageKey: String? {
        guard case .persistent(let id) = self else { return nil }
        return Self.storageKey(for: id)
    }

    static func storageKey(for profileID: Profile.ID) -> String {
        profileID.uuidString.lowercased()
    }

    /// The engine's key rule: case-sensitive `[A-Za-z0-9_-]{1,64}`, never a path.
    static func isValidStorageKey(_ key: String) -> Bool {
        guard (1...64).contains(key.utf8.count) else { return false }
        return key.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F
        }
    }

    var description: String {
        switch self {
        case .persistent(let id): return "profile \(Self.storageKey(for: id))"
        case .offTheRecord(let session, let parent):
            return "private session \(session.uuidString.lowercased()) of \(Self.storageKey(for: parent))"
        }
    }
}

/// Profile teardown order. The engine refuses to close a parent while any
/// off-the-record child is alive (busy), so children close first, one at a
/// time, then the parent.
enum ChromiumProfileTeardown {
    static func closeOrder(for key: ChromiumProfileKey, among open: [ChromiumProfileKey]) -> [ChromiumProfileKey] {
        switch key {
        case .offTheRecord:
            return [key]
        case .persistent(let id):
            let children = open.filter { $0.isOffTheRecord && $0.parentProfileID == id }
            return children + [key]
        }
    }
}
