import AppKit
import SwiftUI
import SidebarModel

enum EaselEditorTool: Equatable {
    case select
    case text
    case arrow
    case rectangle
    case ellipse
}

struct EaselEditorView: View {
    let model: BrowserViewModel
    let sidebarItemID: UUID
    let documentID: UUID

    @State private var document: EaselDocument
    @State private var selectedBlockID: UUID?
    @State private var tool: EaselEditorTool = .select
    @State private var panOffset: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var spaceHeld = false
    @State private var arrowDraftStart: EaselPoint?
    @State private var dragStartFrames: [UUID: EaselFrame] = [:]

    init(model: BrowserViewModel, sidebarItemID: UUID, document: EaselDocument) {
        self.model = model
        self.sidebarItemID = sidebarItemID
        self.documentID = document.id
        _document = State(initialValue: document)
        _zoom = State(initialValue: CGFloat(document.viewport.zoom))
        _panOffset = State(initialValue: CGSize(
            width: document.viewport.offsetX,
            height: document.viewport.offsetY
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            easelToolbar
            Divider()
            canvas
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { syncFromStore() }
        .onChange(of: documentID) { _, _ in reloadDocumentSession() }
        .onChange(of: model.easelRevision) { _, _ in syncFromStore() }
        .focusable()
        .onKeyPress(.delete) {
            if let id = selectedBlockID {
                EaselDocumentOps.removeBlock(id: id, from: &document)
                selectedBlockID = nil
                persist()
            }
            return .handled
        }
        .background(EaselKeyboardMonitor(spaceHeld: $spaceHeld))
    }

    private var easelToolbar: some View {
        HStack(spacing: 12) {
            TextField("Title", text: Binding(
                get: { document.title },
                set: { document.title = $0; persist() }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 280)

            toolButton("pointer", tool: .select)
            toolButton("textformat", tool: .text)
            toolButton("arrow.up.right", tool: .arrow)
            toolButton("rectangle", tool: .rectangle)
            toolButton("circle", tool: .ellipse)

            Spacer()

            Text(String(format: "%.0f%%", zoom * 100))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toolButton(_ symbol: String, tool target: EaselEditorTool) -> some View {
        Button {
            tool = target
        } label: {
            Image(systemName: symbol)
                .frame(width: 28, height: 24)
                .background(tool == target ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                    .overlay(
                        Canvas { context, size in
                            drawGrid(context: &context, size: size)
                        }
                        .opacity(0.35)
                    )

                ZStack {
                    ForEach(document.blocks) { block in
                        blockView(block)
                            .position(
                                x: (block.frame.x + block.frame.width / 2 + panOffset.width) * zoom,
                                y: (block.frame.y + block.frame.height / 2 + panOffset.height) * zoom
                            )
                            .frame(
                                width: block.frame.width * zoom,
                                height: block.frame.height * zoom
                            )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(panGesture(in: geo.size))
                .simultaneousGesture(magnificationGesture)
                .onTapGesture(count: 2) { location in
                    guard tool == .select || tool == .text else { return }
                    addTextBlock(at: location, in: geo.size)
                }
                .gesture(arrowGesture(in: geo.size))
            }
        }
    }

    private func blockView(_ block: EaselBlock) -> some View {
        let isSelected = selectedBlockID == block.id
        return Group {
            switch block.payload {
            case .text(let runs):
                if isSelected {
                    EaselRichTextBlockEditor(
                        runs: richRunsBinding(for: block.id, fallback: runs),
                        onPersist: persist
                    )
                } else {
                    formattedTextView(runs: runs)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(6)
                }
            case .image(let captureID):
                EaselCaptureThumbnail(captureID: captureID, model: model)
            case .shape(let kind, let color, let arrowEnd):
                EaselShapeView(kind: kind, color: color, arrowEnd: arrowEnd)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard tool == .select, !spaceHeld else { return }
                    var updated = block
                    if dragStartFrames[block.id] == nil {
                        dragStartFrames[block.id] = block.frame
                        selectedBlockID = block.id
                    }
                    let start = dragStartFrames[block.id] ?? block.frame
                    updated.frame = EaselFrame(
                        x: start.x + value.translation.width / Double(zoom),
                        y: start.y + value.translation.height / Double(zoom),
                        width: start.width,
                        height: start.height
                    )
                    EaselDocumentOps.updateBlock(updated, in: &document)
                }
                .onEnded { _ in
                    dragStartFrames.removeValue(forKey: block.id)
                    persist()
                }
        )
        .onTapGesture {
            selectedBlockID = block.id
            if tool == .rectangle {
                insertShape(.rectangle, near: block.frame)
            } else if tool == .ellipse {
                insertShape(.ellipse, near: block.frame)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                resizeHandle(for: block)
            }
        }
    }

    private func resizeHandle(for block: EaselBlock) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 10, height: 10)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        var updated = block
                        updated.frame = EaselFrame(
                            x: block.frame.x,
                            y: block.frame.y,
                            width: block.frame.width + value.translation.width / Double(zoom),
                            height: block.frame.height + value.translation.height / Double(zoom)
                        )
                        EaselDocumentOps.updateBlock(updated, in: &document)
                    }
                    .onEnded { _ in persist() }
            )
    }

    private func addTextBlock(at location: CGPoint, in size: CGSize) {
        let canvasPoint = screenToCanvas(location, in: size)
        let block = EaselBlock(
            frame: EaselFrame(x: canvasPoint.x, y: canvasPoint.y, width: 240, height: 120),
            payload: .text(runs: [EaselRichTextRun(text: "Text")])
        )
        EaselDocumentOps.insertBlock(block, in: &document)
        selectedBlockID = block.id
        persist()
    }

    private func insertShape(_ kind: EaselShapeKind, near frame: EaselFrame) {
        let block = EaselBlock(
            frame: EaselFrame(x: frame.x + 40, y: frame.y + 40, width: 120, height: 80),
            payload: .shape(kind: kind, color: EaselColor.accent, arrowEnd: nil)
        )
        EaselDocumentOps.insertBlock(block, in: &document)
        selectedBlockID = block.id
        persist()
    }

    private func arrowGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard tool == .arrow else { return }
                let start = screenToCanvas(value.startLocation, in: size)
                if arrowDraftStart == nil {
                    arrowDraftStart = EaselPoint(x: start.x, y: start.y)
                }
                let end = screenToCanvas(value.location, in: size)
                guard let origin = arrowDraftStart else { return }
                let frame = arrowFrame(from: origin, to: end)
                if let id = selectedBlockID,
                   var existing = document.blocks.first(where: { $0.id == id }),
                   case .shape(_, _, _) = existing.payload {
                    existing.frame = frame
                    existing.payload = .shape(kind: .arrow, color: EaselColor.black, arrowEnd: end)
                    EaselDocumentOps.updateBlock(existing, in: &document)
                } else {
                    let block = EaselBlock(
                        frame: frame,
                        payload: .shape(kind: .arrow, color: EaselColor.black, arrowEnd: end)
                    )
                    EaselDocumentOps.insertBlock(block, in: &document)
                    selectedBlockID = block.id
                }
            }
            .onEnded { _ in
                arrowDraftStart = nil
                persist()
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard spaceHeld else { return }
                panOffset = CGSize(
                    width: document.viewport.offsetX + value.translation.width / zoom,
                    height: document.viewport.offsetY + value.translation.height / zoom
                )
            }
            .onEnded { _ in
                document.viewport.offsetX = Double(panOffset.width)
                document.viewport.offsetY = Double(panOffset.height)
                persist()
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(CGFloat(document.viewport.zoom) * value, 0.25), 3)
            }
            .onEnded { _ in
                document.viewport.zoom = Double(zoom)
                persist()
            }
    }

