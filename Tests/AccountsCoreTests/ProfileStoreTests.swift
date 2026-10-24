import Foundation
import Testing
@testable import AccountsCore

@Suite(.serialized)
final class ProfileStoreTests {
    let service = "SwapBotTest-\(UUID().uuidString)"
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SwapBotTest-\(UUID().uuidString)")
    let keychain = Keychain()
    let store: ProfileStore

    static let work = ["accountUuid": "acc-work", "organizationUuid": "org-work", "emailAddress": "me@work.example", "organizationName": "Work"]
    static let work2 = ["accountUuid": "acc-work2", "organizationUuid": "org-work", "emailAddress": "me2@work.example", "organizationName": "Work"]
    static let personal = ["accountUuid": "acc-me", "organizationUuid": "org-me", "emailAddress": "me@home.example", "organizationName": "Me"]

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ProfileStore(
            paths: Paths(service: service, profileDir: dir.appendingPathComponent("profiles"),
                         claudeJSON: dir.appendingPathComponent("claude.json"),
                         claudeSettings: dir.appendingPathComponent("settings.json")),
            keychain: keychain
        )
    }

    deinit {
        for suffix in ["", ":work", ":work2", ":personal", ":home", ":dead"] {
            try? keychain.delete(service + suffix)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    func login(_ account: [String: String], user: String, access: String, refresh: String, mcp: String = "mcp-token") throws {
        let live: [String: Any] = [
            "claudeAiOauth": ["accessToken": access, "refreshToken": refresh, "expiresAt": 1_900_000_000_000,
                              "refreshTokenExpiresAt": 1_900_000_000_000, "subscriptionType": "max"],
            "mcpOAuth": ["server": ["accessToken": mcp]],
        ]
        try keychain.write(service, try ProfileStore.serialize(live))
        var config = (try? store.readClaudeJSON()) ?? ["numStartups": 3, "projects": ["/tmp": ["allowedTools": []]]]
        config["oauthAccount"] = account
        config["userID"] = user
        try JSONSerialization.data(withJSONObject: config).write(to: store.paths.claudeJSON)
    }

    func live() -> [String: Any] {
        ProfileStore.parseObject(try! keychain.read(service)!)!
    }

    @Test func saveAndSwitchRoundTrip() throws {
        try login(Self.work, user: "u-work", access: "a-work", refresh: "r-work")
        try store.save(as: "work")
        try login(Self.personal, user: "u-me", access: "a-me", refresh: "r-me", mcp: "mcp-latest")
        try store.save(as: "personal")

        #expect(store.profiles().map(\.name) == ["personal", "work"])
        #expect(store.activeProfile()?.name == "personal")

        try store.use("work")
        let oauth = live()["claudeAiOauth"] as! [String: Any]
        #expect(oauth["accessToken"] as? String == "a-work")
        #expect(oauth["refreshToken"] as? String == "r-work")
        #expect((live()["mcpOAuth"] as? [String: [String: String]])?["server"]?["accessToken"] == "mcp-latest")
        let config = try store.readClaudeJSON()
        #expect((config["oauthAccount"] as? [String: String])?["emailAddress"] == "me@work.example")
        #expect(config["userID"] as? String == "u-work")
        #expect(config["numStartups"] as? Int == 3)
        #expect(config["projects"] != nil)
        #expect(store.activeProfile()?.name == "work")
    }

    @Test func switchingResavesRotatedTokensOfOutgoingAccount() throws {
        try login(Self.work, user: "u-work", access: "a-work", refresh: "r-work")
        try store.save(as: "work")
        try login(Self.personal, user: "u-me", access: "a-me", refresh: "r-me")
        try store.save(as: "personal")
        try login(Self.personal, user: "u-me", access: "a-me-2", refresh: "r-me-2")

        try store.use("work")
        try store.use("personal")
        #expect((live()["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String == "r-me-2")
    }

    @Test func emptyLiveTokensNeverClobberASnapshot() throws {
        try login(Self.work, user: "u-work", access: "a-work", refresh: "r-work")
        try store.save(as: "work")
        try login(Self.work, user: "u-work", access: "", refresh: "")

        #expect(throws: AccountsError.emptyLiveTokens) { try store.save(as: "work", replacing: true) }
        #expect(store.snapshotOAuth("work")?["refreshToken"] as? String == "r-work")
    }

    @Test func refusesEmptySnapshotsAndDuplicates() throws {
        try login(Self.work, user: "u-work", access: "a-work", refresh: "r-work")
        try store.save(as: "work")
        #expect(throws: AccountsError.alreadyExists("work")) { try store.save(as: "work") }
        #expect(throws: AccountsError.invalidName("bad name")) { try store.save(as: "bad name") }
        #expect(throws: AccountsError.noSuchProfile("nope")) { try store.use("nope") }

        try keychain.write(store.snapshotService("work"), #"{"claudeAiOauth":{"accessToken":"","refreshToken":""}}"#)
        try login(Self.personal, user: "u-me", access: "a-me", refresh: "r-me")
        #expect(throws: AccountsError.emptySnapshot("work")) { try store.use("work") }
        #expect((live()["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "a-me")
    }

    @Test func renameAndRemove() throws {
        try login(Self.personal, user: "u-me", access: "a-me", refresh: "r-me")
        try store.save(as: "personal")
        try store.rename("personal", to: "home")

        #expect(store.profiles().map(\.name) == ["home"])
        #expect(try keychain.read(store.snapshotService("personal")) == nil)
        #expect(store.profiles().first?.tokens?.hasTokens == true)
        #expect(store.activeProfile()?.name == "home")

        try store.remove("home")
        #expect(store.profiles().isEmpty)
        #expect(try keychain.read(store.snapshotService("home")) == nil)
        #expect((live()["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "a-me")
    }

    @Test func fingerprintChangesOnNewLoginEvenForSameAccount() throws {
        try login(Self.work, user: "u-work", access: "a-work", refresh: "r-work")
        let before = store.fingerprint()
        #expect(store.fingerprint() == before)
        try login(Self.work, user: "u-work", access: "a-work-2", refresh: "r-work-2")
        #expect(store.fingerprint() != before)
    }

    @Test func largeBlobsRoundTripThroughKeychain() throws {
        let big = String(repeating: "x", count: 20_000)
        try login(Self.work, user: "u-work", access: big, refresh: "r", mcp: big)
        try store.save(as: "work")
        #expect(store.snapshotOAuth("work")?["accessToken"] as? String == big)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWAPBOT_ROUNDTRIP"] != nil))
func roundTripRealConfigCopy() throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWAPBOT_ROUNDTRIP"]!)
    let store = ProfileStore(paths: Paths(service: "unused", profileDir: url.deletingLastPathComponent(), claudeJSON: url,
                                          claudeSettings: url.deletingLastPathComponent().appendingPathComponent("settings.json")))
    func canonical() throws -> Data {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    let before = try canonical()
    try store.updateClaudeJSON { _ in }
    #expect(try canonical() == before)
}

@Test func terminateStopsProcessesThatIgnoreSIGTERM() throws {
    func spawn(_ script: String) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        return p.processIdentifier
    }
    let polite = try spawn("exec sleep 60")
    let stubborn = try spawn("trap '' TERM; while :; do sleep 0.1; done")
    usleep(200_000)
    #expect(Processes.isRunning(polite) && Processes.isRunning(stubborn))
    let survivors = Processes.terminate([polite, stubborn], grace: 1)
    #expect(survivors.isEmpty)
    #expect(!Processes.isRunning(polite) && !Processes.isRunning(stubborn))
}

extension ProfileStoreTests {
    @Test func recordsUsageForAnAccountAndKeepsItThroughRename() throws {
        try login(Self.work, user: "u-work", access: "a-work", refresh: "r-work")
        try store.save(as: "work")
        let recorded = store.recordUsage(for: "work") {
            Usage(windows: [UsageWindow(name: "Session", percent: 73), UsageWindow(name: "Week", percent: 91)])
        }
        #expect(recorded?.windows.first?.percent == 73)
        #expect(store.profiles().first?.usage?.windows.last?.percent == 91)

        try store.rename("work", to: "job")
        #expect(store.profiles().first?.usage?.windows.first?.percent == 73)
        try store.remove("job")
        #expect(!FileManager.default.fileExists(atPath: store.usageURL("job").path))
    }

    @Test func failedUsageFetchRecordsNothing() throws {
        try login(Self.work, user: "u-work", access: "a-work", refresh: "r-work")
        try store.save(as: "work")
        #expect(store.recordUsage(for: "work") { nil } == nil)
        #expect(store.profiles().first?.usage == nil)
    }

    @Test func unreadableLiveLoginIsNeverOverwritten() throws {
        try login(Self.work, user: "u-work", access: "a-work", refresh: "r-work")
        try store.save(as: "work")
        try login(Self.personal, user: "u-me", access: "a-me", refresh: "r-me")
        try keychain.write(service, "not json")
        #expect(throws: AccountsError.self) { try store.use("work") }
        #expect(try keychain.read(service) == "not json")
    }
}

@Test func parsesClaudeUsageOutput() throws {
    let output = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 92% used · resets Oct 15 at 11:20pm (Europe/London)
    Current week (Fable): 0% used · resets Oct 18 at 10am (Europe/London)

    What's contributing to your limits usage?
    Last 24h · 13512 requests · 18 sessions
      95% of your usage was at >150k context
    """
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-15T21:00:00Z"))
    let usage = try #require(Usage(claudeOutput: output, now: now))
    #expect(usage.windows.map(\.name) == ["Session", "Week (Fable)"])
    #expect(usage.windows.map(\.percent) == [92, 0])
    #expect(usage.windows.map(\.resetsText) == ["Oct 15 at 11:20pm", "Oct 18 at 10am"])
    #expect(usage.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-10-15T22:20:00Z"))
    #expect(usage.windows[1].resetsAt == ISO8601DateFormatter().date(from: "2026-10-18T09:00:00Z"))
    #expect(Usage(claudeOutput: "Unknown command: /usage") == nil)
}

@Test func onlyAccountsInTheSameOrganizationSharePromptCache() throws {
    let alice = try #require(AccountInfo(["accountUuid": "a", "organizationUuid": "team"]))
    let bob = try #require(AccountInfo(["accountUuid": "b", "organizationUuid": "team"]))
    let personal = try #require(AccountInfo(["accountUuid": "a", "organizationUuid": "solo"]))
    let unknown = try #require(AccountInfo(["accountUuid": "c"]))
    #expect(alice.sharesPromptCache(with: bob))
    #expect(!alice.sharesPromptCache(with: personal))
    #expect(!unknown.sharesPromptCache(with: AccountInfo(["accountUuid": "d"])!))
}

@Test func usageResetsInJanuaryRollIntoNextYear() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-12-30T12:00:00Z"))
    let date = try #require(Usage.parseReset("Jan 2 at 9am (Europe/London)", now: now))
    #expect(date == ISO8601DateFormatter().date(from: "2027-01-02T09:00:00Z"))
}

@Test func shellGivesUpOnHungCommands() {
    let start = Date()
    let result = Shell.run("/bin/sleep", ["30"], timeout: 0.5)
    #expect(result.timedOut)
    #expect(Date().timeIntervalSince(start) < 3)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWAPBOT_LIVE_USAGE"] != nil))
func readsUsageFromClaude() throws {
    let usage = try #require(ClaudeCLI.usage())
    print("live usage: " + usage.windows.map { "\($0.name) \($0.percent)% resets \($0.resetsText ?? "?")" }.joined(separator: " | "))
}

extension ProfileStoreTests {
    func saveAccounts() throws {
        try login(Self.work2, user: "u-work2", access: "a-work2", refresh: "r-work2")
        try store.save(as: "work2")
        try login(Self.personal, user: "u-me", access: "a-me", refresh: "r-me")
        try store.save(as: "personal")
        try login(Self.work, user: "u-work", access: "a-work", refresh: "r-work")
        try store.save(as: "work")
    }

    @Test func usageLimitSwitchesToTheLeastUsedAccountInTheGroup() throws {
        try saveAccounts()
        let autoSwitch = AutoSwitch(store: store)
        try autoSwitch.save(AutoSwitchSettings(groups: [FallbackGroup(name: "Work", members: ["work", "work2"])]))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-17T11:15:00Z"))

        let outcome = autoSwitch.handleLimit(message: "You've hit your session limit · resets 3:20pm (Europe/London)", now: now)
        #expect(outcome == .switched(from: "work", to: "work2"))
        #expect(store.activeProfile()?.name == "work2")
        let session = store.profiles().first { $0.name == "work" }?.usage?.windows.first
        #expect(session?.percent == 100)
        #expect(session?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-17T14:20:00Z"))

        let again = autoSwitch.handleLimit(message: "You've hit your session limit · resets 3:20pm (Europe/London)",
                                           now: now.addingTimeInterval(5))
        #expect(again == .ignored("switched 5s ago"))
        #expect(store.activeProfile()?.name == "work2")
        #expect(store.profiles().first { $0.name == "work2" }?.usage == nil)
    }

    @Test func usageLimitMovesToTheNextGroupOnlyWhenTheGroupIsUsedUp() throws {
        try saveAccounts()
        let autoSwitch = AutoSwitch(store: store)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-17T11:15:00Z"))
        try autoSwitch.save(AutoSwitchSettings(groups: [FallbackGroup(name: "Home", members: ["personal"])]))
        #expect(autoSwitch.handleLimit(message: "You've hit your session limit · resets 3:20pm", now: now)
            == .ignored("“work” hit its session limit; it isn't in a fallback group"))

        let home = FallbackGroup(name: "Home", members: ["personal"])
        try autoSwitch.save(AutoSwitchSettings(groups: [FallbackGroup(name: "Work", members: ["work", "work2"]), home]))
        store.recordUsage(for: "work2") { Usage(windows: [UsageWindow(name: "Week", percent: 100, resetsAt: now.addingTimeInterval(3600))]) }
        #expect(autoSwitch.handleLimit(message: "You've hit your weekly limit · resets Oct 25 at 6pm", now: now)
            == .waiting("“work” hit its week limit and everything it can switch to is used up", until: now.addingTimeInterval(3600)))

        try autoSwitch.save(AutoSwitchSettings(groups: [FallbackGroup(name: "Work", members: ["work", "work2"], next: home.id), home]))
        #expect(autoSwitch.handleLimit(message: "You've hit your weekly limit", now: now) == .switched(from: "work", to: "personal"))
    }

    @Test func serverRateLimitsDontCount() throws {
        try saveAccounts()
        let autoSwitch = AutoSwitch(store: store)
        try autoSwitch.save(AutoSwitchSettings(groups: [FallbackGroup(name: "All", members: ["work", "work2", "personal"])]))
        #expect(autoSwitch.handleLimit(message: "API Error: Rate limit reached") == .ignored("not a usage limit: API Error: Rate limit reached"))
        #expect(store.activeProfile()?.name == "work")
    }

    @Test func fallbackSkipsUsedUpAndExpiredAccountsAndStopsAtLoops() throws {
        let now = Date()
        func profile(_ name: String, percent: Double?, resetsAt: Date? = nil, expired: Bool = false) -> Profile {
            let expiry = (expired ? now.addingTimeInterval(-60) : now.addingTimeInterval(86_400)).timeIntervalSince1970 * 1000
            return Profile(
                name: name,
                account: AccountInfo(["accountUuid": name, "organizationUuid": "org"]),
                tokens: TokenInfo(["accessToken": "a", "refreshToken": "r", "refreshTokenExpiresAt": expiry]),
                usage: percent.map { Usage(windows: [UsageWindow(name: "Session", percent: $0, resetsAt: resetsAt)]) }
            )
        }
        let active = profile("a", percent: 100)
        let profiles = [
            active,
            profile("b", percent: 40),
            profile("c", percent: 100, resetsAt: now.addingTimeInterval(-60)),
            profile("d", percent: 0, expired: true),
            profile("e", percent: nil),
            profile("f", percent: 100, resetsAt: now.addingTimeInterval(3600)),
        ]
        var first = FallbackGroup(name: "First", members: ["a", "b", "c", "d"])
        var second = FallbackGroup(name: "Second", members: ["e", "f"])
        #expect(AutoSwitch.fallback(from: active, in: profiles, settings: AutoSwitchSettings(groups: [first, second]), now: now)?.name == "c")

        first.members = ["a", "d", "f"]
        #expect(AutoSwitch.fallback(from: active, in: profiles, settings: AutoSwitchSettings(groups: [first, second]), now: now) == nil)
        first.next = second.id
        second.next = first.id
        #expect(AutoSwitch.fallback(from: active, in: profiles, settings: AutoSwitchSettings(groups: [first, second]), now: now)?.name == "e")
        second.members = ["f"]
        #expect(AutoSwitch.fallback(from: active, in: profiles, settings: AutoSwitchSettings(groups: [first, second]), now: now) == nil)
        #expect(AutoSwitch.fallback(from: profile("z", percent: 100), in: profiles, settings: AutoSwitchSettings(groups: [first, second]), now: now) == nil)
    }

    @Test func defaultGroupsFollowOrganizationsAndTrackRenamesAndRemovals() throws {
        try saveAccounts()
        let autoSwitch = AutoSwitch(store: store)
        let defaults = autoSwitch.settings()
        #expect(defaults.groups.map(\.name) == ["Me", "Work"])
        #expect(defaults.groups.map(\.members) == [["personal"], ["work", "work2"]])

        try autoSwitch.save(defaults)
        try store.rename("work2", to: "home")
        #expect(autoSwitch.settings().group(containing: "home")?.name == "Work")
        try store.remove("home")
        #expect(autoSwitch.settings().groups.map(\.members) == [["personal"], ["work"]])

        var settings = autoSwitch.settings()
        let work = try #require(settings.group(containing: "work"))
        settings.groups[0].next = work.id
        settings.move("personal", to: work.id)
        settings.remove(group: work.id)
        #expect(settings.groups.count == 1)
        #expect(settings.groups[0].next == nil)
        #expect(settings.group(containing: "personal") == nil)
    }

    @Test func importsUsageClaudeCodeCachedForTheMatchingAccount() throws {
        try saveAccounts()
        var config = try store.readClaudeJSON()
        config["cachedUsageUtilization"] = [
            "accountUuid": "acc-me",
            "fetchedAtMs": 1_792_796_588_055,
            "utilization": [
                "five_hour": ["utilization": 77, "resets_at": "2026-10-24T01:39:59.896789+00:00"],
                "seven_day": ["utilization": 84, "resets_at": "2026-10-25T17:59:59.896807+00:00"],
                "seven_day_opus": NSNull(),
            ],
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: store.paths.claudeJSON)

        #expect(store.importCachedUsage() == "personal")
        let usage = try #require(store.profiles().first { $0.name == "personal" }?.usage)
        #expect(usage.windows.map(\.name) == ["Session", "Week"])
        #expect(usage.windows.map(\.percent) == [77, 84])
        #expect(usage.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-10-24T01:39:59Z"))
        #expect(store.importCachedUsage() == nil)
    }

    @Test func hookInstallKeepsOtherHooksAndRemovesOnlyItsOwn() throws {
        let hooks = ClaudeHooks(settingsURL: store.paths.claudeSettings)
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "say done"]]]],
                "StopFailure": [["matcher": "rate_limit", "hooks": [["type": "command", "command": "say limited"]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: store.paths.claudeSettings)

        try hooks.install(executable: "/Applications/SwapBot.app/Contents/MacOS/SwapBot")
        try hooks.install(executable: "/Users/me/Applications/SwapBot.app/Contents/MacOS/SwapBot")
        #expect(hooks.installedCommand() == "'/Users/me/Applications/SwapBot.app/Contents/MacOS/SwapBot' --limit-reached")
        var stopFailure = (try hooks.read()["hooks"] as? [String: Any])?["StopFailure"] as? [[String: Any]]
        #expect(stopFailure?.count == 2)

        try hooks.uninstall()
        #expect(hooks.installedCommand() == nil)
        let settings = try hooks.read()
        stopFailure = (settings["hooks"] as? [String: Any])?["StopFailure"] as? [[String: Any]]
        #expect(stopFailure?.count == 1)
        #expect((settings["hooks"] as? [String: Any])?["Stop"] != nil)
        #expect(settings["model"] as? String == "opus")
    }

    @Test func hookInstallLeavesInvalidSettingsAlone() throws {
        try Data("{ not json".utf8).write(to: store.paths.claudeSettings)
        let hooks = ClaudeHooks(settingsURL: store.paths.claudeSettings)
        #expect(throws: AccountsError.self) { try hooks.install(executable: "/Applications/SwapBot.app/Contents/MacOS/SwapBot") }
        #expect(try String(contentsOf: store.paths.claudeSettings, encoding: .utf8) == "{ not json")
    }
}

extension ProfileStoreTests {
    func exhaust(_ name: String, until date: Date) {
        store.recordUsage(for: name) { Usage(windows: [UsageWindow(name: "Session", percent: 100, resetsAt: date)]) }
    }

    @Test func waitsForTheEarliestResetInTheChainThenSwitches() throws {
        try saveAccounts()
        let autoSwitch = AutoSwitch(store: store)
        let home = FallbackGroup(name: "Home", members: ["personal"])
        try autoSwitch.save(AutoSwitchSettings(groups: [FallbackGroup(name: "Work", members: ["work", "work2"], next: home.id), home]))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-17T11:15:00Z"))
        exhaust("work2", until: now.addingTimeInterval(2 * 3600))
        exhaust("personal", until: now.addingTimeInterval(3600))

        let outcome = autoSwitch.handleLimit(message: "You've hit your session limit · resets 3:20pm (Europe/London)", now: now)
        #expect(outcome == .waiting("“work” hit its session limit and everything it can switch to is used up",
                                    until: now.addingTimeInterval(3600)))
        #expect(autoSwitch.pendingRetry() == now.addingTimeInterval(3600))
        #expect(store.activeProfile()?.name == "work")

        #expect(autoSwitch.retry(now: now.addingTimeInterval(3601)) == .switched(from: "work", to: "personal"))
        #expect(autoSwitch.pendingRetry() == nil)
    }

    @Test func doesntWaitWhenTheCurrentAccountResetsFirst() throws {
        try saveAccounts()
        let autoSwitch = AutoSwitch(store: store)
        try autoSwitch.save(AutoSwitchSettings(groups: [FallbackGroup(name: "Work", members: ["work", "work2"])]))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-17T11:15:00Z"))
        exhaust("work2", until: now.addingTimeInterval(5 * 3600))

        let outcome = autoSwitch.handleLimit(message: "You've hit your session limit · resets 3:20pm (Europe/London)", now: now)
        #expect(outcome == .ignored("“work” hit its session limit; nothing it can switch to resets before it does"))
        #expect(autoSwitch.pendingRetry() == nil)
    }

    @Test func retryLeavesAnAccountThatHasUsageAgain() throws {
        try saveAccounts()
        let autoSwitch = AutoSwitch(store: store)
        try autoSwitch.save(AutoSwitchSettings(groups: [FallbackGroup(name: "Work", members: ["work", "work2"])]))
        let now = Date()
        exhaust("work", until: now.addingTimeInterval(-60))
        autoSwitch.writeState(AutoSwitchState(retryAt: now))

        #expect(autoSwitch.retry(now: now) == .ignored("“work” has usage again, so it stays"))
        #expect(autoSwitch.pendingRetry() == nil)
        #expect(store.activeProfile()?.name == "work")
    }
}
