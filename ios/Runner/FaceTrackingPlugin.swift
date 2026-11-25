import ARKit
import CoreImage
import CoreMedia
import Flutter
import UIKit
#if canImport(MLKitFaceDetection) && canImport(MLKitVision)
import MLKitFaceDetection
import MLKitVision
#endif

/// ARKit Face Tracking engine (TrueDepth) for the recognition lab.
///
/// The bridge sends raw geometry only: the face pose in camera space, the eye
/// transforms in face space, `lookAtPoint`, blendshapes and the gravity "up"
/// vector in camera space. All angle math and sign conventions live in Dart
/// (`lib/logic/arkit_geometry.dart`) so they are unit tested and can be
/// corrected without touching Swift.
///
/// Frames never leave memory (ФТ-01): `capturedImage` is only shown through a
/// Flutter texture and, in comparison mode, analysed by ML Kit on device.
///
/// Time: every timestamp is in microseconds of the system uptime clock, the
/// same clock as `ARFrame.timestamp` and `CACurrentMediaTime()`. Dart maps it
/// onto its own monotonic clock with the `clock` method.
final class FaceTrackingPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, ARSessionDelegate {
    static let methodChannelName = "nscontrol/arkit"
    static let eventChannelName = "nscontrol/arkit/events"
    /// The plugin outlives the registrar callback.
    private static var instance: FaceTrackingPlugin?

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = FaceTrackingPlugin(textures: registrar.textures())
        let channel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(plugin, channel: channel)
        let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: registrar.messenger())
        events.setStreamHandler(plugin)
        instance = plugin
    }

    private let textures: FlutterTextureRegistry
    private let queue = DispatchQueue(label: "nscontrol.arkit.frames", qos: .userInteractive)
    private let mlQueue = DispatchQueue(label: "nscontrol.arkit.mlkit", qos: .userInitiated)

    /// Everything one running session needs; replaced as a whole.
    final class Active {
        let options: Options
        let preview: PreviewTexture?
        let previewId: Int64?
        let mlKit: MlKitRunner?
        init(options: Options, preview: PreviewTexture?, previewId: Int64?, mlKit: MlKitRunner?) {
            self.options = options
            self.preview = preview
            self.previewId = previewId
            self.mlKit = mlKit
        }
    }

    // Main thread only.
    private var session: ARSession?
    private var sink: FlutterEventSink?
    private var main: Active?
    private var statsTimer: Timer?

    // Touched only on `queue`.
    private var active: Active?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let bgraPool = BufferPool()
    private let mlKitPool = BufferPool()
    private var faceIds: [UUID: Int] = [:]
    private var nextFaceId = 1
    private var frameIndex = 0
    private var pendingEvents = 0
    private var sentDisplay = false
    // Counters for the 1 s stats event; guarded by `countersLock`.
    private let countersLock = NSLock()
    private var counters = Counters()

    struct Options {
        var formatIndex: Int?
        var fps: Int?
        var maxFaces = 2
        var preview = true
        var previewBgra = false
        var compareMlKit = false
        var mlKitOrientation = "auto"
        var mlKitBgra = false
        /// ML Kit input width; 0 keeps the full ARKit frame.
        var mlKitWidth = 640
        var emitEvery = 1
        var vertexStride = 20

        init() {}
        init(_ args: [String: Any]) {
            formatIndex = (args["formatIndex"] as? NSNumber)?.intValue
            fps = (args["fps"] as? NSNumber)?.intValue
            maxFaces = max(1, (args["maxFaces"] as? NSNumber)?.intValue ?? 2)
            preview = args["preview"] as? Bool ?? true
            previewBgra = args["previewBgra"] as? Bool ?? false
            compareMlKit = args["compareMlKit"] as? Bool ?? false
            mlKitOrientation = args["mlKitOrientation"] as? String ?? "auto"
            mlKitBgra = args["mlKitBgra"] as? Bool ?? false
            mlKitWidth = max(0, (args["mlKitWidth"] as? NSNumber)?.intValue ?? 640)
            emitEvery = max(1, (args["emitEvery"] as? NSNumber)?.intValue ?? 1)
            vertexStride = max(1, (args["vertexStride"] as? NSNumber)?.intValue ?? 20)
        }
    }

    struct Counters {
        var arFrames = 0
        var sent = 0
        var droppedEvents = 0
        var mlKitDone = 0
        var mlKitSkipped = 0
        var mlKitBusyUs: Int64 = 0
        var mlKitErrors = 0
        var mlKitWidth = 0
        var mlKitHeight = 0
    }

    init(textures: FlutterTextureRegistry) {
        self.textures = textures
        super.init()
    }

    static func uptimeUs() -> Int64 { Int64((CACurrentMediaTime() * 1_000_000).rounded()) }
    static func us(_ seconds: TimeInterval) -> Int64 { Int64((seconds * 1_000_000).rounded()) }

    // MARK: Flutter

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "isSupported":
            result(ARFaceTrackingConfiguration.isSupported)
        case "clock":
            result(NSNumber(value: Self.uptimeUs()))
        case "formats":
            result(ARFaceTrackingConfiguration.supportedVideoFormats.enumerated().map { index, format in
                ["index": index,
                 "width": Int(format.imageResolution.width),
                 "height": Int(format.imageResolution.height),
                 "fps": format.framesPerSecond] as [String: Any]
            })
        case "start":
            start(Options(args), result: result)
        case "stop":
            stop()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Session

    private func start(_ options: Options, result: @escaping FlutterResult) {
        guard ARFaceTrackingConfiguration.isSupported else {
            result(FlutterError(code: "unsupported", message: "ARKit Face Tracking недоступен на этом устройстве", details: nil))
            return
        }
        stop()
        let configuration = ARFaceTrackingConfiguration()
        let formats = ARFaceTrackingConfiguration.supportedVideoFormats
        if let index = options.formatIndex, formats.indices.contains(index) {
            configuration.videoFormat = formats[index]
        } else if let fps = options.fps, let format = formats.first(where: { $0.framesPerSecond == fps }) {
            configuration.videoFormat = format
        }
        configuration.maximumNumberOfTrackedFaces = min(options.maxFaces, ARFaceTrackingConfiguration.supportedNumberOfTrackedFaces)
        configuration.isLightEstimationEnabled = true
        configuration.worldAlignment = .gravity

        var preview: PreviewTexture?
        var previewId: Int64?
        if options.preview {
            let texture = PreviewTexture()
            preview = texture
            previewId = textures.register(texture)
        }
        let mlKit = options.compareMlKit ? MlKitRunner(orientation: options.mlKitOrientation) : nil
        let state = Active(options: options, preview: preview, previewId: previewId, mlKit: mlKit)
        main = state

        queue.sync {
            active = state
            faceIds = [:]
            nextFaceId = 1
            frameIndex = 0
            pendingEvents = 0
            sentDisplay = false
        }
        countersLock.lock(); counters = Counters(); countersLock.unlock()

        let session = ARSession()
        session.delegate = self
        session.delegateQueue = queue
        self.session = session
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        UIDevice.current.isBatteryMonitoringEnabled = true
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.emitStats() }

        let format = configuration.videoFormat
        var reply: [String: Any] = [
            "width": Int(format.imageResolution.width),
            "height": Int(format.imageResolution.height),
            "fps": format.framesPerSecond,
            "maxFaces": configuration.maximumNumberOfTrackedFaces,
            "mlKitAvailable": MlKitRunner.available,
            "uptimeUs": NSNumber(value: Self.uptimeUs()),
        ]
        if let previewId { reply["textureId"] = NSNumber(value: previewId) }
        result(reply)
    }

    private func stop() {
        statsTimer?.invalidate()
        statsTimer = nil
        session?.pause()
        session?.delegate = nil
        session = nil
        // After this no frame callback touches the old texture or runner.
        queue.sync { active = nil }
        if let previewId = main?.previewId { textures.unregisterTexture(previewId) }
        main = nil
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Runs on `queue`; `active` is nil once `stop()` has returned.
        guard let active else { return }
        let options = active.options
        let deliveredUs = Self.uptimeUs()
        countersLock.lock(); counters.arFrames += 1; countersLock.unlock()

        if let preview = active.preview, let previewId = active.previewId {
            let image = options.previewBgra ? bgra(frame.capturedImage) : frame.capturedImage
            if let image {
                preview.update(image)
                textures.textureFrameAvailable(previewId)
            }
        }
        frameIndex += 1
        if let mlKit = active.mlKit { analyseWithMlKit(frame, runner: mlKit, options: options) }
        guard frameIndex % options.emitEvery == 0 else { return }

        let capturedUs = Self.us(frame.timestamp)
        let imageSize = CGSize(width: CVPixelBufferGetWidth(frame.capturedImage),
                               height: CVPixelBufferGetHeight(frame.capturedImage))
        let portrait = CGSize(width: imageSize.height, height: imageSize.width)
        let cameraFromWorld = frame.camera.transform.inverse
        let up = simd_mul(cameraFromWorld, simd_float4(0, 1, 0, 0))
        let faces: [[String: Any]] = frame.anchors.compactMap { anchor in
            guard let face = anchor as? ARFaceAnchor else { return nil }
            return describe(face, cameraFromWorld: cameraFromWorld, camera: frame.camera, viewport: portrait,
                            vertexStride: options.vertexStride)
        }
        var event: [String: Any] = [
            "type": "arkit",
            "capturedUptimeUs": NSNumber(value: capturedUs),
            "deliveredUptimeUs": NSNumber(value: deliveredUs),
            "imageWidth": Int(imageSize.width),
            "imageHeight": Int(imageSize.height),
            "gravityUp": [Double(up.x), Double(up.y), Double(up.z)],
            "cameraTracking": Self.trackingName(frame.camera.trackingState),
            "faces": faces,
        ]
        if let light = frame.lightEstimate {
            event["lightIntensity"] = Double(light.ambientIntensity)
            event["lightTemperature"] = Double(light.ambientColorTemperature)
        }
        if !sentDisplay {
            sentDisplay = true
            let t = frame.displayTransform(for: .portrait, viewportSize: portrait)
            event["displayTransform"] = [t.a, t.b, t.c, t.d, t.tx, t.ty].map { Double($0) }
        }
        send(event)
    }

    private func describe(_ face: ARFaceAnchor, cameraFromWorld: simd_float4x4, camera: ARCamera, viewport: CGSize,
                          vertexStride: Int) -> [String: Any] {
        let id: Int
        if let known = faceIds[face.identifier] { id = known } else {
            id = nextFaceId
            nextFaceId += 1
            faceIds[face.identifier] = id
        }
        var row: [String: Any] = ["id": id, "tracked": face.isTracked]
        guard face.isTracked else { return row }
        row["faceInCamera"] = Self.flat(simd_mul(cameraFromWorld, face.transform))
        row["leftEye"] = Self.flat(face.leftEyeTransform)
        row["rightEye"] = Self.flat(face.rightEyeTransform)
        row["lookAt"] = [Double(face.lookAtPoint.x), Double(face.lookAtPoint.y), Double(face.lookAtPoint.z)]
        var shapes: [String: Double] = [:]
        for (key, value) in face.blendShapes { shapes[key.rawValue] = value.doubleValue }
        row["blendshapes"] = shapes
        // Rough face box in portrait display coordinates (pixels of the
        // rotated image) from a sample of the face mesh vertices.
        let vertices = face.geometry.vertices
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        var index = 0
        while index < vertices.count {
            let v = vertices[index]
            let world = simd_mul(face.transform, simd_float4(v.x, v.y, v.z, 1))
            let p = camera.projectPoint(simd_float3(world.x, world.y, world.z), orientation: .portrait, viewportSize: viewport)
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
            index += vertexStride
        }
        if minX.isFinite && maxX > minX && maxY > minY {
            row["bounds"] = [Double(minX), Double(minY), Double(maxX - minX), Double(maxY - minY)]
        }
        return row
    }

    /// Emits on the main thread; drops instead of queueing when Dart lags.
    private func send(_ event: [String: Any]) {
        guard pendingEvents < 4 else {
            countersLock.lock(); counters.droppedEvents += 1; countersLock.unlock()
            return
        }
        pendingEvents += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sink?(event)
            self.queue.async { self.pendingEvents -= 1 }
        }
        countersLock.lock(); counters.sent += 1; countersLock.unlock()
    }

    private func emitStats() {
        countersLock.lock()
        let c = counters
        counters = Counters()
        countersLock.unlock()
        let device = UIDevice.current
        var event: [String: Any] = [
            "type": "stats",
            "uptimeUs": NSNumber(value: Self.uptimeUs()),
            "arFrames": c.arFrames,
            "sent": c.sent,
            "droppedEvents": c.droppedEvents,
            "mlKitDone": c.mlKitDone,
            "mlKitSkipped": c.mlKitSkipped,
            "mlKitErrors": c.mlKitErrors,
            "mlKitBusyUs": NSNumber(value: c.mlKitBusyUs),
            "thermal": Self.thermalName(ProcessInfo.processInfo.thermalState),
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "batteryState": Self.batteryName(device.batteryState),
        ]
        if device.batteryLevel >= 0 { event["battery"] = Double(device.batteryLevel) }
        if let mlKit = main?.mlKit { event["mlKitOrientation"] = mlKit.orientationName }
        if c.mlKitWidth > 0 {
            event["mlKitWidth"] = c.mlKitWidth
            event["mlKitHeight"] = c.mlKitHeight
        }
        sink?(event)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let message = (error as NSError).localizedDescription
        let code = (error as? ARError)?.code == .cameraUnauthorized ? "camera_unauthorized" : "session_failed"
        DispatchQueue.main.async { [weak self] in
            self?.sink?(["type": "error", "code": code, "message": message])
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in self?.sink?(["type": "interrupted"]) }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in self?.sink?(["type": "resumed"]) }
    }

    // MARK: ML Kit on the same frame

    private func analyseWithMlKit(_ frame: ARFrame, runner: MlKitRunner, options: Options) {
        guard runner.tryBegin() else {
            countersLock.lock(); counters.mlKitSkipped += 1; countersLock.unlock()
            return
        }
        let capturedUs = Self.us(frame.timestamp)
        let arkitHasFace = frame.anchors.contains { ($0 as? ARFaceAnchor)?.isTracked == true }
        let source = frame.capturedImage
        let sourceWidth = CVPixelBufferGetWidth(source), sourceHeight = CVPixelBufferGetHeight(source)
        let input: CVPixelBuffer?
        if options.mlKitWidth > 0 && sourceWidth > options.mlKitWidth {
            // Closer to the 640-wide frames of the camera-plugin ML Kit path;
            // the aspect ratio (field of view) of the ARKit frame is kept.
            let height = Int((Double(sourceHeight) * Double(options.mlKitWidth) / Double(sourceWidth) / 2).rounded()) * 2
            input = mlKitPool.render(source, size: CGSize(width: options.mlKitWidth, height: height), context: ciContext)
        } else {
            input = options.mlKitBgra ? bgra(source) : source
        }
        guard let buffer = input else {
            runner.end()
            return
        }
        countersLock.lock()
        counters.mlKitWidth = CVPixelBufferGetWidth(buffer)
        counters.mlKitHeight = CVPixelBufferGetHeight(buffer)
        countersLock.unlock()
        mlQueue.async { [weak self] in
            let started = Self.uptimeUs()
            let outcome = runner.analyse(buffer, timestampUs: capturedUs, arkitHasFace: arkitHasFace)
            let completed = Self.uptimeUs()
            runner.end()
            guard let self else { return }
            self.countersLock.lock()
            switch outcome {
            case .faces: self.counters.mlKitDone += 1
            case .failed: self.counters.mlKitErrors += 1
            }
            self.counters.mlKitBusyUs += completed - started
            self.countersLock.unlock()
            guard case let .faces(faces, width, height) = outcome else { return }
            self.queue.async {
                self.send([
                    "type": "mlkit",
                    "capturedUptimeUs": NSNumber(value: capturedUs),
                    "completedUptimeUs": NSNumber(value: completed),
                    "imageWidth": width,
                    "imageHeight": height,
                    "orientation": runner.orientationName,
                    "faces": faces,
                ])
            }
        }
    }

    // MARK: Helpers

    /// Converts the camera's YCbCr buffer to BGRA (fallback for the preview
    /// texture or ML Kit if they reject the native format).
    private func bgra(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        bgraPool.render(source, size: CGSize(width: CVPixelBufferGetWidth(source),
                                             height: CVPixelBufferGetHeight(source)), context: ciContext)
    }

    static func flat(_ m: simd_float4x4) -> [Double] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap {
            [Double($0.x), Double($0.y), Double($0.z), Double($0.w)]
        }
    }

    static func trackingName(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "not_available"
        case .limited: return "limited"
        }
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func batteryName(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}

