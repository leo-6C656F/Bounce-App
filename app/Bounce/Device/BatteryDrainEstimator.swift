import Foundation

/// Estimates how fast the recorder's battery is draining, in percent per hour,
/// from the change-driven readings the SDK pushes.
///
/// Deliberately pure — `Foundation` only, no Combine, no `AppModel`, no
/// `UserDefaults` — so it can be compiled and exercised on the Mac. Same shape
/// and same reason as `BatteryAlertLatch`. All persistence is the caller's job:
/// `state` is readable and `init(state:)` takes it back. Regression checks:
/// `tools/battery-drain-tests/main.swift`.
///
/// ## What we actually get to measure
///
/// The recorder reports battery as an **integer percent** (standard BLE Battery
/// Service, uint8 0–100), delivered *change-driven* via `blePowerChange` /
/// `bleChargingState` — nothing polls it. So the raw signal is a staircase, and
/// the only high-quality information in it is **when each step happened**.
///
/// Whether the steps are 1% or 5% is **not known** — the firmware decides, and it
/// determines whether a per-recording figure is viable at all. That is what
/// `observedStepSizes` is for: discover it from hardware instead of assuming it.
///
/// ## Edge-to-edge timing, not endpoint-to-endpoint — the whole idea
///
/// The obvious estimator is "level at the start of the window minus level at the
/// end, divided by the window". It is *badly* biased, because both endpoints land
/// somewhere inside a quantization step and you don't know where:
///
/// - At the start, the level had already been sitting at (say) 80% for an unknown
///   fraction of a step before we ever looked. That time is counted in the
///   denominator but its drain is not in the numerator.
/// - At the end, the same again: the level has been at 70% for a while and is
///   partway to 69%, and that partial step is invisible.
///
/// Each endpoint therefore contributes up to a **full step** of error — 1% or,
/// worse, 5% — in the same direction: the measured drain is systematically *too
/// low*. Timing the **edges** removes both. If the level became 79% at `t₁` and
/// became 70% at `tₙ`, then exactly 9% was lost in exactly `tₙ - t₁`, with error
/// only in the latency of observing each edge (milliseconds of BLE callback
/// dispatch) rather than a whole percent of charge. That roughly halves the
/// window needed for a given accuracy — which is the difference between a figure
/// that is meaningful over an hour and one that needs a whole day.
///
/// Consequence, and it is why the first reading of a span is not a transition:
/// the level we *join* at is only a baseline. The measurement starts at the first
/// observed edge.
///
/// ## Spans, and why they are discarded rather than averaged
///
/// A *span* is a stretch of uninterrupted, connected, discharging observation.
/// Anything that puts a hole in the staircase **ends** the current span rather
/// than merely skipping a sample:
///
/// - **Charging.** Not a drain measurement at all.
/// - **A disconnect.** BLE callbacks stop; edges pass unobserved.
/// - **A WiFi transfer.** BLE drops *by design* during one (see
///   `PlaudDeviceAgent.isWiFiTransferActive`), so battery callbacks stop exactly
///   where the biggest drain is. Averaging across it would report the *lowest*
///   rate at the moment of the highest.
/// - **A rising level.** Either charging we didn't observe or a fuel-gauge
///   re-estimate. A rise never contributes, so the rate can never come out
///   negative.
///
/// Only the **current** span is estimated from. Spans are never pooled, because
/// **Li-ion percent is not energy**: the discharge curve is flat through the
/// middle and steep at both ends, and gauges re-estimate and jump. A 100→90%
/// span and a 20→10% span can differ by a factor of two on identical load, so
/// averaging them produces a number that describes neither. `Estimate.levelRange`
/// is published for exactly this reason — a caller comparing two figures (say,
/// "with live transcription" vs "without") must check that the ranges overlap
/// before drawing any conclusion, and refuse otherwise.
///
/// ## Dedupe on the level, not on the callback
///
/// `DeviceManager.deviceSubject` is a `CurrentValueSubject` with **no**
/// `removeDuplicates`, and `mutateDevice` republishes on *any* device change —
/// storage, name, firmware. A sampler fed from `devicePublisher` therefore sees
/// many callbacks carrying an unchanged battery value. Those are not transitions;
/// counting them would fill the series with zero-delta samples and compute a
/// drain rate of zero.
struct BatteryDrainEstimator {

