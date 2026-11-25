import Foundation

/// Haptic requested by the alarm loop. The watch app maps it to a
/// `WKHapticType`; this file stays Foundation-only for the command-line tests.
enum AlarmPulse: Equatable {
    case alarm        // .notification
    case alarmRepeat  // .retry
    case soft         // .directionUp
}

/// Watch signal patterns, docs/ux/watch.md §4. One place to tune after
/// measurements: the ТЗ only fixes the first pulse (≤ 2.0 s after the threshold).
enum AlarmPattern {
    static let intervalMs: Double = 800
    /// No reaction for this long: pulses get denser.
    static let escalateAfterMs: Double = 5_000
    static let escalatedIntervalMs: Double = 400
    /// After this long the loop slows down to a reminder pulse.
    static let reminderAfterMs: Double = 30_000
    static let reminderIntervalMs: Double = 3_000
    /// Hard stop, so a lost "event ended" message cannot buzz forever.
    static let maxDurationMs: Double = 5 * 60_000
    static let noticeIntervalMs: Double = 600
}

/// Decides when to repeat the haptic after the first, gated pulse.
///
/// The first pulse is always decided by `AlertGate` (TTL, cancel, duplicates).
/// Repeats only continue a signal that was already accepted, and stop as soon
/// as the phone says the event is over, the user answers, or the link drops.
final class AlarmLoop {
    enum Kind: Equatable {
        /// Camera event: repeats until it ends, is cancelled or answered.
        case event
        /// Short series (advice, test, mild "на дорогу"); `pulses` includes the first.
        case notice(pulses: Int, pulse: AlarmPulse)
    }

    private(set) var target: String?
    private(set) var kind: Kind = .event
    private var startedMs: Double = 0
    private var lastPulseMs: Double = 0
    private var pulses = 0

    var active: Bool { target != nil }
    var isEvent: Bool { active && kind == .event }

    /// Call right after the first (gated) haptic was played.
    func start(target: String, kind: Kind, nowMs: Double) {
        self.target = target
        self.kind = kind
        startedMs = nowMs
        lastPulseMs = nowMs
        pulses = 1
        if case .notice(let total, _) = kind, total <= 1 { self.target = nil }
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
        case .notice(let total, let pulse):
            guard nowMs - lastPulseMs >= AlarmPattern.noticeIntervalMs else { return nil }
            pulses += 1; lastPulseMs = nowMs
            if pulses >= total { target = nil }
            return pulse
        case .event:
            guard elapsed < AlarmPattern.maxDurationMs else { stop(); return nil }
            let interval = elapsed >= AlarmPattern.reminderAfterMs ? AlarmPattern.reminderIntervalMs
                : elapsed >= AlarmPattern.escalateAfterMs ? AlarmPattern.escalatedIntervalMs
                : AlarmPattern.intervalMs
            guard nowMs - lastPulseMs >= interval else { return nil }
            pulses += 1; lastPulseMs = nowMs
            // .notification, then .retry, alternating.
            return pulses % 2 == 0 ? .alarmRepeat : .alarm
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

/// Trip summary shown on W-09, counted on the watch itself.
struct TripTally {
    private(set) var startedMs: Double?
    private(set) var alarms = 0

    mutating func update(tripActive: Bool, nowMs: Double) -> (minutes: Int, alarms: Int)? {
        if tripActive {
            if startedMs == nil { startedMs = nowMs; alarms = 0 }
            return nil
        }
        guard let start = startedMs else { return nil }
        startedMs = nil
        return (Int(((nowMs - start) / 60_000).rounded()), alarms)
    }

    mutating func alarm() { if startedMs != nil { alarms += 1 } }
}
