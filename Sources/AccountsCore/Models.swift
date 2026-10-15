import Foundation

public enum AccountsError: LocalizedError, Equatable {
    case invalidName(String)
    case alreadyExists(String)
    case noSuchProfile(String)
    case noLiveLogin
    case emptyLiveTokens
    case emptySnapshot(String)
    case keychain(String)
    case config(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let n):
            "“\(n)” isn't a valid name. Use letters, numbers, dots, dashes or underscores."
        case .alreadyExists(let n):
            "There's already an account called “\(n)”."
        case .noSuchProfile(let n):
            "No saved account called “\(n)”."
        case .noLiveLogin:
            "Claude Code isn't logged in, so there's nothing to save."
        case .emptyLiveTokens:
            "The current Claude Code login has empty tokens. Log in again before saving it."
        case .emptySnapshot(let n):
            "The saved login for “\(n)” has empty tokens. Use “Log In Again” to refresh it."
        case .keychain(let m):
            "Keychain error: \(m)"
        case .config(let m):
            "~/.claude.json: \(m)"
        }
    }
}

public struct AccountInfo: Equatable, Sendable {
    public let accountUuid: String?
    public let organizationUuid: String?
    public let email: String?
    public let organizationName: String?
    public let displayName: String?

    public init?(_ json: Any?) {
        guard let d = json as? [String: Any] else { return nil }
        accountUuid = d["accountUuid"] as? String
        organizationUuid = d["organizationUuid"] as? String
        email = d["emailAddress"] as? String
        organizationName = d["organizationName"] as? String
        displayName = d["displayName"] as? String
        if accountUuid == nil && email == nil { return nil }
    }

    public func sameLogin(as other: AccountInfo) -> Bool {
        if let a = accountUuid, let b = other.accountUuid {
            return a == b && organizationUuid == other.organizationUuid
        }
        return email != nil && email == other.email
    }
}

public struct TokenInfo: Equatable, Sendable {
    public let hasTokens: Bool
    public let subscriptionType: String?
    public let accessExpires: Date?
    public let refreshExpires: Date?

    init(_ oauth: [String: Any]) {
        hasTokens = Self.nonEmpty(oauth["accessToken"]) && Self.nonEmpty(oauth["refreshToken"])
        subscriptionType = oauth["subscriptionType"] as? String
        accessExpires = Self.date(oauth["expiresAt"])
        refreshExpires = Self.date(oauth["refreshTokenExpiresAt"])
    }

    public func isRefreshExpired(now: Date = Date()) -> Bool {
        guard let refreshExpires else { return false }
        return refreshExpires <= now
    }

    static func nonEmpty(_ v: Any?) -> Bool {
        guard let s = v as? String else { return false }
        return !s.isEmpty
    }

    static func date(_ v: Any?) -> Date? {
        guard let ms = (v as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

public struct Profile: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let account: AccountInfo?
    public let tokens: TokenInfo?
    public let usage: Usage?
}