/// BGRA buffers of one size, filled from a camera buffer by Core Image
/// (format conversion and scaling). Used only on the frame queue.
final class BufferPool {
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero

    func render(_ source: CVPixelBuffer, size target: CGSize, context: CIContext) -> CVPixelBuffer? {
        if pool == nil || size != target {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(target.width),
                kCVPixelBufferHeightKey as String: Int(target.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
            size = target
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let output else { return nil }
        var image = CIImage(cvPixelBuffer: source)
        let sx = target.width / CGFloat(CVPixelBufferGetWidth(source))
        let sy = target.height / CGFloat(CVPixelBufferGetHeight(source))
        if sx != 1 || sy != 1 { image = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy)) }
        context.render(image, to: output)
        return output
    }
}

/// Holds the latest camera image for the Flutter texture. Only in memory.
final class PreviewTexture: NSObject, FlutterTexture {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func update(_ next: CVPixelBuffer) {
        lock.lock()
        buffer = next
        lock.unlock()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }
}

/// ML Kit Face Detection with the same options as the Dart `MlKitDetector`
/// (fast, classification, landmarks, tracking, min face 0.15), run on the
/// ARKit frame itself. One analysis at a time; frames arriving meanwhile are
/// skipped, as in `FramePipeline`.
final class MlKitRunner {
    enum Outcome {
        case faces([[String: Any]], Int, Int)
        case failed
    }

