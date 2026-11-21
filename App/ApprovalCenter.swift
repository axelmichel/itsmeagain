import Foundation
import Observation
import Tools

/// Pending write approvals from chats (and later automations). A tool loop waits in `request` until
/// the user approves or denies; cancelling the turn counts as a denial.
@MainActor
@Observable
final class ApprovalCenter {
    private(set) var pending: [String: ApprovalRequest] = [:]
    @ObservationIgnored private var continuations: [String: CheckedContinuation<Bool, Never>] = [:]

    func request(_ request: ApprovalRequest) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending[request.id] = request
                continuations[request.id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.resolve(request.id, granted: false) }
        }
    }

    func resolve(_ id: String, granted: Bool) {
        pending[id] = nil
        continuations.removeValue(forKey: id)?.resume(returning: granted)
    }
}
