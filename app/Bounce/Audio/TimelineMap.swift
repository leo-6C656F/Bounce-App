import Foundation

/// Maps positions on an original recording's timeline onto the shortened
/// timeline that results from keeping only some of it.
///
/// When the audio editor writes a trimmed copy, every timestamp attached to the
/// original — transcript segment bounds, highlight marks — refers to a timeline
/// that no longer exists. Without this the copy either loses its transcript
/// entirely or, worse, keeps one whose timings drift further out of step the
/// deeper into the recording you scroll, so tap-to-seek lands on the wrong
/// sentence.
///
/// Cheap to build and to query: kept ranges are few (one after a trim, a few
/// dozen after removing silence) and sorted, so lookups are a linear walk over a
/// prefix-sum table.
struct TimelineMap {

    /// Ascending, disjoint ranges of the original that survive.
    let kept: [ClosedRange<TimeInterval>]
    /// `offsets[i]` is where `kept[i]` starts on the new timeline.
    private let offsets: [TimeInterval]

    var duration: TimeInterval {
        guard let last = offsets.last, let range = kept.last else { return 0 }
        return last + (range.upperBound - range.lowerBound)
    }

    /// - Parameter kept: need not be sorted or disjoint; normalised on the way in.
    init(kept: [ClosedRange<TimeInterval>]) {
        let normalised = TimelineMap.normalise(kept)
        self.kept = normalised
        var running: TimeInterval = 0
        var offsets: [TimeInterval] = []
        offsets.reserveCapacity(normalised.count)
        for range in normalised {
            offsets.append(running)
            running += range.upperBound - range.lowerBound
        }
        self.offsets = offsets
    }

    // MARK: - Set operations
    //
    // Every editor action is one of these applied to the kept ranges: trim
    // intersects with the selection, delete subtracts it, remove-silence
    // intersects with the detected speech. They live here rather than on the view
    // model because they are pure timeline arithmetic with no UI or actor
    // involvement — which is also what makes them straightforward to verify.

    static func intersect(
        _ lhs: [ClosedRange<TimeInterval>],
        _ rhs: [ClosedRange<TimeInterval>]
    ) -> [ClosedRange<TimeInterval>] {
        var result: [ClosedRange<TimeInterval>] = []
        for left in lhs {
            for right in rhs {
                let lower = Swift.max(left.lowerBound, right.lowerBound)
                let upper = Swift.min(left.upperBound, right.upperBound)
                if upper > lower { result.append(lower...upper) }
            }
        }
        return normalise(result)
    }

    static func subtract(
        _ ranges: [ClosedRange<TimeInterval>],
        _ cut: ClosedRange<TimeInterval>
    ) -> [ClosedRange<TimeInterval>] {
        var result: [ClosedRange<TimeInterval>] = []
        for range in ranges {
            // Disjoint — keep whole.
            if cut.upperBound <= range.lowerBound || cut.lowerBound >= range.upperBound {
                result.append(range)
                continue
            }
            if range.lowerBound < cut.lowerBound {
                result.append(range.lowerBound...cut.lowerBound)
            }
            if cut.upperBound < range.upperBound {
                result.append(cut.upperBound...range.upperBound)
            }
        }
        return normalise(result)
    }

