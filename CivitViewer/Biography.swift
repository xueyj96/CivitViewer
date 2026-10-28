import Foundation

struct CreatorBiography: Decodable {
    let id: Int
    let username: String
    let profile: Profile?
    let blockedByThem: Bool?
    struct Profile: Decodable { let bio: String? }
}

enum BiographyText {
    static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func plain(_ raw: String) -> String {
        var result = raw
        func replacing(_ pattern: String, _ template: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        // Native Text renders this output. No WebView/HTML importer, script,
        // remote image, CSS or embedded object is loaded for a biography.
        replacing("(?is)<(script|style|iframe|object|template)\\b[^>]*>.*?</\\1\\s*>", "")
        if let regex = try? NSRegularExpression(pattern: "(?is)<a\\b[^>]*href\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a\\s*>") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let href = Range(match.range(at: 1), in: result), let label = Range(match.range(at: 2), in: result) else { continue }
                let text = String(result[label])
                let address = decodeEntities(String(result[href]))
                result.replaceSubrange(whole, with: safeURL(address).map { text + " (" + $0.absoluteString + ")" } ?? text)
            }
        }
        replacing("(?i)<br\\s*/?>|</(?:p|div|li|h[1-6]|blockquote)\\s*>", "\n")
        replacing("<[^>]*>", "")
        return decodeEntities(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func decodeEntities(_ raw: String) -> String {
        var result = raw
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let body = Range(match.range(at: 1), in: result) else { continue }
                let token = String(result[body])
                let number = token.lowercased().hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
                if let number, let scalar = UnicodeScalar(number), !CharacterSet.controlCharacters.contains(scalar) { result.replaceSubrange(whole, with: String(scalar)) }
            }
        }
        for (entity, value) in [("&lt;", "<"),("&gt;", ">"),("&quot;", "\""),("&apos;", "'"),("&#39;", "'"),("&nbsp;", " "),("&amp;", "&")] { result = result.replacingOccurrences(of: entity, with: value) }
        return result
    }
    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let raw = $0.url?.absoluteString, let safe = safeURL(raw), seen.insert(safe.absoluteString).inserted else { return nil }
            return safe
        }
    }
}
