import Foundation

struct LyricToastEvent: Equatable {
    let songID: String
    let songName: String
    let targetMs: Int
    let appliedAtMs: Double
    let changes: Int

    var signedSeconds: String { String(format: "%+.1fs", Double(targetMs) / 1000) }
}

// 只将本次菜单栏运行期间的新成功结果转成浮层事件，历史状态、失败和状态轮询不得反复打扰用户。
struct LyricToastEventGate {
    let startedAtMs: Double
    private var lastEvent: LyricToastEvent?

    init(startedAtMs: Double) { self.startedAtMs = startedAtMs }

    mutating func consume(_ status: [String: Any], enabled: Bool, targetMs: Int, nowMs: Double) -> LyricToastEvent? {
        // 桥接状态来自另一进程，必须同时确认成功、当前歌曲及目标；仅收到连接状态不能视为歌词设置成功。
        guard enabled, status["enabled"] as? Bool == true, status["state"] as? String == "aligned",
              let songID = status["songId"] as? String, !songID.isEmpty,
              songID == status["playingSongId"] as? String,
              let rawName = status["songName"] as? String,
              let currentMs = status["currentMs"] as? Int, currentMs == targetMs,
              status["targetMs"] as? Int == targetMs,
              let appliedAtMs = status["lastAppliedAtMs"] as? Double, appliedAtMs.isFinite,
              let updatedAtMs = status["updatedAtMs"] as? Double, updatedAtMs.isFinite,
              let changes = status["changes"] as? Int, changes > 0 else { return nil }
        // 短暂失联后读到的旧成功不能当成刚刚成功；歌曲、目标和实际偏移也必须同时匹配。
        guard appliedAtMs > startedAtMs, nowMs - appliedAtMs >= -1000, nowMs - appliedAtMs < 4000,
              nowMs - updatedAtMs >= -1000, nowMs - updatedAtMs < 4000 else { return nil }
        let name = rawName.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let event = LyricToastEvent(songID: songID, songName: name, targetMs: targetMs, appliedAtMs: appliedAtMs, changes: changes)
        // 标题可能晚于成功状态补齐，不能把标题更新误当成一次新的歌词设置成功。
        let duplicate = lastEvent.map { $0.songID == event.songID && $0.targetMs == event.targetMs
            && $0.appliedAtMs == event.appliedAtMs && $0.changes == event.changes } ?? false
        guard !duplicate, appliedAtMs >= (lastEvent?.appliedAtMs ?? startedAtMs) else { return nil }
        lastEvent = event
        return event
    }
}
