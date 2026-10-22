//
//  CodeVoiceCommands.swift
//  test_extension
//
//  CodeVoice commands (by Elena Angkawi), merged into this extension.
//  Spoken help for the cursor's line, structure, errors and AI explanations
//  (Apple Foundation Models, on-device). Called from SourceEditorCommand.
//

import Foundation
import AVFoundation
import XcodeKit
import FoundationModels
import AppKit

final class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechManager()
    
    private let synthesizer = AVSpeechSynthesizer()
    private var completionHandler: ((Error?) -> Void)?
    
    private override init() {
        super.init()
        synthesizer.delegate = self
    }
    
    func speak(message: String, completion: ((Error?) -> Void)?) {
        self.completionHandler = completion
        
        let isVoiceOverRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.VoiceOver"
        }
        
        if isVoiceOverRunning {
            // 1. Copy context to pasteboard so user can read it via VO + Shift + C
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(message, forType: .string)
            
            // 2. Play a brief system cue and notify via delay
            NSSound.beep()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.synthesizer.isSpeaking == true {
                    self?.synthesizer.stopSpeaking(at: .immediate)
                }
                
                let utterance = AVSpeechUtterance(string: message)
                utterance.rate = 0.50
                self?.synthesizer.speak(utterance)
            }
        } else {
            // Standard AVSpeechSynthesizer for non-VoiceOver users
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
            
            let utterance = AVSpeechUtterance(string: message)
            utterance.rate = 0.48
            utterance.volume = 1.0
            synthesizer.speak(utterance)
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        completionHandler?(nil)
        completionHandler = nil
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        completionHandler?(nil)
        completionHandler = nil
    }
}

// MARK: - CodeVoice command runner
final class CodeVoiceRunner: NSObject {

    /// Command name endings this runner handles (the Info.plist identifiers end with these).
    static let commandSuffixes = ["SendLines", "ExplainSelection", "CheckErrors", "ReadStructure",
                                  "ReadLineV2", "ReadLineV3", "ReadLine", "Summarize", "LineImpact"]

    static func handles(_ identifier: String) -> Bool {
        commandSuffixes.contains { identifier.hasSuffix(".\($0)") }
    }

    private var commandCompletion: ((Error?) -> Void)?

    func perform(with invocation: XCSourceEditorCommandInvocation, completionHandler: @escaping (Error?) -> Void) {
        self.commandCompletion = completionHandler

        let identifier = invocation.commandIdentifier
        
        if identifier.hasSuffix("SendLines") {
            executeSendLinesFeature(invocation: invocation)
        } else if identifier.hasSuffix("ExplainSelection") {
            executeExplainSelectionFeature(invocation: invocation)
        } else if identifier.hasSuffix("CheckErrors") {
            executeCheckErrorsFeature(invocation: invocation)
        } else if identifier.hasSuffix("ReadStructure") {
            executeReadStructureFeature(invocation: invocation)
        } else if identifier.hasSuffix("ReadLineV2") {
            executeReadLineFeatureV2(invocation: invocation)
        } else if identifier.hasSuffix("ReadLineV3") {
            executeReadLineFeatureV3(invocation: invocation)
        } else if identifier.hasSuffix("ReadLine") {
            executeReadLineFeature(invocation: invocation)
        } else if identifier.hasSuffix("Summarize") {
            executeSummarizeFeature(invocation: invocation)
        } else if identifier.hasSuffix("LineImpact") {
            executeLineImpactFeature(invocation: invocation)
        } else {
            completionHandler(nil)
        }
    }

    // MARK: - Speech Dispatcher
    
    private func speak(message: String) {
        SpeechManager.shared.speak(message: message, completion: commandCompletion)
    }

