# Нативные интеграции NSControl 1.0

Версия протокола: 1. Идентификатор мобильного приложения: `org.nscontrol.nscontrol`.
Connect IQ UUID: `936fbf7641ce4a3a922561ead363a448`.

## Смартфоны

Flutter вызывает MethodChannel `nscontrol/platform`; события идут через EventChannel `nscontrol/events`.

| Метод | Аргументы | Результат |
|---|---|---|
| `alert.start` | `volume: 0..1`, `vibrate: bool` | `status: requested` либо ошибка |
| `alert.stop` | — | остановка текущего звука и периодической вибрации |
| `alert.test` | как `alert.start` | проба 1,5 с |
| `screen.keepAwake` | `enabled: bool` | экран не гаснет во время наблюдения |
| `app.openSettings` | — | системные настройки разрешений приложения; opened / error |
| `sleep.status` | — | available / unavailable / permission_required / error |
| `sleep.authorize` | — | системный запрос только чтения сна |
| `sleep.read` | `from`, `to`: ISO 8601 с зоной | статус, `records`, время чтения, ограничения |
| `wearable.status` | — | фактическое состояние транспорта и причина |
| `wearable.devices` | — | список сопряжённых устройств `{id,name,connected}` |
| `wearable.connect` | `deviceId?` | регистрация выбранного устройства / статус |
| `wearable.send` | `message: Map` | `accepted` и результат транспорта |

Android использует `AudioTrack` с циклическим PCM-буфером и `VibrationEffect`. iOS использует `AVAudioPlayer` с циклическим WAV-буфером и системную вибрацию. Громкость задаётся как коэффициент 0…1 и дополнительно зависит от системной громкости/маршрута вывода. Никакое возвращаемое значение не подтверждает слышимость. Проба автоматически заканчивается; обычное предупреждение играет до остановки. При уходе приложения с экрана нативный адаптер прекращает звук. На iOS прерывание аудиосессии также останавливает звук и публикует `platform_interruption`.

### Health Connect

Зависимость `androidx.health.connect:connect-client:1.1.0`; Android minSdk 26. Перед запросом выполняется `HealthConnectClient.getSdkStatus`. Наличие Android 8+ само по себе не означает доступность Health Connect, особенно на Huawei. В manifest объявлено только `READ_SLEEP`, экран объяснения разрешений и Android 14 alias для просмотра использования данных. Перед каждой страницей проверяется выданное разрешение, `SecurityException` возвращает `permission_required`, частичные результаты при ошибке не выдаются как успешное чтение.

Читаются `SleepSessionRecord` с пагинацией до пустого/null `pageToken`; повтор токена считается ошибкой. Будущие/незавершённые и некорректные интервалы исключены. Поле `source` — пакет поставщика, `provider_id` — исходный UUID записи. Стадия получает ID `<UUID>:stage:<index>`, рамка сеанса — `<UUID>:session`. Рамка помечена `inBed`, а неизвестные стадии не считаются сном. `sleeping/light/deep/rem` дают `asleep`, `awake/awake_in_bed/out_of_bed` — `awake`. Неполная стадийность намеренно не превращается в сон на всю длину сеанса.

При обновлении поставщиком запись вместе со стадиями должна заменяться как группа `(source,provider_id)`: одного upsert сегментов недостаточно, если поставщик удалил стадию. В `device` передаются модель, изготовитель, тип и `is_watch`. Пакет Garmin Connect без метаданных часов не доказывает происхождение с целевых fēnix 7X. По умолчанию Health Connect ограничивает чтение старой истории; NSControl запрашивает текущее окно и не запрашивает доступ ко всей истории или фоновое чтение.

Путь Garmin Connect → Health Connect → NSControl требует испытания на Huawei Pura 70. При недоступности поставщика показывается недоступность. Облачный Garmin Health API, сервер и обход ограничений Huawei отсутствуют.

### HealthKit

