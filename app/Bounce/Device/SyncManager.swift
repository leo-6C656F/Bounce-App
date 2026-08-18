import Combine
import CoreLocation
import Foundation
import NetworkExtension
import PlaudBleSDK
import PlaudDeviceBasicSDK
import PlaudWiFiSDK

/// A recording that still lives on the recorder.
///
/// A plain value type so `DeviceManager` can hand file lists across queues
/// without passing the SDK's mutable `BleFile` reference around.
struct RemoteFile: Equatable {
    let sessionId: Int
    let deviceSN: String
    let sizeBytes: Int
    let duration: TimeInterval

    init(sessionId: Int, deviceSN: String, sizeBytes: Int, duration: TimeInterval) {
        self.sessionId = sessionId
        self.deviceSN = deviceSN
        self.sizeBytes = sizeBytes
        self.duration = duration
    }

    init(_ bleFile: BleFile) {
        sessionId = bleFile.sessionId
        deviceSN = bleFile.sn
        sizeBytes = bleFile.size
        duration = TimeInterval(bleFile.duration()) / 1000.0
    }

    /// `sessionId` is the recording's start time as a Unix timestamp.
    var createdAt: Date { Date(timeIntervalSince1970: Double(sessionId)) }
}

/// Pulls recordings off the device over BLE or WiFi Fast Transfer.
///
/// Two independent transports with separate state, plus the guards that keep
/// them from fighting each other. All `handle*` methods are called by
/// `DeviceManager`; `PlaudWiFiAgentProtocol` callbacks land here directly
/// because the WiFi agent has its own delegate slot.
final class SyncManager: NSObject {

    static let shared = SyncManager()

    /// Everything is exported as MP3. Two reasons, both load-bearing:
    /// `AVAudioPlayer` plays it, and `AVAudioFile` can read it — which is what
    /// on-device transcription needs. Opus lands in an Ogg container that
    /// `AVAudioFile` cannot open, so it is deliberately not used here even
    /// though the SDK offers it.
    private static let exportFormat: AudioExportFormat = .mp3

    // MARK: - Published state

    private let stateSubject = CurrentValueSubject<SyncState, Never>(.idle)
    private let recordingsSubject: CurrentValueSubject<[Recording], Never>
    private let didSyncSubject = PassthroughSubject<String, Never>()

    var statePublisher: AnyPublisher<SyncState, Never> { stateSubject.eraseToAnyPublisher() }
    var recordingsPublisher: AnyPublisher<[Recording], Never> { recordingsSubject.eraseToAnyPublisher() }
    /// Emits a recording id each time audio finishes landing on this iPhone.
    /// `AppModel` listens here to kick off transcription and delivery.
    var didSyncPublisher: AnyPublisher<String, Never> { didSyncSubject.eraseToAnyPublisher() }

    var state: SyncState { stateSubject.value }

    // MARK: - BLE queue state

    private var pendingDownloads: [RemoteFile] = []
    private var totalToSync = 0
    private var syncedCount = 0
    private var currentFileSize = 0
    private var currentSessionId: Int?
    private var lastProgressAt: Date?
    private var lastProgressBytes: Double = 0

    /// True when we only want the file list, with no banner and no download.
    private var isSilentFetch = false

    /// Session ids whose device-side delete the recorder refused
    /// (`bleDeleteFile` status != 0). The delete is issued right as the next
    /// download starts, and the recorder can refuse it while busy — so each
    /// refusal is retried once, when the queue is idle. Session ids are unix
    /// timestamps, so entries never collide across syncs.
    private var refusedDeletes: Set<Int> = []
    private var retriedDeletes: Set<Int> = []

    // MARK: - WiFi state

    private let locationManager = CLLocationManager()
    private var wifiPending: [RemoteFile] = []
    private var wifiTotalToSync = 0
    private var wifiSyncedCount = 0
    /// Retained so ARC doesn't drop the export callback mid-transfer.
    private var wifiExportHandler: WiFiExportHandler?
    /// Guards against stale `bleWiFiOpen` callbacks re-entering the flow.
    private var expectingWiFiCallbacks = false
    private var isWiFiConnecting = false

    private override init() {
        recordingsSubject = CurrentValueSubject(RecordingStore.shared.recordings)
        super.init()
    }

    // MARK: - Control

