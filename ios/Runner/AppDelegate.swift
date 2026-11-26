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
        if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NSControlFaceTracking") {
            FaceTrackingPlugin.register(with: registrar)
        }
    }
    /// The watch app asks for the workout permission; watchOS may hand the sheet
    /// to the paired iPhone. Without this the request silently goes nowhere.
    override func applicationShouldRequestHealthAuthorization(_ application: UIApplication) {
        super.applicationShouldRequestHealthAuthorization(application)
        HKHealthStore().handleAuthorizationForExtension { _, _ in }
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
    private let speech = LabSpeech()
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
        // The trip speaks its calibration prompts on the same audio session
        // the alarm takes and releases: the next phrase re-activates it.
        alerts.onSessionChanged = { [weak self] in self?.speech.sessionTaken() }
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
        case "speech.say":
            speech.say(args["text"] as? String ?? ""); result(["status": "ok"])
        case "speech.stop": speech.stop(); result(["status": "stopped"])
        case "speech.voices": result(speech.voices())
        case "device.info":
            var system = utsname(); uname(&system)
            let model = withUnsafeBytes(of: &system.machine) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            result(["model": model, "os": "iOS \(UIDevice.current.systemVersion)"])
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
        case "wearable.prepare":
            // Trip start: launch the watch app into its background (workout) session,
            // so alerts keep working after the watch screen turns off.
            guard transport == "watch_connectivity", let watch, watch.activationState == .activated,
                  watch.isPaired, watch.isWatchAppInstalled, HKHealthStore.isHealthDataAvailable() else {
                result(["status": "unavailable"]); return
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other
            configuration.locationType = .unknown
            health.startWatchApp(with: configuration) { success, error in
                self.finish(result, success ? ["status": "launched"]
                    : ["status": "error", "reason": error?.localizedDescription ?? "startWatchApp failed"])
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

/// Voice prompts of the lab scenarios and the trip calibration (the best
/// installed Russian system voice, see `bestRussianVoice`).
/// The audio session is activated once, on the first phrase, and kept active
/// until `speech.stop` (scenario cancelled or lab closed). Activating and
/// deactivating it around every phrase stalled the camera for ~0.5 s after
/// each prompt (bench-v1 20261126-001948: 67 gaps of 500–600 ms in both
/// engines, all right after speech, none in silence). `.mixWithOthers`
/// instead of `.duckOthers`, so keeping the session does not leave other
/// audio ducked.
final class LabSpeech: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var active = false
    override init() {
        super.init()
        synthesizer.delegate = self
        // A voice downloaded while the app runs is picked up on the next phrase.
        voiceObserver = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.cachedVoice = nil }
    }
    func say(_ text: String) {
        guard !text.isEmpty else { return }
        if !active {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            active = (try? session.setActive(true)) != nil
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // Calm, unhurried delivery: a little slower than the system default
        // (it was 1.1x, which made the compact voice sound clipped and
        // nervous) and a slightly lower, warmer pitch. Pitch stays near 1.0:
        // larger shifts make the synthesis sound artificial.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 0.95
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }
    /// The nicest Russian voice installed on the phone, chosen on the first
    /// phrase and again after the installed voices change. The
    /// system default ru-RU voice is the compact (low quality) Milena; the
    /// enhanced or premium voices sound far more natural but must be
    /// downloaded by the user (Settings → Accessibility → Spoken Content →
    /// Voices → Russian). Order: quality (premium > enhanced > default),
    /// then a female voice, then Milena before Katya before others. Novelty
    /// and Personal Voice voices are skipped. Falls back to the system
    /// ru-RU voice when nothing else is installed.
    private var cachedVoice: AVSpeechSynthesisVoice?
    private var voiceObserver: NSObjectProtocol?
    private var voice: AVSpeechSynthesisVoice? {
        if cachedVoice == nil { cachedVoice = Self.bestRussianVoice() }
        return cachedVoice
    }
    static func russianVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { voice in
            guard voice.language.lowercased().hasPrefix("ru") else { return false }
            if #available(iOS 17.0, *) {
                if voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice) {
                    return false
                }
            }
            return true
        }
    }
    static func bestRussianVoice() -> AVSpeechSynthesisVoice? {
        func quality(_ voice: AVSpeechSynthesisVoice) -> Int {
            if #available(iOS 16.0, *), voice.quality == .premium { return 3 }
            return voice.quality == .enhanced ? 2 : 1
        }
        func name(_ voice: AVSpeechSynthesisVoice) -> Int {
            let lower = voice.name.lowercased()
            if lower.hasPrefix("milena") { return 2 }
            if lower.hasPrefix("katya") { return 1 }
            return 0
        }
        let best = russianVoices().max { a, b in
            let ka = (quality(a), a.gender == .female ? 1 : 0, name(a))
            let kb = (quality(b), b.gender == .female ? 1 : 0, name(b))
            return ka < kb
        }
        return best ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }
    /// Installed Russian voices for diagnostics (`speech.voices`).
    func voices() -> [String: Any] {
        func quality(_ voice: AVSpeechSynthesisVoice) -> String {
            if #available(iOS 16.0, *), voice.quality == .premium { return "premium" }
            return voice.quality == .enhanced ? "enhanced" : "default"
        }
        let list = Self.russianVoices().map { v -> [String: Any] in
            ["id": v.identifier, "name": v.name, "quality": quality(v),
             "gender": v.gender == .female ? "female" : v.gender == .male ? "male" : "unspecified"]
        }
        return ["selected": voice?.identifier ?? "", "voices": list]
    }
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        guard active else { return }
        active = false
        // Only the lab calls stop; it never runs together with a trip, so no
        // alarm is playing here.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    /// The phone alarm changed the shared audio session (category or active
    /// state); the next phrase sets it up again.
    func sessionTaken() { active = false }
}

final class PhoneAlert {
    var onSessionChanged: (() -> Void)?
    private var player: AVAudioPlayer?
    private var vibration: Timer?
    private var testStop: DispatchWorkItem?
    func start(volume: Float, vibrate: Bool, test: Bool) throws {
        guard volume.isFinite && volume >= 0 && volume <= 1 else { throw NSError(domain: "NSControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Volume must be in 0…1"]) }
        stop()
        let session = AVAudioSession.sharedInstance()
        onSessionChanged?()
        try session.setCategory(.playback, mode: .default, options: [.duckOthers]); try session.setActive(true)
        let audio = try AVAudioPlayer(data: Self.wave())
        // The alarm starts at once, softer, and rises to its volume over
        // 1.5 s instead of breaking in at full volume (user, 25.11).
        audio.numberOfLoops = -1; audio.volume = test ? volume : volume * 0.35; audio.prepareToPlay()
        guard audio.play() else { throw NSError(domain: "NSControl", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio playback could not start"]) }
        if !test { audio.setVolume(volume, fadeDuration: 1.5) }
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
        let current = player
        player = nil
        guard let fading = current, fading.isPlaying else {
            current?.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            onSessionChanged?()
            return
        }
        // Fades out over 0.4 s instead of breaking off. A new alarm started
        // meanwhile keeps the audio session.
        fading.setVolume(0, fadeDuration: 0.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            fading.stop()
            guard let self = self, self.player == nil else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            self.onSessionChanged?()
        }
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
