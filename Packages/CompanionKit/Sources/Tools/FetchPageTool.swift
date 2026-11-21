import CompanionCore
import Foundation
import Network
import PDFKit
import SwiftSoup

/// Downloads a public web page (HTML, text or PDF) and returns its readable text.
public struct FetchPageTool: Tool {
    public let maxCharacters: Int
    public let maxBytes: Int
    private let session: URLSession

    public init(maxCharacters: Int = 12_000, maxBytes: Int = 5_000_000, session: URLSession = .shared) {
        self.maxCharacters = maxCharacters
        self.maxBytes = maxBytes
        self.session = session
    }

    /// The URL (which the model chooses) is requested from the internet.
    public var sendsDataExternally: Bool { true }

    public var spec: ToolSpec {
        ToolSpec(
            name: "fetch_page",
            description: "Download a public web page or PDF and return its main text. Use on URLs from web_search results or URLs the user gave.",
            parameters: [
                "type": "object",
                "properties": ["url": ["type": "string", "description": "Absolute http(s) URL"]],
                "required": ["url"],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let url = try Self.validatedURL(try arguments.requiredString("url"))
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) ItsMeAgain/0.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,text/plain,application/pdf;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ToolError.failed("No HTTP response.") }
        // Redirects are followed automatically; re-check where we ended up.
        if let final = http.url { _ = try Self.validatedURL(final.absoluteString) }
        guard (200..<300).contains(http.statusCode) else {
            throw ToolError.failed("The page returned HTTP \(http.statusCode).")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxBytes { break }
        }

        let mime = http.mimeType ?? ""
        let page: (title: String, text: String)
        if mime == "application/pdf" || url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(data: data) else { throw ToolError.failed("Couldn't read the PDF.") }
            page = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? url.lastPathComponent,
                    document.string ?? "")
        } else if mime.hasPrefix("text/html") || mime.contains("xhtml") || mime.isEmpty {
            page = try HTMLText.extract(String(decoding: data, as: UTF8.self), baseURL: url)
        } else if mime.hasPrefix("text/") || mime.contains("json") {
            page = (url.lastPathComponent, String(decoding: data, as: UTF8.self))
        } else {
            throw ToolError.failed("Unsupported content type \(mime).")
        }

        var text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters)) + "\n\n[… truncated]"
        }
        let title = page.title.isEmpty ? url.host() ?? url.absoluteString : page.title
        return ToolOutput(
            content: "Title: \(title)\nURL: \(url.absoluteString)\n\n\(text.isEmpty ? "(no readable text)" : text)",
            sources: [SourceRef(title: title, url: url.absoluteString)]
        )
    }

    // MARK: URL policy

    /// Only public http(s) URLs: no local files, localhost, LAN or link-local addresses.
    static func validatedURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host()?.lowercased(), !host.isEmpty
        else {
            throw ToolError.invalidArgument("Only absolute http(s) URLs can be fetched.")
        }
        if isPrivate(host: host) {
            throw ToolError.invalidArgument("Refusing to fetch a local or private-network address (\(host)).")
        }
        return url
    }

    static func isPrivate(host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa")
            || !host.contains(".") && IPv6Address(host) == nil
        {
            return true
        }
        if let v4 = IPv4Address(host) {
            let b = [UInt8](v4.rawValue)
            return b[0] == 0 || b[0] == 10 || b[0] == 127 || (b[0] == 169 && b[1] == 254)
                || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 100 && (64...127).contains(b[1]))
        }
        if let v6 = IPv6Address(host) {
            let b = [UInt8](v6.rawValue)
            return v6.isLoopback || v6.isLinkLocal || v6 == .any || (b[0] & 0xFE) == 0xFC
                || (v6.isIPv4Mapped && v6.asIPv4.map { isPrivate(host: "\($0)") } == true)
        }
        return false
    }
}

/// Readability-lite: drops page chrome and keeps headings, paragraphs, lists, code and table cells.
public enum HTMLText {
    public static func extract(_ html: String, baseURL: URL) throws -> (title: String, text: String) {
        let document = try SwiftSoup.parse(html, baseURL.absoluteString)
        let title = try document.title()
        try document.select("script, style, noscript, svg, nav, header, footer, aside, form, iframe, button, [aria-hidden=true], [role=navigation]").remove()

        let root = try document.select("article").first() ?? document.select("main").first() ?? document.body()
        guard let root else { return (title, "") }

        var lines: [String] = []
        for element in try root.select("h1, h2, h3, h4, p, li, pre, blockquote, td, th, dt, dd") {
            // Nested matches (p inside li, …) would repeat text; keep the innermost block.
            if try !element.select("p, li, pre, blockquote").filter({ $0 !== element }).isEmpty { continue }
            let text = try element.text(trimAndNormaliseWhitespace: element.tagName() != "pre")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            switch element.tagName() {
            case "h1": lines.append("# \(trimmed)")
            case "h2": lines.append("## \(trimmed)")
            case "h3", "h4": lines.append("### \(trimmed)")
            case "li": lines.append("- \(trimmed)")
            case "pre": lines.append("```\n\(trimmed)\n```")
            case "p" where element.parents().contains(where: { $0.tagName() == "li" }):
                lines.append("- \(trimmed)")
            default: lines.append(trimmed)
            }
        }
        if lines.isEmpty { lines = [try root.text()] }
        return (title, lines.joined(separator: "\n\n"))
    }
}
