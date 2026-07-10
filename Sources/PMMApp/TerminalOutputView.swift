import AppKit
import Darwin
import SwiftUI

struct TerminalOutputTextView: NSViewRepresentable {
    static let columns = 80
    static let rows = 24
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    static let eightyColumnWidth = ceil(("M" as NSString).size(withAttributes: [.font: font]).width * CGFloat(columns))
    static let scrollViewWidth = NSScrollView.frameSize(
        forContentSize: NSSize(width: eightyColumnWidth, height: 300),
        horizontalScrollerClass: nil,
        verticalScrollerClass: NSScroller.self,
        borderType: .noBorder,
        controlSize: .regular,
        scrollerStyle: .legacy
    ).width

    let output: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let rendered = mainWindowTerminalAttributedOutput(output)
        guard !textView.attributedString().isEqual(to: rendered) else { return }
        textView.textStorage?.setAttributedString(rendered)
        textView.scrollToEndOfDocument(nil)
    }
}

func mainWindowTerminalAttributedOutput(_ output: String) -> NSAttributedString {
    var screen = TerminalScreen(columns: TerminalOutputTextView.columns, rows: TerminalOutputTextView.rows)
    screen.consume(output)
    return screen.attributedString()
}

private struct TerminalStyle {
    var color = NSColor.labelColor
    var bold = false
}

private struct TerminalCell {
    var character: Character?
    var style: TerminalStyle
    var isContinuation = false
}

private struct TerminalScreen {
    let columns: Int
    let visibleRows: Int
    private var lines: [[TerminalCell?]]
    private var cursorRow = 0
    private var cursorColumn = 0
    private var viewportTop = 0
    private var wrapPending = false
    private var style = TerminalStyle()
    private var savedCursor: (row: Int, column: Int)?

    init(columns: Int, rows: Int) {
        self.columns = columns
        visibleRows = rows
        lines = [Array(repeating: nil, count: columns)]
    }

    mutating func consume(_ output: String) {
        var index = output.startIndex
        while index < output.endIndex {
            let character = output[index]
            if character == "\u{1B}" {
                consumeEscape(in: output, index: &index)
            } else {
                consume(character)
                index = output.index(after: index)
            }
        }
    }

    func attributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lastContentRow = lines.lastIndex { $0.contains { $0 != nil } } ?? 0
        let lastRow = min(max(lastContentRow, cursorRow), lines.count - 1)

