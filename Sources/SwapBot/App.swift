import AppKit
import AccountsCore
import ServiceManagement

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static var shared: AppDelegate?

    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--launch-at-login"), i + 1 < CommandLine.arguments.count {
            do {
                if CommandLine.arguments[i + 1] == "on" {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("launch at login: \(error.localizedDescription)")
            }
            print("launch at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
            return
        }
        if CommandLine.arguments.contains("--dump") {
            dump(ProfileStore())
            return
        }
        if CommandLine.arguments.contains("--list") {
            list(ProfileStore())
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--switch"), i + 1 < CommandLine.arguments.count {
            exit(switchAccount(ProfileStore(), to: CommandLine.arguments[i + 1],
                               quitSessions: CommandLine.arguments.contains("--quit-sessions")))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-app-icon"), i + 1 < CommandLine.arguments.count {
            RobotIcon.writeAppIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-icons"), i + 1 < CommandLine.arguments.count {
            renderIcons(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        if CommandLine.arguments.contains("--dump-menu") {
            let menu = NSMenu()
            let delegate = AppDelegate()
            delegate.menuNeedsUpdate(menu)
            withExtendedLifetime(delegate) { printMenu(menu) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let store = ProfileStore()
    var statusItem: NSStatusItem!
    private var timer: Timer?
    private var lastConfigChange: Date?
    private var pendingLogin: PendingLogin?
    private var isBusy = false

    private struct PendingLogin {
        let before: LoginFingerprint
        let relogin: String?
        let started: Date
    }

    private var showsName: Bool {
        get { !UserDefaults.standard.bool(forKey: "hideNameInMenuBar") }
        set { UserDefaults.standard.set(!newValue, forKey: "hideNameInMenuBar") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateLabel()

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { AppDelegate.shared?.tick() }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--screenshot"), i + 1 < CommandLine.arguments.count {
            captureMenu(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }

    private func tick() {
        let modified = (try? store.paths.claudeJSON.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if modified != lastConfigChange {
            lastConfigChange = modified
            updateLabel()
        }
        guard let pending = pendingLogin else { return }
        if Date().timeIntervalSince(pending.started) > 15 * 60 {
            pendingLogin = nil
        } else if store.fingerprint() != pending.before {
            pendingLogin = nil
            loginFinished(pending)
        }
    }

    private func updateLabel() {
        guard let button = statusItem?.button else { return }
        let current = store.currentAccount()
        let active = store.activeProfile()
        let badge: RobotIcon.Badge?
        let title: String
        if current == nil {
            badge = .xmark
            title = "signed out"
        } else if let active {
            badge = nil
            title = active.name
        } else {
            badge = .questionmark
            title = current?.email?.components(separatedBy: "@").first ?? "unsaved"
        }
        button.image = RobotIcon.image(badge: badge)
        button.imagePosition = .imageLeading
        button.title = showsName ? " \(title)" : ""
        button.toolTip = "Claude Code: \(current?.email ?? "signed out")"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let profiles = store.profiles()
        let current = store.currentAccount()
        let active = store.activeProfile(in: profiles)
        let liveTokens = store.currentTokens()

        let header: String
        if let current {
            header = "Signed in as \(current.email ?? "unknown")" + (active == nil ? " (not saved)" : "")
        } else {
            header = "Claude Code is signed out"
        }
        menu.addItem(disabled(header))
        menu.addItem(.separator())

        if profiles.isEmpty {
            menu.addItem(disabled("No saved accounts"))
        }
        for (index, profile) in profiles.enumerated() {
            let isActive = profile.name == active?.name
            let item = NSMenuItem(title: profile.name, action: #selector(switchAccount(_:)),
                                  keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.target = self
            item.representedObject = profile.name
            item.state = isActive ? .on : .off
            item.attributedTitle = accountTitle(profile, tokens: isActive ? liveTokens : profile.tokens)
            item.toolTip = usageTooltip(profile.usage, isActive: isActive)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        if current != nil && active == nil {
            menu.addItem(action("Save Current Login…", #selector(saveCurrent)))
        }
        menu.addItem(action("Add Account…", #selector(addAccount)))
        if !profiles.isEmpty {
            let manage = NSMenuItem(title: "Manage Accounts", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for profile in profiles {
                let entry = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
                let actions = NSMenu()
                actions.addItem(action("Log In Again…", #selector(reloginAccount(_:)), profile.name))
                actions.addItem(action("Rename…", #selector(renameAccount(_:)), profile.name))
                actions.addItem(.separator())
                actions.addItem(action("Remove…", #selector(removeAccount(_:)), profile.name))
                entry.submenu = actions
                sub.addItem(entry)
            }
            manage.submenu = sub
            menu.addItem(manage)
        }

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()
        let login = action("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        settingsMenu.addItem(login)
        let name = action("Show Account Name in Menu Bar", #selector(toggleShowName))
        name.state = showsName ? .on : .off
        settingsMenu.addItem(name)
        let awake = action("Stay Awake with Lid Closed", #selector(toggleSleepDisabled))
        awake.state = Power.sleepDisabled ? .on : .off
        awake.toolTip = "Stops the Mac sleeping at all, even with the lid closed or after SwapBot quits, until you turn this off. Needs an administrator password."
        settingsMenu.addItem(awake)
        settings.submenu = settingsMenu
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SwapBot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func accountTitle(_ profile: Profile, tokens: TokenInfo?) -> NSAttributedString {
        var details = [profile.account?.email ?? "unknown account"]
        if let plan = tokens?.subscriptionType, !plan.isEmpty {
            details.append(plan.prefix(1).uppercased() + plan.dropFirst())
        }
        var warning: (text: String, color: NSColor)?
        if let tokens, tokens.hasTokens {
            if tokens.isRefreshExpired() {
                warning = ("⚠︎ login expired", .systemRed)
            } else if let expires = tokens.refreshExpires {
                let days = Int(expires.timeIntervalSinceNow / 86_400)
                if days < 7 {
                    warning = ("⚠︎ login expires in \(days == 0 ? "under a day" : "\(days) day\(days == 1 ? "" : "s")")", .systemOrange)
                }
            }
        } else {
            warning = ("⚠︎ needs logging in again", .systemRed)
        }

        let small = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let title = NSMutableAttributedString(string: profile.name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: "\n" + details.joined(separator: " · "),
                                        attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        if let warning {
            title.append(NSAttributedString(string: "\n" + warning.text,
                                            attributes: [.font: small, .foregroundColor: warning.color]))
        }
        return title
    }

    private func usageTooltip(_ usage: Usage?, isActive: Bool) -> String {
        if isActive { return "Usage is recorded when you switch away from this account." }
        guard let usage, !usage.windows.isEmpty else {
            return "No usage yet. It's recorded when you switch away from this account."
        }
        return usage.windows.map { window in
            if window.hasReset() { return "\(window.name) has reset" }
            let percent = "\(window.name) \(Int(window.percent.rounded()))%"
            if let resetsAt = window.resetsAt { return "\(percent) · resets \(describeReset(resetsAt))" }
            if let text = window.resetsText { return "\(percent) · resets \(text)" }
            return percent
        }.joined(separator: "\n")
    }

    private func describeReset(_ date: Date) -> String {
        let minutes = Int(date.timeIntervalSinceNow / 60)
        if minutes < 60 { return "in \(max(minutes, 1))m" }
        if minutes < 24 * 60 { return "in \(minutes / 60)h \(minutes % 60)m" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        return formatter.string(from: date)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, _ object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard !isBusy, let name = sender.representedObject as? String else { return }
        guard store.activeProfile()?.name != name else { return }
        let profile = store.profiles().first { $0.name == name }
        guard let tokens = profile?.tokens, tokens.hasTokens, !tokens.isRefreshExpired() else {
            if Prompts.confirm("The saved login for “\(name)” has expired",
                               "Log in as \(profile?.account?.email ?? name) again to keep using it.",
                               confirm: "Log In Again…") {
                startLogin(relogin: name)
            }
            return
        }
        guard quitSessions(before: "switching to “\(name)”") else { return }
        recordOutgoingUsage { [self] in
            do {
                try store.use(name)
            } catch {
                Prompts.error(error, title: "Couldn't switch to “\(name)”")
            }
            updateLabel()
        }
    }

    private func recordOutgoingUsage(then next: @escaping @MainActor () -> Void) {
        guard let outgoing = store.activeProfile()?.name else {
            next()
            return
        }
        isBusy = true
        statusItem.button?.appearsDisabled = true
        Task { @MainActor in
            let usage = await Task.detached { ClaudeCLI.usage() }.value
            if let usage { store.recordUsage(for: outgoing) { usage } }
            isBusy = false
            statusItem.button?.appearsDisabled = false
            next()
        }
    }

    @objc private func saveCurrent() {
        let suggestion = suggestedName(for: store.currentAccount())
        guard let name = Prompts.name(
            "Save Current Login",
            "Name the account signed in as \(store.currentAccount()?.email ?? "unknown").",
            initial: suggestion, confirm: "Save",
            check: { store.exists($0) ? "There's already an account called “\($0)”." : nil }
        ) else { return }
        do {
            try store.save(as: name)
        } catch {
            Prompts.error(error, title: "Couldn't save the login")
        }
        updateLabel()
    }

    @objc private func addAccount() {
        startLogin(relogin: nil)
    }

    @objc private func reloginAccount(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        startLogin(relogin: name)
    }

    @objc private func renameAccount(_ sender: NSMenuItem) {
        guard !isBusy, let name = sender.representedObject as? String,
              let newName = Prompts.name(
                "Rename “\(name)”", "Choose a new name.", initial: name, confirm: "Rename",
                check: { $0 != name && store.exists($0) ? "There's already an account called “\($0)”." : nil }
              ) else { return }
        do {
            try store.rename(name, to: newName)
        } catch {
            Prompts.error(error, title: "Couldn't rename “\(name)”")
        }
        updateLabel()
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard !isBusy, let name = sender.representedObject as? String else { return }
        let isActive = store.activeProfile()?.name == name
        let detail = "This deletes its saved login from the Keychain."
            + (isActive ? " It's the account in use now: Claude Code stays signed in to it, but you can't switch back to it later." : "")
        guard Prompts.confirm("Remove “\(name)”?", detail, confirm: "Remove", destructive: true) else { return }
        do {
            try store.remove(name)
        } catch {
            Prompts.error(error, title: "Couldn't remove “\(name)”")
        }
        updateLabel()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Prompts.error(error, title: "Couldn't change Launch at Login")
        }
    }

    @objc private func toggleSleepDisabled() {
        do {
            try Power.setSleepDisabled(!Power.sleepDisabled)
        } catch {
            Prompts.error(error, title: "Couldn't change Stay Awake with Lid Closed")
        }
    }

    @objc private func toggleShowName() {
        showsName.toggle()
        updateLabel()
    }

    private func startLogin(relogin: String?) {
        guard !isBusy, quitSessions(before: relogin == nil ? "adding an account" : "logging in again") else { return }
        recordOutgoingUsage { [self] in openLogin(relogin: relogin) }
    }

    private func openLogin(relogin: String?) {
        let email = relogin.flatMap { name in store.profiles(includeTokens: false).first { $0.name == name }?.account?.email }
        var command = "claude auth login"
        if let email { command += " --email \(Sessions.shellQuote(email))" }

        if let active = store.activeProfile() {
            try? store.save(as: active.name, replacing: true)
        }
        let before = store.fingerprint()
        do {
            try Sessions.openInTerminal(name: "login", """
            \(command)
            echo
            echo "SwapBot will pick up the new login. You can close this window."
            """)
            pendingLogin = PendingLogin(before: before, relogin: relogin, started: Date())
        } catch {
            Prompts.error(error, title: "Couldn't open Terminal")
        }
    }

    private func loginFinished(_ pending: PendingLogin) {
        updateLabel()
        guard let current = store.currentAccount() else { return }
        let email = current.email ?? "unknown"

        if let match = store.profiles(includeTokens: false).first(where: { $0.account?.sameLogin(as: current) == true }) {
            do {
                try store.save(as: match.name, replacing: true)
                var detail = "Signed in as \(email). Its saved login is up to date."
                if let wanted = pending.relogin, wanted != match.name {
                    detail = "You signed in as \(email), which is saved as “\(match.name)”, not “\(wanted)”. Updated “\(match.name)”."
                }
                Prompts.info("“\(match.name)” is ready", detail)
            } catch {
                Prompts.error(error, title: "Couldn't save the new login")
            }
            updateLabel()
            return
        }

        guard let name = Prompts.name(
            "New Login: \(email)",
            "Name this account" + (current.organizationName.map { " (\($0))" } ?? "") + ".",
            initial: suggestedName(for: current), confirm: "Save",
            check: { store.exists($0) ? "There's already an account called “\($0)”." : nil }
        ) else { return }
        do {
            try store.save(as: name)
        } catch {
            Prompts.error(error, title: "Couldn't save the new login")
        }
        updateLabel()
    }

    private func quitSessions(before what: String) -> Bool {
        let pids = Sessions.runningClaudeSessions()
        guard !pids.isEmpty else { return true }
        let sessions = pids.count == 1 ? "1 Claude Code session" : "\(pids.count) Claude Code sessions"
        switch Prompts.choose(
            "Quit \(sessions) before \(what)?",
            "Sessions left running carry on under the new account, resending their whole conversation without the old account's cache.\n\nQuit sessions' conversations are saved. Pick them up later with claude --resume.",
            confirm: "Quit Sessions",
            alternate: "Continue Anyway"
        ) {
        case .cancel: return false
        case .alternate:
            return Prompts.confirm(
                "Leaving sessions running can use a lot of your usage",
                "The prompt cache doesn't carry over to the new account. The next message in each running session resends its whole conversation uncached, which can take a big chunk of the new account's session usage straight away. Long conversations cost the most.",
                confirm: "Yes, I’m Sure",
                destructive: true
            )
        case .confirm: break
        }
        let survivors = Processes.terminate(pids)
        if !survivors.isEmpty {
            Prompts.info("Couldn't quit every session", "\(survivors.count) Claude Code process\(survivors.count == 1 ? "" : "es") (PID \(survivors.map(String.init).joined(separator: ", "))) is still running, so nothing was changed.")
            return false
        }
        return true
    }

    private func suggestedName(for account: AccountInfo?) -> String {
        let base = account?.email?.components(separatedBy: "@").first ?? "account"
        let cleaned = base.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "-", options: .regularExpression)
        var name = cleaned.isEmpty ? "account" : String(cleaned.prefix(40))
        var n = 2
        while store.exists(name) {
            name = "\(cleaned.prefix(36))-\(n)"
            n += 1
        }
        return name
    }

    private static func renderIcons(to dir: URL) {
        let variants: [(String, RobotIcon.Badge?)] = [("robot", nil), ("robot-unsaved", .questionmark), ("robot-signed-out", .xmark)]
        for (name, badge) in variants {
            let icon = RobotIcon.image(badge: badge)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 144, pixelsHigh: 144, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 144, height: 144).fill()
            icon.draw(in: NSRect(x: 0, y: 0, width: 144, height: 144))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    private static func printMenu(_ menu: NSMenu, depth: Int = 0) {
        for item in menu.items {
            let pad = String(repeating: "    ", count: depth)
            if item.isSeparatorItem { print(pad + "────"); continue }
            let mark = item.state == .on ? "✓ " : "  "
            let key = item.keyEquivalent.isEmpty ? "" : "  [⌘\(item.keyEquivalent.uppercased())]"
            let off = item.isEnabled && (item.action != nil || item.submenu != nil) ? "" : "  (disabled)"
            let lines = (item.attributedTitle?.string ?? item.title).components(separatedBy: "\n")
            print(pad + mark + lines[0] + key + off)
            for line in lines.dropFirst() { print(pad + "    " + line) }
            if let tip = item.toolTip { print(pad + "    [tooltip] " + tip.replacingOccurrences(of: "\n", with: " | ")) }
            if let sub = item.submenu { printMenu(sub, depth: depth + 1) }
        }
    }

    private static func list(_ store: ProfileStore) {
        let profiles = store.profiles(includeTokens: false)
        let active = store.activeProfile(in: profiles)
        for p in profiles {
            let usage = p.usage.map { usage in
                usage.windows.map { window in
                    window.hasReset() ? "\(window.name) has reset" : "\(window.name) \(Int(window.percent.rounded()))%"
                }.joined(separator: ", ")
            } ?? "no usage recorded"
            print("\(p.name == active?.name ? "*" : " ") \(p.name)  \(p.account?.email ?? "?")  \(usage)")
        }
    }

    private static func switchAccount(_ store: ProfileStore, to name: String, quitSessions: Bool) -> Int32 {
        guard let profile = store.profiles().first(where: { $0.name == name }) else {
            print("no saved account named “\(name)”")
            return 1
        }
        let outgoing = store.activeProfile()?.name
        if outgoing == name {
            print("already using “\(name)”")
            return 0
        }
        guard let tokens = profile.tokens, tokens.hasTokens, !tokens.isRefreshExpired() else {
            print("the saved login for “\(name)” has expired; use Log In Again from the menu")
            return 1
        }
        let pids = Sessions.runningClaudeSessions()
        if !pids.isEmpty {
            guard quitSessions else {
                print("\(pids.count) Claude Code session\(pids.count == 1 ? " is" : "s are") running; pass --quit-sessions to quit \(pids.count == 1 ? "it" : "them") first")
                return 1
            }
            let survivors = Processes.terminate(pids)
            guard survivors.isEmpty else {
                print("couldn't quit PID \(survivors.map(String.init).joined(separator: ", ")), so nothing was changed")
                return 1
            }
        }
        if let outgoing { store.recordUsage(for: outgoing) }
        do {
            try store.use(name)
        } catch {
            print("couldn't switch to “\(name)”: \(error.localizedDescription)")
            return 1
        }
        print("switched to “\(name)” (\(profile.account?.email ?? "unknown account"))")
        return 0
    }

    private static func dump(_ store: ProfileStore) {
        let profiles = store.profiles()
        let active = store.activeProfile(in: profiles)
        print("current: \(store.currentAccount()?.email ?? "signed out")")
        for p in profiles {
            let t = p.tokens
            print("\(p.name == active?.name ? "*" : " ") \(p.name)  \(p.account?.email ?? "?")  plan=\(t?.subscriptionType ?? "?") tokens=\(t?.hasTokens ?? false) refreshExpires=\(t?.refreshExpires.map { "\($0)" } ?? "?") usage=\(p.usage.map { $0.windows.map { "\($0.name) \($0.percent)%" }.joined(separator: ", ") } ?? "none")")
        }
        print("running sessions: \(Sessions.runningClaudeSessions().count)")
    }
}
