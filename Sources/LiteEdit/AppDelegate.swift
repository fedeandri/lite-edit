import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowController: MainWindowController?
    private var recentMenu: NSMenu!

    @discardableResult
    private func ensureWindowControllerReady() -> MainWindowController {
        // A cached controller whose window has gone away must not be reused —
        // reusing it is what leaves the app running with zero windows and no
        // way to get one back.
        if let wc = windowController, wc.window != nil {
            if !(wc.window?.isVisible ?? false) { wc.showWindow(nil) }
            return wc
        }
        let wc = MainWindowController()
        windowController = wc
        wc.showWindow(nil)
        wc.restoreSession()
        return wc
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditorShortcuts.install()
        buildMenu()
        _ = ensureWindowControllerReady()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.saveSession()
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
    @discardableResult
    private func handleOpen(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }

        let wc = ensureWindowControllerReady()
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        if isDir.boolValue {
            wc.openFolderDirect(url)
            return true
        }
        if Workspace.isWorkspaceFile(url), wc.openWorkspaceDirect(url) {
            return true
        }
        wc.openFile(url)
        return true
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
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("New File", #selector(doNew), "n"))
        fileMenu.addItem(item("Open...", #selector(doOpen), "o"))
        fileMenu.addItem(item("Open Folder...", #selector(doOpenFolder), "O"))
        fileMenu.addItem(item("Open Workspace...", #selector(doOpenWorkspace), ""))

        recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)

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
        ensureWindowControllerReady().openFolderDirect(url)
    }

    @objc private func openRecentWorkspace(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        ensureWindowControllerReady().openWorkspaceDirect(url)
    }

    @objc private func doClearRecent() {
        RecentItems.clearAll()
    }

    // MARK: - Actions

    @objc func doNew()           { ensureWindowControllerReady().newDocument() }
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
