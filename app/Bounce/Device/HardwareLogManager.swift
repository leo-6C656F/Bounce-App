import Combine
import Foundation
import Observation
import PlaudBleSDK
@preconcurrency import PlaudDeviceBasicSDK

/// Manages pulling, buffering, formatting, and exporting hardware diagnostic logs from the Plaud recorder.
///
/// Hardware logs are requested via `PlaudDeviceAgent.shared.getDeviceLogList(logType:)` and
/// `PlaudDeviceAgent.shared.startSyncDeviceLogFile(logType:)`. Incoming log data chunks arrive on
/// `DeviceManager` via `deviceLogData`, `onSyncDeviceLogStart`, `onSyncDeviceLogStop`, and
/// `onSyncDeviceLogEnd` callbacks and are forwarded here.
@MainActor
@Observable
final class HardwareLogManager {

    static let shared = HardwareLogManager()

    enum State: Equatable {
        case idle
        case fetching(receivedBytes: Int)
        case ready(logText: String, fileURL: URL, fetchedAt: Date)
        case failed(reason: String)

        var isFetching: Bool {
            if case .fetching = self { return true }
            return false
        }
    }

    private(set) var state: State = .idle
    private(set) var lastFetchError: String?

    /// Buffer for incoming binary/text log chunks during a stream
    private var logBuffer = Data()
    private var fetchTimeoutTask: Task<Void, Never>?

    private init() {}

    // MARK: - Actions

    /// Request hardware logs from the paired recorder.
    func fetchLogs(logType: Int = 0) {
        guard DeviceManager.shared.connectionState.isConnected else {
            state = .failed(reason: "Recorder is not connected.")
            return
        }

        DeviceLog.log("HardwareLogManager: fetching hardware logs (logType: \(logType))")
        logBuffer.removeAll()
        state = .fetching(receivedBytes: 0)
        lastFetchError = nil

        // Set safety timeout (15s) in case hardware stream stalls or ends silently
        fetchTimeoutTask?.cancel()
        fetchTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            if case .fetching(let count) = self.state {
                if count > 0 {
                    self.finalizeLogBuffer()
                } else {
                    self.state = .failed(reason: "Fetch timed out. No log response received from recorder.")
                }
            }
        }

        // Request list and start stream
        BleAgent.shared.getDeviceLogList(logType: logType)
        BleAgent.shared.startSyncDeviceLogFile(logType: logType)
    }

    /// Stop an in-progress log sync stream.
    func stopSync() {
        BleAgent.shared.stopSyncDeviceLogFile()
        fetchTimeoutTask?.cancel()
        if case .fetching(let count) = state, count > 0 {
            finalizeLogBuffer()
        } else {
            state = .idle
        }
    }

    /// Delete hardware log files on the recorder to reclaim internal log storage.
    func deleteLogsFromDevice(logType: Int = 0) {
        DeviceLog.log("HardwareLogManager: deleting hardware logs on device (logType: \(logType))")
        BleAgent.shared.deleteDeviceLogFile(logType: logType)
    }

    /// Reset local fetched state.
    func clear() {
        fetchTimeoutTask?.cancel()
        logBuffer.removeAll()
        state = .idle
        lastFetchError = nil
    }

    // MARK: - Delegate Handlers (Forwarded from DeviceManager)

    func handleLogData(start: Int, data: Data, logType: Int) {
        logBuffer.append(data)
        DeviceLog.log("HardwareLogManager: received \(data.count) log bytes (offset: \(start), total: \(logBuffer.count))")
        state = .fetching(receivedBytes: logBuffer.count)
    }

    func handleLogList(data: Data) {
        DeviceLog.log("HardwareLogManager: onGetDeviceLogList received \(data.count) bytes")
        if !data.isEmpty, logBuffer.isEmpty {
            logBuffer.append(data)
            state = .fetching(receivedBytes: logBuffer.count)
        }
    }

    func handleSyncLogStart(data: Data) {
        DeviceLog.log("HardwareLogManager: onSyncDeviceLogStart (\(data.count) header bytes)")
        if !data.isEmpty {
            logBuffer.append(data)
        }
        state = .fetching(receivedBytes: logBuffer.count)
    }

    func handleSyncLogStop() {
        DeviceLog.log("HardwareLogManager: onSyncDeviceLogStop")
        finalizeLogBuffer()
    }

    func handleSyncLogEnd(data: Data) {
        DeviceLog.log("HardwareLogManager: onSyncDeviceLogEnd (\(data.count) tail bytes)")
        if !data.isEmpty {
            logBuffer.append(data)
        }
        finalizeLogBuffer()
    }

    func handleDeviceLogDeleted(data: Data) {
        DeviceLog.log("HardwareLogManager: onDeviceLogDeleted status=\(data.hexDescription)")
    }

    // MARK: - Internal Helper

    private func finalizeLogBuffer() {
        fetchTimeoutTask?.cancel()

        // Guards against a late, duplicate stop/end callback re-finalizing a
        // buffer that's already been written out: `stopSync()` (synchronous,
        // user-initiated) and `handleSyncLogStop`/`handleSyncLogEnd` (async,
        // device-initiated) can both reach here for the same fetch, and
        // `logBuffer` wasn't otherwise cleared after use, so a second call
        // would silently write a second temp file and overwrite `state` with
        // a fresh `.ready(...)` — a duplicate side effect with no signal
        // distinguishing it from the first, legitimate finalization.
        guard state.isFetching else { return }

        guard !logBuffer.isEmpty else {
            state = .failed(reason: "Hardware log buffer is empty.")
            logBuffer.removeAll()
            return
        }

        let serial = DeviceManager.shared.device?.serialNumber ?? "recorder"
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let dateStr = timestampFormatter.string(from: Date())

        let fileName = "Plaud-HardwareLog-\(serial)-\(dateStr).txt"
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        let logText: String
        if let decodedStr = String(data: logBuffer, encoding: .utf8), !decodedStr.isEmpty {
            logText = decodedStr
        } else if let asciiStr = String(data: logBuffer, encoding: .ascii), !asciiStr.isEmpty {
            logText = asciiStr
        } else {
            // Hex dump formatted fallback if binary log payload
            logText = "--- Binary Log Payload (\(logBuffer.count) bytes) ---\n" + logBuffer.hexDescription
        }

        let formattedOutput = """
        ===================================================================
        Plaud Recorder Hardware Diagnostic Log Dump
        Serial Number: \(serial)
        Dumped At: \(Date().formatted(date: .numeric, time: .standard))
        Payload Size: \(logBuffer.count) bytes
        ===================================================================

        \(logText)
        """

        do {
            try formattedOutput.write(to: fileURL, atomically: true, encoding: .utf8)
            state = .ready(logText: formattedOutput, fileURL: fileURL, fetchedAt: Date())
            DeviceLog.log("HardwareLogManager: saved \(logBuffer.count) bytes to \(fileURL.lastPathComponent)")
        } catch {
            state = .failed(reason: "Failed to write hardware log file: \(error.localizedDescription)")
        }
        logBuffer.removeAll()
    }
}
