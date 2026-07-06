import Foundation

enum TextUtilities {
    static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func suffixCharacters(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }

    static func nonEmpty(_ text: String) -> String? {
        let cleaned = normalized(text)
        return cleaned.isEmpty ? nil : cleaned
    }
}