    /// One observed **edge**: the level became `level` at `at`.
    struct Sample: Codable, Hashable {
        var level: Int
        var at: Date
    }

    /// A drain figure and everything needed to judge whether to trust it.
    struct Estimate: Hashable {

        /// Drain rate, always ≥ 0 (a rise ends the span rather than producing a
        /// negative rate).
        var percentPerHour: Double

        /// Edges observed in this span. The rate is measured across
        /// `transitionsObserved - 1` intervals.
        var transitionsObserved: Int

        /// First edge to last edge. Shorter than the span of *observation*, on
        /// purpose — see the type comment.
        var span: TimeInterval

        /// The percentage band the rate was measured over, low…high. Compare two
        /// estimates only when these overlap; Li-ion percent is not linear in
        /// energy.
        var levelRange: ClosedRange<Int>

        /// True when some interval between consecutive edges exceeded
        /// `suspiciousGap` — the app was almost certainly suspended or terminated
        /// and missed edges. **The reported rate is then too low**, not too high:
        /// unobserved time still lands in the denominator. Surface it as "may be
        /// understated" rather than hiding the figure, since a long gap is normal
        /// for a phone.
        var containsSuspiciousGap: Bool
    }

    /// Everything worth persisting between launches. The caller owns storage
    /// (JSON in `UserDefaults` is plenty — a span holds at most ~100 samples).
    struct State: Codable, Hashable {

        /// Edges in the current span, oldest first.
        var transitions: [Sample] = []

        /// Most recent trusted level, transition or baseline. Nil means the next
        /// valid reading starts a new span as its baseline.
        var lastLevel: Int?

        /// Distinct downward step sizes ever seen. Survives span ends — it is a
        /// property of the firmware, not of one measurement window.
        var observedStepSizes: Set<Int> = []
    }

    /// Edges required before `estimate` returns anything.
    ///
    /// The honesty valve. With 1% steps, 10 edges is a 9% drop; at a plausible
    /// 3%/hr that is roughly a three-hour window, and anything shorter is noise
    /// dominated by when the phone happened to be listening. A caller with fewer
    /// shows "Not enough data yet" rather than a number.
    static let defaultMinimumTransitions = 10

    /// Longest interval between consecutive edges that is still credible as
    /// continuous observation.
    ///
    /// A judgement call, not a measurement. Six hours is longer than any single
    /// step should plausibly take on a connected, discharging recorder even at
    /// 5% granularity and a low idle draw, and short enough to catch the case
    /// this is really for: the app was killed overnight and the span silently
    /// spans the gap. Raise it if hardware turns out to step more slowly than
    /// that.
    static let defaultSuspiciousGap: TimeInterval = 6 * 3600

    var minimumTransitions: Int
    var suspiciousGap: TimeInterval

    private(set) var state: State

    init(
        state: State = State(),
        minimumTransitions: Int = BatteryDrainEstimator.defaultMinimumTransitions,
        suspiciousGap: TimeInterval = BatteryDrainEstimator.defaultSuspiciousGap
    ) {
        self.state = state
        self.minimumTransitions = minimumTransitions
        self.suspiciousGap = suspiciousGap
    }

    // MARK: - Feeding readings

