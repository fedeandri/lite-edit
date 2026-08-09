import AppKit

final class MainWindowController: NSWindowController,
    NSSplitViewDelegate,
    EditorViewControllerDelegate,
    TabBarViewDelegate,
    SidebarDelegate,
    FindBarDelegate,
    QuickOpenDelegate
{
    private var splitView: NSSplitView!
    private var sidebarVC: SidebarViewController!
    private var tabBar: TabBarView!
    private var findBar: FindBarView!
    private var editorVC: EditorViewController!
    private var statusBar: StatusBarView!

    private var quickOpen: QuickOpenPanel?
    private var keyMonitor: Any?

    private var documents: [Document] = []
    private var curIdx: Int = -1
    private var sidebarManuallyCollapsed = false

    /// The `.code-workspace` file backing the current sidebar, when one opened
    /// it. Nil whenever a plain folder is showing.
    private(set) var workspaceURL: URL?

    /// Set by the app delegate. Every request to open a *project* — a folder or
    /// a workspace — goes through here so window placement is decided in one
    /// place, whether it came from a double-click, a menu, or the file tree.
    var openProjectHandler: ((URL) -> Void)?

    private var curDoc: Document? {
        guard curIdx >= 0, curIdx < documents.count else { return nil }
        return documents[curIdx]
    }

    /// - Parameter cascadingFrom: when given, the new window is sized like that
    ///   window and offset down-right from it, so a second workspace is visibly
    ///   a second window rather than one exactly covering the other. Only the
    ///   first window uses the saved frame — sharing one autosave name across
    ///   windows makes them fight over the same stored rect.
    convenience init(cascadingFrom previous: NSWindow? = nil) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.minSize = NSSize(width: 640, height: 420)
        w.title = "LiteEdit"
        w.isReleasedWhenClosed = false

        if let prev = previous {
            w.setContentSize(prev.contentRect(forFrameRect: prev.frame).size)
            _ = w.cascadeTopLeft(from: NSPoint(x: prev.frame.minX, y: prev.frame.maxY))
        } else {
            if !w.setFrameUsingName("MainWindow") { w.center() }
            w.setFrameAutosaveName("MainWindow")
        }
        w.backgroundColor = Theme.background

        self.init(window: w)
        buildUI()
        newDocument()
        installKeyMonitor()
    }

    /// Identifies what this window has open, for spotting a second request to
    /// open the same thing. Nil when only loose files are open.
    ///
    /// Symlinks are resolved because the two sides genuinely disagree: an
    /// Apple Event from a double-click delivers `/tmp/…` while a path that has
    /// been through the session store is `/private/tmp/…`. `standardizedFileURL`
    /// alone does not reconcile them — it never resolves symlinks.
    var openRootIdentity: String? {
        (workspaceURL ?? sidebarVC.rootFolderURL)?.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A window that has never been used: no folder, no workspace, and nothing
    /// but the empty scratch tab. Reused instead of opening yet another window.
    var isUnusedScratch: Bool {
        guard workspaceURL == nil, sidebarVC.rootFolderURL == nil else { return false }
        guard documents.count <= 1 else { return false }
        guard let doc = documents.first else { return true }
        return doc.fileURL == nil && !doc.isModified && doc.content.isEmpty
    }

    deinit {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // The monitor is app-wide, so every window installs one. Without
            // this guard Cmd+P would fire Quick Open in all of them at once.
            guard event.window === self.window else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers == "p" {
                self.showQuickOpen()
                return nil
            }
            return event
        }
    }

    // MARK: - UI setup
    // Tab bar and status bar are OUTSIDE the NSSplitView (direct children of contentView).
    // This avoids NSSplitView layer compositing issues that made the tab bar invisible.

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        let tabH: CGFloat = 32
        let statusH: CGFloat = 24

        tabBar = TabBarView()
        tabBar.delegate = self
        tabBar.autoresizingMask = [.minYMargin]
        tabBar.frame = NSRect(x: 0, y: cv.bounds.height - tabH, width: cv.bounds.width, height: tabH)
        cv.addSubview(tabBar)

        statusBar = StatusBarView()
        statusBar.autoresizingMask = [.width, .maxYMargin]
        statusBar.frame = NSRect(x: 0, y: 0, width: cv.bounds.width, height: statusH)
        cv.addSubview(statusBar)

        findBar = FindBarView()
        findBar.delegate = self
        findBar.isHidden = true
        findBar.autoresizingMask = [.width, .minYMargin]
        findBar.frame = NSRect(x: 0, y: cv.bounds.height - tabH, width: cv.bounds.width, height: 0)
        cv.addSubview(findBar)

        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.autoresizingMask = [.width, .height]
        splitView.frame = NSRect(x: 0, y: statusH, width: cv.bounds.width, height: cv.bounds.height - tabH - statusH)
        cv.addSubview(splitView)

        sidebarVC = SidebarViewController()
        sidebarVC.sidebarDelegate = self
        let sideView = sidebarVC.view
        sideView.setFrameSize(NSSize(width: 220, height: splitView.bounds.height))

        editorVC = EditorViewController()
        editorVC.delegate = self
        let editorView = editorVC.view
        editorView.setFrameSize(NSSize(width: splitView.bounds.width - 221, height: splitView.bounds.height))

        splitView.addSubview(sideView)
        splitView.addSubview(editorView)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        updateTabBarFrame()

        DispatchQueue.main.async { [weak self] in
            self?.splitView.setPosition(220, ofDividerAt: 0)
        }
    }

    private func updateTabBarFrame() {
        guard let cv = window?.contentView else { return }
        let tabH: CGFloat = 32
        let editorX: CGFloat
        if sidebarVC.view.isHidden {
            editorX = 0
        } else {
            editorX = sidebarVC.view.frame.width + splitView.dividerThickness
        }
        tabBar.frame = NSRect(
            x: editorX,
            y: cv.bounds.height - tabH,
            width: cv.bounds.width - editorX,
            height: tabH
        )
    }

    // MARK: - Cursor persistence across tab switches

    private func saveCursorPosition() {
        guard let doc = curDoc else { return }
        doc.cursorPosition = editorVC.textView.selectedRange().location
        doc.scrollOffset = editorVC.scrollView.contentView.bounds.origin
    }

    private func restoreCursorPosition() {
        guard let doc = curDoc else { return }
        let tv = editorVC.textView!
        let sv = editorVC.scrollView!
        let len = (tv.string as NSString).length
        let pos = min(doc.cursorPosition, len)

        if let lm = tv.layoutManager, len > 0 {
            if doc.scrollOffset != .zero {
                // Full layout needed so the text view frame is tall enough
                // for the entire viewport, not just up to the cursor.
                lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: len))
            } else if pos > 0 {
                lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(pos + 1, len)))
            }
        }

        tv.setSelectedRange(NSRange(location: pos, length: 0))
        if doc.scrollOffset != .zero {
            sv.contentView.scroll(to: doc.scrollOffset)
            sv.reflectScrolledClipView(sv.contentView)
        } else {
            tv.scrollRangeToVisible(NSRange(location: pos, length: 0))
        }
    }

    /// Defers cursor restoration to the next run-loop iteration so it
    /// survives the layout pass that `replaceTextStorage` triggers.
    private func deferredRestoreCursor() {
        let targetDoc = curDoc
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.curDoc === targetDoc else { return }
            self.restoreCursorPosition()
        }
    }

    // MARK: - Document management

    func newDocument() {
        let doc = Document()
        documents.append(doc)
        curIdx = documents.count - 1
        editorVC.document = doc
        refreshTabs()
        refreshStatus()
    }

    func openDocument() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK else { return }
            p.urls.forEach { self?.openFile($0) }
        }
    }

    func openFile(_ url: URL) {
        if let i = documents.firstIndex(where: { $0.fileURL == url }) {
            saveCursorPosition()
            curIdx = i
            editorVC.document = documents[i]
            refreshTabs(); refreshStatus()
            RecentItems.addFile(url)
            sidebarVC.revealFile(url)
            deferredRestoreCursor()
            return
        }
        do {
            saveCursorPosition()
            let doc = try Document.open(url: url)
            documents.append(doc)
            curIdx = documents.count - 1
            editorVC.document = doc
            refreshTabs(); refreshStatus()
            window?.title = "LiteEdit — \(doc.displayName)"
            RecentItems.addFile(url)
            sidebarVC.revealFile(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func openFileInCurrentTab(_ url: URL) {
        if let i = documents.firstIndex(where: { $0.fileURL == url }) {
            saveCursorPosition()
            curIdx = i
            editorVC.document = documents[i]
            refreshTabs(); refreshStatus()
            window?.title = "LiteEdit — \(documents[i].displayName)"
            RecentItems.addFile(url)
            sidebarVC.revealFile(url)
            deferredRestoreCursor()
            return
        }
        do {
            saveCursorPosition()
            let doc = try Document.open(url: url)
            if curIdx >= 0, curIdx < documents.count {
                let cur = documents[curIdx]
                if !cur.isModified && (cur.fileURL == nil || cur.fileURL == url) {
                    documents[curIdx] = doc
                } else {
                    documents.append(doc)
                    curIdx = documents.count - 1
                }
            } else {
                documents.append(doc)
                curIdx = documents.count - 1
            }
            editorVC.document = doc
            refreshTabs(); refreshStatus()
            window?.title = "LiteEdit — \(doc.displayName)"
            RecentItems.addFile(url)
            sidebarVC.revealFile(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func saveDocument() {
        guard let doc = curDoc else { return }
        if doc.fileURL != nil {
            do { try doc.save(); refreshTabs() } catch { NSAlert(error: error).runModal() }
        } else { saveDocumentAs() }
    }

    func saveDocumentAs() {
        guard let doc = curDoc else { return }
        let p = NSSavePanel()
        p.canCreateDirectories = true
        p.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            do {
                try doc.save(to: url)
                self?.refreshTabs(); self?.refreshStatus()
                self?.window?.title = "LiteEdit — \(doc.displayName)"
                RecentItems.addFile(url)
            } catch { NSAlert(error: error).runModal() }
        }
    }

    func closeCurrentTab() {
        guard curIdx >= 0, curIdx < documents.count else { return }
        let doc = documents[curIdx]
        if doc.isModified {
            let a = NSAlert()
            a.messageText = "Save changes to \(doc.displayName)?"
            a.informativeText = "Your changes will be lost if you don't save them."
            a.addButton(withTitle: "Save")
            a.addButton(withTitle: "Don't Save")
            a.addButton(withTitle: "Cancel")
            let resp = a.runModal()
            if resp == .alertFirstButtonReturn { saveDocument() }
            else if resp == .alertThirdButtonReturn { return }
        }
        documents.remove(at: curIdx)
        if documents.isEmpty { newDocument(); return }
        curIdx = min(curIdx, documents.count - 1)
        editorVC.document = documents[curIdx]
        refreshTabs(); refreshStatus()
        deferredRestoreCursor()
    }

    func openFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let url = p.url, let self = self else { return }
            if let route = self.openProjectHandler { route(url) } else { self.showSidebarAndOpen(url) }
        }
    }

    func openFolderDirect(_ url: URL) {
        showSidebarAndOpen(url)
    }

    /// Opens a `.code-workspace` file. Returns false when the file is not a
    /// usable workspace, so callers can fall back to opening it as text.
    @discardableResult
    func openWorkspaceDirect(_ url: URL) -> Bool {
        guard let ws = Workspace.load(from: url) else { return false }
        workspaceURL = url
        RecentItems.addWorkspace(url)
        revealSidebar()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.sidebarVC.view.frame.width < 10 {
                self.splitView.setPosition(220, ofDividerAt: 0)
            }
            self.sidebarVC.openWorkspace(name: ws.name, folders: ws.folders)
            self.window?.title = "LiteEdit — \(ws.name)"
        }
        return true
    }

    func openWorkspace() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowsMultipleSelection = false
        p.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let url = p.url, let self = self else { return }
            if let route = self.openProjectHandler { route(url); return }
            if !self.openWorkspaceDirect(url) {
                let a = NSAlert()
                a.messageText = "Not a Workspace"
                a.informativeText = "\(url.lastPathComponent) is not a readable .code-workspace file, or none of the folders it lists exist."
                a.addButton(withTitle: "OK")
                a.beginSheetModal(for: self.window!, completionHandler: nil)
            }
        }
    }

    private func showSidebarAndOpen(_ url: URL) {
        workspaceURL = nil
        revealSidebar()
        RecentItems.addFolder(url)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.sidebarVC.view.frame.width < 10 {
                self.splitView.setPosition(220, ofDividerAt: 0)
            }
            self.sidebarVC.openFolder(url)
        }
    }

    private func revealSidebar() {
        sidebarManuallyCollapsed = false
        sidebarVC.view.isHidden = false
        splitView.adjustSubviews()
        splitView.setPosition(220, ofDividerAt: 0)
    }

    func toggleSidebar() {
        if sidebarVC.view.isHidden || splitView.isSubviewCollapsed(sidebarVC.view) {
            sidebarManuallyCollapsed = false
            sidebarVC.view.isHidden = false
            splitView.adjustSubviews()
            splitView.setPosition(220, ofDividerAt: 0)
        } else {
            sidebarManuallyCollapsed = true
            splitView.setPosition(0, ofDividerAt: 0)
            sidebarVC.view.isHidden = true
        }
        updateTabBarFrame()
    }

    func showFind() {
        guard let cv = window?.contentView else { return }
        let tabH: CGFloat = 32
        let findH: CGFloat = 34
        let statusH: CGFloat = 24
        findBar.isHidden = false
        findBar.frame = NSRect(x: 0, y: cv.bounds.height - tabH - findH, width: cv.bounds.width, height: findH)
        splitView.frame = NSRect(x: 0, y: statusH, width: cv.bounds.width, height: cv.bounds.height - tabH - findH - statusH)
        findBar.activate()
    }

    func showGoToLine() {
        let a = NSAlert()
        a.messageText = "Go to Line"
        a.addButton(withTitle: "Go")
        a.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "Line number"
        a.accessoryView = input
        a.beginSheetModal(for: window!) { [weak self] r in
            guard r == .alertFirstButtonReturn, let ln = Int(input.stringValue) else { return }
            self?.editorVC.goToLine(ln)
        }
    }

    func showQuickOpen() {
        guard let w = window else { return }
        let roots = sidebarVC.rootFolderURLs
        guard !roots.isEmpty else {
            let a = NSAlert()
            a.messageText = "No Folder Open"
            a.informativeText = "Open a folder (Cmd+Shift+O) or a workspace first to use Quick Open."
            a.addButton(withTitle: "OK")
            a.beginSheetModal(for: w, completionHandler: nil)
            return
        }

        if let qo = quickOpen, qo.isVisible {
            qo.orderOut(nil)
            w.removeChildWindow(qo)
            w.makeFirstResponder(editorVC.textView)
            return
        }

        if quickOpen == nil {
            quickOpen = QuickOpenPanel(relativeTo: w)
            quickOpen?.quickOpenDelegate = self
        } else {
            let panelW: CGFloat = 520
            let panelH: CGFloat = 340
            let x = w.frame.midX - panelW / 2
            let y = w.frame.maxY - panelH - 60
            quickOpen?.setFrame(NSRect(x: x, y: y, width: panelW, height: panelH), display: false)
        }
        quickOpen?.loadFiles(fromRoots: roots)
        quickOpen?.activate()
        w.addChildWindow(quickOpen!, ordered: .above)
        quickOpen?.makeKeyAndOrderFront(nil)
    }

    // MARK: - QuickOpenDelegate

    func quickOpenDidSelectFile(_ url: URL) {
        openFile(url)
    }

    func quickOpenDismissed() {
        if let qo = quickOpen { window?.removeChildWindow(qo) }
        window?.makeFirstResponder(editorVC.textView)
    }

    // MARK: - Refresh

    private func refreshTabs() {
        let items = documents.map { TabItem(title: $0.displayName, isModified: $0.isModified) }
        tabBar.setTabs(items, selectedIndex: curIdx)
    }

    private func refreshStatus() {
        if let doc = curDoc { statusBar.updateLanguage(doc.language) }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ sv: NSSplitView, constrainMinCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? 150 : pos
    }

    func splitView(_ sv: NSSplitView, constrainMaxCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? sv.bounds.width - 400 : pos
    }

    func splitView(_ sv: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === sidebarVC.view && sidebarManuallyCollapsed
    }

    func splitView(_ sv: NSSplitView, shouldCollapseSubview subview: NSView, forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        if subview === sidebarVC.view {
            sidebarManuallyCollapsed = true
            return true
        }
        return false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        updateTabBarFrame()
    }

    // MARK: - EditorViewControllerDelegate

    func editorTextDidChange(_ vc: EditorViewController) {
        if let doc = curDoc {
            tabBar.updateTab(at: curIdx, item: TabItem(title: doc.displayName, isModified: doc.isModified))
        }
    }
    func editorCursorMoved(_ vc: EditorViewController, line: Int, col: Int) { statusBar.updateCursor(line: line, col: col) }

    // MARK: - TabBarViewDelegate

    func tabBarDidSelectTab(at index: Int) {
        guard index >= 0, index < documents.count else { return }
        saveCursorPosition()
        curIdx = index
        editorVC.document = documents[index]
        tabBar.selectTab(at: curIdx)
        refreshStatus()
        window?.title = "LiteEdit — \(curDoc?.displayName ?? "Untitled")"
        if let url = documents[index].fileURL { sidebarVC.revealFile(url) }
        deferredRestoreCursor()
    }

    func tabBarDidCloseTab(at index: Int) {
        let prev = curIdx
        curIdx = index
        closeCurrentTab()
        if curIdx != prev { refreshTabs() }
    }

    // MARK: - SidebarDelegate

    func sidebarDidSelectFile(_ url: URL, inNewTab: Bool) {
        if inNewTab {
            openFile(url)
        } else {
            openFileInCurrentTab(url)
        }
    }

    func sidebarDidRequestOpenWorkspace(_ url: URL) {
        if let route = openProjectHandler { route(url); return }
        if !openWorkspaceDirect(url) {
            let a = NSAlert()
            a.messageText = "Not a Workspace"
            a.informativeText = "\(url.lastPathComponent) lists no folder that exists on disk."
            a.addButton(withTitle: "OK")
            if let w = window { a.beginSheetModal(for: w, completionHandler: nil) }
        }
    }

    // MARK: - FindBarDelegate

    func findBarNext(_ text: String, caseSensitive: Bool, regex: Bool) {
        _ = editorVC.findNext(text, caseSensitive: caseSensitive, regex: regex)
    }
    func findBarPrev(_ text: String, caseSensitive: Bool) {
        _ = editorVC.findPrev(text, caseSensitive: caseSensitive)
    }
    func findBarReplace(_ search: String, with replacement: String, caseSensitive: Bool) {
        _ = editorVC.replaceCurrent(search, with: replacement, caseSensitive: caseSensitive)
    }
    func findBarReplaceAll(_ search: String, with replacement: String, caseSensitive: Bool) {
        _ = editorVC.replaceAll(search, with: replacement, caseSensitive: caseSensitive)
    }
    func findBarDismissed() {
        guard let cv = window?.contentView else { return }
        let tabH: CGFloat = 32
        let statusH: CGFloat = 24
        findBar.isHidden = true
        findBar.frame.size.height = 0
        splitView.frame = NSRect(x: 0, y: statusH, width: cv.bounds.width, height: cv.bounds.height - tabH - statusH)
        window?.makeFirstResponder(editorVC.textView)
    }
    func findBarMatchCount(_ text: String, caseSensitive: Bool) -> Int {
        editorVC.matchCount(text, caseSensitive: caseSensitive)
    }

    // MARK: - Session persistence

    private static let sessionFolderKey    = "SessionFolder"
    private static let sessionWorkspaceKey = "SessionWorkspace"
    private static let sessionFilesKey   = "SessionFiles"
    private static let sessionIndexKey   = "SessionActiveIndex"
    private static let sessionCursorsKey = "SessionCursors"
    private static let sessionZoomedKey  = "SessionWindowZoomed"

    /// What this window is showing, as plist-safe values. One of these per open
    /// window is stored, so every window comes back on the next launch.
    func sessionState() -> [String: Any] {
        saveCursorPosition()
        var state: [String: Any] = [:]
        // Exactly one of the two: a workspace supersedes the folders it lists.
        if let ws = workspaceURL?.path {
            state[Self.sessionWorkspaceKey] = ws
        } else if let folder = sidebarVC.rootFolderURL?.path {
            state[Self.sessionFolderKey] = folder
        }
        state[Self.sessionFilesKey] = documents.compactMap { $0.fileURL?.path }
        state[Self.sessionIndexKey] = curIdx

        var cursors: [String: Int] = [:]
        for doc in documents {
            if let path = doc.fileURL?.path {
                cursors[path] = doc.cursorPosition
            }
        }
        state[Self.sessionCursorsKey] = cursors
        state[Self.sessionZoomedKey] = window?.isZoomed ?? false
        return state
    }

    /// Restores from the flat UserDefaults keys written by versions before
    /// multi-window support. Only used when no per-window list is present.
    func restoreSession() {
        let ud = UserDefaults.standard
        var legacy: [String: Any] = [:]
        if let v = ud.string(forKey: Self.sessionWorkspaceKey) { legacy[Self.sessionWorkspaceKey] = v }
        if let v = ud.string(forKey: Self.sessionFolderKey)    { legacy[Self.sessionFolderKey] = v }
        legacy[Self.sessionFilesKey]   = ud.stringArray(forKey: Self.sessionFilesKey) ?? []
        legacy[Self.sessionIndexKey]   = ud.integer(forKey: Self.sessionIndexKey)
        legacy[Self.sessionCursorsKey] = ud.dictionary(forKey: Self.sessionCursorsKey) as? [String: Int] ?? [:]
        legacy[Self.sessionZoomedKey]  = ud.bool(forKey: Self.sessionZoomedKey)
        restore(from: legacy)
    }

    func restore(from state: [String: Any]) {
        let folderPath    = state[Self.sessionFolderKey] as? String
        let workspacePath = state[Self.sessionWorkspaceKey] as? String
        let filePaths  = (state[Self.sessionFilesKey] as? [String] ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }

        guard workspacePath != nil || folderPath != nil || !filePaths.isEmpty else { return }

        // A saved workspace wins; a workspace that no longer parses falls back
        // to the saved folder rather than leaving the sidebar empty.
        var restoredSidebar = false
        if let wp = workspacePath, FileManager.default.fileExists(atPath: wp) {
            restoredSidebar = openWorkspaceDirect(URL(fileURLWithPath: wp))
        }
        if !restoredSidebar, let fp = folderPath, FileManager.default.fileExists(atPath: fp) {
            openFolderDirect(URL(fileURLWithPath: fp))
        }

        for path in filePaths {
            openFile(URL(fileURLWithPath: path))
        }

        if let i = documents.firstIndex(where: { $0.fileURL == nil && !$0.isModified && $0.content.isEmpty }),
           documents.count > 1 {
            documents.remove(at: i)
            if curIdx >= i && curIdx > 0 { curIdx -= 1 }
            if curIdx >= documents.count { curIdx = documents.count - 1 }
        }

        let cursors = state[Self.sessionCursorsKey] as? [String: Int] ?? [:]
        for doc in documents {
            if let path = doc.fileURL?.path, let pos = cursors[path] {
                doc.cursorPosition = pos
            }
        }

        let savedIdx = state[Self.sessionIndexKey] as? Int ?? 0
        curIdx = max(0, min(savedIdx, documents.count - 1))
        if curIdx < documents.count {
            editorVC.document = documents[curIdx]
        }
        refreshTabs()
        refreshStatus()
        if let name = curDoc?.displayName {
            window?.title = "LiteEdit — \(name)"
        }

        DispatchQueue.main.async { [weak self] in
            self?.restoreCursorPosition()
            if let url = self?.curDoc?.fileURL {
                self?.sidebarVC.revealFile(url)
            }
            if (state[Self.sessionZoomedKey] as? Bool ?? false), !(self?.window?.isZoomed ?? true) {
                self?.window?.zoom(nil)
            }
        }
    }
}
