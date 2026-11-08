import AppKit
import SidebarModel
import SwiftUI

/// Arc's Settings look (FEATURE-SPECS/SETTINGS.md §1): a fixed 684 × 650 pt
/// window, panes that scroll inside it, 556 pt boxes with 64 pt margins,
/// 8 pt apart, a light fill, a 1 pt border and an inset hairline between rows.
enum SettingsMetrics {
    static let windowSize = CGSize(width: 684, height: 650)
    /// Under the 88 pt title bar and toolbar.
    static let contentHeight: CGFloat = 562
    static let margin: CGFloat = 64
    static let boxWidth: CGFloat = 556
    static let boxSpacing: CGFloat = 8
    static let boxRadius: CGFloat = 6
    /// The label's and control's inset from the box's edges.
    static let rowInset: CGFloat = 10
    static let rowHeight: CGFloat = 36
    static let iconRowHeight: CGFloat = 41
}

enum SettingsColors {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    static let background = dynamic(light: NSColor(white: 0.992, alpha: 1), dark: .windowBackgroundColor)
    static let box = dynamic(light: NSColor(white: 0.976, alpha: 1), dark: NSColor(white: 1, alpha: 0.04))
    static let border = dynamic(light: NSColor(white: 0.894, alpha: 1), dark: NSColor(white: 1, alpha: 0.1))
    static let hairline = dynamic(light: NSColor(white: 0.906, alpha: 1), dark: NSColor(white: 1, alpha: 0.08))
    /// Arc's #979797 details and notes.
    static let tertiary = dynamic(light: NSColor(white: 0.59, alpha: 1), dark: NSColor(white: 0.55, alpha: 1))
    /// The light blue of a hovered link row and the selected profile.
    static let selection = Color.accentColor.opacity(0.11)
    /// Arc's flat grey push buttons and pop-ups.
    static let button = dynamic(light: NSColor(white: 0.922, alpha: 1), dark: NSColor(white: 1, alpha: 0.12))
    static let buttonPressed = dynamic(light: NSColor(white: 0.86, alpha: 1), dark: NSColor(white: 1, alpha: 0.2))
}

/// Arc's push buttons: flat grey rounded rectangles, 24 pt tall, no border.
struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 24)
            .background(configuration.isPressed ? SettingsColors.buttonPressed : SettingsColors.button,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.6))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Arc's pop-up: the choice and ⌃⌄ on the same flat grey, a menu of the
/// choices with a check on the current one.
struct SettingsPopUp<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var minWidth: CGFloat = 110

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.value == selection }?.title ?? "——").font(.system(size: 13))
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(minWidth: minWidth, minHeight: 24)
            .background(SettingsColors.button, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
    }
}

/// One pane: a scroll view as tall as the window's content, the boxes in a
/// column at Arc's margins. `fullBleed` content (Links' hero) spans the width.
struct SettingsPage<Content: View>: View {
    var topPadding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.boxSpacing) { content }
                .padding(.horizontal, SettingsMetrics.margin)
                .padding(.top, topPadding)
                .padding(.bottom, 24)
                .frame(width: SettingsMetrics.windowSize.width, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

/// A box of rows with Arc's inset hairline between them.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        _VariadicView.Tree(DividedRows()) { content }
            .frame(maxWidth: .infinity)
            .background(SettingsColors.box, in: RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous)
                .strokeBorder(SettingsColors.border, lineWidth: 1))
    }
}

private struct DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last { SettingsHairline().padding(.horizontal, SettingsMetrics.rowInset) }
            }
        }
    }
}

struct SettingsHairline: View {
    var body: some View {
        Rectangle().fill(SettingsColors.hairline).frame(height: 1)
    }
}

/// A box's small header above it ("Your Data and Settings").
struct SettingsHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(SettingsColors.tertiary)
            .padding(.leading, SettingsMetrics.rowInset)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Plain text between boxes (Links' and Profiles' introductions).
struct SettingsIntro: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.primary.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SettingsMetrics.rowInset)
    }
}

/// Advanced's 20 pt and the data rows' 24 pt coloured rounded squares.
struct SettingsIconTile: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// The label column: the label, then a note in Arc's tertiary grey.
private struct SettingsRowLabel: View {
    let label: String
    var detail: String?
    var italicDetail = false
    var info: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if let info { SettingsInfoButton(text: info, topic: label) }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .italic(italicDetail)
                    .foregroundStyle(SettingsColors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Label on the left, control on the right.
struct SettingsLabeledRow<Control: View>: View {
    let label: String
    var detail: String?
    var info: String?
    var icon: SettingsIconTile?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 10) {
            if let icon { icon }
            SettingsRowLabel(label: label, detail: detail, info: info)
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 6)
        .frame(minHeight: icon == nil ? SettingsMetrics.rowHeight : SettingsMetrics.iconRowHeight)
        .accessibilityElement(children: .contain)
    }
}

/// A switch row. The switch keeps the row's label for VoiceOver.
struct SettingsSwitchRow: View {
    let label: String
    var detail: String?
    var italicDetail = false
    var info: String?
    var icon: SettingsIconTile?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let icon { icon }
            SettingsRowLabel(label: label, detail: detail, italicDetail: italicDetail, info: info)
            Spacer(minLength: 12)
            Toggle(label, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityHint(detail ?? "")
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 6)
        .frame(minHeight: icon == nil ? SettingsMetrics.rowHeight : SettingsMetrics.iconRowHeight)
    }
}

/// Arc's ⓘ, as a popover with the explanation (Arc's open Help Center pages,
/// two of them dead, §1).
struct SettingsInfoButton: View {
    let text: String
    let topic: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("About \(topic)")
        .accessibilityLabel("About \(topic)")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}

/// Profiles' data rows: a 24 pt coloured icon, the title and a blue arrow;
/// the row fills light blue under the pointer.
struct SettingsLinkRow: View {
    let title: String
    let systemImage: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIconTile(systemImage: systemImage, color: color, size: 24)
                Text(title).font(.system(size: 13))
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 5)
            .frame(height: 32)
            .background(hovering ? SettingsColors.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 5)
        .accessibilityLabel(title)
    }
}

/// Arc's wavy bottom edge on the Links hero.
struct ScallopedBottom: Shape {
    var scallop: CGFloat = 12
    var depth: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
        var x = rect.maxX
        var up = true
        while x > 0 {
            let next = max(0, x - scallop / 2)
            path.addQuadCurve(to: CGPoint(x: next, y: rect.maxY - (up ? 0 : depth)),
                              control: CGPoint(x: (x + next) / 2, y: rect.maxY - (up ? -depth * 0.6 : depth * 1.6)))
            up.toggle()
            x = next
        }
        path.closeSubpath()
        return path
    }
}
