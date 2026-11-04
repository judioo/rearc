import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SidebarModel

/// New Legacy Boost (Advanced) (Arc `newLegacyBoost`, BOOSTS §1): a CSS and
/// JavaScript boost edited as code. Its script runs only once "Allow this
/// boost's script to run" is on, the explicit step every script boost needs.
struct LegacyBoostEditorView: View {
    let model: BrowserViewModel
    let packageID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var css = ""
    @State private var js = ""
    @State private var error: String?

    var body: some View {
        let package = model.store.boostLibrary().package(id: packageID)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(package?.manifest.name ?? "Legacy Boost").font(.title3.weight(.semibold))
                Text(model.boostLibraryRows().first { $0.id == packageID }?.sites ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("CSS").font(.headline)
            codeEditor($css)
            Text("JavaScript").font(.headline)
            codeEditor($js)
            Toggle("Allow this boost’s script to run", isOn: Binding(
                get: { model.store.boostLibrary().package(id: packageID)?.scriptBoost?.userScriptEnabled ?? false },
                set: { model.setBoostScriptAllowed(packageID, allowed: $0) }
            ))
            .help("Scripts in boosts can read and change the pages they run on")
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Export…") { BoostFilePanels.export(packageID, model: model) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    error = model.saveLegacyBoost(packageID, css: css, js: js)
                    if error == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .onAppear {
            css = package?.scriptBoost?.css ?? ""
            js = package?.scriptBoost?.js ?? ""
        }
    }

    private func codeEditor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
    }
}

/// Export… and Import… for boost files (`.rearcboost`).
enum BoostFilePanels {
    static var boostType: UTType {
        UTType(filenameExtension: BoostInterchange.fileExtension, conformingTo: .json) ?? .json
    }

    static func export(_ packageID: UUID, model: BrowserViewModel) {
        guard let package = model.store.boostLibrary().package(id: packageID),
              let data = model.boostFileData(packageID) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BoostInterchange.suggestedFileName(for: package)
        panel.allowedContentTypes = [boostType]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                model.showToast("Exported “\(package.manifest.name)”", systemImage: "square.and.arrow.up")
            } catch {
                model.showToast("Could not save the boost", systemImage: "exclamationmark.triangle")
            }
        }
    }

    static func importBoosts(model: BrowserViewModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [boostType, .json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            let problems = model.importBoostFiles(panel.urls)
            if problems.isEmpty {
                model.showToast(panel.urls.count == 1 ? "Imported a boost" : "Imported \(panel.urls.count) boosts",
                                systemImage: "square.and.arrow.down")
            } else {
                let alert = NSAlert()
                alert.messageText = "Some boosts were not imported"
                alert.informativeText = problems.joined(separator: "\n")
                alert.runModal()
            }
        }
    }
}
