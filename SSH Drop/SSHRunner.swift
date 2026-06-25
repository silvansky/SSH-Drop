import Foundation

enum SSHRunner {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // Multiplex connections so mkdir + scp (and repeat drops) reuse one SSH
    // handshake instead of paying ~1.4s each. %C keeps ControlPath short.
    static let sshOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=15",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=/tmp/sshdrop-%C",
        "-o", "ControlPersist=600",
    ]

    /// Opens the multiplex master ahead of a drop so the transfer starts instantly.
    static func prewarm(host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        Task { _ = try? await run("/usr/bin/ssh", sshOptions + [host, "true"]) }
    }

    static func mkdir(host: String, dir: String) async throws {
        try await run("/usr/bin/ssh", sshOptions + [host, "mkdir -p \(shellQuote(dir))"])
    }

    static func scp(local: URL, host: String, remote: String) async throws {
        // macOS scp uses the SFTP backend: the remote path is taken literally
        // (no remote shell), so it must NOT be shell-quoted.
        try await run("/usr/bin/scp", sshOptions + [local.path, "\(host):\(remote)"])
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = args
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { proc in
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure(message: msg.isEmpty ? "exit \(proc.terminationStatus)" : msg))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
