import AppKit

/// Listen-only CGEventTap watching flagsChanged for the configured modifier
/// key, reporting hold/release. Requires Accessibility (and possibly Input
/// Monitoring) permission.
///
/// Adapted from OpenSuperWhisper's ModifierKeyMonitor (MIT, Copyright (c)
/// 2024 OpenSuperWhisper).
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var selectedKey: ModifierKey = .none
    private var isPressed = false

    /// Callbacks receive the hardware event time (seconds of uptime), so
    /// press durations are measured from when the key moved, not from when a
    /// possibly-congested main thread got around to noticing.
    var onKeyDown: ((TimeInterval) -> Void)?
    var onKeyUp: ((TimeInterval) -> Void)?
    /// ⌘ + the hotkey (when the hotkey itself isn't a Command key).
    var onRepaste: (() -> Void)?

    private init() {}

    @discardableResult
    func start(modifierKey: ModifierKey) -> Bool {
        stop()
        guard modifierKey != .none else { return true }
        selectedKey = modifierKey

        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.reenableTap()
                    return Unmanaged.passUnretained(event)
                }
                monitor.handleFlagsChanged(event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("HotkeyMonitor: failed to create event tap — check Accessibility permission")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        isPressed = false
    }

    /// Called after AppState's watchdog synthesizes a release: the press
    /// state must agree, so a delayed real release event is filtered here
    /// instead of double-firing, and the next press still registers.
    func resetPressState() {
        isPressed = false
    }

    private func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == selectedKey.keyCode else { return }

        // Device-dependent bit, not the semantic mask: the other key of the
        // same pair (Left vs Right ⌥) must not mask this key's release.
        let pressed = (event.flags.rawValue & selectedKey.deviceMask) != 0
        let eventTime = TimeInterval(event.timestamp) / 1_000_000_000

        // ⌘ + hotkey = re-paste gesture, not a dictation. The matching
        // release is ignored because isPressed was never set.
        if pressed && !isPressed
            && selectedKey.cgEventFlag != .maskCommand
            && event.flags.contains(.maskCommand) {
            DispatchQueue.main.async { self.onRepaste?() }
            return
        }

        if pressed && !isPressed {
            isPressed = true
            DispatchQueue.main.async { self.onKeyDown?(eventTime) }
        } else if !pressed && isPressed {
            isPressed = false
            DispatchQueue.main.async { self.onKeyUp?(eventTime) }
        }
    }
}
