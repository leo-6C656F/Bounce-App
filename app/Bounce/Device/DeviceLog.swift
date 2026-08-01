import Foundation

/// Logging for the Bluetooth / SDK path, debug builds only.
///
/// Exists for the same reason `AuthLog` does: when a scan comes back empty
/// there is no way to tell "the radio never started", "the SDK isn't ready",
/// "nothing advertised", and "something advertised but we filtered it out"
/// apart from the outside. Serial numbers are logged in full — they are printed
/// on the hardware and are not a secret.
enum DeviceLog {

    static func log(_ message: String) {
        #if DEBUG
        print("[Device] \(message)")
        #endif
    }
}
