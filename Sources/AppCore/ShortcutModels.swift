import Foundation

public enum ShortcutAction: String, CaseIterable, Codable, Hashable, Sendable {
    case zoom
    case draw
    case breakTimer
    case liveZoom
    case liveDraw
    case record
    case cropRecord
    case windowRecord
    case snip
    case saveSnip
    case demoType
    case previousDemoType
    case panoramaSnip
    case ocrSnip

    public var title: String {
        switch self {
        case .zoom: "Zoom"
        case .draw: "Draw"
        case .breakTimer: "Break Timer"
        case .liveZoom: "Live Zoom"
        case .liveDraw: "Live Draw"
        case .record: "Record"
        case .cropRecord: "Crop Record"
        case .windowRecord: "Window Record"
        case .snip: "Snip"
        case .saveSnip: "Save Snip"
        case .demoType: "DemoType"
        case .previousDemoType: "Previous DemoType Snippet"
        case .panoramaSnip: "Panorama Snip"
        case .ocrSnip: "OCR Snip"
        }
    }
}

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)
}

public struct ShortcutBinding: Codable, Hashable, Sendable {
    public let key: String
    public let keyCode: UInt32
    public let modifiers: ShortcutModifiers

    public init(key: String, keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.key = key
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var windowsStyleDescription: String {
        var parts: [String] = []

        if modifiers.contains(.control) {
            parts.append("Ctrl")
        }
        if modifiers.contains(.option) {
            parts.append("Alt")
        }
        if modifiers.contains(.shift) {
            parts.append("Shift")
        }
        if modifiers.contains(.command) {
            parts.append("Cmd")
        }

        parts.append(key.uppercased())
        return parts.joined(separator: "+")
    }

    public static func parse(_ string: String) throws -> ShortcutBinding {
        let rawTokens = string
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let keyToken = rawTokens.last else {
            throw ShortcutBindingError.invalidFormat
        }

        var modifiers: ShortcutModifiers = []
        for token in rawTokens.dropLast() {
            switch token.lowercased() {
            case "ctrl", "control":
                modifiers.insert(.control)
            case "alt", "option":
                modifiers.insert(.option)
            case "shift":
                modifiers.insert(.shift)
            case "cmd", "command":
                modifiers.insert(.command)
            default:
                throw ShortcutBindingError.invalidModifier(token)
            }
        }

        let normalizedKey = keyToken.uppercased()
        guard let keyCode = ShortcutCatalog.keyCode(for: normalizedKey) else {
            throw ShortcutBindingError.unsupportedKey(normalizedKey)
        }

        return ShortcutBinding(key: normalizedKey, keyCode: keyCode, modifiers: modifiers)
    }
}

public enum ShortcutBindingError: Error, LocalizedError {
    case invalidFormat
    case invalidModifier(String)
    case unsupportedKey(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Shortcut format must look like Ctrl+1 or Ctrl+Alt+6."
        case let .invalidModifier(modifier):
            return "Unsupported modifier: \(modifier)"
        case let .unsupportedKey(key):
            return "Unsupported shortcut key: \(key)"
        }
    }
}

public enum ShortcutCatalog {
    private static let keyCodes: [String: UInt32] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4, "I": 34,
        "J": 38, "K": 40, "L": 37, "M": 46, "N": 45, "O": 31, "P": 35, "Q": 12, "R": 15,
        "S": 1, "T": 17, "U": 32, "V": 9, "W": 13, "X": 7, "Y": 16, "Z": 6
    ]

    public static let windowsEquivalentDefaults: [ShortcutAction: ShortcutBinding] = [
        .zoom: .init(key: "1", keyCode: 18, modifiers: [.control]),
        .draw: .init(key: "2", keyCode: 19, modifiers: [.control]),
        .breakTimer: .init(key: "3", keyCode: 20, modifiers: [.control]),
        .liveZoom: .init(key: "4", keyCode: 21, modifiers: [.control]),
        .liveDraw: .init(key: "4", keyCode: 21, modifiers: [.control, .shift]),
        .record: .init(key: "5", keyCode: 23, modifiers: [.control]),
        .cropRecord: .init(key: "5", keyCode: 23, modifiers: [.control, .shift]),
        .windowRecord: .init(key: "5", keyCode: 23, modifiers: [.control, .option]),
        .snip: .init(key: "6", keyCode: 22, modifiers: [.control]),
        .saveSnip: .init(key: "6", keyCode: 22, modifiers: [.control, .shift]),
        .demoType: .init(key: "7", keyCode: 26, modifiers: [.control]),
        .previousDemoType: .init(key: "7", keyCode: 26, modifiers: [.control, .shift]),
        .panoramaSnip: .init(key: "8", keyCode: 28, modifiers: [.control]),
        .ocrSnip: .init(key: "6", keyCode: 22, modifiers: [.control, .option]),
    ]

    public static var orderedDefaults: [(ShortcutAction, ShortcutBinding)] {
        ShortcutAction.allCases.compactMap { action in
            windowsEquivalentDefaults[action].map { (action, $0) }
        }
    }

    public static func keyCode(for key: String) -> UInt32? {
        keyCodes[key.uppercased()]
    }
}
