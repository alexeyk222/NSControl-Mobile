using Toybox.Application;
using Toybox.Communications;
using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.System;
using Toybox.Time;
using Toybox.Attention;
using Toybox.Timer;
using Toybox.Lang;
using Toybox.Activity;
using Toybox.SensorHistory;

const APP_VERSION = "1.1";

class SendListener extends Communications.ConnectionListener {
    var _failure;
    function initialize(failure) { ConnectionListener.initialize(); _failure = failure; }
    function onComplete() { }
    function onError() { _failure.invoke(); }
}

class NSControlApp extends Application.AppBase {
    var _view;
    function initialize() { AppBase.initialize(); }
    function getInitialView() {
        _view = new ControlView();
        return [_view, new ControlDelegate(_view)];
    }
    function onStop(state) { if (_view != null) { _view.close(); } }
}

// START/ENTER on an active alert sends "accepted" to the phone, which silences
// the phone alarm for exactly the events the phone currently reports active.
class ControlDelegate extends WatchUi.BehaviorDelegate {
    var _view;
    function initialize(view) { BehaviorDelegate.initialize(); _view = view; }
    function onSelect() as Lang.Boolean { return _view.userAccept(); }
}

class ControlView extends WatchUi.View {
    var _reason = "Откройте NSControl на телефоне";
    var _status = "Нет связи";
    var _epoch; var _connection; var _session; var _snapshot = false;
    var _sync; var _pending; var _offset = 0.0d; var _syncTime = 0; var _pendingTime = 0;
    var _seen = {}; var _cancelled = {}; var _serial = 0;
    var _lastTimer = 0; var _phoneConnected = false; var _timer;
    // Presentation state from the latest snapshot.
    var _level = "idle"; var _fatigue = "unknown"; var _driveMin = null;
    var _activeIds = []; var _alerting = false; var _alertTitle = "";
    var _ticks = 0;

