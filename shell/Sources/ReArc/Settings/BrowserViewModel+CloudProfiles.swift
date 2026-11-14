import Foundation
import SidebarModel

/// Settings › Profiles and iCloud (docs/SYNC-RUNTIME.md, "Profiles in
/// iCloud"): which of this Mac's profiles iCloud has too, the profiles only
/// iCloud has, and deleting one profile from iCloud. Everything reads the
/// session's look (`cloudDetection`); a delete looks again first.
extension BrowserViewModel {
    /// Where the profile is: by the session's look, and once sync is on and
    /// up to date, in iCloud, whatever an older look said.
    func cloudPresence(of id: Profile.ID) -> ProfileCloudPresence {
        guard syncControl != nil else { return .unknown(CloudKitSyncAvailability.unavailableMessage) }
        var itemsRead: Int?
        if case .looking(let count) = cloudLook { itemsRead = count }
        if !isCheckingCloud, isSyncEnabled, syncDetails?.phase == .upToDate { return .inICloud }
        return .of(id, spaces: store.spaces, detection: cloudDetection, looking: isCheckingCloud, itemsRead: itemsRead)
    }

    /// The Profiles list's "In iCloud only": the last look's, also while one
    /// runs again. iCloud's copy of a profile of this Mac (another install's
    /// import of the same Arc spaces) is that profile, not listed here; one
    /// that only shares a space with a profile of this Mac is listed.
    var cloudOnlyProfiles: [CloudProfile] {
        cloudDetection?.found?.profiles(notIn: store.profiles, spaces: store.spaces) ?? []
    }

    /// Put in iCloud… can start: the look says only this Mac has it, and the switch isn't waiting.
    func canPutInICloud(_ id: Profile.ID) -> Bool {
        cloudPresence(of: id) == .onlyHere && !syncSwitchWaiting && syncCloudChoice == nil
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
    /// has too (iCloud's copy by its id, or another install's of the same
    /// spaces, which the question then names): asks, with what the session's
    /// look says would go. False when the look has no such profile.
    @discardableResult
    func requestCloudProfileDeletion(_ id: Profile.ID) -> Bool {
        let local = store.profile(withID: id)
        guard canDeleteFromICloud, let found = cloudDetection?.found,
              let cloud = local == nil ? found.profile(id) : found.profiles(matching: id, spaces: store.spaces, among: store.profiles).first,
              let plan = CloudProfileDeletion(profileID: cloud.id, in: Dictionary(found.records.map { ($0.recordName, $0) }) { _, last in last })
        else { return false }
        cloudProfileDeletes.notice = nil
        cloudProfileDeletes.request = CloudProfileDeleteRequest(profile: local ?? cloud.profile, plan: plan, onThisMac: local != nil,
                                                                cloudCopy: cloud.id == id ? nil : cloud)
        return true
    }

    func cloudProfileDeleteTitle(_ request: CloudProfileDeleteRequest) -> String {
        request.onThisMac ? ProfileCloudText.deleteTitle(request.profile.name) : ProfileCloudText.deleteFromICloudTitle(request.profile.name)
    }

    /// The question's text: each button's consequence in a line, and first,
    /// when iCloud's copy has another id, that profile by name with its spaces.
    func cloudProfileDeleteMessage(_ request: CloudProfileDeleteRequest) -> String {
        let receiving = cloudProfileNames(request.plan.receivingProfiles)
        let folder = sidebarBackupFolderName
        let syncOn = isSyncEnabled
        guard request.onThisMac else {
            return ProfileCloudText.deleteFromICloudMessage(request.plan, receiving: receiving, syncOn: syncOn, backupFolder: folder, changed: request.changed)
        }
        let both = ProfileCloudText.bothConsequence(request.plan, receiving: receiving, syncOn: syncOn, backupFolder: folder)
            + containersDeletedNote(request.profile.id, reachesICloud: true)
        let changed = request.changed ? "It changed in iCloud since you looked.\n\n" : ""
        let copy = request.cloudCopy.map { ProfileCloudText.cloudCopy($0) + "\n\n" } ?? ""
        if syncOn { return changed + copy + both + " This can't be undone." }
        return changed + copy + "\(ProfileCloudText.deleteFromThisMac): \(ProfileCloudText.thisMacConsequence)"
            + containersDeletedNote(request.profile.id, reachesICloud: false) + "\n\n"
            + "\(ProfileCloudText.deleteFromBoth): \(both)\n\nThis can't be undone."
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
            // iCloud's copy under another id is this profile's only while every space of it is: by this look, too.
            var cloudCopy: CloudProfile?
            if request.cloudCopy != nil, let current = found.profile(request.plan.profileID) {
                guard found.profiles(matching: profile.id, spaces: self.store.spaces, among: self.store.profiles).contains(where: { $0.id == current.id }) else {
                    deletes.working = nil
                    deletes.notice = CloudProfileNotice(text: ProfileCloudText.noLongerACopy(current.profile.name, of: profile.name), isError: true)
                    return
                }
                cloudCopy = current
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
                    deletes.request = CloudProfileDeleteRequest(profile: profile, plan: plan, onThisMac: request.onThisMac, changed: true, cloudCopy: cloudCopy)
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
    /// iCloud's copy when it has another id than `profile` (another install's
    /// import of the same spaces): the question names it and its spaces.
    var cloudCopy: CloudProfile?

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