    /// Sorts, drops zero-length ranges, and coalesces overlapping *and touching*
    /// ones. Touching matters: `0...10` and `10...20` left separate would show as
    /// two segments in the strip and be written as two frame runs, for a boundary
    /// that isn't there.
    static func normalise(_ ranges: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        let sorted = ranges
            .filter { $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard var current = sorted.first else { return [] }
        var result: [ClosedRange<TimeInterval>] = []
        for range in sorted.dropFirst() {
            if range.lowerBound <= current.upperBound {
                current = current.lowerBound...Swift.max(current.upperBound, range.upperBound)
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }

    // MARK: - Queries

    /// Where `time` lands on the new timeline, or nil if it was removed.
    func map(_ time: TimeInterval) -> TimeInterval? {
        for (index, range) in kept.enumerated() where range.contains(time) {
            return offsets[index] + (time - range.lowerBound)
        }
        return nil
    }

    /// Where `time` lands, snapping a removed position forward to the start of
    /// the next kept region.
    ///
    /// Used for the *start* of a transcript segment that begins inside a cut:
    /// dropping the segment would lose text that is still partly audible, so it
    /// is pulled to where its surviving audio begins.
    func mapClampingForward(_ time: TimeInterval) -> TimeInterval? {
        if let exact = map(time) { return exact }
        for (index, range) in kept.enumerated() where range.lowerBound > time {
            return offsets[index]
        }
        return nil
    }

    /// Where `time` lands, snapping a removed position back to the end of the
    /// previous kept region. The mirror of `mapClampingForward`, for segment ends.
    func mapClampingBackward(_ time: TimeInterval) -> TimeInterval? {
        if let exact = map(time) { return exact }
        for (index, range) in kept.enumerated().reversed() where range.upperBound < time {
            return offsets[index] + (range.upperBound - range.lowerBound)
        }
        return nil
    }

    /// How much of `range` survives, in seconds.
    func survivingDuration(of range: ClosedRange<TimeInterval>) -> TimeInterval {
        kept.reduce(0) { total, keptRange in
            let lower = Swift.max(range.lowerBound, keptRange.lowerBound)
            let upper = Swift.min(range.upperBound, keptRange.upperBound)
            return total + Swift.max(0, upper - lower)
        }
    }

    // MARK: - Model remapping

    /// The transcript rewritten onto the new timeline.
    ///
    /// A segment is kept when **more than half** of it survives. Half is a
    /// judgement call, and the reasoning is that a segment is a phrase: keeping
    /// one whose audio is mostly gone puts words on screen that can't be heard
    /// and that tap-to-seek can only land near, which reads as a bug. Dropping
    /// one that mostly survives loses real content. Half splits those.
    ///
    /// Returns nil when nothing survives — the caller should then treat the copy
    /// as untranscribed rather than attaching an empty transcript, which would
    /// make `isTranscribed` true and suppress the transcription queue.
    func remap(_ transcript: Transcript) -> Transcript? {
        var segments: [TranscriptSegment] = []
        for segment in transcript.segments {
            let span = segment.start...Swift.max(segment.start, segment.end)
            let original = Swift.max(0, span.upperBound - span.lowerBound)
            let surviving = survivingDuration(of: span)
            // Zero-length segments (a single-word timestamp) can't be judged by
            // proportion, so they survive iff their position does.
            if original > 0 {
                guard surviving > original / 2 else { continue }
            }
            guard let start = mapClampingForward(span.lowerBound),
                  let end = mapClampingBackward(span.upperBound) else { continue }
            segments.append(TranscriptSegment(
                text: segment.text,
                start: start,
                end: Swift.max(start, end),
                speaker: segment.speaker))
        }
        guard !segments.isEmpty else { return nil }

        var remapped = Transcript(
            segments: segments,
            localeIdentifier: transcript.localeIdentifier,
            createdAt: transcript.createdAt)
        remapped.isPreview = transcript.isPreview
        return remapped
    }

    /// Highlight marks that survive, on the new timeline.
    func remap(highlights: [TimeInterval]?) -> [TimeInterval]? {
        guard let highlights else { return nil }
        let mapped = highlights.compactMap { map($0) }.sorted()
        return mapped.isEmpty ? nil : mapped
    }
}

extension Array where Element == ClosedRange<TimeInterval> {
    /// Total length of the ranges. Assumes they're disjoint, which everything
    /// produced by `TimelineMap.normalise` — and therefore by `intersect` and
    /// `subtract` — is.
    var totalDuration: TimeInterval {
        reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }
}
