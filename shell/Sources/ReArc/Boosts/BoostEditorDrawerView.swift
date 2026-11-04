import AppKit
import SwiftUI
import SidebarModel

/// The Boosts editor drawer (Arc's Boosts Editor, BOOSTS §3): colour (hue
/// ring, intensity, harmony), dark mode, font and text size, zaps, and the
/// hand-written CSS for the picked element. Changes preview live; Save
/// writes them to the boost.
struct BoostEditorDrawerView: View {
    @Bindable var model: BrowserViewModel
    let draft: BoostEditorDraft

    @State private var cssText: String = ""
    @State private var drawerWidth: CGFloat = 360
    @State private var showsCSS = false

    var body: some View {
        let visual = draft.visual
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        colorSection(visual)
                        Divider()
                        Toggle("Dark Mode", isOn: Binding(
                            get: { visual.darkMode },
                            set: { on in model.updateBoostVisual { $0.darkMode = on } }
                        ))
                        .toggleStyle(.switch)
                        .help("Turn the site dark; pictures and video keep their colours")
                        Divider()
                        fontSection(visual)
                        Divider()
                        zapSection(visual)
                        Divider()
                        selectorSection
                        DisclosureGroup("Custom CSS", isExpanded: $showsCSS) {
                            cssEditor
                        }
                    }
                    .padding(12)
                }
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
                                drawerWidth = min(560, max(300, drawerWidth - g.translation.width))
                            }
                    )
            }
        }
        .onAppear {
            cssText = draft.customCSS
            showsCSS = !draft.customCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && draft.customCSS.trimmingCharacters(in: .whitespacesAndNewlines) != "/* ReArc boost */"
        }
        .onChange(of: draft.customCSS) { _, new in
            if cssText != new { cssText = new }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Boost").font(.headline)
                if draft.selectorDead {
                    Button("Selector died — re-pick") { model.startBoostPicker() }
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let tab = model.store.selectedTab,
                          model.sessionHealedBoostIDs(for: tab).contains(draft.packageID) {
                    Text("Healed for this session").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                model.toggleBoostPicker()
            } label: {
                Label("Pick", systemImage: "scope")
            }
            .help("Pick an element to edit (Esc cancels)")
        }
        .padding(12)
    }

    // MARK: Colour

    private func colorSection(_ visual: BoostVisualStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Colour", isOn: Binding(
                get: { visual.tint != nil },
                set: { on in model.updateBoostVisual { $0.tint = on ? ($0.tint ?? BoostTint(hue: 0.6)) : nil } }
            ))
            .toggleStyle(.switch)
            if let tint = visual.tint {
                HStack(spacing: 6) {
                    ForEach(BoostTint.namedHues, id: \.name) { named in
                        Button { model.updateBoostVisual { $0.tint?.hue = named.hue } } label: {
                            Circle()
                                .fill(Color(hue: named.hue, saturation: 0.8, brightness: 0.9))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.primary.opacity(abs(tint.hue - named.hue) < 0.005 ? 0.9 : 0.1), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(named.name)
                    }
                }
                LabeledContent("Hue") {
                    Slider(value: Binding(get: { tint.hue }, set: { hue in model.updateBoostVisual { $0.tint?.hue = hue } }), in: 0 ... 1)
                        .background(
                            LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 0.8, brightness: 0.9) },
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(height: 4)
                                .clipShape(Capsule())
                        )
                }
                LabeledContent("Intensity") {
                    Slider(value: Binding(get: { tint.intensity }, set: { value in model.updateBoostVisual { $0.tint?.intensity = value } }), in: 0 ... 1)
                }
                Picker("Harmony", selection: Binding(
                    get: { tint.harmony },
                    set: { harmony in model.updateBoostVisual { $0.tint?.harmony = harmony } }
                )) {
                    ForEach(BoostColorHarmony.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: Font

    private func fontSection(_ visual: BoostVisualStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Button("Site’s Own") { model.updateBoostVisual { $0.font = nil } }
                Divider()
                ForEach(BoostFontChoice.presets, id: \.title) { font in
                    Button(font.title) { model.updateBoostVisual { $0.font = font } }
                }
                Menu("Installed Fonts") {
                    ForEach(Self.installedFamilies, id: \.self) { family in
                        Button(family) { model.updateBoostVisual { $0.font = .family(family) } }
                    }
                }
            } label: {
                LabeledContent("Font", value: visual.font?.title ?? "Site’s Own")
            }
            .menuStyle(.borderlessButton)
            LabeledContent("Text Size") {
                HStack {
                    Slider(value: Binding(
                        get: { visual.textScale },
                        set: { value in model.updateBoostVisual { $0.textScale = (value * 20).rounded() / 20 } }
                    ), in: BoostVisualStyle.textScaleRange)
                    Text("\(Int((visual.textScale * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    /// Installed families whose names a boost can carry.
    private static let installedFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .compactMap(BoostFontChoice.safeFamilyName)
        .filter { !$0.hasPrefix(".") }

    // MARK: Zaps

    private func zapSection(_ visual: BoostVisualStyle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Zaps").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    model.startBoostPicker(zap: true)
                } label: {
                    Label("Zap an Element", systemImage: "bolt.fill")
                }
                .help("Click an element on the page to hide it")
            }
            if draft.zapOnPick, draft.pickerActive {
                Text("Click the element to zap — Esc to cancel").font(.caption).foregroundStyle(.secondary)
            }
            if visual.zaps.isEmpty {
                Text("Zapped elements are hidden every time the site loads.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(visual.zaps, id: \.self) { zap in
                HStack {
                    Text(zap)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button { model.updateBoostVisual { $0.removeZap(zap) } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show this element again")
                }
            }
        }
    }

    // MARK: Selected element and CSS

    @ViewBuilder
    private var selectorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected element").font(.caption).foregroundStyle(.secondary)
            if let sel = draft.selectedSelector {
                Text(sel)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2)
                if draft.candidateChoices.count > 1 {
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
                HStack(spacing: 8) {
                    Button("Zap") { model.boostQuickHide() }
                    Button("Zap Similar") { model.boostQuickZapSimilar() }
                    Button("Edit Styles") {
                        model.boostQuickEditStyles()
                        showsCSS = true
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text("Pick an element to zap it or style it").foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cssEditor: some View {
        TextEditor(text: $cssText)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 140)
            .onChange(of: cssText) { _, new in
                model.boostEditorCSSChanged(new)
            }
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
