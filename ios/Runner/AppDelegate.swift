import Flutter
import UIKit
import HealthKit
import AVFoundation
import AudioToolbox
import WatchConnectivity

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    static private(set) var platform: PlatformBridge?
    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
        Self.platform = PlatformBridge(messenger: engineBridge.applicationRegistrar.messenger())
    }
    override func application(_ app: UIApplication, open url: URL,
                              options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if Self.platform?.handle(url: url) == true { return true }
        return super.application(app, open: url, options: options)
    }
}

/// Uses only on-device APIs. HealthKit read authorization is intentionally reported as unknown.
final class PlatformBridge: NSObject, FlutterStreamHandler, WCSessionDelegate {
    private let health = HKHealthStore()
    private let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    private let alerts = PhoneAlert()
    private var sink: FlutterEventSink?
    private var channel: FlutterMethodChannel!
    private var eventChannel: FlutterEventChannel!
    private let iso = ISO8601DateFormatter()
    private var observers: [NSObjectProtocol] = []
    private var watch: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private var garmin: GarminBridge!
    private static let transportKey = "nscontrol.wearable.transport"
    /// "garmin" or "watch_connectivity"; Apple Watch stays the default when paired.
    private var transport: String {
        get { UserDefaults.standard.string(forKey: Self.transportKey) ?? "watch_connectivity" }
        set { UserDefaults.standard.set(newValue, forKey: Self.transportKey) }
    }