    private func screenToCanvas(_ point: CGPoint, in size: CGSize) -> EaselPoint {
        EaselPoint(
            x: Double(point.x / zoom - panOffset.width),
            y: Double(point.y / zoom - panOffset.height)
        )
    }

    private func arrowFrame(from start: EaselPoint, to end: EaselPoint) -> EaselFrame {
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let width = max(abs(end.x - start.x), 24)
        let height = max(abs(end.y - start.y), 24)
        return EaselFrame(x: minX, y: minY, width: width, height: height)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let step: CGFloat = 32 * zoom
        var path = Path()
        var x: CGFloat = 0
        while x < size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y: CGFloat = 0
        while y < size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        context.stroke(path, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)
    }

    private func persist() {
        document.viewport.offsetX = Double(panOffset.width)
        document.viewport.offsetY = Double(panOffset.height)
        document.viewport.zoom = Double(zoom)
        model.updateEaselDocument(document)
    }

    private func reloadDocumentSession() {
        selectedBlockID = nil
        dragStartFrames = [:]
        arrowDraftStart = nil
        syncFromStore()
    }

    private func richRunsBinding(for blockID: UUID, fallback: [EaselRichTextRun]) -> Binding<[EaselRichTextRun]> {
        Binding(
            get: {
                document.blocks.first(where: { $0.id == blockID })
                    .flatMap { block -> [EaselRichTextRun]? in
                        if case .text(let current) = block.payload { return current }
                        return nil
                    } ?? fallback
            },
            set: { newRuns in
                guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
                var block = document.blocks[index]
                block.payload = .text(runs: newRuns.isEmpty ? [EaselRichTextRun(text: "")] : newRuns)
                EaselDocumentOps.updateBlock(block, in: &document)
            }
        )
    }

