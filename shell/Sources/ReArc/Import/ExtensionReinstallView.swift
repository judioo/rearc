import SidebarModel
import SwiftUI

@Observable
final class ExtensionReinstallSession {
    let items: [ExtensionReinstallQueue.Item]
    private(set) var pending: PendingExtensionReinstall
    private(set) var isInstalling = false
    private(set) var hasFinished = false
    private(set) var completed = 0
    private(set) var total = 0
    @ObservationIgnored private weak var model: BrowserViewModel?

    init(model: BrowserViewModel, pending: PendingExtensionReinstall) {
        self.model = model
        self.pending = pending
        items = Array(pending.queue.items.dropFirst(pending.queue.position))
        hasFinished = pending.outstandingItems.isEmpty
    }

    var supportsBulkInstall: Bool {
        #if REARC_CHROMIUM
        return ChromiumRuntime.active?.supportsBulkExtensionInstall == true
        #else
        return false
        #endif
    }
    var failures: [ExtensionReinstallQueue.Item] {
        items.filter { pending.results?[$0.key]?.status == 3 }
    }
    var unavailable: [ExtensionReinstallQueue.Item] {
        items.filter { pending.results?[$0.key]?.unavailable == true }
    }
    var installed: Int {
        items.filter { pending.results?[$0.key]?.status == 0 }.count
    }
    var summary: String {
        var text = "\(installed) installed."
        if !failures.isEmpty { text += " \(failures.count) couldn't be installed." }
        if !unavailable.isEmpty { text += " \(unavailable.count) not available." }
        return text
    }
    var storeFallbacks: [ExtensionReinstallQueue.Item] {
        if supportsBulkInstall { return failures }
        return items.filter { pending.results?[$0.key] == nil || pending.results?[$0.key]?.status == 3 }
    }

    func postpone() { model?.isExtensionReinstallPresented = false }
    func openStore(_ item: ExtensionReinstallQueue.Item) { model?.openExtensionForReinstall(item) }

    func install() {
        guard !isInstalling, !hasFinished else { return }
        guard supportsBulkInstall else {
            // Older engines retain the queue and expose store links on demand.
            model?.showToast("Extensions are ready in the Chrome Web Store", systemImage: "puzzlepiece.extension", action: .reinstallExtensions)
            return
        }
        let chosen = pending.outstandingItems
        guard !chosen.isEmpty else { return }
        total = chosen.count
        isInstalling = true
        model?.isExtensionReinstallPresented = false
        progress()
        // The engine limits store downloads to three. Profiles and unpacked
        // folders run in turn, so an explicit profile close cannot race a job.
        run(chosen)
    }

    private func run(_ remaining: [ExtensionReinstallQueue.Item]) {
        guard let first = remaining.first else {
            isInstalling = false
            hasFinished = true
            model?.dismissToast()
            var message = "\(installed) extensions installed"
            if !failures.isEmpty { message += ". \(failures.count) couldn't be installed" }
            if !unavailable.isEmpty { message += ". \(unavailable.count) not available" }
            model?.showToast(message, systemImage: "puzzlepiece.extension", action: failures.isEmpty && unavailable.isEmpty ? nil : .reinstallExtensions)
            return
        }
        #if REARC_CHROMIUM
        guard let runtime = ChromiumRuntime.active else {
            for item in remaining { record(item, status: 3, reason: "The Chromium engine is unavailable.") }
            run([])
            return
        }
        let group: [ExtensionReinstallQueue.Item]
        if first.origin == .webStore {
            group = Array(remaining.prefix { $0.profileID == first.profileID && $0.origin == .webStore }.prefix(512))
        } else {
            group = [first]
        }
        runtime.installExtensions(group) { [self] item, status, reason, done in
            record(item, status: status, reason: reason)
            if done { run(Array(remaining.dropFirst(group.count))) }
        }
        #endif
    }

    private func record(_ item: ExtensionReinstallQueue.Item, status: Int32, reason: String) {
        if pending.results == nil { pending.results = [:] }
        pending.results?[item.key] = .init(status: status, reason: reason)
        if status == 1 {
            pending.skipped = (pending.skipped ?? []) + [ExtensionConsolidation.Skipped(id: item.id, name: item.name, reason: "already installed")]
        }
        completed += 1
        // Record each terminal result before starting the next group. A crash
        // mid-download is safe: Chromium reports already installed on retry.
        if let model { PendingExtensionReinstall.save(pending, to: model.pendingExtensionReinstallURL) }
        model?.pendingExtensionReinstall = pending
        progress()
    }

    private func progress() {
        model?.showToast("Installing extensions… \(completed) of \(total)", systemImage: "puzzlepiece.extension", duration: 3600)
    }
}

/// Opened only when the user asks for details from the toast or command bar.
struct ExtensionReinstallView: View {
    @Bindable var session: ExtensionReinstallSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session.isInstalling ? "Installing extensions… \(session.completed) of \(session.total)" : session.hasFinished ? session.summary : "Extensions to install").font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.storeFallbacks, id: \.key) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name)
                                if let result = session.pending.results?[item.key], !result.reason.isEmpty {
                                    Text(result.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(item.origin == .webStore ? "Open in Web Store" : "Load Unpacked…") { session.openStore(item) }
                        }
                    }
                    ForEach(session.unavailable, id: \.key) { item in
                        Text("\(item.name): not available — \(session.pending.results?[item.key]?.reason ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array((session.pending.skipped ?? []).enumerated()), id: \.offset) { _, item in
                        Text("\(item.name): \(item.reason)").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(2)
            }.frame(maxHeight: 320)
            HStack { Spacer(); Button("Done") { session.postpone() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 520)
    }
}
