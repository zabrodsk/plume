import Cocoa
import WebKit
import UniformTypeIdentifiers

// MARK: - File source

enum FileSource {
    case local(URL)
    case remote(SSHPath)

    var displayName: String {
        switch self {
        case .local(let url):  return url.lastPathComponent
        case .remote(let p):   return "ssh: \(p.display)"
        }
    }
}

// MARK: - SSH path

struct SSHPath: Equatable {
    let user: String?
    let host: String
    let path: String

    var display: String {
        let u = user.map { "\($0)@" } ?? ""
        return "\(u)\(host):\(path)"
    }

    var sshTarget: String {
        let u = user.map { "\($0)@" } ?? ""
        return "\(u)\(host)"
    }

    /// Parse `[user@]host:path`. The first colon separates host from path.
    /// IPv6 in brackets and Windows-style colons are out of scope for v2.
    static func parse(_ raw: String) -> SSHPath? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let hostPart = String(trimmed[..<colon])
        let pathPart = String(trimmed[trimmed.index(after: colon)...])
        guard !hostPart.isEmpty, !pathPart.isEmpty else { return nil }

        if let at = hostPart.firstIndex(of: "@") {
            let user = String(hostPart[..<at])
            let host = String(hostPart[hostPart.index(after: at)...])
            guard !user.isEmpty, !host.isEmpty else { return nil }
            return SSHPath(user: user, host: host, path: pathPart)
        }
        return SSHPath(user: nil, host: hostPart, path: pathPart)
    }
}

// MARK: - SSH I/O

