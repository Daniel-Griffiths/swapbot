import Foundation

public struct ClaudeHooks {
    public static let flag = "--limit-reached"
    static let event = "StopFailure"

    public let settingsURL: URL

    public init(settingsURL: URL) {
        self.settingsURL = settingsURL
    }

    public static func command(executable: String) -> String {
        "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' " + flag
    }

    public func installedCommand() -> String? {
        guard let settings = try? read(),
              let entries = (settings["hooks"] as? [String: Any])?[Self.event] as? [[String: Any]] else { return nil }
        return entries.lazy
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
            .first(where: Self.isOurs)
    }

    public func install(executable: String) throws {
        try update { entries in
            entries.append([
                "matcher": "rate_limit",
                "hooks": [["type": "command", "command": Self.command(executable: executable), "timeout": 30]],
            ])
        }
    }

    public func uninstall() throws {
        guard installedCommand() != nil else { return }
        try update { _ in }
    }

    static func isOurs(_ command: String) -> Bool {
        command.hasSuffix(" " + flag) && command.contains("SwapBot")
    }

    func update(_ change: (inout [[String: Any]]) -> Void) throws {
        var settings = try read()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var entries = (hooks[Self.event] as? [[String: Any]] ?? []).compactMap { entry -> [String: Any]? in
            guard let commands = entry["hooks"] as? [[String: Any]] else { return entry }
            let kept = commands.filter { !Self.isOurs($0["command"] as? String ?? "") }
            if kept.isEmpty { return nil }
            var entry = entry
            entry["hooks"] = kept
            return entry
        }
        change(&entries)
        hooks[Self.event] = entries.isEmpty ? nil : entries
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        do {
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            throw AccountsError.settings("couldn't write it (\(error.localizedDescription))")
        }
    }

    func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: settingsURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AccountsError.settings("it isn't valid JSON, so it was left alone")
        }
        return object
    }
}
