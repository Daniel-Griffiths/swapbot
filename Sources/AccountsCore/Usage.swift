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
