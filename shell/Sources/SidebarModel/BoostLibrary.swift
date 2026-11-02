import Foundation

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

    public static func add(
        _ package: BoostPackage,
        to library: inout ProfileBoostLibrary,
        enabled: Bool = true
    ) -> BoostLibraryMutationError? {
        let errors = BoostSecurity.validatePackage(package)
        if !errors.isEmpty { return .validationFailed(errors) }
        let install = BoostInstallation(
            packageID: package.manifest.id,
            enabled: enabled,
            order: library.nextOrder()
        )
        library.upsertPackage(package, installation: install)
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

    public static func setScriptUserEnabled(
        packageID: UUID,
        enabled: Bool,
        library: inout ProfileBoostLibrary
    ) -> Bool {
        guard let idx = library.packages.firstIndex(where: { $0.manifest.id == packageID }),
              library.packages[idx].scriptBoost != nil else { return false }
        library.packages[idx].scriptBoost?.userScriptEnabled = enabled
        library.packages[idx].manifest.updatedAt = Date()
        return true
    }
}
