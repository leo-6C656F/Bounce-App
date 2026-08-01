import CoreBluetooth
import Foundation
import PlaudBleSDK

/// Whether we are actually allowed to scan, and why not.
///
/// The SDK owns its own `CBCentralManager` and gives us no visibility into it,
/// so a denied Bluetooth permission or a powered-off radio makes `startScan()`
/// do **nothing at all** — no error, no callback, an empty list forever. That is
/// indistinguishable from "no recorder nearby", which is a miserable thing to
/// debug. This type exists to tell them apart.
enum BluetoothStatus: Equatable {
    case ready
    case notDetermined
    case denied
    case restricted
    case poweredOff
    case unsupported

    var canScan: Bool { self == .ready }

    var title: String {
        switch self {
        case .ready: return "Bluetooth ready"
        case .notDetermined: return "Bluetooth permission needed"
        case .denied: return "Bluetooth is turned off for Bounce"
        case .restricted: return "Bluetooth is restricted"
        case .poweredOff: return "Bluetooth is off"
        case .unsupported: return "Bluetooth isn't available"
        }
    }

    var advice: String {
        switch self {
        case .ready:
            return ""
        case .notDetermined:
            return "Tap scan and allow Bluetooth when iOS asks. Bounce needs it to reach your recorder."
        case .denied:
            return "Open Settings → Bounce and turn Bluetooth on, otherwise Bounce can't see your recorder."
        case .restricted:
            return "Bluetooth is blocked by a device restriction or profile on this iPhone."
        case .poweredOff:
            return "Turn Bluetooth on in Settings or Control Centre, then scan again."
        case .unsupported:
            return "This device doesn't support the Bluetooth features Bounce needs."
        }
    }
}

/// Bluetooth state, plus the scan that finds recorders the SDK's own scan misses.
///
/// ## Why this exists
///
/// `BleAgent.startScan()` scans filtered on service **`0x1910`**, and iOS only
/// reports peripherals whose advertisement contains that UUID. NotePro "Find My"
/// units advertise **`0x504C`** (ASCII `"PL"`) instead, so the SDK never sees
/// them: `bleScanResult` simply never fires, with no error.
///
/// The advertisement is otherwise complete. Feeding its manufacturer data to
/// `BleDevice(peripheral:rssi:manufacturerData:localName:)` — a public
/// initialiser — yields a correct serial number, project code and firmware
/// version, and the resulting object connects through
/// `PlaudDeviceAgent.connectBleDevice` like any other. Verified against a real
/// NotePro: `sn=8810B5…`, `projectCode=881`, `versionCode=67328`.
///
/// So this scans unfiltered, reconstructs `BleDevice`s itself, and hands them to
/// `DeviceManager`. Everything downstream — binding, handshake, sync — is
/// unchanged. Remove this if Plaud ever ships an SDK that scans for `504C`.
final class BluetoothMonitor: NSObject {

    static let shared = BluetoothMonitor()

    /// Plaud's pairing/data service, which the SDK's scan filters on.
    static let plaudServiceUUID = CBUUID(string: "1910")
    /// Plaud's Find My beacon service — ASCII "PL".
    static let plaudFindMyServiceUUID = CBUUID(string: "504C")

    private var central: CBCentralManager?
    private var onChange: ((BluetoothStatus) -> Void)?
    private var onDiscover: ((BleDevice) -> Void)?

    /// Serial numbers already reported this scan, so a device advertising ten
    /// times a second produces one callback.
    private var reportedSerials: Set<String> = []

    private override init() {
        super.init()
    }

    /// Current status. Authorisation is checked first: a denied app can report
    /// an `.unknown` power state, which would otherwise read as "powered off".
    var status: BluetoothStatus {
        switch CBCentralManager.authorization {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .allowedAlways: break
        @unknown default: break
        }

        switch central?.state {
        case .poweredOn: return .ready
        case .poweredOff: return .poweredOff
        case .unsupported: return .unsupported
        case .unauthorized: return .denied
        // .resetting, .unknown, or no manager yet — assume usable rather than
        // showing a scary banner during the brief startup window.
        default: return .ready
        }
    }

