import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../logic/domain.dart';
import 'platform_bridge.dart';
import 'trip_controller.dart';

class SleepController extends ChangeNotifier {
  SleepController({required this.trip, required this.platform}) {
    _rules = RecommendationEngine(tripId: const Uuid().v4());
    trip.onCameraEvidence = (eyes, head) => evaluate(eyes: eyes, head: head);
    trip.onTripStarted = () {
      _rules = RecommendationEngine(tripId: trip.tripId!);
      evaluate();
    };
    trip.onTripEnded = () {
      _rules.endTrip();
      assessment = SelfAssessment.unknown;
      _rules = RecommendationEngine(tripId: const Uuid().v4());
      evaluate();
    };
    trip.onFatigueHigh = evaluate;
    trip.onVitalsChanged = evaluate;
    trip.onBreakTaken = () {
      _rules.restTaken();
      evaluate();
    };
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => evaluate());
    evaluate();
  }
  final TripController trip;
  final PlatformBridge platform;
  final _ids = const Uuid();
  late RecommendationEngine _rules;
  Timer? _timer;
  bool _disposed = false, busy = false, enabled = false;
  String statusMessage = 'Источник сна не подключён';
  String? source;
  DateTime? lastRead;
  SleepCoverage? coverage;
  SleepReadStatus readStatus = SleepReadStatus.unavailable;
  SelfAssessment assessment = SelfAssessment.unknown;
  List<SleepRecord> records = [];
  List<Map<String, Object?>> rawRecords = [];
  final Map<String, bool> _watchOrigin = {};
  final Map<String, String> _originLabels = {};
  String originLabel(SleepRecord record) =>
      _originLabels['${record.source}:${record.sourceId}'] ??
      'Устройство не определено';
  void _rememberOrigin(SleepRecord record, Object? rawDevice) {
    final device = rawDevice is Map ? rawDevice : <String, Object?>{};
    final key = '${record.source}:${record.sourceId}';
    _watchOrigin[key] = device['is_watch'] == true;
    final fields = [
      device['manufacturer'],
      device['model'],
    ].whereType<String>().where((v) => v.isNotEmpty).toList();
    _originLabels[key] =
        '${device['is_watch'] == true ? 'Часы' : 'Происхождение с часов не подтверждено'}${fields.isEmpty ? '' : ' · ${fields.join(' ')}'}';
  }

  bool get selectedWatchOriginVerified {
    final selected = records
        .where(
          (r) =>
              r.source == source &&
              r.end.isAfter(DateTime.now().subtract(const Duration(hours: 24))),
        )
        .toList();
    return selected.isNotEmpty &&
        selected.every(
          (r) => _watchOrigin['${r.source}:${r.sourceId}'] == true,
        );
  }

  late SleepSummary summary;
  Recommendation? recommendation;
  List<String> get sources =>
      records.map((r) => r.source).toSet().toList()..sort();
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    final db = trip.repository;
    if (db == null) return;
    try {
      source = await db.getSetting('sleep_source') as String?;
      enabled = await db.getSetting('sleep_enabled') == true;
      final read = await db.getSetting('sleep_last_read');
      lastRead = read is String ? DateTime.tryParse(read) : null;
      final stored = await db.getSetting('sleep_coverage');
      if (stored is Map) {
        coverage = SleepCoverage.fromJson(Map<String, dynamic>.from(stored));
      }
      await _loadRecords();
      statusMessage = enabled
          ? 'Обновите источник перед поездкой'
          : 'Источник отключён';
    } catch (e) {
      statusMessage = 'Не удалось прочитать локальный сон: $e';
    }
    evaluate();
  }

  Future<void> _loadRecords() async {
    final db = trip.repository;
    if (db == null) return;
    rawRecords = await db.listSleepRecords();
    records = rawRecords
        .map(
          (r) => SleepRecord(
            source: r['source'] as String,
            sourceId:
                '${r['provider_id']}:${r['stage']}:${r['started_at']}:${r['ended_at']}',
            start: DateTime.parse(r['started_at'] as String),
            end: DateTime.parse(r['ended_at'] as String),
            stage: SleepStage.values.byName(r['stage'] as String),
          ),
        )
        .toList();
    _watchOrigin.clear();
    for (var i = 0; i < records.length; i++) {
      final raw = rawRecords[i]['device_json'];
      final device = raw is String ? jsonDecode(raw) : raw;
      _rememberOrigin(records[i], device);
    }
  }

  void evaluate({bool eyes = false, bool? head, DateTime? at}) {
    final now = at ?? DateTime.now();
    summary = SleepNormalizer.summarize(
      records: records,
      now: now,
      selectedSource: source,
      readStatus: selectedWatchOriginVerified
          ? readStatus
          : SleepReadStatus.unavailable,
      lastSuccessfulRead: lastRead,
      coverage: coverage,
    );
    final update = _rules.evaluate(
      localNow: now,
      sleep: summary,
      assessment: assessment,
      tripStarted: trip.active,
      eyesEventOccurred: eyes,
      headEventActive: head ?? (trip.snapshot?.head.activeEvent != null),
      fatigueHigh: trip.fatigue.level == FatigueLevel.high,
      drivingTime: trip.active ? trip.drivingTime : null,
      bodyBattery: trip.freshVitals?.bodyBattery,
    );
    recommendation = update.recommendation;
    final rec = update.recommendation;
    trip.updateRecommendation(rec.message);
    if (update.changed) {
      final containsSleep = source != null && summary.recordCount > 0;
      final containsAssessment = assessment != SelfAssessment.unknown;
      final row = <String, Object?>{
        'id': rec.id,
        'trip_id': trip.tripId,
        'session_id': trip.sessionId,
        'created_at': now.toUtc().toIso8601String(),
        'created_us': trip.sessionId == null ? null : trip.sessionNowUs,
        'action': rec.action.name,
        'reasons_json': rec.reasons.map((r) => r.code).toList(),
        'inputs_json': {
          'local_hour': now.hour,
          'utc_offset_minutes': now.timeZoneOffset.inMinutes,
          if (containsSleep) 'sleep': summary.toJson(),
          if (containsAssessment) 'self_assessment': assessment.name,
          if (trip.active) 'driving_minutes': trip.drivingTime.inMinutes,
          if (trip.active) 'fatigue': trip.fatigue.toJson(),
          'body_battery': ?trip.freshVitals?.bodyBattery,
        },
        'rules_version': Recommendation.rulesVersion,
        'data_sufficient': summary.complete ? 1 : 0,
        'contains_sleep': containsSleep ? 1 : 0,
        'contains_self_assessment': containsAssessment ? 1 : 0,
      };
      trip.journal((db) => db.insertRecommendation(row));
      // The camera alert already carries its associated eye recommendation.
      if (update.shouldNotify && !eyes) {
        unawaited(
          trip.wearable.alert(
            id: rec.id,
            reason: rec.message,
            occurredUs: trip.clock.elapsedMicroseconds,
            event: false,
            kind: 'advice',
          ),
        );
      }
    }
    _notify();
  }

  void setAssessment(SelfAssessment value) {
    assessment = value;
    evaluate();
  }

  Future<void> authorize() async {
    if (busy) return;
    busy = true;
    _notify();
    try {
      final result = await platform.call('sleep.authorize');
      enabled = true;
      trip.journal((db) => db.setSetting('sleep_enabled', true));
      statusMessage =
          (result['message'] ??
                  result['reason'] ??
                  result['status'] ??
                  'Запрос доступа выполнен')
              .toString();
    } catch (e) {
      statusMessage = 'Доступ к источнику недоступен: $e';
    } finally {
      busy = false;
      _notify();
    }
    if (enabled) await refresh();
  }

  Future<void> refresh() async {
    if (busy || !enabled) return;
    busy = true;
    _notify();
    try {
      final now = DateTime.now().toUtc();
      final result = await platform.call('sleep.read', {
        'from': now.subtract(const Duration(days: 30)).toIso8601String(),
        'to': now.toIso8601String(),
      });
      if (!enabled) {
        return; // A source may be disconnected while authorization/query is pending.
      }
      final status = result['status'];
      if (status != 'available' && status != 'success') {
        readStatus = status == 'permission_required'
            ? SleepReadStatus.permissionDenied
            : status == 'unavailable'
            ? SleepReadStatus.unavailable
            : SleepReadStatus.failed;
        statusMessage =
            (result['message'] ??
                    result['reason'] ??
                    'Источник не обновлён; сохранены прежние записи.')
                .toString();
        evaluate();
        return;
      }
      final incoming = (result['records'] as List? ?? [])
          .whereType<Map>()
          .map((m) => Map<String, Object?>.from(m))
          .toList();
      // Validate the entire response before mutating history.
      final validated = <SleepRecord>[];
      for (final r in incoming) {
        final record = SleepRecord(
          source: r['source'] as String,
          sourceId:
              '${r['provider_id'] ?? r['id']}:${r['stage']}:${DateTime.parse(r['start'] as String).toUtc().toIso8601String()}:${DateTime.parse(r['end'] as String).toUtc().toIso8601String()}',
          start: DateTime.parse(r['start'] as String),
          end: DateTime.parse(r['end'] as String),
          stage: SleepStage.values.byName(r['stage'] as String),
        );
        if (!record.end.isAfter(now)) {
          validated.add(record);
          final device = r['device'];
          _rememberOrigin(record, device);
        }
      }
      final fetched =
          DateTime.tryParse(result['read_at']?.toString() ?? '') ?? now;
      final completeSnapshot = result['snapshot_complete'] == true;
      final groups = <String, List<Map<String, Object?>>>{};
      for (final r in incoming) {
        if (DateTime.parse(r['end'] as String).isAfter(now)) continue;
        final provider = (r['provider_id'] ?? r['id']).toString();
        final key = jsonEncode([r['source'], provider]);
        groups.putIfAbsent(key, () => []).add({
          'id': _ids.v4(),
          'source': r['source'],
          'started_at': r['start'],
          'ended_at': r['end'],
          'stage': r['stage'],
          'fetched_at': fetched.toIso8601String(),
          'data_json': {'source_record_id': r['id']},
          'device_json': r['device'],
          'source_modified_at': r['source_modified_at'],
        });
      }
      final snapshotSources = <String>{
        ...(result['sources'] as List? ?? []).whereType<String>(),
        ...validated.map((r) => r.source),
        if (completeSnapshot) ...records.map((r) => r.source),
        if (result['provider'] == 'health_connect' && source != null) source!,
      };
      if (completeSnapshot) {
        for (final selected in snapshotSources) {
          final sourceRows = <Map<String, Object?>>[];
          for (final entry in groups.entries) {
            final key = jsonDecode(entry.key) as List;
            if (key[0] == selected) {
              sourceRows.addAll(
                entry.value.map((row) => {...row, 'provider_id': key[1]}),
              );
            }
          }
          trip.journal(
            (db) => db.reconcileSleepWindow(
              source: selected,
              startedAt:
                  result['query_from']?.toString() ??
                  now.subtract(const Duration(days: 30)).toIso8601String(),
              endedAt: result['query_to']?.toString() ?? now.toIso8601String(),
              records: sourceRows,
              completeSnapshot: true,
            ),
          );
        }
      } else {
        for (final entry in groups.entries) {
          final key = jsonDecode(entry.key) as List;
          trip.journal(
            (db) => db.replaceSleepRecords(
              source: key[0] as String,
              providerId: key[1] as String,
              records: entry.value,
            ),
          );
        }
      }
      await trip.pendingWrites;
      // The provider response is authoritative for this calculation. A failed
      // SQLite write must not relabel the old persisted cache as freshly read.
      {
        final from =
            DateTime.tryParse(result['query_from']?.toString() ?? '') ??
            now.subtract(const Duration(days: 30));
        final to =
            DateTime.tryParse(result['query_to']?.toString() ?? '') ?? now;
        final retained = records.where(
          (r) =>
              !completeSnapshot ||
              !snapshotSources.contains(r.source) ||
              !r.end.isAfter(from) ||
              !r.start.isBefore(to),
        );
        final indexed = {
          for (final r in retained) '${r.source}:${r.sourceId}': r,
        };
        for (final r in validated) {
          indexed['${r.source}:${r.sourceId}'] = r;
        }
        records = indexed.values.toList();
      }
      source ??= sources.length == 1 ? sources.single : null;
      lastRead = fetched;
      readStatus = completeSnapshot
          ? SleepReadStatus.success
          : SleepReadStatus.unavailable;
      if (!completeSnapshot) coverage = null;
      trip.journal(
        (db) => db.setSetting('sleep_last_read', fetched.toIso8601String()),
      );
      trip.journal((db) => db.setSetting('sleep_source', source));
      statusMessage = incoming.isEmpty
          ? 'Нет доступных записей. HealthKit может не различать отсутствие сна и отказ в чтении.'
          : 'Источник обновлён. Проверьте часы, интервалы и полноту записей.';
      evaluate();
    } catch (e) {
      readStatus = SleepReadStatus.failed;
      statusMessage =
          'Ошибка обновления: $e. Кэш не используется для нового вывода о недостатке сна.';
      evaluate();
    } finally {
      busy = false;
      _notify();
    }
  }

  void selectSource(String? value) {
    source = value;
    coverage = null;
    trip.journal((db) => db.setSetting('sleep_source', value));
    trip.journal((db) => db.deleteSetting('sleep_coverage'));
    evaluate();
  }

  void confirmCoverage({required bool unrecordedSleep}) {
    if (source == null) return;
    final now = DateTime.now();
    final current = SleepNormalizer.summarize(
      records: records,
      now: now,
      selectedSource: source,
      readStatus: selectedWatchOriginVerified
          ? readStatus
          : SleepReadStatus.unavailable,
      lastSuccessfulRead: lastRead,
    );
    coverage = SleepCoverage(
      source: source!,
      start: current.windowStart,
      end: current.windowEnd,
      confirmedAt: now.toUtc(),
      hasUnrecordedSleep: unrecordedSleep,
      inputFingerprint: current.inputFingerprint,
    );
    final data = coverage!.toJson();
    trip.journal((db) => db.setSetting('sleep_coverage', data));
    evaluate(at: now);
  }

  void disconnect() {
    enabled = false;
    readStatus = SleepReadStatus.unavailable;
    coverage = null;
    statusMessage = 'Источник отключён. Дальнейшее чтение остановлено.';
    trip.journal((db) => db.setSetting('sleep_enabled', false));
    trip.journal((db) => db.deleteSetting('sleep_coverage'));
    evaluate();
  }

  Future<void> deleteLocalSleep() async {
    disconnect();
    trip.journal((db) => db.deleteSleep());
    await trip.pendingWrites;
    records = [];
    _watchOrigin.clear();
    _originLabels.clear();
    rawRecords = [];
    source = null;
    lastRead = null;
    coverage = null;
    evaluate();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