    /// Fetch the file list quietly. If new recordings turn up, sync starts.
    func fetchFileList() {
        isSilentFetch = true
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    func startSync() {
        guard !state.isActive else { return }
        isSilentFetch = false
        stateSubject.send(.syncing(SyncProgress(totalFiles: 0, syncedFiles: 0, currentFileName: nil)))
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    func stopSync() {
        PlaudDeviceAgent.shared.stopDownloadFile()
        pendingDownloads.removeAll()
        stateSubject.send(.idle)
    }

    /// Reset everything, e.g. after unpairing.
    func reset() {
        stopSync()
        refreshLibrary()
    }

    func refreshLibrary() {
        recordingsSubject.send(RecordingStore.shared.recordings)
    }

    func delete(_ recording: Recording) {
        RecordingStore.shared.delete(id: recording.id)
        refreshLibrary()
    }

    // MARK: - WiFi Fast Transfer

    /// Roughly 10x faster than BLE. Needs the Hotspot Configuration
    /// entitlement, and — because `NEHotspotConfigurationManager` requires it
    /// on iOS 13+ — location permission.
    func startWiFiTransfer() {
        // Hard stop when the build isn't signed for the WiFi entitlements. Not
        // just cosmetic: the location request below would terminate the app,
        // because NSLocationWhenInUseUsageDescription is removed alongside them.
        guard AppCapabilities.wifiFastTransfer else {
            stateSubject.send(.failed("WiFi Fast Transfer isn't enabled in this build."))
            return
        }

        // Switching mid-BLE-sync is allowed; stop BLE first.
        if case .syncing = state {
            PlaudDeviceAgent.shared.stopDownloadFile()
            pendingDownloads.removeAll()
        }
        guard !state.isWiFi else { return }

        switch CLLocationManager().authorizationStatus {
        case .notDetermined:
            // The user has to tap again once they've granted permission.
            locationManager.requestWhenInUseAuthorization()
            return
        case .denied, .restricted:
            stateSubject.send(.failed("WiFi Fast Transfer needs location permission. Enable it in Settings."))
            return
        default:
            break
        }

        expectingWiFiCallbacks = true
        stateSubject.send(.wifiConnecting(.openingHotspot))
        PlaudWiFiAgent.shared.delegate = self
        PlaudDeviceAgent.shared.setDeviceWiFi(open: true)
    }

    func stopWiFiTransfer() {
        tearDownWiFi()
        stateSubject.send(.idle)
    }

    private func tearDownWiFi() {
        expectingWiFiCallbacks = false
        isWiFiConnecting = false
        wifiExportHandler = nil
        wifiPending.removeAll()
        PlaudWiFiAgent.shared.disconnect()
        PlaudDeviceAgent.shared.setDeviceWiFi(open: false)
        PlaudDeviceAgent.shared.endWiFiTransfer()
    }

    // MARK: - Callbacks from DeviceManager

    /// Reconcile the recorder's file list against what we already hold.
    ///
    /// Files are deleted from the recorder once downloaded, so anything still
    /// in this list is by definition not yet synced.
    func handleFileList(_ remoteFiles: [RemoteFile]) {
        let alreadySynced = RecordingStore.shared.recordings.filter(\.isSynced)
        let placeholders = remoteFiles.map {
            Recording(
                sessionId: $0.sessionId,
                deviceSN: $0.deviceSN,
                duration: $0.duration,
                createdAt: $0.createdAt
            )
        }
        RecordingStore.shared.replaceAll(alreadySynced + placeholders)
        refreshLibrary()

        let silent = isSilentFetch
        isSilentFetch = false

        guard !remoteFiles.isEmpty else {
            stateSubject.send(silent ? .idle : .completed)
            return
        }

        pendingDownloads = remoteFiles
        totalToSync = remoteFiles.count
        syncedCount = 0
        downloadNext()
    }

    func handleDownloadProgress(sessionId: Int, progress: Int) {
        // Instantaneous speed from the delta between callbacks.
        let now = Date()
        let bytesSoFar = Double(currentFileSize) * Double(progress) / 100.0

        guard let last = lastProgressAt else {
            lastProgressAt = now
            lastProgressBytes = bytesSoFar
            return
        }
        let elapsed = now.timeIntervalSince(last)
        // Below 100ms the numbers are noise; keep the previous reading.
        guard elapsed > 0.1 else { return }

        let speed = (bytesSoFar - lastProgressBytes) / elapsed
        lastProgressAt = now
        lastProgressBytes = bytesSoFar

        var snapshot = SyncProgress(
            totalFiles: totalToSync,
            syncedFiles: syncedCount,
            currentFileName: RecordingStore.shared.recording(sessionId: sessionId)?.displayTitle
        )
        snapshot.fileProgress = progress
        snapshot.bytesPerSecond = speed
        stateSubject.send(.syncing(snapshot))
    }

    func handleDownloadComplete(sessionId: Int, outputPath: String) {
        syncedCount += 1
        finishFile(sessionId: sessionId, outputPath: outputPath)
        // Free space on the recorder now that we hold the audio. Only after the
        // file is on disk and recorded in the store — never before.
        if DeliverySettings.deletesFromRecorderAfterSync {
            print("[Sync] Requesting device-side delete of session \(sessionId)")
            PlaudDeviceAgent.shared.deleteFile(sessionId: sessionId)
        }
        downloadNext()
    }

    /// Outcome of a device-side delete, forwarded from `bleDeleteFile`.
    func handleDeleteResult(sessionId: Int, status: Int) {
        guard status != 0 else {
            refusedDeletes.remove(sessionId)
            print("[Sync] Recorder confirmed delete of session \(sessionId)")
            // The recorder's storage figure is otherwise only sampled at connect,
            // so a successful delete would never show up until the next
            // reconnect — making the Recorder card read as though nothing had
            // been freed. Coalesced inside DeviceManager, so a multi-file sync
            // costs one command, not one per file. `settling` because the
            // recorder's free-space accounting can lag the confirmation it just
            // sent — the reading a second later is not the final word.
            DeviceManager.shared.refreshStorage(settling: true)
            return
        }
        guard !retriedDeletes.contains(sessionId) else {
            refusedDeletes.remove(sessionId)
            print("[Sync] Recorder refused delete of session \(sessionId) again (status \(status)); giving up")
            return
        }
        print("[Sync] Recorder refused delete of session \(sessionId) (status \(status))")
        refusedDeletes.insert(sessionId)
        // Mid-sync the recorder is busy with the next download; wait for the
        // queue to drain. Otherwise it is idle now, so retry immediately.
        if !state.isActive { retryRefusedDeletes() }
    }

    private func retryRefusedDeletes() {
        for sessionId in refusedDeletes {
            print("[Sync] Retrying device-side delete of session \(sessionId)")
            retriedDeletes.insert(sessionId)
            PlaudDeviceAgent.shared.deleteFile(sessionId: sessionId)
        }
    }

    func handleDownloadFailure(sessionId: Int, reason: String) {
        // One bad file shouldn't stall the queue.
        syncedCount += 1
        downloadNext()
    }

    func handleWiFiOpen(ssid: String, password: String) {
        guard expectingWiFiCallbacks, !isWiFiConnecting else { return }
        isWiFiConnecting = true
        stateSubject.send(.wifiConnecting(.connectingWiFi))

        PlaudWiFiAgent.shared.bleDevice = BleAgent.shared.bleDevice
        PlaudWiFiAgent.shared.delegate = self

        // Give the recorder's hotspot a second to come up properly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            // Recheck before firing: if `stopWiFiTransfer()` cancelled within
            // this 1s window, `tearDownWiFi()` already reset these flags and
            // disconnected — without this check, the closure would fire
            // anyway and reopen a WiFi session moments after the user
            // cancelled it.
            guard let self, self.expectingWiFiCallbacks, self.isWiFiConnecting else { return }
            PlaudWiFiAgent.shared.connectWifi(ssid, password, 60)
        }
    }

    func handleWiFiClose() {
        let wasTransferring = state.isWiFi && !isWiFiConnecting
        expectingWiFiCallbacks = false
        isWiFiConnecting = false
        PlaudDeviceAgent.shared.endWiFiTransfer()

        if case .wifiTransferring = state {
            stateSubject.send(.completed)
        } else if case .wifiConnecting = state {
            stateSubject.send(wasTransferring ? .completed : .idle)
        }
    }

    // MARK: - Download queues

    private func downloadNext() {
        guard !pendingDownloads.isEmpty else {
            retryRefusedDeletes()
            DeviceManager.shared.refreshStorage()
            stateSubject.send(.completed)
            return
        }
        let next = pendingDownloads.removeFirst()

        currentFileSize = next.sizeBytes
        currentSessionId = next.sessionId
        lastProgressAt = nil
        lastProgressBytes = 0

        stateSubject.send(
            .syncing(
                SyncProgress(
                    totalFiles: totalToSync,
                    syncedFiles: syncedCount,
                    currentFileName: RecordingStore.shared.recording(sessionId: next.sessionId)?.displayTitle
                )
            )
        )

        PlaudDeviceAgent.shared.exportAudio(
            sessionId: next.sessionId,
            outputDir: RecordingStore.shared.audioDirectory.path,
            format: Self.exportFormat,
            channels: 1,
            callback: self
        )
    }

    private func wifiDownloadNext() {
        guard !wifiPending.isEmpty else {
            tearDownWiFi()
            stateSubject.send(.completed)
            return
        }
        let next = wifiPending.removeFirst()

        stateSubject.send(
            .wifiTransferring(
                SyncProgress(
                    totalFiles: wifiTotalToSync,
                    syncedFiles: wifiSyncedCount,
                    currentFileName: RecordingStore.shared.recording(sessionId: next.sessionId)?.displayTitle
                )
            )
        )

        let handler = WiFiExportHandler(sessionId: next.sessionId, owner: self)
        wifiExportHandler = handler
        PlaudWiFiAgent.shared.exportAudioViaWiFi(
            sessionId: next.sessionId,
            outputDir: RecordingStore.shared.audioDirectory.path,
            format: Self.exportFormat,
            channels: 1,
            callback: handler
        )
    }

    fileprivate func handleWiFiExportComplete(sessionId: Int, outputPath: String) {
        wifiSyncedCount += 1
        finishFile(sessionId: sessionId, outputPath: outputPath)
        if DeliverySettings.deletesFromRecorderAfterSync {
            PlaudWiFiAgent.shared.deleteFile(sessionId, 1)
        }
        wifiDownloadNext()
    }

    fileprivate func handleWiFiExportFailure(sessionId: Int) {
        wifiSyncedCount += 1
        wifiDownloadNext()
    }

    /// Shared tail for both transports: persist, refresh, announce.
    private func finishFile(sessionId: Int, outputPath: String) {
        RecordingStore.shared.markSynced(sessionId: sessionId, outputPath: outputPath)
        refreshLibrary()
        if let recording = RecordingStore.shared.recording(sessionId: sessionId) {
            didSyncSubject.send(recording.id)
        }
    }
}

// MARK: - AudioExportCallback (BLE)

extension SyncManager: AudioExportCallback {

