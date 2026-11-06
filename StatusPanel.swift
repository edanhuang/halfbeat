import AppKit

// 自绘菜单栏面板，替代系统菜单：只呈现「网易云音乐 · 当前歌曲 · 歌词偏移」和几个开关。
// 用无边框面板窗口而不是 NSPopover：不要气泡箭头、动画时长可自己定、点击别处一定要关。
final class StatusPanel: NSObject {
    struct State {
        enum Level { case ok, waiting, error, off }
        var songName: String
        var offsetMs: Int
        var enabled: Bool
        var showsToast: Bool
        var launchesAtLogin: Bool
        var incompatible: Bool
        var hint: String
        var level: Level
    }

    var onToggleEnabled: ((Bool) -> Void)?
    var onChangeOffset: ((Int) -> Void)?
    var onToggleToast: ((Bool) -> Void)?
    var onToggleLaunch: ((Bool) -> Void)?
    var onOpenMusic: (() -> Void)?
    var onQuit: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?

    private final class PanelWindow: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private let window: PanelWindow
    private let content = StatusPanelContent()
    private var state: State?
    private var monitors: [Any] = []
    private var activeObserver: NSObjectProtocol?
    private(set) var hiddenAt = Date.distantPast

    override init() {
        window = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 240),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.isFloatingPanel = true
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        // 圆角卡片自己是不透明的，系统按它的轮廓画窗口阴影；不再有 popover 的气泡材质。
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isMovable = false
        window.becomesKeyOnlyIfNeeded = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.contentView = content.view
        content.onToggleEnabled = { [weak self] value in self?.onToggleEnabled?(value) }
        content.onChangeOffset = { [weak self] value in self?.onChangeOffset?(value) }
        content.onToggleToast = { [weak self] value in self?.onToggleToast?(value) }
        content.onToggleLaunch = { [weak self] value in self?.onToggleLaunch?(value) }
        content.onOpenMusic = { [weak self] in self?.onOpenMusic?() }
        content.onQuit = { [weak self] in self?.onQuit?() }
        content.onCopyDiagnostics = { [weak self] in self?.onCopyDiagnostics?() }
    }

    var shown: Bool { window.isVisible }

    func show(relativeTo button: NSStatusBarButton) {
        guard let state = state else { return }
        // 打开前用最新状态刷一次，避免面板里还留着两秒前的歌名。
        content.apply(state)
        let size = content.preferredContentSize
        window.setContentSize(size)
        content.view.frame = NSRect(origin: .zero, size: size)
        window.setFrameOrigin(origin(relativeTo: button, size: size))

        // 面板要先成为当前 App 的 key window，否则第一次点开关/按钮只会激活窗口、不触发控件。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 弹出只做一个短淡入，不做位移，避免窗口阴影每帧重算。
        content.view.layer?.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.view.layer?.opacity = 1
        content.view.layer?.add(fade, forKey: "show")
        startDismissal()
    }

    func hide() {
        guard window.isVisible else { return }
        stopDismissal()
        window.orderOut(nil)
        hiddenAt = Date()
    }

    func update(_ state: State) {
        self.state = state
        content.apply(state)
    }

    // 状态项可能被系统挤到屏幕外（菜单栏自动隐藏、项目过多、启动瞬间还没排好），
    // 锚点不可信时退回屏幕右上角，绝不能按这个坐标去 clamp。
    private func origin(relativeTo button: NSStatusBarButton, size: NSSize) -> NSPoint {
        let mouseScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let screen = button.window?.screen ?? mouseScreen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenFrame = screen?.frame ?? visible
        var anchor = NSRect.zero
        if let window = button.window {
            anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        var x: CGFloat
        var y: CGFloat
        if anchor.width > 1, anchor.height > 1, anchor.intersects(screenFrame) {
            x = anchor.maxX - size.width
            y = anchor.minY - size.height - 6
        } else {
            x = visible.maxX - size.width - 12
            y = visible.maxY - size.height - 8
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }

    // 点击别的 App、切走、按 Esc 都要收起；点状态栏图标由 button 的 action 自己切换。
    private func startDismissal() {
        stopDismissal()
        // 别的 App 的点击收不到本地事件，用全局监控兜底。
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.hide()
        }) {
            monitors.append(global)
        }
        // 面板显示时我们会激活自己；切到别的 App 就一定收到这条通知。
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            self?.hide()
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self = self, self.window.isVisible else { return event }
            if event.keyCode == 53 { self.hide(); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "q" {
                self.hide(); self.onQuit?(); return nil
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func stopDismissal() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let activeObserver = activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
            self.activeObserver = nil
        }
    }
}

