import AppKit
import SwiftUI

@MainActor
enum AutoSwitchWindow {
    private static var window: NSWindow?

    static func show() {
        let controller = NSHostingController(rootView: AutoSwitchView(model: AutoSwitchModel()))
        controller.sizingOptions = .preferredContentSize
        if let window {
            window.contentViewController = controller
        } else {
            let window = NSWindow(contentViewController: controller)
            window.title = "Auto-Switch"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { window?.makeFirstResponder(nil) }
    }
}

@MainActor
@Observable
final class AutoSwitchModel {
    struct Account: Identifiable {
        var id: String { name }
        let name: String
        let organization: String
        let organizationID: String
    }

    private(set) var accounts: [Account] = []
    private(set) var settings = AutoSwitchSettings(groups: [])
    private(set) var enabled = false

    init() {
        reload()
    }

    private func reload() {
        do {
            let status = try CLI.decode(AutoSwitchStatus.self, ["auto-switch", "--json"])
            settings = status.settings
            enabled = status.enabled
            accounts = status.accounts.map { profile in
                Account(name: profile.name,
                        organization: profile.account?.organizationLabel ?? profile.account?.email ?? profile.name,
                        organizationID: profile.account?.organizationUuid ?? profile.name)
            }
        } catch {
            Prompts.error(error, title: "Couldn't read the Auto-Switch settings")
        }
    }

    var orderedGroups: [FallbackGroup] {
        let targeted = Set(settings.groups.compactMap(\.next))
        var order: [FallbackGroup] = []
        var seen: Set<UUID> = []
        func follow(_ start: FallbackGroup) {
            var group: FallbackGroup? = start
            while let current = group, seen.insert(current.id).inserted {
                order.append(current)
                group = settings.group(current.next)
            }
        }
        settings.groups.filter { !targeted.contains($0.id) }.forEach(follow)
        settings.groups.forEach(follow)
        return order
    }

    var ungrouped: [Account] {
        accounts.filter { settings.group(containing: $0.name) == nil }
    }

    func members(of group: FallbackGroup) -> [Account] {
        group.members.compactMap { name in accounts.first { $0.name == name } }
    }

    func mixesOrganizations(_ group: FallbackGroup) -> Bool {
        Set(members(of: group).map(\.organizationID)).count > 1
    }

    func crossesOrganizations(from group: FallbackGroup, to next: FallbackGroup) -> Bool {
        let from = Set(members(of: group).map(\.organizationID)), to = Set(members(of: next).map(\.organizationID))
        return from.count != 1 || from != to
    }

    func setEnabled(_ on: Bool) {
        change(["auto-switch", on ? "on" : "off"], failure: "Couldn't change the Claude Code hook")
    }

    func move(_ name: String, to group: UUID?) {
        change(["group", "move", "--", name, group?.uuidString ?? "none"])
    }

    func rename(_ group: UUID, to name: String) {
        change(["group", "rename", "--", group.uuidString, name])
    }

    func setNext(_ next: UUID?, for group: UUID) {
        change(["group", "next", "--", group.uuidString, next?.uuidString ?? "none"])
    }

    func addGroup() {
        change(["group", "add", "--", "New Group"])
    }

    func removeGroup(_ group: UUID) {
        change(["group", "remove", "--", group.uuidString])
    }

    private func change(_ arguments: [String], failure: String = "Couldn't save the Auto-Switch settings") {
        do {
            try CLI.run(arguments)
        } catch {
            Prompts.error(error, title: failure)
        }
        reload()
    }
}

struct AutoSwitchView: View {
    let model: AutoSwitchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Card {
                    HStack {
                        Text("Switch accounts when one hits its usage limit")
                        Spacer()
                        Toggle("Switch accounts when one hits its usage limit",
                               isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                Footnote("Adds a hook to ~/.claude/settings.json, so Claude Code tells SwapBot when a turn stops at a session or weekly limit. SwapBot then switches straight away, without asking.")

                VStack(alignment: .leading, spacing: 0) {
                    Text("Fallback groups")
                        .font(.headline)
                        .padding(.horizontal, 4)
                        .padding(.top, 22)
                        .padding(.bottom, 8)

                    let order = model.orderedGroups
                    ForEach(Array(order.enumerated()), id: \.element.id) { index, group in
                        GroupCard(model: model, group: group)
                        Connector(model: model, group: group, below: index + 1 < order.count ? order[index + 1] : nil)
                    }

                    NeverSwitchTray(model: model)
                        .padding(.top, 2)

                    Button("+ New Group") { model.addGroup() }
                        .buttonStyle(.link)
                        .padding(.top, 12)
                        .padding(.horizontal, 4)

                    Footnote("When an account runs out, SwapBot switches to the member of its group that has used the least. When every member is used up, it moves on to the next group.")
                }
                .disabled(!model.enabled)
                .opacity(model.enabled ? 1 : 0.5)
            }
            .padding(20)
        }
        .frame(width: 560)
        .frame(minHeight: 360, idealHeight: 720)
    }
}

private struct GroupCard: View {
    let model: AutoSwitchModel
    let group: FallbackGroup
    @State private var isTargeted = false

