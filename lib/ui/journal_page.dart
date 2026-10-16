import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/trip_controller.dart';
import 'components.dart';

class JournalPage extends StatefulWidget {
  const JournalPage({super.key, required this.trip});
  final TripController trip;
  @override
  State<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends State<JournalPage> {
  List<Map<String, Object?>> trips = [];
  String? error;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      await widget.trip.pendingWrites;
      final db = widget.trip.repository;
      if (db == null) throw StateError('Локальная база недоступна');
      final data = await db.listTrips();
      if (mounted) {
        setState(() {
          trips = data.reversed.toList();
          busy = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          busy = false;
        });
      }
    }
  }

  Future<void> export(String kind, {String? tripId}) async {
    final db = widget.trip.repository;
    if (db == null) return;
    bool sensitive = false;
    if (kind == 'recommendations') {
      final choice = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Состав экспорта рекомендаций'),
          content: const Text(
            'Включить рекомендации, содержащие сон и самооценку? Без этого выбора они полностью исключаются из файла.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Без чувствительных данных'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Включить сон и самооценку'),
            ),
          ],
        ),
      );
      if (choice == null) return;
      sensitive = choice;
    }
    try {
      await widget.trip.pendingWrites;
      final csv = switch (kind) {
        'sleep_records' => await db.exportSleepCsv(),
        'recommendations' => await db.exportRecommendationsCsv(
          tripId: tripId,
          includeSensitive: sensitive,
        ),
        _ => await db.exportGeneralCsv(tripId: tripId),
      };
      final temp = await getTemporaryDirectory();
      final dir = Directory(
        '${temp.path}/nscontrol_export_${DateTime.now().microsecondsSinceEpoch}',
      );
      await dir.create();
      final file = File('${dir.path}/$kind.csv');
      await file.writeAsString(csv, flush: true);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: 'NSControl · $kind',
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Экспорт не выполнен: $e')));
      }
    }
  }

  Future<void> showSummary(Map<String, Object?> row) async {
    final id = row['id'] as String;
    try {
      final data = await widget.trip.repository!.tripSummary(
        id,
        ongoingSessionEndsUs: widget.trip.sessionId == null
            ? {}
            : {widget.trip.sessionId!: widget.trip.sessionNowUs},
      );
      final events = await widget.trip.repository!.listEvents(tripId: id);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (c) => SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: .7,
            minChildSize: .3,
            maxChildSize: .95,
            builder: (c, scroll) => ListView(
              controller: scroll,
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Итог поездки',
                  style: Theme.of(c).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                Text('Начало: ${localTime(row['started_at'])}'),
                Text('Завершение: ${localTime(row['ended_at'])}'),
                Text(
                  'Наблюдение: ${((data['observation_us'] as int) / 60000000).toStringAsFixed(1)} мин',
                ),
                Text('Рекомендаций: ${data['recommendation_count']}'),
                if (data['journal_incomplete'] == true ||
                    data['duration_is_lower_bound'] == true)
                  const Notice(
                    'Журнал неполный или прерван. Длительность отражает только сохранённые данные.',
                    error: true,
                  ),
                const Divider(height: 28),
                ...['eyes', 'head', 'both'].map((key) {
                  final fraction =
                      (data['unavailable_fraction'] as Map)[key] as num?;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '${switch (key) {
                        'eyes' => 'Глаза',
                        'head' => 'Голова',
                        _ => 'Оба канала',
                      }} недоступны: ${fraction == null ? '—' : '${(fraction * 100).toStringAsFixed(1)}%'}',
                    ),
                  );
                }),
                const Divider(height: 28),
                _vigilance(c, data),
                const Divider(height: 28),
                if (events.isEmpty)
                  const Text('Камерные события не зарегистрированы.'),
                ...events.map(
                  (e) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.warning_amber_rounded),
                    title: Text(
                      e['type'] == 'eyes_closed'
                          ? 'Длительное закрытие глаз'
                          : 'Продолжительный наклон головы',
                    ),
                    subtitle: Text(
                      '${localTime(e['threshold_at'])}\nОкончание: ${e['end_reason'] ?? 'событие активно'}',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => export('journal', tripId: id),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Экспортировать журнал поездки'),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Итог недоступен: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: load,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Журнал', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        const Text(
          'Поездки, сеансы наблюдения и события хранятся на этом устройстве.',
        ),
        const SizedBox(height: 20),
        SectionCard(
          title: 'Экспорт данных',
          icon: Icons.ios_share,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: () => export('journal'),
                child: const Text('Общий журнал CSV'),
              ),
              OutlinedButton(
                onPressed: () => export('sleep_records'),
                child: const Text('Отдельно: сон'),
              ),
              OutlinedButton(
                onPressed: () => export('recommendations'),
                child: const Text('Отдельно: рекомендации'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (busy) const Center(child: CircularProgressIndicator()),
        if (error != null) Notice(error!, error: true),
        if (!busy && error == null && trips.isEmpty)
          const SectionCard(
            title: 'Пока нет поездок',
            icon: Icons.route_outlined,
            child: Text(
              'После наблюдения здесь появятся события и итог. Рекомендации до поездки доступны в отдельном экспорте.',
            ),
          ),
        ...trips.map(
          (row) => Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 12,
              ),
              leading: const Icon(Icons.route_outlined),
              title: Text(localTime(row['started_at'])),
              subtitle: Text(
                '${switch (row['status']) {
                  'active' => 'В процессе',
                  'completed' => 'Завершена',
                  _ => 'Прервана',
                }}${row['journal_incomplete'] == 1 ? ' · журнал неполный' : ''}',
              ),
              onTap: () => showSummary(row),
              trailing: IconButton(
                tooltip: 'Удалить поездку',
                icon: const Icon(Icons.delete_outline),
                onPressed: row['id'] == widget.trip.tripId
                    ? null
                    : () async {
                        if (await confirmDeletion(
                          context,
                          'Будут удалены поездка, её сеансы, события, доставки и рекомендации. Ранее экспортированные файлы останутся.',
                        )) {
                          try {
                            await widget.trip.repository!.deleteTrip(
                              row['id'] as String,
                            );
                            await load();
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Удаление не выполнено: $e'),
                                ),
                              );
                            }
                          }
                        }
                      },
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _vigilance(BuildContext context, Map<String, Object?> data) {
    final minutes = (data['fatigue_per_minute'] as List? ?? []).cast<int>();
    final peak = data['fatigue_peak'] as int?;
    final scheme = Theme.of(context).colorScheme;
    Color color(int level) => switch (level) {
      3 => scheme.error,
      2 => const Color(0xffB26A00),
      1 => scheme.primary,
      _ => scheme.outlineVariant,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Бдительность', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          'Пик признаков усталости: ${switch (peak) {
            3 => 'выраженные',
            2 => 'умеренные',
            1 => 'не видны',
            _ => 'нет данных',
          }}',
        ),
        Text('Перерывов: ${data['breaks'] ?? 0}'),
        if ((data['escalations'] as int? ?? 0) > 0)
          Text('Сигнал усиливался: ${data['escalations']} раз'),
        if (minutes.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 2,
            runSpacing: 2,
            children: [
              for (final level in minutes)
                Container(
                  width: 8,
                  height: 16,
                  decoration: BoxDecoration(
                    color: color(level),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Каждый столбик — минута поездки; серый — камера не наблюдала.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