// 面板卡片：圆角、1px 边框、明暗自适应；没有气泡和箭头。
private final class StatusPanelSurface: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyPalette()
    }

    required init?(coder: NSCoder) { fatalError("StatusPanelSurface 只支持代码创建") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPalette()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    func applyPalette() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.backgroundColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.98).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.08)).cgColor
    }
}

// 不兼容提示行：一行红字，可点复制诊断；默认没有任何"可点"的装饰，靠手型光标与悬停提示暗示。
final class StatusPanelWarning: NSView {
    var onClick: (() -> Void)?
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "网易云音乐版本不兼容")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "点击复制诊断"
        iconView.image = NSImage(systemSymbolName: "xmark.octagon.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        iconView.contentTintColor = .systemRed
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .systemRed
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("StatusPanelWarning 只支持代码创建") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}

// 图标按钮：悬停时在自己的图层上画圆形（或圆角）底色。
final class HoverIconButton: NSButton {
    enum Shape { case circle, rounded(CGFloat) }
    var shape: Shape = .circle
    private var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("HoverIconButton 只支持代码创建") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; applyHighlight() }
    override func mouseExited(with event: NSEvent) { hovered = false; applyHighlight() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if hovered { applyHighlight() }
    }

    override func layout() {
        super.layout()
        if hovered { applyHighlight() }
    }

    private func applyHighlight() {
        guard let layer = layer else { return }
        switch shape {
        case .circle: layer.cornerRadius = min(bounds.width, bounds.height) / 2
        case .rounded(let radius): layer.cornerRadius = radius
        }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.13)
        layer.backgroundColor = (hovered && isEnabled) ? color.cgColor : NSColor.clear.cgColor
    }
}

// 偏移行：− / 数值 / + / 复位。手动排版而不是自动布局，避免按钮被行高与图标内在尺寸拉成椭圆
//（hover 圆形半径按短边算，宽度≠高度就会变成椭圆）。
final class OffsetRowView: NSView {
    func setEnabled(_ enabled: Bool) {
        minusButton.isEnabled = enabled
        plusButton.isEnabled = enabled
        resetButton.isEnabled = enabled
        valueLabel.textColor = enabled ? .labelColor : .tertiaryLabelColor
    }

    let minusButton = HoverIconButton()
    let plusButton = HoverIconButton()
    let resetButton = HoverIconButton()
    let valueLabel = NSTextField(labelWithString: "")

    private static let side: CGFloat = 34
    private static let resetSide: CGFloat = 26

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        for button in [minusButton, plusButton, resetButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            addSubview(button)
        }
        valueLabel.alignment = .center
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        addSubview(valueLabel)
    }

    required init?(coder: NSCoder) { fatalError("OffsetRowView 只支持代码创建") }

    override func layout() {
        super.layout()
        let height = bounds.height
        let side = Self.side
        let resetSide = Self.resetSide
        valueLabel.sizeToFit()
        let valueWidth = valueLabel.frame.width
        let center = bounds.width / 2
        // 数值居中，− 与 + 到数值的间距取同一个值：两侧可用空间取小者，再留出复位图标的位置。
        let leftSpace = center - valueWidth / 2
        let rightSpace = bounds.width - (center + valueWidth / 2)
        let gap = max(6, min(leftSpace - side - 4, rightSpace - side - resetSide - 6))
        valueLabel.frame = NSRect(x: center - valueWidth / 2, y: (height - valueLabel.frame.height) / 2,
                                  width: valueWidth, height: valueLabel.frame.height)
        minusButton.frame = NSRect(x: valueLabel.frame.minX - gap - side, y: (height - side) / 2,
                                   width: side, height: side)
        plusButton.frame = NSRect(x: valueLabel.frame.maxX + gap, y: (height - side) / 2,
                                  width: side, height: side)
        resetButton.frame = NSRect(x: bounds.width - resetSide, y: (height - resetSide) / 2,
                                   width: resetSide, height: resetSide)
    }
}

// 面板里的一行：左侧图标 + 标题 + 右侧控件；整行可点，悬停出现圆角底色。
final class StatusPanelRow: NSView {
    var onClick: (() -> Void)?
    private let highlight = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private var accessoryView: NSView?
    private var hovered = false
    private var interactive = true

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -6),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 6),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        let icon = iconView

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("StatusPanelRow 只支持代码创建") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; setHighlighted() }
    override func mouseExited(with event: NSEvent) { hovered = false; setHighlighted() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if hovered { setHighlighted() }
    }

    override func mouseUp(with event: NSEvent) {
        guard interactive, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    // 悬停底色按明暗分开：深色模式提亮、浅色模式加深，两边都要一眼看得出来。
    private func setHighlighted() {
        guard let layer = highlight.layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.12)
        layer.backgroundColor = (hovered && interactive) ? color.cgColor : NSColor.clear.cgColor
    }
}

