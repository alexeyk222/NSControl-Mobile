import Foundation

/// Pure monotonic protocol gate, shared with the command-line acceptance tests.
/// A positive decision permits a haptic request; it never certifies physical output.
final class AlertGate {
    private(set) var connectionID: String?
    private(set) var sessionID: String?
    private var snapshotReceived = false
    private var syncID: String?
    private var lowerOffsetMs: Double = 0
    private var syncedAtMs: Double = 0
    private var cancelled = Set<String>()
    private var seen = Set<String>()
    private var pendingPing: String?
    private var pendingPingAtMs: Double = 0
    private var lastNow: Double = 0

    func disconnect() {
        connectionID = nil; sessionID = nil; snapshotReceived = false
        syncID = nil; pendingPing = nil
        cancelled.removeAll(); seen.removeAll()
    }

    func receive(_ message: [String: Any], nowMs: Double) -> (status: String, vibrate: Bool) {
        if nowMs < lastNow { disconnect() }
        lastNow = nowMs
        guard (message["v"] as? NSNumber)?.intValue == 1,
              let type = message["type"] as? String,
              let connection = message["connection_id"] as? String,
              let messageID = message["message_id"] as? String,
              !messageID.isEmpty else { return ("invalid", false) }

        if type == "snapshot" {
            if connectionID != connection {
                disconnect()
            } else if sessionID != message["session_id"] as? String {
                // The phone's transport clock is process-monotonic across observation sessions.
                cancelled.removeAll(); seen.removeAll()
            }
            connectionID = connection; sessionID = message["session_id"] as? String
            snapshotReceived = true
            return ("state_only", false)
        }
        guard snapshotReceived, connectionID == connection else { return ("snapshot_required", false) }
        guard sessionID == message["session_id"] as? String else { return ("session_mismatch", false) }

        if type == "ping" {
            pendingPing = messageID
            pendingPingAtMs = nowMs
            return ("pong", false)
        }
        if type == "clock_sync" {
            guard let id = message["sync_id"] as? String, id == pendingPing,
                  let offset = message["watch_minus_phone_lower_ms"] as? NSNumber,
                  offset.doubleValue.isFinite else { return ("invalid_sync", false) }
            guard nowMs - pendingPingAtMs <= 30_000 else { return ("invalid_sync", false) }
            syncID = id; lowerOffsetMs = offset.doubleValue; syncedAtMs = pendingPingAtMs
            pendingPing = nil
            return ("synchronized", false)
        }
        if type == "cancel" {
            if message["all"] as? Bool == true {
                // Cancellation changes event state, not the process-monotonic clock.
                snapshotReceived = false
            } else {
                cancelled.formUnion(message["target_ids"] as? [String] ?? [])
            }
            return ("cancelled", false)
        }
        guard type == "alert" else { return ("state_only", false) }
        guard let target = (message["event_id"] ?? message["recommendation_id"]) as? String,
              let occurred = message["occurred_us"] as? NSNumber,
              occurred.doubleValue.isFinite, occurred.doubleValue >= 0,
              (message["ttl_ms"] as? NSNumber)?.doubleValue == 2000 else { return ("invalid", false) }
        if cancelled.contains(target) { return ("cancelled", false) }
        if seen.contains(messageID) || seen.contains("target:" + target) { return ("duplicate", false) }
        guard let expected = syncID, message["sync_id"] as? String == expected,
              nowMs - syncedAtMs <= 30_000 else { return ("unsynchronized", false) }
        // Lower offset => upper bound on the command's age; include clock drift/rounding.
        let upperAge = nowMs - occurred.doubleValue / 1000 - lowerOffsetMs
            + 1 + 0.001 * (nowMs - syncedAtMs)
        guard upperAge >= 0, upperAge <= 2000 else { return ("expired", false) }
        guard seen.count < 4096 else { return ("capacity", false) }
        seen.insert(messageID); seen.insert("target:" + target)
        return ("accepted", true)
    }
}
