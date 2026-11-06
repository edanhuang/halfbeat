import Foundation

@main struct ToastGateTests {
    static func main() {
        var gate = LyricToastEventGate(startedAtMs: 1000)
        var status: [String: Any] = ["enabled": true, "state": "aligned", "songId": "A", "playingSongId": "A",
            "songName": "Test Song (Remix)", "currentMs": 500, "targetMs": 500,
            "lastAppliedAtMs": 900.0, "updatedAtMs": 2000.0, "changes": 1]
        func consume(_ state: [String: Any], enabled: Bool = true, target: Int = 500, now: Double = 2200) -> LyricToastEvent? {
            gate.consume(state, enabled: enabled, targetMs: target, nowMs: now)
        }
        precondition(consume(status) == nil, "Do not show startup history")
        status["lastAppliedAtMs"] = 2000.0
        precondition(consume(status, enabled: false) == nil, "No success while disabled")
        var invalid = status; invalid["state"] = "error"
        precondition(consume(invalid) == nil, "No toast for failed alignment")
        invalid = status; invalid["playingSongId"] = "B"
        precondition(consume(invalid) == nil, "Reject old-song results")
        precondition(consume(status, target: -500) == nil, "Reject obsolete target")
        let first = consume(status)
        precondition(first?.signedSeconds == "+0.5s")
        precondition(first?.songName == "Test Song (Remix)")
        precondition(consume(status) == nil, "Repeated polls must not replay a toast")
        status["songName"] = "Test Song (Remix) · updated title"
        precondition(consume(status) == nil, "A title-only update is not a new success")
        status["lastAppliedAtMs"] = 2100.0; status["changes"] = 2
        status["currentMs"] = -500; status["targetMs"] = -500
        precondition(consume(status, target: -500)?.signedSeconds == "-0.5s", "New target is a new event")
        status["lastAppliedAtMs"] = 2150.0; status["changes"] = 3
        status["songName"] = "Long\nSong"; status["songId"] = "B"; status["playingSongId"] = "B"
        precondition(consume(status, target: -500)?.songName == "Long Song", "Keep a single line")
        status["lastAppliedAtMs"] = 3000.0; status["changes"] = 4
        precondition(consume(status, target: -500, now: 8000) == nil, "Do not replay stale reconnect history")
        status["lastAppliedAtMs"] = Double.nan
        precondition(consume(status, target: -500) == nil, "Reject nonfinite timestamps")
        print("PASS: toast success gating, startup history, disabled/error, song and target matching, deduplication, signed content, stale events.")
    }
}