// 面板内容：标题与状态点、当前歌曲、歌词偏移（− / + / 复位）、两个开关行、打开网易云与退出。
final class StatusPanelContent: NSViewController {
    var onToggleEnabled: ((Bool) -> Void)?
    var onChangeOffset: ((Int) -> Void)?
    var onToggleToast: ((Bool) -> Void)?
    var onToggleLaunch: ((Bool) -> Void)?
    var onOpenMusic: (() -> Void)?
    var onQuit: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?

    private static let stepMs = 500

    private let headerLabel = NSTextField(labelWithString: "网易云音乐")
    private let stateDot = NSView()
    private let warning = StatusPanelWarning()
    private let songLabel = NSTextField(labelWithString: "—")
    private let offsetRow = OffsetRowView()
    private let enabledSwitch = NSSwitch()
    private let toastSwitch = NSSwitch()
    private let launchSwitch = NSSwitch()
    private let toastRow = StatusPanelRow(symbol: "bell", title: "对齐时弹窗")
    private let launchRow = StatusPanelRow(symbol: "clock.arrow.circlepath", title: "开机自启动")
    private let openRow = StatusPanelRow(symbol: "music.note", title: "打开网易云")
    private let quitRow = StatusPanelRow(symbol: "power", title: "退出")
    private let shortcutLabel = NSTextField(labelWithString: "⌘Q")
    private var offsetMs = 500

