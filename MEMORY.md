# Project Memory

## Current State
**This is `fedeandri/lite-edit`, a fork of `arietan/lite-edit`.** Forked 2026-08-09 from upstream `0787bd0` to add folder and `.code-workspace` opening plus one window per project. `upstream` remote points at `arietan/lite-edit`. **Do not send changes upstream** — the owner has decided this fork stays private to them; do not open a PR against `arietan/lite-edit` unless explicitly asked.

Native macOS code editor (~3,500 lines Swift/AppKit). Single binary under 1 MB (816 KB as built). Builds with `swift build` via `./build.sh`; **full Xcode is not installed and is not needed** — Command Line Tools suffice, but no XCTest target can be built here (`unable to lookup item 'PlatformPath'`).

Fork additions live in `Sources/LiteEdit/Workspace.swift` (new) and in changes to `AppDelegate`, `MainWindowController`, `SidebarViewController`, `QuickOpenPanel`, `RecentItems`, `build.sh`. Design and rationale: **`docs/workspaces-and-windows.md`** — read it before touching project opening or window management.

## Recent Changes
- 2026-08-10: **v1.4.0 (fork)** — `File → Open in Terminal` (Cmd+Shift+T). Launches a terminal at the project root; a multi-root workspace turns the item into a submenu of roots. The command is one `UserDefaults` string, `TerminalCommand`, defaulting to `open -na Ghostty --args --working-directory={dir} --title={name}`; `{dir}`/`{name}` are substituted shell-quoted and run via `/bin/sh -c`. **Menu-enablement trap:** with `autoenablesItems` on (the default), a menu item carrying a submenu instead of an action is disabled and takes its whole submenu with it — the entries render correctly and silently do nothing. `fileMenu` and `terminalMenu` both set it false and manage `isEnabled` themselves.
- 2026-08-09: **v1.3.0 (fork)** — one window per project. `AppDelegate` holds `[MainWindowController]`; `windowFor(project:)` focuses an already-open project, else reuses an untouched empty window, else opens a new one. New windows use `.moveToActiveSpace` (inserted, ordered front, then removed) so they land on the current desktop without following the app between Spaces afterwards. Session persistence became per-window (`SessionWindows` array; old flat keys still read as a fallback). `File → New Window` (Cmd+Shift+N). Three multi-window bugs fixed: symlink-insensitive identity comparison (`/tmp` vs `/private/tmp` — `standardizedFileURL` does not resolve symlinks, so every reopen duplicated a window), the app-wide `Cmd+P` monitor firing in all windows at once, and one shared `setFrameAutosaveName` making windows fight over a single rect.
- 2026-08-09: **v1.2.0 (fork)** — open folders and `.code-workspace` files. Upstream could not open folders at all: `Info.plist` declared only text UTIs so LaunchServices dropped the request before the app saw it, and `application(_:openFile:)` never checked `isDirectory`. `openFolderDirect()` already existed and was simply never wired to an open event. Added `public.folder`/`public.directory` and a `code-workspace` document type at `LSHandlerRank: Alternate` (so installing does not steal an existing default), a JSONC-tolerant workspace parser, a multi-root sidebar, Quick Open across all roots, `applicationShouldHandleReopen`, and a fix for `ensureWindowControllerReady()` reusing a controller whose window was gone (which left the app running with zero windows).
- 2026-04-21: **Released v1.1.6** — "Reveal in Finder" context menu for files and folders in the sidebar. Landing page and Homebrew cask updated.
- 2026-04-17: **Released v1.1.3** — large-file lazy highlighting, markdown live-rehighlight, tab-switch viewport restoration. Landing page updated. Publish-release skill created (replaces old release rule).
- 2026-04-14: Tab-switch cursor reset fix (v1.1.2) — two issues: (1) cursor jumped to line 1 because `replaceTextStorage()` triggers a deferred layout pass that resets NSTextView's selection after synchronous `restoreCursorPosition()`; fixed with `deferredRestoreCursor()` (async dispatch). (2) Scroll clamped to ~line 135 for deep positions because NSLayoutManager lazy layout left the text view frame too short; fixed with `ensureLayout(forCharacterRange:)` up to the saved cursor offset before scrolling.
- 2026-04-13: Tab indent/unindent — Tab with multi-line selection now indents all selected lines instead of deleting them. Shift+Tab unindents (removes one tab or up to 4 leading spaces). Handled in `EditorViewController+Shortcuts.swift` via keyCode 48 in `handleShortcutEvent`.
- 2026-04-13: Markdown highlighting fix — rewrote rules to fix bold/italic overlap (italic regex `\*text\*` was matching inside `**bold**`). Added negative lookaround on italic patterns, reordered rules so bold overrides italic. Added blockquotes, horizontal rules, ordered lists, underscore-based bold/italic, and image links.
- 2026-04-13: Tab-switch performance overhaul — three optimizations: (1) TabBarView uses smart diffing (`setTabs`/`selectTab`/`updateTab`) to avoid tearing down/rebuilding all subviews on every switch and keystroke; (2) SyntaxHighlighter instances cached per language (static dict) to avoid regex recompilation; (3) NSTextStorage cached per Document so switching to a previously-viewed tab swaps pre-highlighted storage via `layoutManager.replaceTextStorage()` instead of re-setting text + rehighlighting. Also fixed double-modified-indicator bug (● and • both shown).
- 2026-04-09: Landing page enhancements for awesome-mac traffic: added social proof badges (GitHub stars, awesome-mac featured, downloads, MIT), hero install command (`brew install --cask lite-edit`) with copy-to-clipboard, and a dedicated 3-column Install section (Homebrew / DMG / build from source). All in `docs/index.html`.
- 2026-04-09: Added auto-indent on Enter — new line inherits leading whitespace (spaces/tabs) from the current line. Implemented via `textView(_:shouldChangeTextIn:replacementString:)` delegate in `EditorViewController.swift`.

