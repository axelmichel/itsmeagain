import Foundation
import Synchronization

/// Serves canned responses keyed by URL host, so parallel tests can each use their own host.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int = 200
        var body: Data
        var contentType = "application/json"
    }

    typealias Handler = @Sendable (URLRequest, Data) -> Response

    private static let handlers = Mutex<[String: Handler]>([:])

    /// Registers a handler on a fresh host and returns a session plus the base URL to use.
    static func make(_ handler: @escaping Handler) -> (URLSession, URL) {
        // Dotted, public-looking name so URL policies (e.g. fetch_page's private-host check) accept it.
        let host = "\(UUID().uuidString.lowercased()).stub.example"
        handlers.withLock { $0[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return (URLSession(configuration: configuration), URL(string: "http://\(host)")!)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
            let handler = Self.handlers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = handler(request, Self.body(of: request))
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": response.contentType]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension AsyncThrowingStream where Element: Sendable {
    func collect() async throws -> [Element] {
        var result: [Element] = []
        for try await element in self { result.append(element) }
        return result
    }
}
