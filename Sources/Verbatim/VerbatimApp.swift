import AVFoundation
import SwiftUI

@MainActor
enum AppShared {
    static let state = AppState()
}

struct VerbatimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppShared.state

    var body: some Scene {
        Window("Verbatim", id: "main") {
            MainView(state: state)
        }
        .defaultSize(width: 520, height: 480)

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.menuIcon)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Sfx.warm()
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { NSLog("Microphone access denied") }
        }

        HotkeyMonitor.shared.onKeyDown = { eventTime in
            Task { @MainActor in AppShared.state.keyDown(at: eventTime) }
        }
        HotkeyMonitor.shared.onKeyUp = { eventTime in
            Task { @MainActor in AppShared.state.keyUp(at: eventTime) }
        }
        HotkeyMonitor.shared.onRepaste = {
            Task { @MainActor in AppShared.state.repasteLast() }
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        updateTrust()

        Task { @MainActor in await AppShared.state.recoverPendingAudio() }
    }

    /// Accessibility can be granted while the app runs, and tap creation can
    /// fail transiently (secure input, permission churn): poll until both the
    /// trust and the tap are live, so no relaunch is ever needed.
    private func updateTrust() {
        let trusted = AXIsProcessTrusted()
        var active = false
        if trusted {
            active = HotkeyMonitor.shared.start(modifierKey: Prefs.shared.hotkey)
        }
        Task { @MainActor in
            AppShared.state.accessibilityGranted = trusted
            AppShared.state.hotkeyActive = active
        }
        if trusted && active {
            trustTimer?.invalidate()
            trustTimer = nil
        } else if trustTimer == nil {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.updateTrust()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock click with no open windows: bring the main window back.
        if !flag {
            for window in sender.windows where window.identifier?.rawValue == "main" {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

/// The main window: live status on top, dictation history below.
struct MainView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var history = History.shared

    var body: some View {
        VStack(spacing: 0) {
            if !state.accessibilityGranted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Verbatim needs Accessibility access to see the hotkey and paste.")
                        .font(.callout)
                    Spacer()
                    Button("Open System Settings") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        NSWorkspace.shared.open(url)
                    }
                }
                .padding(10)
                .background(.yellow.opacity(0.12))
                Divider()
            }

            if state.accessibilityGranted && !state.hotkeyActive {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("The hotkey listener couldn't start. Toggle Accessibility off and on for Verbatim, then relaunch.")
                        .font(.callout)
                    Spacer()
                }
                .padding(10)
                .background(.yellow.opacity(0.12))
                Divider()
            }

            HStack(spacing: 10) {
                Image(systemName: state.menuIcon)
                    .font(.title3)
                    .foregroundStyle(state.iconColor)
                    .frame(width: 24)
                    .contentTransition(.symbolEffect(.replace))
                Text(state.statusLine)
                Spacer()
                SettingsLink { Text("Settings…") }
                    .keyboardShortcut(",")
            }
            .padding()

            Divider()

            StatsView()

            Divider()

            HistoryView()
        }
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState
    @ObservedObject private var history = History.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.statusLine)
        Text(String(format: "Total: %.1f min · ~$%.2f", history.totalSeconds / 60, history.totalCost))
        if !state.lastTranscript.isEmpty {
            Button("Copy last transcript") {
                let pasteboard = NSPasteboard.general
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(state.lastTranscript, forType: .string)
            }
        }
        Divider()
        Button("Open Verbatim") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("h")
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Verbatim") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
