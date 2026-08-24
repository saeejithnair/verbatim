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

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private init() {}

    func start(modifierKey: ModifierKey) {
        stop()
        guard modifierKey != .none else { return }
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
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
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

        let pressed = event.flags.contains(selectedKey.cgEventFlag)
        if pressed && !isPressed {
            isPressed = true
            DispatchQueue.main.async { self.onKeyDown?() }
        } else if !pressed && isPressed {
            isPressed = false
            DispatchQueue.main.async { self.onKeyUp?() }
        }
    }
}
