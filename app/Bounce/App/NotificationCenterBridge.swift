import Foundation
import Observation
import UserNotifications

/// The app's only door onto `UNUserNotificationCenter`.
///
/// **No `Info.plist` key is required for local notifications** — authorization is
/// requested at runtime and that is the whole permission story. Don't add one.
///
/// Deliberately thin and deliberately quiet. Every call is safe to make in any
/// authorization state: when the user has said no, `postLowBattery` returns
/// without doing anything, and nothing here ever retries, loops, or throws into
/// the UI. A notification that fails to post is not worth an error banner.
///
/// The decision of *when* to post lives in `BatteryAlertLatch`, which is pure and
/// tested. This type only knows how.
@MainActor
@Observable
final class NotificationCenterBridge {

    static let shared = NotificationCenterBridge()

    /// Last known authorization state. Read by Settings to explain a denied
    /// toggle; refresh it with `refreshAuthorizationStatus()` (the user can
    /// change it in iOS Settings behind our back, so re-check on appear).
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Category for the low-battery notification. Registered so a future
    /// version can hang actions off it without a migration; it carries none yet.
    /// `nonisolated` so `cancelLowBattery()` can read it off the main actor.
    nonisolated static let lowBatteryCategory = "bounce.lowBattery"

    /// A *fixed* request identifier, so a second low-battery notification
    /// replaces the first rather than stacking. `BatteryAlertLatch` already
    /// makes duplicates unlikely; this makes them impossible to see.
    private nonisolated static let lowBatteryRequest = "bounce.lowBattery.request"

    /// Retained because `UNUserNotificationCenter.delegate` is weak. Kept as a
    /// separate object rather than conforming this `@MainActor` type to the
    /// delegate protocol — the callback is trivial and doesn't need main-actor
    /// isolation.
    private let presenter = ForegroundPresenter()

    private init() {
        let center = UNUserNotificationCenter.current()
        // Claims the process-wide delegate slot. Without it, a notification
        // posted while the app is foreground is swallowed silently — and the
        // user may well be on another tab.
        center.delegate = presenter
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.lowBatteryCategory,
                actions: [],
                intentIdentifiers: [],
                options: [])
        ])
    }

    // MARK: - Authorization

    /// Ask for permission. Returns whether we may post afterwards.
    ///
    /// Alert + sound only. **No badge**: nothing in the app displays or clears a
    /// count, so a badge would stick to the icon with no way to dismiss it from
    /// inside Bounce.
    ///
    /// Call this on first enable of a feature that needs it, never at launch —
    /// a permission prompt the user can't connect to anything they just did gets
    /// denied.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshAuthorizationStatus()
        return granted
    }

    /// Re-read the current status from the system.
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Whether a posted notification will actually be delivered.
    var canPost: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// The user has actively refused. Settings uses this to explain a toggle
    /// that can't be turned on, rather than asking again.
    var isDenied: Bool { authorizationStatus == .denied }

    // MARK: - Posting

    /// Post the low-battery notification. Silent no-op when we aren't allowed to.
    ///
    /// `interruptionLevel` stays `.active` on purpose: `.timeSensitive` needs the
    /// `com.apple.developer.usernotifications.time-sensitive` entitlement, which
    /// a free Personal Team cannot sign — declaring it fails the build, the same
    /// trap as the WiFi Fast Transfer entitlements.
    func postLowBattery(deviceName: String, level: Int) {
        guard canPost else { return }

        let content = UNMutableNotificationContent()
        content.title = "Recorder battery low"
        content.body = "\(deviceName) is at \(level)%. Charge it before your next recording."
        content.sound = .default
        content.categoryIdentifier = Self.lowBatteryCategory
        content.threadIdentifier = Self.lowBatteryCategory
        content.interruptionLevel = .active

        // `trigger: nil` delivers immediately.
        let request = UNNotificationRequest(
            identifier: Self.lowBatteryRequest,
            content: content,
            trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            // Nothing actionable: the user either sees it or doesn't. Logged
            // only in debug builds, and never with anything identifying.
            if let error {
                NotificationLog.log("add failed — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Removal

    /// Drop the low-battery notification, delivered or pending.
    ///
    /// `nonisolated` because `UNUserNotificationCenter.current()` isn't
    /// main-actor bound and this is worth being callable from a teardown path
    /// that isn't already on the main actor.
    nonisolated func cancelLowBattery() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.lowBatteryRequest])
        center.removeDeliveredNotifications(withIdentifiers: [Self.lowBatteryRequest])
    }
}

// MARK: - Foreground presentation

/// Shows notifications as banners even when Bounce is in the foreground. The
/// default behaviour is to deliver them silently to the notification centre,
/// which for a battery warning means the user never sees it.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Logging

/// Matches the `[Component]`-prefixed, `#if DEBUG`-gated shape of `DeviceLog`
/// and friends. No logging abstraction in this codebase by design.
enum NotificationLog {
    static func log(_ message: String) {
        #if DEBUG
        print("[Notifications] \(message)")
        #endif
    }
}
