import Foundation

/// Haptic strength requested by the alarm loop. The watch app maps it to a
/// `WKHapticType`; this file stays Foundation-only for the command-line tests.
enum AlarmPulse: Equatable {
    case normal
    case strong
}

/// Timing of the repeated watch alarm. One place to tune after measurements:
/// the ТЗ only fixes the first pulse (≤ 2.0 s after the threshold), not the rest.
enum AlarmPattern {
    /// Pause between pulses at the start of a camera event.
    static let intervalMs: Double = 1_000
    /// After this long without an answer the pulses get stronger and denser.
    static let escalateAfterMs: Double = 6_000
    static let escalatedIntervalMs: Double = 700
    /// Hard stop, so a lost "event ended" message cannot buzz forever.
    static let maxDurationMs: Double = 60_000
    /// A recommendation or a test is a short burst, not a loop.
    static let noticePulses = 3
    static let noticeIntervalMs: Double = 600
}

/// Decides when to repeat the haptic after the first, gated pulse.
///
/// The first pulse is always decided by `AlertGate` (TTL, cancel, duplicates).
/// Repeats only continue a signal that was already accepted, and stop as soon
/// as the phone says the event is over, the user answers, or the link drops.
final class AlarmLoop {
    enum Kind { case event, notice }

    private(set) var target: String?
    private(set) var kind: Kind = .notice
    private var startedMs: Double = 0
    private var lastPulseMs: Double = 0
    private var pulses = 0

    var active: Bool { target != nil }

    /// Call right after the first (gated) haptic was played.
    func start(target: String, kind: Kind, nowMs: Double) {
        self.target = target
        self.kind = kind
        startedMs = nowMs
        lastPulseMs = nowMs
        pulses = 1
    }

    func stop() { target = nil; pulses = 0 }

    /// Latest list of events the phone still considers active.
    func snapshot(activeIDs: [String]) {
        guard let target, kind == .event else { return }
        if !activeIDs.contains(target) { stop() }
    }

    func cancel(targetIDs: [String], all: Bool) {
        guard let target else { return }
        if all || targetIDs.contains(target) { stop() }
    }

    /// Returns the pulse to play now, or nil. Call a few times per second.
    func tick(nowMs: Double) -> AlarmPulse? {
        guard target != nil else { return nil }
        if nowMs < lastPulseMs { stop(); return nil }  // clock reset
        let elapsed = nowMs - startedMs
        switch kind {
        case .notice:
            guard pulses < AlarmPattern.noticePulses else { stop(); return nil }
            guard nowMs - lastPulseMs >= AlarmPattern.noticeIntervalMs else { return nil }
            pulses += 1; lastPulseMs = nowMs
            if pulses >= AlarmPattern.noticePulses { target = nil }
            return .normal
        case .event:
            guard elapsed < AlarmPattern.maxDurationMs else { stop(); return nil }
            let escalated = elapsed >= AlarmPattern.escalateAfterMs
            let interval = escalated ? AlarmPattern.escalatedIntervalMs : AlarmPattern.intervalMs
            guard nowMs - lastPulseMs >= interval else { return nil }
            pulses += 1; lastPulseMs = nowMs
            return escalated ? .strong : .normal
        }
    }
}

/// Watches the phone link during a trip and warns once when it is lost,
/// because without the link the watch can no longer alert the driver.
final class LinkWatchdog {
    static let lossAfterMs: Double = 8_000
    private var lostSinceMs: Double?
    private var warned = false

    /// - Returns: true exactly once per loss, when the warning should play.
    func update(tripActive: Bool, reachable: Bool, nowMs: Double) -> Bool {
        guard tripActive, !reachable else { lostSinceMs = nil; warned = false; return false }
        let since = lostSinceMs ?? nowMs
        lostSinceMs = since
        guard !warned, nowMs - since >= Self.lossAfterMs else { return false }
        warned = true
        return true
    }
}
