import SwiftUI
import SidebarModel

struct BoostEditorDrawerView: View {
    @Bindable var model: BrowserViewModel
    let draft: BoostEditorDraft

    @State private var cssText: String = ""
    @State private var drawerWidth: CGFloat = 360

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                selectorSection
                Divider()
                cssEditor
                Divider()
                quickActions
                Divider()
                footer
            }
            .frame(width: drawerWidth)
            .background(.regularMaterial)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 4)
                    .gesture(
                        DragGesture()
                            .onChanged { g in
                                drawerWidth = min(560, max(280, drawerWidth - g.translation.width))
                            }
                    )
            }
        }
        .onAppear { cssText = draft.draftCSS }
        .onChange(of: draft.draftCSS) { _, new in
            if cssText != new { cssText = new }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Boost editor")
                    .font(.headline)
                if draft.selectorDead {
                    Button("Selector died — re-pick") {
                        model.startBoostPicker()
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                } else if let tab = model.store.selectedTab,
                          model.sessionHealedBoostIDs(for: tab).contains(draft.packageID) {
                    Text("Healed for this session")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                model.toggleBoostPicker()
            } label: {
                Label("Pick element", systemImage: "scope")
            }
            .help("Pick element to edit (Esc cancels)")
        }
        .padding(12)
    }

    @ViewBuilder
    private var selectorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Target selector")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let sel = draft.selectedSelector {
                Text(sel)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2)
            } else {
                Text("Pick an element on the page")
                    .foregroundStyle(.tertiary)
            }
            if !draft.candidateChoices.isEmpty {
                Text("Top candidates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(draft.candidateChoices.enumerated()), id: \.offset) { idx, choice in
                    Button {
                        model.selectBoostCandidate(at: idx)
                    } label: {
                        HStack {
                            Text(choice.displayLabel)
                                .font(.system(.caption, design: .monospaced))
                                .multilineTextAlignment(.leading)
                            Spacer()
                            if draft.selectedSelector == choice.candidate.css {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cssEditor: some View {
        TextEditor(text: $cssText)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(maxHeight: .infinity)
            .onChange(of: cssText) { _, new in
                model.boostEditorCSSChanged(new)
            }
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            Button("Hide element") { model.boostQuickHide() }
            Button("Zap similar") { model.boostQuickZapSimilar() }
            Button("Edit styles") { model.boostQuickEditStyles() }
        }
        .buttonStyle(.bordered)
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { model.cancelBoostEditor() }
            Spacer()
            Button("Save") { model.saveBoostEditor() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!draft.isDirty && !draft.selectorDead)
        }
        .padding(12)
    }
}
