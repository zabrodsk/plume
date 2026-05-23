import Cocoa
import Sparkle
import WebKit
import UniformTypeIdentifiers

// FileSource, SSHPath, SSHIO live in sshio.swift.

// MARK: - Progress overlay

/// Small non-modal overlay anchored to the bottom-right of a parent view.
/// Shows a loading message and a Cancel button. Fades in after being added.
final class ProgressOverlay {
    private let view: NSView
    private weak var parent: NSView?

    init(parent: NSView, message: String, onCancel: @escaping () -> Void) {
        self.parent = parent

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.102, green: 0.094, blue: 0.082, alpha: 0.90).cgColor
        container.layer?.cornerRadius = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.textColor = NSColor(red: 0.910, green: 0.894, blue: 0.847, alpha: 1.0)
        label.font = NSFont.systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false

        let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
        cancelBtn.bezelStyle = .recessed
        cancelBtn.isBordered = false
        cancelBtn.contentTintColor = NSColor(red: 0.910, green: 0.894, blue: 0.847, alpha: 0.75)
        cancelBtn.font = NSFont.systemFont(ofSize: 12)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        cancelBtn.onAction { onCancel() }

        container.addSubview(label)
        container.addSubview(cancelBtn)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 44),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),

            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cancelBtn.leadingAnchor, constant: -8),

            cancelBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            cancelBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        self.view = container
        parent.addSubview(container)

        NSLayoutConstraint.activate([
            container.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16),
            container.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -16),
        ])

        // Fade in
        container.layer?.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.15
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        container.layer?.add(fade, forKey: "fadeIn")
        container.layer?.opacity = 1
    }

    func dismiss() {
        view.removeFromSuperview()
    }
}

// Helper to attach an action closure to NSButton without a target/selector dance.
private enum AssociatedKeys {
    static var action: UInt8 = 0
}
private extension NSButton {
    func onAction(_ block: @escaping () -> Void) {
        objc_setAssociatedObject(self, &AssociatedKeys.action, block as AnyObject, .OBJC_ASSOCIATION_RETAIN)
        target = self
        action = #selector(runAction)
    }
    @objc private func runAction() {
        (objc_getAssociatedObject(self, &AssociatedKeys.action) as? () -> Void)?()
    }
}

// MARK: - Tab model

/// One open document inside a PlumeWindowController. JS owns the live buffer between
/// snapshots; `content` is refreshed at save / switch / close / persistence checkpoints.
final class Tab {
    let id: UUID
    var source: FileSource?
    var content: String
    var isDirty: Bool

    init(id: UUID = UUID(), source: FileSource? = nil, content: String = "", isDirty: Bool = false) {
        self.id = id
        self.source = source
        self.content = content
        self.isDirty = isDirty
    }

    var title: String { source?.displayName ?? "Untitled" }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    var windows: [PlumeWindowController] = []
    var pendingFileToOpen: URL?
    var pendingRemoteToOpen: SSHPath?
    var updaterController: SPUStandardUpdaterController!

    // Version-keyed so future releases can independently decide whether to show a new welcome.
    private static let firstLaunchKey = "plume.firstLaunchSeen.2.5.0"

