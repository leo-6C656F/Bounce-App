import Combine
import Foundation
import PlaudDeviceBasicSDK

/// Idle WiFi sync: WiFi credentials stored on the recorder so it uploads its
/// own recordings on its own schedule, with no phone involved.
///
/// Tier 1 per `docs/plans/sdk-expansion.md` Phase 1 — every command here has
/// a matching callback on `PlaudDeviceAgentProtocol`, forwarded by
/// `DeviceManager`, so state is only ever set from an `on*` callback, never
/// assumed optimistically the way Phase 4's `setUDiskMode` has to be.
///
/// **Open question, unresolved: whether idle sync uploads to Plaud's cloud or
/// to a URL Bounce could ingest from itself.** That's the one thing that
/// can't be answered by reading the SDK — it needs a real recorder to
/// actually run an idle sync and see what `onWifiSyncUrl` reports. Until
/// then, this wiring is "buildable and safe to ship" but not yet verified
/// against the app's on-device-by-default privacy claim.
final class IdleSyncManager {

    static let shared = IdleSyncManager()

    /// A WiFi network stored on the recorder. The password is deliberately
    /// not part of this type — once written, Bounce has no reason to hold a
    /// copy, and `onWifiSyncConfigReceived` does return it, but we discard it
    /// rather than cache it anywhere.
    struct Network: Identifiable, Equatable {
        var index: UInt32
        var ssid: String
        var id: UInt32 { index }
    }

    enum TestResult: Equatable {
        case testing
        case succeeded
        case failed(code: Int)

        var label: String {
            switch self {
            case .testing: return "Testing…"
            case .succeeded: return "Connected successfully"
            case .failed(let code): return "Couldn't connect (code \(code))"
            }
        }
    }

    private let enabledSubject = CurrentValueSubject<Bool, Never>(false)
    private let networksSubject = CurrentValueSubject<[Network], Never>([])
    private let testResultsSubject = CurrentValueSubject<[UInt32: TestResult], Never>([:])

    var enabledPublisher: AnyPublisher<Bool, Never> { enabledSubject.eraseToAnyPublisher() }
    var networksPublisher: AnyPublisher<[Network], Never> { networksSubject.eraseToAnyPublisher() }
    var testResultsPublisher: AnyPublisher<[UInt32: TestResult], Never> { testResultsSubject.eraseToAnyPublisher() }

    private init() {}

    // MARK: - Commands

    /// Pull current enable state and network list from the recorder. Call on
    /// connect and whenever the idle sync screen appears — nothing here is
    /// pushed to us proactively outside of that.
    func refresh() {
        PlaudDeviceAgent.shared.getWifiSyncEnable()
        PlaudDeviceAgent.shared.getWifiSyncList()
    }

    func setEnabled(_ enabled: Bool) {
        PlaudDeviceAgent.shared.setWifiSyncEnable(value: enabled ? 1 : 0)
    }

    /// `password` is handed straight to the SDK and never logged or persisted
    /// by Bounce — the recorder is the only place it's stored afterward.
    ///
    /// `operation` has no documented meaning beyond its `Int` type; `0` is the
    /// only value exercised so far (add-or-replace-by-index). Flagged rather
    /// than guessed further — confirm on device before relying on any other
    /// value.
    func saveNetwork(index: UInt32, ssid: String, password: String) {
        DeviceLog.log("saveNetwork index=\(index) ssid=\(ssid)")
        PlaudDeviceAgent.shared.setWifiSyncConfig(operation: 0, wifiIndex: index, ssid: ssid, password: password)
    }

    func deleteNetworks(indices: [UInt32]) {
        DeviceLog.log("deleteNetworks indices=\(indices)")
        PlaudDeviceAgent.shared.deleteWifiSyncConfig(wifiIndices: indices)
    }

    func test(index: UInt32) {
        var results = testResultsSubject.value
        results[index] = .testing
        testResultsSubject.send(results)
        PlaudDeviceAgent.shared.setWifiSyncTest(wifiIndex: index)
    }

    /// The lowest index not already in use, for "add a network" flows. The
    /// SDK gives no documented slot limit, so this is unbounded — an
    /// out-of-range index is expected to fail silently on the recorder like
    /// any other unsupported command, per the SDK's usual failure mode.
    func nextFreeIndex() -> UInt32 {
        let used = Set(networksSubject.value.map(\.index))
        var candidate: UInt32 = 0
        while used.contains(candidate) { candidate += 1 }
        return candidate
    }

    // MARK: - Callbacks from DeviceManager

    func handleEnabled(_ value: Int) {
        enabledSubject.send(value != 0)
    }

    func handleListReceived(_ indices: [UInt32]) {
        let existingSSIDs = Dictionary(uniqueKeysWithValues: networksSubject.value.map { ($0.index, $0.ssid) })
        networksSubject.send(indices.map { Network(index: $0, ssid: existingSSIDs[$0] ?? "") })
        // The list callback only carries indices — fetch each network's SSID.
        for index in indices { PlaudDeviceAgent.shared.getWifiSyncConfig(wifiIndex: index) }
    }

    func handleConfigReceived(index: UInt32, ssid: String) {
        var networks = networksSubject.value
        guard let position = networks.firstIndex(where: { $0.index == index }) else { return }
        networks[position].ssid = ssid
        networksSubject.send(networks)
    }

    func handleConfigSet(result: Int) {
        DeviceLog.log("onWifiSyncConfigSet result=\(result)")
        refresh()
    }

    func handleDeleteResult(_ result: Int) {
        DeviceLog.log("onWifiSyncDeleteResult result=\(result)")
        refresh()
    }

    func handleTestStarted(index: UInt32) {
        var results = testResultsSubject.value
        results[index] = .testing
        testResultsSubject.send(results)
    }

    func handleTestResult(index: UInt32, result: Int) {
        var results = testResultsSubject.value
        results[index] = result == 0 ? .succeeded : .failed(code: result)
        testResultsSubject.send(results)
    }

    func handleWillStart(seconds: Int) {
        DeviceLog.log("onWifiSyncWillStart — recorder will start idle sync in \(seconds)s")
    }

    /// The one callback that answers this feature's open question. Logged in
    /// full and deliberately not acted on (no auto-ingest) until an on-device
    /// test shows whether it points at Plaud's cloud or somewhere Bounce
    /// controls.
    func handleUrl(_ url: String) {
        DeviceLog.log("onWifiSyncUrl — recorder reports \(url) — unverified whether this is Plaud's cloud or ours")
    }
}
