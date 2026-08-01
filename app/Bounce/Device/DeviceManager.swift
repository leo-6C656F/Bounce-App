import Combine
import Foundation
import PlaudBleSDK
// @preconcurrency: the SDK predates strict Sendable annotation, so its
// callback types and closures would otherwise emit concurrency warnings on
// every use. The managers confine SDK state to the main queue themselves.
@preconcurrency import PlaudDeviceBasicSDK

/// The single `PlaudDeviceAgentProtocol` delegate for the whole app.
///
/// The SDK exposes exactly one delegate slot, so this type receives *every*
/// callback — including recording and file-sync ones — and fans them out to
/// `RecordingManager` and `SyncManager`. If you need a new SDK callback,
/// implement it in the extension at the bottom of this file and forward it.
/// Do not attempt to register a second delegate.
///
/// Ported from the Plaud template app. Callbacks arrive on SDK-internal
/// queues, so every state mutation hops to main explicitly — that pattern is
/// inherited deliberately rather than modernised, because the reconnect / OTA /
/// WiFi guards below are timing-sensitive and known-good.
/// `@unchecked Sendable`: a singleton whose mutable state is only ever touched
/// inside `DispatchQueue.main` blocks, which the compiler can't see. The SDK
/// hands us `@Sendable` completion closures, so the annotation is what lets us
/// capture `self` in them without lying about the isolation.
final class DeviceManager: NSObject, @unchecked Sendable {

    static let shared = DeviceManager()

    /// True once `configure` has run, so callers don't re-init the SDK.
    private(set) var isConfigured = false

    // MARK: - Published state

    private let connectionStateSubject = CurrentValueSubject<DeviceConnectionState, Never>(.disconnected)
    private let deviceSubject = CurrentValueSubject<PlaudDevice?, Never>(nil)
    private let scannedDevicesSubject = CurrentValueSubject<[ScannedDevice], Never>([])

