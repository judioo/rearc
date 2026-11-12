import SidebarModel
import SwiftUI

/// Settings › Max (FEATURE-SPECS/MAX.md): Arc's tab in Arc's place and
/// layout (banner, introduction, Enable Max, the rows, a footer), holding
/// only scripted helpers. No AI: each follows fixed rules on this Mac and
/// sends nothing. The banner and row drawings are ReArc's own, in the
/// sunrise mark's colours.
struct MaxSettingsPane: View {
    @Bindable var model: BrowserViewModel
    @State private var addingAssistant = false

    static let intro = "Small scripted helpers. No AI: they follow fixed rules on this Mac and send nothing."
    static let assistantsIntro = "An assistant here is only a shortcut to that company’s own site: ReArc opens the site with what you typed. ReArc itself runs no AI."
    static let footer = "These run on this Mac. Nothing is sent."
    static let assistantsFooter = "An assistant opens its own site with what you typed."

    /// The four helper rows, in Arc's order (its 5-Second Previews row is not kept).
    static let helperRows: [MaxFeature] = [.tidyTabs, .instantLinks, .tidyTabTitles, .tidyDownloads]

    var body: some View {
        SettingsPage(topPadding: 0) { rows }
            .sheet(isPresented: $addingAssistant) {
                AddAssistantSheet(add: { model.addCustomAssistant(name: $0, keyword: $1, template: $2) })
            }
    }

    /// The page's boxes, in order (`SettingsPage` lays them out).
    @ViewBuilder var rows: some View {
        MaxBanner()
            .padding(.horizontal, -SettingsMetrics.margin)
            .padding(.bottom, 22)
        SettingsIntro(text: Self.intro)
            .padding(.bottom, 14)
        SettingsGroup {
            SettingsLabeledRow(label: "Enable Max") {
                Button(model.allMaxFeaturesOn ? "All On" : "Turn On All") { model.turnOnAllMaxFeatures() }
                    .disabled(model.allMaxFeaturesOn)
            }
            SettingsSwitchRow(label: "Automatically enable future Max features",
                              isOn: $model.maxPreferences.enablesFutureFeatures)
        }
        SettingsGroup {
            ForEach(Self.helperRows, id: \.self) { feature in
                MaxFeatureRow(feature: feature, isOn: binding(for: feature))
            }
        }
        .padding(.top, 8)
        SettingsHeader(title: "Assistants").padding(.top, 10)
        SettingsIntro(text: Self.assistantsIntro).padding(.bottom, 6)
        SettingsGroup {
            MaxFeatureRow(feature: .assistants, isOn: binding(for: .assistants))
            ForEach(model.commandBarAssistants) { assistant in
                AssistantRow(assistant: assistant,
                             isOn: Binding(get: { model.isAssistantEnabled(assistant.id) },
                                           set: { model.setAssistant(assistant.id, enabled: $0) }),
                             remove: assistant.isCustom ? { model.removeCustomAssistant(assistant.id) } : nil)
                    .disabled(!model.isMaxFeatureOn(.assistants))
            }
            SettingsLabeledRow(label: "Another assistant or site", detail: "Its address, with %s where your text goes.") {
                Button("Add Your Own…") { addingAssistant = true }
            }
        }
        VStack(spacing: 2) {
            Text(Self.footer)
            Text(Self.assistantsFooter)
        }
        .font(.system(size: 12))
        .foregroundStyle(SettingsColors.tertiary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.top, 14)
    }

    private func binding(for feature: MaxFeature) -> Binding<Bool> {
        Binding(get: { model.isMaxFeatureOn(feature) }, set: { model.setMaxFeature(feature, on: $0) })
    }
}

/// One helper: its drawing, title, what its rule does, and the switch.
private struct MaxFeatureRow: View {
    let feature: MaxFeature
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            MaxIllustration(feature: feature)
                .frame(width: 88, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title).font(.system(size: 13))
                Text(feature.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsColors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(feature.title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityHint(feature.detail)
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 10)
    }
}

