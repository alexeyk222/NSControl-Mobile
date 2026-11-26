/// Interface text of NSControl, word for word from docs/ux/copy.md (keys in
/// comments). Change text here, not in screens: one place to proofread,
/// and the forbidden-word test (`test/ui/copy_test.dart`) checks it.
///
/// Tone: a calm navigator, «вы», the action at the end; voice lines up to
/// eight words; no technical words outside developer mode (copy.md §2).
library;

/// Non-breaking space before units: «4 ч 50 мин».
const nbsp = ' ';

abstract final class Copy {
  // §3.1 Onboarding
  static const introTitle = 'Разбужу, если начнёте засыпать'; // onb.intro.title
  static const introPoints = [
    'Слежу через камеру за глазами и головой', // onb.intro.p1
    'Громко тревожу и вибрирую на часах', // onb.intro.p2
    'Подскажу, когда пора отдохнуть', // onb.intro.p3
  ];
  static const introPrivacy =
      'Видео не записывается и не покидает телефон'; // onb.intro.privacy
  static const introCta = 'Настроить'; // onb.intro.cta
  static const onboardingStep = 'Знакомство';
  static const mountTitle = 'Где стоит телефон?'; // onb.mount.title
  static const mountLeft = 'Слева от меня'; // onb.mount.left
  static const mountRight = 'Справа от меня'; // onb.mount.right
  static const mountCenter = 'Прямо передо мной'; // onb.mount.center
  static const mountHint =
      'Лучше всего на решётке обдува, экраном к вам'; // onb.mount.hint
  static const mountView = 'вид с места водителя';
  static const next = 'Дальше';
  static const soundTitle = 'Так звучит тревога'; // onb.sound.title
  static const soundAsk = 'Слышно хорошо?'; // onb.sound.ask
  static const soundYes = 'Да'; // onb.sound.yes
  static const soundLouder = 'Тихо, сделать громче'; // onb.sound.louder
  static const soundRoute = 'Куда выводить тревогу'; // onb.sound.route
  static const routePhone = 'Только телефон'; // onb.sound.route.phone
  static const routeBoth = 'Телефон и машина'; // onb.sound.route.both
  static const soundPlay = 'Прослушать сигнал';

  // §3.2 Before a trip
  static const tabPre = 'Перед поездкой'; // pre.title
  static const tabHistory = 'История'; // his.title
  static const tabSettings = 'Настройки';
  static const verdictOk = 'Хорошей дороги'; // pre.verdict.ok
  static String verdictOkSub(String interval) =>
      'Перерыв советую через $interval'; // pre.verdict.ok.sub
  static const verdictRest =
      'Лучше отдохнуть перед поездкой'; // pre.verdict.rest
  static const verdictUnknown = 'Не знаю, как вы спали'; // pre.verdict.unknown
  static const verdictUnknownSub =
      'Если не выспались, лучше отдохнуть'; // pre.verdict.unknown.sub
  static String reasonSleepShort(String hm) =>
      'Сон за сутки: $hm'; // pre.reason.sleep_short
  static const reasonNight =
      'Сейчас ночь: в это время чаще клонит в сон'; // pre.reason.night
  static const reasonSleepy =
      'Вы отметили, что хочется спать'; // pre.reason.sleepy
  static String reasonSleepPartial(String hm) =>
      'Записана только часть ночи: учёл $hm'; // pre.reason.sleep_partial
  static const reasonEyes = 'В этой поездке закрывались глаза';
  static const reasonLongDrive = 'Долго за рулём без перерыва';
  static const reasonFatigue = 'Камера замечает признаки усталости';

