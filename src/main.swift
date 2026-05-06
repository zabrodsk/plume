import Cocoa
import WebKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, NSWindowDelegate {

    var window: NSWindow!
    var webView: WKWebView!
    var currentFileURL: URL?
    var isDirty: Bool = false
    var pendingFileToOpen: URL?
    var jsReady: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupWindow()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if jsReady { loadFile(url) } else { pendingFileToOpen = url }
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
            self.currentFileURL = nil
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
            self.guardDirty { self.loadFile(url) }
        }
    }

    func loadFile(_ url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            currentFileURL = url
            isDirty = false
            let jsText = encodeForJS(content)
            let jsPath = encodeForJS(url.path)
            webView.evaluateJavaScript("window.creamyAPI.setContent(\(jsText), \(jsPath))")
            updateTitle()
        } catch {
            showError("Could not read file: \(error.localizedDescription)")
        }
    }

    @objc func saveFile() {
        if let url = currentFileURL { saveTo(url) } else { saveFileAs() }
    }

    @objc func saveFileAs() {
        let panel = NSSavePanel()
        if let mdType = UTType(filenameExtension: "md") { panel.allowedContentTypes = [mdType] }
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "Untitled.md"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            self.saveTo(url)
        }
    }

    func saveTo(_ url: URL) {
        webView.evaluateJavaScript("window.creamyAPI.getContent()") { [weak self] result, _ in
            guard let self = self else { return }
            guard let content = result as? String else {
                self.showError("Could not read editor content."); return
            }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                self.currentFileURL = url
                self.isDirty = false
                self.webView.evaluateJavaScript("window.creamyAPI.markClean()")
                self.updateTitle()
            } catch {
                self.showError("Could not save: \(error.localizedDescription)")
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
        let writeContent: (URL) -> Void = { [weak self] url in
            guard let self = self else { return }
            self.webView.evaluateJavaScript("window.creamyAPI.getContent()") { result, _ in
                if let text = result as? String {
                    do {
                        try text.write(to: url, atomically: true, encoding: .utf8)
                        self.currentFileURL = url
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
        if let url = currentFileURL {
            writeContent(url)
        } else {
            let panel = NSSavePanel()
            if let mdType = UTType(filenameExtension: "md") { panel.allowedContentTypes = [mdType] }
            panel.nameFieldStringValue = "Untitled.md"
            panel.beginSheetModal(for: window) { resp in
                if resp == .OK, let url = panel.url { writeContent(url) }
            }
        }
    }

    func updateTitle() {
        window.title = currentFileURL?.lastPathComponent ?? "Untitled"
        window.representedURL = currentFileURL
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
                loadFile(url)
            }
        default:
            break
        }
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
