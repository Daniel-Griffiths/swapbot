import AppKit
import ServiceManagement

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static var shared: AppDelegate?
    private static let changed = Notification.Name("com.danielgriffiths.SwapBot.changed")

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
        if CommandLine.arguments.contains("--limit-reached") {
            exit(CLI.forward(["limit-reached"]))
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

    var statusItem: NSStatusItem!
    private var loginTimer: Timer?
    private var retryTimer: Timer?
    private var pendingLogin: PendingLogin?
    private var isBusy = false
    private var sleepDisabled = Power.sleepDisabled

    private struct PendingLogin {
        let before: String
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
        refresh()
        _ = try? CLI.run(["auto-switch", "refresh-hook"])

        DistributedNotificationCenter.default().addObserver(forName: Self.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.shared?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.shared?.refresh() }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--screenshot"), i + 1 < CommandLine.arguments.count {
            captureMenu(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }

    private func refresh() {
        let status = CLI.status()
        updateLabel(status)
        scheduleRetry(status?.pendingRetry)
    }

    private func scheduleRetry(_ date: Date?) {
        retryTimer?.invalidate()
        retryTimer = nil
        guard let date else { return }
        let timer = Timer(fire: max(date, Date()), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { AppDelegate.shared?.retryAutoSwitch() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func retryAutoSwitch() {
        _ = try? CLI.run(["auto-switch", "retry"])
        refresh()
    }

    private func waitForLogin(_ pending: PendingLogin) {
        pendingLogin = pending
        loginTimer?.invalidate()
        loginTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { AppDelegate.shared?.checkLogin() }
        }
    }

    private func checkLogin() {
        guard let pending = pendingLogin else { return stopWaitingForLogin() }
        if Date().timeIntervalSince(pending.started) > 15 * 60 {
            stopWaitingForLogin()
        } else if let fingerprint = try? CLI.run(["fingerprint"]), fingerprint != pending.before {
            stopWaitingForLogin()
            loginFinished(pending)
        }
    }

    private func stopWaitingForLogin() {
        pendingLogin = nil
        loginTimer?.invalidate()
        loginTimer = nil
    }

    private func updateLabel(_ status: Status?) {
        guard let button = statusItem?.button else { return }
        let current = status?.current
        let badge: RobotIcon.Badge?
        let title: String
        if current == nil {
            badge = .xmark
            title = status == nil ? "unavailable" : "signed out"
        } else if let active = status?.active {
            badge = nil
            title = active
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
        let status = CLI.status(tokens: true)
        updateLabel(status)
        scheduleRetry(status?.pendingRetry)
        guard let status else {
            menu.addItem(disabled("SwapBot couldn't read your accounts"))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit SwapBot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            return
        }
        let profiles = status.accounts
        let current = status.current

        let header: String
        if let current {
            header = "Signed in as \(current.email ?? "unknown")" + (status.active == nil ? " (not saved)" : "")
        } else {
            header = "Claude Code is signed out"
        }
        menu.addItem(disabled(header))
        menu.addItem(.separator())

        if profiles.isEmpty {
            menu.addItem(disabled("No saved accounts"))
        }
        for (index, profile) in profiles.enumerated() {
            let isActive = profile.name == status.active
            let item = NSMenuItem(title: profile.name, action: #selector(switchAccount(_:)),
                                  keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.target = self
            item.representedObject = profile.name
            item.state = isActive ? .on : .off
            item.attributedTitle = accountTitle(profile, tokens: isActive ? status.liveTokens : profile.tokens)
            item.toolTip = usageTooltip(profile.usage, isActive: isActive)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        if current != nil && status.active == nil {
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
        settingsMenu.addItem(action("Auto-Switch…", #selector(showAutoSwitch)))
        settingsMenu.addItem(.separator())
        let login = action("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        settingsMenu.addItem(login)
        let name = action("Show Account Name in Menu Bar", #selector(toggleShowName))
        name.state = showsName ? .on : .off
        settingsMenu.addItem(name)
        let awake = action("Stay Awake with Lid Closed", #selector(toggleSleepDisabled))
        awake.state = sleepDisabled ? .on : .off
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
        guard !isBusy, let name = sender.representedObject as? String, let status = CLI.status(tokens: true),
              status.active != name else { return }
        let profile = status.profile(name)
        guard let tokens = profile?.tokens, tokens.isUsable else {
            if Prompts.confirm("The saved login for “\(name)” has expired",
                               "Log in as \(profile?.account?.email ?? name) again to keep using it.",
                               confirm: "Log In Again…") {
                startLogin(relogin: name)
            }
            return
        }
        let sameTeam = status.current.flatMap { current in profile?.account?.sharesPromptCache(with: current) } ?? false
        guard sameTeam || quitSessions(before: "switching to “\(name)”") else { return }
        runBusy(["switch", name, "--ignore-sessions"], failure: "Couldn't switch to “\(name)”")
    }

    private func runBusy(_ arguments: [String], failure title: String, then next: @escaping @MainActor () -> Void = {}) {
        isBusy = true
        statusItem.button?.appearsDisabled = true
        Task { @MainActor in
            let result = await Task.detached { Result { try CLI.run(arguments, timeout: 120) } }.value
            isBusy = false
            statusItem.button?.appearsDisabled = false
            refresh()
            switch result {
            case .success: next()
            case .failure(let error): Prompts.error(error, title: title)
            }
        }
    }

    @objc private func saveCurrent() {
        guard let status = CLI.status(), let name = Prompts.name(
            "Save Current Login",
            "Name the account signed in as \(status.current?.email ?? "unknown").",
            initial: status.suggestedName ?? "account", confirm: "Save",
            check: { status.exists($0) ? "There's already an account called “\($0)”." : nil }
        ) else { return }
        do {
            try CLI.run(["save", name])
        } catch {
            Prompts.error(error, title: "Couldn't save the login")
        }
        refresh()
    }

    @objc private func addAccount() {
        startLogin(relogin: nil)
    }

    @objc private func reloginAccount(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        startLogin(relogin: name)
    }

    @objc private func renameAccount(_ sender: NSMenuItem) {
        guard !isBusy, let name = sender.representedObject as? String, let status = CLI.status(),
              let newName = Prompts.name(
                "Rename “\(name)”", "Choose a new name.", initial: name, confirm: "Rename",
                check: { $0 != name && status.exists($0) ? "There's already an account called “\($0)”." : nil }
              ) else { return }
        do {
            try CLI.run(["rename", name, newName])
        } catch {
            Prompts.error(error, title: "Couldn't rename “\(name)”")
        }
        refresh()
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard !isBusy, let name = sender.representedObject as? String else { return }
        let isActive = CLI.status()?.active == name
        let detail = "This deletes its saved login from the Keychain."
            + (isActive ? " It's the account in use now: Claude Code stays signed in to it, but you can't switch back to it later." : "")
        guard Prompts.confirm("Remove “\(name)”?", detail, confirm: "Remove", destructive: true) else { return }
        do {
            try CLI.run(["remove", name])
        } catch {
            Prompts.error(error, title: "Couldn't remove “\(name)”")
        }
        refresh()
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
            try Power.setSleepDisabled(!sleepDisabled)
        } catch {
            Prompts.error(error, title: "Couldn't change Stay Awake with Lid Closed")
        }
        sleepDisabled = Power.sleepDisabled
    }

    @objc private func showAutoSwitch() {
        AutoSwitchWindow.show()
    }

    @objc private func toggleShowName() {
        showsName.toggle()
        refresh()
    }

    private func startLogin(relogin: String?) {
        guard !isBusy, quitSessions(before: relogin == nil ? "adding an account" : "logging in again") else { return }
        runBusy(["record-usage"], failure: "Couldn't record usage") { [self] in openLogin(relogin: relogin) }
    }

    private func openLogin(relogin: String?) {
        let status = CLI.status()
        let email = relogin.flatMap { status?.profile($0)?.account?.email }
        var command = "claude auth login"
        if let email { command += " --email \(Sessions.shellQuote(email))" }

        if let active = status?.active {
            _ = try? CLI.run(["save", active, "--replace"])
        }
        do {
            let before = try CLI.run(["fingerprint"])
            try Sessions.openInTerminal(name: "login", """
            \(command)
            echo
            echo "SwapBot will pick up the new login. You can close this window."
            """)
            waitForLogin(PendingLogin(before: before, relogin: relogin, started: Date()))
        } catch {
            Prompts.error(error, title: "Couldn't open Terminal")
        }
    }

    private func loginFinished(_ pending: PendingLogin) {
        refresh()
        guard let status = CLI.status(), let current = status.current else { return }
        let email = current.email ?? "unknown"

        if let match = status.active {
            do {
                try CLI.run(["save", match, "--replace"])
                var detail = "Signed in as \(email). Its saved login is up to date."
                if let wanted = pending.relogin, wanted != match {
                    detail = "You signed in as \(email), which is saved as “\(match)”, not “\(wanted)”. Updated “\(match)”."
                }
                Prompts.info("“\(match)” is ready", detail)
            } catch {
                Prompts.error(error, title: "Couldn't save the new login")
            }
            refresh()
            return
        }

        guard let name = Prompts.name(
            "New Login: \(email)",
            "Name this account" + (current.organizationName.map { " (\($0))" } ?? "") + ".",
            initial: status.suggestedName ?? "account", confirm: "Save",
            check: { status.exists($0) ? "There's already an account called “\($0)”." : nil }
        ) else { return }
        do {
            try CLI.run(["save", name])
        } catch {
            Prompts.error(error, title: "Couldn't save the new login")
        }
        refresh()
    }

    private func quitSessions(before what: String) -> Bool {
        let pids = (try? CLI.decode([Int32].self, ["sessions", "--json"])) ?? []
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
        do {
            try CLI.run(["quit-sessions"], timeout: 30)
        } catch {
            Prompts.info("Couldn't quit every session", error.localizedDescription)
            return false
        }
        return true
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
}
