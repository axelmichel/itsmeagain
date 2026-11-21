import Foundation
import SwiftSoup

/// Just enough MIME to read newsletters and mail fast from Mail's raw `source()` (≈50 ms) instead of
/// `content()` (≈7 s): headers, multipart, base64 / quoted-printable, charsets, RFC 2047 words.
public struct ParsedMail: Sendable, Equatable {
    /// Lowercased header names; repeated headers are joined with ", ".
    public var headers: [String: String]
    public var plainText: String?
    public var html: String?

    /// Best readable text: HTML (with links kept as "text (url)") or plain text.
    public var readableText: String {
        if let html, !html.isEmpty { return NewsletterText.extract(html) }
        return plainText ?? ""
    }
}

public enum MIMEParser {
    public static func parse(_ raw: String) -> ParsedMail {
        var result = ParsedMail(headers: [:])
        let (headerBlock, body) = split(raw)
        result.headers = headers(headerBlock)
        collect(headers: result.headers, body: body, into: &result, depth: 0)
        return result
    }

    static func split(_ text: String) -> (String, String) {
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = text.range(of: separator) {
                return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
            }
        }
        return (text, "")
    }

    static func headers(_ block: String) -> [String: String] {
        var unfolded: [String] = []
        for line in block.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(String(line))
            }
        }
        var headers: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = decodeWords(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        return headers
    }

    private static func collect(headers: [String: String], body: String, into result: inout ParsedMail, depth: Int) {
        guard depth < 8 else { return }
        let contentType = headers["content-type"] ?? "text/plain"
        let type = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        if type.hasPrefix("multipart/"), let boundary = parameter("boundary", in: contentType) {
            for part in body.components(separatedBy: "--\(boundary)").dropFirst() {
                if part.hasPrefix("--") { break }
                let (partHeaders, partBody) = split(part.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")))
                collect(headers: self.headers(partHeaders), body: partBody, into: &result, depth: depth + 1)
            }
            return
        }
        guard type == "text/plain" || type == "text/html" else { return }
        if (headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") { return }
        let text = decodeBody(body, encoding: headers["content-transfer-encoding"], charset: parameter("charset", in: contentType))
        if type == "text/html" {
            if result.html == nil { result.html = text }
        } else if result.plainText == nil {
            result.plainText = text
        }
    }

    static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == name {
                return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    static func decodeBody(_ body: String, encoding: String?, charset: String?) -> String {
        let data: Data
        switch encoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            data = Data(base64Encoded: body.filter { !$0.isWhitespace }) ?? Data()
        case "quoted-printable":
            data = quotedPrintable(body, header: false)
        default:
            return body
        }
        return string(data, charset: charset)
    }

    static func quotedPrintable(_ text: String, header: Bool) -> Data {
        var bytes: [UInt8] = []
        let utf8 = Array(text.utf8)
        var index = 0
        while index < utf8.count {
            let byte = utf8[index]
            if byte == UInt8(ascii: "=") {
                if index + 2 < utf8.count, let value = UInt8(String(decoding: utf8[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                    bytes.append(value)
                    index += 3
                    continue
                }
                // Soft line break "=\r\n" / "=\n".
                if index + 1 < utf8.count, utf8[index + 1] == UInt8(ascii: "\n") { index += 2; continue }
                if index + 2 < utf8.count, utf8[index + 1] == UInt8(ascii: "\r"), utf8[index + 2] == UInt8(ascii: "\n") { index += 3; continue }
            }
            bytes.append(header && byte == UInt8(ascii: "_") ? UInt8(ascii: " ") : byte)
            index += 1
        }
        return Data(bytes)
    }

    static func string(_ data: Data, charset: String?) -> String {
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId,
                let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)))
            {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// RFC 2047: "=?utf-8?Q?Gr=C3=BC=C3=9Fe?=" → "Grüße".
    static func decodeWords(_ value: String) -> String {
        let pattern = /=\?([^?]+)\?([BbQq])\?([^?]*)\?=/
        var result = value.replacing(/\?=\s+=\?/, with: "?==?")  // whitespace between encoded words is dropped
        result = result.replacing(pattern) { match in
            let charset = String(match.output.1)
            let text = String(match.output.3)
            let data = match.output.2.lowercased() == "b"
                ? Data(base64Encoded: text) ?? Data()
                : quotedPrintable(text, header: true)
            return string(data, charset: charset)
        }
        return result
    }
}

/// Newsletter HTML → text with line breaks and links ("text (url)"), so items keep their sources.
public enum NewsletterText {
    static let blocks: Set<String> = ["p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "section", "article", "blockquote", "hr"]
    static let skipped: Set<String> = ["script", "style", "head", "title", "noscript", "svg"]

    public static func extract(_ html: String, maxLinks: Int = 150) -> String {
        guard let document = try? SwiftSoup.parse(html), let body = document.body() else { return "" }
        var output = ""
        var links = 0
        func walk(_ node: Node) {
            if let text = node as? TextNode {
                let value = text.text().replacingOccurrences(of: "\u{00A0}", with: " ")
                let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !collapsed.isEmpty {
                    if !output.isEmpty, !output.hasSuffix("\n"), !output.hasSuffix(" ") { output += " " }
                    output += collapsed
                }
                return
            }
            guard let element = node as? Element else { return }
            let name = element.tagName().lowercased()
            if skipped.contains(name) { return }
            let isBlock = blocks.contains(name)
            if isBlock, !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
            for child in element.getChildNodes() { walk(child) }
            if name == "a", links < maxLinks, let href = try? element.attr("href"), href.hasPrefix("http"),
                !((try? element.text()) ?? "").isEmpty
            {
                output += " (\(href))"
                links += 1
            }
            if isBlock, !output.hasSuffix("\n") { output += "\n" }
        }
        walk(body)
        // Collapse runs of blank lines.
        return output.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
