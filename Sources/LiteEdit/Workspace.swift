import Foundation

/// A parsed VS Code `.code-workspace` file.
///
/// The format is a JSON object with a `folders` array; each entry carries a
/// `path` that is either absolute, `~`-prefixed, or relative to the directory
/// holding the workspace file. Everything else in the file (`settings`,
/// `extensions`, `launch`, …) describes VS Code behaviour and is ignored here.
struct Workspace {
    /// The `.code-workspace` file itself.
    let url: URL
    /// Display name — the file name with its extension stripped.
    let name: String
    /// Folder roots, absolute and de-duplicated, in the order the file lists them.
    let folders: [URL]

    static let fileExtension = "code-workspace"

    static func isWorkspaceFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// Returns nil when the file is unreadable, is not valid JSON, or lists no
    /// folder that exists on disk. A nil result means "open it as a text file".
    static func load(from url: URL) -> Workspace? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let data = stripJSONComments(raw).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let obj = root as? [String: Any]
        else { return nil }

        let base = url.deletingLastPathComponent()
        var seen = Set<String>()
        var resolved: [URL] = []

        for entry in obj["folders"] as? [[String: Any]] ?? [] {
            guard let path = entry["path"] as? String, !path.isEmpty else { continue }
            let folder = absolute(path, relativeTo: base)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
                  isDir.boolValue,
                  seen.insert(folder.path).inserted
            else { continue }
            resolved.append(folder)
        }

        guard !resolved.isEmpty else { return nil }
        return Workspace(url: url,
                         name: url.deletingPathExtension().lastPathComponent,
                         folders: resolved)
    }

    private static func absolute(_ path: String, relativeTo base: URL) -> URL {
        if path.hasPrefix("~") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }

    // MARK: - JSONC

    /// `.code-workspace` files are JSONC: VS Code accepts `//` and `/* */`
    /// comments and trailing commas, all of which `JSONSerialization` rejects.
    /// Strips them while leaving string literals untouched.
    static func stripJSONComments(_ source: String) -> String {
        enum Mode { case code, string, lineComment, blockComment }

        var mode = Mode.code
        var escaped = false
        var out = ""
        out.reserveCapacity(source.count)

        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            switch mode {
            case .code:
                if c == "\"" {
                    mode = .string
                    escaped = false
                    out.append(c)
                } else if c == "/", next == "/" {
                    mode = .lineComment
                    i += 2
                    continue
                } else if c == "/", next == "*" {
                    mode = .blockComment
                    i += 2
                    continue
                } else {
                    if c == "}" || c == "]" { dropTrailingComma(&out) }
                    out.append(c)
                }

            case .string:
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { mode = .code }

            case .lineComment:
                if c == "\n" {
                    mode = .code
                    out.append(c)
                }

            case .blockComment:
                if c == "*", next == "/" {
                    mode = .code
                    i += 2
                    continue
                }
            }
            i += 1
        }
        return out
    }

    /// Removes the comma that would otherwise sit before a `}` or `]`,
    /// skipping back over whitespace.
    private static func dropTrailingComma(_ out: inout String) {
        var idx = out.endIndex
        while idx > out.startIndex {
            let prev = out.index(before: idx)
            let ch = out[prev]
            if ch == " " || ch == "\n" || ch == "\t" || ch == "\r" {
                idx = prev
                continue
            }
            if ch == "," { out.remove(at: prev) }
            return
        }
    }
}
