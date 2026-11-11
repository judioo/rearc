import AppKit
import SidebarModel
import SwiftUI

/// Arc keeps pinned extensions at the top of the sidebar, beside the
/// navigation buttons. Every extension, its pin and the Chrome Web Store are
/// in the site controls panel's grid, so there is no puzzle button (as in
/// Arc). Hidden on WebKit.
struct ExtensionToolbarView: View {
    let model: BrowserViewModel
    let engine: (any WebEngine)?
    @Environment(\.displayScale) private var displayScale

    private var controller: ExtensionsController { model.extensions }
    private var engineKey: ObjectIdentifier? { engine.map { ObjectIdentifier($0) } }

    var body: some View {
        if controller.isAvailable {
            HStack(spacing: 1) {
                ForEach(controller.pinnedActions(for: engine)) { action in
                    ExtensionActionButton(controller: controller, engine: engine, action: action)
                }
            }
            .task(id: engineKey) { controller.refresh(engine, scale: displayScale) }
        }
    }
}

private struct ExtensionActionButton: View {
    let controller: ExtensionsController
    let engine: (any WebEngine)?
    let action: ExtensionActionItem
    @State private var anchor: NSView?
    @Environment(\.sidebarWindow) private var window

    var body: some View {
        Button { controller.run(action.id, for: engine, anchor: anchor) } label: {
            ExtensionIcon(action: action, size: 16)
                .frame(width: 24, height: 22)
                .background(controller.isActionHighlighted(action.id, in: window) ? Color.primary.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .addressBarControlFocus()
        .transformPreference(AddressBarFocusPreference.self) {
            $0 = $0 || controller.openPopupExtensionID == action.id
        }
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.45)
        .background(AnchorReader { anchor = $0 })
        .help(action.tooltip)
        .accessibilityLabel(action.name)
        .contextMenu {
            Text(action.name)
            Button("Unpin") { controller.togglePin(action.id) }
        }
    }
}

/// The action icon with Chrome's badge and the "wants to run" dot.
struct ExtensionIcon: View {
    let action: ExtensionActionItem
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let data = action.iconPNG, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Image(systemName: "puzzlepiece.fill").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            if let badge = action.displayBadge {
                Text(badge)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(action.badgeTextColor.map(Self.color) ?? .white)
                    .padding(.horizontal, 2)
                    .frame(minWidth: 10, minHeight: 9)
                    .background(action.badgeBackgroundColor.map(Self.color) ?? Color(white: 0.38),
                                in: RoundedRectangle(cornerRadius: 2.5))
                    .offset(x: 5, y: 3)
            } else if action.wantsToRun {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 2, y: 2)
            }
        }
    }

    static func color(_ c: ExtensionBadgeColor) -> Color {
        Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}

/// Arc's toolbar popover (ARC-RECORDING-ANALYSIS.md §9, frame 3380): a row
/// of square Share / Boost / Capture buttons, then the site controls'
/// Extensions grid (pinned first, with the pin badge; right-click pins).
private struct ExtensionsMenu: View {
    let model: BrowserViewModel
    let engine: (any WebEngine)?
    let run: (String) -> Void
    let dismiss: () -> Void
    @Environment(\.sidebarWindow) private var window

    var body: some View {
        let url = engine?.currentURL
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let url {
                    ShareLink(item: url) { squareLabel("Share", "square.and.arrow.up") }
                        .buttonStyle(.plain)
                } else {
                    squareLabel("Share", "square.and.arrow.up").opacity(0.4)
                }
                squareButton("Boost", "paintbrush.pointed.fill") { model.newBoost() }
                squareButton("Capture", "camera.fill") { _ = model.beginPageCapture(in: window) }
            }
            Text("Extensions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            SiteControlsExtensionGrid(model: model, engine: engine, manage: {
                dismiss()
                model.openBrowserPage(.extensions)
            }, run: run) {
                dismiss()
                model.openChromeWebStore()
            }
        }
        .padding(12)
        .frame(width: SiteControlCenterView.width + 24)
    }

    private func squareLabel(_ title: String, _ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .frame(width: 48, height: 40)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .help(title)
            .accessibilityLabel(title)
    }

    private func squareButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: { squareLabel(title, symbol) }
        .buttonStyle(.plain)
    }
}

/// Hands back the NSView under a SwiftUI control (anchors for popups).
struct AnchorReader: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
