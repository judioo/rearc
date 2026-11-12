import Foundation
import SidebarModel

/// Settings › Profiles and iCloud (docs/SYNC-RUNTIME.md, "Profiles in
/// iCloud"): which of this Mac's profiles iCloud has too, the profiles only
/// iCloud has, and deleting one profile from iCloud. Everything reads the
/// session's look (`cloudDetection`); a delete looks again first.
extension BrowserViewModel {
    func cloudPresence(of id: Profile.ID) -> ProfileCloudPresence {
        guard syncControl != nil else { return .unknown(CloudKitSyncAvailability.unavailableMessage) }
        var itemsRead: Int?
        if case .looking(let count) = cloudLook { itemsRead = count }
        return .of(id, detection: cloudDetection, looking: isCheckingCloud, itemsRead: itemsRead)
    }

    /// The Profiles list's "In iCloud only": the last look's, also while one runs again.
    var cloudOnlyProfiles: [CloudProfile] {
        cloudDetection?.found?.profiles(notIn: store.profiles) ?? []
    }

    func cloudOnlyProfile(_ id: Profile.ID) -> CloudProfile? {
        cloudOnlyProfiles.first { $0.id == id }
    }

    /// Nothing else is looking or deleting: a delete can start.
    var canDeleteFromICloud: Bool {
        syncControl != nil && !isCheckingCloud && cloudProfileDeletes.working == nil
    }

    func cloudProfileNames(_ ids: [Profile.ID]) -> [String] {
        ids.map { store.profile(withID: $0)?.name ?? cloudDetection?.found?.profile($0)?.profile.name ?? "another profile" }
    }

    /// Delete from iCloud…, or the delete of a profile of this Mac that iCloud
    /// has too: asks, with what the session's look says would go.
    func requestCloudProfileDeletion(_ id: Profile.ID) {
        guard canDeleteFromICloud, let found = cloudDetection?.found,
              let plan = CloudProfileDeletion(profileID: id, in: Dictionary(found.records.map { ($0.recordName, $0) }) { _, last in last }),
              let profile = store.profile(withID: id) ?? found.profile(id)?.profile else { return }
        cloudProfileDeletes.notice = nil
        cloudProfileDeletes.request = CloudProfileDeleteRequest(profile: profile, plan: plan, onThisMac: store.profile(withID: id) != nil)
    }

    /// The person confirmed: look at iCloud again and delete what is there
    /// now, backed up first; if it changed, ask again with the new counts.
    /// `alsoThisMac`: the profile goes from this Mac too, once iCloud's part is done.
    func deleteCloudProfile(_ request: CloudProfileDeleteRequest, alsoThisMac: Bool) {
        guard let control = syncControl else { return }
        let deletes = cloudProfileDeletes
        let profile = request.profile
        deletes.request = nil
        deletes.notice = nil
        deletes.working = profile.id
        checkCloudSidebar { [weak self] detection in
            guard let self else { return }
            guard case .found(let found) = detection else {
                deletes.working = nil
                switch detection {
                case .empty: deletes.notice = CloudProfileNotice(text: ProfileCloudText.gone(profile.name))
                case .signedOut(let message), .unreachable(let message), .unavailable(let message): deletes.notice = CloudProfileNotice(text: message, isError: true)
                case .found: break
                }
                return
            }
            let sidebarFile = self.persistence.fileURL
            Task { @MainActor [weak self] in
                let result = await control.deleteCloudProfile(
                    request.plan, in: found,
                    backup: { try SidebarBackup.writeCloudRecords($0, besides: sidebarFile) },
                    deleteLocally: alsoThisMac ? { [weak self] in _ = self?.deleteProfile(profile.id, deletingSpaces: true) } : nil
                )
                deletes.working = nil
                guard let self else { return }
                switch result {
                case .deleted(_, let detection, let queued):
                    self.cloudDetection = detection
                    deletes.notice = CloudProfileNotice(text: ProfileCloudText.deleted(profile.name, fromThisMacToo: alsoThisMac, queued: queued,
                                                                                       backupFolder: self.sidebarBackupFolderName))
                case .changed(let plan):
                    deletes.request = CloudProfileDeleteRequest(profile: profile, plan: plan, onThisMac: request.onThisMac, changed: true)
                case .gone(let detection):
                    self.cloudDetection = detection
                    deletes.notice = CloudProfileNotice(text: ProfileCloudText.gone(profile.name))
                case .failed(let message):
                    deletes.notice = CloudProfileNotice(text: message, isError: true)
                    // Part of it may have gone: show what iCloud holds now.
                    self.checkCloudSidebar()
                }
            }
        }
    }
}

/// A delete from iCloud waiting for the person's answer.
struct CloudProfileDeleteRequest: Identifiable, Equatable {
    var profile: Profile
    var plan: CloudProfileDeletion
    /// A profile of this Mac too: the answer is This Mac, or This Mac and iCloud.
    var onThisMac: Bool
    /// iCloud changed since the last answer: asked again with the new counts.
    var changed = false

    var id: Profile.ID { profile.id }
}

struct CloudProfileNotice: Equatable {
    var text: String
    var isError = false
}

/// Settings › Profiles' deletes from iCloud: the question asked, the one under
/// way and how the last one went. Owned by the model: closing Settings stops nothing.
@Observable
final class CloudProfileDeletes {
    var request: CloudProfileDeleteRequest?
    /// Looking again, then writing.
    var working: Profile.ID?
    var notice: CloudProfileNotice?
}