  static String readyCameraOk(String side) =>
      'Камера настроена · $side'; // pre.ready.camera.ok
  static const readyCameraNone =
      'Камера не настроена · 10 секунд'; // pre.ready.camera.none
  static const readyCameraDenied =
      'Нет доступа к камере'; // pre.ready.camera.denied
  static const readyCameraNote = mountHint;
  static const readyWatchOk = 'Часы готовы'; // pre.ready.watch.ok
  static const readyWatchClosed =
      'Откройте NSControl на часах'; // pre.ready.watch.closed
  static const readyWatchMissing =
      'Установите NSControl на часы'; // pre.ready.watch.missing
  static const readyWatchOff = 'Без часов'; // pre.ready.watch.off
  static const readyWatchNote = 'При тревоге часы завибрируют';
  static String readySleepOk(String time) =>
      'Сон обновлён в $time'; // pre.ready.sleep.ok
  static const readySleepStale =
      'Сон обновлялся давно'; // pre.ready.sleep.stale
  static const readySleepNone = 'Нет данных о сне'; // pre.ready.sleep.none
  static const readySleepNote = 'Беру только данные сна';
  static const readySleepNoneNote = 'Посмотрю, сколько вы спали за сутки';
  static const actCheck = 'Проверить';
  static const actAllow = 'Разрешить';
  static const actRefresh = 'Обновить';
  static const actOpenSettings = 'Открыть настройки';
  static const feelTitle = 'Как вы себя чувствуете?'; // pre.feel.title
  static const feelFine = 'Бодро'; // pre.feel.fine
  static const feelSleepy = 'Хочется спать'; // pre.feel.sleepy
  static const feelUnknown = 'Не знаю'; // pre.feel.unknown
  static const batteryLow =
      'Подключите зарядку: поездка разряжает телефон'; // pre.battery.low
  static const heatBefore =
      'Телефон нагрет. Не направляйте на него горячий обдув'; // pre.heat
  static const go = 'Поехали'; // pre.cta
  static const goFirstNote = 'Займёт 10 секунд';
  static const testAll = 'Проверить звук и вибрацию'; // pre.test
  static const testSent = 'Сигнал отправлен на телефон и часы';
  static const interrupted = 'Прошлая поездка прервалась';

  // §3.3 Camera setup
  static const calTitle = 'Настройка камеры'; // cal.title
  static const calCheckFace = 'Лицо видно'; // cal.check.face
  static const calCheckEyes = 'Глаза видно'; // cal.check.eyes
  static const calCheckLight = 'Света достаточно'; // cal.check.light
  static const calCheckSingle = 'В кадре только вы'; // cal.check.single
  static const calNoFace = 'Поверните телефон к себе'; // cal.hint.no_face
  static const calMany =
      'В кадре кто-то ещё. Коснитесь своего лица'; // cal.hint.many
  // Until the trip can confirm one face among several (TripController
  // confirms a single face only), the screen waits instead of asking for a
  // tap.
  static const calManyWait =
      'В кадре кто-то ещё. Подожду, пока останетесь одни';
  static const calFaceSeen = 'Вижу вас. Не двигайтесь';
  static const calGo = 'Смотрите на дорогу'; // cal.go
  static const calDone = 'Готово'; // cal.done
  static const calFailMoved = 'Не получилось: вы двигались'; // cal.fail.moved
  static const calFailLost = 'Не получилось: потерял лицо'; // cal.fail.lost
  static const calFailFinal = 'Не получается настроить глаза'; // cal.fail.final
  static const calHeadOnly =
      'Ехать, следя только за головой'; // cal.fail.head_only
  static const cancel = 'Отмена'; // cal.cancel
  static const calStarting = 'Включаю камеру';
  static const calCameraDenied =
      'Без камеры я не смогу следить. Включите её в настройках iOS.'; // onb.camera.denied
  static const retry = 'Повторить';

  // §3.4 On the road
  static const watching = 'Слежу'; // trip.status.watching
  static const headOnly = 'Слежу за головой'; // trip.status.head_only
  static const noFace = 'Не вижу вас'; // trip.status.no_face
  static const noFaceSub = 'Проверьте телефон на остановке'; // .sub
  static const many = 'Вижу несколько лиц'; // trip.status.many
  static const paused = 'Пауза'; // trip.status.paused
  static const cameraError = 'Камера недоступна'; // trip.status.camera_error
  static const cameraErrorSub = 'Пробую снова…';
  static const cameraSilentSub = 'Камера не отвечает, наблюдение остановлено';
  static const starting = 'Запускаю';
  static String elapsed(String hm) => 'В пути $hm'; // trip.ctx.elapsed
  static String breakIn(String hm) => 'Перерыв через $hm'; // trip.ctx.break_in
  static const eyesHidden = 'Глаза не видно'; // trip.ctx.eyes_hidden
  static const adviceBreak = 'Пора сделать перерыв'; // trip.advice.break
  static const adviceStop = 'Рекомендую остановку'; // trip.advice.stop
  static const adviceStopNow = 'Остановитесь как можно скорее';
  static const heatSerious = 'Телефон нагрелся, экономлю';
  static const moved = 'Телефон сдвинулся'; // trip.moved
  static const journalBroken =
      'История этой поездки сохранится не полностью'; // trip.journal.broken
  static const pause = 'Пауза'; // trip.pause
  static const resume = 'Продолжить'; // trip.resume
  static const finish = 'Завершить'; // trip.finish
  static const finishHold = 'Удерживайте…'; // trip.finish.hold
  static const finishHint = 'Удерживайте, чтобы завершить';
  static const watchLost = 'Часы отключились';

