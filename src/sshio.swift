import Foundation

// MARK: - Browse entry

struct BrowseEntry: Equatable {
    let name: String        // e.g. "notes" or "post.md"
    let isDirectory: Bool
    var isOpenable: Bool {  // .md / .markdown / .txt only
        guard !isDirectory else { return false }
        let lower = name.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown") || lower.hasSuffix(".txt")
    }
}

// MARK: - File source

enum FileSource {
    case local(URL)
    case remote(SSHPath)

    var displayName: String {
        switch self {
        case .local(let url):  return url.lastPathComponent
        case .remote(let p):   return "ssh: \(p.display)"
        }
    }
}

// MARK: - SSH path

struct SSHPath: Equatable {
    let user: String?
    let host: String
    let path: String

    var display: String {
        let u = user.map { "\($0)@" } ?? ""
        return "\(u)\(host):\(path)"
    }

    var sshTarget: String {
        let u = user.map { "\($0)@" } ?? ""
        return "\(u)\(host)"
    }

    /// Parse `[user@]host:path`. The first colon separates host from path.
    /// IPv6 in brackets and Windows-style colons are out of scope for v2.
    static func parse(_ raw: String) -> SSHPath? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let hostPart = String(trimmed[..<colon])
        let pathPart = String(trimmed[trimmed.index(after: colon)...])
        guard !hostPart.isEmpty, !pathPart.isEmpty else { return nil }

        if let at = hostPart.firstIndex(of: "@") {
            let user = String(hostPart[..<at])
            let host = String(hostPart[hostPart.index(after: at)...])
            guard !user.isEmpty, !host.isEmpty else { return nil }
            return SSHPath(user: user, host: host, path: pathPart)
        }
        return SSHPath(user: nil, host: hostPart, path: pathPart)
    }
}

// MARK: - SSH task (cancellation handle)

/// Calling cancel() sends SIGTERM to the underlying ssh subprocess, which causes
/// the completion handler to fire with .failure(SSHError.cancelled) shortly after.
final class SSHTask {
    private weak var process: Process?
    private(set) var isCancelled: Bool = false
    init(process: Process) { self.process = process }
    func cancel() {
        isCancelled = true
        process?.terminate()
    }
}

// MARK: - SSH I/O

/// Shells out to /usr/bin/ssh. Zero bundled dependencies.
enum SSHIO {
    enum SSHError: LocalizedError {
        case nonZeroExit(code: Int32, stderr: String)
        case decodeFailed
        case cancelled

