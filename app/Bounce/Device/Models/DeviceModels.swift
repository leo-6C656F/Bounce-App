import Foundation

// MARK: - Connection

/// BLE scanned device, shown for selection before connecting.
struct ScannedDevice: Equatable, Identifiable {
    let name: String
    let serialNumber: String
    let rssi: Float

    var id: String { serialNumber }

    /// Coarse signal bars 0–3, for the pairing list.
    var signalBars: Int {
        switch rssi {
        case ..<(-85): return 0
        case ..<(-70): return 1
        case ..<(-55): return 2
        default: return 3
        }
    }
}

/// Device connection state machine.
enum DeviceConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting(ScannedDevice)
    case connected
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .scanning, .connecting: return true
        default: return false
        }
    }
}

// MARK: - Device

/// A Plaud recorder as we currently understand it.
struct PlaudDevice: Equatable {
    let serialNumber: String
    var name: String
    var batteryLevel: Int
    var isCharging: Bool
    var storageUsed: Int64
    var storageTotal: Int64
    /// Display firmware version, e.g. "V1.4.7".
    var firmwareVersion: String
    /// Latest version available in Plaud's cloud; nil when unchecked or already current.
    var latestFirmwareVersion: String?
    var supportWiFi: Bool

    var storageUsageRatio: Double {
        guard storageTotal > 0 else { return 0 }
        return Double(storageUsed) / Double(storageTotal)
    }

    var hasFirmwareUpdate: Bool { latestFirmwareVersion != nil }

    var model: PlaudModel { PlaudModel(serialNumber: serialNumber) }
}

/// Device family, derived from the serial-number prefix.
enum PlaudModel: String {
    case notePro = "NotePro"
    case notePin = "NotePin"
    case notePinS = "NotePinS"
    case unknown = "Plaud Recorder"

    init(serialNumber: String) {
        switch serialNumber.prefix(3) {
        case "881": self = .notePro
        case "882": self = .notePin
        case "883": self = .notePinS
        default: self = .unknown
        }
    }

    /// Whether a parsed serial looks like a real Plaud recorder.
    ///
    /// Used to sift the fallback scan's results: `BleDevice` will happily parse
    /// any manufacturer data, so this is what separates a recorder from the
    /// hundred other beacons in the room.
    static func isSupportedSerial(_ serial: String) -> Bool {
        guard serial.count >= 8, serial.allSatisfy(\.isHexDigit) else { return false }
        return PlaudModel(serialNumber: serial) != .unknown
    }

    var displayName: String { rawValue }

    var symbolName: String {
        switch self {
        case .notePro: return "square.on.square"
        case .notePin, .notePinS: return "circle.circle"
        case .unknown: return "waveform.circle"
        }
    }
}

/// A paired device known from local storage — no BLE connection required.
struct PairedDeviceInfo: Identifiable, Equatable {
    let serialNumber: String
    let name: String
    let model: PlaudModel

    var id: String { serialNumber }
}

// MARK: - Recording

/// Live recording state machine.
enum RecordingState: Equatable {
    case idle
    case recording(sessionId: Int, startedAt: Date)
    case paused(sessionId: Int)

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }

    var currentSessionId: Int? {
        switch self {
        case .recording(let id, _), .paused(let id): return id
        case .idle: return nil
        }
    }

    var startedAt: Date? {
        if case .recording(_, let at) = self { return at }
        return nil
    }
}

// MARK: - Sync

/// WiFi Fast Transfer connection phase.
enum WiFiConnectPhase: Equatable {
    /// BLE command sent to open the recorder's hotspot.
    case openingHotspot
    /// Joining the hotspot via NEHotspotConfiguration (shows a system dialog).
    case connectingWiFi
    /// WebSocket handshake with the recorder.
    case handshaking

    var label: String {
        switch self {
        case .openingHotspot: return "Waking WiFi"
        case .connectingWiFi: return "Joining recorder"
        case .handshaking: return "Handshaking"
        }
    }
}

/// Snapshot of an in-flight sync.
struct SyncProgress: Equatable {
    let totalFiles: Int
    let syncedFiles: Int
    let currentFileName: String?
    /// Progress through the current file, 0–100.
    var fileProgress: Int = 0
    var bytesPerSecond: Double = 0

    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        let whole = Double(syncedFiles) / Double(totalFiles)
        let partial = Double(fileProgress) / 100.0 / Double(totalFiles)
        return min(whole + partial, 1.0)
    }

    var speedText: String? {
        guard bytesPerSecond > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }
}

/// File sync state machine, covering both BLE and WiFi paths.
enum SyncState: Equatable {
    case idle
    case syncing(SyncProgress)
    case wifiConnecting(WiFiConnectPhase)
    case wifiTransferring(SyncProgress)
    case completed
    case failed(String)

    var isActive: Bool {
        switch self {
        case .syncing, .wifiConnecting, .wifiTransferring: return true
        default: return false
        }
    }

    var progress: SyncProgress? {
        switch self {
        case .syncing(let p), .wifiTransferring(let p): return p
        default: return nil
        }
    }

    var isWiFi: Bool {
        switch self {
        case .wifiConnecting, .wifiTransferring: return true
        default: return false
        }
    }
}
