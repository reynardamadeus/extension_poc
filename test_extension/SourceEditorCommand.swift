//
//  SourceEditorCommand.swift
//  test_extension
//
//  Created by Reynard Amadeus  on 12/10/26.
//

import Foundation
import XcodeKit

class SourceEditorCommand: NSObject, XCSourceEditorCommand {

    func perform(with invocation: XCSourceEditorCommandInvocation, completionHandler: @escaping (Error?) -> Void ) -> Void {
        let buffer = invocation.buffer

        if invocation.commandIdentifier.hasSuffix(".OpenBlock") {
            Self.openBlock(in: buffer)
            return completionHandler(nil)
        }

        if invocation.commandIdentifier.hasSuffix(".JumpToError") {
            return completionHandler(Self.jumpToError(in: buffer))
        }

        // CodeVoice: spoken line context, structure, error check and AI explanations.
        if CodeVoiceRunner.handles(invocation.commandIdentifier) {
            CodeVoiceRunner().perform(with: invocation, completionHandler: completionHandler)
            return
        }

        completionHandler(nil)
    }

    /// "Jump to Error Line" (App Store-safe jumps): the Mac app opened the file and
    /// left the error's line in the shared App Group; move the cursor there.
    private static func jumpToError(in buffer: XCSourceTextBuffer) -> Error? {
        guard let jump = SharedSettings.defaults.dictionary(forKey: SharedSettings.Key.pendingJump),
              let line = jump["line"] as? Int,
              let at = jump["at"] as? Double,
              Date().timeIntervalSince1970 - at < 30 * 60 else {
            return NSError(domain: "ErrorRelay", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "No error selected. Choose one on the watch or with ⌃⇧⌘N first."])
        }
        guard line >= 1, line <= buffer.lines.count else {
            return NSError(domain: "ErrorRelay", code: 2,
                           userInfo: [NSLocalizedDescriptionKey: "Line \(line) isn't in this file (\(jump["file"] as? String ?? "another file"))."])
        }
        let position = XCSourceTextPosition(line: line - 1, column: 0)
        buffer.selections.removeAllObjects()
        buffer.selections.add(XCSourceTextRange(start: position, end: position))
        return nil
    }

    /// "Open Block": turns the cursor's line into `line {` + empty indented line + `}`.
    private static func openBlock(in buffer: XCSourceTextBuffer) {
        guard let selection = buffer.selections.firstObject as? XCSourceTextRange else { return }
        let position = selection.end
        guard buffer.lines.count > 0 else { return }
        let lineIndex = min(position.line, buffer.lines.count - 1)
        guard let line = buffer.lines[lineIndex] as? String else { return }

        let unit = buffer.usesTabsForIndentation
            ? "\t"
            : String(repeating: " ", count: max(1, buffer.indentationWidth))
        let smartReturn = SmartReturn(indentUnit: unit,
                                      annotate: false)
        let result = smartReturn.apply(to: line, cursorColumn: position.column)

        // Replace the one line with the new lines.
        buffer.lines.replaceObject(at: lineIndex, with: result.lines[0])
        for (offset, newLine) in result.lines.dropFirst().enumerated() {
            buffer.lines.insert(newLine, at: lineIndex + 1 + offset)
        }

        // Put the cursor inside the new block.
        let cursor = XCSourceTextPosition(line: lineIndex + result.cursorLineOffset,
                                          column: result.cursorColumn)
        buffer.selections.removeAllObjects()
        buffer.selections.add(XCSourceTextRange(start: cursor, end: cursor))
    }
}
