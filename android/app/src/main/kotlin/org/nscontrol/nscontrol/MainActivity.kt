package org.nscontrol.nscontrol

import android.view.WindowManager
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.health.connect.client.PermissionController
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.launch

class MainActivity : FlutterFragmentActivity() {
    private var events: EventChannel.EventSink? = null
    private lateinit var alerts: PhoneAlert
    private lateinit var sleep: HealthSleep
    private lateinit var garmin: GarminBridge
    private var authorization: MethodChannel.Result? = null
    private val permissionRequest = registerForActivityResult(PermissionController.createRequestPermissionResultContract()) {
        val result = authorization; authorization = null
        if (result != null) lifecycleScope.launch {
            try { result.success(sleep.status()) }
            catch (e: Exception) { result.success(mapOf("status" to "error", "reason" to e.message)) }
        }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        alerts = PhoneAlert(this); sleep = HealthSleep(this)
        garmin = GarminBridge(this) { event -> runOnUiThread { events?.success(event) } }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "nscontrol/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink; sink.success(mapOf("type" to "wearable_status", "status" to garmin.status()))
            }
            override fun onCancel(arguments: Any?) { events = null }
        })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nscontrol/platform").setMethodCallHandler { call, result ->
            lifecycleScope.launch {
                try {
                    when (call.method) {
                        "app.openSettings" -> {
                            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                            result.success(mapOf("status" to "opened"))
                        }
                        "alert.start", "alert.test" -> {
                            alerts.start(call.argument<Number>("volume")?.toDouble() ?: 1.0,
                                call.argument<Boolean>("vibrate") ?: true, call.method == "alert.test")
                            result.success(mapOf("status" to "requested", "physical_output_verified" to false))
                        }
                        "alert.stop" -> { alerts.stop(); result.success(mapOf("status" to "stopped")) }
                        "screen.keepAwake" -> {
                            if (call.argument<Boolean>("enabled") == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            result.success(null)
                        }
                        "sleep.status" -> result.success(sleep.status())
                        "sleep.authorize" -> {
                            val state = sleep.status()
                            if (state["status"] != "permission_required") result.success(state)
                            else if (authorization != null) result.error("busy", "Permission request already open", null)
                            else { authorization = result; permissionRequest.launch(sleep.permissions) }
                        }
                        "sleep.read" -> result.success(sleep.read(requireNotNull(call.argument<String>("from")), requireNotNull(call.argument<String>("to"))))
                        "wearable.status" -> result.success(garmin.status())
                        "wearable.devices" -> result.success(garmin.devices())
                        "wearable.connect" -> garmin.connect(call.argument<String>("deviceId")) { runOnUiThread { result.success(it) } }
                        "wearable.send" -> garmin.send(requireNotNull(call.argument<Map<String, Any?>>("message"))) { runOnUiThread { result.success(it) } }
                        else -> result.notImplemented()
                    }
                } catch (e: SecurityException) {
                    result.success(mapOf("status" to "permission_required", "records" to emptyList<Any>(), "reason" to e.message))
                } catch (e: Exception) {
                    if (call.method.startsWith("alert.")) alerts.stop()
                    result.success(mapOf("status" to "error", "records" to emptyList<Any>(), "reason" to e.message))
                }
            }
        }
    }
    override fun onPause() {
        if (::alerts.isInitialized) alerts.stop()
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        super.onPause()
    }
    override fun onDestroy() {
        if (::alerts.isInitialized) alerts.stop()
        if (::garmin.isInitialized) garmin.close()
        authorization?.error("cancelled", "Activity destroyed", null); authorization = null
        super.onDestroy()
    }
}
