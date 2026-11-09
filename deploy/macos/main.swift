// Menu bar app for the macOS build of schulportal-client.
//
// Starts the Dart server (Contents/Resources/bin/server) as child process and
// shows a menu bar icon with: open web UI, edit settings, show log, restart,
// quit. Config and data live in ~/Library/Application Support/schulportal-client,
// the log in ~/Library/Logs/Schulportal-Client.log.
//
// Built by deploy/build-macos-app.sh (swiftc, no Xcode project).

import Cocoa

/// Exit codes of the server (see server/lib/src/desktop/desktop.dart).
private let exitConfigInvalid: Int32 = 78
private let exitConfigCreated: Int32 = 79

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var server: Process?
    private var webURL: URL?
    private var recentOutput = ""
    private var quitting = false
    private var restarting = false

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var supportDir: URL {
        home.appendingPathComponent("Library/Application Support/schulportal-client")
    }
    private var configURL: URL { supportDir.appendingPathComponent("config.env") }
    private var logURL: URL { home.appendingPathComponent("Library/Logs/Schulportal-Client.log") }
    private var logHandle: FileHandle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = NSImage(named: "MenuBarIcon") {
                image.isTemplate = true // adapts to light/dark menu bar
                button.image = image
            } else {
                button.title = "SPH"
            }
            button.toolTip = "Schulportal-Client"
        }

        let menu = NSMenu()
        menu.addItem(menuItem("Schulportal-Client öffnen", #selector(openWebUI), "o"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Einstellungen bearbeiten …", #selector(editSettings), ","))
        menu.addItem(menuItem("Protokoll anzeigen", #selector(showLog), "l"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Neu starten", #selector(restartServer), "r"))
        menu.addItem(menuItem("Beenden", #selector(quitApp), "q"))
        statusItem.menu = menu

        openLog()
        startServer()
    }

    /// Second launch (Finder, Dock, Spotlight) while running: open the web UI.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWebUI()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let server = server, server.isRunning else { return .terminateNow }
        quitting = true
        server.terminate() // SIGTERM: the server closes the database cleanly
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self, self.server != nil else { return }
            kill(server.processIdentifier, SIGKILL)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Server process

    private func startServer() {
        guard let resources = Bundle.main.resourceURL else { return }
        let process = Process()
        process.executableURL = resources.appendingPathComponent("bin/server")
        var env = ProcessInfo.processInfo.environment
        env["ENV_FILE"] = configURL.path
        process.environment = env
        process.currentDirectoryURL = home

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.handleOutput(data) }
        }
        process.terminationHandler = { [weak self] p in
            // Let the pipe deliver the last output first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.serverExited(p.terminationStatus)
            }
        }

        recentOutput = ""
        webURL = nil
        do {
            try process.run()
            server = process
        } catch {
            alert("Der Server konnte nicht gestartet werden:\n\n\(error.localizedDescription)",
                  style: .critical, buttons: ["Beenden"])
            NSApp.terminate(nil)
        }
    }

    private func handleOutput(_ data: Data) {
        logHandle?.write(data)
        let text = String(decoding: data, as: UTF8.self)
        recentOutput = String((recentOutput + text).suffix(4000))
        for line in text.split(separator: "\n") {
            if let range = line.range(of: "Web UI: ") {
                webURL = URL(string: String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    private func serverExited(_ status: Int32) {
        server = nil
        webURL = nil
        if quitting {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        if restarting {
            restarting = false
            startServer()
            return
        }
        switch status {
        case exitConfigCreated:
            alert("Willkommen beim Schulportal-Client!\n\n"
                + "Die Einstellungen werden jetzt geöffnet. Bitte die Zugangsdaten für das "
                + "Schulportal und ein Passwort für die Web-Oberfläche eintragen, speichern "
                + "und den Schulportal-Client erneut starten.\n\n\(configURL.path)",
                  style: .informational, buttons: ["Einstellungen öffnen"])
            editSettings()
            NSApp.terminate(nil)
        case exitConfigInvalid:
            let choice = alert("Die Einstellungen sind unvollständig oder fehlerhaft:\n\n"
                + problems() + "\n\nNach dem Speichern über das Menü „Neu starten“ wählen.",
                               style: .warning, buttons: ["Einstellungen öffnen", "Beenden"])
            if choice == .alertFirstButtonReturn {
                editSettings()
            } else {
                NSApp.terminate(nil)
            }
        default:
            let choice = alert("Der Server wurde unerwartet beendet (Code \(status)).\n\n"
                + String(recentOutput.suffix(800)),
                               style: .critical, buttons: ["Neu starten", "Protokoll anzeigen", "Beenden"])
            switch choice {
            case .alertFirstButtonReturn: startServer()
            case .alertSecondButtonReturn: showLog()
            default: NSApp.terminate(nil)
            }
        }
    }

    /// "  - problem" lines of the server's ConfigException output.
    private func problems() -> String {
        let lines = recentOutput.split(separator: "\n").filter { $0.hasPrefix("  - ") }
        return lines.isEmpty ? String(recentOutput.suffix(800))
            : lines.map { "•  " + $0.dropFirst(4) }.joined(separator: "\n")
    }

    // MARK: - Menu actions

    @objc private func openWebUI() {
        if let url = webURL {
            NSWorkspace.shared.open(url)
        } else if server == nil {
            restartServer()
        }
    }

    @objc private func editSettings() {
        open(["-t", configURL.path]) // default text editor (TextEdit)
    }

    @objc private func showLog() {
        open(["-a", "Console", logURL.path])
    }

    @objc private func restartServer() {
        if let server = server, server.isRunning {
            restarting = true
            server.terminate()
        } else {
            startServer()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func menuItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @discardableResult
    private func alert(_ text: String, style: NSAlert.Style, buttons: [String]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Schulportal-Client"
        alert.informativeText = text
        alert.alertStyle = style
        for b in buttons { alert.addButton(withTitle: b) }
        return alert.runModal()
    }

    private func open(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        try? p.run()
    }

    /// Appends to the log file; keeps one old file when it grows above 2 MB.
    private func openLog() {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 2_000_000 {
            let old = logURL.appendingPathExtension("old")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: logURL, to: old)
        }
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
