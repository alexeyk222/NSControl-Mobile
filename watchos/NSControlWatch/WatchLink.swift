import Foundation
import HealthKit
import WatchConnectivity
import WatchKit

/// Watch screens, docs/ux/watch.md §3. Exactly one at a time.
enum WatchScreen: Equatable {
    case noLink                                   // W-01
    case ready                                    // W-02
    case watching                                 // W-03
    case unseen(headOnly: Bool)                   // W-04
    case paused                                   // W-05
    case alarm(title: String, reason: String)     // W-06
    case advice(title: String, reason: String)    // W-07
    case test                                     // W-08
    case summary(minutes: Int, alarms: Int)       // W-09
}

/// Live link to the iPhone app. One instance for the app's lifetime, so the
/// workout launch from the phone (`handle(_:)`) and the UI share the state.
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchLink()

    @Published private(set) var screen: WatchScreen = .noLink
    @Published private(set) var driveMinutes: Int?
    @Published private(set) var background: BackgroundSession.State = .off

    let workout = BackgroundSession()
    private let gate = AlertGate()
    private let loop = AlarmLoop()
    private let watchdog = LinkWatchdog()
    private var tally = TripTally()
    private let wc = WCSession.default
    private var receiverEpoch = UUID().uuidString
    private var level = "idle"
    /// Screens that stay until a tap (W-06 while the alarm runs, W-07, W-08, W-09).
    private var overlay: WatchScreen?
    private var overlayUntilMs: Double = 0
    /// Camera event behind the current W-06; nil for a mild "На дорогу!".
    private var alarmTarget: String?
    private var unreachableSinceMs: Double?
    private var timer: Timer?

    /// Phone app gone for this long during a trip: end the background session to save battery.
    static let abandonAfterMs: Double = 10 * 60_000
    /// W-07/W-08/W-09 close by themselves after this long.
    static let overlayMs: Double = 60_000

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

    /// Tap anywhere on W-06. Stops the local loop at once; the phone acknowledges
    /// the event, stops its sound and answers with `cancel`.
    func acknowledgeAlarm() {
        if let target = alarmTarget { send("user_ack", ["event_ids": [target]]) }
        loop.stop()
        alarmTarget = nil
        overlay = nil
        refresh()
    }

    /// Tap on W-07, W-08 or W-09.
    func dismiss() {
        if !loop.isEvent { loop.stop() }
        overlay = nil
        refresh()
    }

    /// Local vibration check, no phone involved.
    func testVibration() {
        play(.alarm)
        show(.test)
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
        let type: WKHapticType
        switch pulse {
        case .alarm: type = .notification
        case .alarmRepeat: type = .retry
        case .soft: type = .directionUp
        }
        WKInterfaceDevice.current().play(type)
    }

    private func tick() {
        let now = nowMs()
        if let pulse = loop.tick(nowMs: now) { play(pulse) }
        // The event alarm screen lives exactly as long as its loop.
        if alarmTarget != nil, !loop.isEvent { overlay = nil; alarmTarget = nil; refresh() }
        if overlay != nil, alarmTarget == nil, now > overlayUntilMs { overlay = nil; refresh() }
        if watchdog.update(tripActive: tripActive, reachable: wc.isReachable, nowMs: now) {
            WKInterfaceDevice.current().play(.failure)
            refresh()
        }
        if tripActive, !wc.isReachable {
            let since = unreachableSinceMs ?? now
            unreachableSinceMs = since
            if now - since >= Self.abandonAfterMs { setLevel("idle") }
        } else {
            unreachableSinceMs = nil
        }
    }

    // MARK: - UI state

    private func show(_ screen: WatchScreen) {
        overlay = screen
        overlayUntilMs = nowMs() + Self.overlayMs
        refresh()
    }

    private func refresh() {
        if let overlay { screen = overlay; return }
        let reachable = wc.activationState == .activated && wc.isReachable
        guard reachable else { screen = .noLink; return }
        switch level {
        case "observing", "warning": screen = .watching
        case "limited", "unavailable": screen = .unseen(headOnly: false)
        case "head_only": screen = .unseen(headOnly: true)
        case "paused": screen = .paused
        default: screen = .ready
        }
    }

    private var unseenShown: Bool {
        if case .unseen = screen { return true }
        return false
    }

    private func setLevel(_ value: String) {
        let wasUnseen = unseenShown
        level = value
        if let summary = tally.update(tripActive: tripActive, nowMs: nowMs()) {
            show(.summary(minutes: summary.minutes, alarms: summary.alarms))
        }
        if tripActive {
            // Started here when the app is in front; the phone also launches it at trip start.
            if workout.state == .off || workout.state == .failed { workout.start() }
        } else if workout.state != .off {
            workout.stop()
        }
        refresh()
        // "Внимание" (§4): one click when the phone stops seeing the driver.
        if unseenShown, !wasUnseen { WKInterfaceDevice.current().play(.click) }
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
                                 "receiver_epoch": self.receiverEpoch,
                                 "background": self.workout.state.rawValue],
                                replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        ready()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        if !session.isReachable {
            // Without the phone nothing can stop or confirm an alarm.
            DispatchQueue.main.async { if self.loop.isEvent { self.loop.stop() } }
        }
        ready()
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
                let signal = AlertSignal(message)
                self.play(signal.firstPulse)
                response["haptic_requested"] = true
                response["watch_haptic_ms"] = self.nowMs()
                if signal.loop == .event {
                    self.loop.start(target: signal.target, kind: signal.loop, nowMs: received)
                    self.alarmTarget = signal.target
                    self.tally.alarm()
                    self.show(signal.screen)
                } else if !self.loop.isEvent {
                    // Advice or a test never hides a running camera alarm.
                    self.loop.start(target: signal.target, kind: signal.loop, nowMs: received)
                    self.show(signal.screen)
                }
            } else if type == "snapshot", decision.status == "state_only" {
                self.loop.snapshot(activeIDs: message["active_event_ids"] as? [String] ?? [])
                self.driveMinutes = (message["drive_min"] as? NSNumber)?.intValue
                self.setLevel(message["level"] as? String ?? (message["session_id"] == nil ? "idle" : "observing"))
            } else if type == "cancel" {
                self.loop.cancel(targetIDs: message["target_ids"] as? [String] ?? [],
                                 all: message["all"] as? Bool == true)
            }
            self.refresh()
            self.respond(response, reply: reply)
        }
    }

    private func respond(_ response: [String: Any], reply: (([String: Any]) -> Void)?) {
        if let reply { reply(response) }
        else if wc.isReachable { wc.sendMessage(response, replyHandler: nil, errorHandler: nil) }
    }
}

