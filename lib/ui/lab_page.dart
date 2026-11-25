import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../logic/domain.dart';
import '../services/detector.dart';
import '../services/face_source.dart';
import '../services/lab_controller.dart';
import 'components.dart';

/// Hidden developer screen (Настройки → Режим разработчика → Лаборатория).
class LabPage extends StatefulWidget {
  const LabPage({super.key, required this.create});
  final LabController Function() create;
  @override
  State<LabPage> createState() => _LabPageState();
}

class _LabPageState extends State<LabPage> with WidgetsBindingObserver {
  late final LabController lab;

  @override
  void initState() {
    super.initState();
    lab = widget.create();
    WidgetsBinding.instance.addObserver(this);
    unawaited(lab.open());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(lab.resume());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(lab.pause());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    lab.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    final files = await lab.recorder.list();
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Записей пока нет')));
      return;
    }
    final picked = await showModalBottomSheet<File>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final f in files.take(20))
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(f.uri.pathSegments.last),
                subtitle: Text('${(f.lengthSync() / 1024).round()} КБ'),
                onTap: () => Navigator.pop(context, f),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(picked.path, mimeType: 'application/x-ndjson')],
        subject: picked.uri.pathSegments.last,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Лаборатория')),
    body: SafeArea(
      child: AnimatedBuilder(
        animation: lab,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusCard(lab: lab),
            const SizedBox(height: 12),
            _Preview(lab: lab),
            const SizedBox(height: 12),
            _Controls(lab: lab, onExport: _export),
            const SizedBox(height: 12),
            _Stream(lab: lab),
            const SizedBox(height: 12),
            _Numbers(lab: lab),
            const SizedBox(height: 12),
            _Feed(lab: lab),
          ],
        ),
      ),
    ),
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.lab});
  final LabController lab;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alarm = lab.engine?.snapshot.activeEvents.isNotEmpty ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          lab.statusLine,
          style: theme.textTheme.headlineMedium?.copyWith(
            color: alarm ? theme.colorScheme.error : null,
          ),
        ),
        if (lab.prompt != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              lab.prompt!,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        if (lab.scenario != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(
              value: lab.scenario!.progress(lab.nowUs),
            ),
          ),
        if (lab.phase == LabPhase.calibrating)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(value: lab.calibrationProgress),
          ),
        if (lab.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Notice(lab.error!),
          ),
      ],
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.lab});
  final LabController lab;
  @override
  Widget build(BuildContext context) {
    final preview = lab.source?.preview();
    final result = lab.lastResults[lab.primaryEngine];
    final size = result?.imageSize;
    if (preview == null) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('Превью недоступно')),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: size == null
              ? preview
              : AspectRatio(
                  aspectRatio: size.width / size.height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      preview,
                      CustomPaint(
                        painter: _FacePainter(
                          faces: result!.faces,
                          imageSize: size,
                          mirrored: lab.source!.previewMirrored,
                          driverId: lab.calibration?.trackingId,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _FacePainter extends CustomPainter {
  _FacePainter({
    required this.faces,
    required this.imageSize,
    required this.mirrored,
    required this.driverId,
    required this.color,
  });
  final List<DetectedFace> faces;
  final Size imageSize;
  final bool mirrored;
  final int? driverId;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / imageSize.width,
        sy = size.height / imageSize.height;
    for (final face in faces) {
      var rect = Rect.fromLTRB(
        face.bounds.left * sx,
        face.bounds.top * sy,
        face.bounds.right * sx,
        face.bounds.bottom * sy,
      );
      if (mirrored) {
        rect = Rect.fromLTRB(
          size.width - rect.right,
          rect.top,
          size.width - rect.left,
          rect.bottom,
        );
      }
      final driver =
          driverId == null || face.measurement.trackingId == driverId;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(12)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = driver ? 3 : 1.5
          ..color = driver ? color : Colors.orange,
      );
    }
  }

  @override
  bool shouldRepaint(_FacePainter old) => true;
}

class _Controls extends StatelessWidget {
  const _Controls({required this.lab, required this.onExport});
  final LabController lab;
  final Future<void> Function() onExport;
  @override
  Widget build(BuildContext context) => SectionCard(
    title: 'Управление',
    icon: Icons.science_outlined,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lab.options.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SegmentedButton<String>(
              segments: [
                for (final o in lab.options)
                  ButtonSegment(value: o.id, label: Text(o.title)),
              ],
              selected: {lab.option.id},
              onSelectionChanged: lab.recording
                  ? null
                  : (value) => unawaited(
                      lab.selectEngine(
                        lab.options.firstWhere((o) => o.id == value.single),
                      ),
                    ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Движок: ${lab.option.title}'),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: lab.phase == LabPhase.stopped || lab.scenario != null
                  ? null
                  : lab.calibrate,
              icon: const Icon(Icons.center_focus_strong_outlined),
              label: const Text('Калибровка'),
            ),
            FilledButton.icon(
              onPressed: lab.scenario != null
                  ? null
                  : () => unawaited(
                      lab.recording
                          ? lab.stopRecording()
                          : lab.startRecording(),
                    ),
              icon: Icon(
                lab.recording ? Icons.stop : Icons.fiber_manual_record,
              ),
              label: Text(lab.recording ? 'Стоп' : 'Запись'),
            ),
            if (lab.scenario == null)
              MenuAnchor(
                builder: (context, controller, _) => FilledButton.tonalIcon(
                  onPressed: lab.phase == LabPhase.stopped
                      ? null
                      : () => controller.isOpen
                            ? controller.close()
                            : controller.open(),
                  icon: const Icon(Icons.record_voice_over_outlined),
                  label: const Text('Сценарий'),
                ),
                menuChildren: [
                  for (final s in Scenario.all)
                    MenuItemButton(
                      onPressed: () => unawaited(lab.startScenario(s)),
                      child: Text(s.title),
                    ),
                ],
              )
            else
              FilledButton.tonalIcon(
                onPressed: () => unawaited(lab.cancelScenario()),
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Прервать'),
              ),
            OutlinedButton.icon(
              onPressed: lab.recording ? null : () => unawaited(onExport()),
              icon: const Icon(Icons.ios_share),
              label: const Text('Экспорт'),
            ),
          ],
        ),
        if (lab.recording)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '● Запись ${lab.recordingId} · ${lab.recorder.lines} строк',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );
}

