import AppKit
import SwiftUI
import SidebarModel

enum EaselRichTextFormatting {
    static func attributedString(from runs: [EaselRichTextRun]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            var attrs: [NSAttributedString.Key: Any] = [.font: font(for: run)]
            if run.isUnderline {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        return result
    }

    static func runs(from attributed: NSAttributedString) -> [EaselRichTextRun] {
        guard attributed.length > 0 else { return [EaselRichTextRun(text: "")] }
        var runs: [EaselRichTextRun] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            let text = attributed.attributedSubstring(from: range).string
            guard !text.isEmpty else { return }
            let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let heading = headingLevel(for: font)
            runs.append(EaselRichTextRun(
                text: text,
                isBold: font.fontDescriptor.symbolicTraits.contains(.bold),
                isItalic: font.fontDescriptor.symbolicTraits.contains(.italic),
                isUnderline: (attrs[.underlineStyle] as? Int ?? 0) != 0,
                headingLevel: heading
            ))
        }
        return runs.isEmpty ? [EaselRichTextRun(text: "")] : runs
    }

    static func font(for run: EaselRichTextRun) -> NSFont {
        if let level = run.headingLevel {
            let size: CGFloat = switch level {
            case 1: 28
            case 2: 22
            default: 18
            }
            return NSFont.systemFont(ofSize: size, weight: .bold)
        }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if run.isBold { traits.insert(.bold) }
        if run.isItalic { traits.insert(.italic) }
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        if traits.isEmpty { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    private static func headingLevel(for font: NSFont) -> Int? {
        if font.pointSize >= 26 { return 1 }
        if font.pointSize >= 20 { return 2 }
        if font.pointSize >= 17, font.fontDescriptor.symbolicTraits.contains(.bold) { return 3 }
        return nil
    }
}

struct EaselRichTextEditor: NSViewRepresentable {
    @Binding var runs: [EaselRichTextRun]
    var onEditingChanged: () -> Void
    var onCoordinatorReady: ((Coordinator) -> Void)?

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(runs: $runs, onEditingChanged: onEditingChanged)
        onCoordinatorReady?(coordinator)
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textStorage?.setAttributedString(EaselRichTextFormatting.attributedString(from: runs))
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.runs = $runs
        let current = EaselRichTextFormatting.runs(from: textView.attributedString())
        if current != runs {
            textView.textStorage?.setAttributedString(EaselRichTextFormatting.attributedString(from: runs))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var runs: Binding<[EaselRichTextRun]>
        let onEditingChanged: () -> Void
        weak var textView: NSTextView?

        init(runs: Binding<[EaselRichTextRun]>, onEditingChanged: @escaping () -> Void) {
            self.runs = runs
            self.onEditingChanged = onEditingChanged
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            runs.wrappedValue = EaselRichTextFormatting.runs(from: textView.attributedString())
            onEditingChanged()
        }

        func applyToggle(_ action: FormatAction) {
            guard let textView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            let mutable = NSMutableAttributedString(attributedString: textView.attributedString())
            let substring = mutable.attributedSubstring(from: range)
            var run = EaselRichTextFormatting.runs(from: substring).first ?? EaselRichTextRun(text: substring.string)
            switch action {
            case .bold: run.isBold.toggle()
            case .italic: run.isItalic.toggle()
            case .underline: run.isUnderline.toggle()
            case .heading: run.headingLevel = (run.headingLevel == nil) ? 2 : nil
            }
            mutable.replaceCharacters(in: range, with: EaselRichTextFormatting.attributedString(from: [run]))
            textView.textStorage?.setAttributedString(mutable)
            runs.wrappedValue = EaselRichTextFormatting.runs(from: mutable)
            onEditingChanged()
        }

        enum FormatAction {
            case bold, italic, underline, heading
        }
    }
}

struct EaselRichTextFormatBar: View {
    let onBold: () -> Void
    let onItalic: () -> Void
    let onUnderline: () -> Void
    let onHeading: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onBold) { Text("B").bold() }
            Button(action: onItalic) { Text("I").italic() }
            Button(action: onUnderline) { Text("U").underline() }
            Button(action: onHeading) { Text("H") }
        }
        .buttonStyle(.bordered)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
