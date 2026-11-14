import Foundation
import Testing
@testable import ReArc
@testable import SidebarModel

/// Sync Sidebar on and off from Settings › Account and › Profiles, a fresh
/// install's import that iCloud already has, and Put in iCloud… after
/// iCloud's copy was deleted. Everything runs against `InMemorySyncServer`.
@MainActor
struct ProfilesICloudSyncTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-icloud-\(UUID())")
    private let server = InMemorySyncServer()

    /// Up to 10 s: the whole suite in parallel can hold the main actor for seconds.
    private func settle(_ until: () -> Bool) async {
        for _ in 0 ..< 2000 where !until() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func coordinator(_ device: String, on: Bool = false, account: String? = "fixture",
                             file: SidebarSyncStateStoring? = nil) -> SidebarSyncCoordinator {
        var state = SidebarSyncState()
        state.enabled = on
        state.decision = on ? .user : nil
        return SidebarSyncCoordinator(transport: server.transport(account: account), stateStore: file ?? InMemorySyncStateStore(state), deviceID: device)
    }

    private func model(_ coordinator: SidebarSyncCoordinator) -> (BrowserViewModel, SidebarSyncScheduler) {
        let scheduler = SidebarSyncScheduler(coordinator: coordinator)
        scheduler.sleeper = { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        let model = BrowserViewModel(persistence: SidebarFilePersistence(fileURL: folder.appendingPathComponent("sidebar.json")),
                                     syncEngine: scheduler, faviconStore: FaviconStore(directory: nil))
        model.finishFirstRunOnboarding()
        return (model, scheduler)
    }

    private func close(_ model: BrowserViewModel, _ scheduler: SidebarSyncScheduler) {
        scheduler.stop()
        model.persistence.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    /// An import of Arc's "Akilu" as ReArc makes it: a profile with an id of
    /// this install's, spaces and rows with ids that follow from Arc's.
    @discardableResult
    private func importArc(into store: SidebarStore, name: String = "Akilu", spaces: [String] = ["Work", "Notes", "Travel"]) -> Profile.ID {
        let profile = store.addProfile(name: name, createInitialSpace: false).id
        for name in spaces {
            let source = "Default:\(name)"
            let space = store.addSpace(name: name, profileID: profile, id: SidebarStore.arcSpaceID(source))
            store.spaces[store.spaces.firstIndex { $0.id == space.id }!].arcSourceID = source
            for row in 0 ..< 2 {
                _ = store.addTab(kind: .pinned, title: "\(name) \(row)", url: URL(string: "https://\(name.lowercased()).test/\(row)")!,
                                 in: space.id, tabID: SidebarStore.arcItemID("\(source):\(row)"))
            }
        }
        return profile
    }

    /// An earlier install that imported the same Arc profile and synced.
    private func earlierInstallInICloud(spaces: [String] = ["Work", "Notes", "Travel"]) async -> (SidebarStore, Profile.ID) {
        let earlier = await earlierInstall(spaces: spaces)
        return (earlier.store, earlier.profile)
    }

    /// The same, with its sync, for what it changes in iCloud later.
    private func earlierInstall(name: String = "Akilu", spaces: [String] = ["Work", "Notes", "Travel"]) async
        -> (store: SidebarStore, profile: Profile.ID, sync: SidebarSyncCoordinator) {
        let store = SidebarStore()
        let starter = store.activeProfileID
        let profile = importArc(into: store, name: name, spaces: spaces)
        // Its only profile: the import, as on the owner's Mac.
        _ = store.deleteProfile(starter, deletingSpaces: true)
        let sync = coordinator("Earlier", on: true)
        sync.host = store
        await sync.sync()
        return (store, profile, sync)
    }

    private func pinned(_ store: SidebarStore, _ profile: Profile.ID) -> [Space.ID: [UUID]] {
        Dictionary(uniqueKeysWithValues: store.spaces(in: profile).map { ($0.id, SidebarTree.leaves(store.content(for: $0.id).pinned).map(\.id)) })
    }

    /// Settings did this with sync off, from the "In iCloud only" row.
    private func deleteFromICloud(_ id: Profile.ID) async throws {
        let sync = coordinator("Settings")
        let found = try #require(await sync.detectCloudSidebar().found)
        let plan = try #require(CloudProfileDeletion(profileID: id, in: Dictionary(uniqueKeysWithValues: found.records.map { ($0.recordName, $0) })))
        let result = await sync.deleteCloudProfile(plan, in: found, backup: { _ in URL(fileURLWithPath: "/dev/null") })
        guard case .deleted = result else { Issue.record("\(result)"); return }
    }

    // MARK: - The switch

    /// Pressed on, the switch shows on while it waits for a look that
    /// doesn't finish; pressed off then, nothing turns on when the look ends.
    @Test func theSwitchWaitingCanBeSwitchedOff() async throws {
        let (model, scheduler) = model(coordinator("A"))
        defer { close(model, scheduler) }
        let gate = Gate()
        server.readHold = { await gate.wait() }
        model.setSyncEnabled(true)
        #expect(model.syncSwitchWaiting)
        #expect(model.syncSwitchIsOn, "shown on, so it can be switched off")
        #expect(!model.isSyncEnabled)
        model.setSyncEnabled(false)
        #expect(!model.syncSwitchIsOn)
        gate.open()
        await settle { model.cloudDetection != nil }
        #expect(model.cloudDetection == .empty(accountID: "fixture"))
        #expect(!model.isSyncEnabled, "the look's late result turns nothing on")
        #expect(server.modifyCount == 0)
    }

    /// Signed out: the switch says why and stays off.
    @Test func signedOutTheSwitchStaysOffAndSaysWhy() async {
        let (model, scheduler) = model(coordinator("A", account: nil))
        defer { close(model, scheduler) }
        model.setSyncEnabled(true)
        await settle { model.syncCloudMessage != nil }
        #expect(model.syncCloudMessage != nil)
        #expect(!model.syncSwitchIsOn)
        #expect(!model.canPutInICloud(model.store.activeProfileID), "where it is isn't known")
    }

    /// A build without iCloud: the switch can't turn on, and the profile
    /// row says why instead of a place.
    @Test func unavailableTheSwitchStaysOff() {
        let model = BrowserViewModel(persistence: SidebarFilePersistence(fileURL: folder.appendingPathComponent("sidebar.json")),
                                     syncEngine: UnavailableSyncEngine(reason: "No entitlement"), faviconStore: FaviconStore(directory: nil))
        defer {
            model.persistence.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(model.syncUnavailableReason != nil)
        model.setSyncEnabled(true)
        #expect(!model.syncSwitchIsOn)
        model.putInICloud(model.store.activeProfileID)
        #expect(!model.syncSwitchIsOn)
        #expect(model.cloudPresence(of: model.store.activeProfileID) == .unknown(CloudKitSyncAvailability.unavailableMessage))
    }

    /// On from an earlier build (sync-state.json says on, the person's
    /// choice): off stops it, and a relaunch reads it off and syncs nothing.
    @Test func offStaysOffAcrossARelaunch() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = SidebarSyncStateFile(fileURL: folder.appendingPathComponent(SidebarSyncStateFile.fileName))
        var on = SidebarSyncState()
        on.enabled = true
        on.decision = .user
        file.save(on)
        let (model, scheduler) = model(coordinator("A", file: file))
        #expect(model.isSyncEnabled && model.syncSwitchIsOn)
        model.setSyncEnabled(false)
        #expect(!model.isSyncEnabled)
        scheduler.stop()
        model.persistence.stop()

        let relaunched = coordinator("A", file: SidebarSyncStateFile(fileURL: file.fileURL))
        #expect(!relaunched.isEnabled)
        let again = SidebarSyncScheduler(coordinator: relaunched)
        relaunched.host = SidebarStore()
        again.start()
        await again.runCycle()
        #expect(server.fetchCount == 0 && server.modifyCount == 0, "nothing reaches iCloud")
        again.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - A fresh install's import

    /// iCloud holds an earlier install's import of the same Arc spaces: the
    /// profile is on this Mac and in iCloud, and nothing is in iCloud only.
    @Test func aFreshImportIsTheProfileICloudHas() async throws {
        let (_, earlier) = await earlierInstallInICloud()
        let (model, scheduler) = model(coordinator("Fresh"))
        defer { close(model, scheduler) }
        let akilu = importArc(into: model.store)
        #expect(akilu != earlier, "profile ids are made per install")
        model.checkCloudSidebar()
        await settle { model.cloudDetection != nil && !model.isCheckingCloud }
        #expect(model.cloudOnlyProfiles.isEmpty, "not “In iCloud only”")
        #expect(model.cloudPresence(of: akilu) == .inICloud)
        #expect(ProfileCloudText.status(model.cloudPresence(of: akilu)) == "On this Mac and in iCloud")
        #expect(!model.canPutInICloud(akilu))

        // Its delete asks about iCloud's copy, under this Mac's name.
        #expect(model.requestCloudProfileDeletion(akilu))
        let request = try #require(model.cloudProfileDeletes.request)
        #expect(request.profile.id == akilu && request.onThisMac)
        #expect(request.plan.profileID == earlier)
        #expect(request.plan.spaces == 3)
        #expect(request.cloudCopy?.id == earlier)
        model.cloudProfileDeletes.request = nil
    }

    // MARK: - The delete of a profile whose copy in iCloud has another id (RC-2026.1113.765 Y-01)

    /// The question names iCloud's profile and its spaces, as the "In iCloud
    /// only" detail does, before what each button does.
    @Test func theDeleteNamesICloudsCopyAndItsSpaces() async throws {
        let earlier = await earlierInstall(name: "Akilu at home", spaces: ["Work", "Notes"])
        let (model, scheduler) = model(coordinator("Fresh"))
        defer { close(model, scheduler) }
        let akilu = importArc(into: model.store)
        model.checkCloudSidebar()
        await settle { model.cloudDetection != nil && !model.isCheckingCloud }
        #expect(model.cloudPresence(of: akilu) == .inICloud, "every space of iCloud's is this profile's; Travel is only here")
        #expect(model.cloudOnlyProfiles.isEmpty)

        #expect(model.requestCloudProfileDeletion(akilu))
        let request = try #require(model.cloudProfileDeletes.request)
        #expect(request.plan.profileID == earlier.profile)
        #expect(model.cloudProfileDeleteTitle(request) == "Delete “Akilu”?")
        let message = model.cloudProfileDeleteMessage(request)
        #expect(message.hasPrefix("In iCloud it is “Akilu at home”, from another Mac or an earlier install, "
                + "with 2 spaces: Work (2 pinned tabs) and Notes (2 pinned tabs).\n\nDelete from This Mac: "), "\(message)")
        #expect(message.contains("Delete from This Mac and iCloud: It also goes from iCloud"))
        model.cloudProfileDeletes.request = nil

        // iCloud's own copy (the same id) needs no second name.
        let own = CloudProfileDeleteRequest(profile: request.profile, plan: request.plan, onThisMac: true)
        #expect(model.cloudProfileDeleteMessage(own).hasPrefix("Delete from This Mac: "))
    }

    /// An earlier install synced one "Personal" with Arc's Home and Work;
    /// this install made "Personal" (Home) and "Work" (Work). iCloud's
    /// "Personal" is neither of them: it is listed "In iCloud only" with its
    /// own Delete from iCloud…, this Mac's two are only here with Put in
    /// iCloud…, and deleting this Mac's "Personal" asks nothing of iCloud.
    @Test func aProfileThatSharesOneSpaceIsNotThisMacsProfile() async throws {
        let earlier = await earlierInstall(name: "Personal", spaces: ["Home", "Work"])
        let (model, scheduler) = model(coordinator("Fresh"))
        defer { close(model, scheduler) }
        let personal = importArc(into: model.store, name: "Personal", spaces: ["Home"])
        let work = importArc(into: model.store, name: "Work", spaces: ["Work"])
        let before = server.records(account: "fixture")
        model.checkCloudSidebar()
        await settle { model.cloudDetection != nil && !model.isCheckingCloud }

        #expect(model.cloudOnlyProfiles.map(\.id) == [earlier.profile], "“In iCloud only” lists iCloud's Personal")
        #expect(model.cloudOnlyProfiles.first?.spaces.map(\.name) == ["Home", "Work"])
        for id in [personal, work] {
            #expect(model.cloudPresence(of: id) == .onlyHere)
            #expect(ProfileCloudText.status(model.cloudPresence(of: id)) == "Only on this Mac")
            #expect(model.canPutInICloud(id), "Put in iCloud… is offered")
            #expect(!model.requestCloudProfileDeletion(id), "its delete is this Mac's alone")
            #expect(model.cloudProfileDeletes.request == nil)
        }

        // iCloud's Personal has its own delete, under its own name.
        #expect(model.requestCloudProfileDeletion(earlier.profile))
        let request = try #require(model.cloudProfileDeletes.request)
        #expect(!request.onThisMac && request.cloudCopy == nil)
        #expect(request.plan.profileID == earlier.profile && request.plan.spaces == 2)
        #expect(model.cloudProfileDeleteTitle(request) == "Delete “Personal” from iCloud?")
        #expect(model.cloudProfileDeleteMessage(request).contains("This Mac is not changed."))
        model.cloudProfileDeletes.request = nil
        #expect(server.records(account: "fixture") == before, "asking changes nothing in iCloud")
    }

    /// Between the question and the answer another Mac put a space into
    /// iCloud's copy that this profile doesn't have: the look made on
    /// confirming sees it, and nothing is deleted here or there.
    @Test func aCopyThatGainedAnotherSpaceIsNotDeleted() async throws {
        let earlier = await earlierInstall(name: "Akilu at home")
        let (model, scheduler) = model(coordinator("Fresh"))
        defer { close(model, scheduler) }
        let akilu = importArc(into: model.store)
        model.checkCloudSidebar()
        await settle { model.cloudDetection != nil && !model.isCheckingCloud }
        #expect(model.requestCloudProfileDeletion(akilu))
        let request = try #require(model.cloudProfileDeletes.request)

        let extra = earlier.store.addSpace(name: "Taxes", profileID: earlier.profile)
        _ = earlier.store.addTab(kind: .pinned, title: "Return", url: URL(string: "https://taxes.test")!, in: extra.id)
        await earlier.sync.sync()
        let before = server.records(account: "fixture")

        model.deleteCloudProfile(request, alsoThisMac: true)
        await settle { model.cloudProfileDeletes.working == nil && model.cloudProfileDeletes.notice != nil }
        #expect(model.cloudProfileDeletes.notice == CloudProfileNotice(text: ProfileCloudText.noLongerACopy("Akilu at home", of: "Akilu"), isError: true))
        #expect(model.cloudProfileDeletes.request == nil)
        #expect(server.records(account: "fixture") == before, "nothing changed in iCloud")
        #expect(model.store.profile(withID: akilu) != nil, "nor on this Mac")
        #expect(!FileManager.default.fileExists(atPath: model.sidebarBackupFolder.path), "nothing to back up")
        #expect(model.cloudOnlyProfiles.map(\.id) == [earlier.profile], "now a profile of its own")
        #expect(model.cloudPresence(of: akilu) == .onlyHere)
    }

    /// It changed but is still this profile's copy (a pinned tab more): the
    /// question comes back with the new counts and still names it; the
    /// second answer deletes it, backed up first.
    @Test func aCopyThatChangedIsAskedAgainByName() async throws {
        let earlier = await earlierInstall(name: "Akilu at home")
        let (model, scheduler) = model(coordinator("Fresh"))
        defer { close(model, scheduler) }
        let akilu = importArc(into: model.store)
        model.checkCloudSidebar()
        await settle { model.cloudDetection != nil && !model.isCheckingCloud }
        #expect(model.requestCloudProfileDeletion(akilu))
        let request = try #require(model.cloudProfileDeletes.request)

        let space = try #require(earlier.store.spaces(in: earlier.profile).first)
        _ = earlier.store.addTab(kind: .pinned, title: "New", url: URL(string: "https://new.test")!, in: space.id)
        await earlier.sync.sync()
        let before = server.records(account: "fixture")

        model.deleteCloudProfile(request, alsoThisMac: true)
        await settle { model.cloudProfileDeletes.working == nil && model.cloudProfileDeletes.request != nil }
        let again = try #require(model.cloudProfileDeletes.request)
        #expect(again.changed && again.onThisMac)
        #expect(again.plan.profileID == earlier.profile && again.plan.deletedTabs == request.plan.deletedTabs + 1)
        #expect(again.cloudCopy?.pinnedTabs == 7)
        let message = model.cloudProfileDeleteMessage(again)
        #expect(message.hasPrefix("It changed in iCloud since you looked.\n\nIn iCloud it is “Akilu at home”, "), "\(message)")
        #expect(message.contains("Work (3 pinned tabs)"))
        #expect(server.records(account: "fixture") == before, "nothing written before the second answer")
        #expect(model.store.profile(withID: akilu) != nil)

        model.deleteCloudProfile(again, alsoThisMac: true)
        await settle { model.cloudProfileDeletes.working == nil && model.cloudProfileDeletes.notice != nil }
        #expect(model.cloudProfileDeletes.notice?.isError == false)
        #expect(FileManager.default.fileExists(atPath: model.sidebarBackupFolder.path), "backed up first")
        #expect(server.records(account: "fixture")[SyncRecordKind.profile.recordName(for: earlier.profile)]?.payload.isAlive == false)
        #expect(model.store.profile(withID: akilu) == nil, "gone from this Mac too")
    }

    // MARK: - Put in iCloud…

    /// What the owner did: deleted iCloud's copy, listed "In iCloud only".
    /// The profile is only on this Mac; Put in iCloud… looks, finds iCloud
    /// empty, turns sync on and uploads it whole, rows and all.
    @Test func putInICloudAfterICloudsCopyWasDeleted() async throws {
        let (_, earlier) = await earlierInstallInICloud()
        try await deleteFromICloud(earlier)
        let (model, scheduler) = model(coordinator("Fresh"))
        defer { close(model, scheduler) }
        let akilu = importArc(into: model.store)
        let rows = pinned(model.store, akilu)
        model.checkCloudSidebar()
        await settle { model.cloudDetection != nil && !model.isCheckingCloud }
        #expect(model.cloudDetection == .empty(accountID: "fixture"))
        #expect(model.cloudPresence(of: akilu) == .onlyHere)
        #expect(ProfileCloudText.note(.onlyHere, syncOn: false) == ProfileCloudText.putInICloudNote)
        #expect(model.canPutInICloud(akilu))

        scheduler.start()
        model.putInICloud(akilu)
        await settle { model.isSyncEnabled && model.syncDetails?.phase == .upToDate }
        #expect(model.syncCloudChoice == nil, "an empty iCloud asks nothing")
        #expect(pinned(model.store, akilu) == rows, "every space and pinned row stays on this Mac")
        let cloud = server.records(account: "fixture")
        for (space, ids) in rows {
            #expect(cloud[SyncRecordKind.space.recordName(for: space)]?.payload.isAlive == true)
            #expect(ids.allSatisfy { cloud[SyncRecordKind.item.recordName(for: $0)]?.payload.isAlive == true })
        }
        #expect(model.cloudPresence(of: akilu) == .inICloud)
        #expect(ProfileCloudText.status(model.cloudPresence(of: akilu), syncOn: true) == "Synced with iCloud")
    }

    /// iCloud still holds another profile: Put in iCloud… asks first (the
    /// switch's sheet), Cancel changes nothing, and Merge brings the
    /// profile back to iCloud over its deleted copy, after a backup.
    @Test func putInICloudWithAnotherProfileInICloudAsksAndMerges() async throws {
        let (earlierStore, earlier) = await earlierInstallInICloud()
        let other = earlierStore.addProfile(name: "Studio", createInitialSpace: false).id
        let studioSpace = earlierStore.addSpace(name: "Studio", profileID: other)
        _ = earlierStore.addTab(kind: .pinned, title: "Board", url: URL(string: "https://board.test")!, in: studioSpace.id)
        let earlierSync = coordinator("Earlier", on: true)
        earlierSync.host = earlierStore
        await earlierSync.sync()
        try await deleteFromICloud(earlier)

        let (model, scheduler) = model(coordinator("Fresh"))
        defer { close(model, scheduler) }
        let akilu = importArc(into: model.store)
        let rows = pinned(model.store, akilu)
        let before = server.records(account: "fixture")
        scheduler.start()
        model.putInICloud(akilu)
        await settle { model.syncCloudChoice != nil }
        let found = try #require(model.syncCloudChoice)
        #expect(!model.isSyncEnabled)
        model.syncCloudChoice = nil // Cancel
        #expect(server.records(account: "fixture") == before, "Cancel changes nothing in iCloud")
        #expect(!model.isSyncEnabled)

        model.putInICloud(akilu)
        #expect(model.syncCloudChoice == found, "this session's look answers at once")
        model.chooseCloudSidebar(.merge, from: found)
        #expect(FileManager.default.fileExists(atPath: model.sidebarBackupFolder.path), "backed up first")
        await settle { model.isSyncEnabled && model.syncDetails?.phase == .upToDate }
        #expect(pinned(model.store, akilu) == rows)
        let cloud = server.records(account: "fixture")
        for (space, ids) in rows {
            #expect(cloud[SyncRecordKind.space.recordName(for: space)]?.payload.isAlive == true)
            #expect(ids.allSatisfy { cloud[SyncRecordKind.item.recordName(for: $0)]?.payload.isAlive == true })
        }
        #expect(model.store.profile(withID: other) != nil, "iCloud's other profile came in")
    }

    /// Sync on: Put in iCloud is a sync now; the profile is then in iCloud.
    @Test func putInICloudWithSyncOnSyncsNow() async throws {
        let (model, scheduler) = model(coordinator("A", on: true))
        defer { close(model, scheduler) }
        let akilu = importArc(into: model.store)
        model.checkCloudSidebar()
        await settle { model.cloudDetection != nil && !model.isCheckingCloud }
        #expect(model.cloudPresence(of: akilu) == .onlyHere, "not uploaded yet")
        #expect(ProfileCloudText.putInICloud(syncOn: true) == "Put in iCloud")
        scheduler.start()
        model.putInICloud(akilu)
        await settle { model.syncDetails?.phase == .upToDate }
        #expect(model.cloudPresence(of: akilu) == .inICloud)
        #expect(server.records(account: "fixture")[SyncRecordKind.profile.recordName(for: akilu)]?.payload.isAlive == true)
    }
}

/// Opens once; waiters before and after go on.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() {
        lock.lock(); isOpen = true; lock.unlock()
    }

    func wait() async {
        while true {
            lock.lock(); let done = isOpen; lock.unlock()
            if done { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
