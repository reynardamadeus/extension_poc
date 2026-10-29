//
//  ErrorContext.swift
//  extension_poc
//
//  Turns a raw compiler error into a sentence that VoiceOver can read well.
//
//  The order is the one we agreed on for speech: WHAT is wrong first (so the user can stop
//  listening early), then WHERE (the line and the block it's in, in CodeVoice v3 style:
//  "func greet, inside struct Greeting"), then the CODE on that line, read last because it
//  is the longest and the user already hears it when VoiceOver reads the line.
//
//    "Missing closing brace. Line 14, in func greet, inside struct Greeting.
//     The block opened on line 9. Code: if isMorning {"
//
//  Punctuation is spelled out ("'}'" → "closing brace") so VoiceOver doesn't read
//  "quote right brace quote".
//

import Foundation

nonisolated enum ErrorContext {

    /// How much is spoken. Picked in the Mac app ("Error detail").
    nonisolated enum Detail: String, CaseIterable, Identifiable, Sendable {
        case brief, context, full
        var id: String { rawValue }
        var label: String {
            switch self {
            case .brief: return "Brief: message and line"
            case .context: return "Context: + the block it's in"
            case .full: return "Full: + the code on the line"
            }
        }
    }

    /// - lines: the file's text (the live editor text when it's the open file).
    /// - notes: compiler notes for this error, e.g. "to match this opening '{'" at line 9.
    static func spoken(_ error: WatchDiagnostic, lines: [String]?, detail: Detail) -> String {
        var parts = [sentence(friendly(error.message))]
        let index = error.line - 1
        var whereText = "Line \(error.line)"
        if detail != .brief, let lines, lines.indices.contains(index) {
            let chain = enclosingBlocks(in: lines, line: index)
            if let inner = chain.first {
                whereText += ", in \(inner)"
                if chain.count > 1 { whereText += ", inside \(chain[1])" }
            } else {
                whereText += ", at the top level"
            }
            if error.fileName != "" { whereText += ", \(spokenFileName(error.fileName))" }
        }
        parts.append(whereText + ".")
        if error.kind == .needsBuild { parts.append("This file changed after the last build. Press Command B to re-check.") }

        if detail == .full, let lines, lines.indices.contains(index) {
            if error.message.hasPrefix("expected '}'"), let opener = unclosedOpener(in: lines, before: index) {
                parts.append("The block opened on line \(opener + 1) is never closed.")
            }
            let code = lines[index].trimmingCharacters(in: .whitespaces)
            parts.append(code.isEmpty ? "The line is empty." : "Code: \(spokenCode(code)).")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Message rewording

    /// Common swiftc wording → plain speech. Unknown messages keep their words,
    /// with punctuation spelled out.
    static func friendly(_ message: String) -> String {
        let rules: [(prefix: String, say: String)] = [
            ("expected '}' in", "Missing closing brace"),
            ("expected '}'", "Missing closing brace"),
            ("expected ')' in", "Missing closing parenthesis"),
            ("expected ')'", "Missing closing parenthesis"),
            ("expected ']'", "Missing closing square bracket"),
            ("unterminated string literal", "This string is missing its closing quote"),
            ("consecutive statements on a line must be separated by ';'",
             "Two statements on one line. Put the second one on a new line"),
            ("extraneous '}' at top level", "Extra closing brace with nothing to close"),
            ("expected expression", "Something is missing here: Swift expected a value or expression"),
            ("expected declaration", "Swift expected a declaration here, like var, let or func"),
        ]
        for rule in rules where message.hasPrefix(rule.prefix) {
            let rest = message.dropFirst(rule.prefix.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return rule.say }
            // "expected '}' in struct" → "Missing closing brace for the struct"
            if rule.prefix.hasSuffix(" in") { return "\(rule.say) for the \(spokenPunctuation(rest))" }
            return "\(rule.say) \(spokenPunctuation(rest))"     // "…expression after operator"
        }
        if let name = firstMatch(#"^cannot find '([^']+)' in scope"#, in: message) {
            return "\(name) is not defined here. Check the spelling, or declare it first"
        }
        if let match = firstMatches(#"^cannot convert value of type '([^']+)' to (?:specified|expected argument) type '([^']+)'"#, in: message) {
            return "Wrong type: this is a \(match[0]), but a \(match[1]) is needed"
        }
        if let name = firstMatch(#"^use of unresolved identifier '([^']+)'"#, in: message) {
            return "\(name) is not defined here"
        }
        return spokenPunctuation(message)
    }

    /// 'x' quoted names lose their quotes; lone punctuation is spelled out.
    static func spokenPunctuation(_ text: String) -> String {
        let names: [String: String] = [
            "'{'": "opening brace", "'}'": "closing brace",
            "'('": "opening parenthesis", "')'": "closing parenthesis",
            "'['": "opening square bracket", "']'": "closing square bracket",
            "';'": "semicolon", "','": "comma", "':'": "colon", "'.'": "dot",
            "'='": "equals sign", "'->'": "arrow", "'\"'": "quote mark",
        ]
        var result = text
        for (symbol, word) in names { result = result.replacingOccurrences(of: symbol, with: word) }
        // Remaining 'name' → name
        result = result.replacingOccurrences(of: #"'([^'\s]+)'"#, with: "$1", options: .regularExpression)
        return result
    }

    // MARK: - Where: the enclosing blocks (CodeVoice v3 wording)

    /// Innermost first, e.g. ["func greet", "struct Greeting"].
    static func enclosingBlocks(in lines: [String], line index: Int) -> [String] {
        var result: [String] = []
        var depth = 0                                  // braces we still need to step out of
        var i = index
        // Braces earlier on the error line itself (e.g. "if x {" on that line) don't count.
        while i > 0, result.count < 2 {
            i -= 1
            let cleaned = clean(lines[i])
            for char in cleaned.reversed() {
                if char == "}" { depth += 1 }
                else if char == "{" {
                    if depth == 0 {
                        result.append(describeBlock(header(in: lines, upTo: i)))
                        if result.count == 2 { break }
                    } else {
                        depth -= 1
                    }
                }
            }
        }
        return result
    }

    /// The line that opens the last block still open before `index` (for missing braces).
    static func unclosedOpener(in lines: [String], before index: Int) -> Int? {
        var stack: [Int] = []
        for i in 0..<min(index, lines.count) {
            for char in clean(lines[i]) {
                if char == "{" { stack.append(i) } else if char == "}" { _ = stack.popLast() }
            }
        }
        return stack.last
    }

    private static func header(in lines: [String], upTo index: Int) -> String {
        var text = ""
        var i = index
        while i >= 0, i >= index - 4 {
            let cleaned = clean(lines[i]).trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty {
                text = cleaned + " " + text
                if firstMatch(#"\b(func|struct|class|enum|actor|protocol|extension|init|var|let|if|guard|for|while|switch|case)\b"#, in: text) != nil { break }
            }
            i -= 1
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func describeBlock(_ text: String) -> String {
        let kinds = ["struct", "class", "enum", "actor", "protocol", "extension", "func"]
        for kind in kinds {
            if let name = firstMatch(#"\b\#(kind)\s+([A-Za-z0-9_.]+)"#, in: text) { return "\(kind) \(name)" }
        }
        if text.contains("init") { return "initializer" }
        if let name = firstMatch(#"\b(?:var|let)\s+([A-Za-z0-9_]+)"#, in: text) { return "property \(name)" }
        if text.hasPrefix("if ") || text.contains("} else if") { return "if statement" }
        if text.hasPrefix("else") || text.hasPrefix("} else") { return "else block" }
        if text.hasPrefix("guard ") { return "guard statement" }
        if text.hasPrefix("for ") { return "for loop" }
        if text.hasPrefix("while ") { return "while loop" }
        if text.hasPrefix("switch ") { return "switch statement" }
        if text.hasPrefix("case ") || text.hasPrefix("default") { return "switch case" }
        if let name = firstMatch(#"([A-Za-z_][A-Za-z0-9_]*)\s*(?:\([^)]*\))?\s*\{\s*$"#, in: text) { return "\(name) block" }
        return "block"
    }

    // MARK: - Helpers

    /// Drops comments and string contents so their braces don't count.
    private static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: #""(?:[^"\\]|\\.)*""#, with: "\"\"", options: .regularExpression)
        if let comment = text.range(of: "//") { text = String(text[..<comment.lowerBound]) }
        return text
    }

    private static func spokenFileName(_ name: String) -> String {
        name.hasSuffix(".swift") ? String(name.dropLast(6)) + " dot swift" : name
    }

    /// Long lines are cut so the sentence stays short.
    private static func spokenCode(_ code: String) -> String {
        code.count > 80 ? String(code.prefix(80)) + "…" : code
    }

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        let capped = first.uppercased() + text.dropFirst()
        return capped.hasSuffix(".") ? capped : capped + "."
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        firstMatches(pattern, in: text)?.first
    }

    private static func firstMatches(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
