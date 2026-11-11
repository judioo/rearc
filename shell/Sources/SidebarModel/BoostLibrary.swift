import Foundation
import CryptoKit

public enum BoostSpacePolicy: String, Codable, Equatable, Sendable {
    case inherit
    case forceOn
    case forceOff
}

public struct BoostInstallation: Codable, Equatable, Hashable, Sendable {
    public var packageID: UUID
    public var enabled: Bool
    public var order: Int
    public var allowPrivate: Bool
    public var spacePolicy: [Space.ID: BoostSpacePolicy]

    public init(
        packageID: UUID,
        enabled: Bool = true,
        order: Int,
        allowPrivate: Bool = false,
        spacePolicy: [Space.ID: BoostSpacePolicy] = [:]
    ) {
        self.packageID = packageID
        self.enabled = enabled
        self.order = order
        self.allowPrivate = allowPrivate
        self.spacePolicy = spacePolicy
    }
}

public struct ProfileBoostLibrary: Codable, Equatable, Sendable {
    public var profileID: Profile.ID
    public var masterEnabled: Bool
    public var packages: [BoostPackage]
    public var installations: [BoostInstallation]
    /// Per-device consent. Never included in sync records or exported packages.
    /// Optional so snapshots written before script approvals still decode.
    public var approvedScriptHashes: [UUID: String]?
    /// Per-device consent for each boost's CSS and host rules, like `approvedScriptHashes`:
    /// CSS that arrives through sync, new or changed, applies only once approved here
    /// (security RC-0.1.0-544 N-02). Optional so older snapshots decode; nil adopts what
    /// this Mac already applies.
    public var approvedStyleHashes: [UUID: String]?

    public init(
        profileID: Profile.ID,
        masterEnabled: Bool = true,
        packages: [BoostPackage] = [],
        installations: [BoostInstallation] = []
    ) {
        self.profileID = profileID
        self.masterEnabled = masterEnabled
        self.packages = packages
        self.installations = installations
        self.approvedScriptHashes = [:]
        self.approvedStyleHashes = [:]
    }

    public func package(id: UUID) -> BoostPackage? {
        packages.first { $0.manifest.id == id }
    }

    public func installation(for packageID: UUID) -> BoostInstallation? {
        installations.first { $0.packageID == packageID }
    }

    public mutating func upsertPackage(_ package: BoostPackage, installation: BoostInstallation) {
        if let idx = packages.firstIndex(where: { $0.manifest.id == package.manifest.id }) {
            packages[idx] = package
        } else {
            packages.append(package)
        }
        if let idx = installations.firstIndex(where: { $0.packageID == installation.packageID }) {
            installations[idx] = installation
        } else {
            installations.append(installation)
        }
    }

    public mutating func removePackage(id: UUID) {
        packages.removeAll { $0.manifest.id == id }
        installations.removeAll { $0.packageID == id }
        approvedScriptHashes?[id] = nil
        approvedStyleHashes?[id] = nil
    }

    /// A library saved before per-device approvals: the scripts this Mac
    /// already runs count as approved here, so the first sync keeps them on.
    public mutating func adoptLegacyScriptApprovals() {
        guard approvedScriptHashes == nil else { return }
        var approved: [UUID: String] = [:]
        for package in packages where package.scriptBoost?.userScriptEnabled == true {
            approved[package.manifest.id] = BoostLibraryOps.scriptApprovalHash(package)
        }
        approvedScriptHashes = approved
    }

    /// A library saved before style approvals: the CSS this Mac already applies counts as approved.
    public mutating func adoptLegacyStyleApprovals() {
        guard approvedStyleHashes == nil else { return }
        var approved: [UUID: String] = [:]
        for package in packages {
            approved[package.manifest.id] = BoostLibraryOps.styleApprovalHash(package)
        }
        approvedStyleHashes = approved
    }

    public mutating func adoptLegacyApprovals() {
        adoptLegacyScriptApprovals()
        adoptLegacyStyleApprovals()
    }

    /// The script may run: switched on here and approved here for these exact bytes and hosts.
    public func scriptApproved(_ package: BoostPackage) -> Bool {
        guard package.scriptBoost?.userScriptEnabled == true, let hash = BoostLibraryOps.scriptApprovalHash(package) else { return false }
        guard let approvals = approvedScriptHashes else { return true }
        return approvals[package.manifest.id] == hash
    }

    /// The CSS may apply: written or approved on this Mac for these exact bytes and hosts.
    public func styleApproved(_ package: BoostPackage) -> Bool {
        guard let hash = BoostLibraryOps.styleApprovalHash(package) else { return true }
        guard let approvals = approvedStyleHashes else { return true }
        return approvals[package.manifest.id] == hash
    }

    /// Local edits are this Mac's own: every package whose CSS or host rules differ from
    /// `previous` is approved as it now stands. Sync never comes through here.
    public mutating func approveLocalStyleEdits(since previous: ProfileBoostLibrary?) {
        adoptLegacyStyleApprovals()
        for package in packages {
            let hash = BoostLibraryOps.styleApprovalHash(package)
            let before = previous?.package(id: package.manifest.id).flatMap(BoostLibraryOps.styleApprovalHash)
            if previous?.package(id: package.manifest.id) == nil || hash != before {
                approvedStyleHashes?[package.manifest.id] = hash
            }
        }
    }