    /// Mirrored candidates first: the selfie convention of the camera preview.
    static let candidates: [(String, UIImage.Orientation)] = [
        ("leftMirrored", .leftMirrored), ("rightMirrored", .rightMirrored),
        ("upMirrored", .upMirrored), ("downMirrored", .downMirrored),
        ("right", .right), ("left", .left), ("up", .up), ("down", .down),
    ]

    private let lock = NSLock()
    private var busy = false
    private let auto: Bool
    private var candidate: Int
    private var misses = 0
    private var hits = 0
    private var locked = false

    init(orientation: String) {
        auto = orientation == "auto"
        candidate = Self.candidates.firstIndex { $0.0 == orientation } ?? 0
        locked = !auto
    }

    var orientationName: String {
        lock.lock(); defer { lock.unlock() }
        return Self.candidates[candidate].0 + (locked ? "" : "?")
    }

    func tryBegin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    func end() {
        lock.lock(); busy = false; lock.unlock()
    }

    /// In auto mode, moves to the next orientation after 15 frames where ARKit
    /// tracks a face and ML Kit finds none; locks after 10 hits.
    private func learn(found: Bool, arkitHasFace: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard auto, !locked, arkitHasFace else { return }
        if found {
            hits += 1
            misses = 0
            if hits >= 10 { locked = true }
        } else {
            misses += 1
            if misses >= 15 {
                misses = 0
                hits = 0
                candidate = (candidate + 1) % Self.candidates.count
            }
        }
    }