    // The SDK invokes these on its own export-callback queue — unlike the file /
    // download / WiFi callbacks in `DeviceManager`, which the SDK delivers there
    // and which hop to main before forwarding here, this object is handed to the
    // SDK as `callback: self`, so nothing hops for it. Every body below mutates
    // the lock-free `RecordingStore` and/or publishes on Combine subjects read by
    // `@MainActor` SwiftUI, so each hops to main itself — exactly as the sibling
    // `WiFiExportHandler` already does for the identical protocol.

    func onProgress(_ progress: Int, message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let sessionId = self.currentSessionId else { return }
            self.handleDownloadProgress(sessionId: sessionId, progress: progress)
        }
    }

    func onComplete(outputPath: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let sessionId = self.currentSessionId else { return }
            self.currentSessionId = nil
            self.handleDownloadComplete(sessionId: sessionId, outputPath: outputPath)
        }
    }

    func onError(_ error: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentSessionId = nil
            // WiFi has taken over, or is about to — BLE errors here are expected.
            guard !self.expectingWiFiCallbacks, !self.isWiFiConnecting, !self.state.isWiFi else { return }
            self.stateSubject.send(.failed("Transfer failed: \(error)"))
        }
    }
}

// MARK: - PlaudWiFiAgentProtocol

extension SyncManager: PlaudWiFiAgentProtocol {

