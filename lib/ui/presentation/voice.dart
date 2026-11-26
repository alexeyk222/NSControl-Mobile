import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/platform_bridge.dart';
import '../design/tokens.dart';

/// Voice prompts of the interface (copy.md §4) and the line they leave on
/// screen: the camera setup shows «Голос: «…»», look B shows a bubble on
/// the trip screen for [NsMotion.voiceBubble].
///
/// The trip controller says its own lines (calibration start, pause,
/// resume, head only, «Отметил»); [show] puts those on screen without
/// speaking them a second time.
class UiVoice extends ChangeNotifier {
  UiVoice({required this.platform, this.enabled = true});

  final PlatformBridge platform;

  /// «Голосовые подсказки» in settings.
  bool enabled;

  /// The line on screen now; null when the bubble has gone.
  String? line;
  Timer? _clear;
  String? _lastSpoken;
  DateTime? _lastAt;

  /// Speaks [text] (when voice is on) and shows it. The same line is not
  /// repeated within 6 s, so a state that flickers does not chatter.
  void say(String text) {
    final now = DateTime.now();
    if (text == _lastSpoken &&
        _lastAt != null &&
        now.difference(_lastAt!) < const Duration(seconds: 6)) {
      return;
    }
    _lastSpoken = text;
    _lastAt = now;
    if (enabled) {
      unawaited(() async {
        try {
          await platform.call('speech.say', {'text': text});
        } catch (_) {
          // Voice is best effort; the screen still shows the line.
        }
      }());
    }
    show(text);
  }

  /// Shows [text] as the last voice line without speaking it.
  void show(String text) {
    line = text;
    _clear?.cancel();
    _clear = Timer(NsMotion.voiceBubble, () {
      line = null;
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  void dispose() {
    _clear?.cancel();
    super.dispose();
  }
}
