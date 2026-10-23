package org.nscontrol.nscontrol

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import java.math.BigDecimal

class GarminBridge(private val context: Context, private val emit: (Map<String, Any?>) -> Unit) {
    companion object { const val APP_ID = "936fbf7641ce4a3a922561ead363a448" }
    private val main = Handler(Looper.getMainLooper())
    private val sdk = ConnectIQ.getInstance(context, ConnectIQ.IQConnectType.WIRELESS)
    private var ready = false
    private var reason = "Запуск Garmin Connect IQ"
    private var device: IQDevice? = null
    private var app: IQApp? = null
    init {
        try {
            sdk.initialize(context, false, object : ConnectIQ.ConnectIQListener {
                override fun onSdkReady() { ready = true; reason = "Выберите сопряжённые часы Garmin"; notifyStatus() }
                override fun onInitializeError(error: ConnectIQ.IQSdkErrorStatus) {
                    ready = false; reason = error.name; notifyStatus()
                }
                override fun onSdkShutDown() { ready = false; reason = "Garmin Connect IQ остановлен"; notifyStatus() }
            })
        } catch (e: Exception) { reason = e.message ?: "Garmin SDK unavailable" }
    }
    fun status(): Map<String, Any?> {
        val connected = ready && device != null && runCatching {
            sdk.getDeviceStatus(device) == IQDevice.IQDeviceStatus.CONNECTED
        }.getOrDefault(false)
        return mapOf("status" to if (!ready) "unavailable" else if (connected && app != null) "connected" else "disconnected",
            "connected" to connected, "device_id" to device?.deviceIdentifier?.toString(),
            "reason" to reason, "transport" to "garmin", "foreground_verified" to false)
    }
    private fun notifyStatus() = emit(mapOf("type" to "wearable_status", "status" to status()))
    fun devices(): List<Map<String, Any?>> {
        check(ready) { reason }
        return (sdk.knownDevices ?: emptyList()).map {
            mapOf("id" to it.deviceIdentifier.toString(), "name" to it.friendlyName,
                "connected" to (sdk.getDeviceStatus(it) == IQDevice.IQDeviceStatus.CONNECTED))
        }
    }
    fun connect(id: String?, complete: (Map<String, Any?>) -> Unit) {
        if (!ready) { complete(status()); return }
        val known = sdk.knownDevices ?: emptyList()
        val selected = if (id != null) known.find { it.deviceIdentifier.toString() == id }
            else known.singleOrNull()
        if (selected == null) {
            complete(mapOf("status" to "selection_required", "reason" to "Выберите сопряжённые часы", "devices" to devices())); return
        }
        sdk.unregisterAllForEvents()
        device = selected; app = null; reason = "Проверка приложения NSControl на часах"
        sdk.registerForDeviceEvents(selected) { _, state ->
            reason = state.name; notifyStatus()
        }
        var finished = false
        fun finish(value: Map<String, Any?>) { if (!finished) { finished = true; complete(value) } }
        main.postDelayed({ finish(mapOf("status" to "error", "reason" to "Garmin не ответил за 8 с. Проверьте Garmin Connect и связь.")) }, 8000)
        sdk.getApplicationInfo(APP_ID, selected, object : ConnectIQ.IQApplicationInfoListener {
            override fun onApplicationInfoReceived(installed: IQApp) {
                if (device?.deviceIdentifier != selected.deviceIdentifier) return
                app = installed
                sdk.registerForAppEvents(selected, installed) { _, _, messages, result ->
                    if (result == ConnectIQ.IQMessageStatus.SUCCESS) {
                        for (message in messages ?: emptyList()) {
                            if (message is Map<*, *>) emit(mapOf("type" to "wearable_message", "message" to message))
                        }
                    } else {
                        emit(mapOf("type" to "wearable_status", "status" to mapOf("status" to "error", "reason" to result.name)))
                    }
                }
                reason = "Откройте NSControl на часах для обмена"
                notifyStatus(); finish(status())
            }
            override fun onApplicationNotInstalled(applicationId: String) {
                reason = "Приложение NSControl не установлено на часах"
                notifyStatus(); finish(mapOf("status" to "app_not_installed", "reason" to reason))
            }
        })
    }
    fun send(message: Map<String, Any?>, complete: (Map<String, Any?>) -> Unit) {
        val selected = device; val target = app
        if (!ready || selected == null || target == null || sdk.getDeviceStatus(selected) != IQDevice.IQDeviceStatus.CONNECTED) {
            complete(mapOf("status" to "disconnected", "accepted" to false)); return
        }
        var finished = false
        fun finish(value: Map<String, Any?>) { if (!finished) { finished = true; complete(value) } }
        main.postDelayed({ finish(mapOf("status" to "timeout", "accepted" to false)) }, 3000)
        // Garmin may compress a Java Double to a 32-bit Float. Preserve the offset's
        // precision as decimal text; Monkey C parses it with toDouble(). Other time
        // fields are integers and retain their exact Long representation.
        val wire = message.toMutableMap()
        (wire["watch_minus_phone_lower_ms"] as? Number)?.let {
            wire["watch_minus_phone_lower_ms"] = BigDecimal.valueOf(it.toDouble()).toPlainString()
        }
        // Transient messages are not retained by Garmin Connect for delayed delivery.
        sdk.sendMessage(selected, target, wire, { _, _, result ->
            finish(mapOf("status" to result.name.lowercase(), "accepted" to (result == ConnectIQ.IQMessageStatus.SUCCESS),
                "app_acknowledged" to false, "physical_vibration_verified" to false))
        }, true)
    }
    fun close() { runCatching { sdk.shutdown(context) }; main.removeCallbacksAndMessages(null) }
}
