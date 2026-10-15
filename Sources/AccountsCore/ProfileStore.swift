import Foundation

public struct Paths: Sendable {
    public var service: String
    public var profileDir: URL
    public var claudeJSON: URL

    public init(service: String, profileDir: URL, claudeJSON: URL) {
        self.service = service
        self.profileDir = profileDir
        self.claudeJSON = claudeJSON
    }

    public static func live(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(
            service: env["SWAPBOT_SERVICE"] ?? "Claude Code-credentials",
            profileDir: env["SWAPBOT_PROFILE_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".claude/account-profiles"),
            claudeJSON: env["SWAPBOT_CLAUDE_JSON"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".claude.json")
        )
    }
}

public struct LoginFingerprint: Equatable, Sendable {
    let accountUuid: String?
    let organizationUuid: String?
    let email: String?
    let refreshTokenHash: Int?
}

public final class ProfileStore {
    public let paths: Paths
    let keychain: Keychain

    public init(paths: Paths = .live(), keychain: Keychain = Keychain()) {
        self.paths = paths
        self.keychain = keychain
    }

    public func profiles(includeTokens: Bool = true) -> [Profile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.profileDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasSuffix(".meta.json") }
            .map { String($0.lastPathComponent.dropLast(".meta.json".count)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                Profile(
                    name: name,
                    account: AccountInfo(readMeta(name)?["oauthAccount"]),
                    tokens: includeTokens ? snapshotOAuth(name).map(TokenInfo.init) : nil,
                    usage: readUsage(name)
                )
            }
    }

    public func currentAccount() -> AccountInfo? {
        AccountInfo((try? readClaudeJSON())?["oauthAccount"])
    }

    public func currentTokens() -> TokenInfo? {
        liveOAuth().map(TokenInfo.init)
    }

    public func activeProfile(in profiles: [Profile]? = nil) -> Profile? {
        guard let current = currentAccount() else { return nil }
        return (profiles ?? self.profiles(includeTokens: false)).first { $0.account?.sameLogin(as: current) == true }
    }

    public func fingerprint() -> LoginFingerprint {
        let account = currentAccount()
        return LoginFingerprint(
            accountUuid: account?.accountUuid,
            organizationUuid: account?.organizationUuid,
            email: account?.email,
            refreshTokenHash: (liveOAuth()?["refreshToken"] as? String).map { $0.hashValue }
        )
    }

    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: metaURL(name).path)
    }

    public func save(as name: String, replacing: Bool = false) throws {
        try Self.validate(name)
        if exists(name) && !replacing { throw AccountsError.alreadyExists(name) }
        try stash(name)
    }

    public func use(_ name: String) throws {
        guard exists(name) else { throw AccountsError.noSuchProfile(name) }
        guard let incoming = snapshotOAuth(name), TokenInfo(incoming).hasTokens else {
            throw AccountsError.emptySnapshot(name)
        }
        let all = profiles(includeTokens: false)
        if let outgoing = activeProfile(in: all) {
            if outgoing.name == name { return }
            try? stash(outgoing.name)
        }

        var live: [String: Any] = [:]
        if let raw = try keychain.read(paths.service) {
            guard let parsed = Self.parseObject(raw) else {
                throw AccountsError.keychain("the live Claude Code login isn't valid JSON, so it was left alone")
            }
            live = parsed
        }
        live["claudeAiOauth"] = incoming
        try keychain.write(paths.service, try Self.serialize(live))

        if let meta = readMeta(name) {
            try updateClaudeJSON { config in
                if let account = meta["oauthAccount"], !(account is NSNull) { config["oauthAccount"] = account }
                if let userID = meta["userID"], !(userID is NSNull) { config["userID"] = userID }
            }
        }
    }

    public func remove(_ name: String) throws {
        guard exists(name) else { throw AccountsError.noSuchProfile(name) }
        try keychain.delete(snapshotService(name))
        try FileManager.default.removeItem(at: metaURL(name))
        try? FileManager.default.removeItem(at: usageURL(name))
    }

    @discardableResult
    public func recordUsage(for name: String, fetch: () -> Usage? = { ClaudeCLI.usage() }) -> Usage? {
        guard exists(name), let usage = fetch() else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(usage) else { return nil }
        try? data.write(to: usageURL(name), options: .atomic)
        return usage
    }

    public func rename(_ name: String, to newName: String) throws {
        try Self.validate(newName)
        guard exists(name) else { throw AccountsError.noSuchProfile(name) }
        if newName == name { return }
        if exists(newName) { throw AccountsError.alreadyExists(newName) }
        if let snapshot = try keychain.read(snapshotService(name)) {
            try keychain.write(snapshotService(newName), snapshot)
        }
        try FileManager.default.moveItem(at: metaURL(name), to: metaURL(newName))
        try? FileManager.default.moveItem(at: usageURL(name), to: usageURL(newName))
        try keychain.delete(snapshotService(name))
    }

    public static func validate(_ name: String) throws {
        let ok = name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$"#, options: .regularExpression) != nil
        if !ok { throw AccountsError.invalidName(name) }
    }

    func stash(_ name: String) throws {
        guard let raw = try keychain.read(paths.service), let live = Self.parseObject(raw) else {
            throw AccountsError.noLiveLogin
        }
        guard let oauth = live["claudeAiOauth"] as? [String: Any], TokenInfo(oauth).hasTokens else {
            throw AccountsError.emptyLiveTokens
        }
        try keychain.write(snapshotService(name), try Self.serialize(["claudeAiOauth": oauth]))

        let config = (try? readClaudeJSON()) ?? [:]
        let meta: [String: Any] = [
            "oauthAccount": config["oauthAccount"] ?? NSNull(),
            "userID": config["userID"] ?? NSNull(),
        ]
        try FileManager.default.createDirectory(at: paths.profileDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: metaURL(name), options: .atomic)
    }

    func snapshotService(_ name: String) -> String { "\(paths.service):\(name)" }

    func metaURL(_ name: String) -> URL { paths.profileDir.appendingPathComponent("\(name).meta.json") }

    func usageURL(_ name: String) -> URL { paths.profileDir.appendingPathComponent("\(name).usage.json") }

    func readUsage(_ name: String) -> Usage? {
        guard let data = try? Data(contentsOf: usageURL(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Usage.self, from: data)
    }

    func readMeta(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: metaURL(name)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func snapshotOAuth(_ name: String) -> [String: Any]? {
        (try? keychain.read(snapshotService(name)))?.flatMap(Self.parseObject)?["claudeAiOauth"] as? [String: Any]
    }

    func liveOAuth() -> [String: Any]? {
        (try? keychain.read(paths.service))?.flatMap(Self.parseObject)?["claudeAiOauth"] as? [String: Any]
    }

    func readClaudeJSON() throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: paths.claudeJSON)
        } catch {
            throw AccountsError.config("couldn't read it (\(error.localizedDescription))")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AccountsError.config("it isn't a JSON object")
        }
        return object
    }

    func updateClaudeJSON(_ change: (inout [String: Any]) -> Void) throws {
        var config = try readClaudeJSON()
        change(&config)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes])
        do {
            try data.write(to: paths.claudeJSON, options: .atomic)
        } catch {
            throw AccountsError.config("couldn't write it (\(error.localizedDescription))")
        }
    }

    static func parseObject(_ raw: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
    }

    static func serialize(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
