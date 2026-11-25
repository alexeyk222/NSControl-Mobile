import Foundation
import HealthKit
import WatchConnectivity
import WatchKit

/// What the watch shows. Derived from the phone's live snapshot and alerts.
enum WatchPhase: Equatable {
    case noLink        // phone app not reachable
    case idle          // linked, no trip
    case observing     // trip running, camera sees the driver
    case limited       // trip running, camera cannot judge right now
    case alarm         // camera event: repeated haptic until answered
    case notice        // recommendation or test: short burst
}

/// Live link to the iPhone app. One instance for the app's lifetime, so the
/// workout launch from the phone (`handle(_:)`) and the UI share the state.
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchLink()

    @Published private(set) var phase: WatchPhase = .noLink
    @Published private(set) var title = "Нет связи с iPhone"
    @Published private(set) var detail = "Откройте NSControl на iPhone"
    @Published private(set) var driveMinutes: Int?
    @Published private(set) var recommendation: String?
    @Published private(set) var background: BackgroundSession.State = .off
    @Published private(set) var lastDelivery: String?

    let workout = BackgroundSession()
    private let gate = AlertGate()
    private let loop = AlarmLoop()
    private let watchdog = LinkWatchdog()
    private let wc = WCSession.default
    private var receiverEpoch = UUID().uuidString
    private var level = "idle"
    private var activeIDs: [String] = []
    private var alarmReason = ""
    private var alarmTarget: String?
    private var unreachableSinceMs: Double?
    private var timer: Timer?

    /// Phone app gone for this long during a trip: end the background session to save battery.
    static let abandonAfterMs: Double = 10 * 60_000

    private override init() {
        super.init()
        workout.onChange = { [weak self] state in
            self?.background = state
            self?.sendState()
        }
        wc.delegate = self
        wc.activate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
    private var tripActive: Bool { level != "idle" }

    // MARK: - User actions

    /// "Я в порядке" on the alarm screen. Stops the local loop at once; the phone
    /// acknowledges the event, stops its sound and answers with `cancel`.
    func acknowledgeAlarm() {
        if let target = alarmTarget { send("user_ack", ["event_ids": [target]]) }
        loop.stop()
        alarmTarget = nil
        refresh()
    }

    /// Local vibration check, no phone involved.
    func testVibration() {
        play(.normal)
        loop.start(target: "local-test", kind: .notice, nowMs: nowMs())
    }

    /// Asks for the workout permission and starts the background session if a trip runs.
    func enableBackground() {
        workout.authorize { [weak self] _ in
            guard let self else { return }
            if self.tripActive { self.workout.start() } else { self.background = self.workout.authorized ? .off : .denied }
            self.sendState()
        }
    }

    /// Launched by the phone (`HKHealthStore.startWatchApp`) at trip start.
    func launchedForTrip(_ configuration: HKWorkoutConfiguration) {
        workout.start(configuration: configuration)
    }

    // MARK: - Haptics

    private func play(_ pulse: AlarmPulse) {
        // Tune on the device: .notification is the strongest standard pattern.
        WKInterfaceDevice.current().play(pulse == .strong ? .failure : .notification)
    }

    private func tick() {
        let now = nowMs()
        if let pulse = loop.tick(nowMs: now) { play(pulse) }
        if !loop.active, alarmTarget != nil || phase == .notice { alarmTarget = nil; refresh() }
        if watchdog.update(tripActive: tripActive, reachable: wc.isReachable, nowMs: now) {
            WKInterfaceDevice.current().play(.failure)
        }
        if tripActive, !wc.isReachable {
            let since = unreachableSinceMs ?? now
            unreachableSinceMs = since
            if now - since >= Self.abandonAfterMs {
                level = "idle"; workout.stop(); refresh()
            }
        } else {
            unreachableSinceMs = nil
        }
    }

    // MARK: - UI state

    private func refresh() {
        let reachable = wc.activationState == .activated && wc.isReachable
        if loop.active, loop.kind == .event {
            phase = .alarm; title = "Внимание!"; detail = alarmReason
        } else if loop.active {
            phase = .notice; title = alarmTarget == nil ? "Проверка вибрации" : "Совет"
            detail = alarmTarget == nil ? "Так часы предупредят вас в поездке" : alarmReason
        } else if !reachable {
            phase = .noLink
            title = tripActive ? "Связь с iPhone потеряна" : "Нет связи с iPhone"
            detail = tripActive ? "Часы не смогут предупредить. Телефон продолжает следить сам"
                                : "Откройте NSControl на iPhone"
        } else {
            switch level {
            case "observing", "warning":
                phase = .observing; title = "Слежу за дорогой"; detail = "Предупрежу вибрацией"
            case "limited", "unavailable":
                phase = .limited; title = "Камера не видит лицо"; detail = "Поправьте телефон или сядьте ровнее"
            default:
                phase = .idle; title = "Готово"; detail = "Начните поездку на iPhone"
            }
        }
    }

    // MARK: - Outgoing

    private func envelope(_ type: String) -> [String: Any] {
        var message: [String: Any] = ["v": 1, "type": type, "message_id": UUID().uuidString,
                                      "receiver_epoch": receiverEpoch]
        if let connection = gate.connectionID { message["connection_id"] = connection }
        if let session = gate.sessionID { message["session_id"] = session }
        return message
    }

    private func send(_ type: String, _ fields: [String: Any] = [:]) {
        guard wc.activationState == .activated, wc.isReachable, gate.connectionID != nil else { return }
        let message = envelope(type).merging(fields) { _, new in new }
        wc.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    /// Tells the phone whether screen-off alerts can work right now.
    private func sendState() {
        send("watch_state", ["background": workout.state.rawValue])
    }

    private func ready() {
        DispatchQueue.main.async {
            self.gate.disconnect()
            self.receiverEpoch = UUID().uuidString
            self.refresh()
            guard self.wc.isReachable else { return }
            self.wc.sendMessage(["v": 1, "type": "ready", "message_id": UUID().uuidString,
                                 "receiver_epoch": self.receiverEpoch], replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        ready()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        if !session.isReachable {
            // Without the phone nothing can stop or confirm an alarm.
            DispatchQueue.main.async { if self.loop.kind == .event { self.loop.stop(); self.alarmTarget = nil } }
        }
        ready()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        // Context is display-only. It cannot authorize replay of a queued alert.
        DispatchQueue.main.async {
            guard !session.isReachable || self.gate.connectionID == nil else { return }
            self.recommendation = applicationContext["recommendation"] as? String
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { handle(message, reply: nil) }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        handle(message, reply: replyHandler)
    }

    private func handle(_ message: [String: Any], reply: (([String: Any]) -> Void)?) {
        DispatchQueue.main.async {
            if message["type"] as? String == "hello" {
                self.gate.disconnect()
                self.receiverEpoch = UUID().uuidString
                var response: [String: Any] = ["v": 1, "type": "ready", "message_id": UUID().uuidString,
                                               "receiver_epoch": self.receiverEpoch,
                                               "background": self.workout.state.rawValue]
                response["connection_id"] = message["connection_id"]
                self.respond(response, reply: reply)
                return
            }
            guard message["receiver_epoch"] as? String == self.receiverEpoch else { return }
            let received = self.nowMs()
            // Check and haptic request are serialized; cancellation is effective once received.
            let decision = self.gate.receive(message, nowMs: received)
            var response: [String: Any] = ["v": 1, "type": "ack", "message_id": UUID().uuidString,
                "ack_message_id": message["message_id"] ?? "", "status": decision.status,
                "haptic_requested": false, "receiver_epoch": self.receiverEpoch,
                "watch_received_ms": received]
            for key in ["connection_id", "session_id", "trip_id"] { response[key] = message[key] }
            let type = message["type"] as? String
            if decision.status == "pong" {
                response["type"] = "pong"
                response["phone_sent_us"] = message["phone_sent_us"]
                response["watch_sent_ms"] = self.nowMs()
            } else if decision.vibrate {
                // No deferred work between the final TTL check and the haptic request.
                self.play(.normal)
                response["haptic_requested"] = true
                response["watch_haptic_ms"] = self.nowMs()
                let event = message["event_id"] as? String
                let target = event ?? message["recommendation_id"] as? String ?? ""
                self.alarmTarget = target
                self.alarmReason = [message["reason"] as? String, message["recommendation"] as? String]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                self.loop.start(target: target, kind: event != nil ? .event : .notice, nowMs: received)
            } else if type == "snapshot", decision.status == "state_only" {
                self.applySnapshot(message)
            } else if type == "cancel" {
                self.loop.cancel(targetIDs: message["target_ids"] as? [String] ?? [],
                                 all: message["all"] as? Bool == true)
            }
            self.lastDelivery = decision.status
            self.refresh()
            self.respond(response, reply: reply)
        }
    }

    private func applySnapshot(_ message: [String: Any]) {
        level = message["level"] as? String ?? (message["session_id"] == nil ? "idle" : "observing")
        activeIDs = message["active_event_ids"] as? [String] ?? []
        loop.snapshot(activeIDs: activeIDs)
        driveMinutes = (message["drive_min"] as? NSNumber)?.intValue
        recommendation = (message["recommendation"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if tripActive {
            // Started here when the app is in front; the phone also launches it at trip start.
            if workout.state == .off || workout.state == .failed { workout.start() }
        } else if workout.state != .off {
            workout.stop()
        }
    }

    private func respond(_ response: [String: Any], reply: (([String: Any]) -> Void)?) {
        if let reply { reply(response) }
        else if wc.isReachable { wc.sendMessage(response, replyHandler: nil, errorHandler: nil) }
    }
}
