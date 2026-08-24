import Foundation

private enum TerminalSanitizerMode {
    case normal
    case escape
    case csi
    case stringControl
    case escapeInStringControl
}

/// Removes terminal control sequences from untrusted display text before the
/// renderer adds its own ANSI framing. CSI commands are discarded, OSC/DCS/
/// SOS/PM/APC payloads are discarded through BEL or ST, and remaining C0/C1
/// controls are replaced with spaces.
func sanitizeTerminalText(_ value: String) -> String {
    var mode = TerminalSanitizerMode.normal
    var result = String.UnicodeScalarView()

    for scalar in value.unicodeScalars {
        let code = scalar.value
        switch mode {
        case .normal:
            consumeNormalScalar(scalar, code: code, mode: &mode, result: &result)
        case .escape:
            consumeEscapeScalar(code, mode: &mode)
        case .csi:
            consumeCSIScalar(code, mode: &mode)
        case .stringControl:
            consumeStringControlScalar(code, mode: &mode)
        case .escapeInStringControl:
            consumeStringControlEscapeScalar(code, mode: &mode)
        }
    }

    return String(result)
}

private func consumeNormalScalar(
    _ scalar: Unicode.Scalar,
    code: UInt32,
    mode: inout TerminalSanitizerMode,
    result: inout String.UnicodeScalarView,
) {
    switch code {
    case 0x1B:
        mode = .escape
    case 0x9B:
        mode = .csi
    case 0x90, 0x98, 0x9D, 0x9E, 0x9F:
        mode = .stringControl
    case 0x00 ... 0x1F, 0x7F ... 0x9F:
        result.append(" ")
    default:
        result.append(scalar)
    }
}

private func consumeEscapeScalar(_ code: UInt32, mode: inout TerminalSanitizerMode) {
    switch code {
    case 0x5B:
        mode = .csi
    case 0x50, 0x58, 0x5D, 0x5E, 0x5F:
        mode = .stringControl
    case 0x30 ... 0x7E:
        mode = .normal
    case 0x1B:
        mode = .escape
    default:
        break
    }
}

private func consumeCSIScalar(_ code: UInt32, mode: inout TerminalSanitizerMode) {
    if 0x40 ... 0x7E ~= code {
        mode = .normal
    } else if code == 0x1B {
        mode = .escape
    }
}

private func consumeStringControlScalar(_ code: UInt32, mode: inout TerminalSanitizerMode) {
    if code == 0x07 || code == 0x9C {
        mode = .normal
    } else if code == 0x1B {
        mode = .escapeInStringControl
    }
}

private func consumeStringControlEscapeScalar(_ code: UInt32, mode: inout TerminalSanitizerMode) {
    if code == 0x5C || code == 0x9C {
        mode = .normal
    } else if code != 0x1B {
        mode = .stringControl
    }
}

/// Conservative terminal-cell width for macOS terminals. Unicode scalar
/// properties cover normal, wide CJK/emoji, and combining scalars. Grapheme
/// clusters are summed scalar-by-scalar, which can overestimate ZWJ/flag
/// sequences but will not underestimate and accidentally allow a physical wrap.
func terminalDisplayWidth(_ value: String) -> Int {
    value.reduce(into: 0) { width, character in
        width += terminalCharacterWidth(character)
    }
}

func fit(_ value: String, width: Int) -> String {
    guard width > 0 else { return "" }
    let singleLine = sanitizeTerminalText(value)
    guard terminalDisplayWidth(singleLine) > width else { return singleLine }
    guard width > 1 else { return "…" }

    let available = width - terminalCharacterWidth("…")
    var result = ""
    var used = 0
    for character in singleLine {
        let characterWidth = terminalCharacterWidth(character)
        guard used + characterWidth <= available else { break }
        result.append(character)
        used += characterWidth
    }
    return result + "…"
}

func wrap(_ value: String, width: Int) -> [String] {
    guard width > 1 else { return [fit(value, width: width)] }
    let words = sanitizeTerminalText(value).split(whereSeparator: \.isWhitespace).map(String.init)
    var lines: [String] = []
    var current = ""

    func flushCurrent() {
        guard !current.isEmpty else { return }
        lines.append(current)
        current = ""
    }

    for word in words {
        if terminalDisplayWidth(word) > width {
            flushCurrent()
            let segments = splitByTerminalWidth(word, width: width)
            lines += segments.dropLast()
            current = segments.last ?? ""
        } else if current.isEmpty {
            current = word
        } else if terminalDisplayWidth(current) + 1 + terminalDisplayWidth(word) <= width {
            current += " \(word)"
        } else {
            flushCurrent()
            current = word
        }
    }
    flushCurrent()
    return lines.isEmpty ? [""] : lines
}

private func terminalCharacterWidth(_ character: Character) -> Int {
    let scalars = character.unicodeScalars
    let scalarWidth = scalars.reduce(into: 0) { width, scalar in
        width += terminalScalarWidth(scalar)
    }
    let requestsEmojiPresentation = scalars.contains { scalar in
        scalar.value == 0xFE0F || scalar.value == 0x20E3
    }
    return requestsEmojiPresentation ? max(2, scalarWidth) : scalarWidth
}

private func terminalScalarWidth(_ scalar: Unicode.Scalar) -> Int {
    let code = scalar.value
    if code < 0x20 || 0x7F ... 0x9F ~= code {
        return 0
    }

    switch scalar.properties.generalCategory {
    case .nonspacingMark, .enclosingMark, .format:
        return 0
    default:
        break
    }

    // Unicode East Asian Wide/Fullwidth ranges used by current macOS
    // terminals. Emoji presentation scalars are also two cells. Scalars not
    // covered here conservatively fall back to one cell; multi-scalar emoji
    // clusters are summed, so ZWJ and flag sequences may truncate early but
    // can never force an unaccounted physical wrap.
    if scalar.properties.isEmojiPresentation || isEastAsianWide(code) {
        return 2
    }
    return 1
}

private func isEastAsianWide(_ code: UInt32) -> Bool {
    switch code {
    case 0x1100 ... 0x115F,
         0x2329 ... 0x232A,
         0x2E80 ... 0xA4CF,
         0xAC00 ... 0xD7A3,
         0xF900 ... 0xFAFF,
         0xFE10 ... 0xFE19,
         0xFE30 ... 0xFE6F,
         0xFF00 ... 0xFF60,
         0xFFE0 ... 0xFFE6,
         0x1F300 ... 0x1FAFF,
         0x20000 ... 0x3FFFD:
        true
    default:
        false
    }
}

private func splitByTerminalWidth(_ value: String, width: Int) -> [String] {
    var segments: [String] = []
    var current = ""
    var used = 0

    for character in value {
        let characterWidth = terminalCharacterWidth(character)
        if characterWidth > width {
            if !current.isEmpty {
                segments.append(current)
                current = ""
                used = 0
            }
            segments.append("…")
        } else if used + characterWidth > width {
            segments.append(current)
            current = String(character)
            used = characterWidth
        } else {
            current.append(character)
            used += characterWidth
        }
    }
    if !current.isEmpty {
        segments.append(current)
    }
    return segments.isEmpty ? [""] : segments
}
