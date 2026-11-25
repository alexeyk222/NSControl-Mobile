import 'dart:io';

import 'package:nscontrol/services/review_page_html.dart';

/// Writes the review page to a file for use on the Mac without the phone:
/// open it in a browser and pick the trip recording, its clips and its
/// review file (docs/trip-debug.md).
///
///   dart run tool/review_page.dart ~/Desktop/nscontrol-review.html
Future<void> main(List<String> args) async {
  final path = args.isEmpty ? 'nscontrol-review.html' : args.first;
  await File(path).writeAsString(reviewPageHtml);
  stdout.writeln(path);
}
