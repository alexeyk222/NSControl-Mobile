# Хранилище и форматы NSControl

`lib/data/trip_repository.dart`, схема SQLite **1**. `Row = Map<String, Object?>`.
Все идентификаторы предоставляет вызывающая сторона; они неизменны. Времена
`*_at` и `at` — ISO 8601 с явной зоной. Они нормализуются в UTC с шестью
знаками дробной секунды для корректной сортировки в SQLite. Нативные строки
с точностью до наносекунд (до девяти знаков дробной секунды) принимаются
с усечением до микросекунд, без округления. Времена `*_us` — целые
неотрицательные микросекунды от начала соответствующего сеанса. `null` означает
неприменимое/неизвестное значение; CSV содержит пустое поле.

## API

```dart
final db = await TripRepository.open(factory: factory, path: path);
await db.insertTrip(row);
await db.updateTrip(id, changes);
await db.insertSession(row);
await db.checkpointSession(id, atUs: offset, diagnostics: metrics);
await db.endSession(id, endedAt: utcIso, endedUs: offset, reason: 'stopped');
await db.upsertEvent(row);
await db.insertTransition(row);
await db.upsertDelivery(row);
await db.insertRecommendation(row);
await db.upsertSleepRecord(row);
await db.listTrips();
await db.listSessions(tripId: id);
await db.listEvents(tripId: id, sessionId: sessionId);
await db.listTransitions(tripId: id, sessionId: sessionId);
await db.listDeliveries(tripId: id);
await db.listRecommendations(tripId: id);
await db.listSleepRecords();
await db.setSetting(key, jsonValue);
await db.getSetting(key);
await db.deleteSetting(key);
await db.markJournalIncomplete(tripId, sessionId: sessionId);
await db.recoverInterrupted(recoveredAt: utcIso);
await db.deleteTrip(id);
await db.deleteSleep(source: source); // без source удаляются все локальные сведения о сне
await db.exportGeneralCsv(tripId: id);
await db.exportSleepCsv();
await db.exportRecommendationsCsv(tripId: id, includeSensitive: false);
await db.tripSummary(id, ongoingSessionEndsUs: {sessionId: offset});
await db.close();
```

Все методы асинхронные и возвращают `Future`. Операции вставки, обновления,
удаления и закрытия возвращают `Future<void>`; методы получения списков —
`Future<List<Row>>`; экспорт — `Future<String>`; `getSetting` — `Future<Object?>`;
`recoverInterrupted` — число восстановленных прерванных сеансов;
`tripSummary` — `Future<Row>`. Если необязательный фильтр не задан, выбираются
все записи. Поля JSON принимают строки JSON, словари `Map` или списки `List`
и возвращаются в виде сохранённых строк JSON. Методы `setSetting` и
`getSetting` автоматически кодируют и декодируют JSON.

По умолчанию используется sqflite и файл `getDatabasesPath()/nscontrol.db`.
В тестах передаются `databaseFactoryFfi` и `inMemoryDatabasePath`, чтобы
проверять реальную SQLite в памяти.

## Записи таблиц

Обязательные значения отмечены `!`; остальные можно не указывать.
Неописанные поля отклоняются: опечатка в имени поля журнала не должна
приводить к незаметной потере данных.

- `trips`: `id!`, `started_at!`, `ended_at`, `status`
  (`active` / `completed` / `interrupted`), `journal_incomplete` (0/1).
- `observation_sessions`: `id!`, `trip_id!`, `started_at!`, `ended_at`,
  `ended_us`, `last_us` (по умолчанию 0), `status`, `end_reason`, `recovered_at`,
  `settings_json` (по умолчанию `{}`), `calibration_json` (по умолчанию `{}`),
  `detector_id`, `detector_version`, `algorithm_version`, `diagnostics_json`
  (по умолчанию `{}`), `journal_incomplete`. Настройки, калибровка, сведения
  о детекторе и алгоритме фиксируются при вставке и затем не изменяются.
- `events`: `id!`, `trip_id!`, `session_id!`, `type!`, `channel!`, `started_at`,
  `started_us!`, `threshold_at`, `threshold_us`, `alert_requested_at`,
  `alert_requested_us`, `acknowledged_at`, `acknowledged_us`, `ended_at`,
  `ended_us`, `end_reason`. При вставке или обновлении сохраняются неизменными
  идентификатор, связи с поездкой и сеансом, тип, канал и начало признака.
  Можно добавить последующие отметки и обновить окончание события.
  Уже записанные отметки порога, запроса оповещения и подтверждения неизменны.
