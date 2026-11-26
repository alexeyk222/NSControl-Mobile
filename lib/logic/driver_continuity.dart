import 'signals.dart';

/// Keeps the calibrated driver across tracking-id changes.
///
/// ML Kit gives a face a new tracking id after every loss (a blind-spot check,
/// a long turn), and `ObservationEngine` treats a new id as a changed face and
/// stops until a new calibration (ФТ-02). ФТ-02 also says the tracking id must
/// not be used to establish identity, ТЗ 4.x (calibration) says an ordinary
/// head turn does not remove the saved profile, and ПЗ adds: after the return
/// to the working view and unambiguous observation of the selected face, the
/// previous parameters are used if the phone was not moved.
///
/// So the identity of the driver is decided here, from geometry, and the
/// engine keeps working unchanged:
/// - one face that reappears within [maxGapUs] where the driver was (face box
///   centre and size as at calibration or just before the loss; distance for
///   ARKit) gets the calibrated id back ([ContinuityDecision.restored]);
/// - without any geometry the face is taken back only within [noGeometryGapUs];
/// - two or more faces, a face elsewhere or of another size, or a longer loss
///   pass through unchanged, and the engine suspends observation until the
///   face is confirmed and calibrated again (ФТ-02);
/// - a face that was last seen touching or crossing the frame edge (within
///   [edgeMargin]) has left the frame, as a participant does when another
///   takes the seat (ПМИ, replacement of the participant): whoever comes back
///   is not taken back, whatever the geometry.
///
/// This is how ФТ-02/ФТ-03 are met, not an extension: it is active in
/// acceptance mode too.
class DriverContinuity {
  DriverContinuity({
    required this.trackingId,
    this.maxGapUs = 5000000,
    this.noGeometryGapUs = 3000000,
    this.centerTolerance = .6,
    this.minSizeRatio = .7,
    this.maxSizeRatio = 1.4,
    this.distanceToleranceM = .12,
    this.edgeMargin = .02,
  });

  /// Tracking id of the calibrated face.
  final int trackingId;

  /// Longest loss after which a matching face is still the driver.
  final int maxGapUs;

  /// The same when the engine reports neither a box nor a distance.
  final int noGeometryGapUs;

  /// Allowed shift of the box centre, in widths of the reference box.
  final double centerTolerance;

  /// Allowed ratio of box widths, new / reference.
  final double minSizeRatio, maxSizeRatio;

  /// Allowed difference of the face distance, metres (ARKit).
  final double distanceToleranceM;

  /// A box this close to a frame edge (fraction of the frame) touches it.
  final double edgeMargin;

  final Set<int> _aliases = {};
  FaceBox? _referenceBox, _lastBox;
  double? _referenceDistance, _lastDistance;
  int? _lastSeenUs;
  bool _lost = false, _leftFrame = false;
  ContinuityDecision _decision = ContinuityDecision.noFace;

  ContinuityDecision get decision => _decision;

  /// Sets where and when the driver was last seen before observation starts:
  /// the last calibration frame (or the median box and distance of the
  /// calibration). Without it a face lost between the end of calibration and
  /// the first observed frame comes back with a new ML Kit id and is taken
  /// for another face. The first face after the start is then checked
  /// against this reference by the same rules as after any loss.
  void anchor(int atUs, {FaceBox? box, double? distanceM}) {
    _lastSeenUs = atUs;
    _lost = false;
    _leftFrame = false;
    _referenceBox = box;
    _lastBox = box;
    _referenceDistance = distanceM;
    _lastDistance = distanceM;
  }

  /// Several faces at the confirmation of the face and in the calibration
  /// window (not in observation, which stops on several faces): the one
  /// that is the driver by geometry (box, distance) as last seen, with the
  /// calibrated id. Null when none fits or more than one does: the driver
  /// cannot be told apart, and the frame is not usable.
  FaceSignals? pick(int atUs, List<FaceSignals> faces) {
    final fits = [
      for (final f in faces)
        if (_matches(atUs, f)) f,
    ];
    if (fits.length != 1) {
      _decision = ContinuityDecision.ambiguous;
      return null;
    }
    final face = fits.single;
    final id = face.trackingId;
    if (id != null && id != trackingId) _aliases.add(id);
    _confirm(atUs, face);
    _decision = ContinuityDecision.same;
    return id == trackingId ? face : _withId(face);
  }