/// How an accepted `alert` is shown and felt. `alarm` comes from the phone:
/// eyes | head | road | advice | stop | test (docs/ux/watch.md §3–4).
struct AlertSignal {
    let target: String
    let screen: WatchScreen
    let firstPulse: AlarmPulse
    let loop: AlarmLoop.Kind

    init(_ message: [String: Any]) {
        let event = message["event_id"] as? String
        target = event ?? message["recommendation_id"] as? String ?? ""
        let reason = message["reason"] as? String ?? ""
        let kind = message["alarm"] as? String ?? (event != nil ? "eyes" : "advice")
        switch kind {
        case "test":
            screen = .test; firstPulse = .alarm; loop = .notice(pulses: 1, pulse: .alarm)
        case "road":
            screen = .alarm(title: "На дорогу!", reason: reason)
            firstPulse = .soft; loop = .notice(pulses: 2, pulse: .soft)
        case "advice", "stop":
            screen = .advice(title: kind == "stop" ? "Найдите остановку" : "Пора на перерыв", reason: reason)
            firstPulse = .soft; loop = .notice(pulses: 1, pulse: .soft)
        default:
            screen = .alarm(title: kind == "head" ? "Голову!" : "Глаза!", reason: reason)
            firstPulse = .alarm; loop = event != nil ? .event : .notice(pulses: 1, pulse: .alarm)
        }
    }
}
