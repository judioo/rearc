import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 19: adoption of ABI 1.11–1.14 (WAVE-16-REPORT.md, WAVE-18-REPORT.md).
final class ChromiumABI114CapabilitiesTests: XCTestCase {
    private let allFeatures: (String) -> Bool = { _ in true }

    func testMinorFourteenAdoptsTheWave16And18Features() {
        let capabilities = ChromiumCapabilities(abiMinorVersion: 14, hasFeature: allFeatures)
        XCTAssertTrue(capabilities.osPermissionShutdown && capabilities.shutdownPendingCloses)
        XCTAssertTrue(capabilities.profileDirectory && capabilities.webUIDailyPages)
        XCTAssertEqual(capabilities.navigationSchemes, NavigationURLPolicy.EngineSchemes.chromium.union(.dailyWebUI))
        XCTAssertTrue(capabilities.summary.contains("profile_directory=1"))
        XCTAssertTrue(capabilities.summary.contains("webui_daily_pages=1"))
    }

    func testEachWaitsForItsMinor() {
        let minor12 = ChromiumCapabilities(abiMinorVersion: 12, hasFeature: allFeatures)
        XCTAssertTrue(minor12.osPermissionShutdown && minor12.shutdownPendingCloses)
        XCTAssertFalse(minor12.profileDirectory || minor12.webUIDailyPages)
        XCTAssertEqual(minor12.navigationSchemes, .chromium)

        let minor13 = ChromiumCapabilities(abiMinorVersion: 13, hasFeature: allFeatures)
        XCTAssertTrue(minor13.profileDirectory)
        XCTAssertFalse(minor13.webUIDailyPages)

        let minor10 = ChromiumCapabilities(abiMinorVersion: 10, hasFeature: allFeatures)
        XCTAssertFalse(minor10.shutdownPendingCloses || minor10.osPermissionShutdown)
    }

    func testAFlagIsNeededAsWellAsTheMinor() {
        let noDaily = ChromiumCapabilities(abiMinorVersion: 15) { $0 != "webui_daily_pages" }
        XCTAssertFalse(noDaily.webUIDailyPages)
        XCTAssertEqual(noDaily.navigationSchemes, .chromium)
        let noDirectory = ChromiumCapabilities(abiMinorVersion: 15) { $0 != "profile_directory" }
        XCTAssertFalse(noDirectory.profileDirectory)
    }

    func testDependentFeaturesNeedTheirBase() {
        let noProfiles = ChromiumCapabilities(abiMinorVersion: 14) { $0 != "profiles" }
        XCTAssertFalse(noProfiles.profileDirectory, "directory opens need named profiles")
        let noNavigation = ChromiumCapabilities(abiMinorVersion: 14) { $0 != "navigation_extended" }
        XCTAssertFalse(noNavigation.webUIDailyPages)
        XCTAssertEqual(noNavigation.navigationSchemes, [])
    }
}

final class ChromiumShutdownGateTests: XCTestCase {
    func testTabClosesDeferShutdownOnlyOnOlderEngines() {
        XCTAssertTrue(ChromiumShutdownGate.mustDefer(profileCloseInFlight: false, tabClosesInFlight: 2, engineJoinsTabCloses: false))
        XCTAssertFalse(ChromiumShutdownGate.mustDefer(profileCloseInFlight: false, tabClosesInFlight: 2, engineJoinsTabCloses: true))
        XCTAssertFalse(ChromiumShutdownGate.mustDefer(profileCloseInFlight: false, tabClosesInFlight: 0, engineJoinsTabCloses: false))
    }

    func testAProfileCloseAlwaysDefersShutdown() {
        XCTAssertTrue(ChromiumShutdownGate.mustDefer(profileCloseInFlight: true, tabClosesInFlight: 0, engineJoinsTabCloses: true))
        XCTAssertTrue(ChromiumShutdownGate.mustDefer(profileCloseInFlight: true, tabClosesInFlight: 3, engineJoinsTabCloses: true))
    }
}

final class ChromiumProfileStoragePlanTests: XCTestCase {
    private let owner = UUID()
    private let other = UUID()
    private let modern = ChromiumProfileStoragePlan.Engine(canOpenDirectory: true, startupDirectory: "Default")
    private let legacy = ChromiumProfileStoragePlan.Engine(canOpenDirectory: false, startupDirectory: "Default")

    private func plan(
        _ id: UUID,
        _ map: ChromiumProfileStorageMap = ChromiumProfileStorageMap(),
        engine: ChromiumProfileStoragePlan.Engine? = nil,
        named: Set<String> = []
    ) -> ChromiumProfileStoragePlan {
        ChromiumProfileStoragePlan.plan(for: id, map: map, legacyOwner: owner, engine: engine ?? modern) { named.contains($0) }
    }

