import AppKit

@MainActor
enum Prompts {
    static func error(_ error: Error, title: String = "Something went wrong") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        run(alert)
    }

    static func info(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        run(alert)
    }

    static func confirm(_ title: String, _ detail: String, confirm: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .critical : .warning
        alert.messageText = title
        alert.informativeText = detail
        let ok = alert.addButton(withTitle: confirm)
        ok.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        return run(alert) == .alertFirstButtonReturn
    }

    enum Choice { case confirm, alternate, cancel }

    /// Three buttons: `confirm` is the default, `alternate` is shown in the destructive (red) style.
    static func choose(_ title: String, _ detail: String, confirm: String, alternate: String) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: alternate).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        switch run(alert) {
        case .alertFirstButtonReturn: return .confirm
        case .alertSecondButtonReturn: return .alternate
        default: return .cancel
        }
    }

    static func name(_ title: String, _ detail: String, initial: String, confirm: String,
                     check: (String) -> String? = { _ in nil }) -> String? {
        var value = initial
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = problem.map { "\(detail)\n\n⚠︎ \($0)" } ?? detail
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = value
            field.placeholderString = "e.g. work"
            alert.accessoryView = field
            alert.addButton(withTitle: confirm)
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard run(alert) == .alertFirstButtonReturn else { return nil }

            value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$"#, options: .regularExpression) == nil {
                problem = "“\(value)” isn't a valid name. Use letters, numbers, dots, dashes or underscores."
                continue
            }
            if let issue = check(value) {
                problem = issue
                continue
            }
            return value
        }
    }

    @discardableResult
    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }
}
