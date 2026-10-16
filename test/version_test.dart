import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/version.dart';

void main() {
  test('appVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match?.group(1), appVersion);
  });
}