    static let welcomeDocument = """
# Welcome to Plume.

Plume is a markdown editor for the satisfaction of typing. Every
letter *blooms*. **Nothing else does.**

## Four keys that matter

- **⌘O** — open a local file
- **⌥⌘O** — open a file on a remote server via SSH
- **⌘F** — find in this page
- **⌘?** — every other shortcut

## A taste of what renders

Inline code looks like `let x = 42`. Fenced code with a language
tag gets colored:

```swift
func bloom(_ letter: Character) -> Animation {
    .opacity(from: 0.4, to: 1.0, duration: .ms(90))
}
```

A link points [home](https://github.com/zabrodsk/plume).

## The page is yours.

Delete this. Type something. Save with `⌘S`. That's all there is.

> *Less app. More page.*

"""

    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        setupMenu()
        spawnInitialWindow()
    }

    var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Plume"
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if let controller = activeWindowController() {
            controller.loadLocalWhenReady(url)
        } else {
            pendingFileToOpen = url
            spawnInitialWindow()
        }
        return true
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
                if let controller = activeWindowController() {
                    controller.loadRemoteWhenReady(remote)
                } else {
                    pendingRemoteToOpen = remote
                    spawnInitialWindow()
                }
            } else if url.isFileURL {
                if let controller = activeWindowController() {
                    controller.loadLocalWhenReady(url)
                } else {
                    pendingFileToOpen = url
                    spawnInitialWindow()
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func spawnInitialWindow() {
        let controller = newWindowController()
        controller.showWindow(nil)
        controller.pendingFileToOpen = pendingFileToOpen
        controller.pendingRemoteToOpen = pendingRemoteToOpen
        controller.shouldShowWelcomeIfNoPending = true
        pendingFileToOpen = nil
        pendingRemoteToOpen = nil
    }

    func newWindowController() -> PlumeWindowController {
        let controller = PlumeWindowController(appDelegate: self)
        windows.append(controller)
        return controller
    }

    func removeWindow(_ controller: PlumeWindowController) {
        windows.removeAll { $0 === controller }
    }

    /// Window that is key, or the first window if none is key (e.g. just after launch).
    func activeWindowController() -> PlumeWindowController? {
        if let key = NSApp.keyWindow, let controller = windows.first(where: { $0.window === key }) {
            return controller
        }
        return windows.first
    }

    func shouldShowWelcomeAndConsume() -> Bool {
        if UserDefaults.standard.bool(forKey: AppDelegate.firstLaunchKey) { return false }
        UserDefaults.standard.set(true, forKey: AppDelegate.firstLaunchKey)
        return true
    }

    func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About \(appName)",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        let checkForUpdates = NSMenuItem(
            title: "Check for Updates\u{2026}",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = updaterController
        appMenu.addItem(checkForUpdates)
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
        // Window-scoped: dispatch via responder chain (target = nil).
        let newItem = NSMenuItem(title: "New", action: #selector(PlumeWindowController.newFile), keyEquivalent: "n")
        newItem.target = nil
        fileMenu.addItem(newItem)

        let openItem = NSMenuItem(title: "Open\u{2026}", action: #selector(PlumeWindowController.openFile), keyEquivalent: "o")
        openItem.target = nil
        fileMenu.addItem(openItem)

        let openSSH = NSMenuItem(title: "Open via SSH\u{2026}", action: #selector(PlumeWindowController.openRemote), keyEquivalent: "o")
        openSSH.keyEquivalentModifierMask = [.command, .option]
        openSSH.target = nil
        fileMenu.addItem(openSSH)

        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = self
        openRecent.submenu = openRecentMenu
        fileMenu.addItem(openRecent)

        fileMenu.addItem(.separator())

        let saveItem = NSMenuItem(title: "Save", action: #selector(PlumeWindowController.saveFile), keyEquivalent: "s")
        saveItem.target = nil
        fileMenu.addItem(saveItem)

        let saveAs = NSMenuItem(title: "Save As\u{2026}", action: #selector(PlumeWindowController.saveFileAs), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        saveAs.target = nil
        fileMenu.addItem(saveAs)

        fileMenu.addItem(.separator())
        // performClose travels the responder chain naturally; no target needed.
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
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: "Find\u{2026}", action: #selector(PlumeWindowController.performFind), keyEquivalent: "f")
        findItem.target = nil
        editMenu.addItem(findItem)
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

        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let cheatsheetItem = NSMenuItem(title: "Plume Cheatsheet",
                                        action: #selector(PlumeWindowController.showCheatsheet),
                                        keyEquivalent: "?")
        cheatsheetItem.keyEquivalentModifierMask = [.command, .shift]
        cheatsheetItem.target = nil
        helpMenu.addItem(cheatsheetItem)
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - NSMenuDelegate (Open Recent)

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let italic = NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0), toHaveTrait: .italicFontMask)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: italic,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let row1 = NSMenuItem()
            row1.attributedTitle = NSAttributedString(string: "no files yet", attributes: attrs)
            row1.isEnabled = false
            let row2 = NSMenuItem()
            row2.attributedTitle = NSAttributedString(string: "⌘O local · ⌥⌘O remote", attributes: attrs)
            row2.isEnabled = false
            menu.addItem(row1)
            menu.addItem(row2)
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

// MARK: - Plume window controller

final class PlumeWindowController: NSWindowController, NSWindowDelegate, WKScriptMessageHandler {

    private unowned let appDelegate: AppDelegate

    var webView: WKWebView!

    // Single-tab semantics for Phase A. Phase C introduces the array + activeTabId.
    var currentFile: FileSource?
    var isDirty: Bool = false
    var jsReady: Bool = false

    var pendingFileToOpen: URL?
    var pendingRemoteToOpen: SSHPath?
    var shouldShowWelcomeIfNoPending: Bool = false

    private var browseController: BrowseWindowController?
    private var currentReadTask: SSHTask?
    private var progressOverlay: ProgressOverlay?
    private var escMonitor: Any?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate

        let frame = NSRect(x: 0, y: 0, width: 880, height: 720)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.center()
        let bgColor = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(red: 0.102, green: 0.094, blue: 0.082, alpha: 1.0)
            } else {
                return NSColor(red: 0.992, green: 0.980, blue: 0.949, alpha: 1.0)
            }
        }
        window.backgroundColor = bgColor
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self

        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "dirty")
        ucc.add(self, name: "ready")
        ucc.add(self, name: "openURL")
        ucc.add(self, name: "tabAction")
        config.userContentController = ucc

        let prefs = WKPreferences()
        prefs.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences = prefs

        webView = WKWebView(frame: frame, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = bgColor
        }

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        window.contentView = webView
        updateTitle()

        // Fullscreen observers — toggle body.fullscreen so the tab-strip spacer collapses.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillEnterFullScreen(_:)),
            name: NSWindow.willEnterFullScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillExitFullScreen(_:)),
            name: NSWindow.willExitFullScreenNotification, object: window
        )
    }

    @objc private func handleWillEnterFullScreen(_ note: Notification) {
        webView.evaluateJavaScript("window.creamyAPI && window.creamyAPI.setFullscreen && window.creamyAPI.setFullscreen(true)")
    }

    @objc private func handleWillExitFullScreen(_ note: Notification) {
        webView.evaluateJavaScript("window.creamyAPI && window.creamyAPI.setFullscreen && window.creamyAPI.setFullscreen(false)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Public load-when-ready entry points

    func loadLocalWhenReady(_ url: URL) {
        if jsReady { loadLocal(url) } else { pendingFileToOpen = url }
    }

    func loadRemoteWhenReady(_ remote: SSHPath) {
        if jsReady { loadRemote(remote) } else { pendingRemoteToOpen = remote }
    }

    // MARK: Menu actions (responder-chain, target = nil)

    @objc func performFind() {
        webView.evaluateJavaScript("window.find_open && window.find_open()")
    }

    @objc func showCheatsheet() {
        webView.evaluateJavaScript("window.cheatsheet_open && window.cheatsheet_open()")
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
        guard let window = window else { return }
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
        guard let window = window else { return }
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

            let key = "plume.sshDialogSeen"
            let firstTime = !UserDefaults.standard.bool(forKey: key)

            let hint: NSTextField? = firstTime ? {
                let label = NSTextField(labelWithString: "Type a host, or just a path.\nPlume reads your ~/.ssh/config.")
                label.font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)
                label.textColor = NSColor.secondaryLabelColor
                label.maximumNumberOfLines = 2
                label.lineBreakMode = .byWordWrapping
                return label
            }() : nil

            let accessoryView: NSView
            if let hint = hint {
                let stack = NSStackView(views: [combo, hint])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 6
                stack.frame = NSRect(x: 0, y: 0, width: 360, height: 64)
                accessoryView = stack
            } else {
                accessoryView = combo
            }
            alert.accessoryView = accessoryView
            alert.window.initialFirstResponder = combo

            if firstTime {
                UserDefaults.standard.set(true, forKey: key)
            }

            alert.beginSheetModal(for: window) { response in
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
        guard let window = window else { return }
        window.title = "Loading \(remote.display)…"

        // Install an Esc key monitor while the read is in flight.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.currentReadTask != nil else { return event }
            if event.keyCode == 53 {  // Esc
                self.currentReadTask?.cancel()
                return nil
            }
            return event
        }

        let task = SSHIO.read(remote) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.dismissReadProgress()
                switch result {
                case .success(let content):
                    self.currentFile = .remote(remote)
                    self.isDirty = false
                    self.sendContentToEditor(content, displayPath: remote.display)
                    self.updateTitle()
                    if let url = self.recentURL(for: remote) {
                        NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    }
                case .failure(let err):
                    self.updateTitle()
                    if case SSHIO.SSHError.cancelled? = err as? SSHIO.SSHError { return }
                    self.showSSHError(err, host: remote.host, path: remote.path)
                }
            }
        }
        currentReadTask = task

        // Show the overlay after 250 ms — skip it entirely if the read is already done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.currentReadTask != nil,
                  let contentView = self.window?.contentView else { return }
            let pathDisplay = (remote.path as NSString).lastPathComponent.isEmpty
                ? remote.path
                : (remote.path as NSString).lastPathComponent
            let msg = "Loading \(remote.host):\(pathDisplay)…"
            self.progressOverlay = ProgressOverlay(
                parent: contentView,
                message: msg,
                onCancel: { [weak self] in self?.currentReadTask?.cancel() }
            )
        }
    }

    private func dismissReadProgress() {
        progressOverlay?.dismiss()
        progressOverlay = nil
        currentReadTask = nil
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    /// Synthesise a plume-ssh:// URL for Open Recent. We use a custom scheme so
    /// NSDocumentController can track remote files the same way it tracks local ones.
    private func recentURL(for remote: SSHPath) -> URL? {
        var components = URLComponents()
        components.scheme = "plume-ssh"
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
        guard let window = window else { return }
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
                            self.showSSHError(err, host: remote.host, path: remote.path)
                        }
                    }
                }
            }
        }
    }

    func guardDirty(_ proceed: @escaping () -> Void) {
        guard let window = window else { proceed(); return }
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
                                self.showSSHError(err, host: remote.host, path: remote.path)
                            }
                        }
                    }
                }
            }
        } else {
            guard let window = window else { return }
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
        guard let window = window else { return }
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
        guardDirty { [weak self] in self?.window?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        appDelegate.removeWindow(self)
    }

    func showError(_ message: String) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func showSSHError(_ error: Error, host: String, path: String?) {
        guard let window = window else { return }
        let info = SSHIO.describe(error: error, host: host, path: path)
        let alert = NSAlert()
        alert.messageText = info.title
        alert.informativeText = info.body
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
            } else if let remote = pendingRemoteToOpen {
                pendingRemoteToOpen = nil
                loadRemote(remote)
            } else if shouldShowWelcomeIfNoPending {
                shouldShowWelcomeIfNoPending = false
                if appDelegate.shouldShowWelcomeAndConsume() {
                    sendContentToEditor(AppDelegate.welcomeDocument, displayPath: nil)
                    isDirty = true
                    updateTitle()
                }
            }
        case "openURL":
            if let s = message.body as? String, let url = URL(string: s) {
                NSWorkspace.shared.open(url)
            }
        case "tabAction":
            // Phase B stub: tab strip is single-tab and read-only from native.
            // Phase C replaces this with real tab dispatch.
            break
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
        win.minSize = NSSize(width: 320, height: 240)
        win.isReleasedWhenClosed = false
        super.init(window: win)

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
