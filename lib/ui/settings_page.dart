import 'dart:async';
import 'package:flutter/material.dart';
import '../logic/detection_profile.dart';
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
    String unit, {
    bool enabled = true,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$title · ${value.toStringAsFixed(unit == 'с' ? 1 : 0)} $unit'),
      Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        onChanged: enabled ? (v) => setState(() => change(v)) : null,
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
            // The tuned profile sets the thresholds; the user's ТЗ
            // thresholds apply in the ТЗ 2.2 reference.
            if (!widget.trip.tzReference)
              Notice(
                'Пороги задаёт профиль ${widget.trip.profile.id}: '
                '${widget.trip.profile.summary}. Ползунки действуют в '
                'режиме «ТЗ 2.2 (эталон)».',
              ),
            slider(
              'Закрытие глаз',
              eyes,
              1,
              3,
              20,
              (v) => eyes = v,
              'с',
              enabled: widget.trip.tzReference,
            ),
            slider(
              'Наклон головы',
              head,
              1,
              5,
              40,
              (v) => head = v,
              'с',
              enabled: widget.trip.tzReference,
            ),
            slider(
              'Угол наклона вниз',
              pitch,
              10,
              35,
              25,
              (v) => pitch = v,
              '°',
              enabled: widget.trip.tzReference,
            ),
            slider(
              'Допустимый поворот головы',
              yaw,
              20,
              45,
              25,
              (v) => yaw = v,
              '°',
              enabled: widget.trip.tzReference,
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
                'Детектор: ${widget.trip.capabilities.id} ${widget.trip.capabilities.version}',
              ),
              if (widget.trip.lastDevice case final device?)
                Text(
                  'ARKit: ${device['arkitFps']} к/с · передано ${device['sent']} · нагрев ${device['thermal']}',
                ),
              Text(
                'Алгоритм: ${ObservationEngine.algorithmVersion} · NSControl $appVersion',
              ),
              Text(
                'Завершено анализов: ${widget.trip.camera.pipeline.completed}',
              ),
              Text(
                'За последние 60 с: ${widget.trip.completedBetween(widget.trip.clock.elapsedMicroseconds - 60000000, widget.trip.clock.elapsedMicroseconds + 1)} анализов',
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
              if (widget.developerMode)
                AnimatedBuilder(
                  animation: widget.trip,
                  builder: (context, _) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Поездка: ТЗ 2.2 (эталон)'),
                    subtitle: Text(
                      'Строгая калибровка по ТЗ: телефон прямо перед лицом, '
                      'пороги ТЗ из настроек. Выключено — профиль '
                      '${DetectionProfile.current.id}: калибровка на любом '
                      'креплении, углы головы от позы «дорога», пороги '
                      'профиля. Со следующей калибровки.',
                    ),
                    value: widget.trip.tzReference,
                    onChanged: widget.trip.active
                        ? null
                        : (value) {
                            final next = value
                                ? DetectionProfile.tz22
                                : DetectionProfile.current;
                            widget.trip.profile = next;
                            widget.trip.journal(
                              (db) => db.setSetting('trip_profile', next.id),
                            );
                            setState(() {});
                          },
                  ),
                ),
              if (widget.developerMode && widget.trip.arkitFactory != null)
                AnimatedBuilder(
                  animation: widget.trip,
                  builder: (context, _) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Движок поездки'),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final engine in TripEngine.values)
                              ChoiceChip(
                                key: Key('trip-engine-${engine.name}'),
                                label: Text(engine.title),
                                selected: widget.trip.engineChoice == engine,
                                onSelected: widget.trip.active
                                    ? null
                                    : (_) {
                                        widget.trip.engineChoice = engine;
                                        widget.trip.journal(
                                          (db) => db.setSetting(
                                            'trip_engine',
                                            engine.name,
                                          ),
                                        );
                                        setState(() {});
                                      },
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'ARKit 30 к/с — основной: видит глаза на решётке. '
                          'ML Kit — запасной: на решётке только голова. '
                          'Со следующей поездки.',
                        ),
                      ],
                    ),
                  ),
                ),
              if (widget.developerMode && widget.trip.recorder != null)
                AnimatedBuilder(
                  animation: widget.trip,
                  builder: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Записывать поездку'),
                        subtitle: const Text(
                          'Числа распознавания в файл JSONL рядом с записями '
                          'Лаборатории, для разбора. Без изображений. '
                          'Со следующей поездки.',
                        ),
                        value: widget.trip.recordTrips,
                        onChanged: widget.trip.active
                            ? null
                            : (value) {
                                widget.trip.recordTrips = value;
                                widget.trip.journal(
                                  (db) =>
                                      db.setSetting('trip_recording', value),
                                );
                                setState(() {});
                              },
                      ),
                      if (widget.trip.recordTrips)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Wrap(
                            spacing: 8,
                            children: [
                              for (final (id, title) in const [
                                ('front', 'Прямо'),
                                ('vent_left', 'Решётка слева'),
                                ('vent_right', 'Решётка справа'),
                              ])
                                ChoiceChip(
                                  label: Text(title),
                                  selected: widget.trip.mountPosition == id,
                                  onSelected: widget.trip.active
                                      ? null
                                      : (_) {
                                          widget.trip.mountPosition = id;
                                          widget.trip.journal(
                                            (db) =>
                                                db.setSetting('trip_mount', id),
                                          );
                                          setState(() {});
                                        },
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
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