    function initialize() {
        View.initialize();
        reset();
        Communications.registerForPhoneAppMessages(method(:onMessage));
        _timer = new Timer.Timer();
        _timer.start(method(:connectionTick), 1000, true);
        ready();
    }
    function close() {
        _timer.stop();
        Communications.registerForPhoneAppMessages(null);
    }
    function reset() {
        _connection = null; _session = null; _snapshot = false; _sync = null; _pending = null;
        _seen = {}; _cancelled = {}; _activeIds = []; _alerting = false;
        _serial += 1;
        // Wall time identifies the epoch only; TTL never compares wall clocks.
        _epoch = Time.now().value().toString() + ":" + System.getTimer().toString() + ":" + _serial.toString();
    }
    function send(data) {
        try { Communications.transmit(data, null, new SendListener(method(:transportError))); }
        catch (e) { transportError(); }
    }
    function transportError() { reset(); _status = "Нет связи"; _level = "idle"; WatchUi.requestUpdate(); }
    function ready() {
        send({"v"=>1, "type"=>"ready", "message_id"=>_epoch, "receiver_epoch"=>_epoch});
    }
    function envelope(type) {
        _serial += 1;
        return {"v"=>1, "type"=>type, "message_id"=>_epoch+":"+_serial.toString(),
            "connection_id"=>_connection, "receiver_epoch"=>_epoch, "session_id"=>_session};
    }
    function connectionTick() as Void {
        var current = System.getTimer();
        var connected = System.getDeviceSettings().phoneConnected;
        if (current < _lastTimer || connected != _phoneConnected) {
            reset();
            _status = connected ? "Синхронизация" : "Нет связи";
            if (!connected) { _level = "idle"; }
            if (connected) { ready(); }
            WatchUi.requestUpdate();
        }
        _phoneConnected = connected; _lastTimer = current;
        _ticks += 1;
        // Telemetry once a minute, only over an established handshake.
        if (_snapshot && _ticks % 60 == 5) { sendVitals(); }
        if (_ticks % 30 == 0) { WatchUi.requestUpdate(); }
    }
    function sendVitals() {
        var data = envelope("vitals");
        var info = Activity.getActivityInfo();
        if (info != null && info.currentHeartRate != null) { data["hr"] = info.currentHeartRate; }
        var battery = latestBodyBattery();
        if (battery != null) { data["body_battery"] = battery; }
        var stress = latestStress();
        if (stress != null) { data["stress"] = stress; }
        if (data.size() > 6) { send(data); }
    }
    function sampleValue(history) {
        if (history == null) { return null; }
        var sample = history.next();
        return (sample != null && sample.data != null) ? sample.data.toNumber() : null;
    }
    function latestBodyBattery() {
        try {
            if ((Toybox has :SensorHistory) && (SensorHistory has :getBodyBatteryHistory)) {
                return sampleValue(SensorHistory.getBodyBatteryHistory({:period=>1}));
            }
        } catch (e) { }
        return null;
    }
    function latestStress() {
        try {
            if ((Toybox has :SensorHistory) && (SensorHistory has :getStressHistory)) {
                return sampleValue(SensorHistory.getStressHistory({:period=>1}));
            }
        } catch (e) { }
        return null;
    }
    function userAccept() as Lang.Boolean {
        if (!_alerting) { return false; }
        _alerting = false;
        if (_snapshot && _activeIds.size() > 0) {
            var data = envelope("user_ack");
            data["event_ids"] = _activeIds;
            send(data);
            _status = "Подтверждение отправлено";
        } else {
            _status = "Скрыто на часах";
        }
        WatchUi.requestUpdate();
        return true;
    }
    function ack(m, status, haptic) {
        _serial += 1;
        send({"v"=>1, "type"=>"ack", "message_id"=>_epoch+":"+_serial.toString(),
            "ack_message_id"=>m["message_id"], "connection_id"=>_connection,
            "receiver_epoch"=>_epoch, "session_id"=>_session, "status"=>status, "haptic_requested"=>haptic});
        _status = label(status); WatchUi.requestUpdate();
    }
    function label(status) {
        if (status.equals("accepted")) { return "Сигнал запрошен"; }
        if (status.equals("synchronized") || status.equals("state_only")) { return "Связь установлена"; }
        if (status.equals("cancelled")) { return "Принято"; }
        if (status.equals("expired")) { return "Срок истёк"; }
        if (status.equals("duplicate")) { return "Уже принято"; }
        return "Нужна синхронизация";
    }
    function onMessage(packet as Communications.PhoneAppMessage) as Void {
        try { processMessage(packet.data); }
        catch (e) { reset(); _status = "Ошибка сообщения"; ready(); WatchUi.requestUpdate(); }
    }
    function applySnapshot(m) {
        _reason = m["recommendation"] != null ? m["recommendation"] : m["reason"];
        if (_reason == null) { _reason = "Нет активных предупреждений"; }
        _level = m["level"] instanceof Lang.String ? m["level"] : "observing";
        _fatigue = m["fatigue"] instanceof Lang.String ? m["fatigue"] : "unknown";
        _driveMin = m["drive_min"] instanceof Lang.Number ? m["drive_min"] : null;
        _activeIds = m["active_event_ids"] instanceof Lang.Array ? m["active_event_ids"] : [];
        if (_activeIds.size() == 0) { _alerting = false; }
    }
    function processMessage(m) {
        if (!(m instanceof Lang.Dictionary) || m["v"] != 1) { return; }
        if (m["type"] == "hello") {
            reset();
            send({"v"=>1, "type"=>"ready", "message_id"=>_epoch, "receiver_epoch"=>_epoch,
                "connection_id"=>m["connection_id"]});
            return;
        }
        if (m["receiver_epoch"] != _epoch || m["message_id"] == null || m["connection_id"] == null) { return; }
        var now = System.getTimer();
        if (now < _lastTimer) { reset(); ready(); return; }
        _lastTimer = now;
        var type = m["type"];
        if (type == "snapshot") {
            if (_connection != m["connection_id"]) {
                _sync = null; _pending = null; _seen = {}; _cancelled = {};
            } else if (_session != m["session_id"]) {
                _seen = {}; _cancelled = {};
            }
            var first = !_snapshot;
            _connection = m["connection_id"]; _session = m["session_id"]; _snapshot = true;
            applySnapshot(m);
            ack(m, "state_only", false);
            if (first) { sendVitals(); }
            return;
        }
        if (!_snapshot || m["connection_id"] != _connection) { ack(m, "snapshot_required", false); return; }
        if (m["session_id"] != _session) { ack(m, "session_mismatch", false); return; }
        if (type == "ping") {
            _pending = m["message_id"];
            _pendingTime = now;
            send({"v"=>1,"type"=>"pong","message_id"=>_epoch+":pong:"+_pending,
                "ack_message_id"=>_pending,"connection_id"=>_connection,"session_id"=>_session,
                "receiver_epoch"=>_epoch,
                "phone_sent_us"=>m["phone_sent_us"],"watch_received_ms"=>now,"watch_sent_ms"=>System.getTimer()});
            return;
        }
        if (type == "clock_sync") {
            if (m["sync_id"] == null || m["sync_id"] != _pending || m["watch_minus_phone_lower_ms"] == null) { ack(m,"invalid_sync",false); return; }
            if (now - _pendingTime > 30000) { ack(m,"invalid_sync",false); return; }
            var offset = m["watch_minus_phone_lower_ms"].toDouble();
            if (offset == null || offset != offset || offset > 1000000000000000.0d || offset < -1000000000000000.0d) { ack(m,"invalid_sync",false); return; }
            _sync = m["sync_id"]; _pending = null; _offset = offset; _syncTime = _pendingTime;
            ack(m,"synchronized",false); return;
        }
        if (type == "cancel") {
            if (m["all"] == true) { _snapshot = false; _alerting = false; }
            else if (m["target_ids"] instanceof Lang.Array) {
                var targets = m["target_ids"] as Lang.Array;
                for (var i=0; i<targets.size(); i+=1) { _cancelled[targets[i]] = true; }
                _alerting = false;
            }
            ack(m,"cancelled",false); return;
        }
        if (type != "alert") { ack(m,"state_only",false); return; }
        var target = m["event_id"] != null ? m["event_id"] : m["recommendation_id"];
        if (target == null || m["occurred_us"] == null || m["ttl_ms"] != 2000) { ack(m,"invalid",false); return; }
        if (_cancelled.hasKey(target)) { ack(m,"cancelled",false); return; }
        if (_seen.hasKey(m["message_id"]) || _seen.hasKey("target:"+target)) { ack(m,"duplicate",false); return; }
        if (_sync == null || m["sync_id"] != _sync || now - _syncTime > 30000) { ack(m,"unsynchronized",false); return; }
        if (_seen.size() >= 512) { ack(m,"capacity",false); return; }
        // Last age check immediately precedes the vibration API; fail closed on timer rollover.
        now = System.getTimer();
        var age = now.toDouble() - m["occurred_us"].toDouble()/1000.0d - _offset + 1.0d + 0.001d*(now-_syncTime);
        if (now < _syncTime || age != age || age < 0 || age > 2000) { ack(m,"expired",false); return; }
        _seen[m["message_id"]] = true; _seen["target:"+target] = true;
        if (!(Attention has :vibrate)) { ack(m,"haptic_unavailable",false); return; }
        try {
            Attention.vibrate([new Attention.VibeProfile(100, 600), new Attention.VibeProfile(0, 200), new Attention.VibeProfile(100, 600)]);
            _alertTitle = m["reason"] != null ? m["reason"] : "Предупреждение";
            _reason = m["recommendation"] != null ? m["recommendation"] : _alertTitle;
            _alerting = true;
            if (m["event_id"] != null) { _level = "warning"; }
            ack(m,"accepted",true);
            // Best effort extras after the acknowledged vibration request.
            try { if (Attention has :backlight) { Attention.backlight(true); } } catch (e) { }
            try { if (Attention has :playTone) { Attention.playTone(Attention.TONE_ALARM); } } catch (e) { }
        } catch (e) { ack(m,"haptic_error",false); }
    }

