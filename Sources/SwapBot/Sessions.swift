import Foundation

enum Sessions {
    static func openInTerminal(name: String, _ body: String) throws {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwapBot", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("\(name).command")
        try "#!/bin/zsh -il\nclear\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let r = Shell.run("/usr/bin/open", ["-a", "Terminal", script.path])
        if r.status != 0 {
            throw TerminalError(message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    struct TerminalError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
