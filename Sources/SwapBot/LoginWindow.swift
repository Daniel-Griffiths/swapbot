import AppKit
import SwiftUI

/// Runs `claude auth login` in the background and shows a small window for the code the sign-in page may hand back.
@MainActor
enum LoginWindow {
    private static var window: NSWindow?
    private static var model: LoginModel?
    private static var closeObserver: NSObjectProtocol?

    static var isOpen: Bool { model != nil }

    static func bringToFront() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func start(claude: String, account: String?, email: String?,
                      finished: @escaping @MainActor () -> Void) throws {
        let model = LoginModel(account: account)
        model.ended = { status, message in
            close()
            if status == 0 {
                finished()
            } else {
                Prompts.error(CLI.Failure(message: message), title: "Couldn't sign in")
            }
        }
        try model.start(claude: claude, email: email)
        self.model = model

        let controller = NSHostingController(rootView: LoginView(model: model, cancel: { window?.close() }))
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.title = "Sign In to Claude"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                self.model?.cancel()
                forget()
            }
        }
        bringToFront()
    }

    static func cancel() {
        model?.cancel()
    }

    private static func close() {
        let closing = window
        forget()
        closing?.close()
    }

    private static func forget() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        model = nil
        window = nil
    }
}

@MainActor
@Observable
final class LoginModel {
    let title: String
    var code = ""
    private(set) var url: URL?
    private(set) var checking = false
    private(set) var problem: String?

    @ObservationIgnored var ended: (Int32, String) -> Void = { _, _ in }
    @ObservationIgnored private let process = Process()
    @ObservationIgnored private let input = Pipe()
    @ObservationIgnored private var output = ""
    @ObservationIgnored private var cancelled = false

    init(account: String?) {
        title = account.map { "Log in to “\($0)” again" } ?? "Add an account"
    }

    func start(claude: String, email: String?) throws {
        signal(SIGPIPE, SIG_IGN)
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["auth", "login"] + (email.map { ["--email", $0] } ?? [])
        process.standardInput = input
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.received(text) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.exited(status) }
        }
        try process.run()
    }

    func submit() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !checking, process.isRunning else { return }
        // Claude Code's own code is "code#state". Anything else would be ignored or fail the whole login.
        guard let line = Self.codeLine(value) else {
            problem = value.count <= 8 && value.allSatisfy(\.isNumber)
                ? "That's the email verification code. Enter it on the Claude sign-in page in your browser, not here."
                : "That doesn't look like the whole code. Copy it again from the sign-in page."
            return
        }
        try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        code = ""
        problem = nil
        checking = true
    }

    /// Accepts "code#state", "code&state=…", or a whole callback URL, and returns "code#state".
    static func codeLine(_ value: String) -> String? {
        if value.contains("#") { return value }
        var query = value.range(of: "?").map { String(value[$0.upperBound...]) } ?? value
        if !query.hasPrefix("code=") { query = "code=" + query }
        let items = URLComponents(string: "x://x?" + query)?.queryItems
        guard let code = items?.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              let state = items?.first(where: { $0.name == "state" })?.value, !state.isEmpty else { return nil }
        return code + "#" + state
    }

    func cancel() {
        cancelled = true
        if process.isRunning { process.terminate() }
    }

    private func received(_ text: String) {
        output += text
        if url == nil, let match = output.range(of: #"https://\S*oauth/authorize\S*"#, options: .regularExpression) {
            url = URL(string: String(output[match]))
        }
        if checking, text.contains("Invalid code") {
            checking = false
            problem = "That doesn't look like the whole code. Copy it again from the sign-in page."
        }
    }

    private func exited(_ status: Int32) {
        guard !cancelled else { return }
        let noise = ["Opening browser", "If the browser didn't open"]
        let message = output.replacingOccurrences(of: "Paste code here if prompted >", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { line in !line.isEmpty && !noise.contains { line.hasPrefix($0) } }
        ended(status, message ?? "claude auth login didn't finish, so nothing was saved.")
    }
}

private struct LoginView: View {
    @Bindable var model: LoginModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            Text("Finish signing in in your browser. Most sign-ins finish by themselves. If the last page shows a long code to paste into Claude Code, paste it here. A 6-digit verification code goes on the sign-in page, not here.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Code", text: $model.code)
                .textFieldStyle(.roundedBorder)
                .disabled(model.checking)
                .onSubmit(model.submit)
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Open Sign-In Page Again") {
                    if let url = model.url { NSWorkspace.shared.open(url) }
                }
                .disabled(model.url == nil)
                Spacer()
                if model.checking { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: model.submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.checking || model.code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
