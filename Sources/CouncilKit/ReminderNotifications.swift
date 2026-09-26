import Foundation
import UserNotifications

/// Small runtime facts shared across the engine.
enum CouncilRuntime {
    /// True inside `swift test` / XCTest — the engine must never touch the Keychain or the
    /// notification center from a test process.
    static let isRunningTests = NSClassFromString("XCTestCase") != nil
    /// Local notifications need a real app bundle; the `council` CLI has none and skips them.
    static var notificationsPossible: Bool { Bundle.main.bundleIdentifier != nil && !isRunningTests }
}

/// Outcome reminders as real macOS notifications.
///
/// The journal is the source of truth and the notification center is a derived cache: every change
/// to a decision, outcome or reminder re-syncs the pending requests, and the app re-syncs on launch.
/// That matters because the free build is ad-hoc signed — macOS may forget the app's notification
/// grant after an update — so a lost notification never loses the reminder itself: the in-app
/// "outcome due" section keeps working regardless.
extension CouncilStore {
    public static let reminderCategoryID = "council.reminder"
    public static let reminderLogActionID = "council.reminder.log"
    /// `userInfo` key carrying the session UUID string, so a click can open that journal card.
    public static let reminderSessionKey = "sessionID"
    static let reminderIDPrefix = "council.reminder."

    static func reminderRequestID(_ id: UUID) -> String { reminderIDPrefix + id.uuidString }

    /// One scheduled reminder: which session, when, and the one line to show.
    public struct ScheduledReminder: Equatable, Sendable {
        public let id: UUID
        public let at: Date
        public let line: String
    }

    /// The reminders that deserve a notification right now: decision logged, outcome still open,
    /// reminder set and still in the future. Pure, so it's testable without a notification center.
    nonisolated public static func scheduledReminders(in sessions: [Session], now: Date) -> [ScheduledReminder] {
        sessions.compactMap { s in
            guard let decision = s.decision?.trimmingCharacters(in: .whitespacesAndNewlines), !decision.isEmpty,
                  (s.outcome ?? "").isEmpty,
                  let at = s.remindAt, at > now else { return nil }
            let title = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let line = title.isEmpty ? decision : "\(title) — \(decision)"
            return ScheduledReminder(id: s.id, at: at, line: Self.excerpt(line, max: 120))
        }
        .sorted { $0.at < $1.at }
    }

    nonisolated static func excerpt(_ s: String, max: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count <= max ? one : String(one.prefix(max - 1)) + "…"
    }

    /// Ask macOS for permission the first time the user sets a reminder (never at launch — an
    /// ad-hoc build would re-prompt after every update). Returns true when notifications can fire.
    public func requestReminderNotificationPermission() async -> Bool {
        guard CouncilRuntime.notificationsPossible else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            reminderNotificationsDenied = false
            return true
        case .denied:
            reminderNotificationsDenied = true
            return false
        default:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            reminderNotificationsDenied = !granted
            return granted
        }
    }

    /// Bring the pending notifications in line with the journal. Cheap and idempotent — called after
    /// every journal edit and once at launch. Does nothing without permission (the in-app due list
    /// is the fallback), and records a denial so the journal card can point at System Settings.
    public func syncReminderNotifications() {
        guard CouncilRuntime.notificationsPossible else { return }
        let desired = Self.scheduledReminders(in: sessions, now: Date())
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            reminderNotificationsDenied = settings.authorizationStatus == .denied
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }

            let pending = await center.pendingNotificationRequests()
                .filter { $0.identifier.hasPrefix(Self.reminderIDPrefix) }
            var keep = Set<String>()
            var stale: [String] = []
            for request in pending {
                let wanted = desired.first { Self.reminderRequestID($0.id) == request.identifier }
                let fireDate = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                if let wanted, let fireDate, abs(fireDate.timeIntervalSince(wanted.at)) < 60 {
                    keep.insert(request.identifier)          // already scheduled for the right time
                } else {
                    stale.append(request.identifier)         // outcome logged, reminder moved or cleared
                }
            }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
            // A banner already sitting in Notification Center for a loop that has since been closed
            // (outcome logged, session deleted) goes too.
            let delivered = await center.deliveredNotifications()
                .map(\.request.identifier)
                .filter { id in
                    id.hasPrefix(Self.reminderIDPrefix)
                        && !desired.contains { Self.reminderRequestID($0.id) == id }
                }
            if !delivered.isEmpty { center.removeDeliveredNotifications(withIdentifiers: delivered) }

            for reminder in desired where !keep.contains(Self.reminderRequestID(reminder.id)) {
                let content = UNMutableNotificationContent()
                content.title = "Council — how did it turn out?"
                content.body = reminder.line
                content.sound = .default
                content.categoryIdentifier = Self.reminderCategoryID
                content.userInfo = [Self.reminderSessionKey: reminder.id.uuidString]
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                            from: reminder.at)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: Self.reminderRequestID(reminder.id),
                                                            content: content, trigger: trigger))
            }
        }
    }
}
