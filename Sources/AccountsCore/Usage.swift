import Foundation

public struct UsageWindow: Codable, Equatable, Sendable {
    public let name: String
    public let percent: Double
    public let resetsAt: Date?
    public let resetsText: String?

    public init(name: String, percent: Double, resetsAt: Date? = nil, resetsText: String? = nil) {
        self.name = name
        self.percent = percent
        self.resetsAt = resetsAt
        self.resetsText = resetsText
    }

    public func hasReset(now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

public struct Usage: Codable, Equatable, Sendable {
    public let windows: [UsageWindow]
    public let recordedAt: Date

    public init(windows: [UsageWindow], recordedAt: Date = Date()) {
        self.windows = windows
        self.recordedAt = recordedAt
    }

    public init?(claudeOutput text: String, now: Date = Date()) {
        let pattern = #"^Current (session|week[^:]*):\s*(\d+(?:\.\d+)?)% used(?:\s*·\s*resets\s+(.+?))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        windows = regex.matches(in: text, range: range).compactMap { match in
            func group(_ i: Int) -> String? {
                Range(match.range(at: i), in: text).map { String(text[$0]) }
            }
            guard let rawName = group(1), let percent = group(2).flatMap(Double.init) else { return nil }
            let name = rawName.prefix(1).uppercased() + rawName.dropFirst()
            let resets = group(3)
            return UsageWindow(
                name: name,
                percent: percent,
                resetsAt: resets.flatMap { Self.parseReset($0, now: now) },
                resetsText: resets.map(Self.stripTimeZone)
            )
        }
        recordedAt = now
        if windows.isEmpty { return nil }
    }

    static func stripTimeZone(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
    }

    static func parseReset(_ s: String, now: Date) -> Date? {
        var zone = TimeZone.current
        if let open = s.lastIndex(of: "("), let close = s.lastIndex(of: ")"), open < close,
           let named = TimeZone(identifier: String(s[s.index(after: open)..<close])) {
            zone = named
        }
        let text = stripTimeZone(s)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let year = calendar.component(.year, from: now)

        for format in ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d, yyyy 'at' h:mma", "MMM d, yyyy 'at' ha"] {
            formatter.dateFormat = format.contains("yyyy") ? format : "yyyy " + format
            let input = format.contains("yyyy") ? text : "\(year) \(text)"
            guard var date = formatter.date(from: input) else { continue }
            if !format.contains("yyyy"), date < now.addingTimeInterval(-30 * 86_400),
               let next = calendar.date(byAdding: .year, value: 1, to: date) {
                date = next
            }
            return date
        }
        for format in ["h:mma", "ha"] {
            formatter.dateFormat = format
            guard let time = formatter.date(from: text) else { continue }
            let parts = calendar.dateComponents([.hour, .minute], from: time)
            guard var date = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now) else { continue }
            if date < now, let next = calendar.date(byAdding: .day, value: 1, to: date) { date = next }
            return date
        }
        return nil
    }
}

extension Usage {
    func marking(_ limit: UsageLimit, now: Date) -> Usage {
        let full = UsageWindow(name: limit.window, percent: 100, resetsAt: limit.resetsAt, resetsText: limit.resetsText)
        var windows = self.windows
        if let i = windows.firstIndex(where: { $0.name == limit.window }) {
            windows[i] = full
        } else if limit.window == "Session" {
            windows.insert(full, at: 0)
        } else {
            windows.append(full)
        }
        return Usage(windows: windows, recordedAt: now)
    }

    public func isExhausted(now: Date = Date()) -> Bool {
        windows.contains { !$0.hasReset(now: now) && $0.percent >= 100 }
    }

    public func availableAt(now: Date = Date()) -> Date? {
        let full = windows.filter { !$0.hasReset(now: now) && $0.percent >= 100 }
        if full.isEmpty { return now }
        let resets = full.compactMap(\.resetsAt)
        return resets.count == full.count ? resets.max() : nil
    }

    public func peakPercent(now: Date = Date()) -> Double {
        windows.filter { !$0.hasReset(now: now) }.map(\.percent).max() ?? 0
    }
}

public struct UsageLimit: Equatable, Sendable {
    public let window: String
    public let resetsAt: Date?
    public let resetsText: String?

    public init?(message: String, now: Date = Date()) {
        let pattern = #"hit your (.+?) limit(?:\s*·\s*resets\s+(.+?))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let kindRange = Range(match.range(at: 1), in: message) else { return nil }
        let kind = message[kindRange].lowercased()
        let resets = Range(match.range(at: 2), in: message).map { String(message[$0]) }
        if kind.contains("session") {
            window = "Session"
        } else if kind.contains("week") {
            window = "Week"
        } else {
            window = kind.prefix(1).uppercased() + kind.dropFirst()
        }
        resetsAt = resets.flatMap { Usage.parseReset($0, now: now) }
            ?? now.addingTimeInterval(window == "Session" ? 5 * 3600 : 7 * 86_400)
        resetsText = resets.map(Usage.stripTimeZone)
    }
}

public struct CachedUsage: Equatable, Sendable {
    public let accountUuid: String
    public let usage: Usage

    static let windows = [("five_hour", "Session"), ("seven_day", "Week"),
                          ("seven_day_opus", "Week (Opus)"), ("seven_day_sonnet", "Week (Sonnet)")]

    public init?(_ json: Any?) {
        guard let d = json as? [String: Any], let accountUuid = d["accountUuid"] as? String,
              let fetched = (d["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let utilization = d["utilization"] as? [String: Any] else { return nil }
        let windows = Self.windows.compactMap { key, name -> UsageWindow? in
            guard let window = utilization[key] as? [String: Any],
                  let percent = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(name: name, percent: percent, resetsAt: (window["resets_at"] as? String).flatMap(Self.date))
        }
        guard !windows.isEmpty else { return nil }
        self.accountUuid = accountUuid
        usage = Usage(windows: windows, recordedAt: Date(timeIntervalSince1970: (fetched / 1000).rounded(.down)))
    }

    static func date(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

public enum ClaudeCLI {
    public static func executable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let path = Shell.run("/bin/zsh", ["-ilc", "command -v claude"], timeout: 10).stdout
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    public static func usage(timeout: TimeInterval = 30) -> Usage? {
        guard let claude = executable() else { return nil }
        let result = Shell.run(claude, ["-p", "/usage"], timeout: timeout,
                               directory: FileManager.default.temporaryDirectory)
        guard result.status == 0 else { return nil }
        return Usage(claudeOutput: result.stdout)
    }
}
