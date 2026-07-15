import Foundation

struct ASRHotwordEntry: Hashable, Sendable {
    let text: String
    let languageCode: String?

    var aliyunPayload: [String: Any] {
        var payload: [String: Any] = [
            "text": text,
            "weight": 4
        ]
        if let languageCode {
            payload["lang"] = languageCode
        }
        return payload
    }
}

enum ASRHotwordFormatter {
    static func normalizedInput(_ rawValue: String) -> String {
        entries(from: rawValue)
            .map(\.text)
            .joined(separator: " ")
    }

    static func entries(from rawValue: String) -> [ASRHotwordEntry] {
        var entries: [ASRHotwordEntry] = []
        var current = String.UnicodeScalarView()

        func flushCurrent() {
            guard !current.isEmpty else { return }
            let text = String(current)
            entries.append(ASRHotwordEntry(text: text, languageCode: languageCode(for: text)))
            current.removeAll(keepingCapacity: true)
        }

        for scalar in rawValue.unicodeScalars {
            if isEnglishLetter(scalar) || isChineseCharacter(scalar) {
                current.append(scalar)
            } else {
                flushCurrent()
            }
        }
        flushCurrent()

        return entries
    }

    private static func languageCode(for text: String) -> String? {
        if text.unicodeScalars.contains(where: isChineseCharacter) {
            return "zh"
        }
        if text.unicodeScalars.allSatisfy(isEnglishLetter) {
            return "en"
        }
        return nil
    }

    private static func isEnglishLetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func isChineseCharacter(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x30000...0x3134F:
            return true
        default:
            return false
        }
    }
}
