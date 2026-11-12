import SwiftUI
import SidebarModel

/// Air Traffic Control settings (Arc `LinkRouting`): ordered rules that send
/// links from other apps to a space or to a Little Arc in a profile, the
/// fallback for everything else, and a link tester.
struct AirTrafficControlView: View {
    @Bindable var model: BrowserViewModel
    @State private var testLink = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Links you open in other apps go to the first rule that matches. Rules for a deleted space or profile are skipped.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.linkRouting.rules.isEmpty {
                Text("No rules yet.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($model.linkRouting.rules) { $rule in
                            ruleRow($rule)
                        }
                    }
                }
                .frame(minHeight: 80, maxHeight: 260)
            }

            HStack {
                Button {
                    model.addLinkRoutingRule()
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                Spacer()
                Picker("Other links", selection: $model.externalLinkDestination) {
                    ForEach(ExternalLinkDestination.allCases, id: \.self) { destination in
                        Text(destination.menuTitle).tag(destination)
                    }
                }
                .fixedSize()
            }

            Divider()
            HStack(spacing: 8) {
                TextField("Test a link, like https://github.com/rearc", text: $testLink)
                    .textFieldStyle(.roundedBorder)
                if let answer = model.describeExternalRoute(testLink) {
                    Label(answer, systemImage: "arrow.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(18)
        .frame(width: 640)
    }

    private func ruleRow(_ rule: Binding<LinkRoutingRule>) -> some View {
        let value = rule.wrappedValue
        return HStack(spacing: 8) {
            Toggle("", isOn: rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(value.isEnabled ? "Rule on" : "Rule off")
            Picker("", selection: rule.matchType) {
                ForEach(LinkRoutingRule.MatchType.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField(value.matchType.placeholder, text: rule.pattern)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(value.pattern.isEmpty || value.isValid ? Color.primary : Color.red)
                .help(value.isValid || value.pattern.isEmpty ? "" : "This pattern matches nothing")
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("", selection: rule.destination) {
                ForEach(model.store.listedProfiles) { profile in
                    ForEach(model.store.spaces(listedIn: profile.id)) { space in
                        Text(ExternalLinkRouting.describe(.space(space.id), in: model.store)).tag(LinkRoutingRule.Destination.space(space.id))
                    }
                }
                Divider()
                ForEach(model.store.profiles) { profile in
                    Text(ExternalLinkRouting.describe(.littleArc(profile.id), in: model.store))
                        .tag(LinkRoutingRule.Destination.littleArc(profile.id))
                }
                if !LinkRoutingState.destinationExists(value.destination, in: model.store) {
                    Text(ExternalLinkRouting.describe(value.destination, in: model.store)).tag(value.destination)
                }
            }
            .labelsHidden()
            .frame(width: 170)
            Button { model.linkRouting.move(value.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(model.linkRouting.rules.first?.id == value.id)
                .help("Move up: earlier rules win")
            Button { model.linkRouting.move(value.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(model.linkRouting.rules.last?.id == value.id)
                .help("Move down")
            Button { model.removeLinkRoutingRule(value.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete rule")
        }
    }
}

extension BrowserViewModel {
    /// App menu and command bar: the Chromium shell's window, or the WebKit scene.
    func showAirTrafficControl() {
        if let present = presentAirTrafficControl {
            present()
        } else {
            isAirTrafficControlPresented = true
        }
    }

    /// A new rule for the page on screen's domain, sending it to the current space.
    @discardableResult
    func addLinkRoutingRule() -> LinkRoutingRule {
        let host = store.selectedTab?.url.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        let rule = LinkRoutingRule(matchType: .domain, pattern: host, destination: .space(store.activeSpaceID))
        linkRouting.rules.append(rule)
        return rule
    }

    func removeLinkRoutingRule(_ id: LinkRoutingRule.ID) {
        linkRouting.rules.removeAll { $0.id == id }
    }

    /// The link tester: where `text` would go now, or nil for an empty field.
    func describeExternalRoute(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)") else {
            return ExternalLinkRouting.describe(.rejected, in: store)
        }
        let route = ExternalLinkRouting.route(url, destination: externalLinkDestination, in: store,
                                              engine: engineHost.navigationSchemes, rules: linkRouting)
        return ExternalLinkRouting.describe(route, in: store)
    }
}
