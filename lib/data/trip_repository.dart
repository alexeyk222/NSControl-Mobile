import 'dart:convert';
import 'dart:math' as math;

import 'package:path/path.dart' as paths;
import 'package:sqflite/sqflite.dart';

typedef Row = Map<String, Object?>;

/// Local audit store. It never owns the alert path; callers handle I/O failures.
class TripRepository {
  TripRepository._(this._db);
  final Database _db;
  static const schemaVersion = 1;

  static Future<TripRepository> open({
    DatabaseFactory? factory,
    String? path,
  }) async {
    final chosen = factory ?? databaseFactory;
    final location =
        path ?? paths.join(await chosen.getDatabasesPath(), 'nscontrol.db');
    final db = await chosen.openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        singleInstance: false,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          for (final statement in _schema) {
            await db.execute(statement);
          }
        },
        onUpgrade: (db, oldVersion, newVersion) => throw StateError(
          'Unsupported schema migration $oldVersion → $newVersion',
        ),
        onDowngrade: (db, oldVersion, newVersion) =>
            throw StateError('Cannot open newer NSControl schema $oldVersion'),
      ),
    );
    return TripRepository._(db);
  }

  Future<void> close() => _db.close();

  Future<void> insertTrip(Row row) async {
    await _db.insert('trips', _normalize('trips', row));
  }

  Future<void> updateTrip(String id, Row changes) async {
    if (changes.keys.any(
      (key) => !{'ended_at', 'status', 'journal_incomplete'}.contains(key),
    )) {
      throw ArgumentError('Trip identity and start are immutable');
    }
    final count = await _db.update(
      'trips',
      _normalize('trips', changes),
      where: 'id = ?',
      whereArgs: [id],
    );
    if (count != 1) throw StateError('Unknown trip $id');
  }

  Future<void> insertSession(Row row) async {
    await _db.insert(
      'observation_sessions',
      _normalize('observation_sessions', row),
    );
  }

  /// Heartbeat captures a lower bound even when channel states do not change.
  /// Diagnostics are aggregate camera/build metrics, never images or health.
  Future<void> checkpointSession(
    String id, {
    required int atUs,
    Map<String, Object?>? diagnostics,
  }) async {
    if (atUs < 0) throw ArgumentError('Checkpoint offset must be nonnegative');
    final encoded = diagnostics == null ? null : jsonEncode(diagnostics);
    await _db.transaction((txn) async {
      final session = await _find(txn, 'observation_sessions', id);
      if (session == null || session['status'] != 'active') {
        throw StateError('Checkpoint requires an active session');
      }
      await _touchSession(txn, id, atUs);
      if (encoded != null) {
        await txn.update(
          'observation_sessions',
          {'diagnostics_json': encoded},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
  }

  Future<void> endSession(
    String id, {
    required String endedAt,
    required int endedUs,
    String reason = 'stopped',
  }) async {
    final changes = _normalize('observation_sessions', {
      'ended_at': endedAt,
      'ended_us': endedUs,
      'end_reason': reason,
      'status': 'completed',
    });
    await _db.transaction((txn) async {
      final session = await _find(txn, 'observation_sessions', id);
      if (session == null) throw StateError('Unknown session $id');
      if (session['status'] != 'active') {
        throw StateError('Session is already closed');
      }
      if (endedUs < (session['last_us'] as int)) {
        throw ArgumentError('Session ends before its last record');
      }
      await txn.update(
        'observation_sessions',
        {...changes, 'last_us': endedUs},
        where: 'id = ?',
        whereArgs: [id],
      );
      await txn.update(
        'events',
        {
          'ended_at': changes['ended_at'],
          'ended_us': endedUs,
          'end_reason': reason,
        },
        where: 'session_id = ? AND ended_us IS NULL',
        whereArgs: [id],
      );
    });
  }

  Future<void> upsertEvent(Row row) async {
    final normalized = _normalize('events', row);
    await _db.transaction((txn) async {
      final id = _requiredId(normalized);
      final previous = await _find(txn, 'events', id);
      if (previous != null) {
        _immutable(previous, normalized, [
          'id',
          'trip_id',
          'session_id',
          'type',
          'channel',
          'started_at',
          'started_us',
        ]);
        for (final key in [
          'threshold_at',
          'threshold_us',
          'alert_requested_at',
          'alert_requested_us',
          'acknowledged_at',
          'acknowledged_us',
        ]) {
          if (previous[key] != null) _immutable(previous, normalized, [key]);
        }
      }
      final merged = {...?previous, ...normalized};
      _validateEventTimes(merged);
      if (previous == null) {
        await txn.insert('events', normalized);
      } else {
        await txn.update(
          'events',
          normalized,
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      final offsets = merged.entries
          .where((entry) => entry.key.endsWith('_us'))
          .map((entry) => entry.value)
          .whereType<int>();
      await _touchSession(
        txn,
        merged['session_id'] as String,
        offsets.fold(0, math.max),
      );
    });
  }

  Future<void> insertTransition(Row row) async {
    final normalized = _normalize('state_transitions', row);
    await _db.transaction((txn) async {
      await txn.insert('state_transitions', normalized);
      await _touchSession(
        txn,
        normalized['session_id'] as String,
        normalized['at_us'] as int,
      );
    });
  }

  Future<void> upsertDelivery(Row row) async {
    final normalized = _normalize('wearable_deliveries', row);
    await _db.transaction((txn) async {
      final id = _requiredId(normalized);
      final previous = await _find(txn, 'wearable_deliveries', id);
      if (previous != null) {
        _immutable(previous, normalized, [
          'id',
          'message_id',
          'trip_id',
          'session_id',
          'event_id',
          'recommendation_id',
        ]);
      }
      final merged = {...?previous, ...normalized};
      if ((merged['event_id'] == null) ==
          (merged['recommendation_id'] == null)) {
        throw ArgumentError(
          'Delivery must reference exactly one event or recommendation',
        );
      }
      await _validateDeliveryLinks(txn, merged);
      if (previous == null) {
        await txn.insert('wearable_deliveries', normalized);
      } else {
        await txn.update(
          'wearable_deliveries',
          normalized,
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
  }

  Future<void> insertRecommendation(Row row) async {
    final normalized = _normalize('recommendations', row);
    final payload = [
      normalized['inputs_json'],
      normalized['reasons_json'],
      normalized['action'],
    ];
    normalized['contains_sleep'] =
        normalized['contains_sleep'] == 1 || _sensitive(payload, _sleepPattern)
        ? 1
        : 0;
    normalized['contains_self_assessment'] =
        normalized['contains_self_assessment'] == 1 ||
            _sensitive(payload, _assessmentPattern)
        ? 1
        : 0;
    await _db.insert('recommendations', normalized);
  }

  Future<void> upsertSleepRecord(Row row) async {
    final normalized = _normalize('sleep_records', row);
    _validateSleep(normalized);
    await _db.transaction((txn) async {
      final found = await txn.query(
        'sleep_records',
        where: 'source = ? AND provider_id = ?',
        whereArgs: [normalized['source'], normalized['provider_id']],
        limit: 1,
      );
      if (found.isEmpty) {
        await txn.insert('sleep_records', normalized);
      } else {
        if (found.length > 1) {
          throw ArgumentError(
            'Use replaceSleepRecords for a segmented provider record',
          );
        }
        await txn.update(
          'sleep_records',
          {...normalized, 'id': found.single['id']},
          where: 'id = ?',
          whereArgs: [found.single['id']],
        );
      }
    });
  }

  /// A provider sleep session can contain multiple stages. Replace the complete
  /// group, including an empty group, in one transaction to remove stale stages.
  Future<void> replaceSleepRecords({
    required String source,
    required String providerId,
    required List<Row> records,
  }) async {
    if (source.trim().isEmpty || providerId.trim().isEmpty) {
      throw ArgumentError('Sleep source and provider ID are required');
    }
    final normalized = <Row>[];
    for (final row in records) {
      if ((row['source'] != null && row['source'] != source) ||
          (row['provider_id'] != null && row['provider_id'] != providerId)) {
        throw ArgumentError('Sleep stage belongs to another provider record');
      }
      final record = _normalize('sleep_records', {
        ...row,
        'source': source,
        'provider_id': providerId,
      });
      _validateSleep(record);
      normalized.add(record);
    }
    await _db.transaction((txn) async {
      await txn.delete(
        'sleep_records',
        where: 'source = ? AND provider_id = ?',
        whereArgs: [source, providerId],
      );
      for (final row in normalized) {
        await txn.insert('sleep_records', row);
      }
    });
  }

  /// Reconcile only an explicitly complete, successful provider query. Do not
  /// call this for cached, paginated-incomplete, denied or ambiguous reads.
  Future<void> reconcileSleepWindow({
    required String source,
    required String startedAt,
    required String endedAt,
    required List<Row> records,
    required bool completeSnapshot,
  }) async {
    if (!completeSnapshot || source.trim().isEmpty) {
      throw ArgumentError(
        'Reconciliation requires a complete successful source snapshot',
      );
    }
    final start = _wallTime(startedAt), end = _wallTime(endedAt);
    if (!DateTime.parse(end).isAfter(DateTime.parse(start))) {
      throw ArgumentError('Invalid query window');
    }
    final normalized = <Row>[];
    final incomingProviders = <String>{};
    final overlappingProviders = <String>{};
    for (final row in records) {
      if (row['source'] != null && row['source'] != source) {
        throw ArgumentError('Sleep snapshot has another source');
      }
      final record = _normalize('sleep_records', {...row, 'source': source});
      _validateSleep(record);
      final provider = record['provider_id'];
      if (provider is! String || provider.isEmpty) {
        throw ArgumentError('Provider ID required');
      }
      normalized.add(record);
      incomingProviders.add(provider);
      if (DateTime.parse(
            record['started_at'] as String,
          ).isBefore(DateTime.parse(end)) &&
          DateTime.parse(
            record['ended_at'] as String,
          ).isAfter(DateTime.parse(start))) {
        overlappingProviders.add(provider);
      }
    }
    if (!overlappingProviders.containsAll(incomingProviders)) {
      throw ArgumentError('Returned sleep group does not overlap query window');
    }
    await _db.transaction((txn) async {
      final previous = await txn.query(
        'sleep_records',
        columns: ['provider_id'],
        where: 'source = ? AND started_at < ? AND ended_at > ?',
        whereArgs: [source, end, start],
      );
      final removeProviders = {
        ...incomingProviders,
        ...previous.map((row) => row['provider_id'] as String),
      };
      for (final provider in removeProviders) {
        await txn.delete(
          'sleep_records',
          where: 'source = ? AND provider_id = ?',
          whereArgs: [source, provider],
        );
      }
      for (final row in normalized) {
        await txn.insert('sleep_records', row);
      }
    });
  }

  Future<List<Row>> listTrips() =>
      _db.query('trips', orderBy: 'started_at, id');
  Future<List<Row>> listSessions({String? tripId}) =>
      _list('observation_sessions', tripId: tripId, orderBy: 'started_at, id');
  Future<List<Row>> listEvents({String? tripId, String? sessionId}) => _list(
    'events',
    tripId: tripId,
    sessionId: sessionId,
    orderBy: 'session_id, started_us, id',
  );
  Future<List<Row>> listTransitions({String? tripId, String? sessionId}) =>
      _list(
        'state_transitions',
        tripId: tripId,
        sessionId: sessionId,
        orderBy: 'session_id, at_us, rowid',
      );
  Future<List<Row>> listDeliveries({String? tripId}) =>
      _list('wearable_deliveries', tripId: tripId, orderBy: 'rowid');
  Future<List<Row>> listRecommendations({String? tripId}) =>
      _list('recommendations', tripId: tripId, orderBy: 'created_at, id');
  Future<List<Row>> listSleepRecords() =>
      _db.query('sleep_records', orderBy: 'started_at, id');

  Future<List<Row>> _list(
    String table, {
    String? tripId,
    String? sessionId,
    String? orderBy,
  }) {
    final terms = <String>[];
    final args = <Object?>[];
    if (tripId != null) {
      terms.add('trip_id = ?');
      args.add(tripId);
    }
    if (sessionId != null) {
      terms.add('session_id = ?');
      args.add(sessionId);
    }
    return _db.query(
      table,
      where: terms.isEmpty ? null : terms.join(' AND '),
      whereArgs: args,
      orderBy: orderBy,
    );
  }

  Future<void> setSetting(String key, Object? value) async {
    if (key.trim().isEmpty) throw ArgumentError('Setting key cannot be empty');
    await _db.insert('settings', {
      'key': key,
      'value_json': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Object?> getSetting(String key) async {
    final rows = await _db.query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single['value_json'] as String);
  }

  Future<void> deleteSetting(String key) async {
    await _db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  Future<void> markJournalIncomplete(String tripId, {String? sessionId}) async {
    await _db.transaction((txn) async {
      await txn.update(
        'trips',
        {'journal_incomplete': 1},
        where: 'id = ?',
        whereArgs: [tripId],
      );
      if (sessionId != null) {
        await txn.update(
          'observation_sessions',
          {'journal_incomplete': 1},
          where: 'id = ? AND trip_id = ?',
          whereArgs: [sessionId, tripId],
        );
      }
    });
  }

  /// A restart cannot measure the lost monotonic tail. Last recorded offset is
  /// a lower bound; recovery wall time is kept separately, never crash time.
  Future<int> recoverInterrupted({String? recoveredAt}) async {
    final recovery = _wallTime(
      recoveredAt ?? DateTime.now().toUtc().toIso8601String(),
    );
    return _db.transaction((txn) async {
      final sessions = await txn.query(
        'observation_sessions',
        where: "status = 'active'",
      );
      for (final session in sessions) {
        final last = session['last_us'] as int;
        await txn.update(
          'observation_sessions',
          {
            'status': 'interrupted',
            'ended_us': last,
            'ended_at': null,
            'end_reason': 'process_interrupted',
            'recovered_at': recovery,
            'journal_incomplete': 1,
          },
          where: 'id = ?',
          whereArgs: [session['id']],
        );
        await txn.update(
          'events',
          {
            'ended_us': last,
            'ended_at': null,
            'end_reason': 'process_interrupted',
          },
          where: 'session_id = ? AND ended_us IS NULL',
          whereArgs: [session['id']],
        );
        await txn.update(
          'trips',
          {'status': 'interrupted', 'journal_incomplete': 1},
          where: 'id = ?',
          whereArgs: [session['trip_id']],
        );
      }
      return sessions.length;
    });
  }

  Future<void> deleteTrip(String id) async {
    await _db.transaction((txn) async {
      await txn.delete('trips', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Conservatively removes every sleep-derived recommendation: an aggregate
  /// snapshot may combine records and need not contain a provider record ID.
  Future<void> deleteSleep({String? source}) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'sleep_records',
        where: source == null ? null : 'source = ?',
        whereArgs: source == null ? null : [source],
      );
      final recommendations = await txn.query('recommendations');
      for (final row in recommendations) {
        if (row['contains_sleep'] == 1 ||
            _sensitive([
              row['inputs_json'],
              row['reasons_json'],
            ], _sleepPattern)) {
          await txn.delete(
            'recommendations',
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }
      for (final row in await txn.query('settings')) {
        if (_sensitive([row['key'], row['value_json']], _sleepPattern)) {
          await txn.delete(
            'settings',
            where: 'key = ?',
            whereArgs: [row['key']],
          );
        }
      }
    });
  }

  Future<String> exportGeneralCsv({String? tripId}) async {
    return _db.transaction((txn) async {
      final output = <Row>[];
      for (final entry in _generalTables.entries) {
        final table = entry.key;
        final records = await txn.query(
          table,
          where: tripId == null
              ? null
              : (table == 'trips' ? 'id = ?' : 'trip_id = ?'),
          whereArgs: tripId == null ? null : [tripId],
          orderBy: 'rowid',
        );
        for (final row in records) {
          final safe = <String, Object?>{};
          for (final key in _columns[table]!) {
            final value = row[key];
            safe[key] =
                key == 'settings_json' ||
                    key == 'calibration_json' ||
                    key == 'diagnostics_json'
                ? jsonEncode(_redactSensitive(jsonDecode(value as String)))
                : value;
          }
          if (table == 'events') {
            final threshold = row['threshold_us'] as int?;
            final request = row['alert_requested_us'] as int?;
            safe['alert_request_latency_ms'] =
                threshold == null || request == null
                ? null
                : (request - threshold) / 1000;
          }
          output.add({
            'schema_version': schemaVersion,
            'row_type': entry.value,
            ...safe,
          });
        }
      }
      return _csv(_generalColumns, output);
    });
  }

  Future<String> exportSleepCsv() async => _csv(
    ['schema_version', ..._columns['sleep_records']!],
    (await listSleepRecords()).map(
      (row) => {'schema_version': schemaVersion, ...row},
    ),
  );

  Future<String> exportRecommendationsCsv({
    String? tripId,
    bool includeSensitive = false,
  }) async {
    final rows = await listRecommendations(tripId: tripId);
    return _csv(
      ['schema_version', ..._columns['recommendations']!],
      rows
          .where(
            (row) =>
                includeSensitive ||
                (row['contains_sleep'] == 0 &&
                    row['contains_self_assessment'] == 0),
          )
          .map((row) => {'schema_version': schemaVersion, ...row}),
    );
  }

  Future<Row> tripSummary(
    String tripId, {
    Map<String, int> ongoingSessionEndsUs = const {},
  }) async {
    return _db.transaction((txn) async {
      final trip = await _find(txn, 'trips', tripId);
      if (trip == null) throw StateError('Unknown trip $tripId');
      final sessions = await txn.query(
        'observation_sessions',
        where: 'trip_id = ?',
        whereArgs: [tripId],
      );
      final events = await txn.query(
        'events',
        where: 'trip_id = ?',
        whereArgs: [tripId],
      );
      final recommendations = await txn.query(
        'recommendations',
        where: 'trip_id = ?',
        whereArgs: [tripId],
      );
      final counts = <String, int>{};
      for (final event in events) {
        final type = event['type'] as String;
        counts[type] = (counts[type] ?? 0) + 1;
      }
      var observationUs = 0;
      final unavailable = <String, int>{'eyes': 0, 'head': 0, 'both': 0};
      var incomplete = trip['journal_incomplete'] == 1;
      var interrupted = 0;
      for (final session in sessions) {
        final last = session['last_us'] as int;
        final explicitEnd = ongoingSessionEndsUs[session['id']];
        if (explicitEnd != null && explicitEnd < last) {
          throw ArgumentError('Summary end precedes last logged offset');
        }
        final duration = (session['ended_us'] as int?) ?? explicitEnd ?? last;
        observationUs += duration;
        incomplete |= session['journal_incomplete'] == 1;
        if (session['status'] == 'interrupted') interrupted++;
        final transitions = await txn.query(
          'state_transitions',
          where: 'session_id = ?',
          whereArgs: [session['id']],
          orderBy: 'at_us, rowid',
        );
        var eyes = false, head = false, cursor = 0;
        void accumulate(int end) {
          final length = end - cursor;
          if (!eyes) unavailable['eyes'] = unavailable['eyes']! + length;
          if (!head) unavailable['head'] = unavailable['head']! + length;
          if (!eyes && !head) {
            unavailable['both'] = unavailable['both']! + length;
          }
          cursor = end;
        }

        for (final transition in transitions) {
          final at = (transition['at_us'] as int).clamp(0, duration);
          accumulate(at);
          final available = transition['available'] == 1;
          if (transition['channel'] == 'eyes' ||
              transition['channel'] == 'both') {
            eyes = available;
          }
          if (transition['channel'] == 'head' ||
              transition['channel'] == 'both') {
            head = available;
          }
        }
        accumulate(duration);
      }
      return {
        'trip_id': tripId,
        'event_counts': counts,
        'recommendation_count': recommendations.length,
        'recommendations': recommendations,
        'observation_us': observationUs,
        'unavailable_us': unavailable,
        'unavailable_fraction': unavailable.map(
          (key, value) =>
              MapEntry(key, observationUs == 0 ? null : value / observationUs),
        ),
        'journal_incomplete': incomplete,
        'interrupted_sessions': interrupted,
        'duration_is_lower_bound': interrupted > 0,
      };
    });
  }
}

Future<Row?> _find(DatabaseExecutor db, String table, String id) async {
  final rows = await db.query(
    table,
    where: 'id = ?',
    whereArgs: [id],
    limit: 1,
  );
  return rows.isEmpty ? null : rows.single;
}

String _requiredId(Row row) {
  final id = row['id'];
  if (id is! String || id.trim().isEmpty) {
    throw ArgumentError('Nonempty id required');
  }
  return id;
}

void _immutable(Row previous, Row changes, List<String> columns) {
  for (final key in columns) {
    if (changes.containsKey(key) && previous[key] != changes[key]) {
      throw ArgumentError('$key is immutable');
    }
  }
}

Future<void> _touchSession(DatabaseExecutor db, String id, int offset) async {
  final session = await _find(db, 'observation_sessions', id);
  if (session == null) throw StateError('Unknown session $id');
  final end = session['ended_us'] as int?;
  if (end != null && offset > end) {
    throw ArgumentError('Record exceeds closed session');
  }
  await db.rawUpdate(
    'UPDATE observation_sessions SET last_us = MAX(last_us, ?) WHERE id = ?',
    [offset, id],
  );
}

Future<void> _validateDeliveryLinks(DatabaseExecutor db, Row row) async {
  final table = row['event_id'] != null ? 'events' : 'recommendations';
  final id = (row['event_id'] ?? row['recommendation_id']) as String;
  final reference = await _find(db, table, id);
  if (reference == null) throw ArgumentError('Unknown delivery reference $id');
  for (final key in ['trip_id', 'session_id']) {
    if (row[key] != null && row[key] != reference[key]) {
      throw ArgumentError('Delivery $key differs from its reference');
    }
  }
}

void _validateEventTimes(Row row) {
  final start = row['started_us'] as int?;
  if (start == null) throw ArgumentError('Event onset required');
  final threshold = row['threshold_us'] as int?;
  final alert = row['alert_requested_us'] as int?;
  final acknowledged = row['acknowledged_us'] as int?;
  final end = row['ended_us'] as int?;
  if ((threshold != null && threshold < start) ||
      (alert != null && (threshold == null || alert < threshold)) ||
      (acknowledged != null && acknowledged < (threshold ?? start)) ||
      (end != null && end < (threshold ?? start))) {
    throw ArgumentError('Event monotonic timestamps are inconsistent');
  }
}

void _validateSleep(Row row) {
  _requiredId(row);
  final start = DateTime.parse(row['started_at'] as String);
  final end = DateTime.parse(row['ended_at'] as String);
  if (!end.isAfter(start)) throw ArgumentError('Sleep end must follow start');
}

Row _normalize(String table, Row row) {
  final allowed = _columns[table]!;
  final output = <String, Object?>{};
  for (final entry in row.entries) {
    final key = entry.key;
    var value = entry.value;
    if (!allowed.contains(key)) {
      throw ArgumentError('Unknown $table field $key');
    }
    if (value != null && key.endsWith('_at') || key == 'at' && value != null) {
      if (value is! String) throw ArgumentError('$key must be ISO 8601 text');
      value = _wallTime(value);
    } else if (value != null && key.endsWith('_us')) {
      if (value is! int || value < 0) {
        throw ArgumentError('$key must be nonnegative integer microseconds');
      }
    } else if (value != null && key.endsWith('_json')) {
      value = jsonEncode(value is String ? jsonDecode(value) : value);
    } else if (value is bool) {
      value = value ? 1 : 0;
    }
    if (value != null &&
        (key == 'id' || key.endsWith('_id')) &&
        (value is! String || value.trim().isEmpty)) {
      throw ArgumentError('$key must be a nonempty string');
    }
    if (key == 'duration_seconds' &&
        value != null &&
        (value is! num || !value.isFinite || value < 0)) {
      throw ArgumentError('duration_seconds must be finite and nonnegative');
    }
    output[key] = value;
  }
  return output;
}

String _wallTime(String value) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:?\d{2})$',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) {
    throw ArgumentError('Calendar time requires ISO 8601 and an explicit zone');
  }
  final parts = [
    for (var index = 1; index <= 6; index++) int.parse(match.group(index)!),
  ];
  final date = DateTime.utc(parts[0], parts[1], parts[2]);
  if (date.year != parts[0] ||
      date.month != parts[1] ||
      date.day != parts[2] ||
      parts[3] > 23 ||
      parts[4] > 59 ||
      parts[5] > 59) {
    throw ArgumentError('Invalid calendar date or time');
  }
  final zone = match.group(7)!;
  if (zone.toUpperCase() != 'Z') {
    final digits = zone.substring(1).replaceAll(':', '');
    if (int.parse(digits.substring(0, 2)) > 23 ||
        int.parse(digits.substring(2)) > 59) {
      throw ArgumentError('Invalid calendar zone offset');
    }
  }
  final parsed = DateTime.parse(value).toUtc();
  final iso = parsed.toIso8601String();
  // Fixed fractional width preserves chronological order for SQLite TEXT.
  return iso.length == 24 ? '${iso.substring(0, iso.length - 1)}000Z' : iso;
}

final _sleepPattern = RegExp(
  r'sleep|slumber|сон|сна|недосып|completeness|healthkit|healthconnect',
  caseSensitive: false,
);
final _assessmentPattern = RegExp(
  r'self.?assessment|self.?report|самооцен|sleepy|drowsy|сонлив',
  caseSensitive: false,
);

bool _sensitive(Object? value, RegExp pattern) =>
    pattern.hasMatch(value is String ? value : jsonEncode(value));

Object? _redactSensitive(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        if (!_sensitive(entry.key.toString(), _sleepPattern) &&
            !_sensitive(entry.key.toString(), _assessmentPattern))
          entry.key.toString(): _redactSensitive(entry.value),
    };
  }
  if (value is List) return value.map(_redactSensitive).toList();
  if (value is String &&
      (_sensitive(value, _sleepPattern) ||
          _sensitive(value, _assessmentPattern))) {
    return null;
  }
  return value;
}

String _csv(List<String> columns, Iterable<Row> rows) {
  String cell(Object? value) {
    if (value == null) return '';
    var text = value.toString();
    // Prefix strings that spreadsheet applications may interpret as formulas.
    // A leading apostrophe is also doubled, making this transport reversible.
    if (value is String &&
        RegExp(r"^(?:\s*[=+@-]|[\t\r\n]|')").hasMatch(text)) {
      text = "'$text";
    }
    if (text.contains(RegExp('[,"\r\n]'))) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }

  return '${[columns.map(cell).join(','), ...rows.map((row) => columns.map((key) => cell(row[key])).join(','))].join('\r\n')}\r\n';
}

const _generalTables = {
  'trips': 'trip',
  'observation_sessions': 'session',
  'events': 'event',
  'state_transitions': 'transition',
  'wearable_deliveries': 'wearable_delivery',
};
final _generalColumns = <String>[
  'schema_version',
  'row_type',
  ...{for (final table in _generalTables.keys) ..._columns[table]!},
  'alert_request_latency_ms',
];

const _columns = <String, List<String>>{
  'trips': ['id', 'started_at', 'ended_at', 'status', 'journal_incomplete'],
  'observation_sessions': [
    'id',
    'trip_id',
    'started_at',
    'ended_at',
    'ended_us',
    'last_us',
    'status',
    'end_reason',
    'recovered_at',
    'settings_json',
    'calibration_json',
    'detector_id',
    'detector_version',
    'algorithm_version',
    'diagnostics_json',
    'journal_incomplete',
  ],
  'events': [
    'id',
    'trip_id',
    'session_id',
    'type',
    'channel',
    'started_at',
    'started_us',
    'threshold_at',
    'threshold_us',
    'alert_requested_at',
    'alert_requested_us',
    'acknowledged_at',
    'acknowledged_us',
    'ended_at',
    'ended_us',
    'end_reason',
  ],
  'state_transitions': [
    'id',
    'trip_id',
    'session_id',
    'channel',
    'at',
    'at_us',
    'state',
    'available',
    'reason',
  ],
  'wearable_deliveries': [
    'id',
    'message_id',
    'trip_id',
    'session_id',
    'event_id',
    'recommendation_id',
    'wearable',
    'status',
    'sent_at',
    'sent_us',
    'received_at',
    'received_us',
    'error_code',
  ],
  'sleep_records': [
    'id',
    'source',
    'provider_id',
    'started_at',
    'ended_at',
    'stage',
    'duration_seconds',
    'fetched_at',
    'data_json',
    'device_json',
    'source_modified_at',
  ],
  'recommendations': [
    'id',
    'trip_id',
    'session_id',
    'created_at',
    'created_us',
    'action',
    'reasons_json',
    'inputs_json',
    'rules_version',
    'data_sufficient',
    'contains_sleep',
    'contains_self_assessment',
  ],
};

const _schema = <String>[
  '''CREATE TABLE trips (
    id TEXT PRIMARY KEY NOT NULL, started_at TEXT NOT NULL, ended_at TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','completed','interrupted')),
    journal_incomplete INTEGER NOT NULL DEFAULT 0 CHECK(journal_incomplete IN (0,1)))''',
  '''CREATE TABLE observation_sessions (
    id TEXT PRIMARY KEY NOT NULL, trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    started_at TEXT NOT NULL, ended_at TEXT, ended_us INTEGER, last_us INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','completed','interrupted')),
    end_reason TEXT, recovered_at TEXT, settings_json TEXT NOT NULL DEFAULT '{}',
    calibration_json TEXT NOT NULL DEFAULT '{}', detector_id TEXT, detector_version TEXT,
    algorithm_version TEXT, diagnostics_json TEXT NOT NULL DEFAULT '{}', journal_incomplete INTEGER NOT NULL DEFAULT 0 CHECK(journal_incomplete IN (0,1)),
    UNIQUE(id,trip_id), CHECK(ended_us IS NULL OR ended_us >= last_us))''',
  '''CREATE TABLE events (
    id TEXT PRIMARY KEY NOT NULL, trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    session_id TEXT NOT NULL, type TEXT NOT NULL, channel TEXT NOT NULL,
    started_at TEXT, started_us INTEGER NOT NULL, threshold_at TEXT, threshold_us INTEGER,
    alert_requested_at TEXT, alert_requested_us INTEGER, acknowledged_at TEXT, acknowledged_us INTEGER,
    ended_at TEXT, ended_us INTEGER, end_reason TEXT,
    FOREIGN KEY(session_id,trip_id) REFERENCES observation_sessions(id,trip_id) ON DELETE CASCADE)''',
  '''CREATE TABLE state_transitions (
    id TEXT PRIMARY KEY NOT NULL, trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    session_id TEXT NOT NULL, channel TEXT NOT NULL CHECK(channel IN ('eyes','head','both')),
    at TEXT, at_us INTEGER NOT NULL, state TEXT NOT NULL, available INTEGER NOT NULL CHECK(available IN (0,1)), reason TEXT,
    FOREIGN KEY(session_id,trip_id) REFERENCES observation_sessions(id,trip_id) ON DELETE CASCADE)''',
  '''CREATE TABLE sleep_records (
    id TEXT PRIMARY KEY NOT NULL, source TEXT NOT NULL, provider_id TEXT NOT NULL,
    started_at TEXT NOT NULL, ended_at TEXT NOT NULL, stage TEXT NOT NULL DEFAULT 'asleep',
    duration_seconds REAL, fetched_at TEXT, data_json TEXT, device_json TEXT, source_modified_at TEXT)''',
  '''CREATE TABLE recommendations (
    id TEXT PRIMARY KEY NOT NULL, trip_id TEXT REFERENCES trips(id) ON DELETE CASCADE, session_id TEXT,
    created_at TEXT NOT NULL, created_us INTEGER, action TEXT NOT NULL,
    reasons_json TEXT NOT NULL DEFAULT '[]', inputs_json TEXT NOT NULL DEFAULT '{}',
    rules_version TEXT NOT NULL, data_sufficient INTEGER NOT NULL DEFAULT 0 CHECK(data_sufficient IN (0,1)),
    contains_sleep INTEGER NOT NULL DEFAULT 0 CHECK(contains_sleep IN (0,1)),
    contains_self_assessment INTEGER NOT NULL DEFAULT 0 CHECK(contains_self_assessment IN (0,1)),
    CHECK(session_id IS NULL OR trip_id IS NOT NULL),
    FOREIGN KEY(session_id,trip_id) REFERENCES observation_sessions(id,trip_id) ON DELETE CASCADE)''',
  '''CREATE TABLE wearable_deliveries (
    id TEXT PRIMARY KEY NOT NULL, message_id TEXT UNIQUE NOT NULL,
    trip_id TEXT REFERENCES trips(id) ON DELETE CASCADE, session_id TEXT,
    event_id TEXT REFERENCES events(id) ON DELETE CASCADE,
    recommendation_id TEXT REFERENCES recommendations(id) ON DELETE CASCADE,
    wearable TEXT, status TEXT NOT NULL, sent_at TEXT, sent_us INTEGER,
    received_at TEXT, received_us INTEGER, error_code TEXT,
    CHECK((event_id IS NOT NULL) != (recommendation_id IS NOT NULL)),
    CHECK(session_id IS NULL OR trip_id IS NOT NULL),
    FOREIGN KEY(session_id,trip_id) REFERENCES observation_sessions(id,trip_id) ON DELETE CASCADE)''',
  'CREATE TABLE settings (key TEXT PRIMARY KEY NOT NULL, value_json TEXT NOT NULL)',
  'CREATE INDEX event_session_time ON events(session_id,started_us)',
  'CREATE INDEX transition_session_time ON state_transitions(session_id,at_us)',
  'CREATE INDEX recommendation_trip_time ON recommendations(trip_id,created_at)',
  'CREATE INDEX sleep_provider ON sleep_records(source,provider_id)',
];
