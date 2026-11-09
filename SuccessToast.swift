import AppKit
import QuartzCore

private final class SuccessToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// 卡片本体：圆角、边框与阴影都画在同一个图层上，动画只改这个图层的透明度与位移。
// 不用窗口阴影、不用窗口位移：窗口移动和窗口阴影每帧都要窗口服务器重算，是浮层掉帧的主要来源。
private final class SuccessToastSurface: NSView {
    static let cornerRadius: CGFloat = 11

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyPalette()
    }

    required init?(coder: NSCoder) { fatalError("SuccessToastSurface 只支持代码创建") }

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
        layer?.cornerRadius = Self.cornerRadius
        // 不能开启裁剪，否则本图层自己的阴影会被一起裁掉；圆角背景由 cornerRadius 自行裁剪。
        layer?.masksToBounds = false
        layer?.borderWidth = 0.5
        layer?.backgroundColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.98).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.08)).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = dark ? 0.45 : 0.20
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        updateShadowPath()
    }

    // 卡片宽度随歌名变化，阴影路径要跟着重算，否则阴影会停在旧尺寸上。
    func updateShadowPath() {
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius,
                                   cornerHeight: Self.cornerRadius, transform: nil)
    }
}

// 自绘桌面浮层只报告成功，不申请系统通知权限、不夺取焦点或鼠标输入。
// 一次成功一张卡片：新卡片固定在右下角基准位，已有卡片整体向左上让出一层；
// 每张卡片各自计时、各自淡出，互不打断，临界点连续切歌也不会互相覆盖或闪断。
final class SuccessToast {
    struct CardState {
        let id: Int
        let frame: NSRect
        let opacity: Float
        let slideOffset: CGFloat
        let presentedCenter: NSPoint
    }

    private static let cardHeight: CGFloat = 52
    private static let shadowPadding: CGFloat = 10
    private static let slideDistance: CGFloat = 10
    static let stackStep: CGFloat = 14
    private static let maxCards = 3
    private static let dwell: TimeInterval = 2.5

    // 供本组件的动画验收与卡片预览导出使用，不读取或截取其他应用的屏幕内容。
    var lifecycleObserver: ((_ phase: String, _ cardID: Int, _ windowFrame: NSRect) -> Void)?

    private final class Card {
        let id: Int
        let surface: SuccessToastSurface
        let songLabel: NSTextField
        let offsetLabel: NSTextField
        let dwell: TimeInterval
        var dismissWork: DispatchWorkItem?
        init(id: Int, surface: SuccessToastSurface, songLabel: NSTextField, offsetLabel: NSTextField,
             dwell: TimeInterval) {
            self.id = id
            self.surface = surface
            self.songLabel = songLabel
            self.offsetLabel = offsetLabel
            self.dwell = dwell
        }
    }

    private let panel: SuccessToastPanel
    private let container = NSView()
    private var cards: [Card] = []      // 0 = 最新（右下角基准位），越靠后越靠左上
    private var fading: [Card] = []     // 已离开堆叠、正在淡出的卡片
    private var nextCardID = 1
    private var activity: NSObjectProtocol?
    private var panelSize = NSSize(width: 380, height: 80)

