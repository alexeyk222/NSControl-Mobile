import Foundation
import UIKit
#if canImport(ConnectIQ)
import ConnectIQ
#endif

/// Garmin Connect IQ transport for iPhone. Device selection goes through the
/// Garmin Connect app, which returns the chosen watches via the
/// `nscontrol-ciq` URL scheme. Messages use the same v1 protocol as Android.
/// A successful send means the SDK handed the message over, not that the watch
/// vibrated: the watch ACK is reported separately through `wearable_message`.
final class GarminBridge: NSObject {
    static let appId = "936fbf76-41ce-4a3a-9225-61ead363a448"
    static let urlScheme = "nscontrol-ciq"
    private static let storedDevicesKey = "nscontrol.garmin.devices"
    private let emit: ([String: Any]) -> Void
    private(set) var reason = "Выберите часы Garmin в Garmin Connect"

    init(emit: @escaping ([String: Any]) -> Void) {
        self.emit = emit
        super.init()
        setUp()
    }

#if canImport(ConnectIQ)
    private var devices: [IQDevice] = []
    private var device: IQDevice?
    private var app: IQApp?
    private var appInstalled = false
    private var sdk: ConnectIQ { ConnectIQ.sharedInstance() }

    var available: Bool { true }

    private func setUp() {
        sdk.initialize(withUrlScheme: Self.urlScheme, uiOverrideDelegate: nil)
        if let data = UserDefaults.standard.data(forKey: Self.storedDevicesKey),
           let stored = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, IQDevice.self], from: data) as? [IQDevice] {
            devices = stored
        }
    }

    /// Opens Garmin Connect for the user to choose watches.
    func selectDevices() -> [String: Any] {
        sdk.showDeviceSelection()
        reason = "Выберите часы в Garmin Connect и вернитесь в NSControl"
        return ["status": "selection_requested", "reason": reason, "transport": "garmin"]
    }

    /// Returns true when the URL was the Garmin Connect selection response.
    func handle(url: URL) -> Bool {
        guard url.scheme == Self.urlScheme else { return false }
        let selected = (sdk.parseDeviceSelectionResponse(from: url) as? [IQDevice]) ?? []
        devices = selected
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: selected, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Self.storedDevicesKey)
        }
        reason = selected.isEmpty ? "Часы Garmin не выбраны" : "Выбрано часов Garmin: \(selected.count)"
        if selected.count == 1 { connect(id: "garmin:\(selected[0].uuid.uuidString)") { _ in } }
        emit(["type": "wearable_devices", "devices": deviceList()])
        notifyStatus()
        return true
    }

    func deviceList() -> [[String: Any]] {
        devices.map { d in
            ["id": "garmin:\(d.uuid.uuidString)", "name": d.friendlyName ?? d.modelName ?? "Garmin",
             "connected": sdk.getDeviceStatus(d) == .connected, "transport": "garmin"]
        }
    }

    func status() -> [String: Any] {
        let connected = device.map { sdk.getDeviceStatus($0) == .connected } ?? false
        return ["status": device == nil ? "disconnected" : connected && appInstalled ? "connected" : connected ? "app_not_installed" : "disconnected",
                "connected": connected && appInstalled, "device_id": device.map { "garmin:\($0.uuid.uuidString)" } as Any,
                "reason": reason, "transport": "garmin", "foreground_verified": false]
    }

    private func notifyStatus() { emit(["type": "wearable_status", "status": status()]) }

    func connect(id: String?, complete: @escaping ([String: Any]) -> Void) {
        let selected = id.flatMap { wanted in devices.first { "garmin:\($0.uuid.uuidString)" == wanted } }
            ?? (devices.count == 1 ? devices[0] : nil)
        guard let selected else {
            complete(["status": "selection_required", "reason": "Выберите часы Garmin", "devices": deviceList()]); return
        }
        sdk.unregister(forAllDeviceEvents: self)
        sdk.unregister(forAllAppMessages: self)
        device = selected; appInstalled = false
        app = IQApp(uuid: UUID(uuidString: Self.appId), store: UUID(), device: selected)
        reason = "Проверка приложения NSControl на часах"
        sdk.register(forDeviceEvents: selected, delegate: self)
        var finished = false
        let finish: ([String: Any]) -> Void = { value in
            DispatchQueue.main.async { if !finished { finished = true; complete(value) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            finish(["status": "error", "reason": "Garmin не ответил за 8 с. Откройте Garmin Connect и проверьте связь."])
        }
        guard let app else { finish(["status": "error", "reason": "Некорректный UUID приложения"]); return }
        sdk.getAppStatus(app) { [weak self] appStatus in
            guard let self, self.device?.uuid == selected.uuid else { return }
            if appStatus?.isInstalled == true {
                self.appInstalled = true
                self.sdk.register(forAppMessages: app, delegate: self)
                self.reason = "Откройте NSControl на часах для обмена"
                self.notifyStatus(); finish(self.status())
            } else {
                self.reason = "Приложение NSControl не установлено на часах"
                self.notifyStatus(); finish(["status": "app_not_installed", "reason": self.reason])
            }
        }
    }

    func send(_ message: [String: Any], complete: @escaping ([String: Any]) -> Void) {
        guard let device, let app, appInstalled, sdk.getDeviceStatus(device) == .connected else {
            complete(["status": "disconnected", "accepted": false]); return
        }
        var finished = false
        let finish: ([String: Any]) -> Void = { value in
            DispatchQueue.main.async { if !finished { finished = true; complete(value) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(["status": "timeout", "accepted": false]) }
        var wire = message
        // The SDK may narrow doubles to 32-bit floats; Monkey C parses text exactly.
        if let offset = wire["watch_minus_phone_lower_ms"] as? NSNumber {
            wire["watch_minus_phone_lower_ms"] = NSDecimalNumber(value: offset.doubleValue).stringValue
        }
        // Transient: a stale alert must never be queued for later delivery.
        sdk.sendMessage(wire, to: app, progress: nil, completion: { result in
            finish(["status": result == .success ? "sent" : "error_\(result.rawValue)",
                    "accepted": result == .success, "app_acknowledged": false, "physical_vibration_verified": false])
        }, isTransient: true)
    }
#else
    var available: Bool { false }
    private func setUp() { reason = "Сборка без Garmin Connect IQ SDK" }
    func selectDevices() -> [String: Any] { ["status": "unavailable", "reason": reason, "transport": "garmin"] }
    func handle(url: URL) -> Bool { false }
    func deviceList() -> [[String: Any]] { [] }
    func status() -> [String: Any] { ["status": "unavailable", "connected": false, "reason": reason, "transport": "garmin"] }
    func connect(id: String?, complete: @escaping ([String: Any]) -> Void) { complete(status()) }
    func send(_ message: [String: Any], complete: @escaping ([String: Any]) -> Void) {
        complete(["status": "unavailable", "accepted": false])
    }
#endif
}

#if canImport(ConnectIQ)
extension GarminBridge: IQDeviceEventDelegate, IQAppMessageDelegate {
    func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {
        guard device.uuid == self.device?.uuid else { return }
        reason = status == .connected ? "Часы Garmin на связи" : "Часы Garmin не на связи"
        notifyStatus()
    }

    func receivedMessage(_ message: Any!, from app: IQApp!) {
        guard let dictionary = message as? [String: Any] else { return }
        emit(["type": "wearable_message", "message": dictionary])
    }
}
#endif