    func testFirstProfileAdoptsDefaultOnce() {
        XCTAssertEqual(plan(owner), .adoptDefault)
        XCTAssertEqual(plan(other), .named(ChromiumProfileKey.storageKey(for: other)), "only the first profile")

        var map = ChromiumProfileStorageMap()
        map.recordDirectory("Default", for: owner)
        XCTAssertEqual(map.legacyDefault, .adopted)
        XCTAssertEqual(map.storage(for: owner), .directory("Default"))
        // Every later launch opens the recorded mapping, never a second adoption.
        XCTAssertEqual(plan(owner, map), .directory("Default"))
        XCTAssertEqual(plan(other, map), .named(ChromiumProfileKey.storageKey(for: other)))
    }

    func testExistingNamedDataIsKeptAndRecorded() {
        let key = ChromiumProfileKey.storageKey(for: owner)
        let directory = ChromiumProfileStoragePlan.namedDirectoryName(forKey: key)
        XCTAssertEqual(plan(owner, named: [directory]), .keepNamed(key))

        var map = ChromiumProfileStorageMap()
        map.legacyDefault = .keptNamed
        XCTAssertEqual(plan(owner, map), .named(key), "the decision is not revisited")
    }

    func testOlderEnginesNeverAdoptOrOpenFreshForAMapping() {
        XCTAssertEqual(plan(owner, engine: legacy), .named(ChromiumProfileKey.storageKey(for: owner)))
        var map = ChromiumProfileStorageMap()
        map.recordDirectory("Default", for: owner)
        XCTAssertEqual(plan(owner, map, engine: legacy), .startupProfile)
        map.recordDirectory("Work", for: other)
        XCTAssertEqual(plan(other, map, engine: legacy), .unsupported("Work"))
    }

    func testAnotherStartupDirectoryIsNotDefault() {
        let custom = ChromiumProfileStoragePlan.Engine(canOpenDirectory: true, startupDirectory: "Profile 1")
        XCTAssertEqual(plan(owner, engine: custom), .named(ChromiumProfileKey.storageKey(for: owner)))
        var map = ChromiumProfileStorageMap()
        map.recordDirectory("Default", for: owner)
        XCTAssertEqual(
            plan(owner, map, engine: .init(canOpenDirectory: false, startupDirectory: "Profile 1")),
            .unsupported("Default")
        )
    }

    func testNamedDirectoryMatchesTheEngineHexRule() {
        XCTAssertEqual(ChromiumProfileStoragePlan.namedDirectoryName(forKey: "Aa-1"), "ReArcProfile-41612D31", "A and a stay distinct")
        let key = "0f7a"
        XCTAssertEqual(ChromiumProfileStoragePlan.namedDirectoryName(forKey: key), "ReArcProfile-30663761")
    }

    func testDirectoryTokenSyntax() {
        for token in ["Default", "Profile 1", "a_b-c"] {
            XCTAssertTrue(ChromiumProfileStoragePlan.isValidDirectoryToken(token), token)
        }
        for token in ["", " Default", "Default ", "../Default", "a/b", "Dé", ".", String(repeating: "a", count: 129)] {
            XCTAssertFalse(ChromiumProfileStoragePlan.isValidDirectoryToken(token), token)
        }
    }

    func testMapRoundTripsAndToleratesAMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ChromiumProfileStorageMap.fileName)
        XCTAssertEqual(ChromiumProfileStorageMap.load(from: url), ChromiumProfileStorageMap())

        var map = ChromiumProfileStorageMap()
        map.recordDirectory("Default", for: owner)
        try map.save(to: url)
        XCTAssertEqual(ChromiumProfileStorageMap.load(from: url), map)

        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(ChromiumProfileStorageMap.load(from: url), ChromiumProfileStorageMap())
    }

    func testLaunchArgumentsGiveTheDataDirectoryAndStartupDirectory() {
        let args = ["ReArc", "--user-data-dir=/tmp/a", "--user-data-dir=/tmp/b"]
        XCTAssertEqual(ChromiumLaunchArguments.userDataDir(in: args), "/tmp/b")
        XCTAssertEqual(ChromiumLaunchArguments.startupProfileDirectory(in: args), "Default")
        XCTAssertEqual(ChromiumLaunchArguments.startupProfileDirectory(in: args + ["--profile-directory=Profile 2"]), "Profile 2")
        XCTAssertNil(ChromiumLaunchArguments.userDataDir(in: ["ReArc"]))
    }
}
