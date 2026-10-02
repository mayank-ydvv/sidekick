import AppKit
import AVFoundation
import ApplicationServices
import IOKit.hid

enum Permission: String, CaseIterable, Identifiable {
    case microphone, screenRecording, accessibility, inputMonitoring
    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "microphone"
        case .screenRecording: "screen recording"
        case .accessibility: "accessibility"
        case .inputMonitoring: "input monitoring"
        }
    }

    var why: String {
        switch self {
        case .microphone: "so i can hear you while you hold the talk keys. audio stays on your mac."
        case .screenRecording: "so i can see what you see — only while you hold the talk keys. screenshots are never saved."
        case .accessibility: "so the talk hotkey works everywhere and esc can stop me."
        case .inputMonitoring: "optional for now — needed later for teaching mode. if sidekick isn't listed, press + and pick it from Applications."
        }
    }

    /// Input Monitoring is only needed for listen-only taps (click observing, Phase 3+).
    /// The push-to-talk tap is an active tap, which runs on Accessibility.
    var isRequired: Bool { self != .inputMonitoring }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

enum PermissionsManager {
    static func isGranted(_ p: Permission) -> Bool {
        switch p {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }

    static var requiredGranted: Bool { Permission.allCases.filter(\.isRequired).allSatisfy(isGranted) }

    @MainActor
    static func request(_ p: Permission) {
        switch p {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                NSWorkspace.shared.open(p.settingsURL)
            }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(p.settingsURL) }
        case .accessibility:
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(opts) { NSWorkspace.shared.open(p.settingsURL) }
        case .inputMonitoring:
            if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) { NSWorkspace.shared.open(p.settingsURL) }
        }
    }
}
