import AppKit
import SwiftUI
import SidebarModel

struct CaptureGalleryView: View {
    @Bindable var model: BrowserViewModel
    @State private var previewRecord: CaptureRecord?

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Captures")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { model.isCapturesGalleryPresented = false }
            }
            .padding(.horizontal)

            if model.store.captures.isEmpty {
                ContentUnavailableView("No captures yet", systemImage: "camera", description: Text("Use Capture Page or Capture Visible Area from the command bar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.store.captures) { record in
                            captureTile(record)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .sheet(item: $previewRecord) { record in
            CapturePreviewSheet(record: record, model: model)
        }
    }

    private func captureTile(_ record: CaptureRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image = model.captureThumbnail(record.id) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { previewRecord = record }

            Text(record.sourceTitle)
                .font(.caption)
                .lineLimit(1)
            Text(record.scope == .fullPage ? "Full page" : "Visible")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

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
