import Foundation
import SidebarModel
import SwiftUI

/// Extensions the onboarding queued to reinstall (PROFILE-IMPORT §3.3).
/// The onboarding is a full-screen takeover, so no store page opens during
/// it: once the browser is shown a toast offers Start and Later, and Start
/// steps through the Import window's footer. Kept beside the sidebar file,
/// so Later survives a relaunch; the command bar offers it until it is done.
struct PendingExtensionReinstall: Codable, Equatable {
    static let fileName = "extension-reinstall.json"

    var queue: ExtensionReinstallQueue
    /// "Arc", "Arc and Chrome": the browsers they came from.
    var from: String

    /// "Reinstall 9 extensions from Arc"
    var title: String {
        let n = queue.remaining
        return "Reinstall \(n) extension\(n == 1 ? "" : "s") from \(from)"
    }

    /// Nil when the file is missing or unreadable, or the queue is done.
    static func load(from url: URL) -> PendingExtensionReinstall? {
        guard let data = try? Data(contentsOf: url),
              let pending = try? JSONDecoder().decode(PendingExtensionReinstall.self, from: data),
              !pending.queue.isFinished else { return nil }
        return pending
    }

    /// Writes `pending`, or removes the file when it is nil or finished.
    static func save(_ pending: PendingExtensionReinstall?, to url: URL) {
        guard let pending, !pending.queue.isFinished else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pending).write(to: url, options: [.atomic])
        } catch {
            FileHandle.standardError.write(Data("[ReArc] could not save \(url.lastPathComponent): \(error.localizedDescription)\n".utf8))
        }
    }
}

extension BrowserViewModel {
    /// Queues them (replacing any earlier queue) and saves it; nothing opens.
    func queueExtensionReinstall(_ queue: ExtensionReinstallQueue, from: String) {
        setPendingExtensionReinstall(queue.isFinished ? nil : PendingExtensionReinstall(queue: queue, from: from))
    }

    func setPendingExtensionReinstall(_ pending: PendingExtensionReinstall?) {
        let pending = pending.flatMap { $0.queue.isFinished ? nil : $0 }
        pendingExtensionReinstall = pending
        PendingExtensionReinstall.save(pending, to: pendingExtensionReinstallURL)
    }

    /// The browser is shown: "Reinstall 9 extensions from Arc", Start or Later.
    /// Letting the toast go is Later.
    func offerPendingExtensionReinstall() {
        guard let pending = pendingExtensionReinstall else { return }
        showToast(pending.title, systemImage: "puzzlepiece.extension", action: .reinstallExtensions,
                  duration: ShellToast.choiceDuration)
    }

    /// Start: the Import window's footer steps through the queue.
    func startPendingExtensionReinstall() {
        guard let pending = pendingExtensionReinstall else { return }
        dismissToast()
        showBrowserImport()
        browserImportWindow?.session.resumeReinstall(pending.queue)
    }

    /// Later: it stays queued, in the command bar.
    func postponePendingExtensionReinstall() {
        dismissToast()
    }

    func dismissToast() {
        withAnimation(ShellToast.outAnimation) { toast = nil }
    }
}