/// One assistant: its tint and initial, name, keyword, what opening it does.
private struct AssistantRow: View {
    let assistant: CommandBarAssistant
    @Binding var isOn: Bool
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(String(assistant.name.prefix(1)))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(red: assistant.tint.red, green: assistant.tint.green, blue: assistant.tint.blue)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(assistant.name).font(.system(size: 13))
                    Text(assistant.keyword)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(SettingsColors.button, in: RoundedRectangle(cornerRadius: 3))
                        .help("Type “\(assistant.keyword)” in the command bar, then Tab")
                }
                Text(assistant.note).font(.system(size: 11)).foregroundStyle(SettingsColors.tertiary)
            }
            Spacer(minLength: 12)
            if let remove {
                Button("Remove", action: remove)
            }
            Toggle(assistant.name, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 6)
        .frame(minHeight: SettingsMetrics.iconRowHeight)
    }
}

/// Add Your Own…: name, keyword and an https address with one %s.
private struct AddAssistantSheet: View {
    /// The problem to show, or nil once added.
    let add: (String, String, String) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keyword = ""
    @State private var template = "https://"
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an Assistant").font(.headline)
            Text("A shortcut to a site that takes your text in its address. ReArc opens that address; it runs no AI itself.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("My Assistant"))
                TextField("Keyword", text: $keyword, prompt: Text("mine"))
                TextField("Address", text: $template, prompt: Text("https://example.com/?q=%s"))
            }
            .formStyle(.columns)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    problem = add(name, keyword, template)
                    if problem == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .buttonStyle(.automatic)
    }
}

// MARK: Drawings

/// The sunrise mark's colours (brand/BRAND.md).
enum MaxPalette {
    static let sun = ReArcMark.sunColor
    static let ultramarine = ReArcMark.blueColor
    static let navy = ReArcMark.navyColor
    static let amber = Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
    static let dawn = Color(red: 1, green: 0.93, blue: 0.86)
}

/// The tab's banner: an ultramarine sky with small suns rising over
/// horizons, "Max" in white, and Arc's scalloped lower edge.
private struct MaxBanner: View {
    /// Where the small suns sit, as fractions of the banner, and their sizes.
    private static let suns: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (0.06, 0.62, 30), (0.17, 0.22, 16), (0.33, 0.70, 14), (0.70, 0.20, 18), (0.84, 0.60, 26), (0.97, 0.28, 14),
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [MaxPalette.navy, MaxPalette.ultramarine], startPoint: .top, endPoint: .bottom)
            ForEach(Array(Self.suns.enumerated()), id: \.offset) { _, sun in
                GeometryReader { proxy in
                    RisingSun(size: sun.size)
                        .position(x: proxy.size.width * sun.x, y: proxy.size.height * sun.y)
                }
            }
            HStack(spacing: 10) {
                RisingSun(size: 34)
                Text("Max")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: MaxPalette.navy.opacity(0.5), radius: 0, x: 2, y: 3)
            }
            .offset(y: -4)
        }
        .frame(height: 104)
        .clipShape(ScallopedBottom(scallop: 14, depth: 5))
        .accessibilityElement()
        .accessibilityLabel("Max")
    }
}

/// A half sun over a short horizon line, ReArc's mark reduced to a glyph.
private struct RisingSun: View {
    let size: CGFloat

    var body: some View {
        Canvas { context, canvas in
            let horizon = canvas.height * 0.68
            let radius = canvas.width * 0.36
            var sun = Path()
            sun.addArc(center: CGPoint(x: canvas.width / 2, y: horizon), radius: radius,
                       startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            sun.closeSubpath()
            context.fill(sun, with: .color(MaxPalette.sun))
            var line = Path()
            line.move(to: CGPoint(x: canvas.width * 0.06, y: horizon + canvas.height * 0.08))
            line.addLine(to: CGPoint(x: canvas.width * 0.94, y: horizon + canvas.height * 0.08))
            context.stroke(line, with: .color(MaxPalette.amber), style: StrokeStyle(lineWidth: max(1.5, canvas.height * 0.09), lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A broom (Tidy Tabs' button and drawing): a handle and fanned bristles.
struct BroomShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        // Handle, top right to the bristles' band.
        path.move(to: CGPoint(x: rect.minX + w * 0.86, y: rect.minY + h * 0.04))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.95, y: rect.minY + h * 0.12))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.55, y: rect.minY + h * 0.56))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.46, y: rect.minY + h * 0.47))
        path.closeSubpath()
        // Bristles.
        path.move(to: CGPoint(x: rect.minX + w * 0.40, y: rect.minY + h * 0.44))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.60, y: rect.minY + h * 0.64))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.30, y: rect.minY + h * 0.98))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.02, y: rect.minY + h * 0.72))
        path.closeSubpath()
        return path
    }
}

