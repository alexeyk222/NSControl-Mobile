# NSControl Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans and independent parallel tasks for the explicitly separated domains below. Keep work in the current empty source repository; source documents remain untouched.

**Goal:** Реализовать приложение по итоговому ТЗ с реальными адаптерами, проверяемым ядром и воспроизводимой сборкой.

**Architecture:** Dart-ядро, Flutter UI, порты сервисов, SQLite; нативные адаптеры и два приложения часов.

**Tech Stack:** Flutter/Dart, google_mlkit_face_detection 0.15.1, camera, SQLite, Kotlin, Swift, Monkey C.

**Spec:** `docs/architecture.md`; исходный нормативный источник — `Итоговые документы/ТЗ_NSControl_редакция_2_3.docx`.

## Global Constraints

- Android 8.0+ и iOS 15.5+; доступность интеграций проверять отдельно.
- Никакой записи кадров, сервера NSControl, аккаунтов, GPS и камеры в фоне.
- Точные пороги из архитектуры/ТЗ; новые движки требуют собственной калибровки.
- Не заявлять результаты физических испытаний без фактических измерений.

## Review Focus

- Некорректное время, поздний ответ и смена сеанса не продолжают отсчёт.
- Поворот в сторону сбрасывает голову без ложной тревоги.
- Кэш сна, неполное покрытие и сдвиг 24 ч не становятся заключением о недосыпе.
- Отмена и восстановление связи исключают старые сигналы часов.
- Ошибка/удаление SQLite не блокирует тревогу и не оставляет чувствительные снимки.

## Task 1 — Toolchain and shared contracts

- [x] Установить Flutter в локальный игнорируемый `.tooling`, зафиксировать версию; создать Android/iOS проект.
- [x] Описать контракты в `docs/contracts.md`; разделить файлы и ответственность независимых задач.
- [x] Получить зависимости и зафиксировать pubspec.lock.

## Task 2 — Detection and recommendation domain

Files: `lib/logic/**`, `test/logic/**`.

- [x] Сначала тесты калибровки (10 с/90/90%, median/MAD), затем Calibration.
- [x] Тесты автоматов: строгие границы, медиана 3, 300 мс gap/late, восстановление 300/500 мс, ID подтверждений; затем ObservationEngine.
- [x] Тесты сна (пересечения, awake, источники, 24 ч, полнота) и рекомендаций (7 ч, 00/06, приоритеты, latching); затем правила.
- [x] `flutter test test/logic` и полный набор тестов без ошибок.

## Task 3 — Storage, export and acceptance tooling

Files: `lib/data/**`, `test/data/**`, `tools/score.py`, `test_tools/**`.

- [x] Сначала тесты реальной SQLite in-memory: связи, upsert, recovery, cascade, удаление сна со снимками.
- [x] Реализовать schema v1, repository, CSV и итог с объединением интервалов недоступности.
- [x] Проверить исключение сна/самооценки из общего CSV и отдельный экспорт.
- [x] Тестировать score.py: один TP на эпизод, дубли FP, FN при недоступности, пустой знаменатель и независимая внешняя задержка.

## Task 4 — Native integrations and watch apps

Files: `android/**`, `ios/**`, `watchos/**`, `garmin/**`, `docs/integrations.md`.

- [x] Реальный HealthKit read authorization/query; Health Connect availability/permission/pagination/stages, только завершённые записи.
- [x] Реальное оповещение телефона с управлением громкостью/вибрацией, stop, keepAwake.
- [x] Watch Connectivity и Connect IQ: discovery, send, receive, status, без очереди старых alerts.
- [x] Приложения часов с TTL, sync, dedup, cancel, snapshot и реальным haptic API.
- [x] Android ARM64 release собран и проверен. iOS/watchOS без Xcode и Garmin без профиля остаются явно неподтверждёнными; см. docs/verification.md.

## Task 5 — Flutter application

Files: `lib/services/**`, `lib/ui/**`, `lib/main.dart`, `test/services/**`, `test/ui/**`.

- [x] Тесты backpressure/late frame/session isolation и ошибок сервисов; затем camera и ML Kit adapter.
- [x] TripController связывает ядро, немедленное оповещение, асинхронный журнал, часы и минутный пересчёт.
- [x] Русские экраны, калибровка/подтверждение лица, настройки, сон, журнал, удаление, share и диагностика.
- [x] Widget tests ключевого пути и ошибок; `flutter analyze`, `flutter test` прошли. Android-сборка проверяется отдельно в задаче 4.

## Task 6 — Integration review and delivery

- [x] Проверить весь diff на соответствие ТЗ, обработку ошибок и отсутствие секретов/заглушек.
- [x] README, matrix требований, инструкция стенда, build tooling/CI и список проверенного.
- [x] Окончательные результаты записаны в docs/verification.md; комплект упакован средствами tools/package_release.py.
