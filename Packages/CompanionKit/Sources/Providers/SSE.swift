import Foundation

enum SSE {
    /// The `data:` payloads of a Server-Sent Events stream.
    ///
    /// `AsyncLineSequence` drops blank lines, so events can't be split on them; both the Anthropic
    /// and OpenAI streams put a whole JSON event on a single `data:` line (and repeat its type
    /// inside the JSON), so `event:`/`id:` lines and comments are skipped.
    static func data<Lines: AsyncSequence>(_ lines: Lines) -> AsyncThrowingStream<String, Error>
    where Lines.Element == String, Lines: Sendable {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines where line.hasPrefix("data:") {
                        var payload = line.dropFirst(5)
                        if payload.first == " " { payload = payload.dropFirst() }
                        continuation.yield(String(payload))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
