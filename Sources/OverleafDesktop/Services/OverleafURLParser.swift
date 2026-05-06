import Foundation

enum OverleafURLParser {
    /// Accepts any of:
    ///   https://www.overleaf.com/project/<id>
    ///   https://www.overleaf.com/project/<id>/...
    ///   https://git.overleaf.com/<id>
    ///   git@git.overleaf.com:<id>
    ///   <id> on its own (24-char hex)
    static func extractProjectID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let pattern = #"[a-f0-9]{24}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              let r = Range(match.range, in: trimmed) else {
            return nil
        }
        return String(trimmed[r]).lowercased()
    }
}
