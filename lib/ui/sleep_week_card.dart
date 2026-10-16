import 'package:flutter/material.dart';
import '../logic/domain.dart';
import 'components.dart';

const _weekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

/// Seven nights of the selected source with a 7 h reference line.
class SleepWeekCard extends StatelessWidget {
  const SleepWeekCard({super.key, required this.week, required this.source});
  final SleepWeek week;
  final String? source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    const maxHours = 10.0, chartHeight = 120.0;
    const targetY = chartHeight * 7 / maxHours;
    final average = week.average;
    final spread = week.onsetSpreadMinutes;
    return SectionCard(
      title: 'Сон за неделю',
      icon: Icons.bar_chart_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (source == null)
            const Text('Выберите источник сна, чтобы увидеть неделю.')
          else ...[
            SizedBox(
              height: chartHeight + 22,
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 26,
                    bottom: 22 + targetY,
                    child: Container(height: 1, color: scheme.outline),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 22 + targetY - 7,
                    child: Text('7 ч', style: text.labelSmall),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final night in week.nights)
                        Expanded(child: _bar(context, night, chartHeight)),
                      const SizedBox(width: 26),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              average == null
                  ? 'Нет записанных ночей за 7 дней'
                  : 'В среднем ${_hm(average)}',
              style: text.titleSmall,
            ),
            if (average != null)
              Text('Записано ночей: ${week.recorded.length} из 7'),
            if (average != null) ...[
              const SizedBox(height: 4),
              Text(
                week.debt == Duration.zero
                    ? 'По записанным ночам недобора до 7 ч нет'
                    : 'Недобор до 7 ч по записанным ночам: ${_hm(week.debt)}',
              ),
            ],
            if (spread != null) ...[
              const SizedBox(height: 4),
              Text('Разброс времени засыпания: ±$spread мин'),
            ],
            const SizedBox(height: 10),
            Text(
              'Справочно: ночи без записей не считаются нулевыми и в оценку не входят. Недельная картина не меняет рекомендацию перед поездкой.',
              style: text.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _bar(BuildContext context, SleepNight night, double chartHeight) {
    final scheme = Theme.of(context).colorScheme;
    final hours = (night.duration?.inMinutes ?? 0) / 60;
    final height = night.hasData
        ? (chartHeight * (hours / 10).clamp(0.02, 1.0))
        : 6.0;
    final color = !night.hasData
        ? scheme.outlineVariant
        : hours >= 7
        ? scheme.primary
        : const Color(0xffB26A00);
    return Tooltip(
      message: night.hasData
          ? '${_weekdays[night.day.weekday - 1]} ${night.day.day}: ${_hm(night.duration!)}'
          : night.inBedOnly
          ? 'Есть запись «в постели» без стадий сна'
          : 'Нет данных',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            height: height,
            margin: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 18,
            child: Text(
              _weekdays[night.day.weekday - 1],
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}

String _hm(Duration d) =>
    '${d.inHours}\u00a0ч\u00a0${d.inMinutes.remainder(60)}\u00a0мин';
