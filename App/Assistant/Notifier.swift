import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// Local notifications for automation results. Permission is requested on first use (when an
/// automation is enabled), not at launch. Clicking a notification opens its conversation.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let conversationKey = "conversationID"
    nonisolated static let memoryKey = "openMemory"

    /// Called with `Conversation.id` when the user clicks a notification.
    var onOpenConversation: (UUID) -> Void = { _ in }
    var onOpenMemory: () -> Void = {}

    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asks once; returns whether notifications are allowed.
    @discardableResult
    func requestPermission() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    func post(title: String, body: String, conversationID: UUID?, opensMemory: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let conversationID { content.userInfo = [Self.conversationKey: conversationID.uuidString] }
        if opensMemory { content.userInfo = [Self.memoryKey: true] }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]  // also while the app is in front
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.userInfo[Self.memoryKey] as? Bool == true {
            await MainActor.run { onOpenMemory() }
            return
        }
        let raw = response.notification.request.content.userInfo[Self.conversationKey] as? String
        guard let raw, let id = UUID(uuidString: raw) else { return }
        await MainActor.run { onOpenConversation(id) }
    }
}

/// "Open at Login" via SMAppService. It registers the app at its current location, so use the copy in
/// /Applications (`make install`), not a debug build.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static var runsFromApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
