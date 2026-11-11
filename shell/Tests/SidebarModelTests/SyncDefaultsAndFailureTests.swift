import Foundation
import Testing
@testable import SidebarModel
#if canImport(CloudKit)
import CloudKit
#endif

/// Local fixtures only: no entitlement or CloudKit account is needed.
@MainActor
struct SyncDefaultsAndFailureTests {
    private final class RejectingTransport: SidebarSyncTransport {
        let base: InMemorySyncTransport
        var rejectsBoost = true
        var throwsForBatch: Bool
        var attempts = 0

        init(server: InMemorySyncServer, throwsForBatch: Bool) {
            base = server.transport(account: "fixture")
            self.throwsForBatch = throwsForBatch
        }
        func accountStatus() async -> SyncAccountStatus { await base.accountStatus() }
        func prepareZone() async throws { try await base.prepareZone() }
        func fetchChanges(since token: Data?) async throws -> SyncFetchResult { try await base.fetchChanges(since: token) }
        func modify(saving records: [SyncWireRecord], deleting names: [String]) async throws -> SyncModifyResult {
            attempts += 1
            let rejected = records.filter { rejectsBoost && $0.payload.kind == .boost }
            if throwsForBatch, !rejected.isEmpty { throw SyncTransportError.schemaNotDeployed("Cannot create new type SidebarBoostRecord in production schema") }
            var result = try await base.modify(saving: records.filter { !rejectsBoost || $0.payload.kind != .boost }, deleting: names)
            for record in rejected {
                result.failures[record.recordName] = .schemaNotDeployed("Cannot create new type SidebarBoostRecord in production schema")
            }
            return result
        }
    }

