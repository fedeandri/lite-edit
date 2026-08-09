# Close Every LiteEdit Instance You Launch for a Test

Testing launch behaviour starts real LiteEdit windows on the user's screen, and each one steals
focus. **Every instance you start, you quit before you report.** Never leave one running for the
user to find, and never leave one for a later turn to clean up.

## Test against an isolated bundle, never the installed app

Copy `LiteEdit.app` aside and give the copy its own `CFBundleIdentifier`
(`com.liteedit.apptest`). It then has its own preferences domain and its own session, so the
user's running `/Applications/LiteEdit.app` is never quit, never overwritten, and never has its
saved session rewritten by a test. Full recipe: `docs/workspaces-and-windows.md` § Testing notes.

## Put the quit in the same script as the launch

A test that opens a window MUST NOT be able to finish without closing it. One script does launch,
wait, quit, and read the result — never a launch in one command and a quit in a later one.

```sh
osascript -e 'tell application id "com.liteedit.apptest" to quit'
```

## Tear the test bundle down when the tests end

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /tmp/LiteEditTest.app
rm -rf /tmp/LiteEditTest.app
defaults delete com.liteedit.apptest
```

Skipping `lsregister -u` leaves the test copy registered as a handler for folders and
`.code-workspace` files, so Finder can later open a deleted bundle.

## Verify before claiming the work is done

```sh
pgrep -lf LiteEdit
```

The output MUST be empty or list only `/Applications/LiteEdit.app`. Any other path is a stray
test instance — quit it now. If a test run died half-way, sweep before doing anything else.

## The user's installed instance

Installing a new build means quitting `/Applications/LiteEdit.app`, and Federico authorised that
on 2026-08-10: quit it, install, reopen it, and say so. Its session restore brings the windows
back. **Tests never touch it** — that is what the isolated bundle is for.

**Why:** stated 2026-08-10 — *"don't leave a thousand liteedit windows open after your tests"*.
Four cold-launch tests in one session each opened windows and pulled focus away from the user's
work. The guarantee wanted is that no test window outlives the turn that opened it.
