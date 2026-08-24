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
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.menuIcon)
        }

        Settings {
            SettingsView()
        }

        Window("Verbatim History", id: "history") {
            HistoryView()
        }
        .defaultSize(width: 480, height: 420)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { NSLog("Microphone access denied") }
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        if !AXIsProcessTrustedWithOptions(options as CFDictionary) {
            NSLog("Waiting for Accessibility permission")
        }

        HotkeyMonitor.shared.onKeyDown = {
            Task { @MainActor in AppShared.state.keyDown() }
        }
        HotkeyMonitor.shared.onKeyUp = {
            Task { @MainActor in AppShared.state.keyUp() }
        }
        HotkeyMonitor.shared.start(modifierKey: Prefs.shared.hotkey)
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
        Button("History…") {
            openWindow(id: "history")
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
