import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../logic/arkit_geometry.dart';
import '../logic/clock_map.dart';
import '../logic/domain.dart';
import 'detector.dart';
import 'face_source.dart';

/// Options of one ARKit run. Everything here can be changed between runs
/// without rebuilding the app, so device checks need fewer builds.
class ArkitOptions {
  const ArkitOptions({
    this.fps,
    this.formatIndex,
    this.maxFaces = 2,
    this.preview = true,
    this.previewBgra = false,
    this.compareMlKit = false,
    this.mlKitOrientation = 'auto',
    this.mlKitBgra = false,
    this.mlKitWidth = 640,
    this.emitEvery = 1,
    this.axes = ArkitAxes.device,
  });

  /// 30 or 60; ignored when [formatIndex] is set.
  final int? fps;
  final int? formatIndex;

  /// More than one face lets the ТЗ "single face" rule see a passenger.
  final int maxFaces;
  final bool preview;

  /// Converts the preview to BGRA if the texture shows the native YCbCr
  /// image wrongly.
  final bool previewBgra;

  /// Runs ML Kit Face Detection on the same `capturedImage`.
  final bool compareMlKit;

  /// `auto` or a `UIImage.Orientation` name such as `leftMirrored`.
  final String mlKitOrientation;
  final bool mlKitBgra;

  /// ML Kit input width in comparison mode: the ARKit frame (1280 wide) is
  /// scaled to it, keeping its aspect ratio, to be closer to the 640-wide
  /// frames of the camera-plugin ML Kit path. 0 keeps the full frame.
  final int mlKitWidth;

  /// Send every n-th ARKit frame to Dart.
  final int emitEvery;
  final ArkitAxes axes;

  Map<String, Object?> toMap() => {
    if (fps != null) 'fps': fps,
    if (formatIndex != null) 'formatIndex': formatIndex,
    'maxFaces': maxFaces,
    'preview': preview,
    'previewBgra': previewBgra,
    'compareMlKit': compareMlKit,
    'mlKitOrientation': mlKitOrientation,
    'mlKitBgra': mlKitBgra,
    'mlKitWidth': mlKitWidth,
    'emitEvery': emitEvery,
  };
}

class ArkitVideoFormat {
  const ArkitVideoFormat(this.index, this.width, this.height, this.fps);
  final int index, width, height, fps;
  @override
  String toString() => '$width×$height @ $fps';
}

class ArkitStartInfo {
  const ArkitStartInfo({
    required this.width,
    required this.height,
    required this.fps,
    required this.maxFaces,
    required this.mlKitAvailable,
    this.textureId,
  });
  final int width, height, fps, maxFaces;
  final bool mlKitAvailable;
  final int? textureId;
}

/// Once-a-second device and throughput numbers for criterion 4 of the plan.
class ArkitStats {
  const ArkitStats({
    required this.atUs,
    required this.arFrames,
    required this.sent,
    required this.droppedEvents,
    required this.mlKitDone,
    required this.mlKitSkipped,
    required this.mlKitErrors,
    required this.mlKitBusyUs,
    required this.thermal,
    required this.lowPower,
    required this.batteryState,
    this.battery,
    this.mlKitOrientation,
    this.lightIntensity,
    this.imageWidth,
    this.imageHeight,
    this.mlKitWidth,
    this.mlKitHeight,
  });
  final int atUs, arFrames, sent, droppedEvents;
  final int mlKitDone, mlKitSkipped, mlKitErrors, mlKitBusyUs;
  final String thermal, batteryState;
  final bool lowPower;
  final double? battery, lightIntensity;
  final String? mlKitOrientation;

  /// `capturedImage` size of the running ARKit format (sensor orientation);
  /// ML Kit analyses the same image in comparison mode.
  final int? imageWidth, imageHeight;

  /// Size of the image ML Kit actually analysed in the last second (after
  /// scaling, before rotation), null when ML Kit did not run.
  final int? mlKitWidth, mlKitHeight;

