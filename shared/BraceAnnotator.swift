//
//  BraceAnnotator.swift
//  extension_poc
//
//  Adds spoken-friendly comments next to braces, e.g.
//
//      func greet() {            // begin
//          if isMorning {        // begin
//              print("Hi")
//          } else {              // end if isMorning, begin
//              print("Hello")
//          }                     // end else
//      }                         // end func greet()
//
//  VoiceOver then reads "end if isMorning" instead of just "right brace".
//  Pure Foundation, so the app can use it for a live preview and the
//  extension uses it to edit the buffer.
//

import Foundation

nonisolated struct BraceAnnotator {
    var style: BracketSetting
    var includeContext: Bool = true
    var maxContextLength: Int = 40

    // MARK: - Public API

    /// Returns the lines with fresh annotations. Existing annotations made by
    /// this tool (either style) are removed first, so running it twice is safe
    /// and switching style in the app just works.
    /// - Parameter range: line indexes to change; `nil` = whole file.
    func annotating(_ lines: [String], in range: ClosedRange<Int>? = nil) -> [String] {
        let clean = removingAnnotations(lines, in: range)
        var result = clean
        var state = ScanState()
        var stack: [(line: Int, context: String)] = []

        for (index, line) in clean.enumerated() {
            let scan = Self.scan(line, state: &state)
            let chars = Array(line)
            var closes: [String] = []

            for event in scan.events {
                switch event {
                case .open(let column):
                    let before = String(chars[..<column])
                    let context = makeContext(before: before, lines: clean, lineIndex: index)
                    stack.append((index, context))
                case .close:
                    guard let opened = stack.popLast() else { continue }
                    // `{ ... }` on the same line: nothing to announce.
                    if opened.line != index { closes.append(opened.context) }
                }
            }
            let opensHere = stack.filter { $0.line == index }.count

            guard range?.contains(index) ?? true,
                  scan.commentStart == nil,                 // never touch lines with a comment
                  !closes.isEmpty || opensHere > 0 else { continue }

            var parts: [String] = closes.map { context in
                includeContext && !context.isEmpty ? "\(style.closeWord) \(context)" : style.closeWord
            }
            parts += Array(repeating: style.openWord, count: opensHere)

            let (body, newline) = Self.splitNewline(line)
            result[index] = Self.trimTrailing(body) + " // " + parts.joined(separator: ", ") + newline
        }
        return result
    }

    /// Removes comments this tool added (any style) from lines that contain a brace.
    func removingAnnotations(_ lines: [String], in range: ClosedRange<Int>? = nil) -> [String] {
        var result = lines
        var state = ScanState()

        for (index, line) in lines.enumerated() {
            let scan = Self.scan(line, state: &state)
            guard range?.contains(index) ?? true,
                  let commentStart = scan.commentStart,
                  !scan.events.isEmpty else { continue }

            let chars = Array(line)
            let (_, newline) = Self.splitNewline(line)
            let commentText = String(chars[(commentStart + 2)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let firstWord = commentText
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .first.map(String.init)?.lowercased() ?? ""

            if BracketSetting.allWords.contains(firstWord) {
                result[index] = Self.trimTrailing(String(chars[..<commentStart])) + newline
            }
        }
        return result
    }

    // MARK: - Context ("if isMorning", "func greet()", "VStack", ...)

    private func makeContext(before: String, lines: [String], lineIndex: Int) -> String {
        var text = Self.cleanContext(before, maxLength: .max)
        if text.isEmpty {
            // Brace on its own line: use the previous non-empty line.
            var i = lineIndex - 1
            while i >= 0 {
                let candidate = Self.splitNewline(lines[i]).body.trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty { text = candidate; break }
                i -= 1
            }
        }
        return Self.cleanContext(text, maxLength: maxContextLength)
    }

    /// Collapses whitespace, drops leading `}`/`)` and trailing `=`, and shortens long text.
    static func cleanContext(_ raw: String, maxLength: Int = 40) -> String {
        // Only strip `}` / `)` / `.` from the START (e.g. "} else"), never the end,
        // so "func greet()" keeps its parentheses.
        var text = String(raw.drop(while: { "}). \t".contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while text.hasSuffix("=") || text.hasSuffix(" ") { text.removeLast() }
        if text.count > maxLength { text = String(text.prefix(maxLength)) + "…" }
        return text
    }

    // MARK: - Tiny Swift/C-style scanner (skips strings and comments)

    enum BraceEvent { case open(Int), close(Int) }

    struct LineScan {
        var events: [BraceEvent] = []
        /// Character index of a `//` comment outside strings, if any.
        var commentStart: Int?
    }

    struct ScanState {
        var blockCommentDepth = 0
        var inMultilineString = false
    }

    static func scan(_ line: String, state: inout ScanState) -> LineScan {
        let chars = Array(line)
        var result = LineScan()
        var inString = false
        var i = 0

        func isTripleQuote(_ at: Int) -> Bool {
            at + 2 < chars.count && chars[at] == "\"" && chars[at + 1] == "\"" && chars[at + 2] == "\""
        }

        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            if state.blockCommentDepth > 0 {
                if c == "*" && next == "/" { state.blockCommentDepth -= 1; i += 2; continue }
                if c == "/" && next == "*" { state.blockCommentDepth += 1; i += 2; continue }
                i += 1; continue
            }
            if state.inMultilineString {
                if c == "\\" { i += 2; continue }
                if isTripleQuote(i) { state.inMultilineString = false; i += 3; continue }
                i += 1; continue
            }
            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
                i += 1; continue
            }

            if c == "/" && next == "/" { result.commentStart = i; break }
            if c == "/" && next == "*" { state.blockCommentDepth += 1; i += 2; continue }
            if c == "\"" {
                if isTripleQuote(i) { state.inMultilineString = true; i += 3; continue }
                inString = true; i += 1; continue
            }
            if c == "{" { result.events.append(.open(i)) }
            if c == "}" { result.events.append(.close(i)) }
            i += 1
        }
        return result
    }

    // MARK: - String helpers

    static func splitNewline(_ line: String) -> (body: String, newline: String) {
        // Note: "\r\n" is ONE Character in Swift, so dropLast() is correct for both.
        if line.hasSuffix("\r\n") { return (String(line.dropLast()), "\r\n") }
        if line.hasSuffix("\n") { return (String(line.dropLast()), "\n") }
        return (line, "")
    }

    static func trimTrailing(_ text: String) -> String {
        var t = text
        while let last = t.last, last == " " || last == "\t" { t.removeLast() }
        return t
    }
}
