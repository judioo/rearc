import Foundation
import Testing
@testable import ReArc
@testable import SidebarModel

@MainActor
struct Perf3Tests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-perf3-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func preparedSidebarPreservesSnapshotWithoutReadingAgain() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sidebar.json")
        let fixture = BenchFixture.make(.items500, seed: 1) { _ in URL(string: "about:blank")! }
        let snapshot = fixture.store.makeSnapshot()
        try JSONEncoder().encode(snapshot).write(to: file)
        let prepared = SidebarFilePersistence.prepareLoad(from: file)
        let expected = SidebarFilePersistence.loadStore(fileURL: file).makeSnapshot()
        try FileManager.default.removeItem(at: file)
        let persistence = SidebarFilePersistence(fileURL: file)
        let restored = persistence.restoreStore(from: prepared)
        #expect(restored.makeSnapshot() == expected)
        #expect(persistence.loadOutcome == .loaded)
        #expect(persistence.autosaveEnabled)
    }

    @Test func preparedSupplementalStoresSurviveFileRemoval() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sidebar.json")
        let store = SidebarStore.sample()
        try JSONEncoder().encode(store.makeSnapshot()).write(to: file)
        let history = Perf2HistoryTests.history()
        try VisitHistoryFile.save(history, to: directory.appendingPathComponent(VisitHistoryFile.fileName))
        try DownloadListFile.save(.init(directory: directory.path, askWhereToSave: true),
                                  to: directory.appendingPathComponent(DownloadListFile.fileName))
        let prepared = PreparedBrowserStartup.load(from: file)
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: child)
        }
        let persistence = SidebarFilePersistence(fileURL: file)
        let model = BrowserViewModel(store: persistence.restoreStore(from: prepared.sidebar), persistence: persistence,
            syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil),
            preparedStartup: prepared, deferStartup: true)
        #expect(model.visitHistory == history)
        #expect(model.downloads.directory.path == directory.path)
        #expect(model.downloads.askWhereToSave)
        #expect(model.engineHost.allTabEngines().isEmpty)
        #expect(Set(prepared.loadSeconds.keys) == ["sidebar", "history", "downloads", "permissions", "sync"])
    }

    @Test func preparedCorruptSidebarKeepsAutosaveDisabled() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sidebar.json")
        try Data("broken".utf8).write(to: file)
        let prepared = SidebarFilePersistence.prepareLoad(from: file)
        let persistence = SidebarFilePersistence(fileURL: file)
        _ = persistence.restoreStore(from: prepared)
        #expect(persistence.loadOutcome == .recoveredFromCorruptFile)
        #expect(!persistence.autosaveEnabled)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    @Test func cachedSidebarDoesNotCreateAnEngineBeforeServicesStart() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SidebarStore()
        let tab = store.addTab(kind: .today, title: "Blank", url: URL(string: "about:blank")!)
        store.selectTab(tab.id)
        let sync = LocalSyncEngine()
        let model = BrowserViewModel(store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: sync, faviconStore: FaviconStore(directory: nil), deferStartup: true)
        #expect(model.startupDeferred)
        model.loadSelectedIfNeeded()
        #expect(model.engineHost.allTabEngines().isEmpty)
        #expect(model.store.selectedTabID == tab.id)
        model.finishStartup()
        let engine = model.engineHost.engine(forTabID: tab.id, profileID: store.activeProfileID)
        #expect(engine != nil)
        model.finishStartup()
        #expect(model.engineHost.allTabEngines().count == 1)
        #expect(model.engineHost.engine(forTabID: tab.id, profileID: store.activeProfileID) === engine)
    }

    @Test func themeCacheInvalidatesOnlyEditedSpaceAndAppearance() {
        let cache = SpaceThemeColorCache(), a = UUID(), b = UUID()
        var theme = SpaceTheme(red: 0.8, green: 0.2, blue: 0.4)
        _ = cache.colors(for: a, theme: theme, dark: false)
        _ = cache.colors(for: b, theme: theme, dark: false)
        for _ in 0..<20 { _ = cache.colors(for: a, theme: theme, dark: false) }
        #expect(cache.buildCount == 2)
        _ = cache.colors(for: a, theme: theme, dark: true)
        #expect(cache.buildCount == 3)
        theme.intensity = 0.4
        _ = cache.colors(for: a, theme: theme, dark: false)
        _ = cache.colors(for: b, theme: SpaceTheme(red: 0.8, green: 0.2, blue: 0.4), dark: false)
        #expect(cache.buildCount == 4)
        let expected = ThemeChromeColors(theme: theme, dark: false, windowDark: false)
        let actual = cache.colors(for: a, theme: theme, dark: false)
        #expect(actual.title == expected.title && actual.selection == expected.selection)
    }

    @Test func preparedTransientEnginesKeepIdentityProfileAndSingleUse() {
        let host = EngineHost(), profile = UUID(), other = UUID()
        host.prepareTransientEngines(profileID: profile)
        // A different profile cannot consume the spare.
        #expect(host.takePreparedLittleArc(profileID: other) == nil)
        let id = host.takePreparedLittleArc(profileID: profile)!
        let engine = host.engine(forLittleArc: id, profileID: profile)
        #expect(engine.pagePrompts.profileID == profile)
        #expect(engine.pagePrompts.role == .littleArc)
        #expect(host.takePreparedLittleArc(profileID: profile) == nil)
        host.removeLittleArc(id, profileID: profile)
        #expect(host.existingLittleArcEngine(id, profileID: profile) == nil)
        let peek = host.ephemeralEngine(profileID: profile)
        #expect(peek.engine.pagePrompts.role == .peek)
        #expect(peek.engine.pagePrompts.profileID == profile)
        host.removeEphemeral(id: peek.id, profileID: profile)
        let next = host.ephemeralEngine(profileID: profile)
        #expect(next.id != peek.id)
        #expect(next.engine !== peek.engine)
        host.prepareTransientEngines(profileID: profile)
        host.evictEngines(forProfileID: profile)
        #expect(host.takePreparedLittleArc(profileID: profile) == nil)
    }

    @Test func modelSwitchesRetainWarmEnginesAndSidebarTrees() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = BenchFixture.make(.items500, seed: 1) { _ in URL(string: "about:blank")! }
        let store = fixture.store
        let model = BrowserViewModel(store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        for id in fixture.spaceIDs { model.selectSpace(id) }
        let engines = model.engineHost.allTabEngines()
        let before = store.makeSnapshot()
        for id in fixture.spaceIDs { model.selectSpace(id) }
        for profile in store.profiles { model.selectProfile(profile.id) }
        let after = store.makeSnapshot()
        #expect(before.tabsByID == after.tabsByID)
        #expect(before.spaces == after.spaces)
        #expect(before.foldersByID == after.foldersByID)
        for (id, profile, engine) in engines {
            #expect(model.engineHost.engine(forTabID: id, profileID: profile) === engine)
        }
    }

    @Test func startupTiming() throws {
        guard ProcessInfo.processInfo.environment["REARC_PERF3_TIMING"] == "1" else { return }
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sidebar.json")
        let fixture = BenchFixture.make(.items500, seed: 1) { _ in URL(string: "about:blank")! }
        try JSONEncoder().encode(fixture.store.makeSnapshot()).write(to: file)
        try VisitHistoryFile.save(Perf2HistoryTests.history(), to: directory.appendingPathComponent(VisitHistoryFile.fileName))
        let prepared = PreparedBrowserStartup.load(from: file)
        for preparedPath in [false, true] {
            var samples: [Double] = []
            for i in 0..<25 {
                let persistence = SidebarFilePersistence(fileURL: file)
                let start = ProcessInfo.processInfo.systemUptime
                let store = preparedPath ? persistence.restoreStore(from: prepared.sidebar)
                    : SidebarFilePersistence.loadStore(persistence: persistence)
                let model = BrowserViewModel(store: store, persistence: persistence,
                    syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil),
                    preparedStartup: preparedPath ? prepared : nil, deferStartup: true)
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                #expect(model.store.spaces.count == fixture.store.spaces.count)
                if i >= 5 { samples.append(elapsed) }
            }
            samples.sort()
            print(String(format: "PERF3 startup-%@ p50=%.4f p95=%.4f max=%.4f ms",
                         preparedPath ? "prepared" : "serial", samples[9], samples[18], samples.last!))
        }
    }

    /// Same pure model entry points before/after. No windows or external URLs.
    @Test func switchTiming() throws {
        guard ProcessInfo.processInfo.environment["REARC_PERF3_TIMING"] == "1" else { return }
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = BenchFixture.make(.items500, seed: 1) { _ in URL(string: "about:blank")! }
        let model = BrowserViewModel(store: fixture.store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        for id in fixture.spaceIDs { model.selectSpace(id) }
        func measure(_ name: String, _ operation: (Int) -> Void) {
            var samples: [Double] = []
            for i in 0..<220 {
                let start = ProcessInfo.processInfo.systemUptime
                operation(i)
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                if i >= 20 { samples.append(elapsed) }
            }
            samples.sort()
            print(String(format: "PERF3 %@ p50=%.4f p95=%.4f max=%.4f ms", name, samples[99], samples[189], samples.last!))
        }
        let spaces = Array(model.store.spaces(in: model.store.profiles[0].id).prefix(2)).map(\.id)
        measure("space") { model.selectSpace(spaces[$0 % 2]) }
        let profiles = model.store.profiles.map(\.id)
        measure("profile") { model.selectProfile(profiles[$0 % profiles.count]) }
        let theme = SpaceTheme(red: 0.8, green: 0.2, blue: 0.4)
        let cache = SpaceThemeColorCache(), id = UUID()
        measure("theme-uncached") { _ in _ = ThemeChromeColors(theme: theme, dark: true) }
        measure("theme-cached") { _ in _ = cache.colors(for: id, theme: theme, dark: true) }
    }
}
