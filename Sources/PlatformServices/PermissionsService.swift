import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hidsystem

public enum PermissionStatus: String, Sendable {
    case granted
    case notGranted
    case requiresManualGrant
}

public struct PermissionSnapshot: Sendable {
    public let screenRecording: PermissionStatus
    public let accessibility: PermissionStatus
    public let inputMonitoring: PermissionStatus

    public init(
        screenRecording: PermissionStatus,
        accessibility: PermissionStatus,
        inputMonitoring: PermissionStatus
    ) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }
}

@MainActor
public protocol PermissionsService {
    func snapshot() -> PermissionSnapshot
    @discardableResult func requestScreenRecording() -> Bool
    @discardableResult func requestAccessibility() -> Bool
    @discardableResult func openScreenRecordingSettings() -> Bool
    @discardableResult func openAccessibilitySettings() -> Bool
    @discardableResult func openInputMonitoringSettings() -> Bool
}

@MainActor
public struct MacPermissionsService: PermissionsService {
    public init() {}

    public func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .notGranted,
            accessibility: isAccessibilityGranted() ? .granted : .notGranted,
            inputMonitoring: inputMonitoringStatus()
        )
    }

    @discardableResult
    public func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        let granted = CGRequestScreenCaptureAccess()
        return granted || openScreenRecordingSettings()
    }

    @discardableResult
    public func requestAccessibility() -> Bool {
        if isAccessibilityGranted() {
            return true
        }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        return granted || openAccessibilitySettings()
    }

    @discardableResult
    public func openScreenRecordingSettings() -> Bool {
        openSystemSettings(urlStrings: [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    @discardableResult
    public func openAccessibilitySettings() -> Bool {
        openSystemSettings(urlStrings: [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    @discardableResult
    public func openInputMonitoringSettings() -> Bool {
        openSystemSettings(urlStrings: [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    private func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    private func inputMonitoringStatus() -> PermissionStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .notGranted
        default:
            return .requiresManualGrant
        }
    }

    private func openSystemSettings(urlStrings: [String]) -> Bool {
        for urlString in urlStrings {
            guard let url = URL(string: urlString) else {
                continue
            }

            if NSWorkspace.shared.open(url) {
                return true
            }
        }

        return false
    }
}