    // The WiFi agent has its own delegate slot, so these land here directly on
    // an SDK-internal queue — they do *not* pass through `DeviceManager`'s main
    // hop the way the BLE callbacks do. Every body that mutates `RecordingStore`
    // or publishes on a Combine subject hops to main itself, keeping the whole
    // WiFi flow main-confined like the rest of the sync state (P0-1).

    func wifiHandshake(_ status: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard status == 0 else {
                // `tearDownWiFi()`, not just `setDeviceWiFi(open: false)` — leaving
                // `expectingWiFiCallbacks`/`isWiFiConnecting` set to `true` after a
                // failure means `startWiFiTransfer()`'s retry silently no-ops:
                // `handleWiFiOpen`'s guard (`guard expectingWiFiCallbacks,
                // !isWiFiConnecting`) fails on the stale flags, so a user who taps
                // "try again" sees nothing happen at all.
                self.stateSubject.send(.failed("WiFi handshake failed (status \(status))"))
                self.tearDownWiFi()
                return
            }
            self.stateSubject.send(.wifiTransferring(SyncProgress(totalFiles: 0, syncedFiles: 0, currentFileName: nil)))
            PlaudWiFiAgent.shared.getFileList(Int(Date().timeIntervalSince1970), 0, false)
        }
    }

    func wifiFileList(_ files: [BleFile]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let knownSessionIds = Set(RecordingStore.shared.recordings.filter(\.isSynced).map(\.sessionId))
            let newFiles = files.map(RemoteFile.init).filter { !knownSessionIds.contains($0.sessionId) }

            guard !newFiles.isEmpty else {
                self.tearDownWiFi()
                self.stateSubject.send(.completed)
                return
            }

            RecordingStore.shared.add(
                newFiles.map {
                    Recording(
                        sessionId: $0.sessionId,
                        deviceSN: $0.deviceSN,
                        duration: $0.duration,
                        createdAt: $0.createdAt
                    )
                }
            )
            self.refreshLibrary()

            self.wifiPending = newFiles
            self.wifiTotalToSync = newFiles.count
            self.wifiSyncedCount = 0
            self.wifiDownloadNext()
        }
    }

    func wifiFileListFail(_ status: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Same reasoning as `wifiHandshake`'s failure branch: without
            // `tearDownWiFi()` here, a retry after this failure silently no-ops.
            self.stateSubject.send(.failed("Couldn't list files over WiFi (status \(status))"))
            self.tearDownWiFi()
        }
    }

    func wifiClose(_ status: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.handleWiFiClose()
        }
    }

    func wifiCommonErr(_ cmd: Int, _ status: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateSubject.send(.failed("WiFi error (cmd \(cmd), status \(status))"))
            self.tearDownWiFi()
        }
    }

    func wifiClientFail() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateSubject.send(.failed("Couldn't reach the recorder over WiFi."))
            self.tearDownWiFi()
        }
    }

    // Unused, but part of the protocol.
    func wifiSyncFile(_ sessionId: Int, _ status: Int) {}
    func wifiSyncFileData(_ sessionId: Int, _ offset: Int, _ count: Int, _ binData: Data) {}
    func wifiDataComplete() {}
    func wifiSyncFileStop(_ status: Int) {}
    func wifiFileDelete(_ sessionId: Int, _ status: Int) {
        print("[Sync] WiFi delete of session \(sessionId) finished with status \(status)")
    }
    func wifiPower(_ power: Int, _ voltage: Int) {}
    func wifiRateFail(_ status: Int) {}
    func wifiRate(_ instantRate: Int, _ averageRate: Int, _ lossRate: Double) {}
    func wifiLogsFail(_ status: Int) {}
    func wifiLogs(_ logData: Data?) {}
    func wifiTips(_ tips: Int) {}
    func wifiOTAStatus(_ status: Int, _ uid: Int) {}
}

// MARK: - WiFi export adapter

/// The WiFi agent takes one callback object per file, so each transfer gets its
/// own adapter that reports back to the manager.
private final class WiFiExportHandler: NSObject, AudioExportCallback {

    private let sessionId: Int
    private weak var owner: SyncManager?

    init(sessionId: Int, owner: SyncManager) {
        self.sessionId = sessionId
        self.owner = owner
    }

    func onProgress(_ progress: Int, message: String) {}

    func onComplete(outputPath: String) {
        DispatchQueue.main.async { [owner, sessionId] in
            owner?.handleWiFiExportComplete(sessionId: sessionId, outputPath: outputPath)
        }
    }

    func onError(_ error: String) {
        DispatchQueue.main.async { [owner, sessionId] in
            owner?.handleWiFiExportFailure(sessionId: sessionId)
        }
    }
}
