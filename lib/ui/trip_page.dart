import 'dart:async';
import 'package:flutter/material.dart';
import '../logic/domain.dart';
import '../services/trip_controller.dart';
import '../services/sleep_controller.dart';
import 'components.dart';
import 'vigilance_card.dart';

class TripPage extends StatelessWidget {
  const TripPage({super.key, required this.trip, required this.sleep});
  final TripController trip;
  final SleepController sleep;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([trip, sleep]),
    builder: (context, _) => ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        Text(
          trip.active ? 'Текущая поездка' : 'Перед поездкой',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        Text(
          trip.active
              ? 'Камера и рекомендации работают независимо.'
              : 'Закрепите телефон. Проверьте состояние и оповещение.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        if (trip.journalIncomplete) ...[
          const Notice(
            'Журнал неполный: запись в хранилище недоступна. Оповещение продолжает работать.',
            error: true,
          ),
          const SizedBox(height: 12),
        ],
        if (trip.alertError != null) ...[
          Notice(trip.alertError!, error: true),
          const SizedBox(height: 12),
        ],
        if (trip.snapshot?.activeEvents.isNotEmpty ?? false) _warning(context),
        LayoutBuilder(
          builder: (context, box) {
            final camera = _cameraCard(context);
            final rec = _recommendation(context);
            return box.maxWidth > 760
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 5, child: camera),
                      const SizedBox(width: 12),
                      Expanded(flex: 4, child: rec),
                    ],
                  )
                : Column(children: [camera, const SizedBox(height: 12), rec]);
          },
        ),
        if (trip.active && trip.phase == TripPhase.observing) ...[
          const SizedBox(height: 12),
          VigilanceCard(trip: trip),
        ],
        const SizedBox(height: 12),
        SectionCard(
          title: 'Как вы себя чувствуете?',
          icon: Icons.self_improvement,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: SelfAssessment.values
                    .map(
                      (value) => ChoiceChip(
                        label: Text(switch (value) {
                          SelfAssessment.unknown => 'Не оценивал',
                          SelfAssessment.notSleepy => 'Сонливость не ощущаю',
                          SelfAssessment.sleepy => 'Есть сонливость',
                        }),
                        selected: sleep.assessment == value,
                        onSelected: (_) => sleep.setAssessment(value),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
              const Text(
                'Ответ относится к этой поездке. Данные часов не отменяют ощущение сонливости.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (!trip.active)
          FilledButton.icon(
            key: const Key('start-trip'),
            onPressed: () => unawaited(trip.start()),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Начать поездку'),
            ),
          )
        else
          OutlinedButton.icon(
            onPressed: () => unawaited(trip.finish()),
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Padding(
              padding: EdgeInsets.all(14),
              child: Text('Завершить поездку'),
            ),
          ),
        if (trip.lastFinishedTrip != null)
          const Padding(
            padding: EdgeInsets.only(top: 14),
            child: Notice(
              'Поездка завершена. Итог и события доступны в журнале.',
            ),
          ),
        const SizedBox(height: 20),
        const Text(
          'NSControl описывает наблюдаемые признаки и не подтверждает отсутствие сонливости. Испытания выполняются только на неподвижном стенде.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );

  Widget _warning(BuildContext context) {
    final events = trip.snapshot!.activeEvents;
    final ids = events.map((e) => e.id).toSet();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xffB3261E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.white),
                SizedBox(width: 10),
                Text(
                  'Предупреждение',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...events.map(
              (e) => Text(
                e.type == EventType.eyesClosed
                    ? 'Длительное закрытие глаз. Остановитесь в безопасном месте для отдыха.'
                    : 'Продолжительный наклон головы — проверьте состояние',
                style: const TextStyle(color: Colors.white, fontSize: 17),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: trip.snapshot!.hasUnacknowledgedAlert
                  ? () => trip.acknowledge(ids)
                  : null,
              child: Text(
                trip.snapshot!.hasUnacknowledgedAlert
                    ? 'Подтвердить · выключить сигнал'
                    : 'Сигнал подтверждён',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cameraCard(BuildContext context) {
    final current = trip.snapshot;
    final label = switch (current?.cameraStatus) {
      CameraStatus.warning => 'Предупреждение',
      CameraStatus.limited => 'Наблюдение ограничено',
      CameraStatus.observing => 'Наблюдение',
      _ => switch (trip.phase) {
        TripPhase.idle => 'Камера выключена',
        TripPhase.findingFace => 'Подтверждение лица',
        TripPhase.calibrating => 'Калибровка',
        TripPhase.paused => 'Наблюдение приостановлено',
        _ => 'Наблюдение недоступно',
      },
    };
    return SectionCard(
      title: label,
      icon: Icons.center_focus_strong,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (trip.movedText != null) ...[
            Notice(trip.movedText!),
            const SizedBox(height: 12),
          ],
          if (trip.heatText != null) ...[
            Notice(trip.heatText!),
            const SizedBox(height: 12),
          ],
          if (trip.preview() case final preview?)
            if (trip.showPreview)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: 230,
                  width: double.infinity,
                  child: ColoredBox(
                    color: Colors.black,
                    // CameraPreview keeps the frame's own aspect ratio
                    // (portrait on a phone held upright); an outer
                    // AspectRatio with the controller's landscape ratio
                    // squeezed it and stretched the face.
                    child: Center(child: preview),
                  ),
                ),
              )
            else
              Notice(
                trip.settings.showPreview
                    ? 'Превью скрыто, чтобы телефон меньше грелся. Анализ продолжается.'
                    : 'Предпросмотр скрыт. Анализ камеры продолжается.',
              )
          else
            Container(
              height: 170,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.face_retouching_natural, size: 52),
                  SizedBox(height: 12),
                  Text('Локальный анализ фронтальной камеры'),
                  SizedBox(height: 4),
                  Text('Без записи фото и видео'),
                ],
              ),
            ),
          const SizedBox(height: 16),
          if (trip.error != null) ...[
            Notice(trip.error!, error: true),
            const SizedBox(height: 12),
          ],
          if (trip.cameraPermissionBlocked) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => unawaited(trip.openSettings()),
                  child: const Text('Настройки разрешений'),
                ),
                FilledButton.tonal(
                  onPressed: () => unawaited(trip.retryCamera()),
                  child: const Text('Повторить запуск'),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (trip.phase == TripPhase.findingFace) ...[
            Text(
              'Лиц в кадре: ${trip.faces.length}. Убедитесь, что в области водителя только ваше лицо.',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed:
                  trip.faces.length == 1 &&
                      trip.faces.single.measurement.trackingId != null
                  ? () => trip.confirmFace(
                      trip.faces.single.measurement.trackingId!,
                    )
                  : null,
              icon: const Icon(Icons.check),
              label: const Text('Это я · калибровать 10 секунд'),
            ),
          ],
          if (trip.phase == TripPhase.calibrating) ...[
            LinearProgressIndicator(value: trip.calibrationProgress),
            const SizedBox(height: 12),
            Text(
              trip.mountRelative
                  ? 'Смотрите на дорогу, как обычно. ${(trip.calibrationProgress * 10).floor()}/10 с · ${trip.calibrationSamples} кадров'
                  : 'Смотрите вперёд, глаза открыты. ${(trip.calibrationProgress * 10).floor()}/10 с · ${trip.calibrationSamples} пригодных измерений',
            ),
          ],
          if (trip.active && trip.engineNote != null) ...[
            Notice(trip.engineNote!),
            const SizedBox(height: 8),
          ],
          if (current != null && trip.calibrationNote != null) ...[
            Notice(trip.calibrationNote!),
            const SizedBox(height: 8),
          ],
          if (current != null) ...[
            _channel(context, 'Глаза', current.eyes),
            const SizedBox(height: 8),
            _channel(context, 'Положение головы', current.head),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () => unawaited(trip.recalibrate()),
              icon: const Icon(Icons.refresh),
              label: const Text('Держатель перемещён · калибровать'),
            ),
          ],
          if (!trip.active)
            TextButton.icon(
              onPressed: () => unawaited(trip.testAlert()),
              icon: const Icon(Icons.volume_up_outlined),
              label: const Text('Проверить звук и вибрацию'),
            ),
        ],
      ),
    );
  }

  Widget _channel(BuildContext context, String name, ChannelSnapshot channel) {
    final description = channel.available
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
    return Row(
      children: [
        Icon(
          channel.available
              ? Icons.check_circle_outline
              : Icons.remove_circle_outline,
          size: 20,
          color: channel.available
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text('$name · $description')),
      ],
    );
  }

  Widget _recommendation(BuildContext context) {
    final rec = sleep.recommendation;
    return SectionCard(
      title: 'Рекомендация отдыха',
      icon: Icons.coffee_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            rec?.message ?? 'Оценка доступных данных',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (rec != null) ...[
            const SizedBox(height: 12),
            ...rec.reasonTexts.map(
              (text) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('• $text'),
              ),
            ),
            const Divider(height: 24),
            Text(rec.dataMessage),
            const SizedBox(height: 6),
            Text(
              'Учтено сна: ${sleep.summary.duration.inHours} ч ${sleep.summary.duration.inMinutes.remainder(60)} мин',
            ),
            Text(
              'Источник: ${sleep.source ?? 'не выбран'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text('Обновление: ${localTime(sleep.lastRead)}'),
            if (!trip.active)
              TextButton.icon(
                onPressed: sleep.busy
                    ? null
                    : () => unawaited(
                        sleep.enabled ? sleep.refresh() : sleep.authorize(),
                      ),
                icon: const Icon(Icons.sync),
                label: Text(
                  sleep.enabled
                      ? 'Обновить сон перед поездкой'
                      : 'Подключить источник сна',
                ),
              ),
          ],
          const SizedBox(height: 14),
          if (!trip.active && trip.freshVitals?.bodyBattery != null) ...[
            Text('Body Battery по часам: ${trip.freshVitals!.bodyBattery}'),
            const SizedBox(height: 6),
          ],
          Text(
            'Часы: ${trip.wearableStatus}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