  /// The `device` line of the recording (see the contract).
  Map<String, Object?> toJson() => {
    'type': 'device',
    'atUs': atUs,
    'thermal': thermal,
    if (battery != null) 'battery': battery,
    'batteryState': batteryState,
    'lowPower': lowPower,
    if (lightIntensity != null) 'light': lightIntensity,
    'arkitFps': arFrames,
    'sent': sent,
    'dropped': droppedEvents,
    'mlKitDone': mlKitDone,
    'mlKitSkipped': mlKitSkipped,
    'mlKitErrors': mlKitErrors,
    'mlKitBusyUs': mlKitBusyUs,
    if (mlKitOrientation != null) 'mlKitOrientation': mlKitOrientation,
    if (imageWidth != null) 'imageWidth': imageWidth,
    if (imageHeight != null) 'imageHeight': imageHeight,
    if (mlKitWidth != null) 'mlKitWidth': mlKitWidth,
    if (mlKitHeight != null) 'mlKitHeight': mlKitHeight,
  };
}

/// Faces from the ML Kit run inside the ARKit bridge, mapped exactly like
/// `MlKitDetector` maps the plugin's faces (pitch = −Euler X, yaw = Euler Y,
/// roll = Euler Z). Keep the two in step until the ML Kit signs are proven
/// in the lab; then both should share one mapping.
///
/// [imageWidth]/[imageHeight] are the upright image size and [mirrored] says
/// whether the bridge analysed a mirrored orientation; with them the signals
/// get the contract's unmirrored [FaceSignals.box].
DetectedFace mlKitFaceFromMap(
  Map<Object?, Object?> map, {
  double? imageWidth,
  double? imageHeight,
  bool mirrored = false,
}) {
  double? d(String key) {
    final value = map[key];
    return value is num && value.isFinite ? value.toDouble() : null;
  }

  final x = d('eulerX');
  final measurement = FaceMeasurement(
    trackingId: (map['trackingId'] as num?)?.toInt(),
    leftEye: d('leftEyeOpen'),
    rightEye: d('rightEyeOpen'),
    pitchDown: x == null ? null : -x,
    yaw: d('eulerY'),
    roll: d('eulerZ'),
  );
  final b = map['bounds'];
  final bounds = b is List && b.length == 4 && b.every((v) => v is num)
      ? Rect.fromLTWH(
          (b[0] as num).toDouble(),
          (b[1] as num).toDouble(),
          (b[2] as num).toDouble(),
          (b[3] as num).toDouble(),
        )
      : Rect.zero;
  FaceBox? box;
  if (bounds != Rect.zero &&
      imageWidth != null &&
      imageHeight != null &&
      imageWidth > 0 &&
      imageHeight > 0) {
    final left = bounds.left / imageWidth, width = bounds.width / imageWidth;
    final candidate = FaceBox(
      left: mirrored ? 1 - left - width : left,
      top: bounds.top / imageHeight,
      width: width,
      height: bounds.height / imageHeight,
    );
    try {
      candidate.validate();
      box = candidate;
    } on FormatException {
      box = null;
    }
  }
  return DetectedFace(
    measurement,
    bounds,
    signals: FaceSignals(
      engineId: DetectorCapabilities.mlKit.id,
      box: box,
      trackingId: measurement.trackingId,
      headYawLeft: measurement.yaw,
      headPitchDown: measurement.pitchDown,
      headRollRight: measurement.roll,
      eyeOpenLeft: measurement.leftEye,
      eyeOpenRight: measurement.rightEye,
    ),
  );
}

/// ARKit Face Tracking engine on iPhone (TrueDepth), streaming like a camera
/// rather than answering `detect` calls, so it sits beside
/// [FaceDetectorPort]. While it runs, ARKit owns the front camera: the camera
/// plugin must be stopped first.
///
/// Time: native timestamps are iOS uptime microseconds. Each event carries
/// its native send time; [ClockMap] turns them into the `nowUs` time given to
/// [start], so `capturedUs`/`completedUs` are on the caller's clock.
class ArkitEngine {
  ArkitEngine({
    MethodChannel? method,
    EventChannel? events,
    this.axes = ArkitAxes.device,
  }) : _method = method ?? const MethodChannel('nscontrol/arkit'),
       _events = events ?? const EventChannel('nscontrol/arkit/events');

  static const capabilities = arkitCapabilities;
  int Function() nowUs = () => 0;
  final MethodChannel _method;
  final EventChannel _events;