    var connectionStatePublisher: AnyPublisher<DeviceConnectionState, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }
    var devicePublisher: AnyPublisher<PlaudDevice?, Never> {
        deviceSubject.eraseToAnyPublisher()
    }
    var scannedDevicesPublisher: AnyPublisher<[ScannedDevice], Never> {
        scannedDevicesSubject.eraseToAnyPublisher()
    }

    var connectionState: DeviceConnectionState { connectionStateSubject.value }
    var device: PlaudDevice? { deviceSubject.value }

    // MARK: - Internal state

    /// Scan results keyed by serial number, so `connect` can find the `BleDevice`.
    private var cachedBleDevices: [String: BleDevice] = [:]
    private var isUserDisconnect = false
    private var hasPopulatedDevice = false
    private var autoReconnectTimer: Timer?
    private var autoReconnectAttempts = 0

    /// True while an OTA is running. The recorder reboots mid-update, so a
    /// disconnect is expected and the SDK handles reconnection itself.
    private(set) var isOTAInProgress = false

    /// Set during the "add another device" flow so a scan doesn't silently
    /// re-grab the device we are trying to move away from.
    var suppressAutoReconnect = false

    /// Coalescing window for `refreshStorage()`, and the longer wait for its
    /// settle reading. See `refreshStorage(settling:)`.
    private static let storageRefreshDebounce: TimeInterval = 1.0
    private static let storageSettleDelay: TimeInterval = 10.0
    private var pendingStorageReads: Set<StorageRead> = []

    private enum StorageRead { case soon, settle }

    #if DEBUG
    /// Previous `bleStorage` used-bytes reading, so each one can be logged as a
    /// delta. Diagnostic only.
    private var lastStorageUsed: Int64?
    #endif

    /// Counts `blePcmData` callbacks, purely so the logging can be sparse.
    private var pcmPacketCount = 0
    /// Same, for the raw encrypted stream probe in `bleData`.
    private var rawDataPacketCount = 0
    private var rawDataBytes = 0

    private override init() {
        super.init()
        PlaudDeviceAgent.shared.delegate = self
    }

    // MARK: - Setup

    /// Initialise the SDK. Must be called before scanning.
    ///
    /// The token is passed in rather than read from the bundle: it is minted at
    /// runtime by `TokenProvider` and rotates, so there is nothing static to
    /// read. `TokenProvider` calls `setUserAccessToken` directly whenever it
    /// mints a replacement, which the SDK accepts live.
    ///
    /// Idempotent on purpose. `initSDK` re-fetches the RSA key pair and **clears
    /// the sn-sign cache**, so calling it again mid-session throws away device
    /// signing state and issues needless network requests. Tapping "scan" twice
    /// used to do exactly that.
    func configure(userId: String, accessToken: String, region: PlaudRegion) {
        RecordingStore.shared.userId = userId

        guard !isConfigured else {
            DeviceLog.log("already configured; refreshing token only")
            PlaudDeviceAgent.shared.setUserAccessToken(accessToken)
            return
        }

        // Keep the SDK's region in step with the host. setCustomDomain alone
        // leaves it stale, which is why the SDK logs "region = jp" against a US
        // domain.
        PlaudDomainManager.shared.setRegion(region.sdkRegion)
        PlaudDeviceAgent.shared.initSDK(userAccessToken: accessToken, customDomain: region.domain)
        isConfigured = true
        DeviceLog.log("initSDK done — domain \(region.domain), region \(region.sdkRegion.rawValue)")
    }

    // MARK: - Scanning

    func startScan() {
        let bluetooth = BluetoothMonitor.shared.status
        DeviceLog.log("startScan — bluetooth \(bluetooth), "
            + "partnerDataReady=\(PlaudDeviceAgent.shared.isPartnerDataReady()), "
            + "configured=\(isConfigured)")

        guard bluetooth.canScan else {
            DeviceLog.log("✗ scan aborted: \(bluetooth.title)")
            connectionStateSubject.send(.failed(bluetooth.title))
            return
        }

        cachedBleDevices.removeAll()
        scannedDevicesSubject.send([])
        connectionStateSubject.send(.scanning)
        PlaudDeviceAgent.shared.startScan()

        // Runs alongside the SDK's scan and catches recorders it filters out —
        // NotePro "Find My" units advertise 504C rather than the 1910 the SDK
        // looks for. See BluetoothMonitor for the full explanation.
        BluetoothMonitor.shared.startFallbackScan { [weak self] device in
            self?.handleFallbackDiscovery(device)
        }
    }

    func stopScan() {
        DeviceLog.log("stopScan")
        PlaudDeviceAgent.shared.stopScan()
        BluetoothMonitor.shared.stopFallbackScan()
        if case .scanning = connectionState {
            connectionStateSubject.send(.disconnected)
        }
    }

    /// Merge a recorder found by our own scan into the same state the SDK's
    /// results feed, so `connect` and the pairing UI need no special case.
    private func handleFallbackDiscovery(_ device: BleDevice) {
        let serial = device.serialNumber

        // The SDK's own scan wins if it also found this device: its BleDevice
        // carries state we can't reconstruct from an advertisement alone.
        guard cachedBleDevices[serial] == nil else { return }
        cachedBleDevices[serial] = device

        let scanned = ScannedDevice(
            name: device.name.isEmpty ? PlaudModel(serialNumber: serial).displayName : device.name,
            serialNumber: serial,
            rssi: device.rssi
        )

        var devices = scannedDevicesSubject.value.filter { $0.serialNumber != serial }
        devices.append(scanned)
        scannedDevicesSubject.send(devices.sorted { $0.rssi > $1.rssi })

        // Mirror the auto-reconnect behaviour in bleScanResult, which never
        // fires for devices the SDK can't see.
        guard !suppressAutoReconnect,
              case .scanning = connectionState,
              RecordingStore.shared.activeDeviceSN == serial
        else { return }

        DeviceLog.log("fallback auto-reconnecting to \(serial)")
        connectionStateSubject.send(.connecting(scanned))
        PlaudDeviceAgent.shared.connectBleDevice(
            bleDevice: device,
            deviceToken: RecordingStore.shared.userId ?? ""
        )
    }

    /// Rescan on foreground, unless we are already connected or mid-OTA.
    /// The 2s delay gives the BLE stack time to power back up.
    func rescanIfNeeded() {
        guard RecordingStore.shared.hasPairedDevice else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            guard !self.connectionState.isConnected, !self.isOTAInProgress else { return }
            self.startScan()
        }
    }

    // MARK: - Connection

    func connect(_ device: ScannedDevice) {
        guard let bleDevice = cachedBleDevices[device.serialNumber] else { return }
        // Set by `configure`; the SDK uses it as the device binding token.
        let userId = RecordingStore.shared.userId ?? ""
        connectionStateSubject.send(.connecting(device))
        PlaudDeviceAgent.shared.connectBleDevice(bleDevice: bleDevice, deviceToken: userId)
    }

    func disconnect() {
        isUserDisconnect = true
        stopAutoReconnect()
        PlaudDeviceAgent.shared.disconnect()
    }

    /// Unbind the active recorder. A Plaud device can only be bound to one app
    /// at a time, so this is what frees it for another app.
    func unpair() {
        isUserDisconnect = true
        stopAutoReconnect()
        let sn = device?.serialNumber
        PlaudDeviceAgent.shared.depair(clear: true)
        if let sn { RecordingStore.shared.removePairedDevice(sn: sn) }
        SyncManager.shared.reset()

        DispatchQueue.main.async { [weak self] in
            self?.hasPopulatedDevice = false
            self?.deviceSubject.send(nil)
            self?.connectionStateSubject.send(.disconnected)
        }
    }

    /// Switch to another paired recorder. BLE only holds one connection, so
    /// this disconnects, waits for the stack to settle, then rescans.
    ///
    /// **Don't reset `isUserDisconnect` back to `false` here.** The disconnect
    /// above is asynchronous — its confirmation lands later, in
    /// `bleConnectState(state: 0)` — and this used to flip the flag back
    /// before that confirmation arrived. `wasUserInitiated` then read `false`
    /// for *this* disconnect and called `startAutoReconnect()`, an independent
    /// 3s-delay/30s-interval/10-attempt loop racing the explicit one-shot
    /// `startScan()` below against the same `activeDeviceSN`, with no de-dup
    /// between the two. Leaving the flag `true` until `bleConnectState`'s own
    /// reset (line ~575) matches how `disconnect()`/`unpair()` already behave.
    func switchDevice(sn: String) {
        isUserDisconnect = true
        stopAutoReconnect()
        PlaudDeviceAgent.shared.disconnect()
        hasPopulatedDevice = false
        deviceSubject.send(nil)

        RecordingStore.shared.activeDeviceSN = sn
        connectionStateSubject.send(.scanning)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            PlaudDeviceAgent.shared.startScan()
        }
    }

    func refreshDeviceInfo() {
        PlaudDeviceAgent.shared.getState()
        PlaudDeviceAgent.shared.getStorage()
    }

    /// Re-read just the recorder's storage figures.
    ///
    /// Deliberately narrower than `refreshDeviceInfo()`, which also issues
    /// `getState()`. This runs mid-session — after a recording stops, after a
    /// sync drains, after each confirmed device-side delete — and `getState` is
    /// needless traffic on the shared BLE command channel in all three cases.
    ///
    /// Coalesced, because a multi-file sync confirms one delete per file and
    /// every `getStorage` is a real write to the recorder. The recorder's own
    /// reply is what updates the UI, so the only cost of dropping a duplicate
    /// request is that the answer reflects the end of the burst — which is the
    /// answer we want anyway.
    ///
    /// - Parameter settling: take a **second** reading `storageSettleDelay`
    ///   later. Pass `true` after anything that should free space — a confirmed
    ///   delete, an erase. The recorder drops the file from its list
    ///   immediately, but its free-space accounting is not guaranteed to have
    ///   caught up a second later, so the early reading can understate what was
    ///   freed. Measured on a NotePro (V1.7.0): the reading taken ~1 s after a
    ///   confirmed delete showed **nothing** reclaimed. The settle reading is
    ///   what tells you whether that is permanent or merely lagging.
    func refreshStorage(settling: Bool = false) {
        scheduleStorageRead(.soon, after: Self.storageRefreshDebounce)
        if settling {
            scheduleStorageRead(.settle, after: Self.storageSettleDelay)
        }
    }

    private func scheduleStorageRead(_ kind: StorageRead, after delay: TimeInterval) {
        guard !pendingStorageReads.contains(kind) else { return }
        pendingStorageReads.insert(kind)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.pendingStorageReads.remove(kind)
            guard self.connectionState.isConnected else { return }
            PlaudDeviceAgent.shared.getStorage()
        }
    }

    /// Open the recorder's stream for an in-progress recording.
    ///
    /// ## `blePcmData` never fires, and it is not our fault
    ///
    /// This is what would drive live transcription and the live waveform. It does
    /// not work with E2EE recordings on SDK 1.0.3 / firmware V1.7.0, and both
    /// available routes were tested on real hardware:
    ///
    /// | Call | E2EE stream primed | `blePcmData` |
    /// |---|---|---|
    /// | `PlaudDeviceAgent.syncFile(sessionId:start:end:)` | yes | **no** |
    /// | `BleAgent.syncFile(sessionId:start:end:decode: true)` | no | **no** |
    ///
    /// `BleAgent`'s overload is the only one taking a `decode` flag (`needDecode`
    /// is get-only), so it looked like the answer. It isn't: it skips
    /// `PlaudDeviceAgent`'s E2EE handling and still delivers nothing. The SDK
    /// logs `E2EE stream: key ready, starting PCM decode` during recording but
    /// never passes frames to the delegate.
    ///
    /// So the high-level call is kept — it at least primes the E2EE stream, and
    /// gives up nothing. `RecordingManager.handlePcmData` is consequently never
    /// called, which is also why the level meter has never actually moved.
    func startLivePCMStream(sessionId: Int, start: Int) {
        DeviceLog.log("syncFile for \(sessionId) — note: blePcmData does not fire for E2EE recordings")
        PlaudDeviceAgent.shared.syncFile(sessionId: sessionId, start: start, end: 0)
    }

    // MARK: - Auto reconnect

    /// Rescan every 30s, up to 10 attempts. The actual reconnect happens in
    /// `bleScanResult`, which only fires when state is `.scanning` — so
    /// anything that kicks off a scan must publish `.scanning` first.
    func startAutoReconnect(initialDelay: TimeInterval = 3.0) {
        stopAutoReconnect()
        autoReconnectAttempts = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            guard let self else { return }
            self.autoReconnectTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.attemptReconnect()
            }
            self.autoReconnectTimer?.fire()
        }
    }

    private func attemptReconnect() {
        autoReconnectAttempts += 1
        guard autoReconnectAttempts <= 10 else {
            stopAutoReconnect()
            return
        }
        connectionStateSubject.send(.scanning)
        PlaudDeviceAgent.shared.startScan()
    }

    func stopAutoReconnect() {
        autoReconnectTimer?.invalidate()
        autoReconnectTimer = nil
    }

    // MARK: - Recording passthrough

    func startRecord() { PlaudDeviceAgent.shared.startRecord() }
    func stopRecord() { PlaudDeviceAgent.shared.stopRecord() }
    func pauseRecord() { PlaudDeviceAgent.shared.pauseRecord() }
    func resumeRecord() { PlaudDeviceAgent.shared.resumeRecord() }

    // MARK: - Firmware

    func checkFirmwareUpdate() async -> PlaudFirmwareCheckResult {
        await withCheckedContinuation { continuation in
            PlaudDeviceAgent.shared.checkFirmwareUpdate { continuation.resume(returning: $0) }
        }
    }

    /// Bounds how long a hung OTA update can suppress disconnect handling.
    /// `bleConnectState` returns early on any disconnect while
    /// `isOTAInProgress` is set — correct while a real update is running, since
    /// the recorder reboots and the SDK reconnects itself, but if the SDK's
    /// completion callback is ever dropped (connection lost mid-flash, an SDK
    /// bug) that flag would otherwise stay `true` forever, and every real
    /// disconnect after that is silently swallowed: no `.disconnected` state,
    /// no auto-reconnect, the UI keeps showing "connected" against a device
    /// that's actually gone. This only resets the flag — it can't also
    /// resume `startFirmwareUpdate`'s continuation with a synthetic result,
    /// because `PlaudFirmwareUpdateResult` is `@_hasMissingDesignatedInitializers`
    /// (verified in the SDK's `.swiftinterface`), so nothing outside the SDK can
    /// construct one. A genuinely hung update still hangs; this just stops it
    /// from also taking disconnect handling down with it.
    private static let otaWatchdogTimeout: TimeInterval = 5 * 60

    /// Run an OTA update. `progress` is delivered on the main queue.
    func startFirmwareUpdate(
        progress: @escaping (PlaudFirmwarePhase, Float) -> Void
    ) async -> PlaudFirmwareUpdateResult {
        isOTAInProgress = true
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.isOTAInProgress else { return }
            DeviceLog.log("OTA watchdog: no completion after "
                + "\(Int(Self.otaWatchdogTimeout))s — clearing isOTAInProgress "
                + "so disconnect handling resumes")
            self.isOTAInProgress = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.otaWatchdogTimeout, execute: watchdog)

        return await withCheckedContinuation { continuation in
            PlaudDeviceAgent.shared.startFirmwareUpdate(
                progress: { phase, percent in
                    DispatchQueue.main.async { progress(phase, percent) }
                },
                completion: { [weak self] result in
                    watchdog.cancel()
                    guard let self else {
                        continuation.resume(returning: result)
                        return
                    }
                    self.isOTAInProgress = false
                    if !result.success {
                        self.hasPopulatedDevice = false
                        DispatchQueue.main.async {
                            self.connectionStateSubject.send(.disconnected)
                            self.deviceSubject.send(nil)
                            self.startAutoReconnect()
                        }
                    }
                    continuation.resume(returning: result)
                }
            )
        }
    }

    // MARK: - Device management

    /// Rename the recorder. `bleDeviceName` confirms the change and updates
    /// `PlaudDevice.name` — no local optimistic update needed here.
    func renameDevice(_ name: String) {
        PlaudDeviceAgent.shared.setDeviceName(name)
    }

    /// Mount the recorder as a USB drive. No confirming callback exists for
    /// this command (Tier 2 per docs/plans/sdk-expansion.md), so the caller
    /// must treat its own stored value as "last requested", not device truth.
    func setUDiskMode(_ enabled: Bool) {
        PlaudDeviceAgent.shared.setUDiskMode(onOff: enabled)
    }

    /// Wipe every recording on the device. Irreversible.
    /// Returns `false` without sending the command if a sync is in flight —
    /// racing a delete against an in-progress download is asking for trouble.
    @discardableResult
    func clearAllFiles() -> Bool {
        guard !SyncManager.shared.state.isActive else {
            DeviceLog.log("clearAllFiles refused — sync in progress")
            return false
        }
        DeviceLog.log("clearAllFiles")
        PlaudDeviceAgent.shared.clearAllFiles()
        // No callback confirms this, so the storage figure is the only evidence
        // the user gets that it did anything. Settling, because wiping every
        // file is exactly the case where the recorder's accounting may lag.
        refreshStorage(settling: true)
        return true
    }

    /// Factory reset. Irreversible, and the recorder forgets its binding
    /// immediately — so unpair locally right away rather than waiting on a
    /// callback that may never arrive once the device reboots.
    @discardableResult
    func restoreFactory() -> Bool {
        guard !SyncManager.shared.state.isActive else {
            DeviceLog.log("restoreFactory refused — sync in progress")
            return false
        }
        DeviceLog.log("restoreFactory")
        PlaudDeviceAgent.shared.restoreFactory()
        unpair()
        return true
    }

    // MARK: - Device info population

    /// Build a `PlaudDevice` from the SDK's cached `BleDevice`. Runs once per
    /// connection so a repeat callback can't wipe `latestFirmwareVersion`.
    private func populateDeviceFromCache() {
        guard let raw = PlaudDeviceAgent.shared.recentConnectDevice, !hasPopulatedDevice else { return }
        hasPopulatedDevice = true

        deviceSubject.send(
            PlaudDevice(
                serialNumber: raw.serialNumber,
                name: raw.name,
                batteryLevel: raw.power,
                isCharging: raw.isCharging,
                storageUsed: 0,
                storageTotal: 0,
                firmwareVersion: Self.formatFirmwareVersion(raw),
                latestFirmwareVersion: nil,
                supportWiFi: raw.supportWiFi
            )
        )
        refreshDeviceInfo()

        PlaudDeviceAgent.shared.checkFirmwareUpdate { [weak self] result in
            guard result.hasUpdate else { return }
            DispatchQueue.main.async {
                self?.mutateDevice { $0.latestFirmwareVersion = result.latestVersion }
            }
        }
    }

    /// `versionCode` packs major.minor.patch into one Int; small values are
    /// legacy four-digit build numbers.
    private static func formatFirmwareVersion(_ raw: BleDevice) -> String {
        let code = raw.versionCode
        let version: String
        if code <= 0 {
            version = "unknown"
        } else if code < 255 {
            version = String(format: "%04d", code)
        } else {
            version = "\((code >> 16) & 0xFF).\((code >> 8) & 0xFF).\(code & 0xFF)"
        }
        return raw.versionTypeStr + version
    }

    private func mutateDevice(_ mutate: (inout PlaudDevice) -> Void) {
        guard var device = deviceSubject.value else { return }
        mutate(&device)
        deviceSubject.send(device)
    }
}

