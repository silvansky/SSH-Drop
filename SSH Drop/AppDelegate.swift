import AppKit

/// Appends a timestamped line to /tmp/sshdrop-trace.log for debugging.
func trace(_ msg: String) {
    let line = "\(Date().timeIntervalSince1970) \(msg)\n"
    let url = URL(fileURLWithPath: "/tmp/sshdrop-trace.log")
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        trace("open event received: \(urls.map(\.lastPathComponent).joined(separator: ","))")
        TransferManager.shared.handle(urls: urls)
    }
}
