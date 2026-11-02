import AppKit
import SwiftUI
import SidebarModel

struct EaselRichTextBlockEditor: View {
    @Binding var runs: [EaselRichTextRun]
    let onPersist: () -> Void

    @State private var coordinator: EaselRichTextEditor.Coordinator?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            EaselRichTextEditor(runs: $runs, onEditingChanged: onPersist) { ready in
                coordinator = ready
            }
            EaselRichTextFormatBar(
                onBold: { coordinator?.applyToggle(.bold) },
                onItalic: { coordinator?.applyToggle(.italic) },
                onUnderline: { coordinator?.applyToggle(.underline) },
                onHeading: { coordinator?.applyToggle(.heading) }
            )
            .padding(4)
        }
        .background(EaselFormatKeyMonitor(coordinator: coordinator))
    }
}

private struct EaselFormatKeyMonitor: NSViewRepresentable {
    let coordinator: EaselRichTextEditor.Coordinator?

    func makeNSView(context: Context) -> NSView {
        KeyMonitorView(coordinator: coordinator)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyMonitorView)?.coordinator = coordinator
    }

    private final class KeyMonitorView: NSView {
        var coordinator: EaselRichTextEditor.Coordinator?
        private var monitor: Any?

        init(coordinator: EaselRichTextEditor.Coordinator?) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.contains(.command) else { return event }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "b":
                    self?.coordinator?.applyToggle(.bold)
                    return nil
                case "i":
                    self?.coordinator?.applyToggle(.italic)
                    return nil
                case "u":
                    self?.coordinator?.applyToggle(.underline)
                    return nil
                default:
                    return event
                }
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
