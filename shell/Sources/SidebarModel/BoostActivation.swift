import Foundation

public struct BoostTabContext: Equatable, Sendable {
    public var profileID: Profile.ID
    public var spaceID: Space.ID?
    public var url: URL
    public var isPrivate: Bool
    /// The space's own switch (`Space.boostsEnabled`); off turns every boost off there.
    public var spaceBoostsEnabled: Bool

    public init(profileID: Profile.ID, spaceID: Space.ID?, url: URL, isPrivate: Bool = false, spaceBoostsEnabled: Bool = true) {
        self.profileID = profileID
        self.spaceID = spaceID
        self.url = url
        self.isPrivate = isPrivate
        self.spaceBoostsEnabled = spaceBoostsEnabled
    }
}

public struct BoostRuntimeEntry: Equatable, Sendable {
    public var packageID: UUID
    public var order: Int
    public var hostScope: [BoostHostRule]
    public var css: String?
    /// Validated rule blocks for atomic coordinator injection (one style node per rule id).
    public var cssRules: [BoostCSSRule]
    public var js: String?
    public var scriptUserEnabled: Bool

    public init(
        packageID: UUID,
        order: Int,
        hostScope: [BoostHostRule],
        css: String?,
        cssRules: [BoostCSSRule] = [],
        js: String?,
        scriptUserEnabled: Bool
    ) {
        self.packageID = packageID
        self.order = order
        self.hostScope = hostScope
        self.css = css
        self.cssRules = cssRules
        self.js = js
        self.scriptUserEnabled = scriptUserEnabled
    }
}

public enum BoostActivation {
    public static func effectiveEnabled(
        installation: BoostInstallation,
        library: ProfileBoostLibrary,
        context: BoostTabContext
    ) -> Bool {
        guard library.profileID == context.profileID else { return false }
        guard library.masterEnabled, context.spaceBoostsEnabled else { return false }
        if context.isPrivate, !installation.allowPrivate { return false }
        guard let package = library.package(id: installation.packageID),
              BoostScopeMatcher.matches(scope: package.manifest.hostScope, url: context.url) else {
            return false
        }
        return resolvedInstallationBit(installation: installation, spaceID: context.spaceID)
    }

    public static func resolvedInstallationBit(
        installation: BoostInstallation,
        spaceID: Space.ID?
    ) -> Bool {
        guard let spaceID else { return installation.enabled }
        switch installation.spacePolicy[spaceID] ?? .inherit {
        case .forceOff: return false
        case .forceOn: return true
        case .inherit: return installation.enabled
        }
    }

    public static func activeEntries(
        library: ProfileBoostLibrary,
        context: BoostTabContext
    ) -> [BoostRuntimeEntry] {
        guard library.profileID == context.profileID else { return [] }
        guard library.masterEnabled, context.spaceBoostsEnabled else { return [] }
        guard BoostScopeMatcher.urlIsEligibleForBoosts(context.url) else { return [] }

        var entries: [BoostRuntimeEntry] = []
        for install in library.installations.sorted(by: { $0.order < $1.order }) {
            guard effectiveEnabled(installation: install, library: library, context: context) else { continue }
            guard let package = library.package(id: install.packageID) else { continue }
            guard BoostSecurity.validatePackage(package).isEmpty else { continue }
            var cssParts: [String] = []
            if let style = package.styleBoost?.css, !style.isEmpty {
                cssParts.append(style)
            }
            if let scriptCSS = package.scriptBoost?.css, !scriptCSS.isEmpty {
                cssParts.append(scriptCSS)
            }
            let css = cssParts.isEmpty ? nil : cssParts.joined(separator: "\n")
            let compiledRules: [BoostCSSRule]
            if let css, !css.isEmpty {
                guard let rules = BoostStyleCompiler.compileStylesheet(css, allowInStyle: true) else { continue }
                compiledRules = rules
            } else {
                compiledRules = []
            }
            let js = package.scriptBoost?.js
            let scriptOn = package.scriptBoost?.userScriptEnabled == true
            entries.append(
                BoostRuntimeEntry(
                    packageID: package.manifest.id,
                    order: install.order,
                    hostScope: package.manifest.hostScope,
                    css: css,
                    cssRules: compiledRules,
                    js: js,
                    scriptUserEnabled: scriptOn && js?.isEmpty == false
                )
            )
        }
        let cssOnly = entries.flatMap { $0.cssRules.map(\.css) }
        if !BoostSecurity.tabCSSBudgetOK(cssOnly) {
            return []
        }
        return entries.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.packageID.uuidString < $1.packageID.uuidString
        }
    }

    /// Per-host list for toggles: packages whose scope matches URL in this profile.
    public static func matchingForHost(
        library: ProfileBoostLibrary,
        url: URL
    ) -> [(package: BoostPackage, installation: BoostInstallation)] {
        guard BoostScopeMatcher.urlIsEligibleForBoosts(url) else { return [] }
        return library.installations.compactMap { install in
            guard let package = library.package(id: install.packageID),
                  BoostScopeMatcher.matches(scope: package.manifest.hostScope, url: url) else {
                return nil
            }
            return (package, install)
        }.sorted { $0.installation.order < $1.installation.order }
    }
}