  /// Sign corrections; may be changed while running (sign test).
  ArkitAxes axes;
  final clock = ClockMap();
  StreamSubscription<Object?>? _subscription;
  int _generation = 0;
  ArkitStartInfo? info;

  /// How to rotate/flip the preview texture; known after the first frame.
  ({int quarterTurns, bool mirrored})? display;
  bool get running => _subscription != null;

  // capturedUptimeUs → capturedUs for recent ARKit frames, so the ML Kit
  // result of the same frame gets exactly the same capturedUs.
  final Map<int, int> _captured = {};
  final List<int> _capturedOrder = [];

  Future<bool> isSupported() async =>
      await _method.invokeMethod<bool>('isSupported') ?? false;

  Future<List<ArkitVideoFormat>> formats() async {
    final list = await _method.invokeListMethod<Object?>('formats') ?? [];
    return [
      for (final item in list.whereType<Map<Object?, Object?>>())
        ArkitVideoFormat(
          (item['index'] as num).toInt(),
          (item['width'] as num).toInt(),
          (item['height'] as num).toInt(),
          (item['fps'] as num).toInt(),
        ),
    ];
  }

  Future<ArkitStartInfo> start(
    ArkitOptions options, {
    required int Function() nowUs,
    required void Function(FaceResult result, Map<String, Object?> raw)
    onResult,
    required void Function(Object) onError,
    void Function(ArkitStats)? onStats,
    void Function(String status)? onStatus,
  }) async {
    await stop();
    final generation = ++_generation;
    this.nowUs = nowUs;
    axes = options.axes;
    clock.reset();
    _captured.clear();
    _capturedOrder.clear();
    display = null;
    _subscription = _events.receiveBroadcastStream().listen(
      (event) {
        if (generation != _generation || event is! Map) return;
        try {
          _handle(event, onResult, onError, onStats, onStatus);
        } catch (error) {
          onError(error);
        }
      },
      onError: (Object error) {
        if (generation == _generation) onError(error);
      },
    );
    try {
      final reply = await _method.invokeMapMethod<String, Object?>(
        'start',
        options.toMap(),
      );
      if (reply == null) throw StateError('ARKit не ответил на запуск');
      final native = (reply['uptimeUs'] as num?)?.toInt();
      if (native != null) clock.sample(nativeUs: native, localUs: nowUs());
      final started = ArkitStartInfo(
        width: (reply['width'] as num).toInt(),
        height: (reply['height'] as num).toInt(),
        fps: (reply['fps'] as num).toInt(),
        maxFaces: (reply['maxFaces'] as num).toInt(),
        mlKitAvailable: reply['mlKitAvailable'] == true,
        textureId: (reply['textureId'] as num?)?.toInt(),
      );
      info = started;
      return started;
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    _generation++;
    final subscription = _subscription;
    _subscription = null;
    info = null;
    if (subscription == null) return;
    await subscription.cancel();
    await _method.invokeMethod<void>('stop');
  }

  void _handle(
    Map<Object?, Object?> event,
    void Function(FaceResult, Map<String, Object?>) onResult,
    void Function(Object) onError,
    void Function(ArkitStats)? onStats,
    void Function(String status)? onStatus,
  ) {
    final received = nowUs();
    switch (event['type']) {
      case 'arkit':
        final delivered = (event['deliveredUptimeUs'] as num).toInt();
        clock.sample(nativeUs: delivered, localUs: received);
        final nativeCaptured = (event['capturedUptimeUs'] as num).toInt();
        final completed = _local(delivered, received);
        final captured = _local(nativeCaptured, completed);
        _remember(nativeCaptured, captured);
        final transform = event['displayTransform'];
        if (transform is List) {
          display = displayOrientation([
            for (final v in transform) (v as num).toDouble(),
          ]);
        }
        final up = [
          for (final v in (event['gravityUp'] as List?) ?? const [])
            (v as num).toDouble(),
        ];
        final rawFaces = [
          for (final f in (event['faces'] as List?) ?? const [])
            ArkitFaceRaw.fromMap(f as Map<Object?, Object?>),
        ];
        final width = (event['imageWidth'] as num?)?.toDouble() ?? 0;
        final height = (event['imageHeight'] as num?)?.toDouble() ?? 0;
        // Bounds come in ARKit's portrait display space; the contract box is
        // unmirrored, so undo the display flip when ARKit applies one.
        final boxFrame = display == null
            ? null
            : (width: height, height: width, mirrored: display!.mirrored);
        final faces = [
          for (final raw in rawFaces)
            _arkitFace(
              raw,
              arkitSignals(raw, gravityUp: up, axes: axes, boxFrame: boxFrame),
            ),
        ];
        onResult(
          FaceResult(
            engineId: arkitCapabilities.id,
            capturedUs: captured,
            completedUs: completed,
            faces: faces,
            // Bounds are in portrait display pixels.
            imageSize: Size(height, width),
          ),
          {
            'gravityUp': up,
            if (event['lightIntensity'] != null)
              'light': event['lightIntensity'],
            'axes': axes.toJson(),
            'faces': [for (final f in rawFaces) f.toJson()],
          },
        );
      case 'mlkit':
        final nativeCaptured = (event['capturedUptimeUs'] as num).toInt();
        final nativeCompleted = (event['completedUptimeUs'] as num).toInt();
        if (!clock.ready) return;
        final completed = _local(nativeCompleted, received);
        final captured =
            _captured[nativeCaptured] ?? _local(nativeCaptured, completed);
        final width = (event['imageWidth'] as num?)?.toDouble() ?? 0;
        final height = (event['imageHeight'] as num?)?.toDouble() ?? 0;
        final orientation = event['orientation'] as String? ?? '';
        onResult(
          FaceResult(
            engineId: DetectorCapabilities.mlKit.id,
            capturedUs: captured,
            completedUs: completed,
            faces: [
              for (final f in (event['faces'] as List?) ?? const [])
                mlKitFaceFromMap(
                  f as Map<Object?, Object?>,
                  imageWidth: width,
                  imageHeight: height,
                  mirrored: orientation.contains('Mirrored'),
                ),
            ],
            imageSize: Size(width, height),
          ),
          {'orientation': event['orientation']},
        );
      case 'stats':
        if (onStats == null || !clock.ready) return;
        double? d(String key) => (event[key] as num?)?.toDouble();
        int i(String key) => (event[key] as num?)?.toInt() ?? 0;
        onStats(
          ArkitStats(
            atUs: _local(i('uptimeUs'), received),
            arFrames: i('arFrames'),
            sent: i('sent'),
            droppedEvents: i('droppedEvents'),
            mlKitDone: i('mlKitDone'),
            mlKitSkipped: i('mlKitSkipped'),
            mlKitErrors: i('mlKitErrors'),
            mlKitBusyUs: i('mlKitBusyUs'),
            thermal: event['thermal'] as String? ?? 'unknown',
            lowPower: event['lowPower'] == true,
            batteryState: event['batteryState'] as String? ?? 'unknown',
            battery: d('battery'),
            mlKitOrientation: event['mlKitOrientation'] as String?,
            imageWidth: info?.width,
            imageHeight: info?.height,
            mlKitWidth: (event['mlKitWidth'] as num?)?.toInt(),
            mlKitHeight: (event['mlKitHeight'] as num?)?.toInt(),
          ),
        );
      case 'error':
        onError(
          StateError(
            event['code'] == 'camera_unauthorized'
                ? 'Нет доступа к камере. Разрешите камеру в настройках iOS.'
                : 'ARKit: ${event['message']}',
          ),
        );
      case 'interrupted' || 'resumed':
        onStatus?.call(event['type'] as String);
    }
  }

  /// Local time of a native instant, never later than [notAfter].
  int _local(int nativeUs, int notAfter) {
    final local = clock.toLocal(nativeUs);
    return local > notAfter ? notAfter : local;
  }

  void _remember(int native, int local) {
    _captured[native] = local;
    _capturedOrder.add(native);
    if (_capturedOrder.length > 240) {
      _captured.remove(_capturedOrder.removeAt(0));
    }
  }

  DetectedFace _arkitFace(ArkitFaceRaw raw, FaceSignals signals) {
    final b = raw.bounds;
    return DetectedFace(
      signals.toMeasurement(),
      b == null ? Rect.zero : Rect.fromLTWH(b[0], b[1], b[2], b[3]),
      signals: signals,
    );
  }
}

/// ARKit as a lab [FaceSource]: `[arkit]` or, with [compare], `[arkit,
/// mlkit]` where ML Kit analyses the same `capturedImage` and both results
/// carry the same `capturedUs`.
class ArkitFaceSource implements FaceSource {
  ArkitFaceSource({
    this.compare = false,
    ArkitOptions? options,
    ArkitEngine? engine,
    this.onRaw,
    this.onStats,
  }) : options = options ?? ArkitOptions(compareMlKit: compare),
       engine = engine ?? ArkitEngine();

