import AppKit
import SwiftUI
import SidebarModel

/// A capture at full size with Copy, Add to Easel and Delete (the Library's
/// Media page and the preview after a capture).
struct CapturePreviewSheet: View {
    let record: CaptureRecord
    let model: BrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var easelTargets: [SidebarEaselRef] = []

    var body: some View {
        VStack(spacing: 16) {
            if let image = model.captureThumbnail(record.id) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 420)
            }
            Text(record.sourceTitle)
                .font(.headline)

            HStack {
                Button("Copy") { model.copyCaptureToClipboard(record) }
                Menu("Add to easel…") {
                    ForEach(easelTargets, id: \.id) { ref in
                        Button(model.easelTitle(for: ref)) {
                            model.insertCapture(record, intoEasel: ref.easelDocumentID)
                        }
                    }
                    if easelTargets.isEmpty {
                        Button("New Easel…") {
                            model.insertCaptureIntoNewEasel(record)
                            dismiss()
                        }
                    }
                }
                Button("Delete", role: .destructive) {
                    model.deleteCapture(record)
                    dismiss()
                }
            }
        }
        .padding()
        .frame(minWidth: 480)
        .onAppear {
            easelTargets = model.store.allEaselRefs()
        }
    }
}