// MARK: - PlaudDeviceAgentProtocol

extension DeviceManager: PlaudDeviceAgentProtocol {

    // MARK: Scan & connect

    func bleScanResult(bleDevices: [BleDevice]) {
        DeviceLog.log("bleScanResult — \(bleDevices.count) device(s): "
            + bleDevices.map { "\($0.serialNumber)/\($0.name)@\(Int($0.rssi))dBm" }.joined(separator: ", "))

        let scanned = bleDevices
            .map { ScannedDevice(name: $0.name, serialNumber: $0.serialNumber, rssi: $0.rssi) }
            .sorted { $0.rssi > $1.rssi }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Merge rather than replace: the fallback scan may already have
            // contributed devices the SDK cannot see, and they must not be
            // dropped when the SDK reports its own findings.
            for device in bleDevices {
                self.cachedBleDevices[device.serialNumber] = device
            }
            let sdkSerials = Set(scanned.map(\.serialNumber))
            let merged = scanned + self.scannedDevicesSubject.value
                .filter { !sdkSerials.contains($0.serialNumber) }
            self.scannedDevicesSubject.send(merged.sorted { $0.rssi > $1.rssi })

            // Auto-reconnect: the active device just came back into range.
            guard !self.suppressAutoReconnect,
                  case .scanning = self.connectionState,
                  let activeSN = RecordingStore.shared.activeDeviceSN,
                  let match = bleDevices.first(where: { $0.serialNumber == activeSN })
            else { return }

            let userId = RecordingStore.shared.userId ?? ""
            self.connectionStateSubject.send(
                .connecting(ScannedDevice(name: match.name, serialNumber: match.serialNumber, rssi: match.rssi))
            )
            PlaudDeviceAgent.shared.connectBleDevice(bleDevice: match, deviceToken: userId)
        }
    }

    func bleScanOverTime() {
        DeviceLog.log("bleScanOverTime — scan window closed")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if case .scanning = self.connectionState {
                self.connectionStateSubject.send(.disconnected)
            }
        }
    }

    func bleConnectState(state: Int) {
        DeviceLog.log("bleConnectState=\(state) (1=connected, 0=disconnected) "
            + "isOTA=\(isOTAInProgress) wifiActive=\(PlaudDeviceAgent.shared.isWiFiTransferActive)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case 0:
                self.hasPopulatedDevice = false

                // The recorder reboots during OTA; the SDK reconnects itself.
                if self.isOTAInProgress { return }

                // BLE deliberately drops during WiFi Fast Transfer. Reconnecting
                // here would tear down the WiFi link we just established.
                if PlaudDeviceAgent.shared.isWiFiTransferActive { return }

                let wasUserInitiated = self.isUserDisconnect
                self.isUserDisconnect = false
                self.connectionStateSubject.send(.disconnected)
                self.deviceSubject.send(nil)
                if !wasUserInitiated { self.startAutoReconnect() }

            case 1:
                self.stopAutoReconnect()
                self.isUserDisconnect = false
                self.connectionStateSubject.send(.connected)

                // A reconnect during a recording we're already tracking leaves the
                // live byte stream dead with nothing to say so — `blePenState`
                // only adopts a recording when we think we're idle. Checked, not
                // assumed: the assembler re-requests only if bytes really stopped.
                if case .recording = RecordingManager.shared.state {
                    Task { @MainActor in LiveTranscriber.shared.resumeStreamingIfStalled() }
                }

            case 2, -1, -2:
                self.connectionStateSubject.send(.failed("Couldn't connect (code \(state))"))

            default:
                break
            }
        }
    }

    /// Handshake complete. This is the only non-optional protocol method.
    func blePenState(
        state: Int, privacy: Int, keyState: Int, uDisk: Int,
        findMyToken: Int, hasSndpKey: Int, deviceAccessToken: Int
    ) {
        DeviceLog.log("blePenState — handshake complete, state=\(state) (0x1003 = recording)")

        let agent = BleAgent.shared
        let isRecording = state == 0x1003 || agent.isRecording
        let sessionId = agent.sessionId

        DispatchQueue.main.async { [weak self] in
            self?.populateDeviceFromCache()

            // 0x1003 (4099) means the recorder is already recording — adopt it.
            if isRecording, case .idle = RecordingManager.shared.state {
                RecordingManager.shared.handleRecordStart(sessionId: sessionId, startTime: sessionId)
                self?.startLivePCMStream(sessionId: sessionId, start: 0)
            }
        }
    }

    func bleBind(sn: String?, status: Int, protVersion: Int, timezone: Int) {
        DeviceLog.log("bleBind sn=\(sn ?? "nil") status=\(status) (0=bound) protVersion=\(protVersion)")
        guard status == 0, let sn else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let raw = PlaudDeviceAgent.shared.recentConnectDevice
            let name = raw?.name ?? sn
            RecordingStore.shared.addPairedDevice(sn: sn, name: name)
            self.deviceSubject.send(
                PlaudDevice(
                    serialNumber: sn,
                    name: name,
                    batteryLevel: raw?.power ?? 0,
                    isCharging: raw?.isCharging ?? false,
                    storageUsed: 0,
                    storageTotal: 0,
                    firmwareVersion: raw.map(Self.formatFirmwareVersion) ?? "",
                    latestFirmwareVersion: nil,
                    supportWiFi: raw?.supportWiFi ?? false
                )
            )
            self.refreshDeviceInfo()
        }
    }

    func bleDeviceDisconnectErr() {
        DispatchQueue.main.async { [weak self] in
            self?.hasPopulatedDevice = false
            self?.connectionStateSubject.send(.disconnected)
            self?.deviceSubject.send(nil)
        }
    }

    // MARK: Device state

    func blePowerChange(power: Int, oldPower: Int) {
        #if DEBUG
        // Instrumentation for the one unknown blocking a drain-rate readout: the
        // firmware's reporting **granularity**. Percent range is confirmed (standard
        // BLE Battery Service, uint8 0–100), but 1% steps and 5% steps need
        // observation windows an order of magnitude apart — ~3 h versus ~15 h for the
        // same accuracy — and 5% steps would make a per-session figure useless.
        //
        // Leave a recorder connected and recording for a few hours, then read the
        // `step=` and `after=` columns: `step` answers granularity, `after` answers
        // cadence. `BatteryDrainEstimator` computes the rate from exactly this
        // signal, and `observedStepSizes` reports the same thing at runtime.
        //
        // Requires a Debug build. Per CLAUDE.md, verify `DEBUG` is actually defined:
        // it silently wasn't, app-wide, for a while.
        let now = Date()
        let gap = Self.lastPowerChangeAt.map { now.timeIntervalSince($0) }
        Self.lastPowerChangeAt = now
        DeviceLog.log(String(
            format: "battery %d%% (was %d%%) step=%d after=%@",
            power, oldPower, abs(power - oldPower),
            gap.map { String(format: "%.0fs", $0) } ?? "first"))
        #endif

        DispatchQueue.main.async { [weak self] in
            self?.mutateDevice { $0.batteryLevel = power }
        }
    }

    #if DEBUG
    /// When the last battery transition was seen, for the interval in the log above.
    /// `nonisolated(unsafe)` because the callback arrives on an SDK queue and this is
    /// diagnostic-only — a torn read would misreport one interval, nothing more.
    nonisolated(unsafe) private static var lastPowerChangeAt: Date?
    #endif

    func bleChargingState(isCharging: Bool, level: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.mutateDevice {
                $0.isCharging = isCharging
                $0.batteryLevel = level
            }
        }
    }

    func bleStorage(total: Int, free: Int, duration: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let used = Int64(total - free)
            #if DEBUG
            // The delta between readings is the only way to tell whether the
            // recorder actually reclaims space when a file is deleted. A
            // confirmed `bleDeleteFile` proves the file left the device's file
            // table; it says nothing about the flash behind it.
            let delta = used - (self.lastStorageUsed ?? used)
            let sign = delta > 0 ? "+" : ""
            DeviceLog.log("bleStorage used=\(used) free=\(free) total=\(total)"
                + (self.lastStorageUsed == nil ? " (first reading)" : " (\(sign)\(delta) since last)"))
            self.lastStorageUsed = used
            #endif
            self.mutateDevice {
                $0.storageTotal = Int64(total)
                $0.storageUsed = used
            }
        }
    }

    func bleDeviceName(name: String?) {
        guard let name else { return }
        DispatchQueue.main.async { [weak self] in
            self?.mutateDevice { $0.name = name }
        }
    }

    // MARK: Forward to RecordingManager

    func bleRecordStart(
        sessionId: Int, start: Int, status: Int, scene: Int, startTime: Int, reason: Int
    ) {
        DispatchQueue.main.async {
            RecordingManager.shared.handleRecordStart(sessionId: sessionId, startTime: startTime)
            // Opening the PCM decode stream is what makes blePcmData fire,
            // which drives both the live waveform and live transcription.
            if status == 0 {
                DeviceManager.shared.startLivePCMStream(sessionId: sessionId, start: start)
            }
        }
    }

    func bleRecordStop(sessionId: Int, reason: Int, fileExist: Bool, fileSize: Int) {
        DispatchQueue.main.async { RecordingManager.shared.handleRecordStop(sessionId: sessionId) }
    }

    func bleRecordPause(sessionId: Int, reason: Int, fileExist: Bool, fileSize: Int) {
        DeviceLog.log("bleRecordPause session=\(sessionId) reason=\(reason) "
            + "fileExist=\(fileExist) fileSize=\(fileSize)")
        DispatchQueue.main.async { RecordingManager.shared.handleRecordPause(sessionId: sessionId) }
    }

    /// `startTime` is logged because it is the field that has to be *distrusted*:
    /// it arrives as 0, which anchored the elapsed timer at 1970. See
    /// `RecordingManager.anchor(sessionId:startTime:)`.
    func bleRecordResume(sessionId: Int, start: Int, status: Int, scene: Int, startTime: Int) {
        DeviceLog.log("bleRecordResume session=\(sessionId) start=\(start) "
            + "status=\(status) scene=\(scene) startTime=\(startTime)")
        DispatchQueue.main.async {
            RecordingManager.shared.handleRecordResume(sessionId: sessionId, startTime: startTime)
        }
    }

    /// Decoded PCM: 640 bytes, 16 kHz mono. Stays off the main queue — it is
    /// high frequency, and `RecordingManager` samples it on a timer instead.
    func blePcmData(sessionId: Int, millsec: Int, pcmData: Data, isMusic: Bool) {
        // Logged sparsely: this fires ~50 times a second, but knowing whether it
        // fires *at all* is the difference between "live transcription is broken"
        // and "the recorder never streamed us anything".
        pcmPacketCount += 1
        if pcmPacketCount == 1 || pcmPacketCount % 250 == 0 {
            DeviceLog.log("blePcmData #\(pcmPacketCount) session=\(sessionId) "
                + "\(pcmData.count) bytes at \(millsec)ms")
        }
        RecordingManager.shared.handlePcmData(pcmData)
    }

    // MARK: Forward to SyncManager

    func bleFileList(bleFiles: [BleFile]) {
        let files = bleFiles.map(RemoteFile.init)
        DispatchQueue.main.async { SyncManager.shared.handleFileList(files) }
    }

    func bleDownloadFile(
        sessionId: Int, desiredOutputPath: String, status: Int, progress: Int, tips: String
    ) {
        DispatchQueue.main.async {
            if status == 0, progress == 100 {
                SyncManager.shared.handleDownloadComplete(sessionId: sessionId, outputPath: desiredOutputPath)
            } else if status == 0 {
                SyncManager.shared.handleDownloadProgress(sessionId: sessionId, progress: progress)
            } else {
                SyncManager.shared.handleDownloadFailure(sessionId: sessionId, reason: tips)
            }
        }
    }

    func bleDeleteFile(sessionId: Int, status: Int) {
        DispatchQueue.main.async {
            SyncManager.shared.handleDeleteResult(sessionId: sessionId, status: status)
        }
    }

    func bleWiFiOpen(_ status: Int, _ wifiName: String, _ wholeName: String, _ wifiPass: String) {
        guard status == 0 else { return }
        DispatchQueue.main.async {
            SyncManager.shared.handleWiFiOpen(ssid: wholeName, password: wifiPass)
        }
    }

    func bleWiFiClose(_ status: Int) {
        DispatchQueue.main.async { SyncManager.shared.handleWiFiClose() }
    }

    // MARK: Raw stream — instrumented to test in-flight decryption

    /// Raw file bytes straight off the recorder, before any decryption.
    ///
    /// Being probed on purpose. Since `blePcmData` never fires for E2EE
    /// recordings, the only route to live audio is to decrypt the stream
    /// ourselves — and every primitive for that is public:
    /// `AudioFileDecryptor.decryptWithPrivateKey`,
    /// `decryptWithChaCha20Stream(counter:)`, `OggOpusParser`,
    /// `PlaudEncryptHeader`. ChaCha20 is a stream cipher, so the `counter`
    /// parameter allows decrypting from an arbitrary offset.
    ///
    /// This logging answers the one open question: whether the encrypted bytes
    /// reach us at all during recording. If they do, the pipeline is buildable.
    /// If they don't, live audio is impossible from the app side.
    func bleData(sessionId: Int, start: Int, data: Data) {
        // The live decryption pipeline's only input. Hopped to main because the
        // assembler is main-actor isolated; the volume here is ~5/sec, not the
        // 50/sec of blePcmData, so a hop per packet is affordable. The instant is
        // stamped here, before the hop, so the assembler can measure how long the
        // main actor made this packet wait.
        let callbackAt = ContinuousClock.now
        Task { @MainActor in
            LiveTranscriber.shared.assembler.ingest(
                sessionId: sessionId, offset: start, data: data, callbackAt: callbackAt)
        }

        rawDataPacketCount += 1
        rawDataBytes += data.count
        if rawDataPacketCount == 1 || rawDataPacketCount % 50 == 0 {
            // First 16 bytes of the very first packet should be the
            // PlaudEncryptHeader magic, "PLAUD.AI", if this is the file header.
            let prefix = data.prefix(16).map { String(format: "%02X", $0) }.joined()
            let ascii = String(decoding: data.prefix(8), as: UTF8.self)
            DeviceLog.log("bleData #\(rawDataPacketCount) session=\(sessionId) "
                + "start=\(start) \(data.count) bytes (total \(rawDataBytes)) "
                + "head=\(prefix) ascii=\(ascii.filter(\.isASCII))")
        }
    }

    func bleSyncFileHead(sessionId: Int, status: Int) {
        DeviceLog.log("bleSyncFileHead session=\(sessionId) status=\(status)")
        rawDataPacketCount = 0
        rawDataBytes = 0
    }

    func bleSyncFileTail(sessionId: Int, crc: Int) {
        DeviceLog.log("bleSyncFileTail session=\(sessionId) crc=\(crc) "
            + "— \(rawDataPacketCount) packet(s), \(rawDataBytes) bytes total")
    }

    // MARK: Forward to DeviceSettings

    func bleMicGain(_ value: Int) {
        DispatchQueue.main.async { DeviceSettings.shared.handleMicGain(value) }
    }

    // MARK: Forward to IdleSyncManager

    func onWifiSyncEnabled(_ value: Int) {
        DispatchQueue.main.async { IdleSyncManager.shared.handleEnabled(value) }
    }

    func onWifiSyncListReceived(list: [UInt32]) {
        DispatchQueue.main.async { IdleSyncManager.shared.handleListReceived(list) }
    }

    func onWifiSyncConfigReceived(index: UInt32, ssid: String, password: String) {
        // `password` is intentionally dropped here — see `IdleSyncManager.Network`.
        DispatchQueue.main.async { IdleSyncManager.shared.handleConfigReceived(index: index, ssid: ssid) }
    }

    func onWifiSyncConfigSet(result: Int) {
        DispatchQueue.main.async { IdleSyncManager.shared.handleConfigSet(result: result) }
    }

    func onWifiSyncDeleteResult(result: Int) {
        DispatchQueue.main.async { IdleSyncManager.shared.handleDeleteResult(result) }
    }

    func onWifiSyncTestStarted(index: UInt32) {
        DispatchQueue.main.async { IdleSyncManager.shared.handleTestStarted(index: index) }
    }

    func onWifiSyncTestResult(index: UInt32, result: Int, rawCode: Int) {
        DispatchQueue.main.async { IdleSyncManager.shared.handleTestResult(index: index, result: result) }
    }

    func onWifiSyncWillStart(seconds: Int) {
        DispatchQueue.main.async { IdleSyncManager.shared.handleWillStart(seconds: seconds) }
    }

    func onWifiSyncUrl(url: String) {
        DispatchQueue.main.async { IdleSyncManager.shared.handleUrl(url) }
    }

    // MARK: Forward to HardwareLogManager

    func deviceLogData(start: Int, data: Data, logType: Int) {
        DispatchQueue.main.async {
            HardwareLogManager.shared.handleLogData(start: start, data: data, logType: logType)
        }
    }

    func onGetDeviceLogList(data: Data) {
        DispatchQueue.main.async {
            HardwareLogManager.shared.handleLogList(data: data)
        }
    }

    func onSyncDeviceLogStart(data: Data) {
        DispatchQueue.main.async {
            HardwareLogManager.shared.handleSyncLogStart(data: data)
        }
    }

    func onSyncDeviceLogStop() {
        DispatchQueue.main.async {
            HardwareLogManager.shared.handleSyncLogStop()
        }
    }

    func onSyncDeviceLogEnd(data: Data) {
        DispatchQueue.main.async {
            HardwareLogManager.shared.handleSyncLogEnd(data: data)
        }
    }

    func onDeviceLogDeleted(data: Data) {
        DispatchQueue.main.async {
            HardwareLogManager.shared.handleDeviceLogDeleted(data: data)
        }
    }

    // MARK: Implemented but unused

    func bleDownloadFileStop() {}
}

