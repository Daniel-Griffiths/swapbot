import Foundation

struct AccountInfo: Decodable, Equatable {
    let accountUuid: String?
    let organizationUuid: String?
    let email: String?
    let organizationName: String?
    let organizationLabel: String?

    func sharesPromptCache(with other: AccountInfo) -> Bool {
        organizationUuid != nil && organizationUuid == other.organizationUuid
    }
}

struct TokenInfo: Decodable, Equatable {
    let hasTokens: Bool
    let subscriptionType: String?
    let refreshExpires: Date?

    func isRefreshExpired(now: Date = Date()) -> Bool {
        guard let refreshExpires else { return false }
        return refreshExpires <= now
    }

    var isUsable: Bool { hasTokens && !isRefreshExpired() }
}

struct UsageWindow: Decodable, Equatable {
    let name: String
    let percent: Double
    let resetsAt: Date?
    let resetsText: String?

    func hasReset(now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

struct Usage: Decodable, Equatable {
    let windows: [UsageWindow]
}

struct Profile: Decodable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let account: AccountInfo?
    let tokens: TokenInfo?
    let usage: Usage?
}

struct Status: Decodable {
    let current: AccountInfo?
    let active: String?
    let suggestedName: String?
    let liveTokens: TokenInfo?
    let pendingRetry: Date?
    let accounts: [Profile]

    func profile(_ name: String) -> Profile? {
        accounts.first { $0.name == name }
    }

    func exists(_ name: String) -> Bool {
        profile(name) != nil
    }
}

struct FallbackGroup: Decodable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let members: [String]
    let next: UUID?
}

struct AutoSwitchSettings: Decodable, Equatable {
    var groups: [FallbackGroup]

    func group(containing name: String) -> FallbackGroup? {
        groups.first { $0.members.contains(name) }
    }

    func group(_ id: UUID?) -> FallbackGroup? {
        groups.first { $0.id == id }
    }
}

struct AutoSwitchStatus: Decodable {
    let enabled: Bool
    let settings: AutoSwitchSettings
    let accounts: [Profile]
}

enum CLI {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let executable = ProcessInfo.processInfo.environment["SWAPBOT_CLI"]
        ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/swapbot").path

    @discardableResult
    static func run(_ arguments: [String], timeout: TimeInterval = 15) throws -> String {
        let result = Shell.run(executable, arguments, timeout: timeout)
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: message.isEmpty ? "swapbot \(arguments.joined(separator: " ")) failed" : message)
        }
        return result.stdout
    }

    static func decode<T: Decodable>(_ type: T.Type, _ arguments: [String]) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(run(arguments).utf8))
    }

    static func status(tokens: Bool = false) -> Status? {
        try? decode(Status.self, ["status", "--json"] + (tokens ? ["--tokens"] : []))
    }

    static func forward(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
