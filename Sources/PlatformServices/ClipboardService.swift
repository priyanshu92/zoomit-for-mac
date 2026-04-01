import AppKit
import Foundation

@MainActor
public protocol ClipboardService {
    func copy(image: NSImage)
    func copy(text: String)
}

@MainActor
public struct MacClipboardService: ClipboardService {
    public init() {}

    public func copy(image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    public func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

