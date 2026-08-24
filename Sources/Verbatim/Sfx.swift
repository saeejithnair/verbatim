import AppKit

/// Sounds preloaded at launch — NSSound(named:) costs ~3 ms on first use,
/// which otherwise lands on the first keyDown.
enum Sfx {
    static let begin = NSSound(named: "Tink")
    static let landed = NSSound(named: "Pop")
    static let nevermind = NSSound(named: "Bottle")
    static let trouble = NSSound(named: "Basso")

    static func warm() {
        _ = (begin, landed, nevermind, trouble)
    }
}