  final bool compare;
  final ArkitOptions options;
  final ArkitEngine engine;

  /// Engine numbers of each result (matrices, raw blendshape names, light),
  /// for a recording that wants to re-derive angles offline. No pixels.
  final void Function(FaceResult result, Map<String, Object?> raw)? onRaw;

  /// Device and throughput numbers once a second (`device` lines).
  final void Function(ArkitStats stats)? onStats;
  bool _running = false;
  int? _textureId;

  @override
  List<DetectorCapabilities> get engines => [
    arkitCapabilities,
    if (compare) DetectorCapabilities.mlKit,
  ];

  @override
  bool get running => _running;

  @override
  bool get previewMirrored => engine.display?.mirrored ?? true;

  @override
  Future<void> start({
    required int Function() nowUs,
    required void Function(FaceResult) onResult,
    required void Function(Object) onError,
    required void Function() onChanged,
  }) async {
    await stop();
    var knownDisplay = false;
    final info = await engine.start(
      ArkitOptions(
        fps: options.fps,
        formatIndex: options.formatIndex,
        maxFaces: options.maxFaces,
        preview: options.preview,
        previewBgra: options.previewBgra,
        compareMlKit: compare,
        mlKitOrientation: options.mlKitOrientation,
        mlKitBgra: options.mlKitBgra,
        mlKitWidth: options.mlKitWidth,
        emitEvery: options.emitEvery,
        axes: options.axes,
      ),
      nowUs: nowUs,
      onResult: (result, raw) {
        // Raw first, so a recorder can put it into the frame line of result.
        onRaw?.call(result, raw);
        onResult(result);
        if (!knownDisplay && engine.display != null) {
          knownDisplay = true;
          onChanged();
        }
      },
      onError: onError,
      onStats: onStats,
      onStatus: (_) => onChanged(),
    );
    _textureId = info.textureId;
    _running = true;
    if (compare && !info.mlKitAvailable) {
      onError(
        StateError('ML Kit недоступен в нативной части: сравнение выключено'),
      );
    }
    onChanged();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _textureId = null;
    await engine.stop();
  }