    /// Begin observing. Creating the manager is what triggers iOS's permission
    /// prompt if it hasn't been shown yet.
    func start(onChange: @escaping (BluetoothStatus) -> Void) {
        self.onChange = onChange
        if central == nil {
            // showPowerAlert: false — we surface our own guidance rather than
            // letting iOS interrupt with a system alert.
            central = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }
        onChange(status)
    }

    // MARK: - Fallback scan

    /// Scan unfiltered and report every Plaud recorder found, including ones the
    /// SDK's filtered scan cannot see. `onDiscover` fires once per serial.
    func startFallbackScan(onDiscover: @escaping (BleDevice) -> Void) {
        guard let central, central.state == .poweredOn else {
            DeviceLog.log("fallback scan skipped — bluetooth not powered on")
            return
        }

        self.onDiscover = onDiscover
        reportedSerials.removeAll()

        guard !central.isScanning else { return }

        // Unfiltered: the whole point is that we cannot predict which service a
        // given firmware advertises. Devices are identified by parsing the
        // manufacturer data instead, which is authoritative.
        //
        // Duplicates ON, because rebinding to the SDK's central can fail
        // transiently while that central is still starting up — with duplicates
        // off, CoreBluetooth reports each peripheral once and there would be no
        // second chance. `reportedSerials` keeps this to one callback per device
        // regardless.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        DeviceLog.log("fallback scan started (unfiltered)")
    }

    func stopFallbackScan() {
        onDiscover = nil
        guard let central, central.isScanning else { return }
        central.stopScan()
        DeviceLog.log("fallback scan stopped")
    }
}

extension BluetoothMonitor: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let status = status
        DeviceLog.log("bluetooth state → \(status)")
        onChange?(status)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let onDiscover,
              let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        else { return }

        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name

        // Let the SDK's own parser decide whether this is a Plaud device. It
        // reads the serial, project code and firmware out of the manufacturer
        // data, and returns an empty serial for anything it doesn't recognise —
        // which is a far better test than sniffing names or service UUIDs.
        let device = BleDevice(
            peripheral: peripheral,
            rssi: RSSI,
            manufacturerData: manufacturerData,
            localName: localName
        )

        let serial = device.serialNumber
        guard PlaudModel.isSupportedSerial(serial) else { return }
        // Checked but not yet recorded: the rebind below can fail transiently
        // (the SDK's central may not be up yet), and marking the serial as seen
        // here would blacklist it for the rest of the scan.
        guard !reportedSerials.contains(serial) else { return }

        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map(\.uuidString)
        DeviceLog.log("fallback found \(serial) (\(localName ?? "unnamed")) "
            + "@\(RSSI.intValue)dBm services=[\(services.joined(separator: ","))] "
            + "projectCode=\(device.projectCode) versionCode=\(device.versionCode)")

        // A CBPeripheral belongs to the central that discovered it. Handing the
        // SDK one of *ours* fails with "peripheral <uuid> not found", because its
        // central has never seen it. Re-resolving the same identifier through the
        // SDK's own central yields an equivalent object it can actually connect.
        guard let connectable = rebindToSDKCentral(peripheral) else {
            DeviceLog.log("  ✗ couldn't rebind \(serial) to the SDK's central — "
                + "will retry on the next advertisement")
            return
        }

        reportedSerials.insert(serial)
        onDiscover(
            BleDevice(
                peripheral: connectable,
                rssi: RSSI,
                manufacturerData: manufacturerData,
                localName: localName
            )
        )
    }

    /// Fetch the same peripheral from the SDK's `CBCentralManager`, so the
    /// object we hand over is one it owns.
    ///
    /// `retrievePeripherals(withIdentifiers:)` works for any peripheral iOS
    /// already knows about — it does not require that central to have scanned it.
    private func rebindToSDKCentral(_ peripheral: CBPeripheral) -> CBPeripheral? {
        guard let sdkCentral = BleAgent.shared.cbManager else {
            DeviceLog.log("  ✗ BleAgent.cbManager is nil — SDK hasn't started its central yet")
            return nil
        }
        // Same central: nothing to do.
        if sdkCentral === central { return peripheral }
        return sdkCentral.retrievePeripherals(withIdentifiers: [peripheral.identifier]).first
    }
}
