import AppKit
import SwiftUI

/// What a tab or folder row needs to show its title as a rename field.
struct SidebarRowRename {
    /// Arc's row is a touch rounder while it is being renamed (the user's
    /// note; at the recording's size the change is under a pixel).
    static let cornerRadius: CGFloat = 10

    let rename: SidebarInlineRename
    let onChange: (String) -> Void
    /// `byKey`: Return or Esc, after which the page takes focus back.
    let onEnd: (_ ending: SidebarInlineRename.Ending, _ byKey: Bool) -> Void

    /// The row's rename, if `id` is the row being renamed.
    init?(row id: UUID, model: BrowserViewModel) {
        guard let rename = model.inlineRename(forRow: id) else { return nil }
        self.rename = rename
        let target = rename.target
        onChange = { model.updateInlineRename($0, target: target) }
        onEnd = { ending, byKey in
            if model.endInlineRename(ending, target: target), byKey { model.restorePageFocus() }
        }
    }

    /// The field, placed so its text sits where the title's did (a
    /// borderless field draws its text 2 pt in).
    func field(weight: NSFont.Weight = .regular) -> some View {
        SidebarRenameField(rename: rename, weight: weight, onChange: onChange, onEnd: onEnd)
            .padding(.leading, -2)
    }
}

/// The row title as Arc edits it in place: the same 14 pt text where the
/// title sat, the whole name selected, the old name as the empty field's
/// placeholder. Return, Tab and a click anywhere else save; Esc cancels.
struct SidebarRenameField: NSViewRepresentable {
    let rename: SidebarInlineRename
    var weight: NSFont.Weight = .regular
    let onChange: (String) -> Void
    let onEnd: (SidebarInlineRename.Ending, _ byKey: Bool) -> Void

    @Environment(\.themeChrome) private var chrome

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SidebarRenameTextField {
        let field = SidebarRenameTextField(string: rename.text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        update(field)
        context.coordinator.watchClicks(outside: field)
        return field
    }

    func updateNSView(_ field: SidebarRenameTextField, context: Context) {
        context.coordinator.parent = self
        update(field)
    }

    static func dismantleNSView(_ field: SidebarRenameTextField, coordinator: Coordinator) {
        // The row went away mid-edit (scrolled off, the sidebar hid): that is
        // focus leaving, so the name typed so far is kept. After this update,
        // not during it.
        coordinator.stopWatching()
        DispatchQueue.main.async { coordinator.finish(.commit, byKey: false) }
    }

    private func update(_ field: SidebarRenameTextField) {
        field.font = .systemFont(ofSize: SidebarMetrics.titleSize, weight: weight)
        field.textColor = NSColor(chrome.title)
        field.placeholderAttributedString = NSAttributedString(string: rename.previousName, attributes: [
            .font: NSFont.systemFont(ofSize: SidebarMetrics.titleSize, weight: weight),
            .foregroundColor: NSColor(chrome.tertiaryText),
        ])
        field.selectionColor = NSColor(chrome.accent).withAlphaComponent(0.28)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SidebarRenameField
        private var ended = false
        private var monitor: Any?

        init(_ parent: SidebarRenameField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                end(.cancel, field: control)
            case #selector(NSResponder.insertNewline(_:)):
                end(.commit, field: control)
            default:
                return false
            }
            return true
        }

        /// Tab, or the field giving up focus some other way.
        func controlTextDidEndEditing(_ note: Notification) {
            finish(.commit, byKey: false)
        }

        private func end(_ ending: SidebarInlineRename.Ending, field: NSControl) {
            finish(ending, byKey: true)
            field.window?.makeFirstResponder(nil)
        }

        func finish(_ ending: SidebarInlineRename.Ending, byKey: Bool) {
            guard !ended else { return }
            ended = true
            stopWatching()
            parent.onEnd(ending, byKey)
        }

        /// A click on a sidebar row or button takes no keyboard focus, so it
        /// would leave the field editing; Arc ends the rename on any click
        /// away from it.
        func watchClicks(outside field: NSTextField) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
                guard let self, let field else { return event }
                let inside = event.window === field.window && field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                if !inside { self.finish(.commit, byKey: false) }
                return event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Takes focus once it is in a window, with the whole name selected. Its
/// own field editor draws the caret and selection, so the window's shared
/// one (the command bar's, the find bar's) keeps the system colours.
final class SidebarRenameTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { SidebarRenameFieldCell.self }
        set {}
    }

    var selectionColor: NSColor = .selectedTextBackgroundColor {
        didSet { (cell as? SidebarRenameFieldCell)?.editor.selectedTextAttributes = [.backgroundColor: selectionColor] }
    }
    private var tookFocus = false

    convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !tookFocus else { return }
        tookFocus = true
        // After the hosting row's layout pass, and after whatever the click
        // or menu that started the rename does with focus.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.makeFirstResponder(self) else { return }
            self.currentEditor()?.selectAll(nil)
        }
    }
}

final class SidebarRenameFieldCell: NSTextFieldCell {
    let editor: NSTextView = {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.insertionPointColor = .controlAccentColor
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}