Используется `HKSampleQuery` только для `.sleepAnalysis`, без записи данных. Результаты включают UUID, bundle ID источника, источник, устройство, productType и завершённые интервалы. Все `asleep` категории учитываются как сон; awake/inBed отделены. Источник и устройство доступны для выбора/проверки происхождения с Apple Watch.

`requestAuthorization` означает завершение диалога, а не доказательство доступа на чтение. `authorizationStatus(for:)` для выяснения чтения не используется: Apple раскрывает им только разрешение записи. Поле `read_authorization: unknown` сохраняется; пустой запрос может означать отсутствие записей или отказ. Явная ошибка разрешения обрабатывается отдельно. Отключение источника в UI прекращает будущие чтения. Полнота истории не выводится из успешного запроса.

## Часы и транспорт

Apple: `WCSession.sendMessage` вызывается только при активированной сессии, установленном приложении и `isReachable`. `updateApplicationContext` применяется только к последнему snapshot для показа состояния. Фоновые очереди `transferUserInfo`/file transfer для предупреждений не используются. Контекст на часах не разрешает вибрацию. Переключение/деактивация часов и reachability публикуются в Flutter.

Garmin: зависимость `com.garmin.connectiq:ciq-companion-app-sdk:2.2.0@aar` из Maven Central. Используются `getKnownDevices`, `getApplicationInfo`, `registerForDeviceEvents`, `registerForAppEvents` и `sendMessage(..., isTransient=true)`. Требуется установленный Garmin Connect Mobile и сопряжение. Пользователь выбирает устройство, если их несколько. Статус соединения SDK не подтверждает, что приложение часов сейчас выполняется: это проверяется handshake. Команда не ставится в повторную очередь NSControl. Тайм-аут отправки — 3 с; это только предел ожидания ответа, не расширение TTL.

Событие `wearable_message` содержит `message`, `wearable_status` содержит карту `status`. На часах запрос haptic и подтверждение приёма отделены от физического результата. `haptic_requested: true` означает исключительно вызов `WKInterfaceDevice.play` / `Attention.vibrate`.

### Словарь сообщений

Обязательная оболочка: `v:1`, `type`, уникальный `message_id`, `connection_id`, `receiver_epoch`. При наличии: `trip_id`, `session_id`, `event_id` либо `recommendation_id`.

1. Телефон отправляет `hello` с новым `connection_id`. Часы сбрасывают готовность и отвечают `ready`, новым `receiver_epoch` и тем же `connection_id`. При старте/изменении достижимости часы могут прислать `ready` без connection ID. Все последующие команды несут этот epoch: старая очередь после старта приложения не может сама себя авторизовать.
2. `snapshot` содержит `active_event_ids`, `recommendation` (строка/отсутствует), `reason` (необязательно). Он только обновляет состояние. Смена соединения сбрасывает дедупликацию и синхронизацию. Смена сеанса в том же receiver epoch очищает события/отмены и сохраняет ещё действующее сопоставление процессных монотонных часов; старый session_id всё равно отклоняется.
3. `ping`: `phone_sent_us` в монотонной шкале телефона. Часы отвечают `pong` с `ack_message_id` исходного ping, `phone_sent_us`, `watch_received_ms`, `watch_sent_ms`.
4. Телефон фиксирует монотонное время получения pong и передаёт `clock_sync`: `sync_id` = ID ping, `watch_minus_phone_lower_ms = watch_sent_ms - phone_reply_received_us/1000`. Синхронизация принимается только для ожидаемого ping и действует не более 30 с. На Garmin поле lower offset передаётся десятичной строкой и разбирается `toDouble()`, чтобы сжатие Java Double в Float мобильным SDK не ухудшило консервативную оценку. Остальные временные поля передаются целыми числами.
5. `alert`: ссылка на событие/рекомендацию, `reason`, `occurred_us` исходного порога/формирования, `ttl_ms:2000`, `sync_id`. Верхняя оценка возраста перед haptic равна `watchNowMs - occurred_us/1000 - lowerOffset + 1 + 0.001*(watchNowMs - pingReceivedMs)`. Последние члены — запас на округление и относительный дрейф 1000 ppm. Значения <0 и >2000 мс отвергаются. Это консервативная инженерная модель, которую необходимо подтвердить/уточнить измерениями на реальных часах.
6. `cancel`: `target_ids` с ID событий/рекомендаций либо `all:true`. Полученная отмена запрещает будущий первичный сигнал. `all` снимает готовность до нового snapshot; действующее сопоставление процессных часов сохраняется. Старые команды после смены сеанса отклоняются по session_id.
7. `ack`: новый `message_id`, `ack_message_id` исходной команды, `status`, `haptic_requested`. Статусы включают accepted, duplicate, expired, cancelled, unsynchronized, snapshot_required, session_mismatch, state_only, synchronized, invalid_sync, capacity.

