import Foundation
import Tools

/// How to leave a mailing list, best option first: a one-click POST (RFC 8058) needs no page,
/// a plain link opens in the browser, a mailto becomes a draft the user sends.
public enum UnsubscribeMethod: Sendable, Hashable {
    case oneClick(URL)
    case openPage(URL)
    case mailto(address: String, subject: String)

    public static func best(for bulk: BulkInfo) -> UnsubscribeMethod? {
        if let link = bulk.unsubscribeURL, let url = try? FetchPageTool.validatedURL(link) {
            return bulk.oneClick ? .oneClick(url) : .openPage(url)
        }
        guard let mailto = bulk.unsubscribeMailto, !mailto.isEmpty else { return nil }
        // mailto:leave@x.example?subject=unsubscribe
        let parts = mailto.split(separator: "?", maxSplits: 1)
        let address = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let query = parts.count > 1 ? URLComponents(string: "?" + parts[1])?.queryItems : nil
        let subject = query?.first { $0.name.lowercased() == "subject" }?.value ?? "unsubscribe"
        return .mailto(address: address, subject: subject)
    }
}

public enum Unsubscriber {
    /// Sends the RFC 8058 one-click request. Only call this on an explicit user action, and never
    /// for spam: it confirms the address is read.
    public static func oneClick(_ url: URL, session: URLSession = .shared) async throws {
        let url = try FetchPageTool.validatedURL(url.absoluteString)
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        let (_, response) = try await session.data(for: request)
        if let final = response.url { _ = try FetchPageTool.validatedURL(final.absoluteString) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MailError.script("The unsubscribe request was refused (HTTP \(code)).")
        }
    }
}
