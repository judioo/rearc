import Foundation
import SidebarModel
import SwiftUI

/// An install toast that waits while the sunrise covers the browser.
struct HeldExtensionToast: Equatable {
    var message: String
    var action: ShellToast.Action?
    var duration: TimeInterval
}

/// Background import work and terminal outcomes, saved beside the sidebar.
struct PendingExtensionReinstall: Codable, Equatable {
    static let fileName = "extension-reinstall.json"

    struct Result: Codable, Equatable {
        var status: Int32
        var reason: String
        var succeeded: Bool { status == 0 || status == 1 }
        var unavailable: Bool { ExtensionConsolidation.unavailable(status: status) }
    }

    var skipped: [ExtensionConsolidation.Skipped]? = nil
    var results: [String: Result]? = nil
    var outstandingItems: [ExtensionReinstallQueue.Item] {
        Array(queue.items.dropFirst(queue.position)).filter { $0.enabledByDefault != false && results?[$0.key] == nil }
    }

    var queue: ExtensionReinstallQueue
    /// "Arc", "Arc and Chrome": the browsers they came from.
    var from: String

    /// Command bar label while work remains, then its saved details.
    var title: String {
        let n = outstandingItems.count
        if n == 0 { return "Extension import details" }
        return "Install \(n) extension\(n == 1 ? "" : "s") from \(from)"
    }

    /// Completed results remain available for the command bar's details.
    static func load(from url: URL) -> PendingExtensionReinstall? {
        guard let pending = read(from: url),
              !pending.queue.isFinished || !(pending.skipped ?? []).isEmpty else { return nil }
        return pending
    }

    static func read(from url: URL) -> PendingExtensionReinstall? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Writes pending work and outcomes atomically; nil explicitly clears it.
    static func save(_ pending: PendingExtensionReinstall?, to url: URL) {
        guard let pending else {
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
    func queueExtensionReinstall(_ queue: ExtensionReinstallQueue, from: String, skipped: [ExtensionConsolidation.Skipped] = []) {
        var pending = PendingExtensionReinstall(skipped: skipped, queue: queue, from: from)
        // Retain terminal outcomes when a manual import repeats the same IDs.
        pending.results = PendingExtensionReinstall.read(from: pendingExtensionReinstallURL)?.results
        setPendingExtensionReinstall(pending)
    }

    func setPendingExtensionReinstall(_ pending: PendingExtensionReinstall?) {
        let pending = pending.flatMap { $0.queue.isFinished && ($0.skipped ?? []).isEmpty ? nil : $0 }
        pendingExtensionReinstall = pending
        PendingExtensionReinstall.save(pending, to: pendingExtensionReinstallURL)
    }

    /// Onboarding's import is the consent; no second decision interrupts it.
    func offerPendingExtensionReinstall() {
        installPendingExtensions()
    }

    /// The sunrise covers the browser: nothing installs, and progress and
    /// results wait for `releaseExtensionFeedback`.
    func holdExtensionFeedback() {
        extensionFeedbackHeld = true
    }

    /// The browser is on screen: the latest install toast held back shows
    /// now, with its full time (a result rather than stale progress).
    func releaseExtensionFeedback() {
        guard extensionFeedbackHeld else { return }
        extensionFeedbackHeld = false
        if let held = heldExtensionToast {
            heldExtensionToast = nil
            showToast(held.message, systemImage: "puzzlepiece.extension", action: held.action, duration: held.duration)
        }
    }

    /// Install progress and results: shown, or held while the sunrise is up.
    func showExtensionToast(_ message: String, action: ShellToast.Action? = nil, duration: TimeInterval = ShellToast.defaultDuration) {
        let toast = HeldExtensionToast(message: message, action: action, duration: duration)
        if extensionFeedbackHeld {
            heldExtensionToast = toast
        } else {
            showToast(toast.message, systemImage: "puzzlepiece.extension", action: toast.action, duration: toast.duration)
        }
    }

    func installPendingExtensions() {
        guard !extensionFeedbackHeld else { return }
        guard let pending = pendingExtensionReinstall, !pending.outstandingItems.isEmpty,
              extensionReinstallSession?.isInstalling != true, !isReconcilingExtensionInventory else { return }
        if pending.queue.items.contains(where: { $0.enabledByDefault == nil }) {
            isReconcilingExtensionInventory = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let inventory = BrowserImportDiscovery.discover().flatMap(\.profiles)
                    .flatMap { ExtensionInventoryReader.read(profile: $0.url) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isReconcilingExtensionInventory = false
                    guard self.pendingExtensionReinstall == pending else { return }
                    var refreshed = pending
                    refreshed.skipped = (refreshed.skipped ?? []) + refreshed.queue.reconcileLegacyInventory(inventory)
                    self.setPendingExtensionReinstall(refreshed)
                    self.installPendingExtensions()
                }
            }
            return
        }
        let session = ExtensionReinstallSession(model: self, pending: pending)
        extensionReinstallSession = session
        session.install()
    }

    /// Details never open the full importer or start another installation.
    func startPendingExtensionReinstall() {
        dismissToast()
        if extensionReinstallSession == nil {
            let pending = pendingExtensionReinstall ?? PendingExtensionReinstall.read(from: pendingExtensionReinstallURL)
            guard let pending else { return }
            extensionReinstallSession = ExtensionReinstallSession(model: self, pending: pending)
        }
        isExtensionReinstallPresented = true
    }

    /// Later: it stays queued, in the command bar.
    func postponePendingExtensionReinstall() {
        dismissToast()
    }

    func dismissToast() {
        withAnimation(ShellToast.outAnimation) { toast = nil }
    }
}
