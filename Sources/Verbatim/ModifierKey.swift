import AppKit

// Adapted from OpenSuperWhisper (MIT, Copyright (c) 2024 OpenSuperWhisper).
enum ModifierKey: String, CaseIterable, Identifiable {
    case none
    case leftCommand, rightCommand
    case leftOption, rightOption
    case leftControl, rightControl
    case fn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Disabled"
        case .leftCommand: "Left ⌘ Command"
        case .rightCommand: "Right ⌘ Command"
        case .leftOption: "Left ⌥ Option"
        case .rightOption: "Right ⌥ Option"
        case .leftControl: "Left ⌃ Control"
        case .rightControl: "Right ⌃ Control"
        case .fn: "Fn"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .none: 0
        case .leftCommand: 55
        case .rightCommand: 54
        case .leftOption: 58
        case .rightOption: 61
        case .leftControl: 59
        case .rightControl: 62
        case .fn: 63
        }
    }

    var cgEventFlag: CGEventFlags {
        switch self {
        case .none: []
        case .leftCommand, .rightCommand: .maskCommand
        case .leftOption, .rightOption: .maskAlternate
        case .leftControl, .rightControl: .maskControl
        case .fn: .maskSecondaryFn
        }
    }

    /// The semantic masks above are side-agnostic — Left ⌥ held elsewhere
    /// keeps maskAlternate set while Right ⌥ is released, so a release check
    /// against them never fires. These NX device-dependent bits identify the
    /// exact key.
    var deviceMask: UInt64 {
        switch self {
        case .none: 0
        case .leftCommand: 0x0000_0008   // NX_DEVICELCMDKEYMASK
        case .rightCommand: 0x0000_0010  // NX_DEVICERCMDKEYMASK
        case .leftOption: 0x0000_0020    // NX_DEVICELALTKEYMASK
        case .rightOption: 0x0000_0040   // NX_DEVICERALTKEYMASK
        case .leftControl: 0x0000_0001   // NX_DEVICELCTLKEYMASK
        case .rightControl: 0x0000_2000  // NX_DEVICERCTLKEYMASK
        case .fn: CGEventFlags.maskSecondaryFn.rawValue  // only one Fn key
        }
    }
}