  @override
  Widget? preview() {
    final id = _textureId, info = engine.info;
    if (id == null || info == null) return null;
    final display = engine.display;
    final turns = display?.quarterTurns ?? 1;
    final width = info.width.toDouble(), height = info.height.toDouble();
    final upright = turns.isOdd ? height / width : width / height;
    return AspectRatio(
      aspectRatio: upright,
      child: RotatedBox(
        quarterTurns: turns,
        child: Transform.flip(
          flipX: display?.mirrored ?? false,
          child: Texture(textureId: id),
        ),
      ),
    );
  }

  @override
  Future<void> dispose() => stop();
}

/// Lab choices for ARKit; `main.dart` adds them to its engine list.
List<LabEngineOption> arkitLabEngineOptions({
  void Function(FaceResult result, Map<String, Object?> raw)? onRaw,
  void Function(ArkitStats stats)? onStats,
}) => [
  LabEngineOption(
    id: 'arkit',
    title: 'ARKit',
    engineIds: [arkitCapabilities.id],
    create: () => ArkitFaceSource(onRaw: onRaw, onStats: onStats),
  ),
  LabEngineOption(
    id: 'arkit_mlkit',
    title: 'ARKit + ML Kit на тех же кадрах',
    engineIds: [arkitCapabilities.id, DetectorCapabilities.mlKit.id],
    create: () =>
        ArkitFaceSource(compare: true, onRaw: onRaw, onStats: onStats),
  ),
];
