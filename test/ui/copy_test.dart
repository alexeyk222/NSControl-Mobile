import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/ui/copy.dart';

/// docs/ux/copy.md §2: no technical words and no blame in the driver's
/// text; voice lines short; red only on the alarm.
void main() {
  final source = File('lib/ui/copy.dart').readAsStringSync();
  final strings = RegExp(
    r"'([^'\\]*(?:\\.[^'\\]*)*)'",
  ).allMatches(source).map((m) => m.group(1)!).toList();

  test('no technical or frightening words in the interface text', () {
    const forbidden = [
      'ARKit',
      'ML Kit',
      'калибровк',
      'трекинг',
      'алгоритм',
      'детектор',
      'порог',
      'канал',
      'датчик',
      'ошибка',
      'Ошибка',
      'сбой',
      'FPS',
      'кадров',
      'опасно',
      'Опасно',
      'вы виноваты',
      'немедленно',
    ];
    for (final s in strings) {
      for (final word in forbidden) {
        expect(s.contains(word), isFalse, reason: '«$s» contains «$word»');
      }
    }
  });

  test('voice lines are up to eight words', () {
    for (final line in [
      Voice.calNoFace,
      Voice.calMany,
      Voice.calGo,
      Voice.calRetry,
      Voice.calDone,
      Voice.headOnly,
      Voice.noFace,
      Voice.many,
      Voice.paused,
      Voice.resumed,
      Voice.cameraError,
      Voice.watchLost,
      Voice.afterEyes,
      Voice.afterEyesAgain,
      Voice.afterHead,
      Voice.breakDue('2 часа'),
    ]) {
      final words = line.split(RegExp(r'[\s ]+')).where((w) => w.isNotEmpty);
      expect(words.length, lessThanOrEqualTo(8), reason: line);
    }
  });

  test('plural and time helpers', () {
    expect(times(1), '1 раз');
    expect(times(2), '2 раза');
    expect(times(5), '5 раз');
    expect(times(12), '12 раз');
    expect(Copy.hisAlarms(21), '21 тревога');
    expect(plain(hoursMinutes(const Duration(minutes: 100))), '1 ч 40 мин');
    expect(plain(hoursMinutes(const Duration(minutes: 45))), '45 мин');
    expect(plain(breakInterval(const Duration(hours: 2))), '2 часа');
    expect(plain(breakInterval(const Duration(minutes: 90))), '1,5 часа');
  });

  test('the alarm red is used by the alarm only', () {
    final offenders = <String>[];
    for (final f in Directory('lib/ui').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final text = f.readAsStringSync();
      final usesRed =
          text.contains('NsColors.alarm') &&
              !text.contains('NsColors.alarmF') ||
          text.toUpperCase().contains('C8161D');
      final allowed =
          f.path.endsWith('alarm_overlay.dart') ||
          f.path.endsWith('tokens.dart');
      if (usesRed && !allowed) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
  });
}

/// The text with plain spaces instead of the non-breaking ones.
String plain(String s) => s.replaceAll(nbsp, ' ');
