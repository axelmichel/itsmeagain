import CompanionCore
import Foundation

enum HTTP {
    /// Throws `ProviderError.http` for non-2xx responses, using the body's error message when present.
    static func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("not an HTTP response")
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        throw ProviderError.http(status: http.statusCode, message: errorMessage(from: body))
    }

    /// Streaming variant: on error, drains (a bounded part of) the body to build the message.
    static func validate(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("not an HTTP response")
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count >= 16_384 { break }
        }
        throw ProviderError.http(status: http.statusCode, message: errorMessage(from: body))
    }

    /// Understands `{"error": "..."}` (Ollama) and `{"error": {"message": "..."}}` (OpenAI, Anthropic).
    static func errorMessage(from body: Data) -> String {
        if let json = try? JSONDecoder().decode(JSONValue.self, from: body) {
            if let message = json["error"]?.stringValue { return message }
            if let message = json["error"]?["message"]?.stringValue { return message }
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "request failed" : text
    }

    /// Maps "nothing is listening" style errors to a readable `ProviderError.unavailable`.
    static func mapConnectionError(_ error: Error, service: String, url: URL) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut, .notConnectedToInternet:
            return ProviderError.unavailable("\(service) is not reachable at \(url.absoluteString).")
        default:
            return error
        }
    }
}
