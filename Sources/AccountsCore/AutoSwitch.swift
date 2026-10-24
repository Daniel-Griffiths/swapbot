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
    case waiting(String, until: Date)
    case ignored(String)
}

struct AutoSwitchState: Codable {
    var lastSwitch: Date?
    var retryAt: Date?
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

    static func chain(from active: Profile, in profiles: [Profile], settings: AutoSwitchSettings,
                      now: Date) -> [[Profile]] {
        var chain: [[Profile]] = []
        var group = settings.group(containing: active.name)
        var visited: Set<UUID> = []
        while let current = group, visited.insert(current.id).inserted {
            chain.append(profiles.filter { profile in
                guard profile.name != active.name, current.members.contains(profile.name),
                      let tokens = profile.tokens else { return false }
                return tokens.hasTokens && !tokens.isRefreshExpired(now: now)
            })
            group = settings.group(current.next)
        }
        return chain
    }

    public static func fallback(from active: Profile, in profiles: [Profile], settings: AutoSwitchSettings,
                                now: Date = Date()) -> Profile? {
        for candidates in chain(from: active, in: profiles, settings: settings, now: now) {
            let pick = candidates.filter { $0.usage?.isExhausted(now: now) != true }.min { a, b in
                let pa = a.usage?.peakPercent(now: now) ?? 0, pb = b.usage?.peakPercent(now: now) ?? 0
                return pa != pb ? pa < pb : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            if let pick { return pick }
        }
        return nil
    }

    public static func nextAvailability(from active: Profile, in profiles: [Profile], settings: AutoSwitchSettings,
                                        now: Date = Date()) -> Date? {
        let times = chain(from: active, in: profiles, settings: settings, now: now).joined().compactMap { profile -> Date? in
            guard let usage = profile.usage else { return now }
            return usage.availableAt(now: now)
        }
        guard let earliest = times.min() else { return nil }
        if let own = active.usage?.availableAt(now: now), own <= earliest { return nil }
        return earliest
    }

    public func handleLimit(message: String, now: Date = Date()) -> AutoSwitchOutcome {
        guard let limit = UsageLimit(message: message, now: now) else {
            return .ignored("not a usage limit: \(message)")
        }
        return withLock {
            if let last = readState().lastSwitch, now.timeIntervalSince(last) < Self.debounce, now >= last {
                return .ignored("switched \(Int(now.timeIntervalSince(last)))s ago")
            }
            guard let active = store.activeProfile() else {
                return .ignored("the current login isn't a saved account")
            }
            store.recordLimit(limit, for: active.name, now: now)
            return switchOrWait(from: active.name, reason: "“\(active.name)” hit its \(limit.window.lowercased()) limit", now: now)
        }
    }

    public func pendingRetry() -> Date? {
        readState().retryAt
    }

    public func retry(now: Date = Date()) -> AutoSwitchOutcome {
        withLock {
            var state = readState()
            state.retryAt = nil
            writeState(state)
            guard let active = store.activeProfile() else {
                return .ignored("the current login isn't a saved account")
            }
            guard active.usage?.isExhausted(now: now) == true else {
                return .ignored("“\(active.name)” has usage again, so it stays")
            }
            return switchOrWait(from: active.name, reason: "“\(active.name)” is still used up", now: now)
        }
    }

    func switchOrWait(from name: String, reason: String, now: Date) -> AutoSwitchOutcome {
        let settings = settings()
        guard settings.group(containing: name) != nil else {
            return .ignored("\(reason); it isn't in a fallback group")
        }
        let profiles = store.profiles()
        guard let active = profiles.first(where: { $0.name == name }) else {
            return .ignored("\(reason); it's no longer saved")
        }
        if let target = Self.fallback(from: active, in: profiles, settings: settings, now: now) {
            do {
                try store.use(target.name)
            } catch {
                return .ignored("couldn't switch to “\(target.name)”: \(error.localizedDescription)")
            }
            writeState(AutoSwitchState(lastSwitch: now, retryAt: nil))
            return .switched(from: name, to: target.name)
        }
        guard let available = Self.nextAvailability(from: active, in: profiles, settings: settings, now: now) else {
            return .ignored("\(reason); nothing it can switch to resets before it does")
        }
        var state = readState()
        state.retryAt = max(available, now.addingTimeInterval(60))
        writeState(state)
        return .waiting("\(reason) and everything it can switch to is used up", until: state.retryAt!)
    }

    public func log(_ outcome: AutoSwitchOutcome, now: Date = Date()) {
        let text: String
        switch outcome {
        case .switched(let from, let to): text = "switched from “\(from)” to “\(to)”"
        case .waiting(let reason, let until): text = "\(reason); trying again at \(ISO8601DateFormatter().string(from: until))"
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

    func readState() -> AutoSwitchState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(AutoSwitchState.self, from: data) else { return AutoSwitchState() }
        return state
    }

    func writeState(_ state: AutoSwitchState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(state).write(to: stateURL, options: .atomic)
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
