import SwiftUI
import SidebarModel

/// View Archive: closed and auto-archived tabs by time bucket, searchable,
/// with restore and Clear Archive (SIDEBAR-SPEC §2.9, DATA-SCHEMA §3).
struct ArchiveView: View {
    let model: BrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var confirmingClear = false

    var body: some View {
        let store = model.store
        let groups = TabArchivePolicy.grouped(store.archivedTabs, matching: query, now: Date())
        VStack(spacing: 0) {
            HStack {
                Text("Archive").font(.title2.weight(.semibold))
                Spacer()
                Menu("Archive Today Tabs After: \(store.autoArchiveThreshold().title)") {
                    ForEach(AutoArchiveThreshold.allCases, id: \.self) { threshold in
                        Button(threshold.title) { model.setAutoArchiveThreshold(threshold) }
                    }
                }
                .fixedSize()
                .help("Today tabs in \(store.activeProfile.name) not selected for this long move here")
            }
            .padding([.horizontal, .top], 16)

            TextField("Search archived tabs", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(16)

            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "archivebox").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "Closed and archived tabs appear here." : "No matches.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.bucket) { group in
                        Section(group.bucket.title) {
                            ForEach(group.records) { record in
                                row(record)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Button("Clear Archive…", role: .destructive) { confirmingClear = true }
                    .disabled(store.archivedTabs.isEmpty)
                Spacer()
                Text("\(store.archivedTabs.count) tab\(store.archivedTabs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
        .confirmationDialog("Clear the archive?", isPresented: $confirmingClear) {
            Button("Clear Archive", role: .destructive) { store.clearArchive() }
        } message: {
            Text("Archived tabs cannot be restored after this.")
        }
    }

    private func row(_ record: ArchivedTabRecord) -> some View {
        HStack(spacing: 10) {
            SiteIconView(image: model.faviconStore.image(for: record.tab.url), token: record.tab.faviconToken, size: 16)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.tab.displayTitle).lineLimit(1)
                Text(record.tab.url.host() ?? record.tab.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if record.reason == .auto {
                Text("Auto").font(.caption2).foregroundStyle(.secondary)
            }
            Text(record.archivedAt, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Restore") {
                model.restoreArchivedTab(record.id)
            }
            .controlSize(.small)
        }
        .contextMenu {
            Button("Restore") { model.restoreArchivedTab(record.id) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.tab.url.absoluteString, forType: .string)
            }
            Divider()
            Button("Remove from Archive") { model.store.removeArchivedTab(record.id) }
        }
    }
}
