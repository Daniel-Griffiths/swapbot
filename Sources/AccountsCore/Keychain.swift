import Foundation

public struct Keychain: Sendable {
    public let account: String
    private let tool = "/usr/bin/security"

    public init(account: String = NSUserName()) {
        self.account = account
    }

    public func read(_ service: String) throws -> String? {
        let r = Shell.run(tool, ["find-generic-password", "-s", service, "-a", account, "-w"])
        if r.status == 44 { return nil }
        guard r.status == 0 else {
            throw AccountsError.keychain("couldn't read \(service): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        var value = r.stdout
        if value.hasSuffix("\n") { value.removeLast() }
        if !value.hasPrefix("{"), let decoded = Self.decodeHex(value) {
            return decoded
        }
        return value
    }

    public func read(_ services: [String]) -> [String?] {
        let results = Results(count: services.count)
        DispatchQueue.concurrentPerform(iterations: services.count) { i in
            results.set(i, try? read(services[i]))
        }
        return results.values
    }

    public func write(_ service: String, _ value: String) throws {
        let r = Shell.run(tool, ["add-generic-password", "-U", "-s", service, "-a", account, "-w", value])
        guard r.status == 0 else {
            throw AccountsError.keychain("couldn't write \(service): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard try read(service) == value else {
            throw AccountsError.keychain("wrote \(service) but it didn't read back intact")
        }
    }

    public func delete(_ service: String) throws {
        let r = Shell.run(tool, ["delete-generic-password", "-s", service, "-a", account])
        guard r.status == 0 || r.status == 44 else {
            throw AccountsError.keychain("couldn't delete \(service): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String?]

        init(count: Int) {
            storage = Array(repeating: nil, count: count)
        }

        var values: [String?] {
            lock.withLock { storage }
        }

        func set(_ index: Int, _ value: String?) {
            lock.withLock { storage[index] = value }
        }
    }

    static func decodeHex(_ s: String) -> String? {
        guard s.count.isMultiple(of: 2), !s.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