    private func formattedTextView(runs: [EaselRichTextRun]) -> Text {
        runs.reduce(Text("")) { partial, run in
            var segment = Text(run.text)
            if run.isBold { segment = segment.bold() }
            if run.isItalic { segment = segment.italic() }
            if run.isUnderline { segment = segment.underline() }
            if let level = run.headingLevel {
                segment = segment.font(level == 1 ? .largeTitle : (level == 2 ? .title2 : .title3))
            }
            return partial + segment
        }
    }

    private func syncFromStore() {
        if let latest = model.easelDocumentStore.document(id: documentID) {
            document = latest
            zoom = CGFloat(latest.viewport.zoom)
            panOffset = CGSize(width: latest.viewport.offsetX, height: latest.viewport.offsetY)
        }
    }
}

private struct EaselShapeView: View {
    let kind: EaselShapeKind
    let color: EaselColor
    let arrowEnd: EaselPoint?

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let swiftColor = Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
                switch kind {
                case .rectangle:
                    context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(swiftColor.opacity(0.25)))
                    context.stroke(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(swiftColor), lineWidth: 2)
                case .ellipse:
                    context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(swiftColor.opacity(0.25)))
                    context.stroke(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(swiftColor), lineWidth: 2)
                case .arrow:
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height / 2))
                    let endX = arrowEnd.map { CGFloat($0.x) } ?? size.width
                    let endY = arrowEnd.map { CGFloat($0.y) } ?? size.height / 2
                    path.addLine(to: CGPoint(x: endX, y: endY))
                    context.stroke(path, with: .color(swiftColor), lineWidth: 2)
                }
            }
        }
    }
}

private struct EaselCaptureThumbnail: View {
    let captureID: UUID
    let model: BrowserViewModel

    var body: some View {
        Group {
            if let image = model.captureThumbnail(captureID) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.2)
                Image(systemName: "photo")
            }
        }
        .clipped()
    }
}

private struct EaselKeyboardMonitor: NSViewRepresentable {
    @Binding var spaceHeld: Bool

    func makeNSView(context: Context) -> NSView {
        let view = KeyCatcherView()
        view.onSpaceChanged = { held in
            spaceHeld = held
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class KeyCatcherView: NSView {
    var onSpaceChanged: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { onSpaceChanged?(true) }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { onSpaceChanged?(false) }
        super.keyUp(with: event)
    }
}