Дедупликация проверяется и по ID сообщения, и по ID события/рекомендации. При переполнении памяти дедупликации новые оповещения отклоняются до смены сеанса; старые ID не вытесняются с риском повторного сигнала. Связь/сеанс, epoch, отмена и срок проверяются до haptic. Завершение короткого события само по себе не является отменой: в непрерывной связи допускается один первичный сигнал в пределах исходных 2 с. После разрыва обязательно новый epoch/snapshot; старое сообщение не может восстановить сигнал.

Garmin использует `System.getTimer`, который может переполняться; при уменьшении значения готовность сбрасывается. Проверка `phoneConnected` выполняется каждую секунду, плюс ошибки и handshake со стороны телефона. На Apple Watch используется system uptime. `ready` и handshake не доказывают работу в выгруженном/произвольном фоне.

## Сборка и установка

### Android

Flutter устанавливает зависимости по `pubspec.lock`, Gradle — по закреплённым версиям. Требуются JDK 17+, Android SDK 36, поддерживаемая Flutter версия из README. В изолированной среде выставить локальный `GRADLE_USER_HOME`, например `$PWD/.tooling/gradle`.

```sh
flutter pub get
flutter build apk --release
```

Для испытаний debug-подпись релизной конфигурации допустима только как явно обозначенная локальная сборка. Для распространения добавить собственный release keystore вне репозитория. Установить Garmin Connect, выполнить сопряжение и установить приложение Connect IQ, затем выбрать часы в NSControl. Проверить обнаружение приложения, hello/ready, snapshot, ping/pong, sync и тест фактической вибрации отдельно.

### iOS / watchOS

Нужны полный Xcode с iOS/watchOS SDK, iPhone, Apple Watch, аккаунт/команда подписи с HealthKit capability. Command Line Tools без Xcode недостаточны. CocoaPods нужен для google_mlkit_face_detection 0.15.1 и GoogleMLKit/FaceDetection 9; Podfile iOS 15.5 и включения Pods xcconfig подготовлены. Flutter поддерживает смешанную сборку SPM/Pods. Podfile.lock появится после первой разрешённой сборки на полном Xcode; сейчас разрешение iOS pods не проверено.

```sh
flutter pub get
(cd ios && pod install)
flutter build ios --no-codesign
cd watchos
xcodegen generate
xcodebuild -project NSControlWatch.xcodeproj -scheme NSControlWatch -sdk watchsimulator CODE_SIGNING_ALLOWED=NO build
```

`watchos/project.yml` — самостоятельный XcodeGen-проект современного single-target SwiftUI watch app, watchOS 9+. Для устройства выбрать свою signing team, совместимые provisioning profiles и `org.nscontrol.nscontrol.watchkitapp`; companion ID должен оставаться равным bundle ID iPhone. Открыть `ios/Runner.xcworkspace` и сгенерированный watch project; для единого iOS archive добавить watch target/product в workspace и фазу Embed Watch Content Runner. Прямой запуск watch target из Xcode подходит для стендовой установки рядом с подписанным Runner. HealthKit entitlement уже включён в Runner. Установить обе части, запустить приложение часов и проверить live reachability.

Независимая проверка протокола без Apple SDK:

```sh
swiftc -module-cache-path /tmp/nscontrol-swift-cache watchos/NSControlWatch/AlertGate.swift watchos/Tests/main.swift -o /tmp/nscontrol-watch-tests
/tmp/nscontrol-watch-tests
```

