import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var manager: TransferManager
    @State private var dropTargeted = false
    private let hintTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            clipboardBar
            Form {
                TextField("Host", text: $manager.host, prompt: Text("alias or user@host"))
                TextField("Path", text: $manager.path, prompt: Text("/remote/dir"))
            }
            dropZone
            List(manager.log) { LogRow(item: $0) }
                .frame(maxHeight: .infinity)
                .overlay {
                    if manager.log.isEmpty {
                        Text("No transfers yet").foregroundStyle(.tertiary)
                    }
                }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 440)
        .background(PasteCatcher { manager.paste() })
        .onAppear { manager.refreshPasteHint(); manager.prewarm() }
        .onReceive(hintTimer) { _ in manager.pollPasteboard() }
    }

    private var clipboardBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clipboard").font(.caption).foregroundStyle(.secondary)
                Text(manager.pasteHint).font(.callout).lineLimit(1)
            }
            Spacer()
            Button { manager.paste() } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
            .frame(height: 110)
            .overlay {
                if manager.busy {
                    ProgressView()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc").imageScale(.large)
                        Text("Drop files here").foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { DropTargetView(targeted: $dropTargeted) { manager.handleDrop($0) } }
    }
}

/// AppKit drop target reading the raw dragging pasteboard, so image files keep
/// their file URL + name. SwiftUI's onDrop flattens images to nameless data.
struct DropTargetView: NSViewRepresentable {
    @Binding var targeted: Bool
    let onDrop: ([TransferManager.PendingUpload]) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DropView()
        view.targetedChanged = { targeted = $0 }
        view.onDrop = onDrop
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DropView else { return }
        view.targetedChanged = { targeted = $0 }
        view.onDrop = onDrop
    }

    final class DropView: NSView {
        var onDrop: (([TransferManager.PendingUpload]) -> Void)?
        var targetedChanged: ((Bool) -> Void)?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            targetedChanged?(true); return .copy
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { targetedChanged?(false) }
        override func draggingEnded(_ sender: NSDraggingInfo) { targetedChanged?(false) }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            targetedChanged?(false)
            guard let payload = try? PasteboardReader.read(sender.draggingPasteboard) else { return false }
            trace("ns drop: urls=\(payload.urls.map(\.lastPathComponent)) temp=\(payload.temp)")
            onDrop?(payload.urls.map { .init(url: $0, temp: payload.temp) })
            return true
        }
    }
}

struct LogRow: View {
    let item: TransferManager.TransferItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                detail
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .uploading: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var detail: some View {
        switch item.state {
        case .uploading:
            EmptyView()
        case .done(let path):
            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }
}

struct PasteCatcher: NSViewRepresentable {
    let onPaste: () -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(onPaste: onPaste) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onPaste = onPaste
    }

    final class CatcherView: NSView {
        var onPaste: () -> Void

        init(onPaste: @escaping () -> Void) {
            self.onPaste = onPaste
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers == "v" {
                if window?.firstResponder is NSText { return false }
                onPaste()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}

extension NSItemProvider {
    func loadFileURL() async -> URL? {
        guard canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// Writes dropped image content (e.g. a screenshot thumbnail) to a temp file.
    func loadImageTemp() async -> URL? {
        let base = imageBaseName
        for type in [UTType.png, UTType.jpeg, UTType.tiff] {
            guard hasItemConformingToTypeIdentifier(type.identifier),
                  let data = await loadData(type.identifier) else { continue }
            if type == .tiff, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                return try? PasteboardReader.writeTemp(png, name: base, ext: "png")
            }
            return try? PasteboardReader.writeTemp(data, name: base, ext: type.preferredFilenameExtension ?? "png")
        }
        if let image = await loadImage(), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return try? PasteboardReader.writeTemp(png, name: base, ext: "png")
        }
        return nil
    }

    private var imageBaseName: String {
        guard let name = suggestedName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "image" }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? "image" : base
    }

    private func loadData(_ identifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func loadImage() async -> NSImage? {
        guard canLoadObject(ofClass: NSImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: NSImage.self) { obj, _ in
                continuation.resume(returning: obj as? NSImage)
            }
        }
    }
}
