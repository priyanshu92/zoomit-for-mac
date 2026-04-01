import AppCore
import Carbon
import Foundation

public protocol GlobalHotKeyCenter: AnyObject {
    var handler: (@Sendable (ShortcutAction) -> Void)? { get set }
    func registerBindings(_ bindings: [ShortcutAction: ShortcutBinding]) throws
    func unregisterAll()
}

public enum GlobalHotKeyError: Error {
    case failedToInstallHandler(OSStatus)
    case failedToRegisterHotKey(ShortcutAction, OSStatus)
}

public final class CarbonHotKeyCenter: GlobalHotKeyCenter {
    public var handler: (@Sendable (ShortcutAction) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actionByIdentifier: [UInt32: ShortcutAction] = [:]
    private var eventHandlerRef: EventHandlerRef?

    public init() throws {
        try installEventHandlerIfNeeded()
    }

    deinit {
        unregisterAll()
    }

    public func registerBindings(_ bindings: [ShortcutAction: ShortcutBinding]) throws {
        unregisterAll()
        try installEventHandlerIfNeeded()

        for (index, entry) in ShortcutCatalog.orderedDefaults.enumerated() {
            let action = entry.0
            guard let binding = bindings[action] else {
                continue
            }

            var hotKeyRef: EventHotKeyRef?
            let identifier = UInt32(index + 1)
            let hotKeyID = EventHotKeyID(signature: fourCharCode("ZMIT"), id: identifier)
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                carbonModifiers(for: binding.modifiers),
                hotKeyID,
                GetEventDispatcherTarget(),
                0,
                &hotKeyRef
            )

            guard status == noErr, let hotKeyRef else {
                throw GlobalHotKeyError.failedToRegisterHotKey(action, status)
            }

            hotKeyRefs.append(hotKeyRef)
            actionByIdentifier[identifier] = action
        }
    }

    public func unregisterAll() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        actionByIdentifier.removeAll()
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, userData in
            guard
                let event,
                let userData
            else {
                return OSStatus(eventNotHandledErr)
            }

            let center = Unmanaged<CarbonHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            return center.handleHotKeyEvent(event)
        }

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard status == noErr else {
            throw GlobalHotKeyError.failedToInstallHandler(status)
        }
    }

    private func handleHotKeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, let action = actionByIdentifier[hotKeyID.id] else {
            return status
        }

        handler?(action)
        return noErr
    }
}

private func carbonModifiers(for modifiers: ShortcutModifiers) -> UInt32 {
    var carbon: UInt32 = 0

    if modifiers.contains(.control) {
        carbon |= UInt32(controlKey)
    }
    if modifiers.contains(.option) {
        carbon |= UInt32(optionKey)
    }
    if modifiers.contains(.shift) {
        carbon |= UInt32(shiftKey)
    }
    if modifiers.contains(.command) {
        carbon |= UInt32(cmdKey)
    }

    return carbon
}

private func fourCharCode(_ string: StaticString) -> OSType {
    string.withUTF8Buffer { buffer in
        buffer.reduce(0) { partial, value in
            (partial << 8) + OSType(value)
        }
    }
}