    @Test func absentStateIsOffAndSavedOffSurvives() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-defaults-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SidebarSyncStateFile(fileURL: folder.appendingPathComponent("sync-state.json"))
        #expect(!file.load().isActive, "Sync Sidebar is off until the person turns it on")
        var state = SidebarSyncState()
        state.enabled = false
        file.save(state)
        #expect(!file.load().enabled)
        let coordinator = SidebarSyncCoordinator(transport: InMemorySyncServer().transport(account: "fixture"), stateStore: file, deviceID: "A")
        #expect(!coordinator.isEnabled)
        coordinator.setEnabled(true)
        #expect(file.load().isActive)
        coordinator.setEnabled(false)
        #expect(!file.load().enabled)
    }

    @Test(arguments: [false, true])
    func rejectedTypeDoesNotBlockOtherTypes(throwsForBatch: Bool) async throws {
        let server = InMemorySyncServer()
        let transport = RejectingTransport(server: server, throwsForBatch: throwsForBatch)
        var state = SidebarSyncState()
        state.enabled = true
        state.decision = .user
        state.joined = true
        var fixtureNames = Set<String>()
        for kind in SyncRecordKind.allCases {
            // Multiple batches as well as every live record kind.
            for _ in 0..<(kind == .item ? 220 : 1) {
                let name = kind.recordName(for: UUID())
                fixtureNames.insert(name)
                state.records[name] = SyncShadowRecord(payload: SyncRecordPayload(kind: kind), pending: true)
            }
        }
        let coordinator = SidebarSyncCoordinator(transport: transport, stateStore: InMemorySyncStateStore(state), deviceID: "A")
        let host = SidebarStore()
        coordinator.host = host
        let outcome = await coordinator.sync()
        #expect(outcome.error?.isSchemaError == true)
        #expect(coordinator.details.technicalError?.contains("SidebarBoostRecord") == true)
        #expect(coordinator.state.pendingCount == 1)
        let uploaded = server.records(account: "fixture")
        for name in fixtureNames {
            #expect((uploaded[name] != nil) == (SyncRecordKind.parse(recordName: name)?.kind != .boost))
        }
        // The rejected type waits out its cooldown; the rest syncs as usual.
        let attempts = transport.attempts
        let laterTab = host.addTab(kind: .pinned, title: "Later edit", url: URL(string: "https://later.invalid")!)
        #expect(await coordinator.sync().error?.isSchemaError == true)
        #expect(transport.attempts > attempts)
        #expect(server.records(account: "fixture").keys.contains(SyncRecordKind.item.recordName(for: laterTab.id)))
        #expect(coordinator.state.pendingCount == 1)
        transport.rejectsBoost = false
        coordinator.retrySchemaRejectedKinds()
        #expect(await coordinator.sync().error == nil)
        #expect(coordinator.state.pendingCount == 0)
        #expect(fixtureNames.isSubset(of: Set(server.records(account: "fixture").keys)))
    }

    @Test func schedulerGatesAllEntrypointsUntilStartedAndBacksOffSchemaFailures() async {
        let server = InMemorySyncServer()
        let transport = RejectingTransport(server: server, throwsForBatch: true)
        var state = SidebarSyncState()
        let name = SyncRecordKind.boost.recordName(for: UUID())
        state.records[name] = SyncShadowRecord(payload: SyncRecordPayload(kind: .boost), pending: true)
        var now = Date()
        let coordinator = SidebarSyncCoordinator(transport: transport, stateStore: InMemorySyncStateStore(state), deviceID: "A", now: { now })
        let scheduler = SidebarSyncScheduler(coordinator: coordinator)
        let host = SidebarStore()
        scheduler.attach(host: host)
        scheduler.sleeper = { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        scheduler.setUserEnabled(true)
        scheduler.syncNow()
        await scheduler.runCycle()
        #expect(server.fetchCount == 0)
        #expect(transport.attempts == 0)
        scheduler.start()
        await scheduler.runCycle()
        let attempts = transport.attempts
        #expect(attempts > 0)
        for _ in 0..<10 { await scheduler.runCycle() }
        #expect(transport.attempts == attempts, "edits and polls don't resend a schema-rejected type")
        now = now.addingTimeInterval(SidebarSyncCoordinator.schemaRetryInterval + 1)
        await scheduler.runCycle()
        #expect(transport.attempts > attempts)
        scheduler.stop()
    }

    @Test func commonErrorsHaveReadableMessagesAndSeparateTechnicalDetails() {
        for error in [SyncTransportError.networkUnavailable, .notAuthenticated, .quotaExceeded, .schemaNotDeployed("Cannot create new field payload in production schema"), .other("<CKRecordID: private-fixture>")] {
            var details = SyncStatusDetails(phase: .failed(error.userMessage))
            details.technicalError = error.technicalDetail
            let presentation = SyncSettingsPresentation(details: details, enabled: true)
            #expect(presentation.errorText == error.userMessage)
            #expect(presentation.technicalError == error.technicalDetail)
            #expect(presentation.errorText?.contains("CKRecordID") == false)
            #expect(presentation.errorText?.contains("production schema") == false)
        }
    }

    #if canImport(CloudKit)
    @Test func cloudKitErrorsMapWithoutAnAccount() {
        let zone = CKRecordZone.ID(zoneName: "fixture", ownerName: CKCurrentUserDefaultName)
        for (code, message) in [(CKError.Code.serverRejectedRequest, "Cannot create new type SidebarBoostRecord in production schema"),
                                (.serverRejectedRequest, "Cannot create new field payload in production schema"),
                                (.invalidArguments, "Cannot create or modify field 'clientTimestamp' in record 'SidebarBoostRecord' in production schema")] {
            let error = CKError(code, userInfo: [NSLocalizedDescriptionKey: message])
            #expect(CloudKitSyncTransport.map(error, zoneID: zone) == .schemaNotDeployed(message))
        }
        let other = CKError(.invalidArguments, userInfo: [NSLocalizedDescriptionKey: "Bad record name"])
        #expect(CloudKitSyncTransport.map(other, zoneID: zone) == .other("Bad record name"))
        #expect(CloudKitSyncTransport.map(CKError(.networkUnavailable), zoneID: zone) == .networkUnavailable)
        #expect(CloudKitSyncTransport.map(CKError(.notAuthenticated), zoneID: zone) == .notAuthenticated)
        #expect(CloudKitSyncTransport.map(CKError(.quotaExceeded), zoneID: zone) == .quotaExceeded)
    }
    #endif
}
