import AppKit

@main struct ToastVisualCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let toast = SuccessToast()
        let screen = NSScreen.main
        let start = ProcessInfo.processInfo.systemUptime
        let preview = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory() + "lyric-toast-preview.png")
        let step = SuccessToast.stackStep
        let anchorRight = (screen?.visibleFrame.maxX ?? 0) - 20

        var a = 0, b = 0, c = 0
        var enteredAt: [Int: Double] = [:]
        var hidden = Set<Int>()
        var windowFrame = NSRect.zero
        var sawLayerSlide = false
        var checkedStack = false
        var checkedInterrupt = false

        func now() -> Double { ProcessInfo.processInfo.systemUptime - start }
        // 这个环境里 precondition 的消息不会打印，用 stderr 留痕定位失败点。
        func trace(_ message: String) {
            fputs(String(format: "[%.2fs] %@\n", now(), message), stderr)
            fflush(stderr)
        }
        func state(_ id: Int) -> SuccessToast.CardState? { toast.cardStates.first { $0.id == id } }
        func show(_ song: String, _ target: Int) -> Int {
            toast.show(LyricToastEvent(songID: song, songName: song, targetMs: target,
                                       appliedAtMs: Date().timeIntervalSince1970 * 1000, changes: 1), on: screen)
        }
        func checkWindow() {
            if windowFrame == .zero { windowFrame = toast.windowFrame }
            precondition(toast.windowFrame == windowFrame, "Window must never move")
        }

        toast.lifecycleObserver = { phase, id, frame in
            trace("\(phase) card=\(id) live=\(toast.liveCardCount) fading=\(toast.cardStates.count - toast.liveCardCount)")
            checkWindow()
            switch phase {
            case "entered":
                enteredAt[id] = now()
                if id == a {
                    // A 停稳一段时间后插入 B：两张卡片必须同时存在，且按左上方向堆叠。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let startCenter = toast.cardStates.first { $0.id == a }?.presentedCenter ?? .zero
                        b = show("Song B", -500)
                        trace("inserted B=\(b)")
                        // 让位动画必须朝左上目标单调靠近、不越过目标（曾经目标点算错导致飞过头再吸回）。
                        let target = NSPoint(x: startCenter.x - step, y: startCenter.y + step)
                        var previous = startCenter
                        for delay in [0.05, 0.10, 0.15] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                guard let point = toast.cardStates.first(where: { $0.id == a })?.presentedCenter else { return }
                                precondition(point.x >= target.x - 0.5 && point.x <= startCenter.x + 0.5, "Reflow must not overshoot horizontally")
                                precondition(point.y <= target.y + 0.5 && point.y >= startCenter.y - 0.5, "Reflow must not overshoot vertically")
                                precondition(abs(point.x - target.x) <= abs(previous.x - target.x) + 0.5, "Reflow must approach monotonically")
                                previous = point
                            }
                        }
                    }
                }
                if id == b {
                    trace("check stack: count/order/positions")
                    precondition(toast.liveCardCount == 2, "Two cards must coexist")
                    let states = toast.cardStates
                    guard let newest = states.first, let older = states.dropFirst().first else {
                        preconditionFailure("Stack is missing a card")
                    }
                    precondition(newest.id == b && older.id == a, "Newest card must be the one at the anchor")
                    precondition(abs(newest.frame.maxX - anchorRight) < 0.5, "Newest card sits at the anchor")
                    precondition(abs(older.frame.maxX - (newest.frame.maxX - step)) < 0.5, "Older card steps left")
                    precondition(abs(older.frame.minY - (newest.frame.minY + step)) < 0.5, "Older card steps up")
                    checkedStack = true
                    trace("stack OK: newest.maxX=\(newest.frame.maxX) older.maxX=\(older.frame.maxX)")
                    try? toast.exportCardPreview(to: preview)
                }
            case "exitStarted":
                if let entered = enteredAt[id] {
                    precondition(now() - entered >= 2.49, "Each card keeps its own 2.5s dwell")
                }
                if id == a {
                    let before = state(a)?.opacity ?? -1
                    trace("A starts fading, opacity=\(before)")
                    precondition(before > 0.9, "Fading card must start from visible")
                    // 退场途中插入新卡片：正在淡出的卡片既不能被打断，也不能被重置。
                    c = show("Song C", 500)
                    trace("inserted C=\(c) during A exit")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        let after = state(a)?.opacity
                        trace("A opacity after insert=\(String(describing: after))")
                        if let after = after {
                            precondition(after < before + 0.001, "Insertion must not restart the fading card")
                            precondition(after > 0, "Fading card must not snap to transparent")
                        }
                        if let sibling = state(b) {
                            precondition(sibling.opacity > 0.9, "Sibling card stays visible")
                        }
                        checkedInterrupt = true
                        trace("interrupt check OK")
                    }
                }
            case "hidden":
                hidden.insert(id)
                if hidden.contains(a) && hidden.contains(b) && hidden.contains(c) {
                    trace("all hidden, checks: stack=\(checkedStack) interrupt=\(checkedInterrupt) slide=\(sawLayerSlide)")
                    precondition(checkedStack && checkedInterrupt && sawLayerSlide, "Animation checks did not all run")
                    // 上限：连续插入 4 张只保留 3 张。
                    for index in 0..<4 { _ = show("Cap \(index)", 500) }
                    precondition(toast.liveCardCount == 3, "Stack is capped at 3 cards")
                    fputs("PASS: stacked cards on the anchor, independent dwell/fade per card, insertion during an exit keeps the fading card continuous, window never moves, stack capped at 3.\n", stdout)
                    exit(0)
                }
            default:
                break
            }
        }

        a = show("Song A (Remix)", 500)
        trace("inserted A=\(a)")
        // 入场仍是图层位移（窗口不动）；多点采样避免错过 0.2 秒的入场。
        for delay in [0.05, 0.09, 0.13] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                checkWindow()
                if let newest = toast.cardStates.first, newest.slideOffset > 0.3 { sawLayerSlide = true }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            fputs("Toast animation timed out\n", stderr)
            exit(1)
        }
        app.run()
    }
}
