import Foundation
import AccountsCore

@MainActor
enum Power {
    /// Whether `pmset disablesleep` is on, which keeps the Mac awake with the lid closed.
    static var sleepDisabled: Bool {
        Shell.run("/usr/bin/pmset", ["-g"]).stdout
            .split(separator: "\n")
            .contains { line in
                let parts = line.split(whereSeparator: \.isWhitespace)
                return parts.first == "SleepDisabled" && parts.last == "1"
            }
    }

    /// Runs `pmset -a disablesleep`, asking for an administrator password. Cancelling the password prompt changes nothing.
    static func setSleepDisabled(_ disabled: Bool) throws {
        let script = NSAppleScript(source: "do shell script \"/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)\" with administrator privileges")
        var info: NSDictionary?
        script?.executeAndReturnError(&info)
        guard let info, info[NSAppleScript.errorNumber] as? Int != -128 else { return }
        throw PowerError(message: info[NSAppleScript.errorMessage] as? String ?? "pmset failed")
    }

    struct PowerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
