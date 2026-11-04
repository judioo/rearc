import AppKit
import SidebarModel
import SwiftUI

/// Shows a page's autofill suggestions (replaceable for tests).
protocol AutofillPanelPresenting: AnyObject {
    func show(_ popup: AutofillPopup, for prompts: PagePromptCenter)
    func hide(for prompts: PagePromptCenter)
}

/// The suggestion list as a borderless child panel under the field, like
/// Chrome's popup: it may extend past the page, and it never becomes key,
/// because Chromium hides the suggestions as soon as the page's view loses
/// focus. The field keeps the keyboard; Chromium routes its arrow keys,
/// Return, Tab and Escape and reports the selection.
final class AutofillPanelPresenter: AutofillPanelPresenting {
    private var panel: AutofillSuggestionPanel?
    private weak var parent: NSWindow?

    func show(_ popup: AutofillPopup, for prompts: PagePromptCenter) {
        guard popup.hasRows, let anchor = prompts.anchorView, let window = anchor.window,
              let screen = window.screen ?? NSScreen.main else { return hide(for: prompts) }
        let size = AutofillPopupLayout.size(for: popup)
        let viewOnScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let frame = AutofillPopupLayout.frame(field: popup.field, viewOnScreen: viewOnScreen, size: size, screen: screen.visibleFrame)
        let panel = self.panel ?? AutofillSuggestionPanel(prompts: prompts)
        self.panel = panel
        panel.setFrame(frame, display: true)
        if parent !== window {
            parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        panel.orderFront(nil)
    }

    func hide(for prompts: PagePromptCenter) {
        guard let panel else { return }
        parent?.removeChildWindow(panel)
        parent = nil
        panel.orderOut(nil)
    }

    /// The panel on screen, if any (self-test).
    var visiblePanel: NSWindow? { panel?.isVisible == true ? panel : nil }
}

final class AutofillSuggestionPanel: NSPanel {
    init(prompts: PagePromptCenter) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 48), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = true
        animationBehavior = .utilityWindow
        contentView = FirstMouseHostingView(rootView: AutofillSuggestionList(prompts: prompts))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click without activating anything, so a click accepts the row at once.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

struct AutofillSuggestionList: View {
    let prompts: PagePromptCenter

    var body: some View {
        Group {
            if let popup = prompts.autofill {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(popup.rows) { row in
                            if row.kind == .separator {
                                Divider().padding(.vertical, 4)
                            } else {
                                rowView(row, in: popup)
                            }
                        }
                    }
                    .padding(AutofillPopupLayout.padding)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Autofill suggestions")
    }

    private func rowView(_ row: AutofillSuggestionRow, in popup: AutofillPopup) -> some View {
        let highlighted = popup.selected == row.id || prompts.autofillHover == row.id
        let secondary = popup.secondaryText(of: row)
        return HStack(spacing: 9) {
            Image(systemName: row.symbolName ?? "text.cursor")
                .font(.system(size: 13))
                .foregroundStyle(highlighted ? Color.white : Color.secondary)
                .frame(width: 18)
                .opacity(row.symbolName == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(popup.primaryText(of: row))
                    .font(.system(size: 13, weight: row.kind == .manage ? .regular : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: AutofillPopupLayout.rowHeight)
        .background(highlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .opacity(row.isAcceptable ? 1 : 0.5)
        .onHover { inside in prompts.previewAutofillRow(inside ? row.id : nil) }
        .onTapGesture { prompts.acceptAutofillRow(row.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
