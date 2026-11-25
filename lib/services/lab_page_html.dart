/// The live page served to the browser on the Mac, by the lab and by the
/// trip's live debug (docs/trip-debug.md). Self-contained (no CDN): it must
/// work in a closed Wi-Fi or the phone's hotspot and never loads anything
/// but the stream of this phone: the numbers and, when the page asks for
/// it, the developer debug video (binary messages, kept only in memory).
const labPageHtml = r'''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NSControl · Лаборатория</title>
<style>
:root{--bg:#f3f6f4;--card:#fff;--fg:#14211d;--muted:#5d6b66;--line:#d9e1dd;--accent:#126d62;--warn:#b3261e;--band:rgba(18,109,98,.09)}
@media (prefers-color-scheme:dark){:root{--bg:#101815;--card:#18231f;--fg:#e4ece8;--muted:#93a39d;--line:#2a3833;--accent:#5fd0bf;--warn:#ff8a80;--band:rgba(95,208,191,.10)}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
header{position:sticky;top:0;z-index:2;background:var(--bg);padding:12px 16px 8px;border-bottom:1px solid var(--line)}
#status{font-size:30px;font-weight:700;letter-spacing:-.5px}
#status.alarm{color:var(--warn)}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}
.chip{border:1px solid var(--line);border-radius:999px;padding:2px 10px;background:var(--card);font-variant-numeric:tabular-nums}
.chip b{font-weight:600}
.chip.rec{border-color:var(--warn);color:var(--warn)}
.chip.bad{border-color:var(--warn);color:var(--warn)}
#prompt{margin-top:6px;font-size:18px;color:var(--accent);min-height:1.4em}
main{padding:12px 16px 40px;display:grid;grid-template-columns:repeat(auto-fill,minmax(440px,1fr));gap:12px}
@media (max-width:520px){main{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:10px 12px}
.card h3{margin:0 0 4px;font-size:14px;font-weight:600;display:flex;justify-content:space-between;gap:8px}
.card h3 span{font-weight:400;color:var(--muted);font-size:12px}
canvas{width:100%;height:160px;display:block}
canvas.strip{height:46px}
.legend{display:flex;flex-wrap:wrap;gap:4px 12px;font-size:12px;color:var(--muted);margin-top:4px}
.legend i{display:inline-block;width:14px;height:3px;border-radius:2px;margin-right:4px;vertical-align:middle}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums;font-size:13px}
td,th{padding:2px 4px;text-align:right;border-bottom:1px solid var(--line)}
td:first-child,th:first-child{text-align:left;color:var(--muted)}
#feed{max-height:320px;overflow:auto;font-size:13px;font-variant-numeric:tabular-nums}
#feed div{padding:2px 0;border-bottom:1px solid var(--line)}
#feed .ev{color:var(--warn);font-weight:600}
#feed .lb{color:var(--accent)}
.wide{grid-column:1/-1}
a{color:var(--accent)}
.vwrap{position:relative;display:flex;justify-content:center;background:#000;border-radius:10px;overflow:hidden;min-height:120px}
#video{width:auto;height:auto;max-width:100%;max-height:520px;display:block}
.vbar{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-top:6px;font-size:12px;color:var(--muted)}
button{font:inherit;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:8px;padding:3px 10px;cursor:pointer}
button:hover{border-color:var(--accent)}
button.on{background:var(--accent);color:var(--card);border-color:var(--accent)}
button.bad{border-color:var(--warn);color:var(--warn)}
select{font:inherit;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:8px;padding:2px 4px}
.marks{display:flex;flex-wrap:wrap;gap:6px;margin:4px 0 8px}
.marks button{padding:6px 12px}
kbd{font-size:11px;border:1px solid var(--line);border-radius:4px;padding:0 4px;color:var(--muted)}
#alarms{max-height:300px;overflow:auto;font-size:13px}
#alarms .row{display:flex;flex-wrap:wrap;gap:6px;align-items:center;padding:4px 0;border-bottom:1px solid var(--line)}
#alarms .row b{color:var(--warn)}
#alarms .verdict{font-weight:600}
td.over{color:var(--warn);font-weight:600}
</style>
</head>
<body>
<header>
  <div id="status">Подключение…</div>
  <div id="prompt"></div>
  <div class="chips">
    <span class="chip" id="c-conn">нет связи</span>
    <span class="chip" id="c-engine">движок —</span>
    <span class="chip" id="c-aps">анализов/с —</span>
    <span class="chip" id="c-lat">задержка —</span>
    <span class="chip" id="c-zone">зона —</span>
    <span class="chip" id="c-driver">водитель —</span>
    <span class="chip" id="c-eyes">глаза —</span>
    <span class="chip" id="c-head">голова —</span>
    <span class="chip" id="c-rec">запись —</span>
    <span class="chip" id="c-device">телефон —</span>
    <span class="chip" id="c-profile">профиль —</span>
    <span class="chip" id="c-alarms">тревог 0</span>
  </div>
</header>
<main id="grid"></main>
<script>
"use strict";
const KEY = new URLSearchParams(location.search).get("k") || "";
const WINDOW = 30;
const PRIMARY_DASH = [], OTHER_DASH = [6, 4];
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const DRIVER = {same:"тот же",restored:"восстановлен",no_face:"нет лица",ambiguous:"несколько лиц",different:"другое лицо"};
const ZONES = {road:"Дорога",mirror_left:"Левое зеркало",mirror_right:"Правое зеркало",mirror_rear:"Салонное зеркало",instruments:"Приборы",console:"Консоль",off_camera:"Вне камеры",unknown:"не определена"};
const ZONE_COLORS = {road:"#2e9d5b",mirror_left:"#3b7dd8",mirror_right:"#7b5bd6",mirror_rear:"#1aa5b8",instruments:"#d89a1e",console:"#c2571a",off_camera:"#888",unknown:"#bbb"};
const PHASES = {unavailable:"недоступен",warmingUp:"прогрев",normal:"норма",signPresent:"признак",warning:"ТРЕВОГА",recovering:"восстановление"};
const CHARTS = [
  {id:"head", title:"Голова, °", sub:"относительно камеры", sym:30, lines:[
    ["headYawLeft","поворот (влево +)","#3b7dd8"],["headPitchDown","наклон (вниз +)","#d23f31"],["headRollRight","крен (к правому плечу +)","#2e9d5b"]]},
  {id:"gaze", title:"Взгляд, °", sub:"голова+глаза / глаз в голове", sym:20, lines:[
    ["gazeLeft","взгляд влево +","#3b7dd8"],["gazeDown","взгляд вниз +","#d23f31"],["eyeGazeLeft","глаз влево +","#7fb0ee"],["eyeGazeDown","глаз вниз +","#f09a90"]]},
  {id:"eyes", title:"Открытие глаз", sub:"0 закрыт · 1 открыт · пунктир — порог T", min:0, max:1, lines:[
    ["eyeOpenLeft","левый","#3b7dd8"],["eyeOpenRight","правый","#d89a1e"]], threshold:"T"},
  {id:"blend", title:"Мимика (blendshapes)", sub:"0..1", min:0, max:1, lines:[
    ["eyeBlinkLeft","blink L","#3b7dd8"],["eyeBlinkRight","blink R","#7fb0ee"],["eyeLookDownLeft","lookDown L","#d23f31"],["eyeLookDownRight","lookDown R","#f09a90"],
    ["eyeSquintLeft","squint L","#7b5bd6"],["eyeSquintRight","squint R","#b7a3ee"],["jawOpen","jawOpen","#2e9d5b"]]},
  {id:"timers", title:"Автоматы, с", sub:"длительность признака · пунктир — пороги профиля", min:0, max:3.5, owner:"derived", lines:[
    ["eyesTimer","глаза","#3b7dd8"],["headTimer","голова","#d23f31"]], marks:[]},
  {id:"mhead", title:"Голова для автоматов, °", sub:"относительно позы «дорога» · пунктир — порог наклона и предел поворота", sym:30, owner:"derived", lines:[
    ["m_pitchDown","наклон вниз +","#d23f31"],["m_yaw","поворот влево +","#3b7dd8"]]},
  {id:"meyes", title:"Глаза для автоматов", sub:"после затвора глаз · пунктир — T калибровки", min:0, max:1, owner:"derived", lines:[
    ["m_eyeLeft","левый","#3b7dd8"],["m_eyeRight","правый","#d89a1e"]]},
  {id:"perf", title:"Производительность", sub:"анализов/с · задержка конвейера, мс/10", min:0, max:40, owner:"derived", lines:[
    ["aps","анализов/с","#2e9d5b"],["latency10","задержка, мс/10","#d89a1e"]]},
];
const series = new Map();   // "engine|key" -> [[t,v]]
const bands = [];           // {step, rep, t0, t1}
const events = [];          // {t, type}
const zones = [];           // [t, zone]
let engines = [], primary = null, tNow = 0, threshold = null, thresholds = {eyes:1.5, head:2.0};
let meta = null, limits = {}, lastMeasure = null, alarms = [], marks = [], tripPhase = null;
const boxes = [];           // [t, box] of the primary engine, for the video overlay
const CAUSES = {mirror:"зеркало",blind_spot:"слепая зона / через плечо",instruments:"приборы / магнитола",phone:"телефон",talk:"разговор / смех",squint:"прищур / солнце",glare:"блики / очки",yawn:"зевок",bump:"кочка / тряска",face_lost:"лицо потеряно / край кадра",mount:"держатель сдвинулся",other:"другое",
  drowsy:"сонливость",deliberate:"намеренно (проверка)",long_look:"долго смотрел вниз"};
const FALSE_CAUSES = ["mirror","blind_spot","instruments","phone","talk","squint","glare","yawn","bump","face_lost","mount","other"];
const TRUE_CAUSES = ["drowsy","deliberate","long_look","other"];
const KINDS = {mark:"метка",false:"ложная",true:"верная",miss:"пропуск"};
let rtt = null, lastDerived = null, lastFrames = {}, dirty = true;
let prevPhase = {eyes:null, head:null};

function el(tag, cls, html) { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; }
const grid = document.getElementById("grid");
const canvases = {};
const videoCard = el("div", "card");
videoCard.appendChild(el("h3", null, `Камера телефона<span id="v-info">видео выкл</span>`));
const vwrap = el("div", "vwrap"); const video = el("canvas"); video.id = "video"; vwrap.appendChild(video); videoCard.appendChild(vwrap);
const vbar = el("div", "vbar",
  `<button id="v-on">Видео</button><button id="v-mirror">Зеркально</button><button id="v-rot">Повернуть</button><button id="v-box" class="on">Рамка</button>` +
  `<span>Только в памяти браузера, не пишется. Только ARKit.</span>`);
videoCard.appendChild(vbar); grid.appendChild(videoCard);
const limitsCard = el("div", "card");
limitsCard.appendChild(el("h3", null, `Пороги и автоматы<span id="l-profile">—</span>`));
const limitsTable = el("table"); limitsCard.appendChild(limitsTable); grid.appendChild(limitsCard);
const marksCard = el("div", "card");
marksCard.appendChild(el("h3", null, `Метки и тревоги<span>пишутся в запись поездки</span>`));
marksCard.appendChild(el("div", "marks",
  `<button data-kind="mark">Метка <kbd>Пробел</kbd></button><button data-kind="false" class="bad">Последняя тревога ложная <kbd>F</kbd></button>` +
  `<button data-kind="true">Последняя верная <kbd>T</kbd></button><button data-kind="miss" class="bad">Пропуск <kbd>M</kbd></button>`));
const alarmsList = el("div"); alarmsList.id = "alarms"; marksCard.appendChild(alarmsList); grid.appendChild(marksCard);
const tripCard = el("div", "card wide");
tripCard.appendChild(el("h3", null, `Вся поездка<span id="t-info">тревоги — красные, метки — по виду</span>`));
const tripCv = el("canvas", "strip"); tripCard.appendChild(tripCv); canvases.trip = tripCv; grid.appendChild(tripCard);
for (const c of CHARTS) {
  const card = el("div", "card");
  card.appendChild(el("h3", null, `${c.title}<span>${c.sub}</span>`));
  const cv = el("canvas"); card.appendChild(cv); canvases[c.id] = cv;
  const lg = el("div", "legend");
  for (const [, name, color] of c.lines) lg.appendChild(el("span", null, `<i style="background:${color}"></i>${name}`));
  card.appendChild(lg); grid.appendChild(card);
}
{
  const card = el("div", "card wide");
  card.appendChild(el("h3", null, `Зона и метки сценария<span>последние ${WINDOW} с</span>`));
  const cv = el("canvas", "strip"); card.appendChild(cv); canvases.strip = cv;
  const lg = el("div", "legend");
  for (const z of Object.keys(ZONES)) lg.appendChild(el("span", null, `<i style="background:${ZONE_COLORS[z]}"></i>${ZONES[z]}`));
  card.appendChild(lg); grid.appendChild(card);
}
const valuesCard = el("div", "card"); valuesCard.appendChild(el("h3", null, "Значения<span>последний кадр</span>"));
const valuesTable = el("table"); valuesCard.appendChild(valuesTable); grid.appendChild(valuesCard);
const feedCard = el("div", "card"); feedCard.appendChild(el("h3", null, "Лента<span>метки, события, фазы</span>"));
const feed = el("div"); feed.id = "feed"; feedCard.appendChild(feed); grid.appendChild(feedCard);
const recCard = el("div", "card wide"); recCard.appendChild(el("h3", null, `Записи на телефоне<span><a id="review-link" href="#">Разбор поездок →</a></span>`));
const recList = el("div"); recCard.appendChild(recList); grid.appendChild(recCard);

function push(key, t, v) {
  if (v == null || !isFinite(v)) return;
  let s = series.get(key); if (!s) { s = []; series.set(key, s); }
  s.push([t, v]);
  while (s.length && s[0][0] < t - WINDOW - 5) s.shift();
}
function fmtT(t) { const m = Math.floor(t / 60), s = (t % 60).toFixed(1).padStart(4, "0"); return `${m}:${s}`; }
function addFeed(text, cls) {
  const d = el("div", cls, `<span style="color:var(--muted)">${fmtT(tNow)}</span> ${text}`);
  feed.prepend(d); while (feed.childNodes.length > 300) feed.lastChild.remove();
}
function reset() {
  series.clear(); bands.length = 0; events.length = 0; zones.length = 0; tNow = 0; threshold = null;
  lastFrames = {}; prevPhase = {eyes:null, head:null}; dirty = true;
  alarms = []; marks = []; boxes.length = 0; lastMeasure = null; renderAlarms();
}
function setChip(id, text, cls) { const c = document.getElementById(id); c.textContent = text; c.className = "chip" + (cls ? " " + cls : ""); }

function onLine(m) {
  switch (m.type) {
    case "pong": rtt = performance.now() - m.t; return;
    case "meta":
      reset(); engines = m.engines || []; primary = engines[0] || null; meta = m; limits = limitsOf(m);
      thresholds = {eyes: limits.eyesClosedUs / 1e6, head: limits.headDownUs / 1e6};
      if (m.source === "trip") document.title = "NSControl · Поездка";
      setChip("c-profile", "профиль " + ((m.detectionProfile || {}).id || "—"));
      renderLimits();
      setChip("c-engine", "движок " + (engines.join(" + ") || "—"));
      setChip("c-rec", m.recordingId ? "● запись " + m.recordingId : "запись выкл", m.recordingId ? "rec" : "");
      if (m.recordingId) addFeed("Начата запись " + m.recordingId, "lb");
      loadRecordings(); break;
    case "calibration":
      threshold = m.profile && m.profile.eyeThreshold; renderLimits();
      addFeed(`Калибровка: наклон ${num(m.profile.neutralPitch)}°, поворот ${num(m.profile.neutralYaw)}°, T=${num(threshold, 2)}`, "lb"); break;
    case "frame": {
      const t = m.capturedUs / 1e6; tNow = Math.max(tNow, t);
      lastFrames[m.engine] = m;
      if (!engines.includes(m.engine)) engines.push(m.engine);
      const s = m.signals || {};
      if (m.engine === primary) { boxes.push([m.capturedUs, s.box || null]); while (boxes.length > 120) boxes.shift(); }
      for (const c of CHARTS) for (const [k] of c.lines) if (k in s) push(m.engine + "|" + k, t, s[k]);
      const b = s.blendshapes || {};
      for (const [k] of CHARTS[3].lines) if (k in b) push(m.engine + "|" + k, t, b[k]);
      dirty = true; break;
    }
    case "derived": {
      const t = m.atUs / 1e6; tNow = Math.max(tNow, t); lastDerived = m;
      // The trip's automata count from their session start (sessionOffsetUs).
      const now = m.atUs - (m.sessionOffsetUs || 0);
      const ms = m.measure; lastMeasure = ms || null;
      if (ms) for (const k of ["pitchDown","yaw","eyeLeft","eyeRight"]) if (k in ms) push("derived|m_" + k, t, ms[k]);
      if (ms && ms.eyeThreshold != null) threshold = ms.eyeThreshold;
      for (const ch of ["eyes", "head"]) {
        const c = m[ch]; if (!c) continue;
        const timer = (c.phase === "signPresent" || c.phase === "warning") && c.signStartedUs != null ? (now - c.signStartedUs) / 1e6 : 0;
        push("derived|" + ch + "Timer", t, timer);
        if (prevPhase[ch] !== c.phase) {
          if (prevPhase[ch] !== null) addFeed(`${ch === "eyes" ? "Глаза" : "Голова"}: ${PHASES[c.phase] || c.phase} (${c.reason})`);
          prevPhase[ch] = c.phase;
        }
      }
      if (m.stats) { push("derived|aps", t, m.stats.aps); push("derived|latency10", t, m.stats.latencyMs / 10); }
      const z = m.zone || "unknown";
      if (!zones.length || zones[zones.length - 1][1] !== z) zones.push([t, z]);
      while (zones.length > 1 && zones[1][0] < t - WINDOW - 5) zones.shift();
      updateHeader(); renderLimits(); dirty = true; break;
    }
    case "event": {
      const e = m.event;
      const name = e.type === "eyes_closed" ? "глаза закрыты"
        : e.type === "head_pitch_down" ? "голова опущена"
        : e.type === "distraction" ? `отвлечение (${e.kind || ""}, ${e.zone || ""})` : e.type;
      const off = (m.sessionOffsetUs || 0) / 1e6;
      if (m.change === "started") {
        events.push({t: e.thresholdUs / 1e6 + off, type: e.type});
        { alarms.push({id: e.id, type: e.type, t: e.thresholdUs / 1e6 + off, t0: e.signStartedUs / 1e6 + off, t1: null, verdict: null, cause: null}); renderAlarms(); }
        addFeed((e.type === "distraction" ? "Расширение: " : "ТРЕВОГА: ") + name, "ev");
      }
      else {
        addFeed(`Событие «${name}» ${m.change === "ended" ? "завершено" + (e.endReason ? " (" + e.endReason + ")" : "") : m.change}`, "ev");
        const a = alarms.find(a => a.id === e.id); if (a && m.change === "ended" && e.endedUs != null) { a.t1 = e.endedUs / 1e6 + off; renderAlarms(); }
      }
      dirty = true; break;
    }
    case "label": {
      const t = m.atUs / 1e6;
      if (m.edge === "start") bands.push({step: m.step, rep: m.rep, t0: t, t1: null});
      else { const b = [...bands].reverse().find(b => b.step === m.step && b.t1 == null); if (b) b.t1 = t; }
      addFeed(`метка ${m.step}${m.rep ? " #" + m.rep : ""} ${m.edge === "start" ? "начало" : "конец"}${m.aborted ? " (прервано)" : ""}`, "lb");
      dirty = true; break;
    }
    case "mark": {
      const t = m.atUs / 1e6; marks.push({t, kind: m.kind, source: m.source, eventId: m.eventId, cause: m.cause});
      const a = m.eventId ? alarms.find(a => a.id === m.eventId) : (m.kind === "false" || m.kind === "true") ? latestAlarm(t) : null;
      if (a && (m.kind === "false" || m.kind === "true")) { a.verdict = m.kind; if (m.cause) a.cause = m.cause; }
      addFeed(`${KINDS[m.kind] || m.kind}${m.cause ? " (" + (CAUSES[m.cause] || m.cause) + ")" : ""} · ${m.source === "phone" ? "с телефона" : "с Mac"}`, "lb");
      renderAlarms(); dirty = true; break;
    }
    case "trip":
      if (m.phase) tripPhase = m.phase;
      if (m.ended) { addFeed("Поездка завершена", "lb"); tripPhase = "idle"; }
      if (m.heat) addFeed(`Нагрев: ${m.heat.thermal}, экономия ${m.heat.economy ? "вкл" : "выкл"}, каждый ${m.heat.emitEvery}-й кадр`);
      break;
    case "device": {
      const th = {nominal:"норма",fair:"тёплый",serious:"горячий",critical:"перегрев"};
      const parts = ["телефон: " + (th[m.thermal] || m.thermal)];
      if (m.battery != null) parts.push(Math.round(m.battery * 100) + "%" + (m.batteryState === "charging" ? " ⚡" : ""));
      if (m.arkitFps != null) parts.push("ARKit " + m.arkitFps + " к/с");
      if (m.mlKitDone != null) parts.push("ML Kit " + m.mlKitDone + "/с");
      if (m.mlKitOrientation) parts.push(m.mlKitOrientation);
      if (m.jpegs) parts.push(`видео ${m.jpegs} к/с, ${Math.round((m.jpegBytes || 0) / 1024)} КБ/с`);
      setChip("c-device", parts.join(" · "), m.thermal === "serious" || m.thermal === "critical" ? "bad" : "");
      break;
    }
    case "lab":
      if (m.prompt !== undefined) document.getElementById("prompt").textContent = m.prompt || "";
      if (m.note) addFeed(m.note);
      break;
  }
}
function num(v, d = 1) { return v == null || !isFinite(v) ? "—" : Number(v).toFixed(d); }
// Thresholds the automata run on: the trip sends them; the lab's profile
// has them, except «ТЗ 2.2 (эталон)», which runs on the user's settings.
function limitsOf(m) {
  const p = m.detectionProfile || {}, st = m.settings || {}, th = m.thresholds || {};
  const src = p.id === "tz-2.2" ? st : p;
  const pick = (k, d) => th[k] != null ? th[k] : src[k] != null ? src[k] : d;
  const att = p.attention || m.attentionSettings || {};
  return {
    id: p.id || "—", eyesClosedUs: pick("eyesClosedUs", 1500000), headDownUs: pick("headDownUs", 2000000),
    pitchThreshold: pick("pitchThreshold", 20), headYawLimit: pick("headYawLimit", 30), maximumGapUs: pick("maximumGapUs", 300000),
    eyeYawLimit: th.eyeYawLimit != null ? th.eyeYawLimit : ((p.eyeYawLimits || {})[(m.engines || [])[0]]),
    fixedT: th.eyeThreshold != null ? th.eyeThreshold : ((p.eyeThresholds || {})[(m.engines || [])[0]]),
    roadAdapt: att.roadAdaptDegPerMin, yawnJaw: att.yawnJaw, mountRelative: att.mountRelative, gaze: att.gazeAwareEyes, distraction: att.distraction,
  };
}
function renderLimits() {
  const L = limits; if (!L.id) return;
  document.getElementById("l-profile").textContent = "профиль " + L.id + (meta && meta.source === "trip" ? " · поездка" : " · лаборатория");
  const ms = lastMeasure || {}, d = lastDerived || {};
  const eyesNow = ms.eyeLeft != null && ms.eyeRight != null ? Math.max(ms.eyeLeft, ms.eyeRight) : null;
  const T = threshold;
  const timer = ch => { const c = d[ch]; if (!c || c.signStartedUs == null || !(c.phase === "signPresent" || c.phase === "warning")) return null; return (d.atUs - (d.sessionOffsetUs || 0) - c.signStartedUs) / 1e6; };
  const te = timer("eyes"), thd = timer("head");
  const att = d.attention || {};
  const rows = [
    ["", "порог", "сейчас"],
    ["T глаз (оба ниже)", num(T, 2) + (L.fixedT != null ? " (профиль)" : " (по калибровке)"), eyesNow == null ? (att.eyeGate && att.eyeGate !== "none" ? "затвор: " + att.eyeGate : "—") : num(eyesNow, 2), eyesNow != null && T != null && eyesNow < T],
    ["Глаза закрыты", "≥ " + num(L.eyesClosedUs / 1e6, 1) + " с", te == null ? "—" : num(te, 1) + " с", te != null && te >= L.eyesClosedUs / 1e6],
    ["Наклон головы", "> " + num(L.pitchThreshold, 0) + "°", num(ms.pitchDown, 1) + "°", ms.pitchDown != null && ms.pitchDown > L.pitchThreshold],
    ["Голова опущена", "≥ " + num(L.headDownUs / 1e6, 1) + " с", thd == null ? "—" : num(thd, 1) + " с", thd != null && thd >= L.headDownUs / 1e6],
    ["|Поворот| для головы", "≤ " + num(L.headYawLimit, 0) + "°", num(ms.yaw, 1) + "°", ms.yaw != null && Math.abs(ms.yaw) > L.headYawLimit],
    ["Разрыв кадров", "до " + Math.round(L.maximumGapUs / 1000) + " мс", ""],
    ["Предел вида глаз", L.eyeYawLimit != null ? num(L.eyeYawLimit, 0) + "°" : "—", ""],
    ["Подстройка «дороги»", L.roadAdapt != null ? num(L.roadAdapt, 1) + "°/мин" : "нет", ""],
    ["Затвор зевка", L.yawnJaw != null ? "jawOpen ≥ " + num(L.yawnJaw, 2) : "нет", ""],
    ["Углы от «дороги»", L.mountRelative ? "да" : "нет (от камеры)", ""],
    ["Отвлечение", L.distraction ? "вкл" : "выкл", ""],
    ["Глаза: автомат / голова", (d.eyes ? (PHASES[d.eyes.phase] || d.eyes.phase) : "—") + " / " + (d.head ? (PHASES[d.head.phase] || d.head.phase) : "—"), tripPhase ? "поездка: " + tripPhase : ""],
  ];
  limitsTable.innerHTML = rows.map((r, i) => i === 0 ? `<tr><th></th><th>${r[1]}</th><th>${r[2]}</th></tr>` : `<tr><td>${r[0]}</td><td>${r[1]}</td><td class="${r[3] ? "over" : ""}">${r[2]}</td></tr>`).join("");
}
function latestAlarm(t) { let best = null; for (const a of alarms) if (a.t <= t + 1 && t - a.t <= 60) best = a; return best; }
const ALARM_NAMES = {eyes_closed:"глаза закрыты", head_pitch_down:"голова опущена", distraction:"отвлечение"};
function renderAlarms() {
  setChip("c-alarms", `тревог ${alarms.length} · разобрано ${alarms.filter(a => a.verdict).length}`, alarms.some(a => !a.verdict) ? "bad" : "");
  if (!alarms.length) { alarmsList.innerHTML = `<div style="color:var(--muted)">Тревог пока нет. Метки ставятся кнопками выше, клавишами или двойным касанием экрана телефона.</div>`; return; }
  alarmsList.innerHTML = alarms.slice().reverse().map(a => {
    const opts = (a.verdict === "true" ? TRUE_CAUSES : FALSE_CAUSES).map(c => `<option value="${c}" ${a.cause === c ? "selected" : ""}>${CAUSES[c]}</option>`).join("");
    return `<div class="row"><b>${fmtT(a.t)}</b> ${ALARM_NAMES[a.type] || a.type}${a.t1 != null ? ` · ${num(a.t1 - a.t0, 1)} с` : ""}` +
      ` <span class="verdict">${a.verdict ? KINDS[a.verdict] : "не разобрана"}</span>` +
      ` <button data-id="${a.id}" data-v="false" class="${a.verdict === "false" ? "on" : ""}">Ложная</button>` +
      `<button data-id="${a.id}" data-v="true" class="${a.verdict === "true" ? "on" : ""}">Верная</button>` +
      `<select data-id="${a.id}"><option value="">причина…</option>${opts}</select></div>`;
  }).join("");
}
let socket = null;
function send(obj) { if (socket && socket.readyState === 1) socket.send(JSON.stringify(obj)); }
function sendMark(kind, extra) { send(Object.assign({type: "mark", kind}, extra || {})); }
alarmsList.addEventListener("click", e => {
  const b = e.target.closest("button[data-id]"); if (!b) return;
  const a = alarms.find(a => a.id === b.dataset.id); const cause = a && a.cause && (b.dataset.v === "true" ? TRUE_CAUSES : FALSE_CAUSES).includes(a.cause) ? a.cause : undefined;
  sendMark(b.dataset.v, {eventId: b.dataset.id, cause});
});
alarmsList.addEventListener("change", e => {
  const s = e.target.closest("select[data-id]"); if (!s || !s.value) return;
  const a = alarms.find(a => a.id === s.dataset.id); if (!a) return;
  sendMark(a.verdict === "true" ? "true" : "false", {eventId: a.id, cause: s.value});
});
marksCard.querySelector(".marks").addEventListener("click", e => { const b = e.target.closest("button[data-kind]"); if (b) sendMark(b.dataset.kind); });
document.addEventListener("keydown", e => {
  if (e.target.closest && e.target.closest("input,select,textarea")) return;
  const k = {" ": "mark", f: "false", t: "true", m: "miss", "а": "false", "е": "true", "ь": "miss"}[e.key.toLowerCase()];
  if (k) { e.preventDefault(); sendMark(k); }
});
function updateHeader() {
  const m = lastDerived; if (!m) return;
  const st = document.getElementById("status");
  // The lab sends its status; the trip's is read from the automata.
  const warn = ch => m[ch] && m[ch].phase === "warning";
  st.textContent = m.status || (warn("eyes") && warn("head") ? "ТРЕВОГА: глаза и голова" : warn("eyes") ? "ТРЕВОГА: глаза закрыты"
    : warn("head") ? "ТРЕВОГА: голова опущена" : m.eyes || m.head ? "Наблюдение · " + (ZONES[m.zone] || m.zone) : "—");
  st.className = (m.eyes && m.eyes.phase === "warning") || (m.head && m.head.phase === "warning") ? "alarm" : "";
  if (m.stats) {
    setChip("c-aps", "анализов/с " + num(m.stats.aps, 0), m.stats.aps < 10 ? "bad" : "");
    const total = m.stats.latencyMs + (rtt == null ? 0 : rtt / 2);
    setChip("c-lat", `задержка ≈ ${num(total, 0)} мс` + (rtt == null ? "" : ` (сеть ${num(rtt / 2, 0)})`), total > 500 ? "bad" : "");
  }
  setChip("c-zone", "зона: " + (ZONES[m.zone] || m.zone));
  if (m.driver) setChip("c-driver", "водитель: " + (DRIVER[m.driver] || m.driver), m.driver === "ambiguous" || m.driver === "different" ? "bad" : "");
  for (const ch of ["eyes", "head"]) {
    const c = m[ch]; if (!c) continue;
    setChip("c-" + ch, `${ch === "eyes" ? "глаза" : "голова"}: ${PHASES[c.phase] || c.phase}`, c.phase === "warning" ? "bad" : "");
  }
  const f = lastFrames[primary] || Object.values(lastFrames)[0];
  const rows = [];
  const all = new Set();
  for (const fr of Object.values(lastFrames)) for (const k of Object.keys(fr.signals || {})) if (k !== "blendshapes" && k !== "engine") all.add(k);
  const names = Object.keys(lastFrames);
  rows.push("<tr><th></th>" + names.map(n => `<th>${n.replace("_face_detection", "").replace("_face_tracking", "")}</th>`).join("") + "</tr>");
  rows.push("<tr><td>лиц</td>" + names.map(n => `<td>${lastFrames[n].faceCount}</td>`).join("") + "</tr>");
  for (const k of all) rows.push(`<tr><td>${k}</td>` + names.map(n => { const v = (lastFrames[n].signals || {})[k]; return `<td>${typeof v === "number" ? num(v, k.startsWith("eyeOpen") || k === "distanceM" ? 2 : 1) : v == null ? "—" : v}</td>`; }).join("") + "</tr>");
  valuesTable.innerHTML = rows.join("");
}

function setup(cv) {
  const dpr = window.devicePixelRatio || 1, w = cv.clientWidth, h = cv.clientHeight;
  if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
  const g = cv.getContext("2d"); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, w, h); return [g, w, h];
}
function drawBands(g, x, h, top) {
  g.font = "11px sans-serif";
  for (const b of bands) {
    const x0 = x(b.t0), x1 = x(b.t1 == null ? tNow : b.t1);
    if (x1 < 0) continue;
    g.fillStyle = css("--band"); g.fillRect(x0, top, Math.max(1, x1 - x0), h - top);
    g.fillStyle = css("--muted"); g.fillText(b.step, Math.max(x0 + 2, 2), top + 11);
  }
  g.strokeStyle = css("--warn"); g.setLineDash([]); g.lineWidth = 2;
  for (const e of events) { const ex = x(e.t); if (ex < 0) continue; g.beginPath(); g.moveTo(ex, top); g.lineTo(ex, h); g.stroke(); }
}
function draw(c) {
  const [g, w, h] = setup(canvases[c.id]);
  const pad = {l: 34, r: 6, t: 4, b: 14};
  const t1 = tNow, t0 = t1 - WINDOW;
  const x = t => pad.l + (t - t0) / WINDOW * (w - pad.l - pad.r);
  const keys = [];
  const owners = c.owner === "derived" ? ["derived"] : engines;
  for (const eng of owners) for (const [k, , color] of c.lines) keys.push([eng + "|" + k, color, eng === primary || eng === "derived" ? PRIMARY_DASH : OTHER_DASH]);
  let lo = c.min, hi = c.max;
  if (c.sym != null) {
    let m = c.sym;
    for (const [k] of keys) for (const [t, v] of series.get(k) || []) if (t >= t0) m = Math.max(m, Math.abs(v));
    m = Math.ceil(m / 10) * 10; lo = -m; hi = m;
  }
  const y = v => pad.t + (hi - v) / (hi - lo) * (h - pad.t - pad.b);
  drawBands(g, x, h - pad.b, pad.t);
  g.strokeStyle = css("--line"); g.fillStyle = css("--muted"); g.lineWidth = 1; g.font = "11px sans-serif"; g.setLineDash([]);
  const ticks = c.sym != null ? [lo, lo / 2, 0, hi / 2, hi] : [lo, (lo + hi) / 2, hi];
  for (const v of ticks) { g.beginPath(); g.moveTo(pad.l, y(v)); g.lineTo(w - pad.r, y(v)); g.stroke(); g.fillText(Number(v.toFixed(2)).toString(), 2, y(v) + 4); }
  for (let s = Math.max(0, Math.ceil(t0 / 5) * 5); s <= t1; s += 5) g.fillText(fmtT(s), x(s) - 14, h - 2);
  const flat = [];
  if (c.threshold && threshold != null) flat.push([threshold, "#888"]);
  if (c.id === "timers") flat.push([thresholds.eyes, "#3b7dd8"], [thresholds.head, "#d23f31"]);
  if (c.id === "meyes" && threshold != null) flat.push([threshold, "#888"]);
  if (c.id === "mhead" && limits.pitchThreshold != null) flat.push([limits.pitchThreshold, "#d23f31"], [limits.headYawLimit, "#3b7dd8"], [-limits.headYawLimit, "#3b7dd8"]);
  for (const [v, col] of flat) { g.strokeStyle = col; g.setLineDash([4, 4]); g.beginPath(); g.moveTo(pad.l, y(v)); g.lineTo(w - pad.r, y(v)); g.stroke(); }
  g.lineWidth = 1.6;
  for (const [k, color, dash] of keys) {
    const s = series.get(k); if (!s || !s.length) continue;
    g.strokeStyle = color; g.setLineDash(dash); g.beginPath();
    let started = false, prevT = null;
    for (const [t, v] of s) {
      if (t < t0 - 1) continue;
      const px = x(t), py = y(Math.max(lo, Math.min(hi, v)));
      if (!started || (prevT != null && t - prevT > 0.4)) g.moveTo(px, py); else g.lineTo(px, py);
      started = true; prevT = t;
    }
    g.stroke();
  }
  g.setLineDash([]);
}
function drawStrip() {
  const [g, w, h] = setup(canvases.strip);
  const pad = 34, t1 = tNow, t0 = t1 - WINDOW;
  const x = t => pad + (t - t0) / WINDOW * (w - pad - 6);
  for (let i = 0; i < zones.length; i++) {
    const [ts, z] = zones[i], te = i + 1 < zones.length ? zones[i + 1][0] : t1;
    g.fillStyle = ZONE_COLORS[z] || "#bbb"; g.fillRect(Math.max(pad, x(ts)), 4, Math.max(0, x(te) - Math.max(pad, x(ts))), 16);
  }
  g.font = "11px sans-serif"; g.fillStyle = css("--muted"); g.fillText("зона", 2, 16); g.fillText("метки", 2, 38);
  for (const b of bands) {
    const x0 = x(b.t0), x1 = x(b.t1 == null ? tNow : b.t1); if (x1 < pad) continue;
    g.fillStyle = css("--accent"); g.fillRect(Math.max(pad, x0), 26, Math.max(2, x1 - Math.max(pad, x0)), 14);
    g.fillStyle = css("--card"); g.fillText(b.step + (b.rep ? " #" + b.rep : ""), Math.max(pad, x0) + 3, 37);
  }
}
const MARK_COLORS = {mark:"#d89a1e", false:"#7b5bd6", true:"#2e9d5b", miss:"#c2571a"};
function drawTrip() {
  const [g, w, h] = setup(canvases.trip);
  const pad = 34, t1 = Math.max(tNow, 60);
  const x = t => pad + t / t1 * (w - pad - 6);
  g.font = "11px sans-serif"; g.fillStyle = css("--muted"); g.fillText("тревоги", 0, 16); g.fillText("метки", 0, 38);
  g.strokeStyle = css("--line"); g.beginPath(); g.moveTo(pad, 22); g.lineTo(w - 6, 22); g.stroke();
  const step = t1 > 1800 ? 600 : t1 > 600 ? 300 : 60;
  for (let s = 0; s <= t1; s += step) g.fillText(fmtT(s).replace(/\.\d$/, ""), x(s) - 10, h - 1);
  for (const a of alarms) { g.fillStyle = a.verdict === "false" ? MARK_COLORS.false : a.verdict === "true" ? MARK_COLORS.true : css("--warn"); g.fillRect(x(a.t0 != null ? a.t0 : a.t), 4, Math.max(3, x(a.t1 != null ? a.t1 : a.t) - x(a.t0 != null ? a.t0 : a.t)), 16); }
  for (const m of marks) { if (m.eventId) continue; g.fillStyle = MARK_COLORS[m.kind] || "#888"; g.beginPath(); g.moveTo(x(m.t), 26); g.lineTo(x(m.t) - 5, 36); g.lineTo(x(m.t) + 5, 36); g.fill(); }
  document.getElementById("t-info").textContent = `${fmtT(tNow).replace(/\.\d$/, "")} · тревог ${alarms.length}, меток ${marks.filter(m => !m.eventId).length}`;
}
function frame() {
  if (dirty) { for (const c of CHARTS) draw(c); drawStrip(); drawTrip(); dirty = false; }
  requestAnimationFrame(frame);
}
// ---- debug video (binary messages: "NSJ1", header length, header, JPEG)
const vstate = {on: false, mirror: false, rot: 0, box: true, last: 0, count: 0, bytes: 0, busy: false};
try { const saved = JSON.parse(localStorage.getItem("nscontrol.video") || "{}"); Object.assign(vstate, {on: saved.on !== false, mirror: !!saved.mirror, rot: saved.rot || 0, box: saved.box !== false}); } catch (e) { vstate.on = true; }
function saveVideo() { try { localStorage.setItem("nscontrol.video", JSON.stringify({on: vstate.on, mirror: vstate.mirror, rot: vstate.rot, box: vstate.box})); } catch (e) {} }
function videoButtons() {
  document.getElementById("v-on").className = vstate.on ? "on" : "";
  document.getElementById("v-mirror").className = vstate.mirror ? "on" : "";
  document.getElementById("v-box").className = vstate.box ? "on" : "";
  if (!vstate.on) document.getElementById("v-info").textContent = "видео выкл";
}
document.getElementById("v-on").onclick = () => { vstate.on = !vstate.on; saveVideo(); videoButtons(); send({type: "video", on: vstate.on}); };
document.getElementById("v-mirror").onclick = () => { vstate.mirror = !vstate.mirror; saveVideo(); videoButtons(); };
document.getElementById("v-rot").onclick = () => { vstate.rot = (vstate.rot + 1) % 4; saveVideo(); };
document.getElementById("v-box").onclick = () => { vstate.box = !vstate.box; saveVideo(); videoButtons(); };
videoButtons();
function nearestBox(us) { let best = null, diff = 200000; for (const [t, b] of boxes) { const d = Math.abs(t - us); if (d < diff) { diff = d; best = b; } } return best; }
async function onJpeg(buf) {
  const view = new DataView(buf);
  if (buf.byteLength < 8 || String.fromCharCode(view.getUint8(0), view.getUint8(1), view.getUint8(2), view.getUint8(3)) !== "NSJ1") return;
  const n = view.getUint32(4, true);
  const head = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 8, n)));
  vstate.count++; vstate.bytes += buf.byteLength;
  if (vstate.busy) return; vstate.busy = true;
  try {
    const bmp = await createImageBitmap(new Blob([new Uint8Array(buf, 8 + n)], {type: "image/jpeg"}));
    drawJpeg(bmp, head); bmp.close && bmp.close();
  } catch (e) { console.error(e); } finally { vstate.busy = false; }
}
// Upright as the phone's preview shows it: rotate by the preview's quarter
// turns, flip when the preview is mirrored, then the page's own choices.
function drawJpeg(bmp, head) {
  const turns = ((head.quarterTurns || 0) + vstate.rot) % 4, odd = turns % 2 === 1;
  const W = odd ? bmp.height : bmp.width, H = odd ? bmp.width : bmp.height;
  if (video.width !== W || video.height !== H) { video.width = W; video.height = H; }
  const g = video.getContext("2d");
  g.save(); g.clearRect(0, 0, W, H);
  if (vstate.mirror) { g.translate(W, 0); g.scale(-1, 1); }
  g.translate(W / 2, H / 2); g.rotate(turns * Math.PI / 2);
  if (head.mirrored) g.scale(-1, 1);
  g.drawImage(bmp, -bmp.width / 2, -bmp.height / 2); g.restore();
  // The contract box is unmirrored portrait; the preview shows it mirrored.
  const b = vstate.box ? nearestBox(head.atUs) : null;
  if (b && vstate.rot === 0) {
    const flip = !!head.mirrored !== vstate.mirror;
    const left = flip ? 1 - b.left - b.width : b.left;
    g.strokeStyle = "#5fd0bf"; g.lineWidth = 2; g.strokeRect(left * W, b.top * H, b.width * W, b.height * H);
  }
  const d = lastDerived;
  if (d) {
    const alarm = (d.eyes && d.eyes.phase === "warning") || (d.head && d.head.phase === "warning");
    g.fillStyle = alarm ? "rgba(179,38,30,.85)" : "rgba(0,0,0,.55)"; g.fillRect(0, H - 22, W, 22);
    g.fillStyle = "#fff"; g.font = "13px sans-serif";
    const ms = d.measure || {};
    g.fillText(`${ZONES[d.zone] || d.zone} · вниз ${num(ms.pitchDown, 0)}° · поворот ${num(ms.yaw, 0)}° · глаза ${num(ms.eyeLeft, 2)}/${num(ms.eyeRight, 2)}${alarm ? " · ТРЕВОГА" : ""}`, 6, H - 7);
  }
}
setInterval(() => { if (vstate.on) document.getElementById("v-info").textContent = vstate.count ? `${vstate.count} к/с · ${Math.round(vstate.bytes / 1024)} КБ/с` : "нет кадров (ARKit? поездка идёт?)"; vstate.count = 0; vstate.bytes = 0; }, 1000);
requestAnimationFrame(frame);

document.getElementById("review-link").href = "/review?k=" + encodeURIComponent(KEY);
async function loadRecordings() {
  try {
    const list = await (await fetch("/recordings?k=" + encodeURIComponent(KEY))).json();
    recList.innerHTML = list.length ? list.map(f => `<div><a href="/recordings/${encodeURIComponent(f.name)}?k=${encodeURIComponent(KEY)}" download>${f.name}</a> · ${(f.bytes / 1024).toFixed(0)} КБ</div>`).join("") : "пока нет";
  } catch (e) { recList.textContent = "список недоступен"; }
}
function connect() {
  const ws = new WebSocket(`ws://${location.host}/ws?k=${encodeURIComponent(KEY)}`);
  ws.binaryType = "arraybuffer"; socket = ws;
  let timer = null;
  ws.onopen = () => { setChip("c-conn", "на связи"); if (vstate.on) send({type: "video", on: true}); timer = setInterval(() => ws.send(JSON.stringify({type: "ping", t: performance.now()})), 1000); };
  ws.onmessage = e => { if (e.data instanceof ArrayBuffer) { if (vstate.on) onJpeg(e.data); return; } try { onLine(JSON.parse(e.data)); } catch (err) { console.error(err); } };
  ws.onclose = () => { clearInterval(timer); setChip("c-conn", "нет связи", "bad"); document.getElementById("status").textContent = "Нет связи с телефоном. Откройте Лабораторию или включите живой дебаг поездки"; setTimeout(connect, 1500); };
}
window.addEventListener("resize", () => dirty = true);
connect();
</script>
</body>
</html>
''';