    var body: some View {
        let showOrganization = model.mixesOrganizations(group)
        let spare = model.accounts.filter { !group.members.contains($0.name) }
        Card(highlighted: isTargeted) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Group name", text: Binding(get: { group.name }, set: { model.rename(group.id, to: $0) }))
                        .textFieldStyle(.plain)
                        .font(.headline)
                    Button {
                        model.removeGroup(group.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Delete group")
                }

                FlowLayout(spacing: 6) {
                    if group.members.isEmpty {
                        Text("Drag accounts here").italic().foregroundStyle(.tertiary)
                    }
                    ForEach(model.members(of: group)) { account in
                        Chip(account: account, showOrganization: showOrganization) {
                            model.move(account.name, to: nil)
                        }
                    }
                    if !spare.isEmpty {
                        Menu("Add Account") {
                            ForEach(spare) { account in
                                let other = model.settings.group(containing: account.name)
                                Button(account.name + (other.map { " (move from \($0.name))" } ?? "")) {
                                    model.move(account.name, to: group.id)
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                if showOrganization {
                    Label("This group mixes organizations. Switching between them makes running sessions resend their whole conversation uncached.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
                }

                Divider()

                HStack {
                    Text("When all are used up, switch to").foregroundStyle(.secondary)
                    Spacer()
                    Picker("When all are used up, switch to",
                           selection: Binding(get: { group.next }, set: { model.setNext($0, for: group.id) })) {
                        Text("Nothing").tag(UUID?.none)
                        ForEach(model.settings.groups.filter { $0.id != group.id }) { other in
                            Text(other.name).tag(Optional(other.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .dropDestination(for: String.self) { names, _ in
            guard let name = names.first else { return false }
            model.move(name, to: group.id)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

private struct Connector: View {
    let model: AutoSwitchModel
    let group: FallbackGroup
    let below: FallbackGroup?

    var body: some View {
        if let next = model.settings.group(group.next), next.id == below?.id {
            let cross = model.crossesOrganizations(from: group, to: next)
            let color: Color = cross ? .orange : .secondary
            VStack(spacing: 2) {
                Rectangle().fill(color).frame(width: 2, height: 10)
                Text(cross ? "different organization · loses the prompt cache" : "same organization · keeps the cache")
                    .font(.caption)
                    .foregroundStyle(color)
                Rectangle().fill(color).frame(width: 2, height: 10)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(color)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
        } else if let next = model.settings.group(group.next) {
            Text("↪ then back to \(next.name)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, below == nil ? 0 : 14)
        } else if below != nil {
            Spacer().frame(height: 14)
        }
    }
}

private struct NeverSwitchTray: View {
    let model: AutoSwitchModel
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Never switch: accounts here stay put when they run out. Drag an account into a group to include it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                if model.ungrouped.isEmpty {
                    Text("Every account is in a group").italic().foregroundStyle(.tertiary)
                }
                ForEach(model.ungrouped) { account in
                    Chip(account: account, showOrganization: true, onRemove: nil)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isTargeted ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .padding(.top, 12)
        .dropDestination(for: String.self) { names, _ in
            guard let name = names.first else { return false }
            model.move(name, to: nil)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

private struct Chip: View {
    let account: AutoSwitchModel.Account
    let showOrganization: Bool
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Text(account.name)
            if showOrganization {
                Text(account.organization).font(.caption).foregroundStyle(.secondary)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Move to Never switch")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, onRemove == nil ? 9 : 6)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .draggable(account.name)
    }
}

private struct Card<Content: View>: View {
    var highlighted = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(highlighted ? Color.accentColor : Color(nsColor: .separatorColor)))
    }
}

private struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 7)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = arrange(subviews, width: width)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
