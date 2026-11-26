import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/trip_controller.dart';
import '../copy.dart';
import '../design/ns_theme.dart';
import '../design/tokens.dart';
import '../presentation/trip_story.dart';
import '../widgets/buttons.dart';
import '../widgets/marks.dart';
import 'common.dart';
import 'home_screen.dart';

/// «История» (design screen 9): the trips newest first with their alarm
/// count, or the empty state; a trip opens its detail page.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.trip});
  final TripController trip;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late Future<List<TripStory>> _stories = _load();

  Future<List<TripStory>> _load() async {
    final db = widget.trip.repository;
    if (db == null) return const [];
    await widget.trip.pendingWrites;
    return TripStory.loadAll(db);
  }

  void _reload() => setState(() => _stories = _load());

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PageHeader(title: Copy.tabHistory),
            Expanded(
              child: FutureBuilder<List<TripStory>>(
                future: _stories,
                builder: (context, snap) {
                  final list = snap.data;
                  if (list == null) return const SizedBox.shrink();
                  if (list.isEmpty) return const _Empty();
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => Divider(color: p.line),
                    itemBuilder: (context, i) => _Item(
                      story: list[i],
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TripDetailPage(
                              trip: widget.trip,
                              story: list[i],
                            ),
                          ),
                        );
                        _reload();
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Text(
          Copy.hisEmpty,
          textAlign: TextAlign.center,
          style: theme.body(theme.palette.text2),
        ),
      ),
    );
  }
}

/// «Сегодня, 21:40», «Вчера, 08:05», «22 ноября, 18:30».
String dayAndTime(DateTime t, {DateTime? now}) {
  final l = t.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(l.year, l.month, l.day);
  const months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  final d = today.difference(day).inDays;
  final name = d == 0
      ? Copy.today
      : d == 1
      ? Copy.yesterday
      : '${l.day} ${months[l.month - 1]}';
  return '$name, ${clock(l)}';
}

