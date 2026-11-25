import 'dart:async';
import 'package:flutter/material.dart';
import '../logic/domain.dart';
import '../services/lab_controller.dart';
import '../services/trip_controller.dart';
import '../version.dart';
import 'components.dart';
import 'lab_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.trip,
    required this.themeMode,
    required this.onTheme,
    this.developerMode = false,
    this.onDeveloperMode,
    this.createLab,
  });
  final TripController trip;
  final ThemeMode themeMode;
  final void Function(ThemeMode) onTheme;
  final bool developerMode;
  final ValueChanged<bool>? onDeveloperMode;
  final LabController Function()? createLab;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late double eyes, head, pitch, yaw, volume;
  late bool hidden, vibrate, preview, escalate;
  @override
  void initState() {
    super.initState();
    final s = widget.trip.settings;
    eyes = s.eyesClosedUs / 1000000;
    head = s.headDownUs / 1000000;
    pitch = s.pitchThreshold;
    yaw = s.headYawLimit;
    volume = s.volume;
    hidden = s.hiddenEyes;
    vibrate = s.vibration;
    preview = s.showPreview;
    escalate = s.escalate;
  }

  Widget slider(
    String title,
    double value,
    double min,
    double max,
    int divisions,
    ValueChanged<double> change,
    String unit,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$title · ${value.toStringAsFixed(unit == 'с' ? 1 : 0)} $unit'),
      Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        onChanged: (v) => setState(() => change(v)),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('Настройки', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 20),
      SectionCard(
        title: 'Пороговые параметры',
        icon: Icons.tune,
        child: Column(
          children: [
            slider('Закрытие глаз', eyes, 1, 3, 20, (v) => eyes = v, 'с'),
            slider('Наклон головы', head, 1, 5, 40, (v) => head = v, 'с'),
            slider(
              'Угол наклона вниз',
              pitch,
              10,
              35,
              25,
              (v) => pitch = v,
              '°',
            ),
            slider(
              'Допустимый поворот головы',
              yaw,
              20,
              45,
              25,
              (v) => yaw = v,
              '°',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Глаза скрыты / тёмные очки'),
              subtitle: const Text('Работает только канал головы'),
              value: hidden,
              onChanged: (v) => setState(() => hidden = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Предпросмотр камеры'),
              value: preview,
              onChanged: (v) => setState(() => preview = v),
            ),
            const Notice(
              'Изменение параметров завершает текущий сеанс. Для продолжения потребуется новая калибровка.',
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      SectionCard(
        title: 'Оповещение',
        icon: Icons.notifications_active_outlined,
        child: Column(
          children: [
            slider(
              'Громкость',
              volume * 100,
              0,
              100,
              100,
              (v) => volume = v / 100,
              '%',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Вибрация телефона'),
              value: vibrate,
              onChanged: (v) => setState(() => vibrate = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Нарастающий сигнал'),
              subtitle: const Text(
                'Если тревогу не подтвердили за 5 с — максимальная громкость и вибрация',
              ),
              value: escalate,
              onChanged: (v) => setState(() => escalate = v),
            ),
            const Text(
              'Беззвучный режим, «Не беспокоить» и настройки ОС могут ограничивать сигнал. Красное предупреждение остаётся видимым.',
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: () async {
          await widget.trip.changeSettings(
            AlgorithmSettings(
              eyesClosedUs: (eyes * 10).round() * 100000,
              headDownUs: (head * 10).round() * 100000,
              pitchThreshold: pitch.roundToDouble(),
              headYawLimit: yaw.roundToDouble(),
              volume: volume,
              vibration: vibrate,
              hiddenEyes: hidden,
              showPreview: preview,
              escalate: escalate,
            ),
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Настройки применены')),
            );
          }
        },
        child: const Padding(
          padding: EdgeInsets.all(14),
          child: Text('Применить настройки'),
        ),
      ),
      const SizedBox(height: 12),
      SectionCard(
        title: 'Оформление',
        icon: Icons.palette_outlined,
        child: Wrap(
          spacing: 8,
          children: ThemeMode.values
              .map(
                (mode) => ChoiceChip(
                  label: Text(switch (mode) {
                    ThemeMode.system => 'Системная',
                    ThemeMode.light => 'Светлая',
                    ThemeMode.dark => 'Тёмная',
                  }),
                  selected: widget.themeMode == mode,
                  onSelected: (_) => widget.onTheme(mode),
                ),
              )
              .toList(),
        ),
      ),
      const SizedBox(height: 12),
      AnimatedBuilder(
        animation: widget.trip,
        builder: (context, _) => SectionCard(
          title: 'Диагностика',
          icon: Icons.monitor_heart_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Детектор: ${widget.trip.detector.capabilities.id} ${widget.trip.detector.capabilities.version}',
              ),
              Text(
                'Алгоритм: ${ObservationEngine.algorithmVersion} · NSControl $appVersion',
              ),
              Text(
                'Завершено анализов: ${widget.trip.camera.pipeline.completed}',
              ),
              Text(
                'За последние 60 с: ${widget.trip.camera.pipeline.completedBetween(widget.trip.clock.elapsedMicroseconds - 60000000, widget.trip.clock.elapsedMicroseconds + 1)} анализов',
              ),
              Text(
                'Полные минутные интервалы сеанса: ${widget.trip.completedPerMinute.isEmpty ? 'ещё нет' : widget.trip.completedPerMinute.join(', ')}',
              ),
              Text(
                'Пропущено занятым детектором: ${widget.trip.camera.pipeline.dropped}',
              ),
              Text('Поздних результатов: ${widget.trip.camera.pipeline.stale}'),
              Text(
                'Время последнего анализа: ${widget.trip.camera.pipeline.lastDurationUs == null ? '—' : '${(widget.trip.camera.pipeline.lastDurationUs! / 1000).toStringAsFixed(1)} мс'}',
              ),
              Text(
                'Возраст результата: ${widget.trip.camera.pipeline.lastCompletedUs == null ? '—' : '${((widget.trip.clock.elapsedMicroseconds - widget.trip.camera.pipeline.lastCompletedUs!) / 1000).round()} мс'}',
              ),
              if (widget.trip.faces.length == 1) ...[
                Text(
                  'Pitch ↓ ${widget.trip.faces.single.measurement.pitchDown?.toStringAsFixed(1) ?? '—'}° · Yaw ${widget.trip.faces.single.measurement.yaw?.toStringAsFixed(1) ?? '—'}°',
                ),
                Text(
                  'Глаза L/R: ${widget.trip.faces.single.measurement.leftEye?.toStringAsFixed(2) ?? '—'} / ${widget.trip.faces.single.measurement.rightEye?.toStringAsFixed(2) ?? '—'} · порог ${widget.trip.calibration?.eyeThreshold?.toStringAsFixed(2) ?? '—'}',
                ),
              ],
              Text(
                'Усталость: ${switch (widget.trip.fatigue.level) {
                  FatigueLevel.unknown => 'нет данных',
                  FatigueLevel.low => 'не видна',
                  FatigueLevel.moderate => 'умеренная',
                  FatigueLevel.high => 'высокая',
                }} · PERCLOS ${widget.trip.fatigue.perclos == null ? '—' : '${(widget.trip.fatigue.perclos! * 100).toStringAsFixed(1)}%'}',
              ),
              Text('Часы: ${widget.trip.wearableStatus}'),
              Text(
                'Обмен с часами: ${widget.trip.wearable.connected ? (widget.trip.wearable.synchronized ? 'время синхронизировано' : 'нет синхронизации') : 'не подключены'}',
              ),
              const SizedBox(height: 12),
              const Text(
                'Контроль скорости и задержки выполняется в release на целевых устройствах. Кадры не сохраняются.',
              ),
            ],
          ),
        ),
      ),
      if (widget.onDeveloperMode != null) ...[
        const SizedBox(height: 12),
        SectionCard(
          title: 'Для разработчика',
          icon: Icons.science_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Режим разработчика'),
                subtitle: const Text(
                  'Показывает Лабораторию распознавания. На поездку не влияет.',
                ),
                value: widget.developerMode,
                onChanged: widget.onDeveloperMode,
              ),
              if (widget.developerMode && widget.createLab != null)
                AnimatedBuilder(
                  animation: widget.trip,
                  builder: (context, _) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.biotech_outlined),
                    title: const Text('Лаборатория'),
                    subtitle: Text(
                      widget.trip.active
                          ? 'Сначала завершите поездку: камера одна'
                          : 'Живые значения, поток на Mac, сценарии и запись',
                    ),
                    enabled: !widget.trip.active,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => LabPage(create: widget.createLab!),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 12),
      TextButton.icon(
        onPressed: () async {
          if (await confirmDeletion(
            context,
            'Сохранённый профиль будет удалён. Условия прошлых сеансов останутся в журнале.',
          )) {
            widget.trip.calibration = null;
            widget.trip.journal((db) => db.deleteSetting('calibration'));
            if (widget.trip.active) await widget.trip.recalibrate();
          }
        },
        icon: const Icon(Icons.delete_outline),
        label: const Text('Удалить профиль калибровки'),
      ),
      TextButton.icon(
        onPressed: widget.trip.active
            ? null
            : () => unawaited(widget.trip.testAlert()),
        icon: const Icon(Icons.volume_up_outlined),
        label: const Text('Проба текущего оповещения'),
      ),
    ],
  );
}