    init(messenger: FlutterBinaryMessenger) {
        super.init()
        channel = FlutterMethodChannel(name: "nscontrol/platform", binaryMessenger: messenger)
        eventChannel = FlutterEventChannel(name: "nscontrol/events", binaryMessenger: messenger)
        eventChannel.setStreamHandler(self)
        channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
        garmin = GarminBridge { [weak self] event in self?.emit(event) }
        watch?.delegate = self; watch?.activate()
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.alerts.stop(); UIApplication.shared.isIdleTimerDisabled = false
            self?.emit(["type": "platform_interruption", "reason": "inactive"])
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
            let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            if raw == AVAudioSession.InterruptionType.ended.rawValue {
                if UIApplication.shared.applicationState == .active { self?.emit(["type": "platform_resumed"]) }
            } else {
                self?.alerts.stop(); UIApplication.shared.isIdleTimerDisabled = false
                self?.emit(["type": "platform_interruption", "reason": "audio_interruption"])
            }
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func handle(url: URL) -> Bool {
        guard garmin.handle(url: url) else { return false }
        transport = "garmin"
        return true
    }
    private func emit(_ event: [String: Any]) { DispatchQueue.main.async { self.sink?(event) } }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events; events(["type": "wearable_status", "status": currentWearableStatus()]); return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
    private func finish(_ result: @escaping FlutterResult, _ value: Any?) { DispatchQueue.main.async { result(value) } }
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "app.openSettings":
            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                result(["status": "error", "reason": "Settings URL unavailable"]); return
            }
            UIApplication.shared.open(url, options: [:]) { opened in
                result(["status": opened ? "opened" : "error"])
            }
        case "alert.start", "alert.test":
            do {
                try alerts.start(volume: (args["volume"] as? NSNumber)?.floatValue ?? 1,
                                 vibrate: args["vibrate"] as? Bool ?? true, test: call.method == "alert.test")
                result(["status": "requested", "physical_output_verified": false])
            } catch { alerts.stop(); result(["status": "error", "reason": error.localizedDescription]) }
        case "alert.stop": alerts.stop(); result(["status": "stopped"])
        case "screen.keepAwake": UIApplication.shared.isIdleTimerDisabled = args["enabled"] as? Bool ?? false; result(nil)
        case "sleep.status": sleepStatus(result)
        case "sleep.authorize":
            guard HKHealthStore.isHealthDataAvailable() else { result(["status": "unavailable"]); return }
            health.requestAuthorization(toShare: [], read: [sleepType]) { completed, error in
                if let error { self.finish(result, ["status": "error", "reason": error.localizedDescription]) }
                else { self.finish(result, ["status": completed ? "available" : "permission_required", "read_authorization": "unknown",
                    "limitation": "HealthKit does not disclose read permission. An empty result may mean no records or denied access."]) }
            }
        case "sleep.read": readSleep(args, result: result)
        case "wearable.status": result(currentWearableStatus())
        case "wearable.devices": result(wearableDevices())
        case "wearable.connect":
            let id = args["deviceId"] as? String
            if id == "garmin:select" { result(garmin.selectDevices()); return }
            if id?.hasPrefix("garmin:") == true || (id == nil && transport == "garmin") {
                transport = "garmin"
                garmin.connect(id: id) { value in self.finish(result, value) }
            } else {
                transport = "watch_connectivity"; watch?.activate(); result(wearableStatus())
            }
        case "wearable.send":
            guard let message = args["message"] as? [String: Any] else { result(["status": "error", "reason": "Missing message"]); return }
            if transport == "garmin" {
                garmin.send(propertyList(message) as? [String: Any] ?? [:]) { value in self.finish(result, value) }
            } else {
                sendToWatch(message, result: result)
            }
        default: result(FlutterMethodNotImplemented)
        }
    }
    private func sleepStatus(_ result: @escaping FlutterResult) {
        guard HKHealthStore.isHealthDataAvailable() else { result(["status": "unavailable"]); return }
        health.getRequestStatusForAuthorization(toShare: [], read: [sleepType]) { status, error in
            self.finish(result, ["status": error == nil ? (status == .shouldRequest ? "permission_required" : "available") : "error", "provider": "healthkit",
                                 "read_authorization": "unknown", "source": "HealthKit",
                                 "reason": error?.localizedDescription ?? "Read permission is private to the user"])
        }
    }
    private func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: text) ?? iso.date(from: text)
    }
    private func readSleep(_ args: [String: Any], result: @escaping FlutterResult) {
        guard HKHealthStore.isHealthDataAvailable() else { result(["status": "unavailable", "records": []]); return }
        guard let start = parseDate(args["from"]), let end = parseDate(args["to"]), start < end else {
            result(["status": "error", "reason": "Invalid sleep window", "records": []]); return
        }
        let readAt = Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: min(end, readAt), options: [])
        let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
            if let error {
                let ns = error as NSError
                self.finish(result, ["status": ns.domain == HKErrorDomain && ns.code == HKError.Code.errorAuthorizationDenied.rawValue ? "permission_required" : "error",
                                     "reason": error.localizedDescription, "records": []]); return
            }
            let rows: [[String: Any]] = (samples as? [HKCategorySample] ?? []).compactMap { sample in
                guard sample.startDate < sample.endDate, sample.endDate <= readAt else { return nil }
                let stage: String
                if sample.value == HKCategoryValueSleepAnalysis.inBed.rawValue { stage = "inBed" }
                else if sample.value == HKCategoryValueSleepAnalysis.awake.rawValue { stage = "awake" }
                else if sample.value == HKCategoryValueSleepAnalysis.asleep.rawValue { stage = "asleep" }
                else if #available(iOS 16.0, *), HKCategoryValueSleepAnalysis.allAsleepValues.contains(HKCategoryValueSleepAnalysis(rawValue: sample.value) ?? .inBed) { stage = "asleep" }
                else { return nil }
                let product = sample.sourceRevision.productType ?? ""
                let device: [String: Any] = ["manufacturer": sample.device?.manufacturer ?? "", "model": sample.device?.model ?? "",
                    "name": sample.device?.name ?? "", "product_type": product,
                    "is_watch": product.hasPrefix("Watch") || sample.device?.model?.lowercased().contains("watch") == true]
                return ["id": sample.uuid.uuidString, "provider_id": sample.uuid.uuidString,
                    "source": sample.sourceRevision.source.bundleIdentifier, "source_name": sample.sourceRevision.source.name,
                    "start": self.iso.string(from: sample.startDate), "end": self.iso.string(from: sample.endDate),
                    "stage": stage, "device": device]
            }
            self.finish(result, ["status": "available", "provider": "healthkit", "records": rows, "read_at": self.iso.string(from: readAt),
                "snapshot_complete": !rows.isEmpty, "sources": Array(Set(rows.compactMap { $0["source"] as? String })),
                "query_from": self.iso.string(from: start), "query_to": self.iso.string(from: min(end, readAt)),
                "read_authorization": "unknown", "coverage_complete": false,
                "limitation": rows.isEmpty ? "No visible samples: HealthKit cannot distinguish no records from denied read access." : "Visible samples do not prove complete sleep coverage."])
        }
        health.execute(query)
    }
    private func currentWearableStatus() -> [String: Any] {
        transport == "garmin" ? garmin.status() : wearableStatus()
    }
    private func wearableDevices() -> [[String: Any]] {
        var list: [[String: Any]] = []
        if watch?.isPaired == true {
            list.append(["id": "apple_watch", "name": "Apple Watch", "connected": watch?.isReachable == true, "transport": "watch_connectivity"])
        }
        list += garmin.deviceList()
        if garmin.available {
            list.append(["id": "garmin:select", "name": "Выбрать часы Garmin…", "connected": false, "transport": "garmin", "action": true])
        }
        return list
    }
    private func wearableStatus() -> [String: Any] {
        guard let watch else { return ["status": "unavailable", "connected": false] }
        let active = watch.activationState == .activated
        return ["status": !active ? "connecting" : !watch.isPaired ? "unpaired" : !watch.isWatchAppInstalled ? "app_not_installed" : watch.isReachable ? "connected" : "disconnected",
            "connected": active && watch.isReachable, "paired": watch.isPaired,
            "app_installed": watch.isWatchAppInstalled, "transport": "watch_connectivity",
            "reason": watch.isReachable ? "Apple Watch на связи" : "Откройте NSControl на Apple Watch"]
    }
    private func propertyList(_ value: Any) -> Any? {
        if value is NSNull { return nil }
        if let dict = value as? [String: Any] { return dict.compactMapValues(propertyList) }
        if let list = value as? [Any] { return list.compactMap(propertyList) }
        return value
    }
    private func sendToWatch(_ raw: [String: Any], result: @escaping FlutterResult) {
        guard let watch, watch.activationState == .activated, watch.isPaired, watch.isWatchAppInstalled else {
            result(["status": "unavailable", "accepted": false]); return
        }
        let message = propertyList(raw) as? [String: Any] ?? [:]
        if message["type"] as? String == "snapshot" {
            do { try watch.updateApplicationContext(message) }
            catch { emit(["type": "wearable_status", "status": ["status": "error", "reason": error.localizedDescription]]) }
        }
        guard watch.isReachable else { result(["status": "disconnected", "accepted": false]); return }
        var finished = false
        let complete: ([String: Any]) -> Void = { value in
            DispatchQueue.main.async { if !finished { finished = true; result(value) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { complete(["status": "timeout", "accepted": false]) }
        watch.sendMessage(message, replyHandler: { response in
            self.emit(["type": "wearable_message", "message": response])
            complete(["status": "sent", "accepted": true, "app_acknowledged": true, "physical_vibration_verified": false])
        }, errorHandler: { error in complete(["status": "error", "accepted": false, "reason": error.localizedDescription]) })
    }
    // Apple Watch state is only reported while it is the selected transport.
    private func emitWatchStatus(_ status: [String: Any]) {
        if transport == "watch_connectivity" { emit(["type": "wearable_status", "status": status]) }
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        emitWatchStatus(wearableStatus())
    }
    func sessionReachabilityDidChange(_ session: WCSession) { emitWatchStatus(wearableStatus()) }
    func sessionWatchStateDidChange(_ session: WCSession) { emitWatchStatus(wearableStatus()) }
    func sessionDidBecomeInactive(_ session: WCSession) { emitWatchStatus(["status": "disconnected", "connected": false]) }
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { emit(["type": "wearable_message", "message": message]) }
}

final class PhoneAlert {
    private var player: AVAudioPlayer?
    private var vibration: Timer?
    private var testStop: DispatchWorkItem?
    func start(volume: Float, vibrate: Bool, test: Bool) throws {
        guard volume.isFinite && volume >= 0 && volume <= 1 else { throw NSError(domain: "NSControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Volume must be in 0…1"]) }
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.duckOthers]); try session.setActive(true)
        let audio = try AVAudioPlayer(data: Self.wave())
        audio.numberOfLoops = -1; audio.volume = volume; audio.prepareToPlay()
        guard audio.play() else { throw NSError(domain: "NSControl", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio playback could not start"]) }
        player = audio
        if vibrate {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            vibration = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
        }
        if test {
            let stop = DispatchWorkItem { [weak self] in self?.stop() }; testStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: stop)
        }
    }
    func stop() {
        testStop?.cancel(); testStop = nil; vibration?.invalidate(); vibration = nil
        player?.stop(); player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    private static func wave() -> Data {
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var x = value.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var x = value.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(36 + 88200); ascii("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(44100); u32(88200); u16(2); u16(16); ascii("data"); u32(88200)
        for index in 0..<44100 {
            let phase = index % 22050
            let taper = max(0, min(1, min(Double(phase) / 220, Double(13230 - phase) / 220)))
            let sample = phase < 13230 ? Int16(sin(2 * .pi * 880 * Double(index) / 44100) * 24000 * taper) : 0
            u16(UInt16(bitPattern: sample))
        }
        return data
    }
}