  // §3.5 Alarm
  static const alarmEyes = 'Глаза!'; // alarm.eyes
  static const alarmHead = 'Поднимите голову!'; // alarm.head
  static const alarmRoad = 'Смотрите на дорогу!'; // alarm.road
  static const alarmHint = 'Коснитесь экрана, чтобы выключить звук';

  // §3.6 Summary
  static const sumTitle = 'Поездка завершена'; // sum.title
  static const sumOnRoad = 'в пути';
  static const sumClean = 'Ни разу не пришлось будить'; // sum.clean
  static String sumAlarms(int n, String reason) =>
      'Будил ${times(n)}: $reason'; // sum.alarms
  static const reasonEyesPast = 'глаза закрывались';
  static const reasonHeadPast = 'голова опускалась';
  static String sumUnseen(String hm) => 'Не видел вас $hm'; // sum.unseen
  static const sumUnseenTip =
      'Похоже, телефон стоит неудачно. Поверните его чуть к себе'; // sum.unseen.tip
  static String sumBreaks(int n) => 'Перерывов: $n'; // sum.breaks
  static const sumTipBreak =
      'В следующий раз сделайте перерыв через 2 часа'; // sum.tip.break
  static const sumTipSleep =
      'Перед следующей поездкой постарайтесь выспаться'; // sum.tip.sleep
  static const sumPartial = 'История сохранилась не полностью'; // sum.partial
  static const done = 'Готово'; // sum.done
  static const more = 'Подробнее'; // sum.more

  // §3.7 History
  static const hisEmpty = 'Здесь появятся ваши поездки'; // his.empty
  static String hisAlarms(int n) =>
      '$n ${_plural(n, 'тревога', 'тревоги', 'тревог')}';
  static const hisClean = 'Без тревог'; // his.item.clean
  static const hisPartial = 'Сохранилась не полностью'; // his.item.partial
  static const hisTimeline = 'Как прошла поездка'; // his.detail.timeline
  static const legendWatching = 'Слежу';
  static const legendUnseen = 'Не видел';
  static const legendAlarm = 'Тревога';
  static const legendPause = 'Пауза';
  static const hisExport = 'Поделиться журналом'; // his.export
  static const hisExportSensitive = 'Добавить сон и самочувствие';
  static const hisExportPlain = 'Только поездка';
  static const hisDelete = 'Удалить поездку'; // his.delete
  static const hisDeleteConfirm =
      'Поездка удалится с этого телефона. Файлы, которые вы уже отправили, останутся.';
  static const delete = 'Удалить';
  static const back = 'Назад';
  static const today = 'Сегодня';
  static const yesterday = 'Вчера';
  static String hisNotSeen(String hm) => 'Не видел вас $hm';
  static const hisActive = 'Идёт сейчас';

