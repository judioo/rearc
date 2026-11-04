import AppKit
import SidebarModel
import SwiftUI

extension View {
    /// The page's prompts over this page view only: a JavaScript dialog
    /// (the page dims and waits; other tabs do not), the permission prompt at
    /// the top leading corner next to the sidebar's URL field, and the
    /// password offer at the top trailing corner. The anchor underneath gives
    /// file panels their window and menus their coordinates.
    func pagePrompts(_ prompts: PagePromptCenter) -> some View {
        modifier(PagePromptOverlay(prompts: prompts))
    }
}

private struct PagePromptOverlay: ViewModifier {
    let prompts: PagePromptCenter

    func body(content: Content) -> some View {
        content
            .background(PromptAnchor(prompts: prompts))
            .overlay(alignment: .topLeading) {
                if let permission = prompts.permission {
                    PermissionPromptCard(prompts: prompts, permission: permission)
                        .id(permission.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let password = prompts.password {
                    PasswordPromptCard(prompts: prompts, prompt: password.prompt)
                        .id(password.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay {
                if let dialog = prompts.dialog {
                    JavaScriptDialogSheet(prompts: prompts, dialog: dialog)
                        .id(dialog.id)
                        .transition(.opacity)
                }
            }
            .animation(.spring(duration: 0.24, bounce: 0.12), value: prompts.permission?.id)
            .animation(.spring(duration: 0.24, bounce: 0.12), value: prompts.password?.id)
            .animation(.easeOut(duration: 0.14), value: prompts.dialog?.id)
    }
}

/// Transparent, click-through view the size of the page.
private struct PromptAnchor: NSViewRepresentable {
    let prompts: PagePromptCenter

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        prompts.anchorView = view
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        if prompts.anchorView !== nsView, nsView.window != nil { prompts.anchorView = nsView }
    }

    final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - JavaScript dialog

/// A tab-scoped sheet: it dims and blocks only this page, so the sidebar,
/// other tabs and windows keep working while the page waits.
private struct JavaScriptDialogSheet: View {
    @Bindable var prompts: PagePromptCenter
    let dialog: PagePromptCenter.Dialog
    @FocusState private var fieldFocused: Bool

    private var request: JavaScriptDialogRequest { dialog.request }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: request.kind == .beforeUnload ? "exclamationmark.triangle.fill" : "globe")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(request.kind == .beforeUnload ? Color.orange : Color.secondary)
                    Text(request.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !request.displayMessage.isEmpty {
                    ScrollView {
                        Text(request.displayMessage)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if request.showsTextField {
                    TextField("", text: $prompts.dialogText)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit { prompts.answerDialog(accept: true) }
                }
                if dialog.offersSuppression {
                    Toggle("Don't allow this page to create more dialogs", isOn: $prompts.suppressDialogs)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Spacer()
                    if request.showsCancel {
                        Button(request.kind == .beforeUnload ? "Stay" : "Cancel") { prompts.answerDialog(accept: false) }
                            .keyboardShortcut(.cancelAction)
                    }
                    Button(request.acceptTitle) { prompts.answerDialog(accept: true) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.regular)
            }
            .padding(18)
            .frame(width: 400)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .padding(.top, 64)
        }
        .onExitCommand {
            if request.showsCancel { prompts.answerDialog(accept: false) } else { prompts.answerDialog(accept: true) }
        }
        .onAppear {
            let window = prompts.anchorView?.window
            // The first of a run of dialogs remembers who had the keyboard (the page).
            if prompts.keyboardOwnerBeforeDialog == nil, let owner = window?.firstResponder, owner !== window {
                prompts.keyboardOwnerBeforeDialog = owner
            }
            if request.showsTextField {
                fieldFocused = true
            } else {
                // Take the keyboard from the page so Return and Esc reach the buttons.
                DispatchQueue.main.async { window?.makeFirstResponder(nil) }
            }
        }
        .onDisappear {
            // The last dialog gives the keyboard back to the page.
            guard prompts.dialog == nil, let window = prompts.anchorView?.window,
                  let page = prompts.keyboardOwnerBeforeDialog else { return }
            prompts.keyboardOwnerBeforeDialog = nil
            DispatchQueue.main.async { window.makeFirstResponder(page) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - Permission prompt

private struct PermissionPromptCard: View {
    @Bindable var prompts: PagePromptCenter
    let permission: PagePromptCenter.Permission

    private var request: PermissionPromptRequest { permission.request }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: request.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(request.host) wants to")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ForEach(request.phrases, id: \.self) { phrase in
                        Text(phrase)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    if let note = request.embeddedNote {
                        Text(note).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Button { prompts.answerPermission(.dismiss) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss — the site can ask again")
            }
            if request.needsSystemAuthorization {
                Text("macOS may also ask to allow ReArc.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Toggle("Remember this decision", isOn: $prompts.rememberPermission)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer(minLength: 12)
                Button("Block") { prompts.answerPermission(.deny) }
                Button("Allow") { prompts.answerPermission(.allow) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 5)
        .padding(.top, 10)
        .padding(.leading, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.host) wants to \(request.phrases.joined(separator: ", "))")
    }
}

// MARK: - Password offer

private struct PasswordPromptCard: View {
    let prompts: PagePromptCenter
    let prompt: PasswordSavePrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Label(prompt.displayUsername, systemImage: "person.crop.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: 8) {
                if !prompt.isUpdate {
                    Button("Never") { prompts.answerPassword(.never) }
                        .help("Never save passwords for this site")
                }
                Spacer(minLength: 12)
                Button("Not Now") { prompts.answerPassword(.notNow) }
                Button(prompt.saveTitle) { prompts.answerPassword(.save) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 5)
        .padding(.top, 10)
        .padding(.trailing, 12)
    }
}
