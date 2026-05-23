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

// MARK: - Persistence

/// Lightweight JSON-on-disk state used to restore windows and tabs across launches.
/// Schema is versioned; defensive load renames the file to state.corrupt.json on any
/// parse failure rather than crashing.
enum PlumeState {

    struct File: Codable {
        var version: Int
        var windows: [Window]
    }
    struct Window: Codable {
        var frame: String          // NSStringFromRect form
        var activeTabIndex: Int
        var tabs: [TabRecord]
    }
    struct TabRecord: Codable {
        var id: String             // UUID string
        var kind: String           // "local" | "remote" | "untitled"
        var url: String?           // file URL string
        var ssh: SSH?
        var contentDraft: String?  // present only when dirty or untitled
        var isDirty: Bool
    }
    struct SSH: Codable {
        var user: String?
        var host: String
        var path: String
    }

    static let currentVersion = 1
    static let restoreOnLaunchKey = "plume.restoreWindowsOnLaunch"

    static func stateURL() -> URL? {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let dir = support.appendingPathComponent("Plume", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("state.json")
        } catch {
            FileHandle.standardError.write(Data("Plume: failed to resolve state directory: \(error)\n".utf8))
            return nil
        }
    }

    static func load() -> File? {
        guard let url = stateURL() else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(File.self, from: data)
            guard decoded.version == currentVersion else {
                quarantine(url, reason: "version mismatch (\(decoded.version) != \(currentVersion))")
                return nil
            }
            return decoded
        } catch {
            quarantine(url, reason: "decode failed: \(error)")
            return nil
        }
    }

    static func save(_ file: File) {
        guard let url = stateURL() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Plume: failed to save state: \(error)\n".utf8))
        }
    }

    private static func quarantine(_ url: URL, reason: String) {
        let corrupt = url.deletingLastPathComponent().appendingPathComponent("state.corrupt.json")
        try? FileManager.default.removeItem(at: corrupt)
        do {
            try FileManager.default.moveItem(at: url, to: corrupt)
            FileHandle.standardError.write(Data("Plume: state quarantined to \(corrupt.path) — \(reason)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Plume: state quarantine failed: \(error)\n".utf8))
        }
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
        // Default restoreWindowsOnLaunch to true on first ever launch.
        if UserDefaults.standard.object(forKey: PlumeState.restoreOnLaunchKey) == nil {
            UserDefaults.standard.set(true, forKey: PlumeState.restoreOnLaunchKey)
        }
        setupMenu()
        let shouldRestore = UserDefaults.standard.bool(forKey: PlumeState.restoreOnLaunchKey)
        if shouldRestore, let state = PlumeState.load(), !state.windows.isEmpty {
            restore(state)
        } else {
            spawnInitialWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Snapshot synchronously so unsaved drafts survive the quit.
        saveStateNow()
    }

    /// Build a state snapshot from current in-memory windows + tabs. JS-side textareas
    /// are snapshotted into each Tab's `content` first so the saved draft is fresh.
    func snapshotState(completion: @escaping (PlumeState.File) -> Void) {
        let group = DispatchGroup()
        for controller in windows {
            for tab in controller.tabs {
                if tab.isDirty || tab.source == nil {
                    group.enter()
                    controller.webView.evaluateJavaScript(
                        "window.creamyAPI.getTabContent('\(tab.id.uuidString)')"
                    ) { result, _ in
                        if let s = result as? String { tab.content = s }
                        group.leave()
                    }
                }
            }
        }
        let finalize: () -> Void = { [weak self] in
            guard let self = self else { return }
            let windows: [PlumeState.Window] = self.windows.map { controller in
                let frame = controller.window.map { NSStringFromRect($0.frame) } ?? ""
                let activeIdx: Int = {
                    if let id = controller.activeTabId,
                       let i = controller.tabs.firstIndex(where: { $0.id == id }) { return i }
                    return 0
                }()
                let tabs: [PlumeState.TabRecord] = controller.tabs.map { tab in
                    var rec = PlumeState.TabRecord(
                        id: tab.id.uuidString,
                        kind: "untitled",
                        url: nil, ssh: nil,
                        contentDraft: nil,
                        isDirty: tab.isDirty
                    )
                    switch tab.source {
                    case .local(let url):
                        rec.kind = "local"
                        rec.url = url.absoluteString
                    case .remote(let r):
                        rec.kind = "remote"
                        rec.ssh = PlumeState.SSH(user: r.user, host: r.host, path: r.path)
                    case .none:
                        rec.kind = "untitled"
                    }
                    // Persist contentDraft only for dirty tabs and untitled tabs
                    // (clean tabs reload from disk/SSH at launch).
                    if tab.isDirty || tab.source == nil {
                        rec.contentDraft = tab.content
                    }
                    return rec
                }
                return PlumeState.Window(frame: frame, activeTabIndex: activeIdx, tabs: tabs)
            }
            completion(PlumeState.File(version: PlumeState.currentVersion, windows: windows))
        }
        // Wait briefly for JS, then save. Using main-queue notify keeps ordering.
        group.notify(queue: .main, execute: finalize)
    }

    /// Persist state asynchronously after a dirty event (debounced).
    private var saveDebounceWork: DispatchWorkItem?
    func scheduleStateSave() {
        saveDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.snapshotState { state in PlumeState.save(state) }
        }
        saveDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Synchronous save path for window close / applicationWillTerminate.
    /// JS evaluateJavaScript is async, so we run a brief runloop to collect the
    /// snapshots before writing.
    func saveStateNow() {
        let sema = DispatchSemaphore(value: 0)
        var captured: PlumeState.File?
        snapshotState { state in
            captured = state
            sema.signal()
        }
        // Pump the main run loop until snapshot completes or 1s elapses.
        let deadline = Date().addingTimeInterval(1.0)
        while captured == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if let file = captured {
            PlumeState.save(file)
        }
        _ = sema  // keep alive
    }

    /// Reconstruct windows + tabs from a saved state file.
    func restore(_ state: PlumeState.File) {
        for win in state.windows {
            let controller = newWindowController()
            // Apply frame if parseable.
            if !win.frame.isEmpty {
                let frame = NSRectFromString(win.frame)
                if frame.size.width > 100 && frame.size.height > 100 {
                    controller.window?.setFrame(frame, display: false)
                }
            }
            controller.pendingRestoreTabs = win.tabs
            controller.pendingRestoreActiveIndex = win.activeTabIndex
            controller.shouldShowWelcomeIfNoPending = false
            controller.startsWithEmptyUntitled = false
            controller.showWindow(nil)
        }
    }

    var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Plume"
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        openOrFocusLocal(url)
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
                openOrFocusRemote(remote)
            } else if url.isFileURL {
                openOrFocusLocal(url)
            }
        }
    }

    /// Open a local URL: focus existing tab if already open anywhere, otherwise
    /// open as a new tab in the active window (or in a fresh window if none).
    func openOrFocusLocal(_ url: URL) {
        let standard = url.standardizedFileURL
        for controller in windows {
            for tab in controller.tabs {
                if case .local(let existing)? = tab.source, existing.standardizedFileURL == standard {
                    controller.window?.makeKeyAndOrderFront(nil)
                    controller.activateTab(id: tab.id)
                    return
                }
            }
        }
        if let controller = activeWindowController() {
            controller.openLocalAsNewTab(url)
        } else {
            pendingFileToOpen = url
            spawnInitialWindow()
        }
    }

    func openOrFocusRemote(_ remote: SSHPath) {
        for controller in windows {
            for tab in controller.tabs {
                if case .remote(let existing)? = tab.source, existing == remote {
                    controller.window?.makeKeyAndOrderFront(nil)
                    controller.activateTab(id: tab.id)
                    return
                }
            }
        }
        if let controller = activeWindowController() {
            controller.openRemoteAsNewTab(remote)
        } else {
            pendingRemoteToOpen = remote
            spawnInitialWindow()
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

    // MARK: App-level menu actions

    @objc func newWindow(_ sender: Any?) {
        let controller = newWindowController()
        // Set flags before showWindow so the JS-ready handler picks them up.
        controller.shouldShowWelcomeIfNoPending = false
        controller.startsWithEmptyUntitled = true
        controller.showWindow(nil)
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

        // New Tab — window-scoped via responder chain.
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(PlumeWindowController.newTab), keyEquivalent: "t")
        newTabItem.target = nil
        fileMenu.addItem(newTabItem)

        // New Window — app-global, opens a fresh PlumeWindowController.
        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)

        fileMenu.addItem(.separator())

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

        // Close Tab — ⌘W. Window-scoped. Falls through to closing the window if last tab.
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(PlumeWindowController.closeTab), keyEquivalent: "w")
        closeTabItem.target = nil
        fileMenu.addItem(closeTabItem)

        // Close Window — ⇧⌘W. Plain NSWindow.performClose travels the responder chain.
        let closeWindowItem = NSMenuItem(title: "Close Window",
                                         action: #selector(NSWindow.performClose(_:)),
                                         keyEquivalent: "W")
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWindowItem)

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
        windowMenu.addItem(.separator())

        // Next / previous tab.
        let nextTab = NSMenuItem(title: "Select Next Tab",
                                 action: #selector(PlumeWindowController.selectNextTab),
                                 keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        nextTab.target = nil
        windowMenu.addItem(nextTab)
        let prevTab = NSMenuItem(title: "Select Previous Tab",
                                 action: #selector(PlumeWindowController.selectPrevTab),
                                 keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        prevTab.target = nil
        windowMenu.addItem(prevTab)

        // ⌃⇥ / ⌃⇧⇥ alternates.
        let nextTabAlt = NSMenuItem(title: "Select Next Tab (alt)",
                                    action: #selector(PlumeWindowController.selectNextTab),
                                    keyEquivalent: "\t")
        nextTabAlt.keyEquivalentModifierMask = [.control]
        nextTabAlt.isAlternate = true
        nextTabAlt.target = nil
        windowMenu.addItem(nextTabAlt)
        let prevTabAlt = NSMenuItem(title: "Select Previous Tab (alt)",
                                    action: #selector(PlumeWindowController.selectPrevTab),
                                    keyEquivalent: "\t")
        prevTabAlt.keyEquivalentModifierMask = [.control, .shift]
        prevTabAlt.isAlternate = true
        prevTabAlt.target = nil
        windowMenu.addItem(prevTabAlt)

        // ⌘1..⌘9 select tab N.
        for i in 1...9 {
            let item = NSMenuItem(title: "Tab \(i)",
                                  action: #selector(PlumeWindowController.selectTabAtIndex(_:)),
                                  keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = i - 1
            item.target = nil
            windowMenu.addItem(item)
        }

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

    // Tab model.
    var tabs: [Tab] = []
    var activeTabId: UUID?
    var jsReady: Bool = false

    var pendingFileToOpen: URL?
    var pendingRemoteToOpen: SSHPath?
    var shouldShowWelcomeIfNoPending: Bool = false
    var startsWithEmptyUntitled: Bool = false
    var pendingRestoreTabs: [PlumeState.TabRecord]?
    var pendingRestoreActiveIndex: Int = 0

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

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillEnterFullScreen(_:)),
            name: NSWindow.willEnterFullScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillExitFullScreen(_:)),
            name: NSWindow.willExitFullScreenNotification, object: window
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleWillEnterFullScreen(_ note: Notification) {
        webView.evaluateJavaScript("window.creamyAPI && window.creamyAPI.setFullscreen && window.creamyAPI.setFullscreen(true)")
    }

    @objc private func handleWillExitFullScreen(_ note: Notification) {
        webView.evaluateJavaScript("window.creamyAPI && window.creamyAPI.setFullscreen && window.creamyAPI.setFullscreen(false)")
    }

    // MARK: Tab lookup

    var activeTab: Tab? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    func tab(withId id: UUID) -> Tab? {
        return tabs.first(where: { $0.id == id })
    }

    func indexOfTab(id: UUID) -> Int? {
        return tabs.firstIndex(where: { $0.id == id })
    }

    // MARK: Tab create / activate / close

    /// Insert a tab into the model, mount its textarea in JS, and activate it.
    func addTabAndActivate(_ tab: Tab) {
        tabs.append(tab)
        let jsContent = encodeForJS(tab.content)
        let jsPath: String
        switch tab.source {
        case .local(let url): jsPath = encodeForJS(url.path)
        case .remote(let r):  jsPath = encodeForJS(r.display)
        case .none:           jsPath = "null"
        }
        webView.evaluateJavaScript("window.creamyAPI.openTab('\(tab.id.uuidString)', \(jsContent), \(jsPath))")
        activateTab(id: tab.id)
    }

    /// Activate `id`: snapshot current tab's content first, then ask JS to swap.
    func activateTab(id: UUID) {
        guard tab(withId: id) != nil else { return }
        // Snapshot outgoing tab's value so persistence and same-window save-as see fresh content.
        if let activeId = activeTabId, activeId != id, let outgoing = self.tab(withId: activeId) {
            webView.evaluateJavaScript("window.creamyAPI.getTabContent('\(activeId.uuidString)')") { [weak self] result, _ in
                if let content = result as? String {
                    outgoing.content = content
                }
                self?.performActivate(id: id)
            }
        } else {
            performActivate(id: id)
        }
    }

    private func performActivate(id: UUID) {
        activeTabId = id
        webView.evaluateJavaScript("window.creamyAPI.activateTab('\(id.uuidString)')")
        updateTitle()
        refreshTabStrip()
    }

    /// Close a tab. If dirty, prompts via guardDirty. If it's the last tab,
    /// falls through to closing the window.
    func closeTabById(_ id: UUID) {
        guard let idx = indexOfTab(id: id), let tab = self.tab(withId: id) else { return }
        guardDirty(tab) { [weak self] in
            guard let self = self else { return }
            self.tabs.remove(at: idx)
            self.webView.evaluateJavaScript("window.creamyAPI.closeTab('\(id.uuidString)')")
            if self.tabs.isEmpty {
                // Last tab — close the window. Don't trigger guardDirty again; we just
                // accepted the close path. windowShouldClose will see empty/clean state.
                self.window?.close()
                return
            }
            // Activate adjacent tab.
            let newActive = self.tabs[min(idx, self.tabs.count - 1)]
            self.activeTabId = newActive.id
            self.webView.evaluateJavaScript("window.creamyAPI.activateTab('\(newActive.id.uuidString)')")
            self.updateTitle()
            self.refreshTabStrip()
        }
    }

    /// Push the current tab list to JS so the strip renders accurately.
    func refreshTabStrip() {
        var rows: [String] = []
        for tab in tabs {
            let title = encodeForJS(tab.title)
            let active = (tab.id == activeTabId) ? "true" : "false"
            let dirty = tab.isDirty ? "true" : "false"
            rows.append("{id:'\(tab.id.uuidString)', title:\(title), active:\(active), dirty:\(dirty)}")
        }
        let arr = "[" + rows.joined(separator: ",") + "]"
        webView.evaluateJavaScript("window.creamyAPI.setTabs(\(arr))")
    }

    // MARK: Public load-when-ready entry points (used by AppDelegate dedup)

    func openLocalAsNewTab(_ url: URL) {
        if !jsReady { pendingFileToOpen = url; return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let tab = Tab(source: .local(url), content: content, isDirty: false)
            addTabAndActivate(tab)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            showError("Could not read file: \(error.localizedDescription)")
        }
    }

    func openRemoteAsNewTab(_ remote: SSHPath) {
        if !jsReady { pendingRemoteToOpen = remote; return }
        // Create a placeholder tab synchronously so the user sees the strip update;
        // fill in content once the SSH read returns.
        let tab = Tab(source: .remote(remote), content: "", isDirty: false)
        tabs.append(tab)
        webView.evaluateJavaScript("window.creamyAPI.openTab('\(tab.id.uuidString)', '', \(encodeForJS(remote.display)))")
        activeTabId = tab.id
        webView.evaluateJavaScript("window.creamyAPI.activateTab('\(tab.id.uuidString)')")
        refreshTabStrip()
        updateTitle()
        beginRemoteRead(remote, into: tab)
    }

    private func beginRemoteRead(_ remote: SSHPath, into targetTab: Tab) {
        guard let window = window else { return }
        window.title = "Loading \(remote.display)…"

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.currentReadTask != nil else { return event }
            if event.keyCode == 53 {
                self.currentReadTask?.cancel()
                return nil
            }
            return event
        }

        let task = SSHIO.read(remote) { [weak self, weak targetTab] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.dismissReadProgress()
                switch result {
                case .success(let content):
                    guard let target = targetTab else { return }
                    target.content = content
                    target.isDirty = false
                    // Replace the tab's buffer. Safe even if active because
                    // it's a fresh, user-initiated load.
                    self.webView.evaluateJavaScript(
                        "window.creamyAPI.setTabContent('\(target.id.uuidString)', \(self.encodeForJS(content)), \(self.encodeForJS(remote.display)))"
                    )
                    self.updateTitle()
                    self.refreshTabStrip()
                    if let url = self.recentURL(for: remote) {
                        NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    }
                case .failure(let err):
                    if case SSHIO.SSHError.cancelled? = err as? SSHIO.SSHError {
                        // Roll back the placeholder tab.
                        if let target = targetTab, let idx = self.indexOfTab(id: target.id) {
                            self.tabs.remove(at: idx)
                            self.webView.evaluateJavaScript("window.creamyAPI.closeTab('\(target.id.uuidString)')")
                            if let last = self.tabs.last {
                                self.activeTabId = last.id
                                self.webView.evaluateJavaScript("window.creamyAPI.activateTab('\(last.id.uuidString)')")
                            } else {
                                self.activeTabId = nil
                            }
                            self.refreshTabStrip()
                            self.updateTitle()
                        }
                        return
                    }
                    self.updateTitle()
                    self.showSSHError(err, host: remote.host, path: remote.path)
                }
            }
        }
        currentReadTask = task

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

    // MARK: Menu actions (responder-chain, target = nil)

    @objc func performFind() {
        webView.evaluateJavaScript("window.find_open && window.find_open()")
    }

    @objc func showCheatsheet() {
        webView.evaluateJavaScript("window.cheatsheet_open && window.cheatsheet_open()")
    }

    @objc func newTab() {
        let tab = Tab(source: nil, content: "", isDirty: false)
        addTabAndActivate(tab)
    }

    @objc func closeTab() {
        guard let active = activeTab else {
            // No tabs — close the window.
            window?.performClose(nil)
            return
        }
        closeTabById(active.id)
    }

    @objc func selectNextTab() {
        guard !tabs.isEmpty, let activeId = activeTabId,
              let idx = indexOfTab(id: activeId) else { return }
        let next = (idx + 1) % tabs.count
        activateTab(id: tabs[next].id)
    }

    @objc func selectPrevTab() {
        guard !tabs.isEmpty, let activeId = activeTabId,
              let idx = indexOfTab(id: activeId) else { return }
        let prev = (idx - 1 + tabs.count) % tabs.count
        activateTab(id: tabs[prev].id)
    }

    @objc func selectTabAtIndex(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < tabs.count else { return }
        activateTab(id: tabs[idx].id)
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
            self.appDelegate.openOrFocusLocal(url)
        }
    }

    @objc func openRemote() {
        guard let window = window else { return }
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

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            let raw = combo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return }

            if raw.contains(":") {
                guard let remote = SSHPath.parse(raw) else {
                    self.showError("Invalid SSH path. Use [user@]host:/path/to/file.")
                    return
                }
                self.appDelegate.openOrFocusRemote(remote)
            } else {
                let host = raw
                let lastPath = UserDefaults.standard.string(forKey: "plume.lastDir.\(host)") ?? "."
                self.browseController = BrowseWindowController(host: host, initialPath: lastPath) { [weak self] picked in
                    self?.appDelegate.openOrFocusRemote(picked)
                    self?.browseController = nil
                }
                self.browseController?.showWindow(nil)
            }
        }
    }

    @objc func saveFile() {
        guard let tab = activeTab else { return }
        switch tab.source {
        case .some(let source):
            saveTab(tab, to: source)
        case .none:
            saveFileAs()
        }
    }

    @objc func saveFileAs() {
        guard let tab = activeTab, let window = window else { return }
        let panel = NSSavePanel()
        if let mdType = UTType(filenameExtension: "md") { panel.allowedContentTypes = [mdType] }
        panel.nameFieldStringValue = tab.source?.displayName ?? "Untitled.md"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            self.saveTab(tab, to: .local(url))
        }
    }

    /// Save a specific tab's content to a given file source. Updates the tab
    /// and refreshes the title bar / tab strip.
    func saveTab(_ tab: Tab, to source: FileSource) {
        webView.evaluateJavaScript("window.creamyAPI.getTabContent('\(tab.id.uuidString)')") { [weak self] result, _ in
            guard let self = self else { return }
            guard let content = result as? String else {
                self.showError("Could not read editor content."); return
            }
            tab.content = content
            switch source {
            case .local(let url):
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    tab.source = .local(url)
                    tab.isDirty = false
                    self.webView.evaluateJavaScript("window.creamyAPI.markTabClean('\(tab.id.uuidString)')")
                    self.updateTitle()
                    self.refreshTabStrip()
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                } catch {
                    self.showError("Could not save: \(error.localizedDescription)")
                }
            case .remote(let remote):
                SSHIO.write(content, to: remote) { writeResult in
                    DispatchQueue.main.async {
                        switch writeResult {
                        case .success:
                            tab.source = .remote(remote)
                            tab.isDirty = false
                            self.webView.evaluateJavaScript("window.creamyAPI.markTabClean('\(tab.id.uuidString)')")
                            self.updateTitle()
                            self.refreshTabStrip()
                        case .failure(let err):
                            self.showSSHError(err, host: remote.host, path: remote.path)
                        }
                    }
                }
            }
        }
    }

    /// Prompt-if-dirty around a specific tab. If clean, proceed immediately.
    func guardDirty(_ tab: Tab, proceed: @escaping () -> Void) {
        guard let window = window else { proceed(); return }
        if !tab.isDirty { proceed(); return }
        // Make this tab active so the user sees what they're being asked about.
        if activeTabId != tab.id {
            activateTab(id: tab.id)
        }
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
                self.saveThenContinue(tab, proceed)
            case .alertSecondButtonReturn:
                proceed()
            default:
                break
            }
        }
    }

    private func saveThenContinue(_ tab: Tab, _ proceed: @escaping () -> Void) {
        if let source = tab.source {
            webView.evaluateJavaScript("window.creamyAPI.getTabContent('\(tab.id.uuidString)')") { [weak self] result, _ in
                guard let self = self, let content = result as? String else { return }
                tab.content = content
                switch source {
                case .local(let url):
                    do {
                        try content.write(to: url, atomically: true, encoding: .utf8)
                        tab.isDirty = false
                        self.webView.evaluateJavaScript("window.creamyAPI.markTabClean('\(tab.id.uuidString)')")
                        self.updateTitle()
                        self.refreshTabStrip()
                        proceed()
                    } catch {
                        self.showError("Could not save: \(error.localizedDescription)")
                    }
                case .remote(let remote):
                    SSHIO.write(content, to: remote) { writeResult in
                        DispatchQueue.main.async {
                            switch writeResult {
                            case .success:
                                tab.isDirty = false
                                self.webView.evaluateJavaScript("window.creamyAPI.markTabClean('\(tab.id.uuidString)')")
                                self.updateTitle()
                                self.refreshTabStrip()
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
                self.webView.evaluateJavaScript("window.creamyAPI.getTabContent('\(tab.id.uuidString)')") { result, _ in
                    guard let content = result as? String else { return }
                    do {
                        try content.write(to: url, atomically: true, encoding: .utf8)
                        tab.source = .local(url)
                        tab.content = content
                        tab.isDirty = false
                        self.webView.evaluateJavaScript("window.creamyAPI.markTabClean('\(tab.id.uuidString)')")
                        self.updateTitle()
                        self.refreshTabStrip()
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
        let tab = activeTab
        switch tab?.source {
        case .local(let url):
            window.title = url.lastPathComponent
            window.representedURL = url
        case .remote(let remote):
            window.title = "ssh: \(remote.display)"
            window.representedURL = nil
        case .none, .some(_):
            window.title = tab?.title ?? "Untitled"
            window.representedURL = nil
        }
        window.isDocumentEdited = tab?.isDirty ?? false
    }

    /// Window-close gate: any dirty tab triggers a prompt for that tab.
    /// When the user closes the window (⇧⌘W or red button), we run through
    /// each dirty tab in order; the user can save, discard, or cancel each.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let dirty = tabs.first(where: { $0.isDirty }) {
            guardDirty(dirty) { [weak self] in
                guard let self = self else { return }
                // Remove the just-handled tab and recurse via window.performClose.
                if let idx = self.indexOfTab(id: dirty.id) {
                    self.tabs.remove(at: idx)
                    self.webView.evaluateJavaScript("window.creamyAPI.closeTab('\(dirty.id.uuidString)')")
                }
                if self.tabs.isEmpty {
                    self.window?.close()
                } else {
                    // More dirty tabs may remain — re-attempt the close.
                    self.window?.performClose(nil)
                }
            }
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        appDelegate.removeWindow(self)
        appDelegate.scheduleStateSave()
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
            // Payload: { tabId: "uuid" }
            if let dict = message.body as? [String: Any],
               let tabIdStr = dict["tabId"] as? String,
               let tabId = UUID(uuidString: tabIdStr),
               let tab = self.tab(withId: tabId) {
                if !tab.isDirty {
                    tab.isDirty = true
                    updateTitle()
                    refreshTabStrip()
                }
                appDelegate.scheduleStateSave()
            }
        case "ready":
            jsReady = true
            handleJSReady()
        case "openURL":
            if let s = message.body as? String, let url = URL(string: s) {
                NSWorkspace.shared.open(url)
            }
        case "tabAction":
            // Payload: { kind: "new"|"close"|"select", tabId: "uuid"|null }
            guard let dict = message.body as? [String: Any],
                  let kind = dict["kind"] as? String else { return }
            switch kind {
            case "new":
                newTab()
            case "select":
                if let tabIdStr = dict["tabId"] as? String, let tabId = UUID(uuidString: tabIdStr) {
                    activateTab(id: tabId)
                }
            case "close":
                if let tabIdStr = dict["tabId"] as? String, let tabId = UUID(uuidString: tabIdStr) {
                    closeTabById(tabId)
                }
            default:
                break
            }
        default:
            break
        }
    }

    private func handleJSReady() {
        if let records = pendingRestoreTabs, !records.isEmpty {
            pendingRestoreTabs = nil
            restoreTabs(records, activeIndex: pendingRestoreActiveIndex)
            return
        }
        if let url = pendingFileToOpen {
            pendingFileToOpen = nil
            openLocalAsNewTab(url)
            return
        }
        if let remote = pendingRemoteToOpen {
            pendingRemoteToOpen = nil
            openRemoteAsNewTab(remote)
            return
        }
        if shouldShowWelcomeIfNoPending {
            shouldShowWelcomeIfNoPending = false
            if appDelegate.shouldShowWelcomeAndConsume() {
                let tab = Tab(source: nil, content: AppDelegate.welcomeDocument, isDirty: true)
                addTabAndActivate(tab)
                return
            }
            // Fall through — open an empty Untitled.
            startsWithEmptyUntitled = true
        }
        if startsWithEmptyUntitled {
            startsWithEmptyUntitled = false
            let tab = Tab(source: nil, content: "", isDirty: false)
            addTabAndActivate(tab)
        }
    }

    /// Recreate tabs from saved records. Dirty tabs and untitled tabs use the
    /// persisted contentDraft; clean tabs reload from disk/SSH.
    private func restoreTabs(_ records: [PlumeState.TabRecord], activeIndex: Int) {
        for rec in records {
            let id = UUID(uuidString: rec.id) ?? UUID()
            switch rec.kind {
            case "local":
                if let urlStr = rec.url, let url = URL(string: urlStr) {
                    if rec.isDirty, let draft = rec.contentDraft {
                        let tab = Tab(id: id, source: .local(url), content: draft, isDirty: true)
                        tabs.append(tab)
                        let jsContent = encodeForJS(draft)
                        webView.evaluateJavaScript(
                            "window.creamyAPI.openTab('\(tab.id.uuidString)', \(jsContent), \(encodeForJS(url.path)))"
                        )
                    } else {
                        // Clean — reload from disk.
                        if let content = try? String(contentsOf: url, encoding: .utf8) {
                            let tab = Tab(id: id, source: .local(url), content: content, isDirty: false)
                            tabs.append(tab)
                            let jsContent = encodeForJS(content)
                            webView.evaluateJavaScript(
                                "window.creamyAPI.openTab('\(tab.id.uuidString)', \(jsContent), \(encodeForJS(url.path)))"
                            )
                        }
                    }
                }
            case "remote":
                if let ssh = rec.ssh {
                    let remote = SSHPath(user: ssh.user, host: ssh.host, path: ssh.path)
                    if rec.isDirty, let draft = rec.contentDraft {
                        let tab = Tab(id: id, source: .remote(remote), content: draft, isDirty: true)
                        tabs.append(tab)
                        let jsContent = encodeForJS(draft)
                        webView.evaluateJavaScript(
                            "window.creamyAPI.openTab('\(tab.id.uuidString)', \(jsContent), \(encodeForJS(remote.display)))"
                        )
                    } else {
                        // Clean — create placeholder tab and fire SSH read.
                        let tab = Tab(id: id, source: .remote(remote), content: "", isDirty: false)
                        tabs.append(tab)
                        webView.evaluateJavaScript(
                            "window.creamyAPI.openTab('\(tab.id.uuidString)', '', \(encodeForJS(remote.display)))"
                        )
                        beginRemoteRead(remote, into: tab)
                    }
                }
            default:
                // Untitled — only meaningful if we have a draft.
                let draft = rec.contentDraft ?? ""
                let tab = Tab(id: id, source: nil, content: draft, isDirty: rec.isDirty)
                tabs.append(tab)
                let jsContent = encodeForJS(draft)
                webView.evaluateJavaScript(
                    "window.creamyAPI.openTab('\(tab.id.uuidString)', \(jsContent), null)"
                )
            }
        }
        // If nothing restored (e.g. all local files vanished), open an empty Untitled.
        if tabs.isEmpty {
            let tab = Tab(source: nil, content: "", isDirty: false)
            addTabAndActivate(tab)
            return
        }
        let idx = max(0, min(activeIndex, tabs.count - 1))
        activeTabId = tabs[idx].id
        webView.evaluateJavaScript("window.creamyAPI.activateTab('\(tabs[idx].id.uuidString)')")
        refreshTabStrip()
        updateTitle()
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
        } else if chars == "\u{1B}" {
            window?.close()
        } else if chars == "\u{7F}" || (event.modifierFlags.contains(.command) && chars == "\u{F700}") {
            navigate(to: BrowseEntry(name: "..", isDirectory: true))
        } else {
            super.keyDown(with: event)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

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
