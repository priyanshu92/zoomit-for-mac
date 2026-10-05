import Foundation

/// Commands reachable through `zoomit://` URLs so launchers such as Raycast, Alfred,
/// Shortcuts, or a Stream Deck can drive the app. Every `ShortcutAction` is exposed under
/// its kebab-case name (`zoomit://ocr-snip`, `zoomit://break-timer`), plus a few commands
/// that only exist in the menu.
///
/// The scheme is declared under `CFBundleURLTypes` in the Info.plist that
/// `Scripts/install.sh` writes; `swift run` builds have no bundle and do not receive URLs.
public enum AppURLCommand: Equatable, Hashable, Sendable {
    case action(ShortcutAction)
    case textFromClipboard
    case textFromFile
    case textCaptureHistory
    case preferences

    public static let scheme = "zoomit"

    public static var allCommands: [AppURLCommand] {
        ShortcutAction.allCases.map(AppURLCommand.action) + [
            .textFromClipboard,
            .textFromFile,
            .textCaptureHistory,
            .preferences,
        ]
    }

    /// Accepts `zoomit://name`, `zoomit:name`, and `zoomit:///name`. Matching ignores case,
    /// hyphens, and underscores so `zoomit://OCR_Snip` and `zoomit://ocrsnip` both work.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else {
            return nil
        }

        let name: String
        if let host = url.host, !host.isEmpty {
            name = host
        } else {
            name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        self.init(name: name)
    }

    public init?(name: String) {
        let normalized = Self.normalized(name)
        guard !normalized.isEmpty else {
            return nil
        }

        if let command = Self.allCommands.first(where: { Self.normalized($0.name) == normalized }) {
            self = command
            return
        }

        if normalized == "settings" {
            self = .preferences
            return
        }

        return nil
    }

    public var name: String {
        switch self {
        case let .action(action): action.urlName
        case .textFromClipboard: "ocr-clipboard"
        case .textFromFile: "ocr-file"
        case .textCaptureHistory: "ocr-history"
        case .preferences: "preferences"
        }
    }

    public var url: URL {
        // `name` only ever contains lowercase ASCII letters and hyphens.
        URL(string: "\(Self.scheme)://\(name)")!
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0 != "-" && $0 != "_" }
    }
}

public extension ShortcutAction {
    /// Kebab-case form of the raw value, used for `zoomit://` URLs: `demoMirrorRegion`
    /// becomes `demo-mirror-region`.
    var urlName: String {
        var result = ""
        for character in rawValue {
            if character.isUppercase {
                result.append("-")
                result.append(contentsOf: character.lowercased())
            } else {
                result.append(character)
            }
        }
        return result
    }
}
