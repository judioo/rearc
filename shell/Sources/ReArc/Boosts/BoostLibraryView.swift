import SwiftUI
import SidebarModel

/// The Library's Boosts page (View Boosts; Arc `BoostsPage`, BOOSTS §2, §5): the active
/// profile's boosts with a master switch, per-boost on/off, script consent,
/// and New, Edit, Rename, Duplicate, Open Site and Delete.
struct BoostLibraryView: View {
    let model: BrowserViewModel
    @State private var query = ""
    @State private var isCreating = false
    @State private var newName = ""
    @State private var newSite = ""
    @State private var createError: String?
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var deletingID: UUID?

    var body: some View {
        let rows = model.boostLibraryRows(filter: query)
        let total = model.store.boostLibrary().packages.count
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.store.activeProfile.name).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Toggle("Boosts On", isOn: Binding(
                    get: { model.boostsMasterEnabled },
                    set: { model.setBoostsMasterEnabled($0) }
                ))
                .toggleStyle(.switch)
                .help("Turn every boost in this profile on or off")
                Menu {
                    Button("Import Boosts…") { BoostFilePanels.importBoosts(model: model) }
                    Button("New Legacy Boost (Advanced)") {
                        if let error = model.newLegacyBoost() { createError = error; isCreating = true }
                    }
                    .disabled(model.store.selectedTab.map { !BoostScopeMatcher.urlIsEligibleForBoosts($0.url) } ?? true)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Import boost files, or a CSS and JavaScript boost for this page")
                Button {
                    newName = ""
                    newSite = model.store.selectedTab.flatMap { BoostScopeMatcher.defaultRule(forPage: $0.url)?.host } ?? ""
                    createError = nil
                    isCreating = true
                } label: {
                    Label("New Boost", systemImage: "plus")
                }
                .popover(isPresented: $isCreating, arrowEdge: .bottom) { newBoostForm }
            }
            .padding([.horizontal, .top], 16)

            if total > 3 {
                TextField("Search boosts", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding([.horizontal, .top], 16)
            }

            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "paintbrush.pointed").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(total == 0 ? "Boosts restyle the sites you visit. Create one for this page with New Boost." : "No matches.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    BoostLibraryRowView(
                        row: row,
                        masterEnabled: model.boostsMasterEnabled,
                        onToggle: { model.setBoostEnabled(row.id, enabled: $0) },
                        onAllowScript: { model.setBoostScriptAllowed(row.id, allowed: $0) },
                        onEdit: { model.editBoost(row.id) },
                        onOpenSite: { model.openBoostSite(row.id) }
                    )
                    .contextMenu { menu(for: row) }
                }
                .listStyle(.inset)
                .opacity(model.boostsMasterEnabled ? 1 : 0.6)
            }

            HStack {
                Text("\(total) boost\(total == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
        }
        .alert("Rename Boost", isPresented: Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingID = nil }
            Button("Save") {
                if let id = renamingID { model.renameBoost(id, to: renameText) }
                renamingID = nil
            }
        }
        .alert(deleteTitle, isPresented: Binding(
            get: { deletingID != nil },
            set: { if !$0 { deletingID = nil } }
        )) {
            Button("Cancel", role: .cancel) { deletingID = nil }
            Button("Delete Boost", role: .destructive) {
                if let id = deletingID { model.deleteBoost(id) }
                deletingID = nil
            }
        } message: {
            Text("Its styles stop applying to every site. This cannot be undone.")
        }
    }

    private var deleteTitle: String {
        let name = deletingID.flatMap { id in model.boostLibraryRows().first { $0.id == id }?.name } ?? "Boost"
        return "Delete “\(name)”?"
    }

    @ViewBuilder
    private func menu(for row: BoostLibraryRow) -> some View {
        Button(row.hasStyle ? "Edit on This Page" : "Edit Code…") { model.editBoost(row.id) }
            .disabled(row.hasStyle && !row.matchesCurrentPage)
        Button("Open Site") { model.openBoostSite(row.id) }
            .disabled(row.siteURL == nil)
        Divider()
        Button("Rename…") {
            renameText = row.name
            renamingID = row.id
        }
        Button("Duplicate") { model.duplicateBoost(row.id) }
        Button("Export…") { BoostFilePanels.export(row.id, model: model) }
        Divider()
        Button("Delete…", role: .destructive) { deletingID = row.id }
    }

    private var newBoostForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Boost").font(.headline)
            TextField("Name (optional)", text: $newName)
                .textFieldStyle(.roundedBorder)
            TextField("Site, e.g. github.com", text: $newSite)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if let createError {
                Text(createError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isCreating = false }
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func create() {
        if let error = model.createBoost(name: newName, site: newSite) {
            createError = error
        } else {
            isCreating = false
        }
    }
}

private struct BoostLibraryRowView: View {
    let row: BoostLibraryRow
    let masterEnabled: Bool
    let onToggle: (Bool) -> Void
    let onAllowScript: (Bool) -> Void
    let onEdit: () -> Void
    let onOpenSite: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: row.colorHex) ?? .accentColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).lineLimit(1)
                    if row.hasStyle { badge("CSS") }
                    if row.hasScript { badge("JS") }
                }
                Text(row.sites)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isHovering {
                if (row.matchesCurrentPage && row.hasStyle) || !row.hasStyle {
                    Button("Edit", action: onEdit).controlSize(.small)
                } else if row.siteURL != nil {
                    Button("Open Site", action: onOpenSite).controlSize(.small)
                }
            }
            if row.hasScript {
                Toggle("Allow Script", isOn: Binding(get: { row.scriptAllowed }, set: onAllowScript))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Script boosts run only after you allow their script")
            }
            Toggle("", isOn: Binding(get: { row.enabled }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(!masterEnabled)
                .help(masterEnabled ? (row.enabled ? "Turn this boost off" : "Turn this boost on") : "Boosts are off for this profile")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.secondary)
    }
}

extension Color {
    /// "#RRGGBB" (Boost metadata colours).
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