  /// Returns [faces] with the calibrated id restored where the face is the
  /// driver; everything else is passed on as is.
  List<FaceSignals> resolve(int atUs, List<FaceSignals> faces) {
    if (faces.isEmpty) {
      _lose();
      _decision = ContinuityDecision.noFace;
      return faces;
    }
    if (faces.length > 1) {
      _lose();
      _decision = ContinuityDecision.ambiguous;
      return faces;
    }
    final face = faces.single;
    final id = face.trackingId;
    final known =
        id == trackingId ||
        _aliases.contains(id) ||
        (id == null && !_lost && _lastSeenUs != null);
    if (known || _lastSeenUs == null && (id == null || id == trackingId)) {
      _confirm(atUs, face);
      _decision = ContinuityDecision.same;
      return id == trackingId ? faces : [_withId(face)];
    }
    if (_matches(atUs, face)) {
      if (id != null) _aliases.add(id);
      _confirm(atUs, face);
      _decision = ContinuityDecision.restored;
      return [_withId(face)];
    }
    _decision = ContinuityDecision.different;
    return faces;
  }

  /// True when the driver was last seen at the frame edge before the loss.
  bool get leftFrame => _leftFrame;

  void _lose() {
    if (!_lost) {
      final box = _lastBox;
      _leftFrame = box != null && _atEdge(box);
    }
    _lost = true;
  }

  bool _atEdge(FaceBox b) =>
      b.left <= edgeMargin ||
      b.top <= edgeMargin ||
      b.left + b.width >= 1 - edgeMargin ||
      b.top + b.height >= 1 - edgeMargin;

  void _confirm(int atUs, FaceSignals face) {
    _lastSeenUs = atUs;
    _lost = false;
    _leftFrame = false;
    if (face.box != null) {
      _referenceBox ??= face.box;
      _lastBox = face.box;
    }
    if (face.distanceM != null) {
      _referenceDistance ??= face.distanceM;
      _lastDistance = face.distanceM;
    }
  }

  bool _matches(int atUs, FaceSignals face) {
    final last = _lastSeenUs;
    if (last == null || _leftFrame) return false;
    final gap = atUs - last;
    final box = face.box, distance = face.distanceM;
    final canBox = box != null && _referenceBox != null;
    final canDistance = distance != null && _referenceDistance != null;
    if (!canBox && !canDistance) return gap <= noGeometryGapUs;
    if (gap > maxGapUs) return false;
    if (canBox &&
        !(_boxMatches(box, _referenceBox!) ||
            (_lastBox != null && _boxMatches(box, _lastBox!)))) {
      return false;
    }
    if (canDistance &&
        !((distance - _referenceDistance!).abs() <= distanceToleranceM ||
            (_lastDistance != null &&
                (distance - _lastDistance!).abs() <= distanceToleranceM))) {
      return false;
    }
    return true;
  }

  bool _boxMatches(FaceBox b, FaceBox ref) {
    final ratio = b.width / ref.width;
    final dx = b.centerX - ref.centerX, dy = b.centerY - ref.centerY;
    final shift = (dx * dx + dy * dy) / (ref.width * ref.width);
    return ratio >= minSizeRatio &&
        ratio <= maxSizeRatio &&
        shift <= centerTolerance * centerTolerance;
  }

  FaceSignals _withId(FaceSignals f) => FaceSignals(
    engineId: f.engineId,
    trackingId: trackingId,
    tracked: f.tracked,
    headYawLeft: f.headYawLeft,
    headPitchDown: f.headPitchDown,
    headRollRight: f.headRollRight,
    gazeLeft: f.gazeLeft,
    gazeDown: f.gazeDown,
    eyeGazeLeft: f.eyeGazeLeft,
    eyeGazeDown: f.eyeGazeDown,
    eyeOpenLeft: f.eyeOpenLeft,
    eyeOpenRight: f.eyeOpenRight,
    distanceM: f.distanceM,
    box: f.box,
    headRotation: f.headRotation,
    blendshapes: f.blendshapes,
  );
}

enum ContinuityDecision {
  /// The calibrated face (or an id already taken back).
  same('same'),

  /// A new id taken back as the driver by geometry after a loss.
  restored('restored'),

  /// No face in the frame.
  noFace('no_face'),

  /// More than one face: the engine suspends observation (ФТ-02).
  ambiguous('ambiguous'),

  /// Another face, or too long a loss: the engine suspends observation.
  different('different');

  const ContinuityDecision(this.code);
  final String code;
}
