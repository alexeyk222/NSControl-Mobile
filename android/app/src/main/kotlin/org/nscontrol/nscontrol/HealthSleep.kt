package org.nscontrol.nscontrol

import android.app.Activity
import android.os.Bundle
import android.widget.TextView
import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.metadata.Device
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import java.time.Instant

class HealthSleep(private val context: Context) {
    val permissions = setOf(HealthPermission.getReadPermission(SleepSessionRecord::class))
    private fun client() = HealthConnectClient.getOrCreate(context)
    suspend fun status(): Map<String, Any> {
        val sdk = HealthConnectClient.getSdkStatus(context)
        if (sdk != HealthConnectClient.SDK_AVAILABLE) return mapOf("status" to "unavailable", "provider" to "health_connect",
            "reason" to if (sdk == HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED)
                "Health Connect requires installation or update" else "Health Connect unavailable on this device")
        return mapOf("status" to if (client().permissionController.getGrantedPermissions().containsAll(permissions))
            "available" else "permission_required", "source" to "Health Connect", "provider" to "health_connect")
    }
    suspend fun read(from: String, to: String): Map<String, Any> {
        val access = status()
        if (access["status"] != "available") return access + ("records" to emptyList<Any>())
        val start = Instant.parse(from); val end = Instant.parse(to)
        require(start < end) { "Invalid sleep window" }
        val readAt = Instant.now()
        val rows = mutableListOf<Map<String, Any?>>()
        var token: String? = null
        val usedTokens = mutableSetOf<String>()
        do {
            // Re-check for each page so a revoked permission cannot keep a long read alive.
            if (!client().permissionController.getGrantedPermissions().containsAll(permissions)) {
                return mapOf("status" to "permission_required", "records" to emptyList<Any>())
            }
            val page = client().readRecords(ReadRecordsRequest(SleepSessionRecord::class,
                timeRangeFilter = TimeRangeFilter.between(start, end), pageSize = 1000, pageToken = token))
            for (record in page.records) {
                if (record.endTime > readAt || record.startTime >= record.endTime) continue
                val device = record.metadata.device
                val base = mapOf("source" to record.metadata.dataOrigin.packageName,
                    "provider_id" to record.metadata.id,
                    "source_modified_at" to record.metadata.lastModifiedTime.toString(),
                    "device" to mapOf("manufacturer" to device?.manufacturer,
                        "model" to device?.model, "type" to device?.type,
                        "is_watch" to (device?.type == Device.TYPE_WATCH)))
                // A session without stage evidence is not assumed to be fully asleep.
                rows += base + mapOf("id" to "${record.metadata.id}:session", "start" to record.startTime.toString(),
                    "end" to record.endTime.toString(), "stage" to "inBed")
                for ((index, stage) in record.stages.withIndex()) {
                    if (stage.startTime >= stage.endTime || stage.endTime > readAt) continue
                    val kind = when (stage.stage) {
                        SleepSessionRecord.STAGE_TYPE_SLEEPING, SleepSessionRecord.STAGE_TYPE_LIGHT,
                        SleepSessionRecord.STAGE_TYPE_DEEP, SleepSessionRecord.STAGE_TYPE_REM -> "asleep"
                        SleepSessionRecord.STAGE_TYPE_AWAKE, SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED,
                        SleepSessionRecord.STAGE_TYPE_OUT_OF_BED -> "awake"
                        else -> "inBed"
                    }
                    rows += base + mapOf("id" to "${record.metadata.id}:stage:$index", "start" to stage.startTime.toString(),
                        "end" to stage.endTime.toString(), "stage" to kind)
                }
            }
            token = page.pageToken?.takeIf { it.isNotEmpty() }
            if (token != null && !usedTokens.add(token)) error("Health Connect repeated pagination token")
        } while (token != null)
        return mapOf("status" to "available", "provider" to "health_connect", "records" to rows, "read_at" to readAt.toString(),
            "snapshot_complete" to true, "sources" to rows.mapNotNull { it["source"] as? String }.distinct(),
            "query_from" to start.toString(), "query_to" to end.toString(),
            "coverage_complete" to false,
            "limitation" to "Health Connect availability and Garmin provenance require device verification; unstaged sessions are not counted as sleep.")
    }
}

class HealthRationaleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(this).apply {
            text = "NSControl читает только завершённые записи сна для локальных рекомендаций. " +
                "Сведения не отправляются на сервер. Полнота сна подтверждается отдельно. " +
                "Доступ можно отозвать в Health Connect; локальные сведения удалить в NSControl."
            textSize = 18f; setPadding(32, 48, 32, 32)
        })
    }
}
