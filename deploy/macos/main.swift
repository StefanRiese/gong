// Menu bar app for the macOS build of gong.
//
// Starts the Dart server (Contents/Resources/bin/server-<arch>) as child process and
// shows a menu bar icon with: open web UI, settings (web UI), show log, restart,
// quit. Data (and an optional config.env) live in
// ~/Library/Application Support/gong, the log in
// ~/Library/Logs/Gong.log. On first start the server opens its
// setup page in the browser.
//
// Built by deploy/build-macos-app.sh (swiftc, no Xcode project).

import Cocoa

/// Dart AOT executables cannot be merged with lipo (the program is appended
/// to the runtime), so the app contains one server per architecture and the
/// (universal) launcher starts the one matching its own slice.
#if arch(arm64)
private let serverBinary = "bin/server-arm64"
#else
private let serverBinary = "bin/server-x86_64"
#endif

/// Exit code of the server for an invalid config.env (EX_CONFIG).
private let exitConfigInvalid: Int32 = 78

/// Exit code of the server: a new version is unpacked in
/// <support>/update/Gong.app (see update_service.dart).
private let exitUpdateReady: Int32 = 80

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var server: Process?
    private var webURL: URL?
    private var recentOutput = ""
    private var quitting = false
    private var restarting = false

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var supportDir: URL {
        home.appendingPathComponent("Library/Application Support/gong")
    }
    private var configURL: URL { supportDir.appendingPathComponent("config.env") }
    private var logURL: URL { home.appendingPathComponent("Library/Logs/Gong.log") }
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
            button.toolTip = "Gong"
        }

        let menu = NSMenu()
        menu.addItem(menuItem("Gong öffnen", #selector(openWebUI), "o"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Einstellungen …", #selector(openSettings), ","))
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
        process.executableURL = resources.appendingPathComponent(serverBinary)
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
        case exitUpdateReady:
            installUpdate()
        case exitConfigInvalid:
            let choice = alert("Die Konfigurationsdatei ist fehlerhaft:\n\n"
                + problems() + "\n\nNach dem Speichern über das Menü „Neu starten“ wählen.",
                               style: .warning, buttons: ["Datei öffnen", "Beenden"])
            if choice == .alertFirstButtonReturn {
                editConfigFile()
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

    /// Replaces this app bundle with the downloaded version and starts it.
    private func installUpdate() {
        let updateDir = supportDir.appendingPathComponent("update")
        let source = updateDir.appendingPathComponent("Gong.app")
        let target = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: source)
            try? FileManager.default.removeItem(at: updateDir)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", target.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            let choice = alert("Das Update konnte nicht installiert werden:\n\n"
                + error.localizedDescription
                + "\n\nBitte die neue Version von GitHub laden und die App ersetzen.",
                               style: .warning, buttons: ["Download öffnen", "Weiter mit alter Version"])
            if choice == .alertFirstButtonReturn,
               let url = URL(string: "https://github.com/StefanRiese/gong/releases/latest") {
                NSWorkspace.shared.open(url)
            }
            try? FileManager.default.removeItem(at: updateDir)
            startServer()
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

    /// Server settings page of the web UI.
    @objc private func openSettings() {
        if let url = webURL?.appendingPathComponent("einstellungen/server") {
            NSWorkspace.shared.open(url)
        } else if server == nil {
            restartServer()
        }
    }

    /// Optional config.env (advanced settings, only on errors in it).
    private func editConfigFile() {
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
        alert.messageText = "Gong"
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
