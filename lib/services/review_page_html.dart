/// The review page (docs/trip-debug.md): served by the phone at `/review`
/// next to the live page, or written to a file by `tool/review_page.dart`
/// and opened on the Mac with local files. It goes through every alarm and
/// mark of a recorded trip with its clip and its numbers and saves the
/// verdicts as `nscontrol-<id>.review.json` (numbers and words only).
/// Self-contained: no CDN, nothing leaves the phone and the Mac.
const reviewPageHtml = r'''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NSControl · Разбор поездки</title>
<style>
:root{--bg:#f3f6f4;--card:#fff;--fg:#14211d;--muted:#5d6b66;--line:#d9e1dd;--accent:#126d62;--warn:#b3261e;--ok:#2e7d4f;--band:rgba(18,109,98,.09)}
@media (prefers-color-scheme:dark){:root{--bg:#101815;--card:#18231f;--fg:#e4ece8;--muted:#93a39d;--line:#2a3833;--accent:#5fd0bf;--warn:#ff8a80;--ok:#7fd69b;--band:rgba(95,208,191,.10)}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
header{position:sticky;top:0;z-index:2;background:var(--bg);padding:12px 16px 8px;border-bottom:1px solid var(--line)}
h1{font-size:24px;margin:0 0 6px}
.bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
button,select,input,textarea{font:inherit;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:8px;padding:4px 10px}
button{cursor:pointer}
button:hover{border-color:var(--accent)}
button.on{background:var(--accent);color:var(--card);border-color:var(--accent)}
button.bad.on{background:var(--warn);border-color:var(--warn)}
main{display:grid;grid-template-columns:minmax(260px,340px) 1fr;gap:12px;padding:12px 16px 40px}
@media (max-width:820px){main{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:10px 12px}
.card h3{margin:0 0 6px;font-size:14px;display:flex;justify-content:space-between;gap:8px}
.card h3 span{font-weight:400;color:var(--muted);font-size:12px}
#items{max-height:calc(100vh - 170px);overflow:auto}
.item{padding:6px 4px;border-bottom:1px solid var(--line);cursor:pointer;display:flex;gap:6px;align-items:baseline}
.item.sel{background:var(--band)}
.item .t{font-variant-numeric:tabular-nums;color:var(--muted);min-width:52px}
.item .v{margin-left:auto;font-size:12px;font-weight:600}
.v.false{color:var(--warn)} .v.true{color:var(--ok)} .v.none{color:var(--muted)}
.detail{display:grid;grid-template-columns:minmax(240px,420px) 1fr;gap:12px}
@media (max-width:1100px){.detail{grid-template-columns:1fr}}
.vwrap{background:#000;border-radius:10px;display:flex;justify-content:center;min-height:160px;overflow:hidden}
#clip{max-width:100%;max-height:560px;display:block}
canvas.plot{width:100%;height:170px;display:block}
.muted{color:var(--muted)}
table{border-collapse:collapse;font-variant-numeric:tabular-nums;font-size:13px;width:100%}
td,th{padding:2px 6px;border-bottom:1px solid var(--line);text-align:left}
.verdicts{display:flex;flex-wrap:wrap;gap:6px;margin:6px 0}
textarea{width:100%;min-height:48px}
#summary td:nth-child(n+2){text-align:right}
a{color:var(--accent)}
</style>
</head>
<body>
<header>
  <h1>Разбор поездки</h1>
  <div class="bar">
    <select id="rec"><option value="">запись на телефоне…</option></select>
    <label class="muted">или файлы на Mac: <input type="file" id="files" multiple accept=".jsonl,.ndjson,.json"></label>
    <button id="save">Сохранить разбор на телефоне</button>
    <button id="download">Скачать разбор</button>
    <span id="status" class="muted">Выберите поездку.</span>
  </div>
</header>
<main>
  <div class="card"><h3>Тревоги и метки<span id="count"></span></h3><div id="items"></div></div>
  <div>
    <div class="card" id="detail"><span class="muted">Слева — тревоги и метки поездки. Клавиши: ↑/↓ — выбор, F — ложная, T — верная, U — спорно, пробел — пуск клипа.</span></div>
    <div class="card" style="margin-top:12px"><h3>Итог<span>по разбору</span></h3><div id="summary" class="muted">—</div></div>
  </div>
</main>
<script>
"use strict";
const KEY = new URLSearchParams(location.search).get("k") || "";
const q = s => document.querySelector(s);
const CAUSES = {mirror:"зеркало",blind_spot:"слепая зона / через плечо",instruments:"приборы / магнитола",phone:"телефон",talk:"разговор / смех",squint:"прищур / солнце",glare:"блики / очки",yawn:"зевок",bump:"кочка / тряска",face_lost:"лицо потеряно / край кадра",mount:"держатель сдвинулся",other:"другое",
  drowsy:"сонливость",deliberate:"намеренно (проверка)",long_look:"долго смотрел вниз"};
const FALSE_CAUSES = ["mirror","blind_spot","instruments","phone","talk","squint","glare","yawn","bump","face_lost","mount","other"];
const TRUE_CAUSES = ["drowsy","deliberate","long_look","other"];
const TYPES = {eyes_closed:"глаза закрыты", head_pitch_down:"голова опущена", distraction:"отвлечение"};
const ZONES = {road:"дорога",mirror_left:"левое зеркало",mirror_right:"правое зеркало",mirror_rear:"салонное зеркало",instruments:"приборы",console:"консоль",off_camera:"вне камеры",unknown:"—"};
const MARK_VERDICTS = {no_issue:"всё в порядке", miss_eyes:"пропуск: глаза", miss_head:"пропуск: голова", false_alarm:"ложная тревога (без события)", unsure:"спорно"};
let rec = null, review = null, items = [], sel = -1, clips = [], localFiles = null;

function fmtT(us) { const t = us / 1e6, m = Math.floor(t / 60), s = (t % 60).toFixed(1).padStart(4, "0"); return `${m}:${s}`; }
function num(v, d = 1) { return v == null || !isFinite(v) ? "—" : Number(v).toFixed(d); }
function status(t) { q("#status").textContent = t; }

async function listPhone() {
  if (!KEY) return;
  try {
    const list = await (await fetch("/recordings?k=" + encodeURIComponent(KEY))).json();
    const sel = q("#rec");
    for (const f of list) { const o = document.createElement("option"); o.value = f.name; o.textContent = `${f.name.includes("trip-") ? "🚗 " : ""}${f.name} · ${(f.bytes / 1048576).toFixed(1)} МБ`; sel.appendChild(o); }
  } catch (e) { status("Список записей недоступен: откройте страницу по ссылке с телефона или выберите файлы."); }
}

// Streams the JSONL and keeps what the review needs: meta, calibrations,
// events, marks, labels, trip lines, derived (10/s) and every 6th frame.
async function parseStream(stream, onProgress) {
  const r = {meta: null, cal: [], events: [], marks: [], derived: [], frames: [], trip: [], firstUs: null, lastUs: 0};
  const reader = stream.pipeThrough(new TextDecoderStream()).getReader();
  let rest = "", n = 0, fi = 0;
  const line = l => {
    if (!l) return; let m; try { m = JSON.parse(l); } catch (e) { return; }
    const t = m.atUs != null ? m.atUs : m.capturedUs; if (t != null) { if (r.firstUs == null) r.firstUs = t; if (t > r.lastUs) r.lastUs = t; }
    switch (m.type) {
      case "meta": r.meta = m; break;
      case "calibration": r.cal.push(m); break;
      case "event": r.events.push(m); break;
      case "mark": r.marks.push(m); break;
      case "trip": r.trip.push(m); break;
      case "derived": r.derived.push({t: m.atUs, zone: m.zone, ms: m.measure || null, gate: m.attention && m.attention.eyeGate, driver: m.attention && m.attention.driver,
        eyes: m.eyes && m.eyes.phase, head: m.head && m.head.phase}); break;
      case "frame": if ((fi++ % 6) === 0) { const s = m.signals || {}; r.frames.push({t: m.capturedUs, n: m.faceCount, p: s.headPitchDown, y: s.headYawLeft, l: s.eyeOpenLeft, rr: s.eyeOpenRight}); } break;
    }
  };
  for (;;) {
    const {value, done} = await reader.read(); if (done) break;
    rest += value; const parts = rest.split("\n"); rest = parts.pop();
    for (const p of parts) line(p);
    n += parts.length; if (onProgress && n % 20000 < parts.length) onProgress(n);
  }
  line(rest);
  return r;
}

function recId() { return rec && rec.meta ? rec.meta.recordingId : ""; }
function limits() {
  const m = rec.meta || {}, p = m.detectionProfile || {}, th = m.thresholds || {}, st = m.settings || {};
  const src = p.id === "tz-2.2" ? st : p;
  const g = (k, d) => th[k] != null ? th[k] : src[k] != null ? src[k] : d;
  return {id: p.id || "—", eyesUs: g("eyesClosedUs", 1500000), headUs: g("headDownUs", 2000000), pitch: g("pitchThreshold", 20), yaw: g("headYawLimit", 30)};
}

function buildItems() {
  items = [];
  const byId = new Map();
  for (const e of rec.events) {
    const ev = e.event || {}, off = e.sessionOffsetUs || 0;
    if (e.change === "started") {
      const it = {kind: "event", eventId: ev.id, eventType: ev.type, atUs: ev.thresholdUs + off, signStartedUs: ev.signStartedUs + off, endedUs: null, verdict: null, cause: null, note: "", live: null};
      byId.set(ev.id, it); items.push(it);
    } else if (e.change === "ended" && byId.has(ev.id) && ev.endedUs != null) byId.get(ev.id).endedUs = ev.endedUs + off;
  }
  for (const m of rec.marks) {
    if (m.eventId && byId.has(m.eventId)) { const it = byId.get(m.eventId); it.live = m.kind; it.verdict = it.verdict || (m.kind === "false" || m.kind === "true" ? m.kind : null); if (m.cause) it.cause = m.cause; continue; }
    if ((m.kind === "false" || m.kind === "true") && !m.eventId) {
      // "the latest alarm": the last one up to 60 s before the mark.
      const prev = items.filter(i => i.kind === "event" && i.atUs <= m.atUs + 1e6 && m.atUs - i.atUs <= 60e6).pop();
      if (prev) { prev.live = m.kind; prev.verdict = prev.verdict || m.kind; continue; }
    }
    items.push({kind: "mark", mark: m.kind, source: m.source, atUs: m.atUs, verdict: null, cause: m.cause || null, note: m.note || "",
      windowFromUs: m.atUs - 10e6, windowToUs: m.atUs + 1e6});
  }
  items.sort((a, b) => a.atUs - b.atUs);
  if (review && Array.isArray(review.items)) {
    for (const s of review.items) {
      const it = items.find(i => s.kind === "event" ? i.eventId === s.eventId : i.kind === "mark" && Math.abs(i.atUs - s.atUs) < 1000);
      if (it) Object.assign(it, {verdict: s.verdict, cause: s.cause || null, note: s.note || "", windowFromUs: s.windowFromUs != null ? s.windowFromUs : it.windowFromUs, windowToUs: s.windowToUs != null ? s.windowToUs : it.windowToUs});
    }
  }
}

function renderList() {
  const box = q("#items");
  const done = items.filter(i => i.verdict).length;
  q("#count").textContent = `${done} из ${items.length} разобрано`;
  box.innerHTML = items.map((it, i) => {
    const title = it.kind === "event" ? (TYPES[it.eventType] || it.eventType) : `метка: ${({mark:"что-то не так",miss:"пропуск",false:"ложная",true:"верная"})[it.mark] || it.mark}${it.source === "phone" ? " (телефон)" : ""}`;
    const v = it.verdict;
    const vt = !v ? "не разобрано" : it.kind === "event" ? ({false:"ложная",true:"верная",unsure:"спорно"})[v] : MARK_VERDICTS[v] || v;
    const cls = !v ? "none" : (v === "false" || v === "false_alarm" || v.startsWith("miss")) ? "false" : v === "true" || v === "no_issue" ? "true" : "none";
    return `<div class="item ${i === sel ? "sel" : ""}" data-i="${i}"><span class="t">${fmtT(it.atUs)}</span><span>${title}${it.cause ? " · " + (CAUSES[it.cause] || it.cause) : ""}</span><span class="v ${cls}">${vt}</span></div>`;
  }).join("") || `<div class="muted">В записи нет тревог и меток.</div>`;
}
q("#items").addEventListener("click", e => { const d = e.target.closest(".item"); if (d) select(+d.dataset.i); });

function near(list, t, key = "t") { let lo = 0, hi = list.length - 1; while (lo < hi) { const mid = (lo + hi) >> 1; if (list[mid][key] < t) lo = mid + 1; else hi = mid; } return list[lo]; }

function select(i) {
  sel = i; renderList(); const it = items[i]; if (!it) return;
  const d = q("#detail"), L = limits();
  const at = near(rec.derived, it.atUs) || {}, ms = at.ms || {};
  const isEvent = it.kind === "event";
  const choices = isEvent ? [["true","Верная (T)"],["false","Ложная (F)"],["unsure","Спорно (U)"]] : Object.entries(MARK_VERDICTS);
  const causes = (it.verdict === "true" ? TRUE_CAUSES : FALSE_CAUSES).map(c => `<option value="${c}" ${it.cause === c ? "selected" : ""}>${CAUSES[c]}</option>`).join("");
  d.innerHTML = `<h3>${isEvent ? (TYPES[it.eventType] || it.eventType) : "Метка"} в ${fmtT(it.atUs)}<span>${isEvent ? `признак с ${fmtT(it.signStartedUs)}${it.endedUs ? ", конец " + fmtT(it.endedUs) : ""}` : (it.source === "phone" ? "с телефона" : "с Mac")}${it.live ? " · на ходу: " + (({false:"ложная",true:"верная"})[it.live] || it.live) : ""}</span></h3>
  <div class="detail"><div><div class="vwrap"><canvas id="clip"></canvas></div><div class="bar" style="margin-top:6px"><button id="play">▶︎</button><input id="scrub" type="range" min="0" max="0" value="0" style="flex:1"><select id="speed"><option>0.5</option><option selected>1</option><option>2</option></select><span id="ct" class="muted"></span></div><div id="clipnote" class="muted"></div></div>
  <div><canvas class="plot" id="pHead"></canvas><canvas class="plot" id="pEyes"></canvas>
  <table><tr><th>В момент</th><th></th></tr><tr><td>зона</td><td>${ZONES[at.zone] || at.zone || "—"}</td></tr><tr><td>наклон / поворот от «дороги»</td><td>${num(ms.pitchDown)}° / ${num(ms.yaw)}° (порог ${L.pitch}°, предел ±${L.yaw}°)</td></tr>
  <tr><td>глаза Л / П, T</td><td>${num(ms.eyeLeft, 2)} / ${num(ms.eyeRight, 2)}, T ${num(ms.eyeThreshold, 2)}</td></tr><tr><td>затвор глаз · водитель</td><td>${at.gate || "—"} · ${at.driver || "—"}</td></tr></table></div></div>
  <div class="verdicts">${choices.map(([v, t]) => `<button data-v="${v}" class="${it.verdict === v ? "on" : ""} ${v === "false" || v.startsWith("miss") || v === "false_alarm" ? "bad" : ""}">${t}</button>`).join("")}
  <select id="cause"><option value="">причина…</option>${causes}</select></div>
  ${!isEvent ? `<div class="bar muted">Окно пропуска: от <input id="wf" type="number" step="0.5" style="width:80px" value="${((it.windowFromUs - it.atUs) / 1e6).toFixed(1)}"> до <input id="wt" type="number" step="0.5" style="width:80px" value="${((it.windowToUs - it.atUs) / 1e6).toFixed(1)}"> с от метки</div>` : ""}
  <textarea id="note" placeholder="Заметка: что было на самом деле">${it.note || ""}</textarea>`;
  d.querySelectorAll(".verdicts button").forEach(b => b.onclick = () => { it.verdict = b.dataset.v; changed(); select(sel); });
  q("#cause").onchange = e => { it.cause = e.target.value || null; changed(); renderList(); };
  q("#note").oninput = e => { it.note = e.target.value; changed(false); };
  if (!isEvent) { q("#wf").onchange = e => { it.windowFromUs = it.atUs + Math.round(+e.target.value * 1e6); changed(false); }; q("#wt").onchange = e => { it.windowToUs = it.atUs + Math.round(+e.target.value * 1e6); changed(false); }; }
  plot("pHead", it, [["pitchDown", "наклон", "#d23f31"], ["yaw", "поворот", "#3b7dd8"]], null, [[L.pitch, "#d23f31"], [L.yaw, "#3b7dd8"], [-L.yaw, "#3b7dd8"]]);
  plot("pEyes", it, [["eyeLeft", "левый", "#3b7dd8"], ["eyeRight", "правый", "#d89a1e"]], [0, 1], [[ms.eyeThreshold, "#888"]]);
  loadClip(it);
}

function plot(id, it, lines, range, flats) {
  const cv = q("#" + id), dpr = devicePixelRatio || 1, w = cv.clientWidth, h = cv.clientHeight;
  cv.width = w * dpr; cv.height = h * dpr; const g = cv.getContext("2d"); g.setTransform(dpr, 0, 0, dpr, 0, 0);
  const t0 = it.atUs - 12e6, t1 = it.atUs + 6e6, pad = 34;
  const pts = rec.derived.filter(d => d.t >= t0 && d.t <= t1 && d.ms);
  let lo = range ? range[0] : -30, hi = range ? range[1] : 30;
  if (!range) { let m = 30; for (const p of pts) for (const [k] of lines) if (p.ms[k] != null) m = Math.max(m, Math.abs(p.ms[k])); m = Math.ceil(m / 10) * 10; lo = -m; hi = m; }
  const x = t => pad + (t - t0) / (t1 - t0) * (w - pad - 4), y = v => 4 + (hi - v) / (hi - lo) * (h - 20);
  const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
  if (it.kind === "event") { g.fillStyle = "rgba(179,38,30,.12)"; g.fillRect(x(it.signStartedUs), 4, Math.max(2, x(it.endedUs || it.atUs) - x(it.signStartedUs)), h - 20); }
  else { g.fillStyle = "rgba(216,154,30,.15)"; g.fillRect(x(it.windowFromUs), 4, Math.max(2, x(it.windowToUs) - x(it.windowFromUs)), h - 20); }
  g.strokeStyle = css("--warn"); g.beginPath(); g.moveTo(x(it.atUs), 4); g.lineTo(x(it.atUs), h - 16); g.stroke();
  g.fillStyle = css("--muted"); g.font = "11px sans-serif"; g.strokeStyle = css("--line");
  for (const v of [lo, (lo + hi) / 2, hi]) { g.beginPath(); g.moveTo(pad, y(v)); g.lineTo(w - 4, y(v)); g.stroke(); g.fillText(String(+v.toFixed(2)), 2, y(v) + 4); }
  for (let s = -12; s <= 6; s += 3) g.fillText((s > 0 ? "+" : "") + s + " с", x(it.atUs + s * 1e6) - 10, h - 2);
  for (const [v, c] of flats) if (v != null) { g.strokeStyle = c; g.setLineDash([4, 4]); g.beginPath(); g.moveTo(pad, y(v)); g.lineTo(w - 4, y(v)); g.stroke(); }
  g.setLineDash([]); g.lineWidth = 1.6;
  for (const [k, , c] of lines) { g.strokeStyle = c; g.beginPath(); let prev = null; for (const p of pts) { const v = p.ms[k]; if (v == null) { prev = null; continue; } const px = x(p.t), py = y(Math.max(lo, Math.min(hi, v))); if (prev == null || p.t - prev > 400000) g.moveTo(px, py); else g.lineTo(px, py); prev = p.t; } g.stroke(); }
  g.lineWidth = 1; g.fillStyle = css("--muted"); g.fillText(lines.map(l => l[1]).join(" · ") + (pts.length ? "" : " — нет данных measure (старая запись)"), pad + 4, 14);
}

// ---- clips: NDJSON with a header line and base64 JPEG lines
let player = {frames: [], i: 0, timer: null, head: null};
async function clipText(c) { return c.file ? await c.file.text() : await (await fetch(`/clips/${encodeURIComponent(c.name)}?k=${encodeURIComponent(KEY)}`)).text(); }
async function loadClip(it) {
  stop(); player = {frames: [], i: 0, timer: null, head: null};
  const note = q("#clipnote");
  // A clip file is named by its first trigger; merged clips run longer.
  const c = clips.find(c => c.head && it.atUs >= c.head.fromUs && it.atUs <= c.head.toUs) ||
    clips.filter(c => !c.head && c.atMs * 1000 - 10e6 <= it.atUs && it.atUs - c.atMs * 1000 <= 60e6).pop();
  if (!c) { note.textContent = clips.length ? "Клипа для этого момента нет." : "Клипов нет: включите «Клипы тревог» в настройках разработчика (только ARKit)."; return; }
  note.textContent = "Загружаю клип…";
  const lines = (await clipText(c)).split("\n").filter(Boolean).map(l => JSON.parse(l));
  player.head = c.head = lines[0]; player.frames = lines.slice(1).filter(l => l.type === "jpeg");
  const scrub = q("#scrub"); scrub.max = player.frames.length - 1;
  player.i = Math.max(0, player.frames.findIndex(f => f.atUs >= it.atUs - 3e6));
  scrub.oninput = () => { player.i = +scrub.value; show(); };
  q("#play").onclick = () => player.timer ? stop() : play();
  note.textContent = `${player.frames.length} кадров, ${fmtT(player.head.fromUs)}–${fmtT(player.head.toUs)}. Только на этом компьютере.`;
  show();
}
async function show() {
  const f = player.frames[player.i]; if (!f) return; const h = player.head, cv = q("#clip"); if (!cv) return;
  const bmp = await createImageBitmap(new Blob([Uint8Array.from(atob(f.data), c => c.charCodeAt(0))], {type: "image/jpeg"}));
  const turns = (h.quarterTurns || 0) % 4, odd = turns % 2 === 1, W = odd ? bmp.height : bmp.width, H = odd ? bmp.width : bmp.height;
  cv.width = W; cv.height = H; const g = cv.getContext("2d");
  g.save(); g.translate(W / 2, H / 2); g.rotate(turns * Math.PI / 2); if (h.mirrored) g.scale(-1, 1); g.drawImage(bmp, -bmp.width / 2, -bmp.height / 2); g.restore();
  const it = items[sel], dt = it ? (f.atUs - it.atUs) / 1e6 : 0, d = near(rec.derived, f.atUs) || {}, ms = d.ms || {};
  const inSign = it && it.kind === "event" && f.atUs >= it.signStartedUs && f.atUs <= (it.endedUs || it.atUs);
  g.fillStyle = inSign ? "rgba(179,38,30,.85)" : "rgba(0,0,0,.55)"; g.fillRect(0, H - 22, W, 22); g.fillStyle = "#fff"; g.font = "13px sans-serif";
  g.fillText(`${dt >= 0 ? "+" : ""}${dt.toFixed(1)} с · ${ZONES[d.zone] || "—"} · вниз ${num(ms.pitchDown, 0)}° · глаза ${num(ms.eyeLeft, 2)}/${num(ms.eyeRight, 2)}`, 6, H - 7);
  q("#scrub").value = player.i; q("#ct").textContent = fmtT(f.atUs);
}
function play() { const speed = +q("#speed").value; q("#play").textContent = "❚❚"; player.timer = setInterval(() => { if (player.i >= player.frames.length - 1) return stop(); player.i++; show(); }, 200 / speed); }
function stop() { if (player.timer) clearInterval(player.timer); player.timer = null; const b = q("#play"); if (b) b.textContent = "▶︎"; }

// ---- summary and saving
let dirty = false;
function changed(list = true) { dirty = true; if (list) renderList(); summary(); status("Есть несохранённые изменения"); }
function observedUs() { const c = rec.cal[0]; return c ? rec.lastUs - c.atUs : rec.lastUs - (rec.firstUs || 0); }
function summary() {
  const ev = items.filter(i => i.kind === "event"), h = observedUs() / 3.6e9;
  const by = (type, v) => ev.filter(i => i.eventType === type && i.verdict === v).length;
  const rows = Object.keys(TYPES).filter(t => ev.some(i => i.eventType === t)).map(t => `<tr><td>${TYPES[t]}</td><td>${ev.filter(i => i.eventType === t).length}</td><td>${by(t, "true")}</td><td>${by(t, "false")}</td><td>${by(t, "unsure")}</td><td>${ev.filter(i => i.eventType === t && !i.verdict).length}</td></tr>`).join("");
  const fp = ev.filter(i => i.verdict === "false" && i.eventType !== "distraction").length;
  const causes = {}; for (const i of ev) if (i.verdict === "false") causes[i.cause || "—"] = (causes[i.cause || "—"] || 0) + 1;
  const misses = items.filter(i => i.kind === "mark" && (i.verdict || "").startsWith("miss")).length;
  q("#summary").innerHTML = `<table><tr><th>Тревога</th><th>всего</th><th>верных</th><th>ложных</th><th>спорных</th><th>не разобрано</th></tr>${rows}</table>
  <p>Наблюдение ${num(h * 60, 0)} мин; ложных тревог глаз и головы ${fp}${h > 0 ? `, ≈ ${num(fp / h, 1)} в час (цель КЧ-03: не больше 1 в час)` : ""}; пропусков по меткам ${misses}.</p>
  <p>Причины ложных: ${Object.entries(causes).map(([c, n]) => `${CAUSES[c] || c} ${n}`).join(", ") || "—"}.</p>
  <p class="muted">Профиль ${limits().id}. Разбор попадает в подбор порогов так: <code>dart run tool/trip_review.dart запись.jsonl --out размеченная.jsonl</code>, затем <code>tool/tune.dart</code> на размеченной записи (docs/trip-debug.md).</p>`;
}
function reviewJson() {
  return {type: "review", schema: 1, recordingId: recId(), reviewedAt: new Date().toISOString(), profile: limits().id, observedUs: observedUs(),
    items: items.map(i => i.kind === "event"
      ? {kind: "event", eventId: i.eventId, eventType: i.eventType, atUs: i.atUs, signStartedUs: i.signStartedUs, endedUs: i.endedUs, verdict: i.verdict, cause: i.cause, note: i.note || undefined, live: i.live || undefined}
      : {kind: "mark", mark: i.mark, source: i.source, atUs: i.atUs, verdict: i.verdict, cause: i.cause, note: i.note || undefined, windowFromUs: i.windowFromUs, windowToUs: i.windowToUs})};
}
q("#save").onclick = async () => {
  if (!rec) return; if (!KEY) return status("Сохранить на телефоне можно только со страницы, открытой с телефона. Скачайте разбор.");
  try { const r = await fetch(`/reviews/${encodeURIComponent(recId())}?k=${encodeURIComponent(KEY)}`, {method: "PUT", body: JSON.stringify(reviewJson())}); if (!r.ok) throw new Error(r.status); dirty = false; status("Разбор сохранён на телефоне: nscontrol-" + recId() + ".review.json"); }
  catch (e) { status("Не сохранилось: " + e.message + ". Скачайте разбор."); }
};
q("#download").onclick = () => { if (!rec) return; const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob([JSON.stringify(reviewJson(), null, 1)], {type: "application/json"})); a.download = `nscontrol-${recId()}.review.json`; a.click(); };
window.addEventListener("beforeunload", e => { if (dirty) { e.preventDefault(); e.returnValue = ""; } });
document.addEventListener("keydown", e => {
  if (e.target.closest("input,select,textarea")) return;
  if (e.key === "ArrowDown" || e.key === "j") { e.preventDefault(); select(Math.min(items.length - 1, sel + 1)); }
  else if (e.key === "ArrowUp" || e.key === "k") { e.preventDefault(); select(Math.max(0, sel - 1)); }
  else if (e.key === " ") { e.preventDefault(); player.timer ? stop() : play(); }
  else { const it = items[sel]; const v = it && it.kind === "event" ? {f: "false", t: "true", u: "unsure", "а": "false", "е": "true", "г": "unsure"}[e.key.toLowerCase()] : null; if (v) { it.verdict = v; changed(); select(sel); } }
});

async function openRecording(source) {
  status("Читаю запись…"); stop(); sel = -1; review = null; clips = [];
  rec = await parseStream(source.stream, n => status(`Читаю запись… ${n} строк`));
  if (!rec.meta) return status("Это не запись NSControl.");
  if (source.review) review = source.review;
  else if (KEY) { try { const r = await fetch(`/reviews/${encodeURIComponent(recId())}?k=${encodeURIComponent(KEY)}`); if (r.ok) review = await r.json(); } catch (e) {} }
  if (source.clips) clips = source.clips;
  else if (KEY) { try { clips = (await (await fetch(`/clips?rec=${encodeURIComponent(recId())}&k=${encodeURIComponent(KEY)}`)).json()).map(c => ({name: c.name, atMs: +((c.name.match(/\.clip-(\d+)-/) || [])[1])})); } catch (e) {} }
  buildItems(); renderList(); summary();
  status(`${recId()}: ${rec.meta.source === "trip" ? "поездка" : "лаборатория"}, ${fmtT(rec.lastUs)}, тревог ${items.filter(i => i.kind === "event").length}, меток ${items.filter(i => i.kind === "mark").length}, клипов ${clips.length}${review ? ", есть сохранённый разбор" : ""}`);
  if (items.length) select(0);
}
q("#rec").onchange = async e => {
  if (!e.target.value) return;
  const r = await fetch(`/recordings/${encodeURIComponent(e.target.value)}?k=${encodeURIComponent(KEY)}`);
  await openRecording({stream: r.body});
};
q("#files").onchange = async e => {
  const files = [...e.target.files];
  const main = files.find(f => f.name.endsWith(".jsonl")); if (!main) return status("Нужен файл записи .jsonl");
  const rv = files.find(f => f.name.endsWith(".review.json"));
  const cl = [];
  for (const f of files.filter(f => f.name.endsWith(".ndjson"))) { const first = (await f.slice(0, 4096).text()).split("\n")[0]; try { cl.push({file: f, name: f.name, head: JSON.parse(first)}); } catch (err) {} }
  await openRecording({stream: main.stream(), review: rv ? JSON.parse(await rv.text()) : null, clips: cl});
};
listPhone();
</script>
</body>
</html>
''';
