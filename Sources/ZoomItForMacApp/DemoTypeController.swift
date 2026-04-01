import AppKit
import AppCore
import PlatformServices

@MainActor
final class DemoTypeController {
    private let settingsStore: AppSettingsStore
    private let clipboardService: ClipboardService

    private var isActive = false
    private var backgroundThread: Thread?
    private var snippets: [String] = []
    private var currentSnippetIndex = 0
    private var escMonitor: Any?

    init(settingsStore: AppSettingsStore, clipboardService: ClipboardService) {
        self.settingsStore = settingsStore
        self.clipboardService = clipboardService
    }

    func toggle(accessibilityPermission: PermissionStatus) {
        // If the background thread finished, clean up stale state
        if isActive, let thread = backgroundThread, thread.isFinished {
            backgroundThread = nil
            isActive = false
        }

        if isActive {
            stop()
            return
        }

        guard accessibilityPermission == .granted else {
            NSSound.beep()
            return
        }

        start()
    }

    func moveToPreviousSnippet() {
        guard !isActive else {
            NSSound.beep()
            return
        }

        guard snippets.count > 1, currentSnippetIndex > 0 else {
            NSSound.beep()
            return
        }

        currentSnippetIndex -= 1
    }

    func dismiss() {
        stop()
    }

    private func start() {
        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
        let text: String
        if clipboardText.hasPrefix("[start]") {
            text = String(clipboardText.dropFirst("[start]".count))
        } else {
            let settings = settingsStore.load()
            text = settings.trimmedDemoTypeText
        }

        guard !text.isEmpty else {
            NSSound.beep()
            return
        }

        snippets = DemoTypeController.makeSnippets(from: text)
        currentSnippetIndex = 0

        let snippet = currentSnippetText
        isActive = true

        let charsPerTick = settingsStore.load().validatedDemoTypeCharactersPerTick
        let thread = Thread {
            // Wait for the Carbon hotkey key-up to fully settle
            Thread.sleep(forTimeInterval: 0.3)
            guard !Thread.current.isCancelled else { return }
            DemoTypeController.typeText(snippet, charsPerTick: charsPerTick)
        }
        thread.qualityOfService = .userInteractive
        backgroundThread = thread
        thread.start()

        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                DispatchQueue.main.async { self?.stop() }
            }
        }
    }

    private func stop() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        backgroundThread?.cancel()
        backgroundThread = nil
        isActive = false
    }

    private var currentSnippetText: String {
        guard snippets.indices.contains(currentSnippetIndex) else {
            return settingsStore.load().trimmedDemoTypeText
        }
        return snippets[currentSnippetIndex]
    }

    nonisolated private static func typeText(_ text: String, charsPerTick: Int) {
        let source = CGEventSource(stateID: .privateState)

        let scalars = Array(text.unicodeScalars)
        var index = 0

        while index < scalars.count {
            guard !Thread.current.isCancelled else { return }

            let end = min(index + charsPerTick, scalars.count)
            let chunk = scalars[index..<end]

            for scalar in chunk {
                if scalar == "\n" {
                    guard
                        let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
                        let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
                    else { continue }
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                } else if scalar == "\t" {
                    guard
                        let down = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: true),
                        let up = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: false)
                    else { continue }
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                } else {
                    let string = String(scalar)
                    guard
                        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                    else { continue }
                    down.keyboardSetUnicodeString(stringLength: string.utf16.count, unicodeString: Array(string.utf16))
                    up.keyboardSetUnicodeString(stringLength: string.utf16.count, unicodeString: Array(string.utf16))
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
            }

            index = end
            Thread.sleep(forTimeInterval: 0.04)
        }
    }

    nonisolated private static func makeSnippets(from text: String) -> [String] {
        var snippets: [String] = []
        var current: [String] = []

        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                let snippet = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !snippet.isEmpty {
                    snippets.append(snippet)
                }
                current.removeAll()
            } else {
                current.append(line)
            }
        }

        let trailingSnippet = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailingSnippet.isEmpty {
            snippets.append(trailingSnippet)
        }

        if snippets.isEmpty {
            return [text]
        }

        return snippets
    }
}
