import AppKit
import SwiftUI
import SidebarModel

/// A note as a document (Arc's rich text editor, EASEL-CAPTURE §3): a
/// title, then text with headings, lists, checklists, quotes, bold, italic,
/// underline, strikethrough, code and links. Markdown shortcuts at the start
/// of a line ("# ", "- ", "1. ", "[] ", "> ") format it. Saved as it is typed.
struct NoteEditorView: View {
    let model: BrowserViewModel
    let sidebarItemID: UUID
    @State private var document: EaselDocument
    @State private var title: String
    @State private var controller = NoteTextController()
    @State private var saveWork: DispatchWorkItem?
    @State private var linkRequest = false
    @State private var linkText = ""

    init(model: BrowserViewModel, sidebarItemID: UUID, document: EaselDocument) {
        self.model = model
        self.sidebarItemID = sidebarItemID
        _document = State(initialValue: document)
        _title = State(initialValue: document.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Untitled Note", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 30, weight: .bold))
                        .onSubmit { controller.focus() }
                        .onChange(of: title) { _, new in
                            model.renameEasel(documentID: document.id, title: new)
                        }
                    NoteTextEditor(controller: controller, content: document.noteContent) { content in
                        document.setNoteContent(content)
                        scheduleSave()
                    } onOpenLink: { url in
                        model.openInNewTab(url)
                    }
                    .frame(minHeight: 400)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onDisappear { flush() }
        .alert("Add Link", isPresented: $linkRequest) {
            TextField("https://", text: $linkText)
            Button("Cancel", role: .cancel) {}
            Button("Remove Link") { controller.setLink(nil) }
            Button("Add") { controller.setLink(NoteEditing.linkURL(from: linkText)) }
        } message: {
            Text("Links open in a new tab.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Body") { controller.setBlockStyle(.paragraph, toggle: false) }
                Button("Heading 1") { controller.setBlockStyle(.heading(1), toggle: false) }
                Button("Heading 2") { controller.setBlockStyle(.heading(2), toggle: false) }
                Button("Heading 3") { controller.setBlockStyle(.heading(3), toggle: false) }
            } label: {
                Label("Style", systemImage: "textformat.size")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Heading or body text")
            Divider().frame(height: 16).padding(.horizontal, 4)
            formatButton("bold", "Bold (⌘B)", key: "b") { controller.toggleInline(.noteBold) }
            formatButton("italic", "Italic (⌘I)", key: "i") { controller.toggleInline(.noteItalic) }
            formatButton("underline", "Underline (⌘U)", key: "u") { controller.toggleInline(.underlineStyle) }
            formatButton("strikethrough", "Strikethrough (⇧⌘X)", key: "x", modifiers: [.command, .shift]) { controller.toggleInline(.strikethroughStyle) }
            formatButton("chevron.left.forwardslash.chevron.right", "Code") { controller.toggleInline(.noteCode) }
            formatButton("link", "Link (⌘K)", key: "k") {
                linkText = controller.selectedLink?.absoluteString ?? ""
                linkRequest = true
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            formatButton("list.bullet", "Bulleted List (⇧⌘8)", key: "8", modifiers: [.command, .shift]) { controller.setBlockStyle(.bullet) }
            formatButton("list.number", "Numbered List (⇧⌘7)", key: "7", modifiers: [.command, .shift]) { controller.setBlockStyle(.numbered) }
            formatButton("checklist", "Checklist (⇧⌘L)", key: "l", modifiers: [.command, .shift]) { controller.setBlockStyle(.checklist(checked: false)) }
            formatButton("text.quote", "Quote") { controller.setBlockStyle(.quote) }
            Spacer()
            Menu {
                Button("Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document.noteContent.markdown(), forType: .string)
                    model.showToast("Copied note as Markdown", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func formatButton(_ symbol: String, _ help: String, key: Character? = nil,
                              modifiers: EventModifiers = .command, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
        .modifier(OptionalShortcut(key: key, modifiers: modifiers))
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = document
        let work = DispatchWorkItem { [model] in
            var latest = model.easelDocumentStore.document(id: snapshot.id) ?? snapshot
            latest.setNoteContent(snapshot.noteContent)
            model.easelDocumentStore.save(latest)
            model.easelMutationRevision &+= 1
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func flush() {
        guard let work = saveWork else { return }
        work.cancel()
        work.perform()
        saveWork = nil
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: Character?
    let modifiers: EventModifiers

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
        } else {
            content
        }
    }
}

/// Lets the toolbar act on the text view.
@MainActor
final class NoteTextController {
    weak var coordinator: NoteTextEditor.Coordinator?

    func focus() { coordinator?.focus() }
    func toggleInline(_ key: NSAttributedString.Key) { coordinator?.toggleInline(key) }
    func setBlockStyle(_ style: NoteBlockStyle, toggle: Bool = true) { coordinator?.setBlockStyle(style, toggle: toggle) }
    func setLink(_ url: URL?) { coordinator?.setLink(url) }
    var selectedLink: URL? { coordinator?.selectedLink }
}

struct NoteTextEditor: NSViewRepresentable {
    let controller: NoteTextController
    let content: NoteContent
    var onChange: (NoteContent) -> Void
    var onOpenLink: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onOpenLink: onOpenLink)
    }

    func makeNSView(context: Context) -> NoteTextView {
        let view = NoteTextView(frame: .zero)
        view.isRichText = true
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        context.coordinator.textView = view
        context.coordinator.load(content)
        controller.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: NoteTextView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onOpenLink = onOpenLink
        controller.coordinator = context.coordinator
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NoteTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(layout.usedRect(for: container).height + 24, 400))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (NoteContent) -> Void
        var onOpenLink: (URL) -> Void
        weak var textView: NoteTextView?
        private(set) var content = NoteContent()
        private var rendering = false

        init(onChange: @escaping (NoteContent) -> Void, onOpenLink: @escaping (URL) -> Void) {
            self.onChange = onChange
            self.onOpenLink = onOpenLink
        }

        func focus() {
            textView?.window?.makeFirstResponder(textView)
        }

        func load(_ content: NoteContent) {
            self.content = content
            render(selection: nil)
        }

        /// Redraws from `content`, keeping the caret at the same text position.
        private func render(selection: (block: Int, offset: Int)?, length: Int = 0) {
            guard let view = textView, let storage = view.textStorage else { return }
            rendering = true
            storage.setAttributedString(NoteTextFormatting.attributedString(content))
            // The text was replaced under the typing undo stack; its ranges no longer hold.
            view.undoManager?.removeAllActions(withTarget: view)
            view.undoManager?.removeAllActions(withTarget: storage)
            if let selection {
                let start = NoteTextFormatting.location(of: selection, in: content)
                view.setSelectedRange(NSRange(location: start, length: min(length, storage.length - start)))
            }
            updateTypingAttributes()
            rendering = false
        }

        /// The last line's style while it is empty (it has no text to hold it).
        private var emptyLastStyle: NoteBlockStyle? {
            content.blocks.last.flatMap { $0.text.isEmpty ? $0.style : nil }
        }

        private var caret: (block: Int, offset: Int) {
            NoteTextFormatting.blockPosition(of: textView?.selectedRange().location ?? 0, in: content)
        }

        private func commit(_ updated: NoteContent, caret: (block: Int, offset: Int), length: Int = 0) {
            content = updated
            render(selection: caret, length: length)
            onChange(content)
        }

        // MARK: Typing

        func textDidChange(_ notification: Notification) {
            guard !rendering, let view = textView, let storage = view.textStorage else { return }
            let parsed = NoteTextFormatting.content(storage, emptyLastStyle: emptyLastStyle)
            let position = NoteTextFormatting.blockPosition(of: view.selectedRange().location, in: parsed)
            var updated = parsed
            var caret = position
            // Markdown shortcut: "# ", "- ", "1. ", "[] " or "> " opening a body line.
            if updated.blocks.indices.contains(position.block), updated.blocks[position.block].style == .paragraph {
                let text = updated.blocks[position.block].text
                if let space = text.firstIndex(of: " "), text.distance(from: text.startIndex, to: space) + 1 == position.offset,
                   let style = NoteEditing.shortcutStyle(forPrefix: String(text[..<space])) {
                    let prefixLength = position.offset
                    updated.blocks[position.block] = NoteBlock(style, runs: Self.dropping(prefixLength, from: updated.blocks[position.block].runs))
                    caret = (position.block, 0)
                }
            }
            // Re-render when markers or styles moved (numbering, a new list line).
            if updated != parsed || updated.markers() != parsed.markers()
                || NoteTextFormatting.attributedString(updated).string != storage.string {
                commit(updated, caret: caret)
            } else {
                content = updated
                onChange(content)
            }
        }

        static func dropping(_ count: Int, from runs: [NoteRun]) -> [NoteRun] {
            var remaining = count
            var out: [NoteRun] = []
            for var run in runs {
                let length = (run.text as NSString).length
                if remaining >= length { remaining -= length; continue }
                if remaining > 0 { run.text = (run.text as NSString).substring(from: remaining); remaining = 0 }
                out.append(run)
            }
            return out
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let position = caret
            guard content.blocks.indices.contains(position.block) else { return false }
            let block = content.blocks[position.block]
            if selector == #selector(NSResponder.insertNewline(_:)), textView.selectedRange().length == 0 {
                let decision = NoteEditing.styleAfterReturn(in: block.style, blockIsEmpty: block.text.isEmpty)
                var updated = content
                if block.text.isEmpty, decision.current != block.style {
                    updated.blocks[position.block].style = decision.current
                    commit(updated, caret: position)
                    return true
                }
                let head = Self.prefix(position.offset, of: block.runs)
                let tail = Self.dropping(position.offset, from: block.runs)
                updated.blocks[position.block] = NoteBlock(block.style, runs: head)
                updated.blocks.insert(NoteBlock(decision.next, runs: tail), at: position.block + 1)
                commit(updated, caret: (position.block + 1, 0))
                return true
            }
            if selector == #selector(NSResponder.deleteBackward(_:)), textView.selectedRange().length == 0, position.offset == 0,
               let cleared = NoteEditing.styleAfterDeleteAtStart(block.style) {
                var updated = content
                updated.blocks[position.block].style = cleared
                commit(updated, caret: position)
                return true
            }
            return false
        }

        static func prefix(_ count: Int, of runs: [NoteRun]) -> [NoteRun] {
            var remaining = count
            var out: [NoteRun] = []
            for var run in runs where remaining > 0 {
                let length = (run.text as NSString).length
                if length > remaining { run.text = (run.text as NSString).substring(to: remaining) }
                remaining -= min(length, remaining)
                out.append(run)
            }
            return out
        }

        /// The caret never sits inside a marker, and typed text never takes a marker's attributes.
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            guard !rendering, new.length == 0, let storage = textView.textStorage, new.location < storage.length,
                  storage.attribute(.noteMarker, at: new.location, effectiveRange: nil) != nil else { return new }
            var range = NSRange()
            _ = storage.attribute(.noteMarker, at: new.location, effectiveRange: &range)
            return NSRange(location: NSMaxRange(range), length: 0)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !rendering else { return }
            updateTypingAttributes()
        }

        func textView(_ textView: NSTextView, shouldChangeTypingAttributes old: [String: Any],
                      toAttributes new: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var attributes = new
            attributes[.noteMarker] = nil
            attributes[.cursor] = nil
            return attributes
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return true }
            onOpenLink(url)
            return true
        }

        /// A click on a checklist marker checks or unchecks it.
        func clicked(atCharacter index: Int) -> Bool {
            guard let storage = textView?.textStorage, index < storage.length,
                  storage.attribute(.noteMarker, at: index, effectiveRange: nil) != nil else { return false }
            let block = NoteTextFormatting.blockPosition(of: index, in: content).block
            guard case .checklist = content.blocks[block].style else { return false }
            var updated = content
            updated.toggleChecklist(at: block)
            commit(updated, caret: caret)
            return true
        }

        private func updateTypingAttributes() {
            guard let view = textView, content.blocks.indices.contains(caret.block) else { return }
            let style = content.blocks[caret.block].style
            var attributes = view.typingAttributes
            attributes[.noteMarker] = nil
            attributes[.cursor] = nil
            attributes[.noteBlockStyle] = NoteTextFormatting.styleKey(style)
            attributes[.paragraphStyle] = NoteTextFormatting.paragraphStyle(for: style)
            attributes[.font] = NoteTextFormatting.font(for: style, bold: attributes[.noteBold] != nil,
                                                        italic: attributes[.noteItalic] != nil, code: attributes[.noteCode] != nil)
            attributes[.foregroundColor] = style == .quote ? NSColor.secondaryLabelColor : NSColor.labelColor
            view.typingAttributes = attributes
        }

        // MARK: Toolbar

        func toggleInline(_ key: NSAttributedString.Key) {
            guard let view = textView, let storage = view.textStorage else { return }
            let range = view.selectedRange()
            let on: Any = key == .underlineStyle || key == .strikethroughStyle ? NSUnderlineStyle.single.rawValue : true
            if range.length == 0 {
                var attributes = view.typingAttributes
                attributes[key] = attributes[key] == nil ? on : nil
                view.typingAttributes = attributes
                updateTypingAttributes()
                return
            }
            var allSet = true
            storage.enumerateAttribute(key, in: range) { value, _, _ in
                if value == nil || (value as? Int) == 0 { allSet = false }
            }
            storage.beginEditing()
            if allSet { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: on, range: range) }
            storage.endEditing()
            let start = NoteTextFormatting.blockPosition(of: range.location, in: content)
            let updated = NoteTextFormatting.content(storage, emptyLastStyle: emptyLastStyle)
            commit(updated, caret: start, length: range.length)
        }

        func setBlockStyle(_ style: NoteBlockStyle, toggle: Bool) {
            guard let view = textView else { return }
            let range = view.selectedRange()
            let first = NoteTextFormatting.blockPosition(of: range.location, in: content)
            let last = NoteTextFormatting.blockPosition(of: NSMaxRange(range), in: content)
            var updated = content
            let indices = Array(first.block ... max(first.block, last.block))
            if toggle {
                updated.setStyle(style, blocks: indices)
            } else {
                for index in indices where updated.blocks.indices.contains(index) { updated.blocks[index].style = style }
            }
            commit(updated, caret: first)
        }

        var selectedLink: URL? {
            guard let view = textView, let storage = view.textStorage, view.selectedRange().location < storage.length else { return nil }
            return storage.attribute(.link, at: view.selectedRange().location, effectiveRange: nil) as? URL
        }

        func setLink(_ url: URL?) {
            guard let view = textView, let storage = view.textStorage else { return }
            var range = view.selectedRange()
            if range.length == 0, range.location < storage.length {
                // No selection: the link under the caret.
                var effective = NSRange()
                guard storage.attribute(.link, at: range.location, effectiveRange: &effective) != nil else { return }
                range = effective
            }
            guard range.length > 0 else { return }
            storage.beginEditing()
            if let url { storage.addAttribute(.link, value: url, range: range) } else { storage.removeAttribute(.link, range: range) }
            storage.endEditing()
            commit(NoteTextFormatting.content(storage, emptyLastStyle: emptyLastStyle), caret: NoteTextFormatting.blockPosition(of: range.location, in: content), length: range.length)
        }
    }
}

final class NoteTextView: NSTextView {
    weak var coordinator: NoteTextEditor.Coordinator?

    /// Pasted text takes the note's styles, not the source's fonts and colours.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let layout = layoutManager, let container = textContainer {
            var fraction: CGFloat = 0
            let glyph = layout.glyphIndex(for: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y),
                                          in: container, fractionOfDistanceThroughGlyph: &fraction)
            let index = layout.characterIndexForGlyph(at: glyph)
            if coordinator?.clicked(atCharacter: index) == true { return }
        }
        super.mouseDown(with: event)
    }
}
