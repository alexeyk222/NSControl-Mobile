import 'package:flutter/material.dart';
import '../logic/domain.dart';
import '../services/trip_controller.dart';
import 'components.dart';

/// Live fatigue trends, continuous driving time and watch telemetry.
class VigilanceCard extends StatelessWidget {
  const VigilanceCard({super.key, required this.trip});
  final TripController trip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = trip.fatigue;
    final (label, color) = switch (f.level) {
      FatigueLevel.unknown => ('Накопление данных', scheme.outline),
      FatigueLevel.low => ('Признаков усталости не видно', scheme.primary),
      FatigueLevel.moderate => (
        'Умеренные признаки усталости',
        const Color(0xffB26A00),
      ),
      FatigueLevel.high => ('Выраженные признаки усталости', scheme.error),
    };
    final driving = trip.drivingTime;
    final total = trip.drive.breakAfterUs;
    final progress = (driving.inMicroseconds / total).clamp(0.0, 1.0);
    final vitals = trip.freshVitals;
    final metrics = [
      (
        'Глаза закрыты',
        f.perclos == null ? '—' : '${(f.perclos! * 100).round()} %',
      ),
      (
        'Морганий в минуту',
        f.blinksPerMinute == null ? '—' : '${f.blinksPerMinute!.round()}',
      ),
      ('Среднее моргание', f.meanBlinkMs == null ? '—' : '${f.meanBlinkMs} мс'),
      ('Долгие за 5\u00a0мин', '${f.longBlinks}'),
      ('Кивки за 5\u00a0мин', '${f.nods}'),
      ('Охват глаз', '${(f.eyeCoverage * 100).round()} %'),
    ];
    return SectionCard(
      title: 'Бдительность',
      icon: Icons.insights_outlined,
      trailing: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            key: const Key('fatigue-level'),
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: color),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, box) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (name, value) in metrics)
                  SizedBox(
                    width: (box.maxWidth - 16) / 3,
                    child: _metric(context, name, value),
                  ),
              ],
            ),
          ),
          const Divider(height: 28),
          Text(
            'Без перерыва: ${_duration(driving)}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
            color: progress >= 1 ? scheme.error : null,
          ),
          const SizedBox(height: 6),
          Text(
            progress >= 1
                ? 'Рекомендуется перерыв 15–20 минут'
                : 'До рекомендуемого перерыва: ${_duration(trip.untilBreak)}',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('mark-break'),
              onPressed: trip.markBreak,
              icon: const Icon(Icons.local_cafe_outlined),
              label: const Text('Я сделал перерыв'),
            ),
          ),
          if (vitals != null) ...[
            const Divider(height: 20),
            Row(
              children: [
                const Icon(Icons.watch_outlined, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    [
                      if (vitals.heartRate != null) 'Пульс ${vitals.heartRate}',
                      if (vitals.bodyBattery != null)
                        'Body Battery ${vitals.bodyBattery}',
                      if (vitals.stress != null) 'Стресс ${vitals.stress}',
                    ].join(' · '),
                  ),
                ),
              ],
            ),
          ],
          if (trip.watchAcknowledgedAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'Сигнал подтверждён на часах: ${localTime(trip.watchAcknowledgedAt)}',
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'Экспериментальный индикатор: показывает тенденции и не заменяет предупреждения о закрытии глаз и наклоне головы.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _metric(BuildContext context, String name, String value) => Container(
    constraints: const BoxConstraints(minHeight: 76),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: Theme.of(context).textTheme.titleMedium),
        Text(
          name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

String _duration(Duration d) => d.inHours > 0
    ? '${d.inHours} ч ${d.inMinutes.remainder(60)} мин'
    : '${d.inMinutes} мин';