- `state_transitions`: `id!`, `trip_id!`, `session_id!`, `channel!`
  (`eyes`, `head` или `both`), `at`, `at_us!`, `state!`, `available!` (0/1),
  `reason`. Записи переходов только добавляются, без последующего изменения.
- `wearable_deliveries`: `id!`, `message_id!`, `trip_id`, `session_id`,
  `event_id`, `recommendation_id`, `wearable`, `status!`, `sent_at`, `sent_us`,
  `received_at`, `received_us`, `error_code`. Требуется ровно одна ссылка:
  на событие или на рекомендацию. При обновлении неизменны идентификатор
  записи, идентификатор сообщения и все связи. Тело сообщения, причины
  рекомендаций, сон и самооценка здесь не хранятся. Поля `received_*`
  фиксируют приём приложением часов, а не физическую вибрацию.
- `sleep_records`: `id!`, `source!`, `provider_id!`, `started_at!`, `ended_at!`,
  `stage` (по умолчанию `asleep`), `duration_seconds`, `fetched_at`, `data_json`.
  Сочетание источника и идентификатора поставщика определяет одну группу
  исходных данных; для стадий используется групповой API, описанный ниже.
  При обновлении одиночной записи сохраняется её исходный локальный ID.
- `recommendations`: `id!`, `trip_id`, `session_id`, `created_at!`, `created_us`,
  `action!`, `reasons_json` (по умолчанию `[]`), `inputs_json` (по умолчанию `{}`),
  `rules_version!`, `data_sufficient` (0/1), `contains_sleep` (0/1),
  `contains_self_assessment` (0/1). Признаки чувствительности определяются
  консервативно по входам и причинам, а также по флагам вызывающей стороны.
  Переданный ложный флаг не отменяет обнаруженный чувствительный снимок.
- `settings`: `key`, `value_json`. Профиль калибровки удаляется вызовом
  `deleteSetting('calibration')`; неизменные снимки уже созданных сеансов
  сохраняются как контекст журнала. Настройки и снимки, относящиеся ко сну,
  удаляются методом `deleteSleep`.

Методы `upsertEvent` и `insertTransition` атомарно продвигают `last_us` сеанса.
Проверяются все связи, в том числе принадлежность сеанса указанной поездке.
Удаление выполняется транзакционно с каскадами внешних ключей. Исключения
передаются контроллеру; немедленное оповещение должно предшествовать
асинхронной записи журнала. Если сама SQLite недоступна, контроллер сохраняет
предупреждение о неполном журнале в оперативной памяти.

## Стадии одной записи сна

`replaceSleepRecords({required String source, required String providerId,
required List<Row> records})` атомарно заменяет все стадии исходной записи,
включая удаление старой группы при пустом списке. В строках можно опустить
`source` и `provider_id` — они берутся из аргументов. Конфликтующие значения
отклоняются. `id` каждой стадии уникален. Дополнительные поля сна:
`device_json` (минимальные сведения о часах), `source_modified_at` (время
изменения поставщиком). `upsertSleepRecord` обновляет одиночную запись по
сочетанию `source` и `provider_id`, сохраняя её локальный ID; для многостадийной
записи нужно использовать групповую замену.

`reconcileSleepWindow({required String source, required String startedAt,
required String endedAt, required List<Row> records,
required bool completeSnapshot})` принимает полный успешный снимок одного
источника. Группы, пересекающие окно `[startedAt, endedAt)`, заменяются; записи
других источников и история вне окна сохраняются. `completeSnapshot: false`
отклоняется без изменений. Нельзя использовать для неполной страницы, ошибки,
кэша или неразличимого отказа HealthKit; в этих случаях допустимо только
обновление фактически полученных групп. Стадии группы могут выходить за окно,
но хотя бы одна должна с ним пересекаться.

## Итог поездки и прерывание

