import AppKit
import Foundation
import ServiceManagement

struct OffsetConfig: Codable {
    var schema = 1
    var enabled = true
    var targetMs = 500
    var leaseUntilMs: Double = 0
    var toastOnAlign = true

    init() {}

    // 旧配置文件没有新字段，缺省按默认值补齐，不能因为多了一个开关就丢掉整个配置。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        targetMs = try container.decodeIfPresent(Int.self, forKey: .targetMs) ?? 500
        leaseUntilMs = try container.decodeIfPresent(Double.self, forKey: .leaseUntilMs) ?? 0
        toastOnAlign = try container.decodeIfPresent(Bool.self, forKey: .toastOnAlign) ?? true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LyricOffsetMenubar", isDirectory: true)
    var config = OffsetConfig()
    var item: NSStatusItem!
    var timer: Timer?
    var maintenance = false
    var lastError: String?
    var connection = "waiting"
    lazy var bridge = RuntimeBridge(support: support)
    var attemptedPIDs = Set<pid_t>()
    var missingConnectionTicks = 0
    var cachedStatus: [String: Any] = [:]
    private let panel = StatusPanel()
    private let successToast = SuccessToast()
    private var toastEvents = LyricToastEventGate(startedAtMs: Date().timeIntervalSince1970 * 1000)
    private var toastTimer: Timer?
    private var lastToastCheckAtMs: Double = 0
    private var latencyEvents: [[String: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let data = try? Data(contentsOf: support.appendingPathComponent("config.json")),
               let saved = try? JSONDecoder().decode(OffsetConfig.self, from: data),
               saved.schema == 1, abs(saved.targetMs) <= 10000 { config = saved }
        } catch { lastError = error.localizedDescription }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 菜单栏只保留品牌轮廓；模板图像由系统适配明暗模式，时延和开关状态继续在面板及悬浮说明中展示。
        let menuIcon = NSImage(contentsOf: Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf")!)!
        // 图标画布几乎铺满，18pt 在菜单栏里偏大；15pt 更接近系统图标的视觉重量。
        menuIcon.size = NSSize(width: 15, height: 15)
        menuIcon.isTemplate = true
        item.button?.image = menuIcon
        item.button?.imagePosition = .imageOnly
        item.button?.setAccessibilityLabel("歌词对齐")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)

        // 面板只负责展示与回调，配置落盘、连接和心跳仍由这里掌握。
        panel.onToggleEnabled = { [weak self] value in self?.setEnabled(value) }
        panel.onChangeOffset = { [weak self] value in self?.setTarget(value) }
        panel.onToggleToast = { [weak self] value in self?.setShowsToast(value) }
        panel.onToggleLaunch = { [weak self] value in self?.setLaunchAtLogin(value) }
        panel.onOpenMusic = { [weak self] in self?.openMusic() }
        panel.onQuit = { [weak self] in self?.quit() }
        panel.onCopyDiagnostics = { [weak self] in self?.copyDiagnostics() }

        writeConfig()
        bridge.tick()
        refresh()

        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.writeConfig(); self?.bridge.tick(); self?.autoConnect(); self?.refresh()
            }
        }
        // 面板打开、菜单跟踪或系统弹窗期间都要继续续租，否则会被误认为菜单栏已退出。
        for mode in [RunLoop.Mode.common, .modalPanel, .eventTracking] { RunLoop.main.add(timer!, forMode: mode) }
        // 独立读取成功事件，避免浮层等待两秒心跳；不重复触发连接或修改歌词。
        toastTimer = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in self?.checkToastEvent() }
        for mode in [RunLoop.Mode.common, .modalPanel, .eventTracking] { RunLoop.main.add(toastTimer!, forMode: mode) }
        if CommandLine.arguments.contains("--show-panel") {
            // 状态项排好之前锚点是无效的，延后一拍再弹。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPanel() }
        }
    }

    func label(_ ms: Int) -> String {
        if ms == 0 { return "不偏移" }
        return "\(ms > 0 ? "提前" : "延后") \(String(format: "%.1f", Double(abs(ms)) / 1000)) 秒"
    }

    func writeConfig(expired: Bool = false) {
        // 设置持久化与接管有效期分开：退出只撤销有效期，保留用户的开关和目标，不回滚歌曲偏移。
        config.leaseUntilMs = expired ? 0 : Date().timeIntervalSince1970 * 1000 + 8000
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: support.appendingPathComponent("config.json"), options: .atomic)
        } catch { lastError = "配置写入失败：\(error.localizedDescription)" }
    }

    func refresh() {
        let now = Date().timeIntervalSince1970 * 1000
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.netease.163music").isEmpty
        // 状态由另一进程持续写入；绕过文件缓存，短暂读取失败时保留最近的有效快照并按时间判定失联。
        if let data = try? Data(contentsOf: support.appendingPathComponent("status.json"), options: .uncached),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { cachedStatus = object }
        let status = cachedStatus
        let fresh = now - (status["updatedAtMs"] as? Double ?? 0) < 5000
        connection = fresh ? (status["state"] as? String ?? "waiting") : "disconnected"

        // 注入成功但接口对不上，或注入时报「页面/模块不支持」，都归为“版本不兼容”。
        let probe = status["probe"] as? [String: Any]
        let bridgeError = bridge.error ?? ""
        let injectionUnsupported = ["Unsupported player runtime", "Unsupported lyric state",
                                    "找不到受支持的网易云播放器页面"]
            .contains { bridgeError.contains($0) }
        let incompatible = (probe?["verdict"] as? String) == "incompatible" || injectionUnsupported

        let level: StatusPanel.State.Level
        let hint: String
        if incompatible {
            level = .error; hint = "网易云音乐版本不兼容"
        } else if let error = lastError {
            level = .error; hint = error
        } else if maintenance {
            level = .waiting; hint = "正在重新连接网易云…"
        } else if !running {
            level = .off; hint = "网易云音乐未运行"
        } else if bridgeError.contains("Player initializing") {
            level = .waiting; hint = "等待网易云播放器初始化"
        } else if !fresh {
            level = bridge.connected ? .waiting : .off
            hint = bridge.connected ? "等待歌词状态" : "等待连接"
        } else if !config.enabled {
            level = .off; hint = "自动对齐已关闭"
        } else {
            switch connection {
            case "aligned": level = .ok; hint = "歌词已对齐"
            case "no-lyrics": level = .waiting; hint = "当前歌曲无可调整歌词"
            case "invalid-offset": level = .error; hint = "歌词偏移数据无效"
            case "error": level = .error; hint = status["error"] as? String ?? "适配异常"
            case "disabled": level = .waiting; hint = "等待设置生效"
            default: level = .waiting; hint = "等待歌词加载"
            }
        }

        // 歌名那行同时承担未运行/异常的提示，不再多写一行说明。
        let song = status["songName"] as? String ?? ""
        let songText: String
        if !running { songText = "网易云音乐未运行" }
        else if let error = lastError { songText = error }
        else if level == .error { songText = hint }
        else { songText = fresh && !song.isEmpty ? song : "—" }

        item.button?.title = ""
        item.button?.appearsDisabled = !config.enabled
        item.button?.toolTip = "歌词偏移：\(label(config.targetMs))\n\(hint)"
        panel.update(StatusPanel.State(songName: songText, offsetMs: config.targetMs, enabled: config.enabled,
                                       showsToast: config.toastOnAlign,
                                       launchesAtLogin: SMAppService.mainApp.status == .enabled,
                                       incompatible: incompatible, hint: hint, level: level))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(); return false
    }

    @objc func togglePanel() {
        if panel.shown { panel.hide(); return }
        // 面板因这次点击先失去 key 而收起时，不要立刻又被同一次点击打开。
        if Date().timeIntervalSince(panel.hiddenAt) < 0.15 { return }
        showPanel()
    }

    func showPanel() {
        refresh()
        guard let button = item.button else { return }
        panel.show(relativeTo: button)
    }

    func setEnabled(_ value: Bool) {
        config.enabled = value
        writeConfig(); refresh()
    }

    func setTarget(_ ms: Int) {
        config.targetMs = min(max(ms, -10000), 10000)
        writeConfig(); refresh()
    }

    func setShowsToast(_ value: Bool) {
        config.toastOnAlign = value
        writeConfig(); refresh()
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch { lastError = "开机自启动设置失败：\(error.localizedDescription)" }
        refresh()
    }

    @objc func openMusic() {
        panel.hide()
        let launch = NSWorkspace.OpenConfiguration()
        if config.enabled { launch.arguments = ["--remote-debugging-port=\(RuntimeBridge.port)", "--remote-debugging-address=127.0.0.1"] }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/NeteaseMusic.app"), configuration: launch)
    }

    private func checkToastEvent() {
        let checkedAtMs = Date().timeIntervalSince1970 * 1000
        let checkGapMs = lastToastCheckAtMs > 0 ? checkedAtMs - lastToastCheckAtMs : 0
        lastToastCheckAtMs = checkedAtMs
        // 关掉“对齐时弹窗”后只是不打扰，不影响歌词对齐；事件本身仍按时间与去重规则过滤。
        guard config.toastOnAlign,
              let data = try? Data(contentsOf: support.appendingPathComponent("status.json"), options: .uncached),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = toastEvents.consume(status, enabled: config.enabled, targetMs: config.targetMs,
                                             nowMs: Date().timeIntervalSince1970 * 1000) else { return }
        successToast.show(event, on: item.button?.window?.screen)
        // Only record actual success presentations. Keep a bounded local history for
        // separating player lyric load, bridge alignment and App timer delays.
        let presentedAtMs = Date().timeIntervalSince1970 * 1000
        let record: [String: Any] = ["presentedAtMs": presentedAtMs,
                                    "appliedToToastMs": presentedAtMs - event.appliedAtMs,
                                    "toastCheckGapMs": checkGapMs,
                                    "bridge": status["timing"] as? [String: Any] ?? [:]]
        latencyEvents.append(record)
        if latencyEvents.count > 40 { latencyEvents.removeFirst(latencyEvents.count - 40) }
        if let data = try? JSONSerialization.data(withJSONObject: latencyEvents) {
            try? data.write(to: support.appendingPathComponent("latency.json"), options: .atomic)
        }
    }

    // 诊断信息打成一段 JSON 放进剪贴板，方便用户直接贴出来排查。
    func copyDiagnostics() {
        let payload: [String: Any] = [
            "app": ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                    "bridge": RuntimeBridge.bridgeVersion],
            "config": ["enabled": config.enabled, "targetMs": config.targetMs, "toastOnAlign": config.toastOnAlign],
            "connection": ["connected": bridge.connected, "state": connection,
                           "error": bridge.error ?? "", "appError": lastError ?? ""],
            "status": cachedStatus,
            "recentLatency": latencyEvents
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "{}"
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        panel.hide()
        successToast.show(message: "已复制诊断结果", on: item.button?.window?.screen)
    }

    func autoConnect() {
        guard config.enabled, !maintenance,
              let player = NSRunningApplication.runningApplications(withBundleIdentifier: "com.netease.163music").first else {
            missingConnectionTicks = 0; return
        }
        if bridge.connected { missingConnectionTicks = 0; return }
        missingConnectionTicks += 1
        // 普通入口启动的播放器可能没有本机调试接口；先等待初始化，每个进程至多重启一次，避免重连循环反复中断播放。
        if missingConnectionTicks >= 5 && !attemptedPIDs.contains(player.processIdentifier) {
            attemptedPIDs.insert(player.processIdentifier); missingConnectionTicks = 0
            restartMusic(debug: true)
        }
    }

    func restartMusic(debug: Bool) {
        // 连接模式切换必须重启播放器才能应用启动参数；只请求正常退出，超时不强杀，避免丢失播放器自身状态。
        guard !maintenance else { return }
        maintenance = true; refresh()
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.netease.163music")
        applications.forEach { _ = $0.terminate() }
        let deadline = Date().addingTimeInterval(12)
        func waitForExit() {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.netease.163music").isEmpty {
                if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: waitForExit) }
                else { self.maintenance = false; self.show("网易云尚未退出，请手动退出后重试连接。"); self.refresh() }
                return
            }
            let launch = NSWorkspace.OpenConfiguration()
            if debug { launch.arguments = ["--remote-debugging-port=\(RuntimeBridge.port)", "--remote-debugging-address=127.0.0.1"] }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/NeteaseMusic.app"), configuration: launch) { app, error in
                DispatchQueue.main.async {
                    self.maintenance = false
                    if let app = app { self.attemptedPIDs.insert(app.processIdentifier) }
                    self.lastError = error?.localizedDescription
                    self.missingConnectionTicks = 0; self.refresh()
                }
            }
        }
        waitForExit()
    }

    func show(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "歌词对齐"; alert.informativeText = message
        alert.addButton(withTitle: "好"); alert.runModal()
    }

    @objc func quit() {
        panel.hide()
        writeConfig(expired: true)
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        toastTimer?.invalidate()
        writeConfig(expired: true)
    }
}

let lockURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LyricOffsetMenubar")
try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)
let lockFD = open(lockURL.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
