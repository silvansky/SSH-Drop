import AppKit
import Combine
import Foundation

@MainActor
final class TransferManager: ObservableObject {
    static let shared = TransferManager()

    @Published var host: String { didSet { defaults.set(host, forKey: "host") } }
    @Published var path: String { didSet { defaults.set(path, forKey: "path") } }
    @Published var hostHistory: [String] { didSet { defaults.set(hostHistory, forKey: "hostHistory") } }
    @Published var pasteHint = "Empty"
    @Published var pasteIsRichText = false
    @Published var log: [TransferItem] = []
    @Published var busy = false

    private let defaults = UserDefaults.standard
    private var lastChangeCount = NSPasteboard.general.changeCount

    private static let maxHistory = 5

    init() {
        host = defaults.string(forKey: "host") ?? ""
        path = defaults.string(forKey: "path") ?? ""
        hostHistory = defaults.stringArray(forKey: "hostHistory") ?? []
        SSHRunner.prewarm(host: host)
    }

    func prewarm() { SSHRunner.prewarm(host: host) }

    func selectHost(_ h: String) {
        host = h
        SSHRunner.prewarm(host: h)
    }

    private func rememberHost() {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        hostHistory = Array(([h] + hostHistory.filter { $0 != h }).prefix(Self.maxHistory))
    }

    struct TransferItem: Identifiable {
        let id = UUID()
        let name: String
        var state: State
        enum State: Equatable {
            case uploading, done(String), failed(String)
        }
    }

    struct PendingUpload {
        let url: URL
        let temp: Bool
    }

    // MARK: Pasteboard

    func refreshPasteHint() {
        pasteHint = PasteboardReader.hint()
        pasteIsRichText = PasteboardReader.isRichText()
    }

    func pollPasteboard() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        refreshPasteHint()
    }

    func paste() { paste(PasteboardReader.read) }

    func pastePlain() { paste(PasteboardReader.readPlainText) }

    /// ⌘V default: strip formatting from rich text, otherwise normal paste.
    func pasteFromKeyboard() {
        PasteboardReader.isRichText() ? pastePlain() : paste()
    }

    private func paste(_ reader: (NSPasteboard) throws -> PasteboardReader.Payload?) {
        do {
            guard let payload = try reader(.general) else {
                appendFailed(name: "Clipboard", message: "Nothing to paste"); return
            }
            trace("paste -> \(payload.urls.map(\.pathExtension))")
            enqueue(payload.urls.map { PendingUpload(url: $0, temp: payload.temp) })
        } catch {
            appendFailed(name: "Clipboard", message: error.localizedDescription)
        }
    }

    // MARK: Upload

    func handle(urls: [URL]) {
        enqueue(urls.map { PendingUpload(url: $0, temp: false) })
    }

    func handleDrop(_ uploads: [PendingUpload]) {
        guard !uploads.isEmpty else {
            appendFailed(name: "Drop", message: "Unsupported drop content"); return
        }
        enqueue(uploads)
    }

    private func enqueue(_ uploads: [PendingUpload]) {
        guard !uploads.isEmpty else { return }
        guard validate() else {
            for u in uploads where u.temp { removeTemp(u.url) }
            return
        }
        rememberHost()
        let host = self.host, path = self.path
        Task { await uploadBatch(uploads, host: host, path: path) }
    }

    private func validate() -> Bool {
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            appendFailed(name: "—", message: "Host is empty"); return false
        }
        if path.trimmingCharacters(in: .whitespaces).isEmpty {
            appendFailed(name: "—", message: "Path is empty"); return false
        }
        return true
    }

    private func uploadBatch(_ uploads: [PendingUpload], host: String, path: String) async {
        busy = true
        defer { busy = false }
        let dir = Self.join(path, Self.dateFolder())
        var used = Set<String>()
        var remotePaths: [String] = []
        for item in uploads {
            trace("row+upload start: \(item.url.lastPathComponent)")
            let id = appendUploading(name: item.url.lastPathComponent)
            let isDir = Self.isDirectory(item.url)
            let remote = Self.join(dir, Self.uniqueName(for: item.url.lastPathComponent, isDirectory: isDir, in: &used))
            do {
                try await upload(item.url, to: remote, dir: dir, host: host, recursive: isDir)
                trace("upload done: \(remote)")
                remotePaths.append(remote)
                update(id, .done(remote))
            } catch {
                update(id, .failed(error.localizedDescription))
            }
            if item.temp { removeTemp(item.url) }
        }
        if !remotePaths.isEmpty { copyToClipboard(remotePaths.joined(separator: "\n")) }
    }

    private func removeTemp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func upload(_ url: URL, to remote: String, dir: String, host: String, recursive: Bool) async throws {
        try await SSHRunner.mkdir(host: host, dir: dir)
        trace("mkdir done, scp start")
        try await SSHRunner.scp(local: url, host: host, remote: remote, recursive: recursive)
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func copyToClipboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        lastChangeCount = pb.changeCount
    }

    // MARK: Naming

    static func dateFolder(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd-MM-yyyy"
        return f.string(from: date)
    }

    static func remoteName(for original: String, isDirectory: Bool = false,
                           timestamp: Int = Int(Date().timeIntervalSince1970)) -> String {
        // Don't split a folder name on dots (e.g. "my.assets" is not an extension).
        let ext = isDirectory ? "" : URL(fileURLWithPath: original).pathExtension
        let base = ext.isEmpty ? original : URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        return ext.isEmpty ? "\(base)_\(timestamp)" : "\(base)_\(timestamp).\(ext)"
    }

    /// Avoids same-second collisions within a batch (e.g. two unnamed pasted images).
    static func uniqueName(for original: String, isDirectory: Bool, in used: inout Set<String>) -> String {
        let name = remoteName(for: original, isDirectory: isDirectory)
        let ext = isDirectory ? "" : URL(fileURLWithPath: name).pathExtension
        let stem = ext.isEmpty ? name : URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        var candidate = name
        var n = 2
        while used.contains(candidate) {
            candidate = ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)"
            n += 1
        }
        used.insert(candidate)
        return candidate
    }

    static func join(_ a: String, _ b: String) -> String {
        a.hasSuffix("/") ? a + b : a + "/" + b
    }

    // MARK: Log

    @discardableResult
    private func appendUploading(name: String) -> UUID {
        let item = TransferItem(name: name, state: .uploading)
        log.insert(item, at: 0)
        return item.id
    }

    private func appendFailed(name: String, message: String) {
        log.insert(TransferItem(name: name, state: .failed(message)), at: 0)
    }

    private func update(_ id: UUID, _ state: TransferItem.State) {
        guard let i = log.firstIndex(where: { $0.id == id }) else { return }
        log[i].state = state
    }
}
