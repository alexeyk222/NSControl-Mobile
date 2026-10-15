import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct NSControlWatchApp: App {
    @StateObject private var link = WatchLink()
    var body: some Scene {
        WindowGroup {
          ScrollView {
            VStack(spacing: 10) {
                Text("NSControl").font(.headline)
                Text(link.reason).font(.body).multilineTextAlignment(.center)
                Text(link.status).font(.caption2).foregroundStyle(.secondary)
                Text("1.0 • 1").font(.caption2).foregroundStyle(.secondary)
            }.padding()
          }
        }
    }
}

final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var reason = "Откройте NSControl на телефоне"
    @Published var status = "Нет связи"
    private let gate = AlertGate()
    private let session = WCSession.default
    private var receiverEpoch = UUID().uuidString
    override init() {
        super.init()
        session.delegate = self
        session.activate()
    }
    private func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
    private func label(_ status: String) -> String {
        switch status {
        case "synchronized": return "Связь установлена"
        case "accepted": return "Сигнал запрошен"
        case "state_only": return "Актуальное состояние"
        case "expired": return "Срок сигнала истёк"
        case "duplicate": return "Уже принято"
        case "cancelled": return "Отменено"
        default: return "Ожидается синхронизация"
        }
    }
    private func ready() {
        DispatchQueue.main.async {
            self.gate.disconnect()
            self.receiverEpoch = UUID().uuidString
            guard self.session.isReachable else { return }
            self.session.sendMessage(["v": 1, "type": "ready", "message_id": UUID().uuidString,
                                      "receiver_epoch": self.receiverEpoch], replyHandler: nil, errorHandler: nil)
        }
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.status = error?.localizedDescription ?? "Ожидается синхронизация" }
        ready()
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.status = session.isReachable ? "Ожидается синхронизация" : "Нет связи" }
        ready()
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        // Context is display-only. It cannot authorize replay of a queued alert.
        DispatchQueue.main.async {
            // Live protocol state wins over an opportunistically delivered older context.
            guard !session.isReachable || self.gate.connectionID == nil else { return }
            self.reason = applicationContext["recommendation"] as? String ?? applicationContext["reason"] as? String ?? "Нет активных предупреждений"
        }
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { handle(message, reply: nil) }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handle(message, reply: replyHandler)
    }
    private func handle(_ message: [String: Any], reply: (([String: Any]) -> Void)?) {
        DispatchQueue.main.async {
            if message["type"] as? String == "hello" {
                self.gate.disconnect()
                self.receiverEpoch = UUID().uuidString
                var response: [String: Any] = ["v": 1, "type": "ready", "message_id": UUID().uuidString,
                                               "receiver_epoch": self.receiverEpoch]
                response["connection_id"] = message["connection_id"]
                if let reply { reply(response) }
                else if self.session.isReachable { self.session.sendMessage(response, replyHandler: nil, errorHandler: nil) }
                return
            }
            guard message["receiver_epoch"] as? String == self.receiverEpoch else { return }
            let received = self.nowMs()
            // Check and haptic request are serialized; cancellation is effective once received.
            let decision = self.gate.receive(message, nowMs: received)
            var response: [String: Any] = ["v": 1, "type": "ack", "message_id": UUID().uuidString,
                "ack_message_id": message["message_id"] ?? "", "status": decision.status,
                "haptic_requested": false, "receiver_epoch": self.receiverEpoch]
            for key in ["connection_id", "session_id", "trip_id"] { response[key] = message[key] }
            if decision.status == "pong" {
                response["type"] = "pong"
                response["phone_sent_us"] = message["phone_sent_us"]
                response["watch_received_ms"] = received
                response["watch_sent_ms"] = self.nowMs()
            } else if decision.vibrate {
                // No deferred work between the final TTL check and the haptic request.
                WKInterfaceDevice.current().play(.notification)
                response["haptic_requested"] = true
            }
            DispatchQueue.main.async {
                self.status = self.label(decision.status)
                if decision.vibrate {
                    self.reason = [message["reason"] as? String, message["recommendation"] as? String]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                } else if message["type"] as? String == "snapshot" {
                    self.reason = message["reason"] as? String ?? message["recommendation"] as? String ?? "Нет активных предупреждений"
                }
            }
            if let reply { reply(response) }
            else if self.session.isReachable { self.session.sendMessage(response, replyHandler: nil, errorHandler: nil) }
        }
    }
}
