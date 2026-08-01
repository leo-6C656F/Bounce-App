import Foundation
import PlaudBleSDK
import PlaudDeviceBasicSDK

/// Recording quality settings for the currently paired recorder.
///
/// **Tier 2 for everything except mic gain**, per `docs/plans/sdk-expansion.md`
/// Phase 3: `BleAgent`'s scene/mode/VAD/VPU-gain commands have no confirming
/// callback on `PlaudDeviceAgentProtocol` — only on `BleAgentProtocol`, which
/// isn't safe to intercept (see Phase 5) — so those four are fire-and-forget.
/// Nothing here is assumed to be the device's factory default: each setting
/// starts as `nil` ("no preference set from Bounce") and only becomes
/// non-nil once the user actively picks a value, at which point it's both
/// sent to the recorder and remembered per device serial. It can still
/// drift if the setting is changed from the recorder's own screen — this is
/// "last requested by Bounce," not verified device state.
///
/// Mic gain is the one exception: `setMicGain`/`readMicGain` and the
/// `bleMicGain` callback all live on `PlaudDeviceAgent`, so it really is read
/// back from the device rather than assumed.
@Observable
final class DeviceSettings {

    static let shared = DeviceSettings()

    private let defaults = UserDefaults.standard

    /// Last value reported by `bleMicGain`, or `nil` before the first read
    /// completes. Written only from `DeviceManager`'s callback forward — the
    /// SDK gives no documented range, so this is shown and edited as a raw
    /// integer rather than a normalised scale.
    private(set) var micGain: Int?

    private init() {}

    // MARK: - Tier 1: mic gain (real device state)

    func refreshMicGain() {
        PlaudDeviceAgent.shared.readMicGain()
    }

    func setMicGain(_ value: Int) {
        PlaudDeviceAgent.shared.setMicGain(value: value)
    }

    /// Called by `DeviceManager` when `bleMicGain` fires.
    func handleMicGain(_ value: Int) {
        micGain = value
    }

    // MARK: - Tier 2: fire-and-forget, "last requested" per device serial

    func scene(for serial: String) -> RecScene? {
        storedRawValue(key("recScene", serial)).flatMap(RecScene.init)
    }

    func setScene(_ scene: RecScene, for serial: String) {
        defaults.set(scene.rawValue, forKey: key("recScene", serial))
        BleAgent.shared.setRecScene(type: scene)
    }

    func mode(for serial: String) -> RecMode? {
        storedRawValue(key("recMode", serial)).flatMap(RecMode.init)
    }

    func setMode(_ mode: RecMode, for serial: String) {
        defaults.set(mode.rawValue, forKey: key("recMode", serial))
        BleAgent.shared.setRecMode(type: mode)
    }

    func vadEnabled(for serial: String) -> Bool? {
        defaults.object(forKey: key("vadEnabled", serial)) as? Bool
    }

    func setVadEnabled(_ enabled: Bool, for serial: String) {
        defaults.set(enabled, forKey: key("vadEnabled", serial))
        BleAgent.shared.openVAD(open: enabled)
    }

    func vadSensitivity(for serial: String) -> VadSensitivity? {
        storedRawValue(key("vadSensitivity", serial)).flatMap(VadSensitivity.init)
    }

    func setVadSensitivity(_ sensitivity: VadSensitivity, for serial: String) {
        defaults.set(sensitivity.rawValue, forKey: key("vadSensitivity", serial))
        BleAgent.shared.setVadSensitivity(sensitivity: sensitivity)
    }

    func vpuGain(for serial: String) -> VpuGain? {
        storedRawValue(key("vpuGain", serial)).flatMap(VpuGain.init)
    }

    func setVpuGain(_ gain: VpuGain, for serial: String) {
        defaults.set(gain.rawValue, forKey: key("vpuGain", serial))
        BleAgent.shared.setVpuGain(gain: gain)
    }

    // MARK: - LED Control (Tier 2: fire-and-forget per serial)

    /// Whether the recording LED indicator light is enabled (true) or discreet (false).
    /// `nil` before the user sets an explicit preference from Bounce.
    func ledEnabled(for serial: String) -> Bool? {
        defaults.object(forKey: key("ledEnabled", serial)) as? Bool
    }

    func setLedEnabled(_ enabled: Bool, for serial: String) {
        defaults.set(enabled, forKey: key("ledEnabled", serial))
        BleAgent.shared.setLedState(onOff: enabled ? 1 : 0)
    }

    // MARK: - Auto Power-Off (Tier 2: fire-and-forget per serial)

    enum AutoPowerOffOption: Int, CaseIterable, Identifiable {
        case never = 0
        case fiveMinutes = 5
        case tenMinutes = 10
        case fifteenMinutes = 15
        case thirtyMinutes = 30

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .never: return "Never"
            case .fiveMinutes: return "5 minutes"
            case .tenMinutes: return "10 minutes"
            case .fifteenMinutes: return "15 minutes"
            case .thirtyMinutes: return "30 minutes"
            }
        }
    }

    func autoPowerOff(for serial: String) -> AutoPowerOffOption? {
        storedRawValue(key("autoPowerOff", serial)).flatMap(AutoPowerOffOption.init)
    }

    func setAutoPowerOff(_ option: AutoPowerOffOption, for serial: String) {
        defaults.set(option.rawValue, forKey: key("autoPowerOff", serial))
        BleAgent.shared.setAutoPowerOff(value: option.rawValue)
    }

    private func storedRawValue(_ key: String) -> Int? {
        defaults.object(forKey: key) as? Int
    }

    private func key(_ setting: String, _ serial: String) -> String {
        "deviceSettings.\(setting).\(serial)"
    }
}