        for rowIndex in 0...lastRow {
            let line = lines[rowIndex]
            let lastCell = line.lastIndex { $0 != nil } ?? -1
            if lastCell >= 0 {
                for column in 0...lastCell {
                    guard let cell = line[column], !cell.isContinuation else { continue }
                    result.append(NSAttributedString(
                        string: String(cell.character ?? " "),
                        attributes: [
                            .font: cell.style.bold ? TerminalOutputTextView.boldFont : TerminalOutputTextView.font,
                            .foregroundColor: cell.style.color,
                        ]
                    ))
                }
            }
            if rowIndex < lastRow {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [.font: TerminalOutputTextView.font, .foregroundColor: NSColor.labelColor]
                ))
            }
        }
        return result
    }

    private mutating func consume(_ character: Character) {
        switch character {
        case "\r\n":
            lineFeed()
        case "\r":
            cursorColumn = 0
            wrapPending = false
        case "\n":
            lineFeed()
        case "\u{8}":
            cursorColumn = max(cursorColumn - 1, 0)
            wrapPending = false
        case "\t":
            cursorColumn = min(((cursorColumn / 8) + 1) * 8, columns - 1)
            wrapPending = false
        case "\u{7}", "\u{0}":
            break
        default:
            guard !character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) else { return }
            put(character)
        }
    }

    private mutating func put(_ character: Character) {
        var width = character.unicodeScalars.reduce(0) { partial, scalar in
            max(partial, Int(Darwin.wcwidth(wchar_t(scalar.value))))
        }
        if width < 1 { width = 1 }
        width = min(width, 2)

        if wrapPending || cursorColumn + width > columns {
            lineFeed()
        }
        ensureRow(cursorRow)
        lines[cursorRow][cursorColumn] = TerminalCell(character: character, style: style)
        if width == 2, cursorColumn + 1 < columns {
            lines[cursorRow][cursorColumn + 1] = TerminalCell(character: nil, style: style, isContinuation: true)
        }

        if cursorColumn + width >= columns {
            cursorColumn = columns - 1
            wrapPending = true
        } else {
            cursorColumn += width
        }
    }

    private mutating func lineFeed() {
        wrapPending = false
        cursorColumn = 0
        if cursorRow >= viewportTop + visibleRows - 1 {
            cursorRow += 1
            viewportTop += 1
        } else {
            cursorRow += 1
        }
        ensureRow(cursorRow)
    }

    private mutating func consumeEscape(in output: String, index: inout String.Index) {
        let next = output.index(after: index)
        guard next < output.endIndex else {
            index = next
            return
        }

        switch output[next] {
        case "[":
            consumeCSI(in: output, start: output.index(after: next), index: &index)
        case "]":
            consumeOSC(in: output, start: output.index(after: next), index: &index)
        case "7":
            savedCursor = (cursorRow, cursorColumn)
            index = output.index(after: next)
        case "8":
            restoreCursor()
            index = output.index(after: next)
        case "(", ")", "*", "+":
            let afterDesignator = output.index(after: next)
            index = afterDesignator < output.endIndex ? output.index(after: afterDesignator) : afterDesignator
        default:
            index = output.index(after: next)
        }
    }

    private mutating func consumeCSI(in output: String, start: String.Index, index: inout String.Index) {
        var end = start
        while end < output.endIndex,
              let scalar = output[end].unicodeScalars.first,
              !(0x40...0x7E).contains(Int(scalar.value)) {
            end = output.index(after: end)
        }
        guard end < output.endIndex else {
            index = output.endIndex
            return
        }

        let rawParameters = String(output[start..<end])
        let parameters = rawParameters.drop(while: { "?<=>!".contains($0) })
        let values = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let command = output[end]
        executeCSI(command, values: values)
        index = output.index(after: end)
    }

    private mutating func consumeOSC(in output: String, start: String.Index, index: inout String.Index) {
        var end = start
        while end < output.endIndex {
            if output[end] == "\u{7}" {
                index = output.index(after: end)
                return
            }
            if output[end] == "\u{1B}" {
                let next = output.index(after: end)
                if next < output.endIndex, output[next] == "\\" {
                    index = output.index(after: next)
                    return
                }
            }
            end = output.index(after: end)
        }
        index = output.endIndex
    }

    private mutating func executeCSI(_ command: Character, values: [Int]) {
        let first = max(values.first ?? 1, 1)
        wrapPending = false
        switch command {
        case "A": cursorRow = max(cursorRow - first, viewportTop)
        case "B": moveCursorDown(first)
        case "C": cursorColumn = min(cursorColumn + first, columns - 1)
        case "D": cursorColumn = max(cursorColumn - first, 0)
        case "E":
            moveCursorDown(first)
            cursorColumn = 0
        case "F":
            cursorRow = max(cursorRow - first, viewportTop)
            cursorColumn = 0
        case "G", "`": cursorColumn = min(first - 1, columns - 1)
        case "H", "f":
            let row = max((values.first ?? 1) - 1, 0)
            let column = max((values.dropFirst().first ?? 1) - 1, 0)
            cursorRow = viewportTop + min(row, visibleRows - 1)
            cursorColumn = min(column, columns - 1)
            ensureRow(cursorRow)
        case "J": eraseDisplay(values.first ?? 0)
        case "K": eraseLine(values.first ?? 0)
        case "P": deleteCharacters(first)
        case "X": eraseCharacters(first)
        case "m": applySGR(values.isEmpty ? [0] : values)
        case "s": savedCursor = (cursorRow, cursorColumn)
        case "u": restoreCursor()
        default: break
        }
    }

    private mutating func moveCursorDown(_ count: Int) {
        cursorRow = min(cursorRow + count, viewportTop + visibleRows - 1)
        ensureRow(cursorRow)
    }

    private mutating func eraseLine(_ mode: Int) {
        ensureRow(cursorRow)
        switch mode {
        case 1:
            for column in 0...cursorColumn { lines[cursorRow][column] = nil }
        case 2:
            lines[cursorRow] = Array(repeating: nil, count: columns)
        default:
            for column in cursorColumn..<columns { lines[cursorRow][column] = nil }
        }
    }

    private mutating func eraseDisplay(_ mode: Int) {
        let bottom = min(viewportTop + visibleRows - 1, lines.count - 1)
        switch mode {
        case 1:
            if viewportTop < cursorRow {
                for row in viewportTop..<cursorRow { lines[row] = Array(repeating: nil, count: columns) }
            }
            eraseLine(1)
        case 2, 3:
            if viewportTop <= bottom {
                for row in viewportTop...bottom { lines[row] = Array(repeating: nil, count: columns) }
            }
        default:
            eraseLine(0)
            if cursorRow < bottom {
                for row in (cursorRow + 1)...bottom { lines[row] = Array(repeating: nil, count: columns) }
            }
        }
    }

    private mutating func deleteCharacters(_ count: Int) {
        ensureRow(cursorRow)
        let count = min(count, columns - cursorColumn)
        guard count > 0 else { return }
        lines[cursorRow].removeSubrange(cursorColumn..<(cursorColumn + count))
        lines[cursorRow].append(contentsOf: repeatElement(nil, count: count))
    }

    private mutating func eraseCharacters(_ count: Int) {
        ensureRow(cursorRow)
        for column in cursorColumn..<min(cursorColumn + count, columns) {
            lines[cursorRow][column] = nil
        }
    }

    private mutating func restoreCursor() {
        guard let savedCursor else { return }
        cursorRow = max(savedCursor.row, viewportTop)
        cursorColumn = min(max(savedCursor.column, 0), columns - 1)
        ensureRow(cursorRow)
    }

    private mutating func applySGR(_ values: [Int]) {
        var index = 0
        while index < values.count {
            switch values[index] {
            case 0: style = TerminalStyle()
            case 1: style.bold = true
            case 22: style.bold = false
            case 30...37: style.color = ansiColor(values[index] - 30, bright: false)
            case 39: style.color = .labelColor
            case 90...97: style.color = ansiColor(values[index] - 90, bright: true)
            case 38 where index + 2 < values.count && values[index + 1] == 5:
                style.color = ansi256Color(values[index + 2])
                index += 2
            case 38 where index + 4 < values.count && values[index + 1] == 2:
                style.color = NSColor(
                    red: CGFloat(values[index + 2]) / 255,
                    green: CGFloat(values[index + 3]) / 255,
                    blue: CGFloat(values[index + 4]) / 255,
                    alpha: 1
                )
                index += 4
            default: break
            }
            index += 1
        }
    }

    private func ansiColor(_ value: Int, bright: Bool) -> NSColor {
        switch value {
        case 0: return bright ? .secondaryLabelColor : .black
        case 1: return .systemRed
        case 2: return .systemGreen
        case 3: return .systemYellow
        case 4: return .systemBlue
        case 5: return .systemPurple
        case 6: return .systemCyan
        default: return bright ? .labelColor : .systemGray
        }
    }

    private func ansi256Color(_ value: Int) -> NSColor {
        if value < 16 { return ansiColor(value % 8, bright: value >= 8) }
        if value >= 232 {
            let component = CGFloat(8 + (value - 232) * 10) / 255
            return NSColor(red: component, green: component, blue: component, alpha: 1)
        }
        let value = min(max(value, 16), 231) - 16
        let components = [value / 36, (value / 6) % 6, value % 6].map { $0 == 0 ? 0 : 55 + $0 * 40 }
        return NSColor(
            red: CGFloat(components[0]) / 255,
            green: CGFloat(components[1]) / 255,
            blue: CGFloat(components[2]) / 255,
            alpha: 1
        )
    }

    private mutating func ensureRow(_ row: Int) {
        while lines.count <= row {
            lines.append(Array(repeating: nil, count: columns))
        }
    }
}