    function levelColor() {
        if (_alerting || _level.equals("warning")) { return Graphics.COLOR_RED; }
        if (_level.equals("observing")) {
            if (_fatigue.equals("high")) { return Graphics.COLOR_RED; }
            if (_fatigue.equals("moderate")) { return Graphics.COLOR_ORANGE; }
            return Graphics.COLOR_GREEN;
        }
        if (_level.equals("limited")) { return Graphics.COLOR_YELLOW; }
        if (_level.equals("unavailable")) { return Graphics.COLOR_ORANGE; }
        return Graphics.COLOR_DK_GRAY;
    }
    function levelText() {
        if (_level.equals("observing")) { return "Наблюдение"; }
        if (_level.equals("limited")) { return "Ограничено"; }
        if (_level.equals("warning")) { return "Предупреждение"; }
        if (_level.equals("unavailable")) { return "Камера недоступна"; }
        return _snapshot ? "Поездка не начата" : "NSControl";
    }
    function fatigueText() {
        if (_fatigue.equals("high")) { return "Усталость: высокая"; }
        if (_fatigue.equals("moderate")) { return "Усталость: умеренная"; }
        if (_fatigue.equals("low")) { return "Усталость не видна"; }
        return null;
    }
    function drawWrapped(dc, text, font, y, width, height) {
        var fitted = text;
        if (Graphics has :fitTextToArea) { fitted = Graphics.fitTextToArea(text, font, width, height, true); }
        if (fitted == null) { fitted = ""; }
        dc.drawText(dc.getWidth()/2, y, font, fitted, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
    function onUpdate(dc) {
        var w = dc.getWidth(); var h = dc.getHeight(); var x = w/2;
        var center = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;
        if (_alerting) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_RED); dc.clear();
            dc.drawText(x, h*18/100, Graphics.FONT_MEDIUM, "ВНИМАНИЕ", center);
            drawWrapped(dc, _alertTitle, Graphics.FONT_SMALL, h*42/100, w*80/100, h*24/100);
            if (!_reason.equals(_alertTitle)) {
                drawWrapped(dc, _reason, Graphics.FONT_XTINY, h*65/100, w*74/100, h*16/100);
            }
            dc.drawText(x, h*85/100, Graphics.FONT_XTINY, "START — принять", center);
            return;
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK); dc.clear();
        dc.setColor(levelColor(), Graphics.COLOR_TRANSPARENT);
        if (dc has :setPenWidth) { dc.setPenWidth(8); }
        dc.drawCircle(x, h/2, x - 5);
        if (dc has :setPenWidth) { dc.setPenWidth(1); }
        dc.drawText(x, h*17/100, Graphics.FONT_SMALL, levelText(), center);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        drawWrapped(dc, _reason, Graphics.FONT_XTINY, h*40/100, w*76/100, h*26/100);
        var details = "";
        if (_driveMin != null) { details = "В пути " + (_driveMin / 60).toString() + ":" + (_driveMin % 60).format("%02d"); }
        var fatigue = fatigueText();
        if (fatigue != null && _level.equals("observing")) {
            dc.drawText(x, h*61/100, Graphics.FONT_XTINY, fatigue, center);
        }
        if (details.length() > 0) { dc.drawText(x, h*69/100, Graphics.FONT_XTINY, details, center); }
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, h*79/100, Graphics.FONT_XTINY, _status, center);
        dc.drawText(x, h*89/100, Graphics.FONT_XTINY, APP_VERSION, center);
    }
}
