import Darwin
import Foundation

public struct FallbackGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var members: [String]
    public var next: UUID?

    public init(id: UUID = UUID(), name: String, members: [String] = [], next: UUID? = nil) {
        self.id = id
        self.name = name
        self.members = members
        self.next = next
    }
}

public struct AutoSwitchSettings: Codable, Equatable, Sendable {
    public var groups: [FallbackGroup]

    public init(groups: [FallbackGroup] = []) {
        self.groups = groups
    }

    public func group(containing name: String) -> FallbackGroup? {
        groups.first { $0.members.contains(name) }
    }

    public func group(_ id: UUID?) -> FallbackGroup? {
        groups.first { $0.id == id }
    }

    public mutating func move(_ name: String, to groupID: UUID?) {
        for i in groups.indices { groups[i].members.removeAll { $0 == name } }
        if let i = groups.firstIndex(where: { $0.id == groupID }) { groups[i].members.append(name) }
    }

    public mutating func remove(group id: UUID) {
        groups.removeAll { $0.id == id }
        for i in groups.indices where groups[i].next == id { groups[i].next = nil }
    }

    public mutating func renameMember(_ name: String, to newName: String) {
        for i in groups.indices {
            groups[i].members = groups[i].members.map { $0 == name ? newName : $0 }
        }
    }

    public static func defaults(for profiles: [Profile]) -> AutoSwitchSettings {
        var groups: [FallbackGroup] = []
        var byOrganization: [String: Int] = [:]
        for profile in profiles {
            let key = profile.account?.organizationUuid ?? profile.name
            if let i = byOrganization[key] {
                groups[i].members.append(profile.name)
            } else {
                byOrganization[key] = groups.count
                groups.append(FallbackGroup(name: profile.account?.organizationLabel ?? profile.name, members: [profile.name]))
            }
        }
        return AutoSwitchSettings(groups: groups)
    }
}

extension AccountInfo {
    public var organizationLabel: String? {
        guard let name = organizationName else { return nil }
        return name.hasSuffix("'s Organization") ? "Personal" : name
    }
}

public enum AutoSwitchOutcome: Equatable, Sendable {
    case switched(from: String, to: String)
    case ignored(String)
}

public struct AutoSwitch {
    public let store: ProfileStore
    public static let debounce: TimeInterval = 60

    public init(store: ProfileStore) {
        self.store = store
    }

    public func hasSettings() -> Bool {
        FileManager.default.fileExists(atPath: settingsURL.path)
    }

    public func settings() -> AutoSwitchSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(AutoSwitchSettings.self, from: data) else {
            return .defaults(for: store.profiles(includeTokens: false))
        }
        return settings
    }

    public func save(_ settings: AutoSwitchSettings) throws {
        try FileManager.default.createDirectory(at: store.paths.profileDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }

    public func update(_ change: (inout AutoSwitchSettings) -> Void) {
        guard hasSettings() else { return }
        var settings = settings()
        change(&settings)
        try? save(settings)
    }

    public static func fallback(from active: Profile, in profiles: [Profile], settings: AutoSwitchSettings,
                                now: Date = Date()) -> Profile? {
        var group = settings.group(containing: active.name)
        var visited: Set<UUID> = []
        while let current = group, visited.insert(current.id).inserted {
            let candidates = profiles.filter { profile in
                guard profile.name != active.name, current.members.contains(profile.name),
                      let tokens = profile.tokens, tokens.hasTokens, !tokens.isRefreshExpired(now: now) else { return false }
                return profile.usage?.isExhausted(now: now) != true
            }
            let pick = candidates.min { a, b in
                let pa = a.usage?.peakPercent(now: now) ?? 0, pb = b.usage?.peakPercent(now: now) ?? 0
                return pa != pb ? pa < pb : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            if let pick { return pick }
            group = settings.group(current.next)
        }
        return nil
    }

    public func handleLimit(message: String, now: Date = Date()) -> AutoSwitchOutcome {
        guard let limit = UsageLimit(message: message, now: now) else {
            return .ignored("not a usage limit: \(message)")
        }
        return withLock {
            if let last = lastSwitch(), now.timeIntervalSince(last) < Self.debounce, now >= last {
                return .ignored("switched \(Int(now.timeIntervalSince(last)))s ago")
            }
            guard let active = store.activeProfile() else {
                return .ignored("the current login isn't a saved account")
            }
            store.recordLimit(limit, for: active.name, now: now)
            let settings = settings()
            let hit = "“\(active.name)” hit its \(limit.window.lowercased()) limit"
            guard settings.group(containing: active.name) != nil else {
                return .ignored("\(hit); it isn't in a fallback group")
            }
            let profiles = store.profiles()
            guard let current = profiles.first(where: { $0.name == active.name }),
                  let target = Self.fallback(from: current, in: profiles, settings: settings, now: now) else {
                return .ignored("\(hit); no account in its fallback groups has usage left")
            }
            do {
                try store.use(target.name)
            } catch {
                return .ignored("couldn't switch to “\(target.name)”: \(error.localizedDescription)")
            }
            setLastSwitch(now)
            return .switched(from: active.name, to: target.name)
        }
    }

    public func log(_ outcome: AutoSwitchOutcome, now: Date = Date()) {
        let text: String
        switch outcome {
        case .switched(let from, let to): text = "switched from “\(from)” to “\(to)”"
        case .ignored(let reason): text = "didn't switch: \(reason)"
        }
        let line = "\(ISO8601DateFormatter().string(from: now)) \(text)\n"
        try? FileManager.default.createDirectory(at: store.paths.profileDir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    var settingsURL: URL { store.paths.profileDir.appendingPathComponent("auto-switch.json") }
    var stateURL: URL { store.paths.profileDir.appendingPathComponent("auto-switch.state.json") }
    var lockURL: URL { store.paths.profileDir.appendingPathComponent("auto-switch.lock") }
    public var logURL: URL { store.paths.profileDir.appendingPathComponent("auto-switch.log") }

    func lastSwitch() -> Date? {
        guard let data = try? Data(contentsOf: stateURL),
              let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stamp = state["lastSwitch"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: stamp)
    }

    func setLastSwitch(_ date: Date) {
        let state = ["lastSwitch": ISO8601DateFormatter().string(from: date)]
        try? JSONSerialization.data(withJSONObject: state).write(to: stateURL, options: .atomic)
    }

    func withLock<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: store.paths.profileDir, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return body()
    }
}
