import Foundation

struct ShellResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

enum Shell {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10,
                           directory: URL? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }
        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        for (pipe, box) in [(out, outBox), (err, errBox)] {
            group.enter()
            DispatchQueue.global().async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if group.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                group.wait()
            }
        }
        process.waitUntilExit()
        return ShellResult(
            status: timedOut ? -2 : process.terminationStatus,
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: timedOut
                ? "\(URL(fileURLWithPath: executable).lastPathComponent) didn't respond within \(Int(timeout)) seconds"
                : String(decoding: errBox.data, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
