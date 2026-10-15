using Toybox.Application;
using Toybox.Communications;
using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.System;
using Toybox.Time;
using Toybox.Attention;
using Toybox.Timer;
using Toybox.Lang;

class SendListener extends Communications.ConnectionListener {
    var _failure;
    function initialize(failure) { ConnectionListener.initialize(); _failure = failure; }
    function onComplete() { }
    function onError() { _failure.invoke(); }
}

class NSControlApp extends Application.AppBase {
    var _view;
    function initialize() { AppBase.initialize(); }
    function getInitialView() { _view = new ControlView(); return [_view]; }
    function onStop(state) { if (_view != null) { _view.close(); } }
}

class ControlView extends WatchUi.View {
    var _reason = "Откройте NSControl на телефоне";
    var _status = "Нет связи";
    var _epoch; var _connection; var _session; var _snapshot = false;
    var _sync; var _pending; var _offset = 0.0d; var _syncTime = 0; var _pendingTime = 0;
    var _seen = {}; var _cancelled = {}; var _serial = 0;
    var _lastTimer = 0; var _phoneConnected = false; var _timer;

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
        _seen = {}; _cancelled = {};
        _serial += 1;
        // Wall time identifies the epoch only; TTL never compares wall clocks.
        _epoch = Time.now().value().toString() + ":" + System.getTimer().toString() + ":" + _serial.toString();
    }
    function send(data) {
        try { Communications.transmit(data, null, new SendListener(method(:transportError))); }
        catch (e) { transportError(); }
    }
    function transportError() { reset(); _status = "Нет связи"; WatchUi.requestUpdate(); }
    function ready() {
        send({"v"=>1, "type"=>"ready", "message_id"=>_epoch, "receiver_epoch"=>_epoch});
    }
    function connectionTick() {
        var current = System.getTimer();
        var connected = System.getDeviceSettings().phoneConnected;
        if (current < _lastTimer || connected != _phoneConnected) {
            reset();
            _status = connected ? "Синхронизация" : "Нет связи";
            if (connected) { ready(); }
            WatchUi.requestUpdate();
        }
        _phoneConnected = connected; _lastTimer = current;
    }
    function ack(m, status, haptic) {
        _serial += 1;
        send({"v"=>1, "type"=>"ack", "message_id"=>_epoch+":"+_serial.toString(),
            "ack_message_id"=>m["message_id"], "connection_id"=>_connection,
            "receiver_epoch"=>_epoch, "session_id"=>_session, "status"=>status, "haptic_requested"=>haptic});
        _status = label(status); WatchUi.requestUpdate();
    }
    function label(status) {
        if (status == "accepted") { return "Сигнал запрошен"; }
        if (status == "synchronized") { return "Связь установлена"; }
        if (status == "state_only") { return "Текущее состояние"; }
        if (status == "cancelled") { return "Отменено"; }
        if (status == "expired") { return "Срок истёк"; }
        if (status == "duplicate") { return "Уже принято"; }
        return "Нужна синхронизация";
    }
    function onMessage(packet) {
        try { processMessage(packet.data); }
        catch (e) { reset(); _status = "Ошибка сообщения"; ready(); WatchUi.requestUpdate(); }
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
            _connection = m["connection_id"]; _session = m["session_id"]; _snapshot = true;
            _reason = m["recommendation"] != null ? m["recommendation"] : m["reason"];
            if (_reason == null) { _reason = "Нет активных предупреждений"; }
            ack(m, "state_only", false); return;
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
            if (m["all"] == true) { _snapshot = false; }
            else if (m["target_ids"] instanceof Lang.Array) {
                for (var i=0; i<m["target_ids"].size(); i+=1) { _cancelled[m["target_ids"][i]] = true; }
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
            Attention.vibrate([new Attention.VibeProfile(100, 500)]);
            _reason = m["reason"] != null ? m["reason"] : "Предупреждение";
            if (m["recommendation"] != null) { _reason = m["recommendation"] + ". " + _reason; }
            ack(m,"accepted",true);
        } catch (e) { ack(m,"haptic_error",false); }
    }
    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK); dc.clear();
        var x = dc.getWidth()/2;
        dc.drawText(x, 30, Graphics.FONT_SMALL, "NSControl", Graphics.TEXT_JUSTIFY_CENTER);
        var length = _reason.length();
        for (var line = 0; line < 5 && line*28 < length; line += 1) {
            var end = (line+1)*28;
            if (end > length) { end = length; }
            var text = _reason.substring(line*28, end);
            if (line == 4 && end < length) { text += "…"; }
            dc.drawText(x, 65 + line*25, Graphics.FONT_XTINY, text, Graphics.TEXT_JUSTIFY_CENTER);
        }
        dc.drawText(x, dc.getHeight()-65, Graphics.FONT_XTINY, _status, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(x, dc.getHeight()-40, Graphics.FONT_XTINY, "1.0 • 1", Graphics.TEXT_JUSTIFY_CENTER);
    }
}