    /// Feed one reading.
    ///
    /// - Returns: true when the reading was **recorded as an edge** — i.e. the
    ///   level actually moved downward under trustworthy conditions. False when
    ///   it was ignored (unchanged, unknown, or span-ending).
    ///
    /// - Parameters:
    ///   - level: Battery percentage, or nil when unknown. Anything outside
    ///     1…100 is treated as unknown; **0 in particular**, because
    ///     `DeviceManager` builds `PlaudDevice` with `raw?.power ?? 0` before the
    ///     first real reading lands, and taking that placeholder as an edge would
    ///     invent a huge drop on every connect.
    ///   - isCharging: Ends the span.
    ///   - isConnected: False ends the span.
    ///   - isTransferring: A file transfer in progress (`SyncState.isActive`).
    ///     Ends the span.
    ///
    /// Ordering note that matters: the **conditions are checked before the
    /// level**. A nil level on its own is inert — it neither records nor ends a
    /// span, since an unrelated snapshot lacking a battery value is no evidence
    /// of anything. But a nil level *with* `isConnected == false` does end the
    /// span, and it has to: `DeviceManager.bleDeviceDisconnectErr` sends
    /// `deviceSubject.send(nil)`, so the disconnect snapshot has no level by
    /// construction. Treating nil as inert first would mean disconnects never
    /// ended a span at all.
    @discardableResult
    mutating func record(
        level: Int?,
        at: Date,
        isCharging: Bool,
        isConnected: Bool,
        isTransferring: Bool
    ) -> Bool {
        guard isConnected, !isCharging, !isTransferring else {
            endSpan()
            return false
        }

        guard let level, (1...100).contains(level) else { return false }

        // No baseline yet: this reading is one, not an edge. We have no idea how
        // long the level had already been sitting here.
        guard let previous = state.lastLevel else {
            state.lastLevel = level
            return false
        }

        // Unchanged — a republished snapshot, not a transition. See the type
        // comment on `removeDuplicates`.
        guard level != previous else { return false }

        // A rise means charging we didn't see, or the gauge re-estimated. End the
        // span; the new level is the baseline of the next one. Never a negative
        // rate, and the step is not recorded — a +40% jump says nothing about the
        // firmware's discharge granularity.
        guard level < previous else {
            endSpan()
            state.lastLevel = level
            return false
        }

        // The clock moved backwards (time zone edit, NTP correction). Timestamps
        // in the span are no longer comparable, so start over rather than emit a
        // nonsense interval.
        if let last = state.transitions.last, at < last.at {
            endSpan()
            state.lastLevel = level
            return false
        }

        state.observedStepSizes.insert(previous - level)
        state.transitions.append(Sample(level: level, at: at))
        state.lastLevel = level
        return true
    }

    /// End the current span, keeping the granularity evidence.
    mutating func endSpan() {
        state.transitions.removeAll()
        state.lastLevel = nil
    }

    /// Forget everything, granularity evidence included. For when the recorder
    /// itself changes (unpair, switch device) — a different unit may run
    /// different firmware.
    mutating func reset() {
        state = State()
    }

    // MARK: - Reading out

    /// Nil until the evidence is sufficient — fewer than `minimumTransitions`
    /// edges, or a degenerate window.
    var estimate: Estimate? {
        guard state.transitions.count >= minimumTransitions,
            let first = state.transitions.first,
            let last = state.transitions.last
        else { return nil }

        let span = last.at.timeIntervalSince(first.at)
        let drop = first.level - last.level
        guard span > 0, drop > 0 else { return nil }

        return Estimate(
            percentPerHour: Double(drop) / span * 3600,
            transitionsObserved: state.transitions.count,
            span: span,
            // `first.level` is the level *after* the first edge, which is exactly
            // the band the rate was measured over — not the baseline we joined at.
            levelRange: last.level...first.level,
            containsSuspiciousGap: hasSuspiciousGap
        )
    }

    /// Distinct observed step sizes, so the app can discover whether the firmware
    /// reports 1% or 5% steps rather than assuming. Downward steps only.
    ///
    /// A mixed set (e.g. `[1, 2]`) is normal even at 1% granularity — a 2 appears
    /// whenever the app was not listening for one intermediate edge. The useful
    /// reading is the **minimum**: if it never goes below 5, the firmware steps
    /// in 5s and any figure from a short recording is worthless.
    var observedStepSizes: Set<Int> { state.observedStepSizes }

    /// Edges in the current span. For a "collecting data…" progress hint.
    var transitionsInCurrentSpan: Int { state.transitions.count }

    private var hasSuspiciousGap: Bool {
        zip(state.transitions, state.transitions.dropFirst())
            .contains { $1.at.timeIntervalSince($0.at) > suspiciousGap }
    }
}
