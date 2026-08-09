# Workspaces and windows

How this fork opens projects, and why each piece is built the way it is. Upstream
(`arietan/lite-edit`) has none of this: it opens single files into one window.

## What "opening a project" means here

A **project** is a folder or a `.code-workspace` file. A **file** is anything else.
They are routed differently and always have been the point of the fork:

| Opened | Goes to |
|---|---|
| Folder | Its own window, sidebar rooted at that folder |
| `.code-workspace` | Its own window, one sidebar root per `folders[]` entry |
| Anything else | A tab in the window you are already in |

`AppDelegate.handleOpen(_:)` is the single funnel. Double-click, `open -a LiteEdit`,
`File → Open Folder…`, `File → Open Workspace…`, `Open Recent`, and right-click →
**Open Workspace** in the file tree all pass through it, so none of them can drift
into behaving differently. Menu and sidebar paths reach it through
`MainWindowController.openProjectHandler`, a closure the delegate installs on every
window it creates.

## Why folders did not open at all before

Two independent faults, both needed fixing:

1. **`Info.plist` declared no folder type.** It listed `public.text`,
   `public.plain-text` and `public.source-code` only. LaunchServices matches the
   target against that list *before* the app is involved, so `open -a LiteEdit
   <folder>` was dropped and nothing happened — no error, no window, nothing.
2. **`application(_:openFile:)` never checked for a directory.** It called
   `openFile()` on whatever it was handed, which would have read a folder as text.

`openFolderDirect(_:)` already existed and was already used by session restore. It
had simply never been connected to an incoming open event.

Both new document types are registered at **`LSHandlerRank: Alternate`**. LiteEdit
therefore appears in *Open With* without seizing the association from whatever the
user has set as default. Change the default deliberately, not by installing:

```sh
duti -s com.liteedit.app .code-workspace all   # LiteEdit opens them
duti -s com.vscodium     .code-workspace all   # hand them back
```

## Parsing `.code-workspace`

`Workspace.load(from:)` reads the file and returns nil for anything unusable, which
callers treat as "open it as text" — the right outcome when you are looking at a
workspace file that is broken.

- `folders[].path` is resolved absolute, `~`-prefixed, or **relative to the
  directory holding the workspace file**. `{"path": "."}` — the most common form —
  means the folder the file sits in.
- Folders that no longer exist are skipped; duplicates are collapsed. A file whose
  folders have all gone returns nil rather than an empty tree.
- Everything else in the file (`settings`, `extensions`, `launch`) is ignored. Those
  describe VS Code behaviour and have no meaning here.

**The format is JSONC, not JSON.** VS Code accepts `//` comments, `/* */` blocks and
trailing commas; `JSONSerialization` rejects all three. `stripJSONComments(_:)`
removes them with a scanner that tracks whether it is inside a string literal, so a
`//` inside a path is left alone. Without it, a hand-edited workspace file — which is
most of them — fails to open for no visible reason.

## Multi-root sidebar

`SidebarViewController` holds `rootFolderURLs: [URL]` and a flag:

- **One folder** — `rootItems` holds that folder's *children*, exactly as upstream.
  A single-folder workspace renders identically to opening the folder directly; only
  the header names the workspace.
- **Several folders** — `rootItems` holds the roots *themselves*, each an expandable
  top-level node, and `isMultiRoot` is set.

That flag exists because `revealFile(_:)` has to walk one level differently in each
case: with multiple roots it must first find the root containing the file and expand
it, then walk the remaining components inside it.

`rootFolderURL` remains as a computed first-element so single-root callers are
unchanged. Quick Open uses `rootFolderURLs` and searches every root, prefixing each
hit with its root's folder name when there is more than one — without the prefix two
files with the same relative path are indistinguishable in the list.

## One window per project

`AppDelegate` holds `[MainWindowController]`. `windowFor(project:)` decides where a
project lands, in order:

1. **A window already showing it** → focus that one. Reopening never duplicates.
2. **An untouched empty window** (`isUnusedScratch`: no folder, no workspace, one
   unmodified empty tab) → reuse it, so opening a project from a fresh launch does
   not strand a blank window.
3. Otherwise → a new window.

### Landing on the desktop you are looking at

A new window gets `.moveToActiveSpace` inserted into its `collectionBehavior`, is
ordered front, and then has the flag **removed** on the next runloop pass. Setting it
is what pulls the window to the current Space; leaving it set would make the window
follow the app between Spaces forever after, which is not what anyone wants from a
project window.

Ordering the target window front *before* calling `NSApp.activate` matters too —
activating first can raise an existing window on another Space and drag you there.

### Three bugs that only appear with more than one window

Each was invisible in the single-window design and would have surfaced immediately:

- **Identity comparison must resolve symlinks.** An Apple Event from a double-click
  delivers `/tmp/…`; the same path round-tripped through the session store comes back
  `/private/tmp/…`. `standardizedFileURL` does *not* reconcile these — it never
  resolves symlinks — so every reopen produced a duplicate window. Both sides now use
  `resolvingSymlinksInPath()`.
- **The `Cmd+P` monitor is app-wide.** `NSEvent.addLocalMonitorForEvents` is
  installed per window controller but fires for every event in the application, so
  N windows meant N Quick Open panels on one keystroke. The handler now ignores
  events whose `event.window` is not its own.
- **One frame autosave name cannot serve many windows.** Every window called
  `setFrameAutosaveName("MainWindow")` and they fought over the same stored rect.
  Only the first window uses the saved frame; the rest cascade off the previous one.

## Session persistence

`SessionWindows` is an array with one dictionary per open window — its workspace *or*
folder (never both; a workspace supersedes the folders it lists), open files, cursor
positions, active tab, zoom state. Every window is reopened on the next launch.

The older flat keys (`SessionWorkspace`, `SessionFolder`, `SessionFiles`, …) are still
read when that array is absent, so upgrading does not lose the open project.
`MainWindowController.restoreSession()` is exactly that fallback: it collects the flat
keys into a dictionary and hands it to the same `restore(from:)` the array path uses.

## Testing notes

There is no test target, and one cannot easily be added on this machine: `swift build`
reports `unable to lookup item 'PlatformPath'` because XCTest needs full Xcode rather
than the Command Line Tools.

Verify behaviour through **the app's own saved state**, not AppleScript. `System
Events` reports stale or missing window counts against this ad-hoc-signed bundle —
during development it claimed one window when two existed, and returned "invalid
index" seconds after successfully counting. Quitting and reading `SessionWindows` out
of `~/Library/Preferences/com.liteedit.app.plist` is reliable and tells you what each
window actually had open:

```sh
osascript -e 'tell application "LiteEdit" to quit'; sleep 4
python3 -c "import plistlib,os; d=plistlib.load(open(os.path.expanduser('~/Library/Preferences/com.liteedit.app.plist'),'rb')); print([w.get('SessionWorkspace') or w.get('SessionFolder') for w in d.get('SessionWindows',[])])"
```

## Build and install

```sh
./build.sh
rm -rf /Applications/LiteEdit.app && cp -r LiteEdit.app /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/LiteEdit.app
```

The `lsregister` step is required after any change to `Info.plist`'s document types —
without it macOS keeps serving the previously registered claims and the new ones look
broken. The bundle is **ad-hoc signed**, so macOS may prompt on first launch of a
rebuild; right-click → Open clears it.