### Garmin Connect IQ

Установить официальный Connect IQ SDK 9.2.0 и профиль устройства `fenix7x` через SDK Manager после входа в Garmin Connect account (вход требуется официальной инструкцией); путь к SDK передать явно. В рабочем окружении официальный менеджер подготовлен по пути `.tooling/SdkManager.app` (вне распространяемого исходного комплекта); однако проверка `codesign --verify --deep --strict` выявила недействительную arm64-подпись как в исходном официальном DMG, так и в копии. Менеджер не запускался; защиту macOS не отключали и приложение не переподписывали. Для входа следует получить проверенный актуальный менеджер с официального сайта Garmin, затем самостоятельно войти и загрузить fenix7x. Компилятор уже доступен в `.tooling/connectiq/bin/monkeyc`. Создать developer key локально, не включать его в комплект. `monkey.jungle`, manifest, ресурсы и исходники находятся в `garmin/`.

```sh
mkdir -p build/garmin
"$CIQ_SDK/bin/monkeyc" -f garmin/monkey.jungle -d fenix7x -y /private/path/developer_key.der -o build/garmin/NSControl.prg
"$CIQ_SDK/bin/monkeydo" build/garmin/NSControl.prg fenix7x
```

Для часов установить подписанный PRG в `GARMIN/APPS` поддерживаемым устройством способом; для магазина/пакета использовать экспорт SDK. UUID manifest должен совпадать с Android `GarminBridge.APP_ID`. Проверить отображение русского текста и его обрезку на устройстве. В приложении нет фонового сервиса, workout session или обещания работы после выгрузки; обязательный тест — запущенное приложение с активным и автоматически погасшим экраном.

## Подтверждение и ограничения

В этой среде доступны статические проверки plist/Xcode project и выполняемые Swift-тесты протокола. Они проверяют отсутствие snapshot, свежий сигнал, дубли, отмену, границу TTL с запасом, неверную временную шкалу и разрыв. Результаты Android сборки фиксируются в README/отчёте поставки. Полная компиляция Apple targets требует Xcode SDK. Для Garmin в этой среде загружен официальный компилятор 9.2.0: `monkeyc --version` выполнен, но сборка с `-d fenix7x` остановилась с `Invalid device id`, поскольку отдельный профиль устройства не установлен. Его нужно загрузить SDK Manager; успешная компиляция/установка PRG не подтверждена. Отсутствие такой компиляции нельзя называть успешной сборкой.

Фактическая громкость, старт звука ≤0,5 с, вибрация ≤2 с, screen-off поведение, потребление, устойчивость 60 минут, реальные записи сна и доступность Health Connect на Huawei проверяются на целевых устройствах. Ни unit tests, ни callback транспорта, ни haptic API не являются доказательством физической вибрации. Эти проверки остаются обязательными пунктами стендовой приёмки.

## Официальные источники

- [Health Connect: sleep sessions](https://developer.android.com/health-and-fitness/health-connect/features/sleep-sessions)
- [Health Connect: reading and pagination](https://developer.android.com/health-and-fitness/guides/health-connect/develop/read-data)
- [Apple: HealthKit authorizationStatus](https://developer.apple.com/documentation/healthkit/hkhealthstore/authorizationstatus(for:))
- [Apple: sleep analysis categories](https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis)
- [Apple: WCSession and delivery methods](https://developer.apple.com/documentation/watchconnectivity/wcsession)
- [Garmin: official Android SDK and Maven coordinates](https://github.com/garmin/connectiq-android-sdk)
- [Garmin: Communications API](https://developer.garmin.com/connect-iq/api-docs/Toybox/Communications.html)
- [Garmin: Attention API](https://developer.garmin.com/connect-iq/api-docs/Toybox/Attention.html)
- [Garmin: SDK downloads](https://developer.garmin.com/connect-iq/sdk/)

- [Garmin: SDK Manager login and device library setup](https://developer.garmin.com/connect-iq/connect-iq-basics/getting-started/)
