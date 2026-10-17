//
//  SmartReturn.swift
//  extension_poc
//
//  "Open Block" (Smart Return): turns the current line into a block.
//
//      add()|            ⌥Return  →   add() { // begin
//                                         |
//                                     } // end add()
//
//  Pure Foundation so it can be tested and previewed in the app.
//

import Foundation

nonisolated struct SmartReturn {
    var indentUnit: String = "    "
    var style: BracketSetting = .beginEnd
    var annotate: Bool = true
    var includeContext: Bool = true

    struct Result: Equatable {
        /// Lines that replace the ONE original line.
        var lines: [String]
        /// Cursor position, line relative to the original line.
        var cursorLineOffset: Int
        var cursorColumn: Int
    }

    /// - Parameters:
    ///   - line: the full current line (may end with "\n").
    ///   - cursorColumn: cursor column (UTF-16 offset) on that line.
    func apply(to line: String, cursorColumn: Int) -> Result {
        let (body, newline) = BraceAnnotator.splitNewline(line)
        let nsBody = body as NSString
        let column = max(0, min(cursorColumn, nsBody.length))
        let before = nsBody.substring(to: column)
        let after = nsBody.substring(from: column)
        let indent = String(body.prefix(while: { $0 == " " || $0 == "\t" }))
        let nl = newline.isEmpty ? "\n" : newline

        // Find the code part (ignore an existing // comment, skip strings).
        var state = BraceAnnotator.ScanState()
        let scan = BraceAnnotator.scan(body, state: &state)
        let chars = Array(body)
        let code = scan.commentStart.map { String(chars[..<$0]) } ?? body
        let existingComment = scan.commentStart.map { String(chars[$0...]) }
        let codeTrimmed = BraceAnnotator.trimTrailing(code)
            .trimmingCharacters(in: .whitespaces)

        // Cursor must be at the end of the code. Only auto-closed characters
        // like `)` `]` `"` may follow it (e.g. Xcode left the cursor in `add(|)`).
        let afterIsIgnorable = after.trimmingCharacters(in: .whitespaces)
            .allSatisfy { ")]\"'".contains($0) }
        let cursorInComment = scan.commentStart.map { column > $0 } ?? false

        guard !codeTrimmed.isEmpty, afterIsIgnorable, !cursorInComment else {
            return plainNewline(before: before, after: after, indent: indent, newline: newline)
        }

        // Build the opening line.
        let opener = codeTrimmed.hasSuffix("{")
            ? indent + codeTrimmed
            : indent + codeTrimmed + " {"
        let openComment = existingComment.map { " " + $0 }
            ?? (annotate ? " // \(style.openWord)" : "")

        // Build the closing line.
        var closer = indent + "}"
        if annotate {
            let context = BraceAnnotator.cleanContext(
                String(codeTrimmed.hasSuffix("{") ? codeTrimmed.dropLast() : Substring(codeTrimmed)))
            closer += includeContext && !context.isEmpty
                ? " // \(style.closeWord) \(context)"
                : " // \(style.closeWord)"
        }

        let inner = indent + indentUnit
        return Result(
            lines: [opener + openComment + nl, inner + nl, closer + newline],
            cursorLineOffset: 1,
            cursorColumn: (inner as NSString).length
        )
    }

    /// Fallback: behave like a normal Return (split the line, keep indentation).
    private func plainNewline(before: String, after: String, indent: String, newline: String) -> Result {
        let nl = newline.isEmpty ? "\n" : newline
        var newIndent = indent
        if BraceAnnotator.trimTrailing(before).hasSuffix("{") { newIndent += indentUnit }
        let rest = String(after.drop(while: { $0 == " " || $0 == "\t" }))
        return Result(
            lines: [BraceAnnotator.trimTrailing(before) + nl, newIndent + rest + newline],
            cursorLineOffset: 1,
            cursorColumn: (newIndent as NSString).length
        )
    }
}