    override func loadView() {
        let root = StatusPanelSurface(frame: NSRect(x: 0, y: 0, width: 300, height: 240))

        headerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        headerLabel.textColor = .secondaryLabelColor

        stateDot.wantsLayer = true
        stateDot.layer?.cornerRadius = 3
        stateDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stateDot.widthAnchor.constraint(equalToConstant: 6),
            stateDot.heightAnchor.constraint(equalToConstant: 6)
        ])
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        enabledSwitch.controlSize = .small
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)
        let headerRow = NSStackView(views: [headerLabel, stateDot, headerSpacer, enabledSwitch])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 6

        warning.isHidden = true
        warning.onClick = { [weak self] in self?.onCopyDiagnostics?() }
        songLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        songLabel.lineBreakMode = .byTruncatingMiddle
        songLabel.maximumNumberOfLines = 1
        songLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let divider = NSBox()
        divider.boxType = .separator

        let minusButton = offsetRow.minusButton
        let plusButton = offsetRow.plusButton
        let resetButton = offsetRow.resetButton
        minusButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "歌词再延后")
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "歌词再提前")
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "恢复为不偏移")
        for button in [minusButton, plusButton, resetButton] {
            button.target = self
        }
        minusButton.action = #selector(stepDown)
        plusButton.action = #selector(stepUp)
        resetButton.action = #selector(resetOffset)
        minusButton.toolTip = "歌词再延后 0.5 秒"
        plusButton.toolTip = "歌词再提前 0.5 秒"
        resetButton.toolTip = "恢复为不偏移（0 秒）"
        minusButton.image = minusButton.image?.withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        plusButton.image = plusButton.image?.withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        resetButton.image = resetButton.image?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        offsetRow.heightAnchor.constraint(equalToConstant: 40).isActive = true

        // 两行开关：整行可点，右侧是开关。
        for box in [toastSwitch, launchSwitch] {
            box.controlSize = .small
        }
        toastSwitch.target = self
        toastSwitch.action = #selector(toggleToast)
        launchSwitch.target = self
        launchSwitch.action = #selector(toggleLaunch)
        toastRow.addAccessory(toastSwitch)
        toastRow.onClick = { [weak self] in
            guard let self = self else { return }
            self.toastSwitch.state = self.toastSwitch.state == .on ? .off : .on
            self.onToggleToast?(self.toastSwitch.state == .on)
        }
        launchRow.addAccessory(launchSwitch)
        launchRow.onClick = { [weak self] in
            guard let self = self else { return }
            self.launchSwitch.state = self.launchSwitch.state == .on ? .off : .on
            self.onToggleLaunch?(self.launchSwitch.state == .on)
        }

        // 页脚：左边整行“打开网易云”，右边是可 hover 的退出行（附 ⌘Q 提示）。
        openRow.onClick = { [weak self] in self?.openMusic() }
        shortcutLabel.font = .systemFont(ofSize: 10)
        shortcutLabel.textColor = .tertiaryLabelColor
        quitRow.addAccessory(shortcutLabel)
        quitRow.onClick = { [weak self] in self?.quit() }

        let footerRow = NSStackView(views: [openRow, quitRow])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 8
        openRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        quitRow.setContentHuggingPriority(.required, for: .horizontal)
        openRow.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for item in [headerRow, warning, songLabel, divider, offsetRow, toastRow, launchRow, footerRow] {
            stack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.setCustomSpacing(8, after: headerRow)
        stack.setCustomSpacing(12, after: divider)
        stack.setCustomSpacing(12, after: offsetRow)
        stack.setCustomSpacing(4, after: toastRow)
        stack.setCustomSpacing(8, after: launchRow)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 300),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            divider.heightAnchor.constraint(equalToConstant: 1)
        ])
        view = root
        root.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 300, height: ceil(root.fittingSize.height))
    }

    func apply(_ state: StatusPanel.State) {
        // 面板可能还没显示过，先确保视图已构建。
        _ = view
        offsetMs = state.offsetMs
        songLabel.stringValue = state.songName
        songLabel.toolTip = state.songName
        enabledSwitch.state = state.enabled ? .on : .off
        toastSwitch.state = state.showsToast ? .on : .off
        launchSwitch.state = state.launchesAtLogin ? .on : .off
        warning.isHidden = !state.incompatible
        songLabel.isHidden = state.incompatible
        setControlsEnabled(!state.incompatible)
        offsetRow.valueLabel.stringValue = Self.text(for: state.offsetMs)
        offsetRow.valueLabel.textColor = (state.enabled && !state.incompatible) ? .labelColor : .tertiaryLabelColor
        offsetRow.minusButton.isEnabled = !state.incompatible && state.offsetMs > -10000
        offsetRow.plusButton.isEnabled = !state.incompatible && state.offsetMs < 10000
        offsetRow.needsLayout = true
        stateDot.layer?.backgroundColor = Self.color(for: state.level).cgColor
        stateDot.toolTip = state.hint
    }

    // 不兼容时所有可操作项一起置灰：留着配置，但当前不生效。
    private func setControlsEnabled(_ enabled: Bool) {
        offsetRow.setEnabled(enabled)
        toastRow.setEnabled(enabled)
        launchRow.setEnabled(enabled)
        enabledSwitch.isEnabled = enabled
    }

    private static func text(for ms: Int) -> String {
        if ms == 0 { return "不偏移" }
        return "\(ms > 0 ? "提前" : "延后") \(String(format: "%.1f", Double(abs(ms)) / 1000)) 秒"
    }

    private static func color(for level: StatusPanel.State.Level) -> NSColor {
        switch level {
        case .ok: return NSColor(calibratedRed: 0.13, green: 0.65, blue: 0.43, alpha: 1)
        case .waiting: return NSColor.systemOrange
        case .error: return NSColor.systemRed
        case .off: return NSColor.tertiaryLabelColor
        }
    }

    @objc private func toggleEnabled() { onToggleEnabled?(enabledSwitch.state == .on) }
    @objc private func stepDown() { onChangeOffset?(max(offsetMs - Self.stepMs, -10000)) }
    @objc private func stepUp() { onChangeOffset?(min(offsetMs + Self.stepMs, 10000)) }
    // 复位 = 归零（不偏移），不是回到默认的提前 0.5 秒。
    @objc private func resetOffset() { onChangeOffset?(0) }
    @objc private func toggleToast() { onToggleToast?(toastSwitch.state == .on) }
    @objc private func toggleLaunch() { onToggleLaunch?(launchSwitch.state == .on) }
    @objc private func openMusic() { onOpenMusic?() }
    @objc private func quit() { onQuit?() }
}

extension StatusPanelRow {
    // 不兼容时整行置灰：标题/图标变淡，右侧控件禁用，点击也不再触发。
    func setEnabled(_ enabled: Bool) {
        interactive = enabled
        titleLabel.textColor = enabled ? .labelColor : .tertiaryLabelColor
        iconView.contentTintColor = enabled ? .secondaryLabelColor : .quaternaryLabelColor
        (accessoryView as? NSControl)?.isEnabled = enabled
    }


    // 行创建时还不知道右侧控件，补挂一个并补上约束。
    func addAccessory(_ accessory: NSView) {
        accessoryView = accessory
        accessory.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accessory)
        NSLayoutConstraint.activate([
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8)
        ])
    }
}
