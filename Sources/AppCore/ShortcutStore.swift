import Foundation

public protocol ShortcutStore: Sendable {
    func binding(for action: ShortcutAction) -> ShortcutBinding
    func allBindings() -> [ShortcutAction: ShortcutBinding]
    func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) throws
    func setBindings(_ bindings: [ShortcutAction: ShortcutBinding]) throws
    func resetToDefaults() throws
}

public enum ShortcutStoreError: Error {
    case failedToEncode
}

public final class UserDefaultsShortcutStore: ShortcutStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let storageKey = "shortcutBindings"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func binding(for action: ShortcutAction) -> ShortcutBinding {
        allBindings()[action] ?? ShortcutCatalog.windowsEquivalentDefaults[action]!
    }

    public func allBindings() -> [ShortcutAction: ShortcutBinding] {
        guard
            let data = userDefaults.data(forKey: storageKey),
            let stored = try? decoder.decode([ShortcutAction: ShortcutBinding].self, from: data)
        else {
            return ShortcutCatalog.windowsEquivalentDefaults
        }

        return ShortcutCatalog.windowsEquivalentDefaults.merging(stored) { _, override in override }
    }

    public func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) throws {
        var bindings = allBindings()
        bindings[action] = binding
        try setBindings(bindings)
    }

    public func setBindings(_ bindings: [ShortcutAction: ShortcutBinding]) throws {
        guard let data = try? encoder.encode(bindings) else {
            throw ShortcutStoreError.failedToEncode
        }

        userDefaults.set(data, forKey: storageKey)
    }

    public func resetToDefaults() throws {
        try setBindings(ShortcutCatalog.windowsEquivalentDefaults)
    }
}