class _Stream extends StatelessWidget {
  const _Stream({required this.lab});
  final LabController lab;
  @override
  Widget build(BuildContext context) {
    final urls = lab.server.urls.where((u) => !u.contains('127.0.0.1'));
    return SectionCard(
      title: 'Поток на Mac',
      icon: Icons.wifi_tethering,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!lab.server.running)
            const Text('Сервер не запущен')
          else if (urls.isEmpty)
            const Text('Нет адреса в сети Wi-Fi. Подключите iPhone к Wi-Fi.')
          else
            for (final url in urls)
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      url,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Копировать',
                    icon: const Icon(Icons.copy),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: url)),
                  ),
                ],
              ),
          Text(
            'Откройте адрес в браузере на Mac в той же сети Wi-Fi. '
            'Передаются только числа, кадры не покидают телефон. '
            'Подключено страниц: ${lab.server.clients}',
          ),
        ],
      ),
    );
  }
}

String _n(double? v, [int digits = 1]) =>
    v == null ? '—' : v.toStringAsFixed(digits);

class _Numbers extends StatelessWidget {
  const _Numbers({required this.lab});
  final LabController lab;
  @override
  Widget build(BuildContext context) {
    final snap = lab.engine?.snapshot;
    String channel(ChannelSnapshot? c) {
      if (c == null) return '—';
      final started = c.signStartedUs;
      final timer =
          started != null &&
              (c.phase == ChannelPhase.signPresent ||
                  c.phase == ChannelPhase.warning)
          ? ' · ${((lab.nowUs - started) / 1000000).toStringAsFixed(1)} с'
          : '';
      return '${c.phase.name} (${c.reason.code})$timer';
    }

    return SectionCard(
      title: 'Числа',
      icon: Icons.analytics_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Анализов/с ${lab.analysesPerSecond.round()} · задержка конвейера '
            '${lab.lastLatencyUs == null ? '—' : '${(lab.lastLatencyUs! / 1000).round()} мс'}',
          ),
          Text('Зона: ${LabController.zoneNames[lab.attentionState.zone]}'),
          Text('Автомат глаз: ${channel(snap?.eyes)}'),
          Text('Автомат головы: ${channel(snap?.head)}'),
          if (lab.calibration != null)
            Text(
              'Калибровка: наклон ${_n(lab.calibration!.neutralPitch)}°, '
              'поворот ${_n(lab.calibration!.neutralYaw)}°, '
              'T ${_n(lab.calibration!.eyeThreshold, 2)}',
            ),
          const SizedBox(height: 8),
          for (final entry in lab.lastSignals.entries) ...[
            Text(
              entry.key,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(_signals(entry.value)),
          ],
        ],
      ),
    );
  }

  static String _signals(FaceSignals? s) {
    if (s == null) return 'лица нет';
    final parts = [
      'поворот ${_n(s.headYawLeft)}° (влево +)',
      'наклон ${_n(s.headPitchDown)}° (вниз +)',
      'крен ${_n(s.headRollRight)}° (вправо +)',
      'глаза L ${_n(s.eyeOpenLeft, 2)} / R ${_n(s.eyeOpenRight, 2)}',
      if (s.hasGaze) 'взгляд ${_n(s.gazeLeft)}° / ${_n(s.gazeDown)}°',
      if (s.distanceM != null) 'до лица ${_n(s.distanceM, 2)} м',
      if (!s.tracked) 'трекинг ненадёжен',
    ];
    return parts.join(' · ');
  }
}

class _Feed extends StatelessWidget {
  const _Feed({required this.lab});
  final LabController lab;
  @override
  Widget build(BuildContext context) => SectionCard(
    title: 'Лента',
    icon: Icons.list_alt,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lab.notes.isEmpty) const Text('Пока пусто'),
        for (final note in lab.notes.take(30))
          Text(
            '${(note.atUs / 1000000).toStringAsFixed(1)} с · ${note.text}',
            style: note.important
                ? TextStyle(color: Theme.of(context).colorScheme.error)
                : null,
          ),
      ],
    ),
  );
}

/// Engines the lab can use. Thread "ARKit" adds its sources here.
List<LabEngineOption> labEngineOptions(FaceDetectorPort Function() mlKit) => [
  LabEngineOption(
    id: 'mlkit',
    title: 'ML Kit',
    engineIds: const ['mlkit_face_detection'],
    create: () => CameraFaceSource(mlKit()),
  ),
];