        var errorDescription: String? {
            switch self {
            case .nonZeroExit(let c, let s):
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return "ssh exited with code \(c)." }
                return "ssh exited with code \(c): \(trimmed)"
            case .decodeFailed:
                return "Remote file is not valid UTF-8."
            case .cancelled:
                return "Cancelled."
            }
        }
    }

    /// Read remote text file via `ssh host cat`. Returns an SSHTask that can cancel
    /// the in-flight subprocess.
    @discardableResult
    static func read(_ remote: SSHPath, completion: @escaping (Result<String, Error>) -> Void) -> SSHTask {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = sshArgs(for: remote.sshTarget) + [
            "cat", "--", shellQuote(remote.path)
        ]

        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let task = SSHTask(process: proc)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try proc.run()
                proc.waitUntilExit()

                if task.isCancelled {
                    completion(.failure(SSHError.cancelled))
                    return
                }

                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

                if proc.terminationStatus != 0 {
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    completion(.failure(SSHError.nonZeroExit(code: proc.terminationStatus, stderr: err)))
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    completion(.failure(SSHError.decodeFailed))
                    return
                }
                completion(.success(text))
            } catch {
                completion(.failure(error))
            }
        }

        return task
    }

    /// Write remote text file atomically (write to .tmp, then mv).
    static func write(_ text: String, to remote: SSHPath, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

            let pid = ProcessInfo.processInfo.processIdentifier
            let pathQ = shellQuote(remote.path)
            let tmpQ  = shellQuote("\(remote.path).plume-tmp.\(pid)")
            let remoteCmd = "cat > \(tmpQ) && mv \(tmpQ) \(pathQ)"

            proc.arguments = sshArgs(for: remote.sshTarget) + [remoteCmd]

            let inPipe = Pipe(); let errPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardError = errPipe

            do {
                try proc.run()
                if let data = text.data(using: .utf8) {
                    try inPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try inPipe.fileHandleForWriting.close()
                proc.waitUntilExit()

                if proc.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    completion(.failure(SSHError.nonZeroExit(code: proc.terminationStatus, stderr: err)))
                    return
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// List a remote directory, returning sorted BrowseEntry values.
    /// Tries GNU ls flags first; falls back to BSD-compatible ls -1ap if the remote rejects them.
    static func list(host: String, path: String, completion: @escaping (Result<[BrowseEntry], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let quotedPath = shellQuote(path)
            // First attempt: GNU ls with long format for reliable type detection.
            let gnuArgs = sshArgs(for: host) + ["ls -lap --time-style=long-iso -- \(quotedPath)"]
            if let entries = runLS(host: host, args: gnuArgs, longFormat: true) {
                completion(.success(sortEntries(entries, path: path)))
                return
            }
            // Fallback: BSD ls (macOS remotes, older Linux) which rejects --time-style.
            let bsdArgs = sshArgs(for: host) + ["ls -1ap -- \(quotedPath)"]
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = bsdArgs
            let outPipe = Pipe(); let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus != 0 {
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    completion(.failure(SSHError.nonZeroExit(code: proc.terminationStatus, stderr: err)))
                    return
                }
                let stdout = String(data: data, encoding: .utf8) ?? ""
                let entries = parseShortFormat(stdout)
                completion(.success(sortEntries(entries, path: path)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Join a path component onto a base path. Handles ".." (go to parent) and trailing-slash normalisation.
    static func joinPath(_ base: String, _ component: String) -> String {
        if component == ".." {
            let parent = (base as NSString).deletingLastPathComponent
            return parent.isEmpty ? "/" : parent
        }
        let sep = base.hasSuffix("/") ? "" : "/"
        return base + sep + component
    }

    /// Map a raw SSH error into a human-readable (title, body) pair for NSAlert.
    static func describe(error: Error, host: String, path: String?) -> (title: String, body: String) {
        let location: String = {
            if let p = path { return "\(host):\(p)" }
            return host
        }()

        if let sshErr = error as? SSHError {
            switch sshErr {
            case .cancelled:
                return ("Cancelled", "")
            case .decodeFailed:
                return ("Encoding error", "Remote file is not valid UTF-8.")
            case .nonZeroExit(_, let stderr):
                if stderr.range(of: "permission denied", options: .caseInsensitive) != nil {
                    return ("Permission denied", location)
                }
                if stderr.range(of: "no such file or directory", options: .caseInsensitive) != nil {
                    return ("File not found", location)
                }
                if stderr.range(of: "connection timed out", options: .caseInsensitive) != nil ||
                   stderr.range(of: "operation timed out", options: .caseInsensitive) != nil {
                    return ("Connection timed out", "Couldn't reach \(host).")
                }
                if stderr.range(of: "could not resolve hostname", options: .caseInsensitive) != nil ||
                   stderr.range(of: "name or service not known", options: .caseInsensitive) != nil {
                    return ("Host unreachable", "\(host) — DNS lookup failed.")
                }
                if stderr.range(of: "connection refused", options: .caseInsensitive) != nil {
                    return ("Connection refused", "\(host) — is sshd running?")
                }
                if stderr.range(of: "host key verification failed", options: .caseInsensitive) != nil {
                    return ("Host key mismatch", "\(host) — your ~/.ssh/known_hosts may need updating.")
                }
            }
        }

        return ("SSH error", error.localizedDescription)
    }

    // Run ls with the given pre-built argument list; returns nil if ssh exits non-zero.
    private static func runLS(host: String, args: [String], longFormat: Bool) -> [BrowseEntry]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: data, encoding: .utf8) ?? ""
        return longFormat ? parseLongFormat(stdout) : parseShortFormat(stdout)
    }

    // Parse `ls -lap` long format. Each non-header line: permissions, links, user, group, size, date, time, name.
    private static func parseLongFormat(_ output: String) -> [BrowseEntry] {
        var entries: [BrowseEntry] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Skip the "total NNN" header line.
            if trimmed.hasPrefix("total ") { continue }
            let firstChar = trimmed.first ?? " "
            // We care about regular files (-), directories (d), and symlinks (l).
            guard firstChar == "-" || firstChar == "d" || firstChar == "l" else { continue }
            // Name is the last whitespace-separated field (after the time field).
            guard let name = extractName(from: trimmed, isLong: true) else { continue }
            let isDir = name.hasSuffix("/") || firstChar == "d"
            let cleanName = name.hasSuffix("/") ? String(name.dropLast()) : name
            if cleanName == "." || cleanName == ".." { continue }
            if cleanName.hasPrefix(".") && !isDir { continue }
            entries.append(BrowseEntry(name: cleanName, isDirectory: isDir))
        }
        return entries
    }

    // Parse `ls -1ap` short format. Each line is just the name with optional trailing "/".
    private static func parseShortFormat(_ output: String) -> [BrowseEntry] {
        var entries: [BrowseEntry] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let isDir = trimmed.hasSuffix("/")
            let cleanName = isDir ? String(trimmed.dropLast()) : trimmed
            if cleanName == "." || cleanName == ".." { continue }
            if cleanName.hasPrefix(".") && !isDir { continue }
            entries.append(BrowseEntry(name: cleanName, isDirectory: isDir))
        }
        return entries
    }

    // Extract the file name from a long-format ls line.
    // Name is the last token after the date+time fields (index 7+). Handle "name -> target" symlinks.
    private static func extractName(from line: String, isLong: Bool) -> String? {
        guard isLong else { return line.trimmingCharacters(in: .whitespaces) }
        let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        // Long format has at least 8 tokens: perms links user group size date time name...
        guard tokens.count >= 8 else { return nil }
        // Rejoin everything from index 7 onward (name may contain spaces).
        let namePart = tokens[7...].joined(separator: " ")
        // Strip symlink target: "name -> /target" → "name"
        if let arrowRange = namePart.range(of: " -> ") {
            return String(namePart[..<arrowRange.lowerBound])
        }
        return namePart
    }

    // Sort: ".." synthetic first, then real directories (alpha), then files (alpha).
    private static func sortEntries(_ raw: [BrowseEntry], path: String) -> [BrowseEntry] {
        var result: [BrowseEntry] = []
        // Add synthetic ".." unless we're at root.
        let normalised = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if normalised != "/" {
            result.append(BrowseEntry(name: "..", isDirectory: true))
        }
        let dirs  = raw.filter { $0.isDirectory  }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        let files = raw.filter { !$0.isDirectory }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        result += dirs + files
        return result
    }

    /// Common ssh flags. BatchMode prevents interactive password prompts (we want to fail
    /// fast rather than block the UI on a hidden tty); ConnectTimeout caps the wait.
    private static func sshArgs(for target: String) -> [String] {
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            // Reuse existing TCP+auth connection; %C hashes (local_user,host,port,remote_user).
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=/tmp/plume-%C",
            "-o", "ControlPersist=600",
            target
        ]
    }

    /// POSIX shell single-quote escape: wrap in '…', and escape embedded ' as '\''.
    private static func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - SSH config parser

/// Parses ~/.ssh/config for Host aliases useful as autocomplete candidates.
enum SSHConfig {
    /// Parse ~/.ssh/config and return literal Host aliases (no glob patterns).
    /// Returns [] if the file is missing or unreadable. Sorted, de-duplicated.
    static func hostAliases() -> [String] {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let raw = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }

        var seen = Set<String>()
        for line in raw.components(separatedBy: .newlines) {
            // Strip inline comments and trim.
            let stripped = line.components(separatedBy: "#").first ?? ""
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Accept both `Host foo` (whitespace) and `Host=foo` (equals) forms.
            let normalized = trimmed.replacingOccurrences(of: "=", with: " ")
            var tokens = normalized.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard tokens.count >= 2,
                  tokens[0].lowercased() == "host" else { continue }
            tokens.removeFirst()

            for token in tokens {
                // Skip glob patterns and negations — useless for autocomplete.
                guard !token.contains("*"), !token.contains("?"), !token.hasPrefix("!") else { continue }
                seen.insert(token)
            }
        }
        return seen.sorted { $0.lowercased() < $1.lowercased() }
    }
}
