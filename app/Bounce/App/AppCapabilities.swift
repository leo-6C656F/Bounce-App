import Foundation

/// Features that depend on entitlements the build may not be signed for.
///
/// WiFi Fast Transfer needs `HotspotConfiguration` and `wifi-info`, and Apple
/// only grants those to a **paid** Developer Program membership — a free
/// Personal Team cannot sign them, and the build fails outright if they are
/// declared. So the entitlements and this flag are both switched from
/// `app/project.yml`, together.
///
/// To turn WiFi Fast Transfer on, uncomment the two marked blocks in
/// `project.yml` and run `xcodegen generate`. Nothing else needs to change —
/// the transfer code is always compiled, just gated.
enum AppCapabilities {

    /// True only when the build is signed for the WiFi entitlements.
    ///
    /// Gating matters beyond hiding a menu item: `startWiFiTransfer` calls
    /// `CLLocationManager.requestWhenInUseAuthorization()`, and iOS terminates
    /// the app if that is called without `NSLocationWhenInUseUsageDescription`
    /// in Info.plist — which is also removed when the entitlements are.
    static var wifiFastTransfer: Bool {
        #if BOUNCE_WIFI_FAST_TRANSFER
        return true
        #else
        return false
        #endif
    }
}