`tripSummary` возвращает `trip_id`, `event_counts` (числа по типу камерного
события), `recommendation_count`, `recommendations`, `observation_us`,
`unavailable_us` и `unavailable_fraction` с ключами `eyes`, `head`, `both`,
`journal_incomplete`, `interrupted_sessions`, `duration_is_lower_bound`.
Рекомендации не входят в счётчик камерных событий. До первого перехода канал
считается недоступным. Повтор одного состояния не создаёт новый интервал.
`both` — время одновременной недоступности обоих каналов: пересечение уже
объединённых интервалов. Доли имеют знаменатель длительность всех сеансов;
при нуле возвращается `null`. Паузу между сеансами не выдаём за наблюдение.

Для активного сеанса можно передать актуальное смещение в
`ongoingSessionEndsUs`; иначе используется последнее записанное смещение.
После сбоя процесс не знает потерянный хвост монотонной шкалы:
`recoverInterrupted` ставит `interrupted`, `journal_incomplete=1`,
`ended_us=last_us`, оставляет `ended_at` пустым и записывает `recovered_at`
отдельно. Поэтому длительность прерванной поездки — нижняя граница, а не
фактическое время аварии. Открытые события завершаются причиной
`process_interrupted`; повторный вызов восстановления не изменяет уже обработанные сеансы.

## CSV

Кодировка при сохранении — UTF-8, разделитель запятая, строки CRLF, числа с
точкой. `null` экспортируется пустым полем. Кавычки удваиваются, поля с
запятой, кавычками или переводами строки заключаются в кавычки. CSV передаётся
в системное меню «Поделиться» пользовательским интерфейсом; репозиторий возвращает строку.

Для защиты от формул текстовое поле, начинающееся с `=`, `+`, `-`, `@`
(включая предварительные пробелы), табуляции, CR/LF или апострофа, получает один
дополнительный апостроф. Это обратимое транспортное экранирование: при
программном чтении CSV удалить ровно один первый апостроф у начинающихся
с него значений. Исходный апостроф удваивается. Числовые поля не изменяются;
исходные значения в SQLite тоже не изменяются.

Общий CSV содержит только типы `trip`, `session`, `event`, `transition`,
`wearable_delivery`. Используется фиксированный набор колонок, а не
универсальный дамп таблиц. Содержимое рекомендаций и сна не присоединяется
даже к доставке с `recommendation_id`. Защитная очистка JSON сеанса исключает
ключи/значения сна и самооценки; штатные снимки содержат только настройки
камерного алгоритма и калибровку.

Полный порядок колонок общего CSV:

```text
schema_version,row_type,id,started_at,ended_at,status,journal_incomplete,trip_id,ended_us,last_us,end_reason,recovered_at,settings_json,calibration_json,detector_id,detector_version,algorithm_version,diagnostics_json,session_id,type,channel,started_us,threshold_at,threshold_us,alert_requested_at,alert_requested_us,acknowledged_at,acknowledged_us,at,at_us,state,available,reason,message_id,event_id,recommendation_id,wearable,sent_at,sent_us,received_at,received_us,error_code,alert_request_latency_ms
```

`alert_request_latency_ms = (alert_requested_us - threshold_us)/1000` —
внутренний показатель до запроса; он не подтверждает слышимый звук.

Отдельный `sleep_records.csv`:

```text
schema_version,id,source,provider_id,started_at,ended_at,stage,duration_seconds,fetched_at,data_json,device_json,source_modified_at
```

Отдельный `recommendations.csv`:

```text
schema_version,id,trip_id,session_id,created_at,created_us,action,reasons_json,inputs_json,rules_version,data_sufficient,contains_sleep,contains_self_assessment
```

Без `includeSensitive: true` целиком исключаются рекомендации со сном или
самооценкой, включая действие и тексты причин. Признаки чувствительности
автоматически повышаются по ключам и содержимому минимального снимка/причин;
переданный ложный флаг не отменяет обнаруженную чувствительность.
`deleteSleep` удаляет все рекомендации со снимками сна и их доставки,
а также настройки полноты/кэша сна. При удалении одного источника удаление
агрегатных снимков выполняется консервативно для всех источников. Локальное
удаление не изменяет данные поставщика и ранее экспортированные файлы.

## Независимая оценка приёмки

```sh
python3 tools/score.py measurements.json --output score.json
python3 -m unittest discover -s test_tools -v
```

Формат входа, времена в миллисекундах одной внешне синхронизированной шкалы:

