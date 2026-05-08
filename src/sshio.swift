import Foundation

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

// MARK: - SSH I/O

/// Shells out to /usr/bin/ssh. Zero bundled dependencies.
enum SSHIO {
    enum SSHError: LocalizedError {
        case nonZeroExit(code: Int32, stderr: String)
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .nonZeroExit(let c, let s):
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return "ssh exited with code \(c)." }
                return "ssh exited with code \(c): \(trimmed)"
            case .decodeFailed:
                return "Remote file is not valid UTF-8."
            }
        }
    }

    /// Read remote text file via `ssh host cat`.
    static func read(_ remote: SSHPath, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = sshArgs(for: remote.sshTarget) + [
                "cat", "--", shellQuote(remote.path)
            ]

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
                guard let text = String(data: data, encoding: .utf8) else {
                    completion(.failure(SSHError.decodeFailed))
                    return
                }
                completion(.success(text))
            } catch {
                completion(.failure(error))
            }
        }
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