class _Item extends StatelessWidget {
  const _Item({required this.story, required this.onTap});
  final TripStory story;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    final (mark, text) = story.active
        ? (MarkKind.ok, Copy.hisActive)
        : story.alarmCount > 0
        ? (MarkKind.alarm, Copy.hisAlarms(story.alarmCount))
        : story.partial
        ? (MarkKind.attention, Copy.hisPartial)
        : (MarkKind.ok, Copy.hisClean);
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dayAndTime(story.start),
                      style: theme.caption(p.text2),
                    ),
                    const SizedBox(height: 2),
                    Text(hoursMinutes(story.total), style: theme.heading()),
                  ],
                ),
              ),
              StatusMark(mark),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  text,
                  textAlign: TextAlign.right,
                  style: theme.caption(p.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One trip: its length, the ribbon «Как прошла поездка» with the legend,
/// what happened, «Поделиться журналом» and «Удалить поездку».
class TripDetailPage extends StatelessWidget {
  const TripDetailPage({super.key, required this.trip, required this.story});
  final TripController trip;
  final TripStory story;

  Future<void> _share(BuildContext context, bool sensitive) async {
    final db = trip.repository;
    if (db == null) return;
    final dir = await getTemporaryDirectory();
    final stamp = story.start.toLocal().toIso8601String().substring(0, 16);
    final general = File('${dir.path}/nscontrol-$stamp.csv')
      ..writeAsStringSync(await db.exportGeneralCsv(tripId: story.id));
    final rec = File('${dir.path}/nscontrol-$stamp-advice.csv')
      ..writeAsStringSync(
        await db.exportRecommendationsCsv(
          tripId: story.id,
          includeSensitive: sensitive,
        ),
      );
    await SharePlus.instance.share(
      ShareParams(files: [XFile(general.path), XFile(rec.path)]),
    );
  }

  Future<void> _askShare(BuildContext context) async {
    final theme = NsTheme.of(context);
    final sensitive = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: theme.palette.surface,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NsButton.secondary(
                Copy.hisExportPlain,
                onPressed: () => Navigator.pop(context, false),
              ),
              const SizedBox(height: 10),
              NsButton.secondary(
                Copy.hisExportSensitive,
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (sensitive == null || !context.mounted) return;
    await _share(context, sensitive);
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await confirmDelete(
      context,
      title: Copy.hisDelete,
      body: Copy.hisDeleteConfirm,
      action: Copy.delete,
    );
    if (!ok || !context.mounted) return;
    trip.journal((db) => db.deleteTrip(story.id));
    await trip.pendingWrites;
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PageHeader(title: '', back: Copy.tabHistory),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                children: [
                  Text(
                    '${dayAndTime(story.start)} – ${clock(story.end)}',
                    style: theme.caption(p.text2),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${hoursMinutes(story.total)} ${Copy.sumOnRoad}',
                    style: theme.title(),
                  ),
                  const SizedBox(height: 24),
                  Text(Copy.hisTimeline, style: theme.caption(p.text)),
                  const SizedBox(height: 10),
                  TripRibbon(story: story),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(clock(story.start), style: theme.caption(p.text2)),
                      const Spacer(),
                      Text(clock(story.end), style: theme.caption(p.text2)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const _Legend(),
                  const SizedBox(height: 20),
                  ...storyLines(story),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Column(
                children: [
                  NsButton.secondary(
                    Copy.hisExport,
                    onPressed: trip.repository == null
                        ? null
                        : () => _askShare(context),
                  ),
                  NsButton.text(
                    Copy.hisDelete,
                    onPressed: story.active ? null : () => _delete(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What happened in a trip, as marked lines (summary and detail).
List<Widget> storyLines(TripStory s, {NsPalette? palette}) {
  final reasons = [
    if (s.eyesAlarms > 0) Copy.reasonEyesPast,
    if (s.headAlarms > 0) Copy.reasonHeadPast,
  ].join(', ');
  return [
    if (s.alarmCount > 0)
      MarkedLine(
        mark: MarkKind.alarm,
        text: Copy.sumAlarms(s.alarmCount, reasons),
        palette: palette,
      )
    else
      MarkedLine(mark: MarkKind.ok, text: Copy.sumClean, palette: palette),
    if (s.unseen >= const Duration(minutes: 1))
      MarkedLine(
        mark: MarkKind.attention,
        text: Copy.sumUnseen(hoursMinutes(s.unseen)),
        palette: palette,
      ),
    if (s.partial)
      MarkedLine(
        mark: MarkKind.attention,
        text: Copy.sumPartial,
        palette: palette,
      ),
  ];
}

/// The ribbon: watching in the accent, not seen hatched yellow, pause
/// grey, alarms as white bars across (never red outside the alarm).
class TripRibbon extends StatelessWidget {
  const TripRibbon({super.key, required this.story, this.height = 22});
  final TripStory story;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = NsTheme.of(context).palette;
    return Semantics(
      label: '${Copy.hisTimeline}: ${Copy.hisAlarms(story.alarmCount)}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CustomPaint(
          size: Size(double.infinity, height),
          painter: _RibbonPainter(story, p),
        ),
      ),
    );
  }
}

class _RibbonPainter extends CustomPainter {
  _RibbonPainter(this.story, this.p);
  final TripStory story;
  final NsPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = p.track);
    for (final s in story.segments) {
      final rect = Rect.fromLTRB(
        s.from * size.width,
        0,
        s.to * size.width,
        size.height,
      );
      switch (s.kind) {
        case StoryKind.watching:
          canvas.drawRect(rect, Paint()..color = p.accent);
        case StoryKind.pause:
          canvas.drawRect(rect, Paint()..color = p.pause);
        case StoryKind.unseen:
          _hatch(canvas, rect, p.attention);
      }
    }
    final bar = Paint()..color = p.text;
    for (final a in story.alarms) {
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(a * size.width, size.height / 2),
          width: 3,
          height: size.height + 6,
        ),
        bar,
      );
    }
  }

  void _hatch(Canvas canvas, Rect rect, Color c) {
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawRect(rect, Paint()..color = c.withValues(alpha: .25));
    final line = Paint()
      ..color = c
      ..strokeWidth = 2;
    for (var x = rect.left - rect.height; x < rect.right; x += 6) {
      canvas.drawLine(
        Offset(x, rect.bottom),
        Offset(x + rect.height, rect.top),
        line,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RibbonPainter old) => old.story != story || old.p != p;
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    Widget item(Widget swatch, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        swatch,
        const SizedBox(width: 6),
        Text(label, style: theme.caption(p.text2)),
      ],
    );
    Widget box(Color c) => Container(
      width: 14,
      height: 10,
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(2),
      ),
    );
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        item(box(p.accent), Copy.legendWatching),
        item(box(p.attention.withValues(alpha: .6)), Copy.legendUnseen),
        item(Container(width: 3, height: 14, color: p.text), Copy.legendAlarm),
        item(box(p.pause), Copy.legendPause),
      ],
    );
  }
}
