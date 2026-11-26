import 'package:flutter/material.dart';

import '../../logic/domain.dart';
import '../../services/trip_controller.dart';
import '../design/ns_theme.dart';

/// Developer mode on the trip screen (architect, 25.11): the technical
/// state of each channel, the live debug address and how to mark a moment.
/// Never shown to a driver without developer mode: the main screen keeps
/// one calm line (`TripController.watchText`).
class TripDevPanel extends StatelessWidget {
  const TripDevPanel({super.key, required this.trip});
  final TripController trip;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.trip;
    final style = theme.caption(p.text2).copyWith(fontSize: 13);
    final s = trip.snapshot;
    return Container(
      key: const Key('trip-dev'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface.withValues(alpha: .9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: DefaultTextStyle(
        style: style,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (s != null) ...[
              Text('Глаза · ${channelText(s.eyes)}'),
              Text('Голова · ${channelText(s.head)}'),
            ],
            if (trip.engineNote != null) Text(trip.engineNote!),
            if (trip.error != null) Text(trip.error!),
            if (trip.debugUrls.isNotEmpty)
              SelectableText(
                'Mac: ${trip.debugUrls.first} · страниц: ${trip.debugPages}',
                style: style,
              ),
            if (trip.recording)
              Text(
                'Запись ${trip.recordingId}'
                '${trip.clips != null ? ', клипы тревог' : ''}',
              ),
            if (trip.liveDebug || trip.recording)
              const Text('Двойное касание экрана ставит метку'),
          ],
        ),
      ),
    );
  }

  /// Technical state of a channel, as the old trip card wrote it.
  static String channelText(ChannelSnapshot channel) => channel.available
      ? switch (channel.phase) {
          ChannelPhase.signPresent =>
            'Признак наблюдается, порог ещё не достигнут',
          ChannelPhase.warning => 'Предупреждение',
          ChannelPhase.recovering => 'Проверка восстановления',
          _ => 'Данные пригодны',
        }
      : switch (channel.reason) {
          ChannelReason.hiddenEyes => 'Отключён: глаза скрыты',
          ChannelReason.sideTurn => 'Поворот головы в сторону',
          ChannelReason.eyePose => 'Глаза вне рабочего ракурса',
          ChannelReason.noFace => 'Лицо не найдено',
          ChannelReason.warmingUp => 'Накопление измерений',
          ChannelReason.missingEyes => 'Нет пригодных оценок глаз',
          ChannelReason.missingAngles => 'Нет пригодных углов',
          ChannelReason.observationGap => 'Пауза более 0,3 с',
          ChannelReason.noRecentData => 'Нет новых данных более 1 с',
          _ => 'Наблюдение недоступно',
        };
}
