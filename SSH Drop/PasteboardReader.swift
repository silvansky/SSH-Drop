import AppKit
import UniformTypeIdentifiers

enum PasteboardReader {
    struct Payload {
        let urls: [URL]
        let temp: Bool
    }

    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static func hint(_ pb: NSPasteboard = .general) -> String {
        let files = fileURLs(pb)
        if files.count == 1 { return "File: \(files[0].lastPathComponent)" }
        if files.count > 1 { return "\(files.count) files" }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) { return "Image" }
        if pb.data(forType: .rtf) != nil { return "Rich text" }
        if pb.string(forType: .string) != nil { return "Text" }
        if let type = pb.types?.first { return type.rawValue }
        return "Empty"
    }

    static func isRichText(_ pb: NSPasteboard = .general) -> Bool {
        fileURLs(pb).isEmpty && pb.data(forType: .rtf) != nil
    }

    /// Forces the plain-text representation of rich-text clipboard content.
    static func readPlainText(_ pb: NSPasteboard = .general) throws -> Payload? {
        if let string = pb.string(forType: .string), let data = string.data(using: .utf8) {
            return Payload(urls: [try writeTemp(data, name: "pasted_text", ext: "txt")], temp: true)
        }
        if let rtf = pb.data(forType: .rtf),
           let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           let data = attributed.string.data(using: .utf8) {
            return Payload(urls: [try writeTemp(data, name: "pasted_text", ext: "txt")], temp: true)
        }
        return nil
    }

    static func read(_ pb: NSPasteboard = .general) throws -> Payload? {
        let files = fileURLs(pb)
        if !files.isEmpty { return Payload(urls: files, temp: false) }

        if let png = pb.data(forType: .png) {
            return Payload(urls: [try writeTemp(png, name: "pasted_image", ext: "png")], temp: true)
        }
        if let tiff = pb.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return Payload(urls: [try writeTemp(png, name: "pasted_image", ext: "png")], temp: true)
        }
        if let rtf = pb.data(forType: .rtf) {
            return Payload(urls: [try writeTemp(rtf, name: "pasted_text", ext: "rtf")], temp: true)
        }
        if let s = pb.string(forType: .string), let data = s.data(using: .utf8) {
            return Payload(urls: [try writeTemp(data, name: "pasted_text", ext: "txt")], temp: true)
        }
        return nil
    }

    static func writeTemp(_ data: Data, name: String, ext: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).\(ext)")
        try data.write(to: url)
        return url
    }
}