## Architecture Decisions
- **Fork:** Ghostty cannot be launched with a working directory any other way. Its CLI refuses to start the emulator on macOS, `+new-window` answers "not supported on this platform", and `open -a Ghostty <dir>` only activates the existing instance despite its `public.directory` claim. `open -na Ghostty --args --working-directory=…` is the documented and only working form.
- **Fork:** every path that opens a *project* (folder or workspace) funnels through `AppDelegate.handleOpen(_:)` — double-click, `open -a`, menus, Open Recent, and the sidebar context menu. Menu and sidebar paths reach it via `MainWindowController.openProjectHandler`, a closure the delegate installs on each window. Adding a new entry point means routing it there, not reimplementing placement.
- **Fork:** paths compared for "is this already open?" must go through `resolvingSymlinksInPath()`. Apple Events deliver `/tmp/…`, the session store returns `/private/tmp/…`, and `standardizedFileURL` does not reconcile them.
- **Fork:** `.code-workspace` is JSONC — comments and trailing commas are legal and `JSONSerialization` rejects them. `Workspace.stripJSONComments` handles it with a string-literal-aware scanner.
- **Fork:** verify multi-window behaviour by quitting and reading `SessionWindows` from `~/Library/Preferences/com.liteedit.app.plist`. `System Events`/AppleScript reports stale and missing window counts against this ad-hoc-signed bundle and will mislead you.
- **Fork:** re-run `lsregister -f /Applications/LiteEdit.app` after any `Info.plist` document-type change, or macOS keeps serving the old claims and the change looks broken.
- Pure AppKit + TextKit 1 (forced via `_ = textView.layoutManager`), no SwiftUI
- Global `NSEvent.addLocalMonitorForEvents` in `EditorShortcuts` handles shortcuts (Option+Up/Down, Cmd+Shift+K, Cmd+Shift+L)
- Multi-cursor edits bypass `didChangeText()` to avoid selection collapse from rehighlighting
- Auto-indent uses a `suppressAutoIndent` flag to prevent recursion when calling `insertText` from the delegate
- Tab switching uses NSTextStorage-per-document caching: each Document holds a `cachedTextStorage` that preserves text + highlighting attributes across tab switches. `loadDoc()` swaps via `layoutManager.replaceTextStorage()` for O(1) switches. Cursor/scroll restoration must be deferred (`DispatchQueue.main.async`) because `replaceTextStorage` invalidates layout asynchronously, resetting the selection.
- TabBarView exposes `setTabs(_:selectedIndex:)` (smart rebuild), `selectTab(at:)` (appearance only), `updateTab(at:item:)` (single tab label). Hot paths (tab click, keystroke) use targeted methods; structural changes (open/close tab) use `setTabs`.

## Known Issues & TODOs
- **Fork, unverified interactively** (wired and compiling, exercised only by code path): Quick Open prefixing hits with the root folder name in a multi-root window; right-click a `.code-workspace` inside the file tree → Open Workspace; new-window placement landing on the Space the double-click came from.
- **Fork:** a folder and its own `.code-workspace` file count as two different projects, so both can be open in separate windows at once. Identity is the opened path, and a human would call them the same project. Not yet decided whether that is worth collapsing.
- **Fork:** `TerminalCommand` is executable configuration run through `/bin/sh -c`. Values are shell-quoted so paths cannot inject, but the setting itself is trusted by design — the same trust level as a shell alias.
- **Fork:** a window whose saved workspace has since been deleted restores **empty** rather than reporting anything. Harmless, but a stale session can produce blank windows.
- Auto-indent is whitespace-matching only; no smart indent (e.g. increase after `{`)
- Markdown fenced code blocks may still lose highlighting when editing deep inside them (visible-range rehighlight helps but multi-page code blocks can exceed the viewport)
- Large files (> 100k chars) use lazy viewport-only highlighting; text outside the viewport + buffer stays unhighlighted until scrolled to
- Landing page: merged into awesome-mac (101k+ stars); remaining enhancement ideas: animated demo GIF/video, real cold-start benchmarks, honest "Not for you if..." section, mobile hamburger nav, JSON-LD structured data

## Key Files & Patterns
- `Sources/LiteEdit/Workspace.swift` — **fork**: `.code-workspace` parsing, JSONC comment/trailing-comma stripping, folder resolution
- `Sources/LiteEdit/TerminalLauncher.swift` — **fork**: `TerminalCommand` default, `{dir}`/`{name}` shell-quoted substitution, `/bin/sh -c` execution
- `Sources/LiteEdit/AppDelegate.swift` — **fork**: multi-window management (`windowControllers`, `windowFor(project:)`, `makeWindow()`), the `handleOpen(_:)` routing funnel, menu construction including the Open in Terminal submenu
- `docs/workspaces-and-windows.md` — **fork**: full design record; read before changing project opening, window placement, or menus
- `Sources/LiteEdit/EditorViewController.swift` — main text view, delegate, find/replace, auto-indent
- `Sources/LiteEdit/EditorViewController+Shortcuts.swift` — line move, delete, multi-cursor edit
- `Sources/LiteEdit/SyntaxHighlighter.swift` — regex-based highlighting for 20+ languages
- `Sources/LiteEdit/MainWindowController.swift` — window, tabs, session persistence
- `Sources/LiteEdit/SidebarViewController.swift` — file tree explorer

## Environment & Setup
- Requires macOS 13+, Xcode Command Line Tools, Swift 5.9
- Build: `swift build` or `bash build.sh`
- Run: `open LiteEdit.app`
