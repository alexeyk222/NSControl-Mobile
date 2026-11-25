/// The lab page served to the browser on the Mac. Self-contained (no CDN):
/// it must work in a closed Wi-Fi and never loads anything but the numbers
/// stream of this phone.
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
    <span class="chip" id="c-eyes">глаза —</span>
    <span class="chip" id="c-head">голова —</span>
    <span class="chip" id="c-rec">запись —</span>
  </div>
</header>
<main id="grid"></main>
<script>
"use strict";
const KEY = new URLSearchParams(location.search).get("k") || "";
const WINDOW = 30;
const PRIMARY_DASH = [], OTHER_DASH = [6, 4];
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
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
  {id:"timers", title:"Автоматы ТЗ, с", sub:"длительность признака · пунктир — пороги", min:0, max:3.5, lines:[
    ["eyesTimer","глаза","#3b7dd8"],["headTimer","голова","#d23f31"]], marks:[]},
  {id:"perf", title:"Производительность", sub:"анализов/с · задержка конвейера, мс/10", min:0, max:40, lines:[
    ["aps","анализов/с","#2e9d5b"],["latency10","задержка, мс/10","#d89a1e"]]},
];
const series = new Map();   // "engine|key" -> [[t,v]]
const bands = [];           // {step, rep, t0, t1}
const events = [];          // {t, type}
const zones = [];           // [t, zone]
let engines = [], primary = null, tNow = 0, threshold = null, thresholds = {eyes:1.5, head:2.0};
let rtt = null, lastDerived = null, lastFrames = {}, dirty = true;
let prevPhase = {eyes:null, head:null};

function el(tag, cls, html) { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; }
const grid = document.getElementById("grid");
const canvases = {};
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
const recCard = el("div", "card wide"); recCard.appendChild(el("h3", null, "Записи на телефоне<span>JSONL, только числа</span>"));
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
}
function setChip(id, text, cls) { const c = document.getElementById(id); c.textContent = text; c.className = "chip" + (cls ? " " + cls : ""); }

function onLine(m) {
  switch (m.type) {
    case "pong": rtt = performance.now() - m.t; return;
    case "meta":
      reset(); engines = m.engines || []; primary = engines[0] || null;
      setChip("c-engine", "движок " + (engines.join(" + ") || "—"));
      setChip("c-rec", m.recordingId ? "● запись " + m.recordingId : "запись выкл", m.recordingId ? "rec" : "");
      if (m.recordingId) addFeed("Начата запись " + m.recordingId, "lb");
      loadRecordings(); break;
    case "calibration":
      threshold = m.profile && m.profile.eyeThreshold;
      addFeed(`Калибровка: наклон ${num(m.profile.neutralPitch)}°, поворот ${num(m.profile.neutralYaw)}°, T=${num(threshold, 2)}`, "lb"); break;
    case "frame": {
      const t = m.capturedUs / 1e6; tNow = Math.max(tNow, t);
      lastFrames[m.engine] = m;
      if (!engines.includes(m.engine)) engines.push(m.engine);
      const s = m.signals || {};
      for (const c of CHARTS) for (const [k] of c.lines) if (k in s) push(m.engine + "|" + k, t, s[k]);
      const b = s.blendshapes || {};
      for (const [k] of CHARTS[3].lines) if (k in b) push(m.engine + "|" + k, t, b[k]);
      dirty = true; break;
    }
    case "derived": {
      const t = m.atUs / 1e6; tNow = Math.max(tNow, t); lastDerived = m;
      const now = m.atUs;
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
      updateHeader(); dirty = true; break;
    }
    case "event": {
      const e = m.event, name = e.type === "eyes_closed" ? "глаза закрыты" : "голова опущена";
      if (m.change === "started") { events.push({t: e.thresholdUs / 1e6, type: e.type}); addFeed("ТРЕВОГА: " + name, "ev"); }
      else addFeed(`Событие «${name}» ${m.change === "ended" ? "завершено (" + e.endReason + ")" : m.change}`, "ev");
      dirty = true; break;
    }
    case "label": {
      const t = m.atUs / 1e6;
      if (m.edge === "start") bands.push({step: m.step, rep: m.rep, t0: t, t1: null});
      else { const b = [...bands].reverse().find(b => b.step === m.step && b.t1 == null); if (b) b.t1 = t; }
      addFeed(`метка ${m.step}${m.rep ? " #" + m.rep : ""} ${m.edge === "start" ? "начало" : "конец"}${m.aborted ? " (прервано)" : ""}`, "lb");
      dirty = true; break;
    }
    case "lab":
      if (m.prompt !== undefined) document.getElementById("prompt").textContent = m.prompt || "";
      if (m.note) addFeed(m.note);
      break;
  }
}
function num(v, d = 1) { return v == null || !isFinite(v) ? "—" : Number(v).toFixed(d); }
function updateHeader() {
  const m = lastDerived; if (!m) return;
  const st = document.getElementById("status");
  st.textContent = m.status || "—";
  st.className = (m.eyes && m.eyes.phase === "warning") || (m.head && m.head.phase === "warning") ? "alarm" : "";
  if (m.stats) {
    setChip("c-aps", "анализов/с " + num(m.stats.aps, 0), m.stats.aps < 10 ? "bad" : "");
    const total = m.stats.latencyMs + (rtt == null ? 0 : rtt / 2);
    setChip("c-lat", `задержка ≈ ${num(total, 0)} мс` + (rtt == null ? "" : ` (сеть ${num(rtt / 2, 0)})`), total > 500 ? "bad" : "");
  }
  setChip("c-zone", "зона: " + (ZONES[m.zone] || m.zone));
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
  const owners = c.id === "timers" || c.id === "perf" ? ["derived"] : engines;
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
  for (let s = Math.ceil(t0 / 5) * 5; s <= t1; s += 5) g.fillText(fmtT(s), x(s) - 14, h - 2);
  const flat = [];
  if (c.threshold && threshold != null) flat.push([threshold, "#888"]);
  if (c.id === "timers") flat.push([thresholds.eyes, "#3b7dd8"], [thresholds.head, "#d23f31"]);
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
function frame() {
  if (dirty) { for (const c of CHARTS) draw(c); drawStrip(); dirty = false; }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

async function loadRecordings() {
  try {
    const list = await (await fetch("/recordings?k=" + encodeURIComponent(KEY))).json();
    recList.innerHTML = list.length ? list.map(f => `<div><a href="/recordings/${encodeURIComponent(f.name)}?k=${encodeURIComponent(KEY)}" download>${f.name}</a> · ${(f.bytes / 1024).toFixed(0)} КБ</div>`).join("") : "пока нет";
  } catch (e) { recList.textContent = "список недоступен"; }
}
function connect() {
  const ws = new WebSocket(`ws://${location.host}/ws?k=${encodeURIComponent(KEY)}`);
  let timer = null;
  ws.onopen = () => { setChip("c-conn", "на связи"); timer = setInterval(() => ws.send(JSON.stringify({type: "ping", t: performance.now()})), 1000); };
  ws.onmessage = e => { try { onLine(JSON.parse(e.data)); } catch (err) { console.error(err); } };
  ws.onclose = () => { clearInterval(timer); setChip("c-conn", "нет связи", "bad"); document.getElementById("status").textContent = "Нет связи с телефоном. Откройте Лабораторию"; setTimeout(connect, 1500); };
}
window.addEventListener("resize", () => dirty = true);
connect();
</script>
</body>
</html>
''';