/// Each row's small drawing of what its rule does.
private struct MaxIllustration: View {
    let feature: MaxFeature

    var body: some View {
        ZStack {
            background
            content
        }
        .accessibilityHidden(true)
    }

    private var background: Color {
        switch feature {
        case .tidyTabs: return MaxPalette.ultramarine.opacity(0.16)
        case .instantLinks: return MaxPalette.amber.opacity(0.2)
        case .tidyTabTitles: return MaxPalette.sun.opacity(0.18)
        case .tidyDownloads: return MaxPalette.navy.opacity(0.85)
        case .assistants: return MaxPalette.dawn
        }
    }

    @ViewBuilder private var content: some View {
        switch feature {
        case .tidyTabs:
            HStack(spacing: 6) {
                VStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule().fill(MaxPalette.ultramarine.opacity(index % 2 == 0 ? 0.55 : 0.35)).frame(width: 30, height: 4)
                    }
                }
                BroomShape().fill(MaxPalette.sun).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    folder(MaxPalette.ultramarine)
                    folder(MaxPalette.amber)
                }
            }
        case .instantLinks:
            VStack(spacing: 5) {
                HStack(spacing: 3) {
                    Image(systemName: "magnifyingglass").font(.system(size: 7, weight: .bold))
                    Capsule().fill(.primary.opacity(0.35)).frame(width: 26, height: 3)
                    Spacer(minLength: 0)
                    Text("⇧↩").font(.system(size: 7, weight: .bold))
                }
                .padding(.horizontal, 5)
                .frame(width: 66, height: 14)
                .background(.white, in: RoundedRectangle(cornerRadius: 4))
                Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold)).foregroundStyle(MaxPalette.sun)
                RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 66, height: 12)
                    .overlay(alignment: .leading) { Capsule().fill(MaxPalette.ultramarine).frame(width: 30, height: 3).padding(.leading, 5) }
            }
            .foregroundStyle(MaxPalette.navy)
        case .tidyTabTitles:
            VStack(alignment: .leading, spacing: 5) {
                pill(width: 70, highlighted: false)
                    .overlay { Rectangle().fill(MaxPalette.sun).frame(height: 1) }
                pill(width: 40, highlighted: true)
            }
        case .tidyDownloads:
            HStack(spacing: 5) {
                Image(systemName: "doc.fill").font(.system(size: 18)).foregroundStyle(.white.opacity(0.9))
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(.white.opacity(0.35)).frame(width: 40, height: 4)
                    Capsule().fill(MaxPalette.amber).frame(width: 30, height: 4)
                }
            }
        case .assistants:
            HStack(spacing: 4) {
                Image(systemName: "command").font(.system(size: 8, weight: .bold))
                Capsule().fill(MaxPalette.ultramarine).frame(width: 18, height: 8)
                Capsule().fill(.primary.opacity(0.25)).frame(width: 30, height: 4)
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(.white, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(MaxPalette.navy)
        }
    }

    private func folder(_ color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "folder.fill").font(.system(size: 8)).foregroundStyle(color)
            Capsule().fill(color.opacity(0.5)).frame(width: 14, height: 3)
        }
    }

    private func pill(width: CGFloat, highlighted: Bool) -> some View {
        HStack(spacing: 3) {
            Circle().fill(MaxPalette.ultramarine).frame(width: 5, height: 5)
            Capsule().fill(highlighted ? MaxPalette.navy.opacity(0.7) : .primary.opacity(0.25)).frame(width: width - 14, height: 3)
        }
        .padding(.horizontal, 4)
        .frame(width: width, height: 11, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 3))
    }
}