```json
{
  "episodes": [
    {"id":"e1","device":"iPhone11","type":"eyes_closed","threshold_ms":1500}
  ],
  "detections": [
    {"id":"d1","device":"iPhone11","type":"eyes_closed","threshold_ms":1520,
     "alert_request_latency_ms":12}
  ],
  "external_measurements": [
    {"device":"iPhone11","detection_id":"d1","sound_at_ms":1900,
     "vibration_at_ms":3200,"uncertainty_ms":80}
  ]
}
```

`device`, `type`, `id` обязательны; ID уникальны внутри устройства и массива.
`threshold_ms` — независимый порог эпизода или записанный порог события.
Числа должны быть конечными. Неизвестные/повторные ссылки внешних измерений
отклоняются. Порядок входных массивов не влияет на сопоставление.

Сопоставление строго внутри устройства и типа, максимум один-к-одному по
порогу с включёнными границами ±1000 мс. Детерминированные увеличивающие пути
находят максимальное число соответствий, включая конкурирующие близкие
эпизоды. Несопоставленные события — FP; имеющие допустимого кандидата —
`duplicate_fp` внутри FP. Несопоставленные эпизоды — FN независимо от
доступности канала. Пустой знаменатель даёт JSON `null`. Результаты по
устройствам не усредняются для приёмки; общие суммы помечены как описательные.
`--tolerance-ms` предназначен для исследования; нормативное значение 1000.

Внешние задержки считаются от независимого порога сопоставленного эпизода.
Звук проверяется по 500 мс, вибрация по 2000 мс с добавлением погрешности;
погрешность должна быть ≤100 мс. Сигнал раньше порога более чем на погрешность
отмечается `early` и не проходит проверку. Отрицательные задержки никогда
не улучшают среднее `mean_nonnegative_ms`. Отсутствующее внешнее измерение
остаётся `null`/`missing`; внутреннее время запроса не подставляется вместо
него. `all_within_limit` — `false` при измеренном нарушении, `true` только
при полном наборе соответствующих измерений без нарушений, иначе `null`.
Эта утилита не заменяет испытания оборудования, отрицательный часовой тест,
контроль частоты анализов и отдельный протокол доставки рекомендаций на часы.

## Периодические отметки и диагностика

`checkpointSession(String id, {required int atUs, Map<String,Object?>? diagnostics})`
транзакционно продвигает `last_us` максимумом и при переданном снимке заменяет
`diagnostics_json`. Закрытый сеанс не принимает новые контрольные отметки.
Вызывающий контроллер сохраняет отметку активности каждую секунду и минутный
снимок числа завершённых анализов, пригодных измерений глаз/головы, разрывов
и режима сборки. Диагностика содержит
только агрегаты камеры/сборки; JSON сна и самооценки здесь недопустимы и
защитно исключаются при экспорте. Снимок включён в строку `session` общего CSV.
Это последнее известное состояние, не полный ряд внешних измерений; проверка
каждого скользящего 60-секундного окна требует отдельного ряда завершений.

## Диагностика бдительности (расширение, без изменения схемы)

`observation_sessions.diagnostics_json` в контрольных точках дополнительно содержит:

| Ключ | Значение |
|---|---|
| `fatigue` | Последний снимок `FatigueMonitor` (`level`, `perclos`, `blinks_per_minute`, `mean_blink_ms`, `long_blinks_5m`, `nods_5m`, `eye_coverage`) |
| `continuous_drive_s` | Непрерывное время поездки по `DriveClock`, с |
| `trip_fatigue_per_minute` | Накопительный по поездке список: пиковый индекс уровня за минуту (`0` unknown, `1` low, `2` moderate, `3` high, `-1` камера не наблюдала) |
| `trip_breaks` | Перерывы: кнопка «Я сделал перерыв» и паузы ≥ 15 мин |
| `trip_escalations` | Сколько раз сигнал усиливался до максимума |

`tripSummary` берёт самый длинный список и максимальные счётчики среди сеансов поездки и возвращает `fatigue_per_minute`, `fatigue_peak`, `breaks`, `escalations`. Значения не содержат кадров, сна или самооценки. Правила 1.1 записывают `driving_minutes`, `fatigue` и `body_battery` в `inputs_json` рекомендации; `body_battery` относится к данным здоровья и экспортируется только по отдельному выбору (как сон).
