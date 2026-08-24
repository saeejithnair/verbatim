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
}
