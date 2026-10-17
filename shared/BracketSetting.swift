//
//  BracketSetting.swift
//  extension_poc
//
//  Created by Reynard Amadeus  on 12/10/26.
//
//  Shared by the app AND the extension (both targets must include the `shared` folder).
//

import Foundation

/// Which words get added next to `{` and `}` so VoiceOver reads them.
nonisolated enum BracketSetting: String, CaseIterable, Identifiable {
    case beginEnd
    case startFinished

    var id: String { rawValue }

    /// Word placed after an opening brace.
    var openWord: String {
        switch self {
        case .beginEnd: return "begin"
        case .startFinished: return "started"
        }
    }

    /// Word placed after a closing brace.
    var closeWord: String {
        switch self {
        case .beginEnd: return "end"
        case .startFinished: return "finished"
        }
    }

    /// Label shown in the companion app.
    var label: String { "\(openWord) / \(closeWord)" }

    /// Every word any style can produce, so "Remove" cleans up both styles.
    static var allWords: Set<String> {
        Set(allCases.flatMap { [$0.openWord, $0.closeWord] })
    }
}
