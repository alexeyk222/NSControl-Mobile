import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/services/trip_controller.dart';
import 'package:nscontrol/ui/copy.dart';
import 'package:nscontrol/ui/presentation/trip_view.dart';
import 'package:nscontrol/ui/widgets/marks.dart';
import 'package:nscontrol/ui/widgets/status_indicator.dart';

import 'copy_test.dart' show plain;

/// docs/ux/states.md S-01…S-16 on the trip screen.
void main() {
  TripView view(TripFacts f) => TripView.from(f);

  test('S-01 watching shows the time on the road', () {
    final v = view(
      const TripFacts(watchText: 'Слежу', drivingTime: Duration(minutes: 72)),
    );
    expect(v.indicator, IndicatorKind.watching);
    expect(v.status, Copy.watching);
    expect(v.tone, StatusTone.normal);
    expect(plain(v.context!), 'В пути 1 ч 12 мин');
    expect(v.advice, isNull);
  });

  test('S-02 head only is yellow and says the eyes are not seen', () {
    final v = view(const TripFacts(watchText: 'Слежу за головой'));
    expect(v.indicator, IndicatorKind.headOnly);
    expect(v.tone, StatusTone.attention);
    expect(v.context, Copy.eyesHidden);
  });

  test('S-04 not seen and S-05 several faces', () {
    final unseen = view(const TripFacts(watchText: 'Не вижу вас'));
    expect(unseen.indicator, IndicatorKind.unseen);
    expect(unseen.status, Copy.noFace);
    expect(unseen.voice, Voice.noFace);
    final many = view(
      const TripFacts(
        watchText: 'В кадре кто-то ещё. Слежу, когда останетесь одни',
        multipleFaces: true,
      ),
    );
    expect(many.status, Copy.many);
    expect(many.indicator, IndicatorKind.unseen);
  });

  test('S-12 a silent camera never reads «Слежу» (architect, 25.11)', () {
    final v = view(
      const TripFacts(
        cameraSilent: true,
        watchText: 'Камера не отвечает, наблюдение остановлено',
      ),
    );
    expect(v.status, Copy.cameraError);
    expect(v.context, 'Камера не отвечает, наблюдение остановлено');
    expect(v.indicator, isNot(IndicatorKind.watching));
    // Even when the controller's line still says «Слежу».
    final stale = view(const TripFacts(cameraSilent: true, watchText: 'Слежу'));
    expect(stale.status, isNot(Copy.watching));
  });

  test('S-07 the driver\'s pause wins over the camera state', () {
    final v = view(
      const TripFacts(
        userPaused: true,
        phase: TripPhase.paused,
        watchText: 'Слежу',
      ),
    );
    expect(v.indicator, IndicatorKind.paused);
    expect(v.status, Copy.paused);
  });

  test('a session that is starting is not shown as watching', () {
    final v = view(const TripFacts(phase: TripPhase.paused));
    expect(v.status, Copy.starting);
    expect(v.indicator, IndicatorKind.idle);
  });

  test('advice: after alarms, then the break time', () {
    expect(
      view(const TripFacts(watchText: 'Слежу', breakDue: true)).advice,
      Copy.adviceBreak,
    );
    expect(
      view(const TripFacts(watchText: 'Слежу', headAlarms: 1)).advice,
      Copy.adviceStop,
    );
    expect(
      view(const TripFacts(watchText: 'Слежу', eyesAlarms: 1)).advice,
      Copy.adviceStop,
    );
    expect(
      view(
        const TripFacts(watchText: 'Слежу', eyesAlarms: 2, breakDue: true),
      ).advice,
      Copy.adviceStopNow,
    );
  });

  test('the notice on top: moved phone, heat, watch, journal, note', () {
    expect(
      view(
        const TripFacts(watchText: 'Слежу', movedText: 'Телефон сдвинулся'),
      ).notice,
      'Телефон сдвинулся',
    );
    final heat = view(
      const TripFacts(
        watchText: 'Слежу',
        heatText: 'Телефон нагрелся, экономлю',
      ),
    );
    expect(heat.noticeGlyph, NsGlyph.thermo);
    final watch = view(const TripFacts(watchText: 'Слежу', watchLost: true));
    expect(watch.notice, Copy.watchLost);
    expect(watch.noticeGlyph, NsGlyph.watchOff);
    expect(
      view(const TripFacts(watchText: 'Слежу', calibrationNote: 'нота')).notice,
      'нота',
    );
  });
}
