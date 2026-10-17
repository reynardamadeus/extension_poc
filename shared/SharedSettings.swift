//
//  SharedSettings.swift
//  extension_poc
//
//  Settings written by the companion app and read by the Xcode extension.
//  They travel through an App Group, so BOTH targets need the App Groups
//  capability with exactly this identifier.
//

import Foundation

nonisolated enum SharedSettings {
    /// Team-ID-prefixed App Group (works on macOS without extra portal setup).
    static let appGroupID = "CWW22WYZK6.project.extension-poc"

    enum Key {
        static let style = "bracketStyle"
        static let includeContext = "includeContext"
        static let annotateNewBlocks = "annotateNewBlocks"
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    /// True when this process really has access to the App Group container.
    static var isAppGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    static var style: BracketSetting {
        BracketSetting(rawValue: defaults.string(forKey: Key.style) ?? "") ?? .beginEnd
    }

    static var includeContext: Bool {
        defaults.object(forKey: Key.includeContext) as? Bool ?? true
    }

    /// Whether "Open Block" adds begin/end comments to the braces it creates.
    static var annotateNewBlocks: Bool {
        defaults.object(forKey: Key.annotateNewBlocks) as? Bool ?? true
    }
}