    init() {
        panel = SuccessToastPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 380, height: 80)),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "歌词已对齐"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 阴影交给卡片图层：窗口服务器阴影在动画期间每帧重算，而且没法跟图层一起淡出。
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none

        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        panel.contentView = container
    }

    @discardableResult
    func show(_ event: LyricToastEvent, on preferredScreen: NSScreen?) -> Int {
        present(title: event.songName, detail: event.signedSeconds, symbol: "checkmark.circle.fill",
                tint: NSColor(calibratedRed: 0.13, green: 0.65, blue: 0.43, alpha: 1),
                dwell: 2.5, on: preferredScreen)
    }

    // 只用于“已复制诊断结果”这类一次性提示：复用同一套卡片、堆叠与动画。
    @discardableResult
    func show(message: String, on preferredScreen: NSScreen?) -> Int {
        present(title: message, detail: nil, symbol: "doc.on.doc.fill", tint: .controlAccentColor,
                dwell: 1.8, on: preferredScreen)
    }

    @discardableResult
    private func present(title: String, detail: String?, symbol: String, tint: NSColor,
                         dwell: TimeInterval, on preferredScreen: NSScreen?) -> Int {
        guard let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first else { return 0 }
        let available = screen.visibleFrame
        // 面板按屏幕允许的最宽卡片一次性定尺寸：动画期间窗口既不移动也不改宽高，卡片全部在窗口内移动。
        let widest = min(480, available.width - 40)
        let size = NSSize(width: widest + Self.slideDistance + Self.shadowPadding * 2,
                          height: Self.cardHeight + CGFloat(Self.maxCards - 1) * Self.stackStep + Self.shadowPadding * 2)
        let origin = NSPoint(x: available.maxX - 20 - size.width + Self.slideDistance,
                             y: available.minY + 18 - Self.shadowPadding)

        let card = makeCard(title: title, detail: detail, symbol: symbol, tint: tint, dwell: dwell)
        let cardWidth = min(max(300, ceil(card.songLabel.intrinsicContentSize.width
                                          + card.offsetLabel.intrinsicContentSize.width) + 99), widest)
        // 超出上限时先把最深的一张移出堆叠，新卡片才能占用右下角基准位。
        if cards.count >= Self.maxCards, let deepest = cards.last { removeFromStack(deepest) }
        cards.insert(card, at: 0)
        panelSize = size

        withoutImplicitAnimations {
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            container.frame = NSRect(origin: .zero, size: size)
            card.surface.frame = slotFrame(width: cardWidth, slot: 0)
            // 入场起点：完全透明 + 右侧滑入位置；在窗口内完成，窗口本身不动。
            card.surface.layer?.opacity = 0
            card.surface.layer?.transform = CATransform3DMakeTranslation(Self.slideDistance, 0, 0)
        }
        card.surface.updateShadowPath()
        panel.orderFrontRegardless()
        beginActivity()

        // 已有卡片整体向左上让出一层；它们自己的停留计时和退场动画不受影响。
        for (index, existing) in cards.enumerated() where index > 0 {
            reflow(existing, to: slotFrame(width: existing.surface.frame.width, slot: index))
        }
        animateEntrance(card)
        return card.id
    }

    var windowFrame: NSRect { panel.frame }
    var liveCardCount: Int { cards.count }

    // 供动画验收读取：堆叠中的卡片在前，正在淡出的卡片在后；frame 用屏幕坐标便于和基准位比对。
    var cardStates: [CardState] {
        (cards + fading).map { card in
            let layer = card.surface.layer
            let presented = layer?.presentation()
            return CardState(id: card.id, frame: panel.convertToScreen(card.surface.frame),
                             opacity: presented?.opacity ?? (layer?.opacity ?? 0),
                             slideOffset: presented?.transform.m41 ?? 0,
                             presentedCenter: presented?.position ?? layer?.position ?? .zero)
        }
    }

    func exportCardPreview(to url: URL) throws {
        guard let view = cards.first?.surface else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: url) }
    }

    private func makeCard(title: String, detail: String?, symbol: String, tint: NSColor,
                          dwell: TimeInterval) -> Card {
        let surface = SuccessToastSurface(frame: NSRect(x: 0, y: 0, width: 300, height: Self.cardHeight))
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 25, weight: .semibold))
        icon.contentTintColor = tint
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let textColor = NSColor(name: NSColor.Name("LyricToastText")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .white : NSColor(calibratedWhite: 0.10, alpha: 1)
        }
        let songLabel = NSTextField(labelWithString: title)
        songLabel.font = .systemFont(ofSize: 14, weight: .medium)
        songLabel.textColor = textColor
        songLabel.lineBreakMode = .byTruncatingMiddle
        songLabel.maximumNumberOfLines = 1
        songLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let offsetLabel = NSTextField(labelWithString: detail ?? "")
        offsetLabel.isHidden = detail == nil
        offsetLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        offsetLabel.textColor = textColor
        offsetLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        offsetLabel.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, songLabel, offsetLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 27), icon.heightAnchor.constraint(equalToConstant: 27),
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
            row.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
        ])
        container.addSubview(surface)
        let card = Card(id: nextCardID, surface: surface, songLabel: songLabel, offsetLabel: offsetLabel, dwell: dwell)
        nextCardID += 1
        return card
    }

    // 堆叠位置：slot 0 是右下角基准位，往后每一层向左上偏移一个步长。
    private func slotFrame(width: CGFloat, slot: Int) -> NSRect {
        let right = panelSize.width - Self.slideDistance - CGFloat(slot) * Self.stackStep
        let bottom = Self.shadowPadding + CGFloat(slot) * Self.stackStep
        return NSRect(x: right - width, y: bottom, width: width, height: Self.cardHeight)
    }

    private func animateEntrance(_ card: Card) {
        guard let layer = card.surface.layer else { return }
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let entrance = CAAnimationGroup()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        var animations: [CAAnimation] = [fade]
        if !reducedMotion {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = Self.slideDistance
            slide.toValue = 0
            animations.append(slide)
        }
        entrance.animations = animations
        entrance.duration = reducedMotion ? 0.12 : 0.20
        entrance.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

        // 入场动画整段由图层在 GPU 上播放，主线程被心跳或状态读取占用时也不会掉帧。
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak card] in
            guard let self = self, let card = card, self.cards.contains(where: { $0 === card }) else { return }
            self.lifecycleObserver?("entered", card.id, self.panel.frame)
            // 完全进入后停留 2.5 秒；每张卡片自己计时，后到的卡片不会重置前面的退出时间。
            let work = DispatchWorkItem { [weak self, weak card] in
                guard let self = self, let card = card else { return }
                self.dismiss(card)
            }
            card.dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + card.dwell, execute: work)
        }
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        layer.add(entrance, forKey: "entrance")
        CATransaction.commit()
    }

    private func dismiss(_ card: Card) {
        guard cards.contains(where: { $0 === card }) else { return }
        lifecycleObserver?("exitStarted", card.id, panel.frame)
        // 观察者可能已经插入新卡片，索引必须在回调之后重新取。
        guard let index = cards.firstIndex(where: { $0 === card }) else { return }
        // 先把它从堆叠里摘掉：后面的卡片补位，它自己在原位继续淡出，不会被新事件打断。
        cards.remove(at: index)
        fading.append(card)
        for (newIndex, remaining) in cards.enumerated() where newIndex >= index {
            reflow(remaining, to: slotFrame(width: remaining.surface.frame.width, slot: newIndex))
        }
        fadeOut(card, duration: 0.28)
    }

    private func removeFromStack(_ card: Card) {
        cards.removeAll { $0 === card }
        fading.append(card)
        fadeOut(card, duration: 0.18)
    }

    private func fadeOut(_ card: Card, duration: CFTimeInterval) {
        card.dismissWork?.cancel()
        card.dismissWork = nil
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fade = CABasicAnimation(keyPath: "opacity")
        // 从当前呈现值继续淡出，即使它还在入场或上一次淡出中被移出堆叠也不会跳。
        fade.fromValue = card.surface.layer?.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = reducedMotion ? 0.12 : duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak card] in
            guard let self = self, let card = card else { return }
            card.surface.removeFromSuperview()
            self.fading.removeAll { $0 === card }
            self.lifecycleObserver?("hidden", card.id, self.panel.frame)
            if self.cards.isEmpty && self.fading.isEmpty {
                self.panel.orderOut(nil)
                self.endActivity()
            }
        }
        CATransaction.setDisableActions(true)
        card.surface.layer?.opacity = 0
        card.surface.layer?.add(fade, forKey: "exit")
        CATransaction.commit()
    }

    // 堆叠让位/补位：只移动卡片图层，窗口本身始终不动。
    private func reflow(_ card: Card, to frame: NSRect) {
        guard let layer = card.surface.layer else { return }
        let from = layer.presentation()?.position ?? layer.position
        withoutImplicitAnimations {
            card.surface.frame = frame
        }
        // 目标位置必须取设置后的模型值：图层锚点由 AppKit 决定（视图图层是 (0,0)），
        // 用 frame 的中心去猜会让卡片斜着飞过目标再吸回去。
        let to = layer.position
        guard from != to else { return }
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: from)
        move.toValue = NSValue(point: to)
        // 与新卡片的入场同曲线同时长，整摞看起来是同一次动作。
        move.duration = reducedMotion ? 0.10 : 0.20
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        layer.add(move, forKey: "reflow")
    }

    // 就位、换内容、改尺寸都必须瞬时生效，动画只由显式 CAAnimation 驱动。
    private func withoutImplicitAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // 后台 accessory 应用在窗口不可见时会被 App Nap 降频；浮层显示期间申请用户可见活动。
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "\(AppIdentity.displayName)：显示对齐成功浮层")
    }

    private func endActivity() {
        if let activity = activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
