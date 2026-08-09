import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowControllers: [MainWindowController] = []
    private var recentMenu: NSMenu!
    private var terminalMenu: NSMenu!
    private var terminalItem: NSMenuItem!
    private var fileMenu: NSMenu!

    private static let sessionWindowsKey = "SessionWindows"

    /// Drops controllers whose window has been closed. Called before anything
    /// that reasons about "the open windows".
    private func pruneClosedWindows() {
        windowControllers.removeAll { $0.window == nil }
    }

    /// The window a menu command or a loose file should act on: the key window,
    /// then the main window, then the most recently created one.
    private var activeWindowController: MainWindowController? {
        pruneClosedWindows()
        if let key = NSApp.keyWindow,
           let wc = windowControllers.first(where: { $0.window === key }) { return wc }
        if let main = NSApp.mainWindow,
           let wc = windowControllers.first(where: { $0.window === main }) { return wc }
        return windowControllers.last
    }

    @discardableResult
    private func ensureWindowControllerReady() -> MainWindowController {
        if let wc = activeWindowController {
            if !(wc.window?.isVisible ?? false) { wc.showWindow(nil) }
            return wc
        }
        return makeWindow()
    }

    /// Creates a window and brings it to the Space the user is looking at.
    /// `.moveToActiveSpace` is set only for the ordering, then removed, so the
    /// window afterwards stays on the desktop it was opened on instead of
    /// following the app around.
    @discardableResult
    private func makeWindow() -> MainWindowController {
        pruneClosedWindows()
        let wc = MainWindowController(cascadingFrom: windowControllers.last?.window)
        wc.openProjectHandler = { [weak self] url in self?.handleOpen(url) }
        windowControllers.append(wc)

        if let w = wc.window {
            w.collectionBehavior.insert(.moveToActiveSpace)
            wc.showWindow(nil)
            w.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { w.collectionBehavior.remove(.moveToActiveSpace) }
        } else {
            wc.showWindow(nil)
        }
        return wc
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditorShortcuts.install()
        buildMenu()
        restoreWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        pruneClosedWindows()
        let states = windowControllers.map { $0.sessionState() }
        UserDefaults.standard.set(states, forKey: Self.sessionWindowsKey)
    }

    /// Reopens one window per window that was open at quit. Falls back to the
    /// single-window keys written before multi-window support existed.
    private func restoreWindows() {
        let saved = UserDefaults.standard.array(forKey: Self.sessionWindowsKey) as? [[String: Any]] ?? []

        guard !saved.isEmpty else {
            let wc = makeWindow()
            wc.restoreSession()
            return
        }

        for state in saved {
            let wc = makeWindow()
            wc.restore(from: state)
        }
        windowControllers.first?.window?.makeKeyAndOrderFront(nil)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleOpen(URL(fileURLWithPath: filename))
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        var opened = false
        for name in filenames {
            if handleOpen(URL(fileURLWithPath: name)) { opened = true }
        }
        sender.reply(toOpenOrPrint: opened ? .success : .failure)
    }

    /// Brings a window back when the app is running with none — clicking the
    /// Dock icon is otherwise a dead end.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { ensureWindowControllerReady().showWindow(nil) }
        return true
    }

    /// Routes one path to the right opener: directory → folder tree,
    /// `.code-workspace` → workspace, anything else → text tab. A workspace
    /// file that will not parse falls through to being opened as text, which
    /// is what you want when you are looking at a broken one.
    ///
    /// Projects get a window each. Opening a second workspace never replaces
    /// the first — it opens beside it, on whichever desktop you are on.
    @discardableResult
    private func handleOpen(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }

        let isProject = isDir.boolValue || Workspace.isWorkspaceFile(url)

        if isProject {
            let target = windowFor(project: url)
            let opened = isDir.boolValue
                ? { target.openFolderDirect(url); return true }()
                : target.openWorkspaceDirect(url)

            if !opened {
                // Not a usable workspace after all — show the JSON instead.
                target.openFile(url)
            }
            target.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        let wc = ensureWindowControllerReady()
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        wc.openFile(url)
        return true
    }

    /// Picks the window a project should land in:
    /// already open somewhere → that window; an untouched empty window → reuse
    /// it rather than leave a blank one behind; otherwise a new window.
    private func windowFor(project url: URL) -> MainWindowController {
        pruneClosedWindows()
        // Must match openRootIdentity's normalisation, symlinks included.
        let identity = url.resolvingSymlinksInPath().standardizedFileURL.path

        if let existing = windowControllers.first(where: { $0.openRootIdentity == identity }) {
            return existing
        }
        if let scratch = windowControllers.first(where: { $0.isUnusedScratch }) {
            return scratch
        }
        return makeWindow()
    }

    // MARK: - Menu bar

    private func buildMenu() {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LiteEdit", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LiteEdit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // File menu
        let fileItem = NSMenuItem()
        fileMenu = NSMenu(title: "File")
        fileMenu.delegate = self
        // Enablement here is decided in updateTerminalItem, not by AppKit.
        // With auto-enabling on, "Open in Terminal" is disabled the moment it
        // carries a submenu instead of an action — which disables the submenu
        // with it, so the entries render but cannot be clicked.
        fileMenu.autoenablesItems = false
        fileMenu.addItem(item("New File", #selector(doNew), "n"))
        fileMenu.addItem(item("New Window", #selector(doNewWindow), "N"))
        fileMenu.addItem(item("Open...", #selector(doOpen), "o"))
        fileMenu.addItem(item("Open Folder...", #selector(doOpenFolder), "O"))
        fileMenu.addItem(item("Open Workspace...", #selector(doOpenWorkspace), ""))

        recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)

        fileMenu.addItem(.separator())

        // Fires directly for a single-root project; grows a submenu listing
        // every root when a multi-root workspace is open. Both are decided in
        // menuNeedsUpdate so the menu always reflects the current window.
        terminalItem = NSMenuItem(title: "Open in Terminal",
                                  action: #selector(doOpenInTerminal), keyEquivalent: "T")
        terminalItem.target = self
        terminalMenu = NSMenu(title: "Open in Terminal")
        terminalMenu.delegate = self
        // Items are built fresh in menuNeedsUpdate and are always actionable;
        // leaving auto-enabling on left every one of them greyed out.
        terminalMenu.autoenablesItems = false
        fileMenu.addItem(terminalItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Save", #selector(doSave), "s"))
        fileMenu.addItem(item("Save As...", #selector(doSaveAs), "S"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Close Tab", #selector(doClose), "w"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Edit menu
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // Find menu
        let findItem = NSMenuItem()
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(item("Find...", #selector(doFind), "f"))
        findMenu.addItem(item("Go to Line...", #selector(doGoToLine), "g"))
        findMenu.addItem(.separator())
        findMenu.addItem(item("Quick Open...", #selector(doQuickOpen), "p"))
        findItem.submenu = findMenu
        main.addItem(findItem)

        // View menu
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item("Toggle Sidebar", #selector(doToggleSidebar), "b"))
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Window menu
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        winItem.submenu = winMenu
        main.addItem(winItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = winMenu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    // MARK: - NSMenuDelegate (Open Recent)

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === fileMenu { updateTerminalItem(); return }
        if menu === terminalMenu { populateTerminalMenu(menu); return }
        guard menu === recentMenu else { return }
        menu.removeAllItems()

        let recentFiles = RecentItems.files
        let recentFolders = RecentItems.folders
        let recentWorkspaces = RecentItems.workspaces

        if recentWorkspaces.isEmpty && recentFolders.isEmpty && recentFiles.isEmpty {
            let empty = NSMenuItem(title: "No Recent Items", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        if !recentWorkspaces.isEmpty {
            let header = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for url in recentWorkspaces {
                let mi = NSMenuItem(title: url.deletingPathExtension().lastPathComponent,
                                    action: #selector(openRecentWorkspace(_:)), keyEquivalent: "")
                mi.target = self
                mi.toolTip = url.path
                mi.representedObject = url
                mi.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
                mi.image?.size = NSSize(width: 14, height: 14)
                menu.addItem(mi)
            }
        }

        if !recentFolders.isEmpty {
            if !recentWorkspaces.isEmpty { menu.addItem(.separator()) }
            let header = NSMenuItem(title: "Folders", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for url in recentFolders {
                let mi = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentFolder(_:)), keyEquivalent: "")
                mi.target = self
                mi.toolTip = url.path
                mi.representedObject = url
                mi.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                mi.image?.size = NSSize(width: 14, height: 14)
                menu.addItem(mi)
            }
        }

        if !recentFiles.isEmpty {
            if !recentFolders.isEmpty { menu.addItem(.separator()) }
            let header = NSMenuItem(title: "Files", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for url in recentFiles {
                let mi = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentFile(_:)), keyEquivalent: "")
                mi.target = self
                mi.toolTip = url.path
                mi.representedObject = url
                mi.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                mi.image?.size = NSSize(width: 14, height: 14)
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Recent", action: #selector(doClearRecent), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        ensureWindowControllerReady().openFile(url)
    }

    @objc private func openRecentFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        handleOpen(url)
    }

    @objc private func openRecentWorkspace(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        handleOpen(url)
    }

    @objc private func doClearRecent() {
        RecentItems.clearAll()
    }

    // MARK: - Open in Terminal

    /// One root opens straight from the menu item; several turn it into a
    /// submenu so the target is chosen explicitly. An item carrying a submenu
    /// cannot also fire an action, so the two are mutually exclusive.
    private func updateTerminalItem() {
        let roots = activeWindowController?.projectRoots ?? []
        terminalItem.isEnabled = !roots.isEmpty
        if roots.count > 1 {
            terminalItem.submenu = terminalMenu
            terminalItem.action = nil
        } else {
            terminalItem.submenu = nil
            terminalItem.action = #selector(doOpenInTerminal)
            terminalItem.target = self
        }
    }

    private func populateTerminalMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in activeWindowController?.projectRoots ?? [] {
            let mi = NSMenuItem(title: url.lastPathComponent,
                                action: #selector(openTerminalAtRoot(_:)), keyEquivalent: "")
            mi.target = self
            mi.toolTip = url.path
            mi.representedObject = url
            mi.isEnabled = true
            menu.addItem(mi)
        }
    }

    @objc private func doOpenInTerminal() {
        guard let url = activeWindowController?.projectRoots.first else { return }
        launchTerminal(at: url)
    }

    @objc private func openTerminalAtRoot(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        launchTerminal(at: url)
    }

    /// A terminal that silently fails to appear is near-impossible to diagnose,
    /// so the command and its exit status are shown rather than swallowed.
    private func launchTerminal(at url: URL) {
        do {
            try TerminalLauncher.open(directory: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not open a terminal"
            switch error {
            case TerminalLauncher.LaunchError.failed(let command, let status):
                alert.informativeText = "The command exited with status \(status):\n\n\(command)\n\n"
                    + "Change it with:\ndefaults write com.liteedit.app \(TerminalLauncher.defaultsKey) -string '<command>'"
            case TerminalLauncher.LaunchError.notRun(let command, let underlying):
                alert.informativeText = "\(underlying)\n\n\(command)"
            default:
                alert.informativeText = error.localizedDescription
            }
            alert.addButton(withTitle: "OK")
            if let w = activeWindowController?.window {
                alert.beginSheetModal(for: w, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }

    // MARK: - Actions

    @objc func doNew()           { ensureWindowControllerReady().newDocument() }
    @objc func doNewWindow()     { makeWindow() }
}

extension AppDelegate {
    @objc func doOpen()          { ensureWindowControllerReady().openDocument() }
    @objc func doOpenFolder()    { ensureWindowControllerReady().openFolder() }
    @objc func doOpenWorkspace() { ensureWindowControllerReady().openWorkspace() }
    @objc func doSave()          { ensureWindowControllerReady().saveDocument() }
    @objc func doSaveAs()        { ensureWindowControllerReady().saveDocumentAs() }
    @objc func doClose()         { ensureWindowControllerReady().closeCurrentTab() }
    @objc func doFind()          { ensureWindowControllerReady().showFind() }
    @objc func doGoToLine()      { ensureWindowControllerReady().showGoToLine() }
    @objc func doQuickOpen()     { ensureWindowControllerReady().showQuickOpen() }
    @objc func doToggleSidebar() { ensureWindowControllerReady().toggleSidebar() }
}
