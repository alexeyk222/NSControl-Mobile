import 'dart:async';
import 'package:flutter/material.dart';
import '../services/sleep_controller.dart';
import '../services/trip_controller.dart';
import '../logic/domain.dart';
import 'components.dart';
import 'sleep_week_card.dart';

class IntegrationsPage extends StatefulWidget {
  const IntegrationsPage({super.key, required this.sleep, required this.trip});
  final SleepController sleep;
  final TripController trip;
  @override
  State<IntegrationsPage> createState() => _IntegrationsPageState();
}

class _IntegrationsPageState extends State<IntegrationsPage> {
  bool connecting = false;
  Future<void> connect([String? id]) async {
    setState(() => connecting = true);
    await widget.trip.connectWearable(deviceId: id);
    if (mounted) setState(() => connecting = false);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.sleep, widget.trip]),
    builder: (context, _) {
      final sleep = widget.sleep;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Сон и часы', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 20),
          SectionCard(
            title: 'Оповещение на запястье',
            icon: Icons.watch_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.trip.wearableStatus),
                const SizedBox(height: 8),
                Text(
                  widget.trip.wearable.synchronized
                      ? 'Обмен временем установлен'
                      : 'Вибрация требует актуального обмена с приложением часов',
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: connecting ? null : () => unawaited(connect()),
                  icon: const Icon(Icons.bluetooth_searching),
                  label: Text(connecting ? 'Подключение…' : 'Подключить часы'),
                ),
                ...widget.trip.wearableDevices.map(
                  (d) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      d['action'] == true ? Icons.add_link : Icons.watch,
                    ),
                    title: Text(d['name']?.toString() ?? d['id'].toString()),
                    subtitle: Text(
                      d['action'] == true
                          ? 'Откроется Garmin Connect'
                          : d['connected'] == true
                          ? 'Связь установлена'
                          : 'Устройство сопряжено',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => unawaited(connect(d['id'].toString())),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Откройте NSControl на Apple Watch SE или Garmin fēnix 7X. Ответ приложения часов подтверждает приём команды, а не физическую вибрацию. На Garmin кнопка START подтверждает тревогу; часы раз в минуту передают пульс, Body Battery и стресс.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Сведения о завершённом сне',
            icon: Icons.bedtime_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Notice(
                  sleep.statusMessage,
                  error: sleep.enabled && sleep.readStatus.name == 'failed',
                ),
                const SizedBox(height: 16),
                Text(
                  'Учтено за последние 24 часа',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                Text(
                  '${sleep.summary.duration.inHours} ч ${sleep.summary.duration.inMinutes.remainder(60)} мин',
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                Text(
                  sleep.summary.complete
                      ? 'Полнота подтверждена'
                      : 'Недостаточно данных для оценки сна',
                ),
                const SizedBox(height: 10),
                Text('Успешное чтение: ${localTime(sleep.lastRead)}'),
                const SizedBox(height: 10),
                Notice(
                  sleep.selectedWatchOriginVerified
                      ? 'Источник указывает, что записи получены с часов. Точную модель сверяйте с приложением поставщика.'
                      : 'Происхождение с часов не подтверждено или источник содержит записи другого устройства. Полнота для рекомендации не подтверждается.',
                ),
                if (sleep.sources.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: sleep.sources.contains(sleep.source)
                        ? sleep.source
                        : null,
                    decoration: const InputDecoration(
                      labelText: 'Приоритетный источник',
                      border: OutlineInputBorder(),
                    ),
                    isExpanded: true,
                    items: sleep.sources
                        .map(
                          (s) => DropdownMenuItem(
                            value: s,
                            child: Text(s, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: sleep.selectSource,
                  ),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: sleep.busy
                          ? null
                          : () => unawaited(
                              sleep.enabled
                                  ? sleep.refresh()
                                  : sleep.authorize(),
                            ),
                      icon: Icon(sleep.enabled ? Icons.sync : Icons.lock_open),
                      label: Text(
                        sleep.busy
                            ? 'Чтение…'
                            : sleep.enabled
                            ? 'Обновить сон'
                            : 'Разрешить чтение сна',
                      ),
                    ),
                    if (sleep.enabled)
                      OutlinedButton(
                        onPressed: sleep.disconnect,
                        child: const Text('Отключить источник'),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                const Text(
                  'iPhone читает HealthKit. Для Huawei проверяется Garmin Connect → Health Connect; если сервис недоступен, приложение покажет это явно. Синхронизация у поставщика может требовать сеть.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SleepWeekCard(
            week: SleepWeek.build(
              records: sleep.records,
              source: sleep.source,
              now: DateTime.now(),
            ),
            source: sleep.source,
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Проверка полноты',
            icon: Icons.fact_check_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Проверьте, что выбранный источник охватывает всё окно ${localTime(sleep.summary.windowStart)} — ${localTime(sleep.summary.windowEnd)}.',
                ),
                const SizedBox(height: 10),
                const Text(
                  'Был ли сон, который часы не записали? Подтверждение относится к указанному окну и этим записям; при изменении данных или сдвиге окна оно проверяется заново.',
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonal(
                      onPressed:
                          sleep.source == null ||
                              !sleep.enabled ||
                              !sleep.selectedWatchOriginVerified
                          ? null
                          : () => sleep.confirmCoverage(unrecordedSleep: false),
                      child: const Text('Нет, весь сон записан'),
                    ),
                    OutlinedButton(
                      onPressed: sleep.source == null
                          ? null
                          : () => sleep.confirmCoverage(unrecordedSleep: true),
                      child: const Text('Да / не уверен'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Локальная история',
            icon: Icons.history,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (sleep.records.isEmpty)
                  const Text('Завершённые записи ещё не получены.'),
                ...sleep.records.reversed
                    .take(30)
                    .map(
                      (r) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${localTime(r.start)} → ${localTime(r.end)}',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            Text(
                              '${switch (r.stage.name) {
                                'awake' => 'Бодрствование',
                                'inBed' => 'В постели, сон не подтверждён',
                                _ => 'Сон',
                              }} · ${r.source}',
                            ),
                            Text(sleep.originLabel(r)),
                          ],
                        ),
                      ),
                    ),
                if (sleep.records.length > 30)
                  Text(
                    'Показаны последние 30 из ${sleep.records.length} интервалов. Полная история доступна в экспорте.',
                  ),
                TextButton.icon(
                  onPressed: sleep.records.isEmpty
                      ? null
                      : () async {
                          if (await confirmDeletion(
                            context,
                            'Будут удалены локальные записи сна и рекомендации с их снимками. Данные поставщика и ранее экспортированные файлы не изменятся.',
                          )) {
                            await sleep.deleteLocalSleep();
                          }
                        },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Удалить локальные сведения о сне'),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
