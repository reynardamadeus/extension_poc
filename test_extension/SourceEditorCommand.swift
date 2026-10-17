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

        let lines = buffer.lines.compactMap { $0 as? String }
        guard !lines.isEmpty else { return completionHandler(nil) }

        // Read settings fresh every time, so changes in the app apply immediately.
        let annotator = BraceAnnotator(style: SharedSettings.style,
                                       includeContext: SharedSettings.includeContext)
        let range = Self.selectedLineRange(in: buffer)

        let updated: [String]
        if invocation.commandIdentifier.hasSuffix(".RemoveAnnotations") {
            updated = annotator.removingAnnotations(lines, in: range)
        } else {
            updated = annotator.annotating(lines, in: range)
        }

        // Only replace lines that changed (keeps undo clean and fast).
        for (index, newLine) in updated.enumerated() where newLine != lines[index] {
            buffer.lines[index] = newLine
        }
        completionHandler(nil)
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
                                      style: SharedSettings.style,
                                      annotate: SharedSettings.annotateNewBlocks,
                                      includeContext: SharedSettings.includeContext)
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

    /// Selected text → those lines. Just a cursor (nothing selected) → whole file (nil).
    private static func selectedLineRange(in buffer: XCSourceTextBuffer) -> ClosedRange<Int>? {
        let ranges = buffer.selections.compactMap { $0 as? XCSourceTextRange }
        let real = ranges.filter { $0.start.line != $0.end.line || $0.start.column != $0.end.column }
        guard !real.isEmpty else { return nil }

        let first = real.map(\.start.line).min()!
        var last = real.map { r in
            // A selection ending at column 0 of the next line doesn't include that line.
            r.end.column == 0 && r.end.line > r.start.line ? r.end.line - 1 : r.end.line
        }.max()!
        last = min(last, buffer.lines.count - 1)
        return first...max(first, last)
    }
}
