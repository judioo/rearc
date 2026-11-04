import AppKit
import SidebarModel
import SwiftUI

/// Arc keeps extensions at the top of the sidebar: pinned actions beside
/// the navigation buttons and a puzzle button with every extension, its pin,
/// chrome://extensions and the Chrome Web Store. Hidden on WebKit.
struct ExtensionToolbarView: View {
    let model: BrowserViewModel
    let engine: (any WebEngine)?
    @Environment(\.displayScale) private var displayScale
    @State private var showsMenu = false
    @State private var menuAnchor: NSView?

    private var controller: ExtensionsController { model.extensions }
    private var engineKey: ObjectIdentifier? { engine.map { ObjectIdentifier($0) } }

    var body: some View {
        if controller.isAvailable {
            HStack(spacing: 1) {
                ForEach(controller.pinnedActions(for: engine)) { action in
                    ExtensionActionButton(controller: controller, engine: engine, action: action)
                }
                Button { showsMenu.toggle() } label: {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(AnchorReader { menuAnchor = $0 })
                .help("Extensions")
                .accessibilityLabel("Extensions")
                .popover(isPresented: $showsMenu, arrowEdge: .bottom) {
                    ExtensionsMenu(model: model, engine: engine) { id in
                        showsMenu = false
                        // The popup opens once this menu has closed.
                        DispatchQueue.main.async { controller.run(id, for: engine, anchor: menuAnchor) }
                    } dismiss: { showsMenu = false }
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

    var body: some View {
        Button { controller.run(action.id, for: engine, anchor: anchor) } label: {
            ExtensionIcon(action: action, size: 16)
                .frame(width: 24, height: 22)
                .background(controller.openPopupExtensionID == action.id ? Color.primary.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

private struct ExtensionsMenu: View {
    let model: BrowserViewModel
    let engine: (any WebEngine)?
    let run: (String) -> Void
    let dismiss: () -> Void

    var body: some View {
        let actions = model.extensions.actions(for: engine)
        VStack(alignment: .leading, spacing: 2) {
            Text("Extensions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            if actions.isEmpty {
                Text("No extensions")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            ForEach(actions) { action in
                HStack(spacing: 8) {
                    Button { run(action.id) } label: {
                        HStack(spacing: 8) {
                            ExtensionIcon(action: action, size: 16)
                            Text(action.name).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!action.isEnabled)
                    .help(action.tooltip)
                    let pinned = model.extensions.pins.isPinned(action.id)
                    Button { model.extensions.togglePin(action.id) } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .font(.system(size: 11))
                            .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(pinned ? "Unpin \(action.name)" : "Pin \(action.name)")
                    .accessibilityLabel(pinned ? "Unpin \(action.name)" : "Pin \(action.name)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            Divider().padding(.vertical, 4)
            menuRow("Manage Extensions", "gearshape") { model.openBrowserPage(.extensions) }
            menuRow("Chrome Web Store", "bag") { model.openChromeWebStore() }
        }
        .padding(.vertical, 10)
        .frame(width: 260)
    }

    private func menuRow(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
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
