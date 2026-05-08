import Cocoa
import WebKit
import UniformTypeIdentifiers

// FileSource, SSHPath, SSHIO live in sshio.swift.

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, NSWindowDelegate, NSMenuDelegate {

    var window: NSWindow!
    var webView: WKWebView!
    var currentFile: FileSource?
    var isDirty: Bool = false
    var pendingFileToOpen: URL?
    var pendingRemoteToOpen: SSHPath?
    var jsReady: Bool = false
    var browseController: BrowseWindowController?

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

        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = self
        openRecent.submenu = openRecentMenu
        fileMenu.addItem(openRecent)

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
            alert.informativeText = "Pick a host to browse, or type a full [user@]host:path to open directly."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")

            let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            combo.placeholderString = "user@host  or  user@host:/path/to/file.md"
            combo.completes = true
            combo.usesDataSource = false
            combo.addItems(withObjectValues: SSHConfig.hostAliases())
            alert.accessoryView = combo
            alert.window.initialFirstResponder = combo

            alert.beginSheetModal(for: self.window) { response in
                guard response == .alertFirstButtonReturn else { return }
                let raw = combo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return }

                if raw.contains(":") {
                    // Full [user@]host:path — existing fast-path.
                    guard let remote = SSHPath.parse(raw) else {
                        self.showError("Invalid SSH path. Use [user@]host:/path/to/file.")
                        return
                    }
                    self.loadRemote(remote)
                } else {
                    // Host alias — open browse window.
                    let host = raw
                    let lastPath = UserDefaults.standard.string(forKey: "plume.lastDir.\(host)") ?? "."
                    self.browseController = BrowseWindowController(host: host, initialPath: lastPath) { [weak self] picked in
                        self?.loadRemote(picked)
                        self?.browseController = nil
                    }
                    self.browseController?.showWindow(nil)
                }
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
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
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
                    // Register in Open Recent using a synthetic plume-ssh:// URL.
                    if let url = self.recentURL(for: remote) {
                        NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    }
                case .failure(let err):
                    self.updateTitle()
                    self.showError("SSH read failed: \(err.localizedDescription)")
                }
            }
        }
    }

    /// Synthesise a plume-ssh:// URL for Open Recent. We use a custom scheme so
    /// NSDocumentController can track remote files the same way it tracks local ones.
    private func recentURL(for remote: SSHPath) -> URL? {
        var components = URLComponents()
        components.scheme = "plume-ssh"
        // remote.host may be "user@server" (browse flow) or bare "server" (direct path flow).
        // URLComponents.host rejects embedded "@", so split user out explicitly.
        if let user = remote.user {
            components.user = user
            components.host = remote.host
        } else if let at = remote.host.firstIndex(of: "@") {
            components.user = String(remote.host[..<at])
            components.host = String(remote.host[remote.host.index(after: at)...])
        } else {
            components.host = remote.host
        }
        components.path = remote.path.hasPrefix("/") ? remote.path : "/" + remote.path
        return components.url
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

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "plume-ssh" {
                let path = url.path
                let host: String = {
                    if let user = url.user, let h = url.host { return "\(user)@\(h)" }
                    return url.host ?? ""
                }()
                guard !host.isEmpty else { continue }
                let remote = SSHPath(user: nil, host: host, path: path)
                if jsReady { loadRemote(remote) } else { pendingRemoteToOpen = remote }
            } else if url.isFileURL {
                if jsReady { loadLocal(url) } else { pendingFileToOpen = url }
            }
        }
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
            } else if let remote = pendingRemoteToOpen {
                pendingRemoteToOpen = nil
                loadRemote(remote)
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

    // MARK: - NSMenuDelegate (Open Recent)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in urls {
            let title: String
            if url.scheme == "plume-ssh" {
                let userPart = url.user.map { "\($0)@" } ?? ""
                title = "ssh: \(userPart)\(url.host ?? "?")\(url.path)"
            } else {
                title = url.lastPathComponent
            }
            let item = NSMenuItem(title: title, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecents), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSApp.delegate?.application?(NSApp, open: [url])
    }

    @objc func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}

// MARK: - Browse window controller

final class BrowseWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let host: String
    private var currentPath: String
    private let onOpen: (SSHPath) -> Void

    private var entries: [BrowseEntry] = []
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")

    init(host: String, initialPath: String, onOpen: @escaping (SSHPath) -> Void) {
        self.host = host
        self.currentPath = initialPath
        self.onOpen = onOpen

        let frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable]
        let win = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.minSize = NSSize(width: 320, height: 240)
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self as? NSWindowDelegate

        buildUI()
        loadDirectory()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func buildUI() {
        guard let win = window else { return }
        win.title = "Browse — \(host):\(currentPath)"

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Name"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 22
        tableView.action = #selector(handleClick)
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.target = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .left
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.secondaryLabelColor

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
        ])

        win.contentView = container
        win.center()
    }

    private func loadDirectory() {
        statusLabel.stringValue = "Loading\u{2026}"
        entries = []
        tableView.reloadData()
        window?.title = "Browse — \(host):\(currentPath)"

        SSHIO.list(host: host, path: currentPath) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let list):
                    self.entries = list
                    self.tableView.reloadData()
                    let count = list.filter { $0.name != ".." }.count
                    self.statusLabel.stringValue = "\(count) item\(count == 1 ? "" : "s")"
                case .failure(let err):
                    self.entries = []
                    self.tableView.reloadData()
                    self.statusLabel.stringValue = err.localizedDescription
                }
            }
        }
    }

    private func navigate(to entry: BrowseEntry) {
        guard entry.isDirectory else { return }
        let newPath = SSHIO.joinPath(currentPath, entry.name)
        currentPath = newPath
        UserDefaults.standard.set(currentPath, forKey: "plume.lastDir.\(host)")
        loadDirectory()
    }

    private func pick(entry: BrowseEntry) {
        guard entry.isOpenable else { return }
        let filePath = SSHIO.joinPath(currentPath, entry.name)
        let remote = SSHPath(user: nil, host: host, path: filePath)
        onOpen(remote)
        window?.close()
    }

    // MARK: Click handling

    @objc private func handleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        if entry.isOpenable {
            pick(entry: entry)
        }
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        if entry.isDirectory {
            navigate(to: entry)
        } else if entry.isOpenable {
            pick(entry: entry)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        if chars == "\r" || chars == "\n" {
            let row = tableView.selectedRow
            guard row >= 0, row < entries.count else { return }
            let entry = entries[row]
            if entry.isDirectory {
                navigate(to: entry)
            } else if entry.isOpenable {
                pick(entry: entry)
            }
        } else if chars == "\u{1B}" {  // Esc
            window?.close()
        } else if chars == "\u{7F}" || (event.modifierFlags.contains(.command) && chars == "\u{F700}") {
            // Backspace or Cmd-Up: go to parent
            navigate(to: BrowseEntry(name: "..", isDirectory: true))
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reuse = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reuse
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            ])
        }
        let prefix = entry.isDirectory ? "\u{1F4C1} " : ""
        cell.textField?.stringValue = prefix + entry.name
        return cell
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
