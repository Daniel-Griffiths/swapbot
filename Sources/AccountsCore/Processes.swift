import Darwin
import Foundation

public enum Processes {
    public static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    @discardableResult
    public static func terminate(_ pids: [Int32], grace: TimeInterval = 5) -> [Int32] {
        for pid in pids { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        var remaining = pids.filter(isRunning)
        while !remaining.isEmpty && Date() < deadline {
            usleep(100_000)
            remaining = remaining.filter(isRunning)
        }
        for pid in remaining { kill(pid, SIGKILL) }
        usleep(200_000)
        return remaining.filter(isRunning)
    }
}
