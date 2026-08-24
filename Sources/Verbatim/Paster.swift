import AppKit
import Carbon

/// Pastes text into the frontmost app via the clipboard and a synthesized
/// Cmd+V, then restores the previous clipboard.
///
/// Adapted from OpenSuperWhisper's ClipboardUtil (MIT, Copyright (c) 2024
/// OpenSuperWhisper), minus its non-QWERTY layout handling.
enum Paster {
    /// Slow consumers (browsers, Electron apps) can service the synthesized
    /// Cmd+V long after the event is posted; restoring the clipboard earlier
    /// makes them paste the old contents instead of the transcription.
    static let restoreDelay: TimeInterval = 1.5

    /// The user's clipboard is snapshotted once per paste *burst*, not per
    /// paste: back-to-back dictations inside the restore window would
    /// otherwise snapshot the previous transcript and restore that instead
    /// of the user's data, destroying it. Main thread only.
    private static var savedSnapshot: [NSPasteboard.PasteboardType: Data]?
    private static var pendingRestore: DispatchWorkItem?

    /// Returns false when secure event input (password fields, some
    /// terminals, Cursor) would swallow the synthesized Cmd+V — the text is
    /// left on the clipboard instead of being silently lost.
    @discardableResult
    static func insertText(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general

        if IsSecureEventInputEnabled() {
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(text, forType: .string)
            return false
        }

        // Only the first paste of a burst sees the user's real clipboard.
        let midBurst = pendingRestore != nil
        pendingRestore?.cancel()
        pendingRestore = nil
        if !midBurst {
            savedSnapshot = savedContents(of: pasteboard)
        }

        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount

        sendCmdV()

        let work = DispatchWorkItem {
            pendingRestore = nil
            defer { savedSnapshot = nil }
            // A different changeCount means someone else took the clipboard;
            // restoring would clobber their data.
            guard pasteboard.changeCount == changeCount,
                  let snapshot = savedSnapshot, !snapshot.isEmpty else { return }
            pasteboard.declareTypes(Array(snapshot.keys), owner: nil)
            for (type, data) in snapshot {
                pasteboard.setData(data, forType: type)
            }
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
        return true
    }

    private static func sendCmdV() {
        let keyCodeV: CGKeyCode = 9  // QWERTY 'V'
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func savedContents(of pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType: Data]? {
        guard let types = pasteboard.types, !types.isEmpty else { return nil }
        var contents: [NSPasteboard.PasteboardType: Data] = [:]
        for type in types {
            if let data = pasteboard.data(forType: type) {
                contents[type] = data
            }
        }
        return contents.isEmpty ? nil : contents
    }
}
