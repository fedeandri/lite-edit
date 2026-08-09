import Foundation

/// Opens a terminal at a directory by running a user-configured command.
///
/// The command lives in one `UserDefaults` key rather than a preferences UI,
/// which this app does not have:
///
/// ```sh
/// defaults write com.liteedit.app TerminalCommand -string \
///   'open -na Ghostty --args --working-directory={dir} --title={name}'
/// ```
///
/// `{dir}` and `{name}` are substituted **shell-quoted**, so a path containing
/// a space or an apostrophe cannot break the command or inject extra words.
/// The result runs through `/bin/sh -c`, so pipes, `&&` and environment
/// prefixes behave the way they are written.
///
/// Note this makes `TerminalCommand` executable configuration. That is the
/// same trust level as a shell alias — it is the user's own machine and their
/// own setting — but it is not inert data.
enum TerminalLauncher {
    static let defaultsKey = "TerminalCommand"

    /// Ghostty documents this as the way to launch it with arguments on macOS:
    /// its CLI refuses to start the emulator directly, and `+new-window`
    /// answers "not supported on this platform".
    static let defaultCommand =
        "open -na Ghostty --args --working-directory={dir} --title={name}"

    static var command: String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return defaultCommand }
        return stored
    }

    enum LaunchError: Error {
        case failed(command: String, status: Int32)
        case notRun(command: String, underlying: String)
    }

    /// Runs the configured command with `{dir}` and `{name}` filled in.
    static func open(directory url: URL) throws {
        let dir = url.path
        let name = url.lastPathComponent

        let rendered = command
            .replacingOccurrences(of: "{dir}", with: shellQuoted(dir))
            .replacingOccurrences(of: "{name}", with: shellQuoted(name))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", rendered]
        process.currentDirectoryURL = url

        do {
            try process.run()
        } catch {
            throw LaunchError.notRun(command: rendered, underlying: error.localizedDescription)
        }

        // `open` returns as soon as it has handed off to LaunchServices, so
        // waiting here costs nothing and catches a command that is simply wrong.
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LaunchError.failed(command: rendered, status: process.terminationStatus)
        }
    }

    /// Wraps a value in single quotes for `/bin/sh`, escaping any single quote
    /// by closing, emitting an escaped quote, and reopening: `'` → `'\''`.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
