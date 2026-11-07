import SwiftUI
import SidebarModel

/// Minimal standalone window (PEEK-LITTLE-BROWSER §2): a compact toolbar
/// with back, forward and reload, the address placeholder that opens its
/// mini command bar, the profile indicator and Open in <Space> (⌘O) with a menu of other spaces; then the page.
struct LittleArcWindowView: View {
    @Bindable var model: BrowserViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    let windowID: LittleArcWindow.ID

    @State private var isEditingAddress = false
    @State private var addressText = ""
    @FocusState private var addressFocused: Bool

    private var record: LittleArcWindow? {
        model.store.littleArcWindow(withID: windowID)
    }

    var body: some View {
        Group {
            if let record {
                let engine = model.littleArcEngine(for: windowID)
                VStack(spacing: 0) {
                    toolbar(for: record, engine: engine)
                    Divider()
                    engine.makeView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .pageStatus(engine.activity) { engine.reload() }
                        .findBar(model.findBar, for: engine)
                }
            } else {
                Text("Little Arc window unavailable")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .overlay(alignment: .topLeading) { LittleArcProbeMarker(windowID: windowID) }
        .background(
            WindowKeyObserver(
                onBecameKey: { model.keyLittleArcID = windowID },
                onClose: { if model.keyLittleArcID == windowID { model.keyLittleArcID = nil } }
            )
            .frame(width: 0, height: 0)
        )
        .onAppear {
            model.focusedLittleArcID = windowID
            model.touchLittleArcIfNeeded(windowID)
            model.loadLittleArcIfNeeded(windowID)
            consumeFocusRequest()
        }
        .onChange(of: model.littleArcFocusRequest) { _, _ in consumeFocusRequest() }
        // Archived elsewhere (Settings › Links › Archive Little Arcs after): the window goes too.
        .onChange(of: record == nil) { _, gone in if gone { dismiss() } }
        .onDisappear {
            if model.focusedLittleArcID == windowID {
                model.focusedLittleArcID = nil
            }
            if model.store.littleArcWindow(withID: windowID) != nil {
                model.closeLittleArcWindow(windowID)
            }
        }
    }

    private func dismiss() {
        if let presenter = model.windowPresenter {
            presenter.dismissLittleArcWindow(windowID)
        } else {
            dismissWindow(id: "littleArc", value: windowID)
        }
    }

    /// ⌘L or a new blank Little Arc: the address field starts editing.
    private func consumeFocusRequest() {
        guard model.littleArcFocusRequest == windowID else { return }
        model.littleArcFocusRequest = nil
        beginEditing()
    }

    private func beginEditing() {
        addressText = LittleArcChrome.editingText(for: model.littleArcEngine(for: windowID).currentURL ?? record?.url)
        isEditingAddress = true
        DispatchQueue.main.async { addressFocused = true }
    }

    private func toolbar(for record: LittleArcWindow, engine: any WebEngine) -> some View {
        HStack(spacing: 6) {
            navButton("chevron.left", "Back (⌘[)", enabled: engine.canGoBack) { engine.goBack() }
            navButton("chevron.right", "Forward (⌘])", enabled: engine.canGoForward) { engine.goForward() }
            navButton(engine.isLoading ? "xmark" : "arrow.clockwise", engine.isLoading ? "Stop" : "Reload (⌘R)", enabled: true) {
                engine.isLoading ? engine.stopLoading() : engine.reload()
            }
            address(for: record, engine: engine)
            navButton("link", "Copy Link", enabled: true) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString((engine.currentURL ?? record.url).absoluteString, forType: .string)
            }
            profileMenu(for: record)
            openInButton(for: record)
            Button {
                model.closeLittleArcWindow(windowID)
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            // Tinted with the space Open in targets, as Arc tints it.
            let theme = model.store.littleArcTargetSpace(for: windowID)?.theme
            ZStack {
                Rectangle().fill(.bar)
                if let theme {
                    let color = Color(red: theme.red, green: theme.green, blue: theme.blue)
                    LinearGradient(colors: [color.opacity(0.22), color.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
                }
            }
        }
    }

    /// Arc's "Open in <Space> ⌘O ⌄": the space of the last focused browser
    /// window, in its theme colour, and a menu of the profile's other spaces.
    @ViewBuilder
    private func openInButton(for record: LittleArcWindow) -> some View {
        let target = model.store.littleArcTargetSpace(for: windowID)
        let others = model.store.spaces(in: record.profileID).filter { $0.id != target?.id }
        HStack(spacing: 0) {
            Button {
                open(into: target?.id)
            } label: {
                HStack(spacing: 4) {
                    Text("Open in").foregroundStyle(.secondary)
                    Text(target?.name ?? "ReArc")
                        .fontWeight(.medium)
                        .foregroundStyle(target.map { Color(red: $0.theme.red, green: $0.theme.green, blue: $0.theme.blue) } ?? .primary)
                    Text("⌘O")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Move this page into a tab in \(target?.name ?? "your current space")")
            .accessibilityLabel("Open in \(target?.name ?? "ReArc")")
            if !others.isEmpty {
                Divider().frame(height: 14)
                Menu {
                    ForEach(others) { space in
                        Button(space.name) { open(into: space.id) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 6)
                .help("Open in another space")
                .accessibilityLabel("Open in another space")
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        // The address field gives way: at the default 520 pt the label read "Open… Pers…".
        .fixedSize()
    }

    private func open(into spaceID: Space.ID?) {
        model.promoteLittleArcWindow(windowID, into: spaceID)
        dismiss()
    }

    private func navButton(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    /// The command-bar placeholder: the site's host; click (or ⌘L) to type
    /// a URL or search, which loads in this window. A domain completes inline.
    @ViewBuilder
    private func address(for record: LittleArcWindow, engine: any WebEngine) -> some View {
        Group {
            if isEditingAddress {
                let suffix = InlineDomainCompletion.complete(addressText, candidates: InlineDomainCompletion.candidates(history: model.visitHistory))
                    .flatMap { InlineDomainCompletion.suffix(typed: addressText, completion: $0) }
                TextField("Search or enter URL", text: $addressText)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .overlay(alignment: .leading) {
                        if let suffix {
                            (Text(addressText).foregroundColor(.clear) + Text(suffix).foregroundColor(.secondary.opacity(0.7)))
                                .lineLimit(1)
                                .allowsHitTesting(false)
                        }
                    }
                    .onKeyPress(.rightArrow, phases: .down) { press in
                        guard press.modifiers.isEmpty, let suffix else { return .ignored }
                        addressText += suffix
                        return .handled
                    }
                    .onSubmit {
                        let text = addressText + (suffix ?? "")
                        if model.navigateLittleArc(windowID, to: text) { isEditingAddress = false }
                    }
                    .onExitCommand { isEditingAddress = false }
                    .onChange(of: addressFocused) { _, focused in if !focused { isEditingAddress = false } }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: securityIcon(engine.securityState))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    // Arc centres the host in the field.
                    Spacer(minLength: 0)
                    let text = LittleArcChrome.addressText(for: engine.currentURL ?? record.url)
                    Text(text.isEmpty ? "Search or enter URL" : text)
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    // Keeps the host centred against the icon on the left.
                    Color.clear.frame(width: 10, height: 1)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: beginEditing)
                .help((engine.currentURL ?? record.url).absoluteString)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Address, \(record.url.absoluteString)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(isEditingAddress ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 7))
    }

    private func securityIcon(_ state: WebSecurityState) -> String {
        switch state {
        case .secure: return "lock.fill"
        case .insecure, .dangerous: return "exclamationmark.triangle.fill"
        case .none, .unknown: return "globe"
        }
    }

    /// Arc's `littleBrowserProfileIndicator`: which profile this window uses, and a switch.
    @ViewBuilder
    private func profileMenu(for record: LittleArcWindow) -> some View {
        if let profile = model.store.profile(withID: record.profileID) {
            Menu {
                ForEach(model.store.profiles) { other in
                    Button {
                        model.changeLittleArcProfile(windowID, to: other.id)
                    } label: {
                        if other.id == profile.id {
                            Label(other.name, systemImage: "checkmark")
                        } else {
                            Text(other.name)
                        }
                    }
                }
            } label: {
                ProfileAvatarView(profile: profile, diameter: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Profile: \(profile.name)")
            .accessibilityLabel("Profile \(profile.name)")
        }
    }
}
