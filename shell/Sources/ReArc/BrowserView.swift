import AppKit
import SwiftUI
import SidebarModel

/// Root window layout: sidebar on the left, web content filling the rest,
/// command bar floating centered on top. The active space's theme color is
/// applied as a subtle window tint.
struct BrowserView: View {
    @Bindable var model: BrowserViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if model.isSidebarVisible {
                    SidebarView(model: model)
                        .transition(.move(edge: .leading))
                }
                contentArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Subtle space-theme window tint.
            .background(model.themeColor.opacity(0.10))

            if let session = model.peekSession, let web = model.peekEngineView() {
                PeekOverlayView(
                    title: session.title,
                    url: session.url,
                    webContent: web,
                    onOpenInTab: { model.peekOpenInFullTab() },
                    onOpenInLittleArc: { model.peekOpenInLittleArc() },
                    onCopyLink: { model.peekCopyLink() },
                    onDismiss: { model.dismissPeek() }
                )
            }

            boostEditorChrome

            if model.sidebarRecoveredFromCorruption {
                VStack {
                    Text("Recovered from a corrupted file — your previous state was preserved separately")
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            }

            if model.isCommandBarPresented {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissCommandBar() }
                CommandBarOverlay(
                    text: $model.commandBarText,
                    results: model.commandBarResults,
                    highlightedIndex: model.commandBarHighlightedIndex,
                    errorMessage: model.commandBarError,
                    onMoveHighlight: { model.moveCommandBarHighlight(by: $0) },
                    onSelectIndex: { index in
                        model.commandBarHighlightedIndex = index
                        model.submitCommandBar()
                    },
                    onSubmit: { model.submitCommandBar() },
                    onCancel: { model.dismissCommandBar() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .tint(model.themeColor)
        .animation(.easeInOut(duration: 0.15), value: model.isCommandBarPresented)
        .frame(minWidth: 760, minHeight: 520)
        .background(
            WindowOcclusionReader { model.handleWindowOcclusion($0) }
                .frame(width: 0, height: 0)
        )
        .navigationTitle(contentTitle)
        .sheet(isPresented: $model.isCapturesGalleryPresented) {
            CaptureGalleryView(model: model)
        }
        .sheet(isPresented: $model.isCapturePreviewPresented) {
            if let record = model.lastCapturePreview {
                CapturePreviewSheet(record: record, model: model)
            }
        }
        .alert("Capture failed", isPresented: Binding(
            get: { model.captureErrorMessage != nil },
            set: { if !$0 { model.captureErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.captureErrorMessage ?? "")
        }
        .onAppear {
            stripCloseWindowShortcut()
            model.restoreLittleArcWindowsIfNeeded()
        }
        .onChange(of: model.littleArcOpenRequests) { _, requests in
            for id in requests {
                openWindow(id: "littleArc", value: id)
            }
            if !requests.isEmpty {
                model.clearLittleArcOpenRequests()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.prepareForQuit()
        }
        .alert("Rename Profile", isPresented: Binding(
            get: { model.pendingProfileRenameID != nil },
            set: { if !$0 { model.pendingProfileRenameID = nil } }
        )) {
            TextField("Name", text: $model.pendingProfileRenameName)
            Button("Cancel", role: .cancel) { model.pendingProfileRenameID = nil }
            Button("Save") {
                if let id = model.pendingProfileRenameID {
                    _ = model.store.renameProfile(id, to: model.pendingProfileRenameName)
                }
                model.pendingProfileRenameID = nil
            }
        }
    }

    private var contentTitle: String {
        if let ref = model.store.selectedEaselRef {
            return model.easelTitle(for: ref)
        }
        return model.store.selectedTab?.title ?? "ReArc"
    }

    /// Removes ⌘W from File > Close Window so the Tabs menu's Close Tab
    /// command is the only ⌘W in the app. The window can still be closed
    /// with the red traffic-light button.
    private func stripCloseWindowShortcut() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for topItem in mainMenu.items {
            guard let submenu = topItem.submenu else { continue }
            for item in submenu.items
            where item.keyEquivalent == "w"
                && item.keyEquivalentModifierMask == .command
                && item.action == NSSelectorFromString("performClose:") {
                item.keyEquivalent = ""
            }
        }
    }

    @ViewBuilder
    private var boostEditorChrome: some View {
        if let draft = model.boostEditorDraft {
            VStack {
                if draft.pickerActive {
                    Text("Pick an element — Esc to cancel")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(draft.pickerActive)

            BoostEditorDrawerView(model: model, draft: draft)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if let ref = model.store.selectedEaselRef,
           let document = model.easelDocument(forSidebarItem: ref.id) {
            EaselEditorView(model: model, sidebarItemID: ref.id, document: document)
                .id(document.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let split = model.activeSplit {
            SplitContentView(split: split, model: model, accent: model.themeColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let tab = model.store.selectedTab {
            model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
                .makeView()
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(theme: model.themeColor)
        }
    }
}

private struct EmptyStateView: View {
    let theme: Color

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 44))
                .foregroundStyle(theme.opacity(0.7))
            Text("No tabs open")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Press ⌘T to open one")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