  // §3.8 Settings
  static const setDesign = 'Оформление';
  static const setDesignChosen = 'Выбрано';
  static const setDesignLocked = 'Сменить можно после поездки';
  static const setTheme = 'Тема вне поездки';
  static const themeSystem = 'Как в системе';
  static const themeDark = 'Тёмная';
  static const themeLight = 'Светлая';
  static const setMount = 'Крепление'; // set.mount
  static const setMountSide = 'Где стоит телефон'; // set.mount.side
  static const setRecal = 'Перенастроить камеру'; // set.mount.recal
  static const setPreview = 'Показывать камеру в пути'; // set.mount.preview
  static const setSound = 'Звук и голос'; // set.sound
  static const setVolume = 'Громкость тревоги'; // set.sound.volume
  static const setVoice = 'Голосовые подсказки'; // set.sound.voice
  static const setRoute = soundRoute; // set.sound.route
  static const setEscalate =
      'Усиливать, если не реагирую'; // set.sound.escalate
  static const setVibrate = 'Вибрация телефона'; // set.sound.vibrate
  static const setTestSound = 'Проверить звук'; // set.sound.test
  static const setWatch = 'Apple Watch'; // set.watch
  static const setWatchTest = 'Проверить вибрацию'; // set.watch.test
  static const setWatchDetails = 'Часы и сон подробно';
  static const setSleep = 'Сон'; // set.sleep
  static const setSleepSource = 'Источник'; // set.sleep.source
  static const setSleepSourceValue = '«Здоровье»';
  static const setDetect = 'Распознавание'; // set.detect
  static const setGlasses =
      'Тёмные очки (следить только за головой)'; // set.detect.glasses
  static const setBreak = 'Напоминать о перерыве каждые'; // set.detect.break
  static const setData = 'Данные и приватность'; // set.data
  static const setDataWhat =
      'Поездки, тревоги и советы. Видео и фото не сохраняются. Ничего не отправляется на серверы NSControl.';
  static const setDeleteAll = 'Удалить всю историю'; // set.data.delete_all
  static const setDeleteAllConfirm =
      'Все поездки удалятся с этого телефона. Файлы, которые вы уже отправили, останутся.';
  static const setDeleteCal = 'Удалить настройку камеры'; // set.data.delete_cal
  static const setAbout = 'О приложении'; // set.about
  static const setLimits =
      'NSControl помогает заметить сонливость, но не гарантирует, что вы бодры. Не заменяет отдых.';
  static const setDev = 'Режим разработчика'; // set.about.dev
  static const setDevTools = 'Для разработчика';
  static const volumeMax = 'Максимум';
  static const volumeLoud = 'Громко';
  static const volumeMedium = 'Средне';
  static const sideLeft = 'слева';
  static const sideRight = 'справа';
  static const sideCenter = 'прямо';
}

/// Voice lines (copy.md §3.3–§5, §4): short, understood without the screen.
abstract final class Voice {
  static const calNoFace = 'Поверните телефон к себе';
  static const calMany = 'В кадре кто-то ещё';
  static const calGo = 'Смотрите на дорогу, как обычно. Пять секунд';
  static const calRetry = 'Ещё раз. Смотрите на дорогу';
  static const calDone = 'Готово. Слежу за дорогой';
  static const headOnly = 'Не вижу глаза. Слежу только за головой';
  static const noFace = 'Не вижу вас';
  static const many = 'В кадре кто-то ещё';
  static const paused = 'Пауза. Защита выключена';
  static const resumed = 'Продолжаю';
  static const cameraError = 'Камера недоступна';
  static const watchLost = 'Часы отключились. Тревога только на телефоне';
  static String breakDue(String hours) =>
      'Вы за рулём $hours. Пора сделать перерыв';
  static const afterEyes = 'Вы закрывали глаза. Найдите место для остановки';
  static const afterEyesAgain =
      'Вы снова закрывали глаза. Остановитесь как можно скорее';
  static const afterHead = 'Голова опускалась. Если клонит в сон, остановитесь';
  static const alarmEyes = 'Глаза!';
  static const alarmHead = 'Поднимите голову!';
  static const alarmRoad = 'На дорогу!';
}

/// «2 раза», «5 раз».
String times(int n) => '$n ${_plural(n, 'раз', 'раза', 'раз')}';

String _plural(int n, String one, String few, String many) {
  final mod10 = n % 10, mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
  return many;
}

/// «1 ч 12 мин», «45 мин», «0 мин» with non-breaking spaces.
String hoursMinutes(Duration d) {
  final total = d.inMinutes;
  final h = total ~/ 60, m = total % 60;
  if (h == 0) return '$m$nbspмин';
  if (m == 0) return '$h$nbspч';
  return '$h$nbspч $m$nbspмин';
}

/// «2 часа», «1,5 часа», «3 часа» for the break interval.
String breakInterval(Duration d) {
  final minutes = d.inMinutes;
  if (minutes % 60 == 0) {
    final h = minutes ~/ 60;
    return '$h$nbsp${_plural(h, 'час', 'часа', 'часов')}';
  }
  final h = minutes / 60;
  return '${h.toStringAsFixed(1).replaceAll('.', ',')}$nbspчаса';
}

/// «08:14».
String clock(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}';
}