    /// Drops approvals of boosts that no longer exist, so a deleted ID cannot come back approved.
    public mutating func pruneApprovals() {
        let ids = Set(packages.map(\.manifest.id))
        approvedScriptHashes = approvedScriptHashes?.filter { ids.contains($0.key) }
        approvedStyleHashes = approvedStyleHashes?.filter { ids.contains($0.key) }
    }

    public func nextOrder() -> Int {
        (installations.map(\.order).max() ?? 0) + 1
    }
}

public enum BoostLibraryMutationError: Equatable, Sendable {
    case profileMismatch
    case packageNotFound
    case validationFailed([BoostSecurityError])
    case duplicateName
}

public enum BoostLibraryOps {
    public static func empty(for profileID: Profile.ID) -> ProfileBoostLibrary {
        ProfileBoostLibrary(profileID: profileID)
    }

    /// `approvingStyle`: false for a boost file from elsewhere (RC-0.1.0-602 N-02): its CSS
    /// waits for Review CSS… like CSS that arrives by sync, so the validator is not its only check.
    public static func add(
        _ package: BoostPackage,
        to library: inout ProfileBoostLibrary,
        enabled: Bool = true,
        approvingStyle: Bool = true
    ) -> BoostLibraryMutationError? {
        let errors = BoostSecurity.validatePackage(package)
        if !errors.isEmpty { return .validationFailed(errors) }
        let install = BoostInstallation(
            packageID: package.manifest.id,
            enabled: enabled,
            order: library.nextOrder()
        )
        library.upsertPackage(package, installation: install)
        if approvingStyle {
            _ = approveStyle(packageID: package.manifest.id, library: &library)
        } else {
            library.adoptLegacyStyleApprovals()
            library.approvedStyleHashes?[package.manifest.id] = nil
        }
        return nil
    }

    public static func duplicate(
        packageID: UUID,
        in library: inout ProfileBoostLibrary,
        newName: String? = nil
    ) -> BoostPackage? {
        guard let source = library.package(id: packageID),
              let sourceInstall = library.installation(for: packageID) else { return nil }
        var copy = source
        let newID = UUID()
        copy.manifest.id = newID
        copy.manifest.version = 1
        copy.manifest.name = newName ?? "\(source.manifest.name) Copy"
        copy.manifest.createdAt = Date()
        copy.manifest.updatedAt = Date()
        copy.provenance = BoostProvenance(imported: false)
        let install = BoostInstallation(
            packageID: newID,
            enabled: sourceInstall.enabled,
            order: library.nextOrder(),
            allowPrivate: sourceInstall.allowPrivate
        )
        library.upsertPackage(copy, installation: install)
        if library.styleApproved(source) { _ = approveStyle(packageID: newID, library: &library) }
        return copy
    }

    public static func setSpacePolicy(
        packageID: UUID,
        spaceID: Space.ID,
        policy: BoostSpacePolicy,
        library: inout ProfileBoostLibrary
    ) -> Bool {
        guard let idx = library.installations.firstIndex(where: { $0.packageID == packageID }) else {
            return false
        }
        library.installations[idx].spacePolicy[spaceID] = policy
        return true
    }

    public static func setInstallationEnabled(
        packageID: UUID,
        enabled: Bool,
        library: inout ProfileBoostLibrary
    ) -> Bool {
        guard let idx = library.installations.firstIndex(where: { $0.packageID == packageID }) else {
            return false
        }
        library.installations[idx].enabled = enabled
        return true
    }

    /// Bind consent to both code and its scope, so changing where code runs
    /// cannot reuse approval for the same bytes on another site.
    public static func scriptApprovalHash(_ package: BoostPackage) -> String? {
        guard let js = package.scriptBoost?.js, !js.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let scope = try? encoder.encode(package.manifest.hostScope) else { return nil }
        var bytes = Data(js.utf8)
        bytes.append(0)
        bytes.append(scope)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The CSS a boost applies (style and script CSS, as `BoostActivation` joins them).
    public static func combinedCSS(_ package: BoostPackage) -> String? {
        let parts = [package.styleBoost?.css, package.scriptBoost?.css].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Consent to CSS covers its bytes and its host rules, as for scripts.
    public static func styleApprovalHash(_ package: BoostPackage) -> String? {
        guard let css = combinedCSS(package) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let scope = try? encoder.encode(package.manifest.hostScope) else { return nil }
        var bytes = Data("css".utf8)
        bytes.append(0)
        bytes.append(Data(css.utf8))
        bytes.append(0)
        bytes.append(scope)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func approveStyle(packageID: UUID, library: inout ProfileBoostLibrary) -> Bool {
        guard let package = library.package(id: packageID) else { return false }
        library.adoptLegacyStyleApprovals()
        library.approvedStyleHashes?[packageID] = styleApprovalHash(package)
        return true
    }

    public static func setScriptUserEnabled(
        packageID: UUID,
        enabled: Bool,
        library: inout ProfileBoostLibrary
    ) -> Bool {
        guard let idx = library.packages.firstIndex(where: { $0.manifest.id == packageID }),
              library.packages[idx].scriptBoost != nil else { return false }
        library.adoptLegacyScriptApprovals()
        library.packages[idx].scriptBoost?.userScriptEnabled = enabled
        library.approvedScriptHashes?[packageID] = enabled ? scriptApprovalHash(library.packages[idx]) : nil
        library.packages[idx].manifest.updatedAt = Date()
        return true
    }
}