    /// Hands the result to the companion app, which shows it in a floating panel.
    private func showInPanel(_ text: String, command: String, line: Int) {
        SharedSettings.defaults.set(["text": text, "command": command, "line": line,
                                     "at": Date().timeIntervalSince1970],
                                    forKey: SharedSettings.Key.lineContext)
        DistributedNotificationCenter.default().postNotificationName(
            SharedSettings.lineContextNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: - Feature 0: Show Lines in Panel
    // Sends real lines from Xcode to the companion app's floating panel.
    // Cursor only → the cursor's line with 3 lines above and below.
    // Selection → exactly the selected lines (up to 200).

    private func executeSendLinesFeature(invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        guard buffer.lines.count > 0,
              let selection = buffer.selections.firstObject as? XCSourceTextRange else {
            commandCompletion?(nil)
            return
        }

        let lastIndex = buffer.lines.count - 1
        let cursor = min(max(selection.start.line, 0), lastIndex)
        let hasSelection = selection.start.line != selection.end.line || selection.start.column != selection.end.column

        var first = cursor
        var last = cursor
        if hasSelection {
            first = min(max(selection.start.line, 0), lastIndex)
            // A selection ending at column 0 of the next line doesn't include that line.
            last = selection.end.column == 0 && selection.end.line > selection.start.line
                ? selection.end.line - 1 : selection.end.line
            last = max(first, min(min(last, lastIndex), first + 199))
        } else {
            first = max(0, cursor - 3)
            last = min(lastIndex, cursor + 3)
        }

        var lines: [[String: Any]] = []
        for i in first...last {
            let raw = buffer.lines[i] as? String ?? ""
            let code = raw.trimmingCharacters(in: .newlines).replacingOccurrences(of: "\t", with: "    ")
            lines.append(["n": i + 1, "code": code])
        }

        let context = findParentContext(in: buffer.lines, startingFrom: cursor)
        let place = context.map { "Inside \($0)" } ?? "At global scope"
        let summary = first == last
            ? "Line \(first + 1). \(place)."
            : "Lines \(first + 1) to \(last + 1). Cursor on line \(cursor + 1). \(place)."

        SharedSettings.defaults.set(["text": summary, "command": "Lines from Xcode",
                                     "line": cursor + 1, "lines": lines,
                                     "at": Date().timeIntervalSince1970],
                                    forKey: SharedSettings.Key.lineContext)
        DistributedNotificationCenter.default().postNotificationName(
            SharedSettings.lineContextNotification, object: nil, userInfo: nil, deliverImmediately: true)
        commandCompletion?(nil)
    }

    // MARK: - Feature 1: Read Line Context (Original Format)
    // Example: "Inside struct makan. Line 5. Code: var nasi: String"

    private func executeReadLineFeature(invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        guard let selection = buffer.selections.firstObject as? XCSourceTextRange else {
            commandCompletion?(nil)
            return
        }

        let lineIndex = selection.start.line
        guard lineIndex >= 0, lineIndex < buffer.lines.count,
              let sourceLine = buffer.lines[lineIndex] as? String else {
            commandCompletion?(nil)
            return
        }

        let code = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
        // A modifier line (.accessibilityHint after a closure or a call) belongs to the chain's base.
        let chain = modifierChain(in: buffer.lines, at: lineIndex)
        let context = findParentContext(in: buffer.lines, startingFrom: chain?.baseLine ?? lineIndex)
        let contextPhrase = context != nil ? "Inside \(context!)." : "At global scope."
        let chainPhrase = chain.map { " " + $0.spokenBase(currentLine: lineIndex) } ?? ""

        let message = code.isEmpty
            ? "\(contextPhrase) Line \(lineIndex + 1). Empty line."
            : "\(contextPhrase) Line \(lineIndex + 1). Code: \(code)\(chainPhrase)"

        showInPanel(message, command: "Read Line Context", line: lineIndex + 1)
        speak(message: message)
    }

    // MARK: - Feature 1.2: Read Line Context V2 ("within")
    // Example: "Line 5: variable nasi within struct makan."

    private func executeReadLineFeatureV2(invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        guard let selection = buffer.selections.firstObject as? XCSourceTextRange else {
            commandCompletion?(nil)
            return
        }

        let lineIndex = selection.start.line
        guard lineIndex >= 0, lineIndex < buffer.lines.count,
              let sourceLine = buffer.lines[lineIndex] as? String else {
            commandCompletion?(nil)
            return
        }

        let code = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let chain = modifierChain(in: buffer.lines, at: lineIndex)
        let entity = chain?.spokenEntity(currentLine: lineIndex) ?? describeLineEntity(code: code)
        let context = findParentContext(in: buffer.lines, startingFrom: chain?.baseLine ?? lineIndex)

        let message: String
        if let context = context {
            message = "Line \(lineIndex + 1): \(entity) within \(context)."
        } else {
            message = "Line \(lineIndex + 1): \(entity) at global scope."
        }

        showInPanel(message, command: "Read Line Context v2", line: lineIndex + 1)
        speak(message: message)
    }

    // MARK: - Feature 1.3: Read Line Context V3 ("inside")
    // Example: "Line 5: func nasi inside closure makan."

    private func executeReadLineFeatureV3(invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        guard let selection = buffer.selections.firstObject as? XCSourceTextRange else {
            commandCompletion?(nil)
            return
        }

        let lineIndex = selection.start.line
        guard lineIndex >= 0, lineIndex < buffer.lines.count,
              let sourceLine = buffer.lines[lineIndex] as? String else {
            commandCompletion?(nil)
            return
        }

        let code = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let chain = modifierChain(in: buffer.lines, at: lineIndex)
        let entity = chain?.spokenEntity(currentLine: lineIndex) ?? describeLineEntity(code: code)
        let context = findParentContext(in: buffer.lines, startingFrom: chain?.baseLine ?? lineIndex)

        let message: String
        if let context = context {
            message = "Line \(lineIndex + 1): \(entity) inside \(context)."
        } else {
            message = "Line \(lineIndex + 1): \(entity) at global scope."
        }

        showInPanel(message, command: "Read Line Context v3", line: lineIndex + 1)
        speak(message: message)
    }

    private func describeLineEntity(code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty line" }

        if let match = firstRegexMatch(pattern: "\\b(var|let)\\s+([A-Za-z0-9_]+)", in: trimmed, captureGroup: 2) {
            return "variable \(match)"
        }
        if let match = firstRegexMatch(pattern: "\\bfunc\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "func \(match)"
        }
        if let match = firstRegexMatch(pattern: "\\bstruct\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "struct \(match)"
        }
        if let match = firstRegexMatch(pattern: "\\bclass\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "class \(match)"
        }
        if let match = firstRegexMatch(pattern: "\\benum\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "enum \(match)"
        }

        return trimmed
    }
    
    private func findParentContext(in lines: NSMutableArray, startingFrom lineIndex: Int) -> String? {
        var openBracesNeeded = 1
        for i in stride(from: lineIndex - 1, through: 0, by: -1) {
            guard let line = lines[i] as? String else { continue }
            let cleaned = cleanCodeLine(line)
            
            openBracesNeeded += cleaned.filter { $0 == "}" }.count
            openBracesNeeded -= cleaned.filter { $0 == "{" }.count
            
            if openBracesNeeded <= 0 {
                let headerText = findHeaderLineText(in: lines, upTo: i)
                return identifyContext(from: headerText)
            }
        }
        return nil
    }

    // MARK: - Feature 2: Read Code Structure

    private func executeReadStructureFeature(invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        guard let selection = buffer.selections.firstObject as? XCSourceTextRange else {
            commandCompletion?(nil)
            return
        }

        let lineIndex = selection.start.line
        guard lineIndex >= 0, lineIndex < buffer.lines.count,
              let sourceLine = buffer.lines[lineIndex] as? String else {
            commandCompletion?(nil)
            return
        }

        let currentLineNum = lineIndex + 1
        let code = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let allBlocks = parseAllBlocks(in: buffer.lines)
        let enclosingBlocks = allBlocks
            .filter { $0.startLine <= currentLineNum && $0.endLine >= currentLineNum }
            .sorted { ($0.endLine - $0.startLine) < ($1.endLine - $1.startLine) }

        let nestingLevel = enclosingBlocks.count
        let lineCodePhrase = code.isEmpty ? "Empty line." : "Code: \(code)."

        let rangePhrase: String
        if enclosingBlocks.isEmpty {
            rangePhrase = "At global scope."
        } else {
            let currentBlock = enclosingBlocks[0]
            rangePhrase = "Inside \(currentBlock.contextDescription), from line \(currentBlock.startLine) to line \(currentBlock.endLine)."
        }

        let message = "Line \(currentLineNum). Level \(nestingLevel). \(lineCodePhrase) \(rangePhrase)"
        speak(message: message)
    }

    // MARK: - Feature 3: Line Impact Analysis

    private func executeLineImpactFeature(invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        guard let selection = buffer.selections.firstObject as? XCSourceTextRange else {
            commandCompletion?(nil)
            return
        }

        let lineIndex = selection.start.line
        guard lineIndex >= 0, lineIndex < buffer.lines.count,
              let sourceLine = buffer.lines[lineIndex] as? String else {
            commandCompletion?(nil)
            return
        }

        let currentLineNum = lineIndex + 1
        let code = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !code.isEmpty else {
            speak(message: "Line \(currentLineNum) is an empty line and has no functional impact.")
            return
        }

        let fullText = buffer.completeBuffer

        Task {
            do {
                let session = LanguageModelSession(
                    instructions: """
                    You are an accessibility assistant for speech synthesis.
                    Analyze line \(currentLineNum) (`\(code)`) within the context of the provided Swift file.
                    Explain in 2 short, plain-English sentences:
                    1. What parent structure contains this line.
                    2. How executing or changing this line impacts state, parameters, return values, or control flow within this file.
                    Do not refer to other files in the project. Keep the tone concise and spoken-word friendly without formatting symbols.
                    """
                )
                
                let aiResponse = try await session.respond(to: fullText)
                let aiSummary = aiResponse.content.trimmingCharacters(in: .whitespacesAndNewlines)

                let finalMessage = aiSummary.isEmpty
                    ? "Could not determine impact for line \(currentLineNum)."
                    : "Line \(currentLineNum) impact: \(aiSummary)"
                
                await MainActor.run {
                    self.speak(message: finalMessage)
                }
            } catch {
                await MainActor.run {
                    self.speak(message: "Line impact analysis unavailable.")
                }
            }
        }
    }

    // MARK: - Feature 4: Check Code Errors & Warnings

    private func executeCheckErrorsFeature(invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        let fullText = buffer.completeBuffer
        
        var localIssues: [String] = []
        var symbolStack: [(char: Character, line: Int)] = []

        for i in 0..<buffer.lines.count {
            guard let lineStr = buffer.lines[i] as? String else { continue }
            let lineNum = i + 1
            let cleaned = cleanCodeLine(lineStr)
            
            var inString = false
            var prevChar: Character? = nil
            
            for char in cleaned {
                if char == "\"" && prevChar != "\\" {
                    inString.toggle()
                }
                
                if !inString {
                    if char == "{" || char == "(" || char == "[" {
                        symbolStack.append((char, lineNum))
                    } else if char == "}" || char == ")" || char == "]" {
                        if let last = symbolStack.last {
                            let matches = (last.char == "{" && char == "}") ||
                                          (last.char == "(" && char == ")") ||
                                          (last.char == "[" && char == "]")
                            if matches {
                                _ = symbolStack.popLast()
                            } else {
                                localIssues.append("Line \(lineNum): Unexpected closing '\(char)'. Expected closing bracket for '\(last.char)' opened at line \(last.line).")
                            }
                        } else {
                            localIssues.append("Line \(lineNum): Extra closing '\(char)' without an opening bracket.")
                        }
                    }
                }
                prevChar = char
            }
            
            if inString {
                localIssues.append("Line \(lineNum): Unclosed text quote.")
            }
        }

        while let unclosed = symbolStack.popLast() {
            localIssues.append("Line \(unclosed.line): Missing closing bracket for '\(unclosed.char)'.")
        }

        if !localIssues.isEmpty {
            let issueCount = localIssues.count
            let summary = "Found \(issueCount) syntax issue\(issueCount > 1 ? "s" : ""): " + localIssues.joined(separator: " ")
            speak(message: summary)
            return
        }

        Task {
            do {
                let session = LanguageModelSession(
                    instructions: """
                    You are an accessibility assistant for screen readers. Analyze the provided Swift code for errors, warnings, unused variables, or bad syntax.
                    Format each issue as 'Line [X]: [simplified, plain-English explanation]'.
                    Explain what is wrong and how to fix it in simple terms without compiler jargon.
                    List all issues found in chronological line order.
                    If no errors or warnings exist, reply strictly with 'No errors or warnings found.'
                    """
                )
                
                let aiResponse = try await session.respond(to: fullText)
                let aiResult = aiResponse.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = aiResult.isEmpty ? "No errors or warnings found." : aiResult
                
                await MainActor.run {
                    self.speak(message: message)
                }
            } catch {
                await MainActor.run {
                    self.speak(message: "No syntax errors found in standard check.")
                }
            }
        }
    }

    // MARK: - Feature 5: Summarize File

    private func executeSummarizeFeature(invocation: XCSourceEditorCommandInvocation) {
        let fullText = invocation.buffer.completeBuffer
        
        let structCount = count(pattern: "\\bstruct\\s+", in: fullText)
        let classCount = count(pattern: "\\bclass\\s+", in: fullText)
        let funcCount = count(pattern: "\\bfunc\\s+", in: fullText)
        
        let structureMessage = "This file contains \(structCount) structs, \(classCount) classes, and \(funcCount) functions."
        
        Task {
            do {
                let session = LanguageModelSession(
                    instructions: "Analyze the following Swift code and provide a one-sentence summary of its primary purpose. Do not include any code, formatting, or introductory text."
                )
                
                let aiResponse = try await session.respond(to: fullText)
                let aiSummary = aiResponse.content.trimmingCharacters(in: .whitespacesAndNewlines)

                let finalMessage = aiSummary.isEmpty ? structureMessage : "\(structureMessage) Summary: \(aiSummary)"
                
                await MainActor.run {
                    self.speak(message: finalMessage)
                }
            } catch {
                await MainActor.run {
                    self.speak(message: "\(structureMessage)")
                }
            }
        }
    }

    // MARK: - Feature 6: Explain Selected Code

    private func executeExplainSelectionFeature(invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        guard let selection = buffer.selections.firstObject as? XCSourceTextRange else {
            commandCompletion?(nil)
            return
        }

        let startLine = selection.start.line
        let endLine = selection.end.line
        
        var selectedLines: [String] = []
        for lineIndex in startLine...endLine {
            if lineIndex >= 0 && lineIndex < buffer.lines.count,
               let lineStr = buffer.lines[lineIndex] as? String {
                selectedLines.append(lineStr)
            }
        }
        
        let selectedCode = selectedLines.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !selectedCode.isEmpty else {
            speak(message: "Please highlight a selection of code to explain.")
            return
        }

        Task {
            do {
                let session = LanguageModelSession(
                    instructions: """
                    You are an accessibility assistant for visually impaired developers.
                    Translate the provided Swift code snippet into a simple, single-sentence plain-English explanation.
                    Focus on what the code accomplishes conceptually. Do not repeat code syntax or output formatting.
                    """
                )
                
                let aiResponse = try await session.respond(to: selectedCode)
                let aiSummary = aiResponse.content.trimmingCharacters(in: .whitespacesAndNewlines)

                let finalMessage = aiSummary.isEmpty
                    ? "Could not explain selection."
                    : "Selection explanation: \(aiSummary)"
                
                await MainActor.run {
                    self.speak(message: finalMessage)
                }
            } catch {
                await MainActor.run {
                    self.speak(message: "Unable to explain selected code.")
                }
            }
        }
    }

    // MARK: - Modifier chains
    // Handles lines like these, where the line only makes sense with the chain's start:
    //
    //     Button("Save") { save() }
    //         .accessibilityHint("Saves the file")      ← cursor here
    //     }.accessibilityLabel("Close")                 ← modifier right after a closure
    //     Text("Hi").font(.title).accessibilityHint("Greeting")   ← chain on one line

    private struct ModifierChain {
        let base: String          // e.g. Button("Save")
        let baseLine: Int         // 0-based line where the chain starts
        let modifiers: [String]   // e.g. accessibilityHint "Saves the file"

        /// Read Line Context: "Chained on Button("Save") from line 5."
        func spokenBase(currentLine: Int) -> String {
            baseLine == currentLine
                ? "Chained on \(base)."
                : "Chained on \(base) from line \(baseLine + 1)."
        }

        /// v2 / v3: "modifier accessibilityHint "Saves the file" on Button("Save") from line 5"
        func spokenEntity(currentLine: Int) -> String {
            let mods: String
            switch modifiers.count {
            case 0: mods = "chain"
            case 1: mods = "modifier \(modifiers[0])"
            default: mods = "modifiers " + modifiers.joined(separator: ", then ")
            }
            return baseLine == currentLine
                ? "\(mods) on \(base)"
                : "\(mods) on \(base) from line \(baseLine + 1)"
        }
    }

    /// Finds the top-level `.modifier(...)` calls on this line and the line where their chain starts.
    /// Returns nil when the line isn't a chain (a normal statement, or `.red` inside a list).
    private func modifierChain(in lines: NSMutableArray, at lineIndex: Int) -> ModifierChain? {
        guard lineIndex >= 0, lineIndex < lines.count, let raw = lines[lineIndex] as? String else { return nil }
        let (modifiers, firstModifierAt) = Self.topLevelModifiers(raw)
        let chars = Array(raw)
        guard let first = firstModifierAt else { return nil }

        // The chain starts on this same line: Text("Hi").font(.title)
        let prefix = String(chars[..<first])
        var balance = Self.closersMinusOpeners(cleanCodeLine(prefix))
        let prefixWords = prefix.trimmingCharacters(in: .whitespaces)
        if balance == 0, prefixWords.contains(where: { $0.isLetter }) {
            return ModifierChain(base: Self.spokenBase(prefixWords), baseLine: lineIndex, modifiers: modifiers)
        }
        guard balance >= 0 else { return nil }

        // Walk up past the closure / call the chain hangs on, and past earlier `.modifier` lines.
        var index = lineIndex - 1
        while index >= 0, index >= lineIndex - 300 {
            let original = lines[index] as? String ?? ""
            let cleaned = cleanCodeLine(original)
            balance += Self.closersMinusOpeners(cleaned)
            if balance < 0 { return nil }        // walked out of the enclosing block: not a chain
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if balance == 0, !trimmed.isEmpty, !trimmed.hasPrefix(".") {
                return ModifierChain(base: Self.spokenBase(original.trimmingCharacters(in: .whitespacesAndNewlines)),
                                     baseLine: index, modifiers: modifiers)
            }
            index -= 1
        }
        return nil
    }

    /// The top-level `.modifier(...)` calls on one line, and where the first one starts.
    /// `.title` inside `.font(.title)` is an argument, not a modifier, so it's skipped.
    private static func topLevelModifiers(_ raw: String) -> (modifiers: [String], firstAt: Int?) {
        let chars = Array(raw)
        var depth = 0
        var inString = false
        var i = 0
        var modifiers: [String] = []
        var firstModifierAt: Int?

        while i < chars.count {
            let c = chars[i]
            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" { break }          // comment
            if c == "\"" { inString = true; i += 1; continue }
            if "({[".contains(c) {
                depth += 1
            } else if ")}]".contains(c) {
                depth -= 1
            } else if c == ".", depth <= 0, i + 1 < chars.count,
                      chars[i + 1].isLetter || chars[i + 1] == "_" {
                let before = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                let startsChain = before.isEmpty || before.hasSuffix(")") || before.hasSuffix("}") || before.hasSuffix("]")
                if startsChain || firstModifierAt != nil {
                    var j = i + 1
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                    var spoken = String(chars[(i + 1)..<j])
                    var k = j
                    while k < chars.count, chars[k] == " " { k += 1 }
                    if k < chars.count, chars[k] == "(" {
                        let argument = bracketContents(chars, openAt: k)
                        if !argument.isEmpty { spoken += " " + argument }
                    } else if k < chars.count, chars[k] == "{" {
                        spoken += " with closure"
                    }
                    modifiers.append(spoken)
                    if firstModifierAt == nil { firstModifierAt = i }
                    i = j
                    continue
                }
            }
            i += 1
        }

        return (modifiers, firstModifierAt)
    }

    private static func closersMinusOpeners(_ text: String) -> Int {
        text.reduce(0) { count, c in
            ")}]".contains(c) ? count + 1 : ("({[".contains(c) ? count - 1 : count)
        }
    }

    /// The text inside the parentheses that start at `start` (strings kept), shortened for speech.
    private static func bracketContents(_ chars: [Character], openAt start: Int) -> String {
        var depth = 0
        var inString = false
        var i = start
        var inner: [Character] = []
        while i < chars.count {
            let c = chars[i]
            if inString {
                if c == "\\", i + 1 < chars.count {
                    inner.append(c); inner.append(chars[i + 1]); i += 2
                    continue
                }
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "(" {
                depth += 1
                if depth == 1 { i += 1; continue }
            } else if c == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            inner.append(c)
            i += 1
        }
        var text = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 60 { text = String(text.prefix(60)) + "…" }
        return text
    }

    /// The chain's start as it's spoken: up to its opening brace, e.g. Button("Save").
    private static func spokenBase(_ text: String) -> String {
        var result = ""
        var inString = false
        var previous: Character?
        for c in text {
            if c == "\"" && previous != "\\" { inString.toggle() }
            if c == "{" && !inString { break }
            result.append(c)
            previous = c
        }
        var base = result.trimmingCharacters(in: .whitespaces)
        if base.hasPrefix("return ") { base.removeFirst(7) }
        if base.count > 60 { base = String(base.prefix(60)) + "…" }
        return base.isEmpty ? "the expression above" : base
    }

    // MARK: - Structural Code Analysis Helpers

    private struct CodeBlock {
        let startLine: Int
        var endLine: Int
        let contextDescription: String
        let headerLineText: String
    }

    private struct PendingBlock {
        let startLine: Int
        let headerLineText: String
        let contextDescription: String
    }

    private func parseAllBlocks(in lines: NSMutableArray) -> [CodeBlock] {
        var completedBlocks: [CodeBlock] = []
        var stack: [PendingBlock] = []

        for i in 0..<lines.count {
            guard let lineStr = lines[i] as? String else { continue }
            let currentLineNum = i + 1
            let cleaned = cleanCodeLine(lineStr)

            for char in cleaned {
                if char == "{" {
                    let headerText = findHeaderLineText(in: lines, upTo: i)
                    let context = identifyContext(from: headerText)
                    stack.append(PendingBlock(startLine: currentLineNum, headerLineText: headerText, contextDescription: context))
                } else if char == "}" {
                    if let top = stack.popLast() {
                        let block = CodeBlock(
                            startLine: top.startLine,
                            endLine: currentLineNum,
                            contextDescription: top.contextDescription,
                            headerLineText: top.headerLineText
                        )
                        completedBlocks.append(block)
                    }
                }
            }
        }

        let totalLines = max(1, lines.count)
        while let top = stack.popLast() {
            completedBlocks.append(CodeBlock(
                startLine: top.startLine,
                endLine: totalLines,
                contextDescription: top.contextDescription,
                headerLineText: top.headerLineText
            ))
        }

        return completedBlocks
    }

    private func cleanCodeLine(_ line: String) -> String {
        var cleaned = line
        if let commentIndex = cleaned.range(of: "//")?.lowerBound {
            cleaned = String(cleaned[..<commentIndex])
        }
        cleaned = cleaned.replacingOccurrences(of: "\"[^\"]*\"", with: "\"\"", options: .regularExpression)
        return cleaned
    }

    private func findHeaderLineText(in lines: NSMutableArray, upTo lineIndex: Int) -> String {
        guard lineIndex >= 0, lineIndex < lines.count else { return "" }
        
        var combinedText = ""
        var lookback = lineIndex
        
        while lookback >= 0 && lookback >= lineIndex - 5 {
            if let str = lines[lookback] as? String {
                let cleaned = cleanCodeLine(str).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    combinedText = cleaned + " " + combinedText
                    let lower = combinedText.lowercased()
                    if lower.contains("func ") || lower.contains("struct ") || lower.contains("class ") ||
                       lower.contains("enum ") || lower.contains("actor ") || lower.contains("protocol ") ||
                       lower.contains("var ") || lower.contains("let ") || lower.contains("init") {
                        break
                    }
                }
            }
            lookback -= 1
        }
        
        return combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func identifyContext(from lineText: String) -> String {
        let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)

        if let match = firstRegexMatch(pattern: "\\bstruct\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "struct \(match)"
        }
        if trimmed.contains("struct ") { return "struct" }

        if let match = firstRegexMatch(pattern: "\\bclass\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "class \(match)"
        }
        if trimmed.contains("class ") { return "class" }

        if let match = firstRegexMatch(pattern: "\\benum\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "enum \(match)"
        }
        if trimmed.contains("enum ") { return "enum" }

        if let match = firstRegexMatch(pattern: "\\bactor\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "actor \(match)"
        }
        if trimmed.contains("actor ") { return "actor" }

        if let match = firstRegexMatch(pattern: "\\bprotocol\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "protocol \(match)"
        }
        if trimmed.contains("protocol ") { return "protocol" }

        if let match = firstRegexMatch(pattern: "\\bfunc\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "func \(match)"
        }
        if trimmed.contains("func ") { return "function" }

        if trimmed.contains("for ") || trimmed.contains("forEach") { return "for loop" }
        if trimmed.contains("while ") { return "while loop" }
        if trimmed.contains("repeat ") { return "repeat-while loop" }

        if trimmed.contains("if ") || trimmed.contains("else if") { return "if statement" }
        if trimmed.contains("else") { return "else statement" }
        if trimmed.contains("guard ") { return "guard statement" }
        if trimmed.contains("switch ") { return "switch statement" }

        if let match = firstRegexMatch(pattern: "\\b(var|let)\\s+([A-Za-z0-9_]+)", in: trimmed, captureGroup: 2) {
            if trimmed.contains("{") || trimmed.contains("->") || trimmed.contains("closure") {
                return "closure \(match)"
            }
            return "property \(match)"
        }

        if trimmed.contains("init") { return "initializer" }

        if let match = firstRegexMatch(pattern: "([A-Za-z0-9_]+)\\s*=\\s*\\{", in: trimmed) {
            return "closure \(match)"
        }

        if let match = firstRegexMatch(pattern: "([A-Za-z0-9_]+)\\s*\\{", in: trimmed) {
            return "\(match) block"
        }

        return "block"
    }

    private func firstRegexMatch(pattern: String, in text: String, captureGroup: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, options: [], range: nsRange) {
            if match.numberOfRanges > captureGroup, let range = Range(match.range(at: captureGroup), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    private func count(pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }
}