/// Shells out to /usr/bin/ssh. Zero bundled dependencies.
enum SSHIO {
    enum SSHError: LocalizedError {
        case nonZeroExit(code: Int32, stderr: String)
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .nonZeroExit(let c, let s):
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return "ssh exited with code \(c)." }
                return "ssh exited with code \(c): \(trimmed)"
            case .decodeFailed:
                return "Remote file is not valid UTF-8."
            }
        }
    }

    /// Read remote text file via `ssh host cat`.
    static func read(_ remote: SSHPath, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = sshArgs(for: remote.sshTarget) + [
                "cat", "--", shellQuote(remote.path)
            ]

            let outPipe = Pipe(); let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            do {
                try proc.run()
                proc.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

                if proc.terminationStatus != 0 {
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    completion(.failure(SSHError.nonZeroExit(code: proc.terminationStatus, stderr: err)))
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    completion(.failure(SSHError.decodeFailed))
                    return
                }
                completion(.success(text))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Write remote text file atomically (write to .tmp, then mv).
    static func write(_ text: String, to remote: SSHPath, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

            let pid = ProcessInfo.processInfo.processIdentifier
            let pathQ = shellQuote(remote.path)
            let tmpQ  = shellQuote("\(remote.path).plume-tmp.\(pid)")
            let remoteCmd = "cat > \(tmpQ) && mv \(tmpQ) \(pathQ)"

            proc.arguments = sshArgs(for: remote.sshTarget) + [remoteCmd]

            let inPipe = Pipe(); let errPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardError = errPipe

            do {
                try proc.run()
                if let data = text.data(using: .utf8) {
                    try inPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try inPipe.fileHandleForWriting.close()
                proc.waitUntilExit()

                if proc.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    completion(.failure(SSHError.nonZeroExit(code: proc.terminationStatus, stderr: err)))
                    return
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Common ssh flags. BatchMode prevents interactive password prompts (we want to fail
    /// fast rather than block the UI on a hidden tty); ConnectTimeout caps the wait.
    private static func sshArgs(for target: String) -> [String] {
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            target
        ]
    }

    /// POSIX shell single-quote escape: wrap in '…', and escape embedded ' as '\''.
    private static func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, NSWindowDelegate {

    var window: NSWindow!
    var webView: WKWebView!
    var currentFile: FileSource?
    var isDirty: Bool = false
    var pendingFileToOpen: URL?
    var jsReady: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupWindow()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if jsReady { loadLocal(url) } else { pendingFileToOpen = url }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func setupWindow() {
        let frame = NSRect(x: 0, y: 0, width: 880, height: 720)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.center()
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.102, green: 0.094, blue: 0.082, alpha: 1.0)
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "dirty")
        ucc.add(self, name: "ready")
        config.userContentController = ucc

        let prefs = WKPreferences()
        prefs.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences = prefs

        webView = WKWebView(frame: frame, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = window.backgroundColor ?? .black
        }

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateTitle()
    }

    func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About \(appName)",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide \(appName)",
                                   action: #selector(NSApplication.hide(_:)),
                                   keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(appName)",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New", action: #selector(newFile), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: "Open\u{2026}", action: #selector(openFile), keyEquivalent: "o"))

        let openSSH = NSMenuItem(title: "Open via SSH\u{2026}", action: #selector(openRemote), keyEquivalent: "o")
        openSSH.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(openSSH)

        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Save", action: #selector(saveFile), keyEquivalent: "s"))
        let saveAs = NSMenuItem(title: "Save As\u{2026}", action: #selector(saveFileAs), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close",
                                    action: #selector(NSWindow.performClose(_:)),
                                    keyEquivalent: "w"))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All",
                                    action: #selector(NSText.selectAll(_:)),
                                    keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fullScreen = NSMenuItem(title: "Toggle Full Screen",
                                    action: #selector(NSWindow.toggleFullScreen(_:)),
                                    keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize",
                                      action: #selector(NSWindow.performMiniaturize(_:)),
                                      keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom",
                                      action: #selector(NSWindow.performZoom(_:)),
                                      keyEquivalent: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Plume"
    }

    @objc func newFile() {
        guardDirty { [weak self] in
            guard let self = self else { return }
            self.currentFile = nil
            self.webView.evaluateJavaScript("window.creamyAPI.setContent('', null)")
            self.isDirty = false
            self.updateTitle()
        }
    }

    @objc func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType, .plainText]
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            self.guardDirty { self.loadLocal(url) }
        }
    }

    @objc func openRemote() {
        guardDirty { [weak self] in
            guard let self = self else { return }
            let alert = NSAlert()
            alert.messageText = "Open via SSH"
            alert.informativeText = "Enter [user@]host:path. Uses your existing SSH keys and ~/.ssh/config."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.placeholderString = "user@host:/path/to/file.md"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            alert.beginSheetModal(for: self.window) { response in
                guard response == .alertFirstButtonReturn else { return }
                let raw = field.stringValue
                guard let remote = SSHPath.parse(raw) else {
                    self.showError("Invalid SSH path. Use [user@]host:/path/to/file.")
                    return
                }
                self.loadRemote(remote)
            }
        }
    }

    func loadLocal(_ url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            currentFile = .local(url)
            isDirty = false
            sendContentToEditor(content, displayPath: url.path)
            updateTitle()
        } catch {
            showError("Could not read file: \(error.localizedDescription)")
        }
    }

    func loadRemote(_ remote: SSHPath) {
        // Optimistically show progress in title; actual content fills in async.
        window.title = "Loading \(remote.display)…"
        SSHIO.read(remote) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let content):
                    self.currentFile = .remote(remote)
                    self.isDirty = false
                    self.sendContentToEditor(content, displayPath: remote.display)
                    self.updateTitle()
                case .failure(let err):
                    self.updateTitle()
                    self.showError("SSH read failed: \(err.localizedDescription)")
                }
            }
        }
    }

    @objc func saveFile() {
        switch currentFile {
        case .some(let source):
            saveTo(source)
        case .none:
            saveFileAs()
        }
    }

    @objc func saveFileAs() {
        let panel = NSSavePanel()
        if let mdType = UTType(filenameExtension: "md") { panel.allowedContentTypes = [mdType] }
        panel.nameFieldStringValue = currentFile?.displayName ?? "Untitled.md"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            self.saveTo(.local(url))
        }
    }

    func saveTo(_ source: FileSource) {
        webView.evaluateJavaScript("window.creamyAPI.getContent()") { [weak self] result, _ in
            guard let self = self else { return }
            guard let content = result as? String else {
                self.showError("Could not read editor content."); return
            }
            switch source {
            case .local(let url):
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    self.currentFile = .local(url)
                    self.isDirty = false
                    self.webView.evaluateJavaScript("window.creamyAPI.markClean()")
                    self.updateTitle()
                } catch {
                    self.showError("Could not save: \(error.localizedDescription)")
                }
            case .remote(let remote):
                SSHIO.write(content, to: remote) { writeResult in
                    DispatchQueue.main.async {
                        switch writeResult {
                        case .success:
                            self.currentFile = .remote(remote)
                            self.isDirty = false
                            self.webView.evaluateJavaScript("window.creamyAPI.markClean()")
                            self.updateTitle()
                        case .failure(let err):
                            self.showError("SSH save failed: \(err.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    func guardDirty(_ proceed: @escaping () -> Void) {
        if !isDirty { proceed(); return }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes."
        alert.informativeText = "Do you want to save before continuing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveThenContinue(proceed)
            case .alertSecondButtonReturn:
                proceed()
            default:
                break
            }
        }
    }

    private func saveThenContinue(_ proceed: @escaping () -> Void) {
        if let source = currentFile {
            // We have a destination — save and chain.
            webView.evaluateJavaScript("window.creamyAPI.getContent()") { [weak self] result, _ in
                guard let self = self, let content = result as? String else { return }
                switch source {
                case .local(let url):
                    do {
                        try content.write(to: url, atomically: true, encoding: .utf8)
                        self.isDirty = false
                        self.webView.evaluateJavaScript("window.creamyAPI.markClean()")
                        self.updateTitle()
                        proceed()
                    } catch {
                        self.showError("Could not save: \(error.localizedDescription)")
                    }
                case .remote(let remote):
                    SSHIO.write(content, to: remote) { writeResult in
                        DispatchQueue.main.async {
                            switch writeResult {
                            case .success:
                                self.isDirty = false
                                self.webView.evaluateJavaScript("window.creamyAPI.markClean()")
                                self.updateTitle()
                                proceed()
                            case .failure(let err):
                                self.showError("SSH save failed: \(err.localizedDescription)")
                            }
                        }
                    }
                }
            }
        } else {
            // No destination — prompt for one (always local; SSH save-as is v3).
            let panel = NSSavePanel()
            if let mdType = UTType(filenameExtension: "md") { panel.allowedContentTypes = [mdType] }
            panel.nameFieldStringValue = "Untitled.md"
            panel.beginSheetModal(for: window) { [weak self] resp in
                guard let self = self, resp == .OK, let url = panel.url else { return }
                self.webView.evaluateJavaScript("window.creamyAPI.getContent()") { result, _ in
                    guard let content = result as? String else { return }
                    do {
                        try content.write(to: url, atomically: true, encoding: .utf8)
                        self.currentFile = .local(url)
                        self.isDirty = false
                        self.webView.evaluateJavaScript("window.creamyAPI.markClean()")
                        self.updateTitle()
                        proceed()
                    } catch {
                        self.showError("Could not save: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func updateTitle() {
        switch currentFile {
        case .local(let url):
            window.title = url.lastPathComponent
            window.representedURL = url
        case .remote(let remote):
            window.title = "ssh: \(remote.display)"
            window.representedURL = nil
        case .none:
            window.title = "Untitled"
            window.representedURL = nil
        }
        window.isDocumentEdited = isDirty
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !isDirty { return true }
        guardDirty { [weak self] in self?.window.close() }
        return false
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "dirty":
            isDirty = true
            updateTitle()
        case "ready":
            jsReady = true
            if let url = pendingFileToOpen {
                pendingFileToOpen = nil
                loadLocal(url)
            }
        default:
            break
        }
    }

    private func sendContentToEditor(_ content: String, displayPath: String?) {
        let jsText = encodeForJS(content)
        let jsPath = displayPath.map { encodeForJS($0) } ?? "null"
        webView.evaluateJavaScript("window.creamyAPI.setContent(\(jsText), \(jsPath))")
    }

    func encodeForJS(_ str: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [str], options: [])
        var json = String(data: data, encoding: .utf8) ?? "[\"\"]"
        json.removeFirst(); json.removeLast()
        return json
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