    #if canImport(MLKitFaceDetection) && canImport(MLKitVision)
    static let available = true
    private lazy var detector: FaceDetector = {
        let options = FaceDetectorOptions()
        options.performanceMode = .fast
        options.landmarkMode = .all
        options.classificationMode = .all
        options.contourMode = .none
        options.minFaceSize = 0.15
        options.isTrackingEnabled = true
        return FaceDetector.faceDetector(options: options)
    }()

    func analyse(_ buffer: CVPixelBuffer, timestampUs: Int64, arkitHasFace: Bool) -> Outcome {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                     formatDescriptionOut: &description)
        guard let description else { return .failed }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: timestampUs, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                 formatDescription: description, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return .failed }
        lock.lock()
        let orientation = Self.candidates[candidate].1
        lock.unlock()
        let image = VisionImage(buffer: sample)
        image.orientation = orientation
        let faces: [Face]
        do { faces = try detector.results(in: image) } catch { return .failed }
        learn(found: !faces.isEmpty, arkitHasFace: arkitHasFace)
        let rows: [[String: Any]] = faces.map { face in
            var row: [String: Any] = [
                "bounds": [Double(face.frame.minX), Double(face.frame.minY),
                           Double(face.frame.width), Double(face.frame.height)],
            ]
            if face.hasTrackingID { row["trackingId"] = face.trackingID }
            if face.hasHeadEulerAngleX { row["eulerX"] = Double(face.headEulerAngleX) }
            if face.hasHeadEulerAngleY { row["eulerY"] = Double(face.headEulerAngleY) }
            if face.hasHeadEulerAngleZ { row["eulerZ"] = Double(face.headEulerAngleZ) }
            if face.hasLeftEyeOpenProbability { row["leftEyeOpen"] = Double(face.leftEyeOpenProbability) }
            if face.hasRightEyeOpenProbability { row["rightEyeOpen"] = Double(face.rightEyeOpenProbability) }
            return row
        }
        let rotated = orientation == .left || orientation == .right ||
            orientation == .leftMirrored || orientation == .rightMirrored
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        return .faces(rows, rotated ? height : width, rotated ? width : height)
    }
    #else
    static let available = false
    func analyse(_ buffer: CVPixelBuffer, timestampUs: Int64, arkitHasFace: Bool) -> Outcome { .failed }
    #endif
}
