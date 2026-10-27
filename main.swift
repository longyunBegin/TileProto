import AppKit
import ApplicationServices
import QuartzCore

// TileProto：菜单栏自动平铺。操作只在鼠标和菜单栏面板上。
// 原理：Accessibility API（AXUIElement）枚举窗口并改 frame。
//  1. 单一自适应布局：1 全屏、2 左右分、3 三列等分、4 田字。间距固定 8。
//     格子数 = min(窗口数, 上限, 4)。一格铺满工作区，不留边。
//  2. 窗口多于格子时堆进活动格子。橙色握把点按轮换；悬停上沿用芯片直达。
//     ⌃⌘ 拖到某格子上时，即使刚好满格也并进去，空出的格子收掉。
//  3. ⌘ 拖到另一格子交换。普通拖动松手弹回，并提示要按住 ⌘。
//  4. Primary：被点窗口与第 0 格顶部互换。Focus：铺满工作区，再点悬停条上的 Focus，
//     按进入前记下的帧还原。Float：按当前尺寸居中，其余窗口立刻补位。
//  5. 活动格子描边，其余格子盖 50% 暗色。两者固定开启，没有单独开关。
// 布局、交换、Focus、弹回约 0.5 秒短弹簧。拖分隔线跟手。

func log(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    print(line, terminator: "")
    let path = ("~/tileproto/tileproto.log" as NSString).expandingTildeInPath
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path) {
            if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - 面板小部件（纯代码 AppKit，无 storyboard）

final class DotView: NSView {
    var color: NSColor = .systemGray {
        didSet { layer?.backgroundColor = color.cgColor }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = color.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }
}

final class TileCellView: NSView {
    var onClick: (() -> Void)?
    private let iconView = NSImageView()
    private let nameLabel: NSTextField
    private let badgeLabel = NSTextField(labelWithString: "")
    var isActiveTile = false {
        didSet { updateStyle() }
    }
    var badgeCount = 0 {
        didSet {
            badgeLabel.isHidden = badgeCount <= 1
            badgeLabel.stringValue = "\(badgeCount)"
        }
    }
    init(icon: NSImage?, name: String) {
        nameLabel = NSTextField(labelWithString: name)
        super.init(frame: .zero)
        wantsLayer = true
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.alignment = .center
        badgeLabel.textColor = .white
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeLabel.layer?.cornerRadius = 8
        badgeLabel.isHidden = true
        for v in [iconView, nameLabel, badgeLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 2),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            badgeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            badgeLabel.widthAnchor.constraint(equalToConstant: 16),
            badgeLabel.heightAnchor.constraint(equalToConstant: 16),
        ])
        updateStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 64) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    private func updateStyle() {
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = isActiveTile ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}

final class DiagramButton: NSView {
    var rects: [CGRect] = []  // 单位坐标，y 从上往下
    var indexTag = 0  // NSView.tag 只读，另用此字段存数量值
    var isSelected = false {
        didSet {
            updateStyle()
            needsDisplay = true
        }
    }
    var isDisabled = false {
        didSet {
            alphaValue = isDisabled ? 0.35 : 1.0
            updateStyle()
        }
    }
    var onClick: (() -> Void)?
    private let labelField: NSTextField
    init(title: String) {
        labelField = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        labelField.font = .systemFont(ofSize: 11)
        labelField.alignment = .center
        labelField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelField)
        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelField.trailingAnchor.constraint(equalTo: trailingAnchor),
            labelField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            labelField.heightAnchor.constraint(equalToConstant: 14),
        ])
        updateStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 62) }
    override func mouseDown(with event: NSEvent) {
        if !isDisabled { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let area = NSRect(x: 6, y: 18, width: bounds.width - 12, height: bounds.height - 22)
        let fill = isSelected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        fill.setFill()
        for r in rects {
            let x = area.minX + r.minX * area.width
            let w = r.width * area.width
            let h = r.height * area.height
            let y = area.minY + (1 - r.minY - r.height) * area.height
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: 3, yRadius: 3).fill()
        }
    }
    private func updateStyle() {
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = isSelected ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}

// v9：高亮颜色板（面板里一排小圆点）与高亮框视图（画边框或光晕）

final class HighlightBorderView: NSView {
    var strokeColor: NSColor = .controlAccentColor
    var thickness: CGFloat = 3
    var glow = false
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if glow {
            // 光晕：只画框外阴影与辉光线，不盖半透明填充、不压窗口内容
            let rect = bounds.insetBy(dx: 8, dy: 8)
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            let shadow = NSShadow()
            shadow.shadowColor = strokeColor
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = .zero
            shadow.set()
            strokeColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
            path.stroke()
        } else {
            // 边框：面板比磁贴 frame 每边大 thickness，描边居中正好落在间隙里
            let rect = bounds.insetBy(dx: thickness / 2, dy: thickness / 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            strokeColor.setStroke()
            path.lineWidth = thickness
            path.stroke()
        }
    }
}

final class TileProtoApp: NSObject, NSApplicationDelegate, NSWindowDelegate {

    var statusItem: NSStatusItem!
    var autoTile = true
    var autoOffPlacedKeys: Set<String> = []  // 关自动平铺后已见过的窗口：只给此后新开的窗口居中一次
    var tileLimit = 4
    var stackTops: [String: Int] = [:]  // C 批：key 为“屏ID:磁贴下标”，多屏不串位
    var lastSignature = ""
    var pendingSignature = ""
    var pendingTicks = 0
    var excludedBundles: Set<String> = []
    var lastTrustState: Bool? = nil
    var panelPopover: NSPopover!
    var panelContainer: NSView!
    var panelStack: NSStackView!
    var autoSwitch: NSSwitch!
    var statusDot: DotView!
    var statusLabel: NSTextField!
    var tilesStack: NSStackView!
    var tilesPlaceholder: NSTextField!
    var countButtons: [DiagramButton] = []

    var tileAppLabel: NSTextField!
    var tileAppSwitch: NSSwitch!
    var requestAXButton: NSButton!
    var lastPanelTilesKey = ""
    var lastPanelHeight: CGFloat = 0
    // v6 状态：悬停条 / 分隔线 / Float / Primary / 自定义分割
    var floatedKeys: Set<String> = []          // 单窗口 Float：pid|标题
    // 最小尺寸学习：key = 应用名（learnName 已在两条落点路径上传入），
    // 值 = 观测到的落点下限（每维独立）；存 UserDefaults 持久化本机。
    var learnedMinSizes: [String: CGSize] = [:]
    var learnedMinChanged = false
    let learnedMinDefaultsKey = "tileproto.learnedMinSizes"
    var primaryKey: String? = nil              // 主窗口：pid|标题，computeTiles 里移到首位（旧全局机制，现已无人设置，仅留裁剪）
    // Primary 交换（按屏）：该窗口恒为 tile0 顶部；每轮 tile() 后施加，窗口关闭/被浮动时裁剪。
    var primaryKeysByScreen: [CGDirectDisplayID: String] = [:]
    var splitOverrides: [String: CGFloat] = [:] // key: 屏-磁贴数-分隔线id，值：分隔线中心占 visibleFrame 的比例
    var lastTiles: [(stack: [WinInfo], frame: CGRect, top: WinInfo)] = []
    var lastVF: CGRect = .zero
    var lastScreenFrame: CGRect = .zero
    var tickCount = 0
    var dragQuiet = false
    var draggingDividerID: String? = nil
    var hoverPanel: NSPanel!

    var hoverKey: String? = nil
    var hoverTileFrame: CGRect = .zero
    var gripPanels: [String: NSPanel] = [:]
    var dotPanels: [String: NSPanel] = [:]          // key：屏ID:磁贴下标，活动磁贴顶部中央蓝圆点手柄
    var stackMarkerPanels: [String: NSPanel] = [:]  // key：屏ID:磁贴下标，堆叠磁贴顶部橙色标记
    var lastStackByScreen: [CGDirectDisplayID: Bool] = [:]  // 每屏上次是否有堆叠（堆叠 toast 防刷屏）
    var stackPanel: NSPanel?
    var stackPanelSid: CGDirectDisplayID = 0
    var stackPanelTile = 0
    var restoreFloatsButton: NSButton!
    var loginSwitch: NSSwitch!
    // 鼠标重排：会话事件 tap 只订阅左键，用来识别 ⌘ 交换和 ⌃⌘ 进堆叠。
    var eventTap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var tapRunning = false
    var mouseTapFailedLogged = false
    var windowOrder: [String] = []
    /// 手动堆叠：key 不占自己的磁贴，跟在 host 窗口所在的磁贴里。
    /// 窗口数刚好等于上限时，⌃⌘ 拖上去也靠这张表并进目标磁贴，原格子收掉。
    var stackedOnto: [String: String] = [:]

    // 活动格子描边、其余格子 50% 暗色，都固定开启。
    var lastActiveTile = 0

    // D 批状态：⌘拖交换 / ⌃⌘拖进堆叠
    enum DragMode { case swap, stack }
    struct DragState {
        let mode: DragMode
        let sourceTile: Int
        let draggedKey: String
        let frames: [CGRect]  // mouseDown 时的磁贴 frame（Cocoa 坐标）
        let screenID: CGDirectDisplayID  // C 批：拖动发生的屏；跨屏松手按取消处理
        var targetTile: Int? = nil
    }
    var dragState: DragState? = nil
    var pendingDrag: DragState? = nil  // ⌘按下未移动时的待定拖动：不吞事件，移动超 3pt 才转正
    var pendingDragPoint: CGPoint = .zero
    var dragRingPanel: NSPanel? = nil
    var pinnedActiveTile: Int? = nil
    var pinnedFrontmostPid: pid_t? = nil

    // 上次平铺落点：普通拖动弹回、Focus 还原都读它。只活在这次运行里。
    var lastPlacedFrames: [String: CGRect] = [:]  // winKey -> frame
    // C 批：多显示器 + Spaces（每屏独立设置、窗口集合与磁贴 frame；单屏时与旧行为一致）
    struct ScreenSettings {
        var tileLimit = 4
    }
    var globalSettings = ScreenSettings()  // 全局一套设置（按屏的平铺状态 lastTilesByScreen、stackTops 不动）
    var lastTilesByScreen: [CGDirectDisplayID: [(stack: [WinInfo], frame: CGRect, top: WinInfo)]] = [:]
    var lastVFByScreen: [CGDirectDisplayID: CGRect] = [:]
    var lastScreenFrameByScreen: [CGDirectDisplayID: CGRect] = [:]
    var lastActiveTileByScreen: [CGDirectDisplayID: Int] = [:]
    var lastTiledSignatureByScreen: [CGDirectDisplayID: String] = [:]
    var pinnedScreenID: CGDirectDisplayID? = nil
    // C 批第二部分：Stage Manager 暂停 + 最小尺寸学习
    var stageManagerPaused = false  // 当前是否因 Stage Manager 开启而暂停平铺
    var lastDiagLog = ""  // 诊断日志去重：连续相同内容只记一次
    func logDiag(_ msg: String) {
        guard msg != lastDiagLog else { return }
        lastDiagLog = msg
        log(msg)
    }


    func screenID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    func mainHeight() -> CGFloat { NSScreen.main?.frame.height ?? 0 }
    func isMainScreen(_ s: NSScreen) -> Bool {
        guard let m = NSScreen.main else { return false }
        return screenID(s) == screenID(m)
    }
    // 全局一套设置：忽略传入的屏，一律返回同一份
    func settingsFor(_ screen: NSScreen) -> ScreenSettings {
        globalSettings
    }
    func setSettingsFor(_ st: ScreenSettings, screen: NSScreen) {
        globalSettings = st
        tileLimit = st.tileLimit
    }
    func screenName(_ s: NSScreen) -> String {
        if isMainScreen(s) { return "主屏" }
        if let idx = NSScreen.screens.firstIndex(where: { screenID($0) == screenID(s) }) { return "副屏 \(idx + 1)" }
        return "副屏"
    }
    // 窗口按 frame 中心点归属到所在屏；跨屏或无 frame 时 fallback 主屏
    func screenForFrame(_ f: CGRect) -> NSScreen {
        let c = CGPoint(x: f.midX, y: f.midY)
        for s in NSScreen.screens where s.frame.contains(c) { return s }
        return NSScreen.main ?? NSScreen.screens[0]
    }
    // 活动屏 = 前台窗口所在屏，否则主屏
    func activeScreen() -> NSScreen {
        if let app = NSWorkspace.shared.frontmostApplication {
            let wins = collectWindows()
            if let w = wins.first(where: { $0.pid == app.processIdentifier }), !w.frame.isEmpty {
                return screenForFrame(w.frame)
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
    func stackTopKey(_ sid: CGDirectDisplayID, _ tile: Int) -> String { "\(sid):\(tile)" }







    // MARK: - B 批第二部分：开机启动（LaunchAgent，应用自己写 plist）
    var loginPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.example.tileproto.plist")
    }

    func loginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: loginPlistURL.path)
    }

    func setLoginItem(_ on: Bool) {
        let path = loginPlistURL.path
        if on {
            let exe = Bundle.main.executablePath
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("tileproto/TileProto.app/Contents/MacOS/TileProto").path
            let dict: NSDictionary = [
                "Label": "com.example.tileproto",
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            try? FileManager.default.createDirectory(atPath: loginPlistURL.deletingLastPathComponent().path,
                                                     withIntermediateDirectories: true)
            if dict.write(toFile: path, atomically: true) {
                runLaunchctl(["load", path])
                log("login item on")
            } else {
                log("login item: plist write failed")
            }
        } else {
            runLaunchctl(["unload", path])
            try? FileManager.default.removeItem(atPath: path)
            log("login item off")
        }
    }

    func runLaunchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadExcluded()
        loadLearnedMinSizes()
        setupPanelUI()
        setupHoverBar()
        setupMouseDragTap()
        requestAccessibility()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.updateHover()
        }
        // 切 Space 与接/断屏时立即重排。Focus 期间 forceTile 会跳过。
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            log("space changed")
            self?.forceTile()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            log("screen parameters changed")
            self?.forceTile()
        }
        tick()
        log("TileProto started, limit=\(tileLimit) excluded=\(excludedBundles.count)")
    }

    // MARK: - 菜单栏面板

    func setupPanelUI() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▦"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))
        buildPanelContent()
        let vc = NSViewController()
        vc.view = panelContainer
        panelPopover = NSPopover()
        panelPopover.contentViewController = vc
        panelPopover.behavior = .transient
        panelPopover.animates = true
        refreshPanel()
    }

    @objc func togglePanel(_ sender: NSButton) {
        guard let button = statusItem.button else { return }
        if panelPopover.isShown {
            panelPopover.close()
        } else {
            refreshPanel()
            panelPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    func hRow(distribution: NSStackView.Distribution = .fill, spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView()
        s.orientation = .horizontal
        s.distribution = distribution
        s.spacing = spacing
        return s
    }

    // 垂直面板内行宽固定 288（面板宽 320 减左右边距各 16）
    func w288(_ v: NSView) -> NSView {
        v.widthAnchor.constraint(equalToConstant: 288).isActive = true
        return v
    }

    func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    func buildPanelContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panelStack = stack

        // 头部：应用名 + 自动平铺开关
        let header = hRow()
        let titleLabel = NSTextField(labelWithString: "▦ TileProto")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        autoSwitch = NSSwitch()
        autoSwitch.target = self
        autoSwitch.action = #selector(panelToggleAuto(_:))
        let spacer1 = NSView()
        spacer1.setContentHuggingPriority(.init(1), for: .horizontal)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(spacer1)
        header.addArrangedSubview(sectionLabel("自动平铺"))
        header.addArrangedSubview(autoSwitch)
        stack.addArrangedSubview(w288(header))

        // 状态行
        let statusRow = hRow(spacing: 6)
        statusDot = DotView(frame: .zero)
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusRow.addArrangedSubview(statusDot)
        statusRow.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(w288(statusRow))
        stack.addArrangedSubview(w288(separator()))

        // 磁贴预览格
        tilesStack = hRow(distribution: .fillEqually)
        tilesPlaceholder = NSTextField(labelWithString: "暂无可平铺的窗口")
        tilesPlaceholder.font = .systemFont(ofSize: 12)
        tilesPlaceholder.textColor = .secondaryLabelColor
        tilesPlaceholder.isHidden = true
        stack.addArrangedSubview(w288(tilesStack))
        stack.addArrangedSubview(w288(tilesPlaceholder))

        let captionRow = hRow()
        let windowsLabel = sectionLabel("Windows on this screen")
        windowsLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        captionRow.addArrangedSubview(windowsLabel)
        stack.addArrangedSubview(w288(captionRow))

        // 数量按钮
        let countRow = hRow(distribution: .fillEqually)
        let countDiagrams: [[CGRect]] = [
            [CGRect(x: 0, y: 0, width: 1, height: 1)],
            [CGRect(x: 0, y: 0, width: 0.47, height: 1), CGRect(x: 0.53, y: 0, width: 0.47, height: 1)],
            [CGRect(x: 0, y: 0, width: 0.30, height: 1), CGRect(x: 0.35, y: 0, width: 0.30, height: 1), CGRect(x: 0.70, y: 0, width: 0.30, height: 1)],
            [CGRect(x: 0, y: 0, width: 0.47, height: 0.47), CGRect(x: 0.53, y: 0, width: 0.47, height: 0.47), CGRect(x: 0, y: 0.53, width: 0.47, height: 0.47), CGRect(x: 0.53, y: 0.53, width: 0.47, height: 0.47)],
        ]
        for c in 1...4 {
            let b = DiagramButton(title: "\(c)")
            b.rects = countDiagrams[c - 1]
            b.indexTag = c
            b.onClick = { [weak self] in self?.applyLimit(c) }
            countButtons.append(b)
            countRow.addArrangedSubview(b)
        }
        stack.addArrangedSubview(w288(countRow))
        stack.addArrangedSubview(w288(separator()))

        // 动作行：Retile
        let actionRow = hRow(distribution: .fillEqually)
        let tileNowBtn = NSButton(title: "Retile", target: self, action: #selector(panelTileNow(_:)))
        actionRow.addArrangedSubview(tileNowBtn)
        stack.addArrangedSubview(w288(actionRow))

        // v6 第二动作行：恢复浮动窗口
        let actionRow2 = hRow(distribution: .fillEqually)
        restoreFloatsButton = NSButton(title: "恢复浮动窗口", target: self, action: #selector(panelRestoreFloats(_:)))
        actionRow2.addArrangedSubview(restoreFloatsButton!)
        stack.addArrangedSubview(w288(actionRow2))

        // 开机启动
        let loginRow = hRow()
        let loginLabel = NSTextField(labelWithString: "开机启动")
        loginLabel.font = .systemFont(ofSize: 12)
        loginLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        loginSwitch = NSSwitch()
        loginSwitch.target = self
        loginSwitch.action = #selector(panelToggleLogin(_:))
        loginSwitch.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let loginSpacer = NSView()
        loginSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        loginRow.addArrangedSubview(loginLabel)
        loginRow.addArrangedSubview(loginSpacer)
        loginRow.addArrangedSubview(loginSwitch)
        stack.addArrangedSubview(w288(loginRow))

        let tileAppRow = hRow()
        tileAppLabel = NSTextField(labelWithString: "Tile")
        tileAppLabel.font = .systemFont(ofSize: 12)
        tileAppLabel.lineBreakMode = .byTruncatingTail
        tileAppSwitch = NSSwitch()
        tileAppSwitch.target = self
        tileAppSwitch.action = #selector(panelToggleTileApp(_:))
        tileAppSwitch.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let tileAppSpacer = NSView()
        tileAppSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        tileAppRow.addArrangedSubview(tileAppLabel)
        tileAppRow.addArrangedSubview(tileAppSpacer)
        tileAppRow.addArrangedSubview(tileAppSwitch)
        stack.addArrangedSubview(w288(tileAppRow))
        stack.addArrangedSubview(w288(separator()))

        // 底部（重新请求权限仅在未授权时显示）
        let footerRow = hRow(distribution: .fillEqually)
        requestAXButton = NSButton(title: "重新请求辅助功能权限", target: self, action: #selector(panelRequestAX(_:)))
        let quitBtn = NSButton(title: "退出 TileProto", target: self, action: #selector(panelQuit(_:)))
        footerRow.addArrangedSubview(requestAXButton!)
        footerRow.addArrangedSubview(quitBtn)
        stack.addArrangedSubview(w288(footerRow))

        panelContainer = NSView()
        panelContainer.addSubview(stack)
        panelContainer.widthAnchor.constraint(equalToConstant: 320).isActive = true
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panelContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: panelContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panelContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: panelContainer.bottomAnchor),
        ])
    }

    func refreshPanel() {
        guard panelContainer != nil, panelPopover != nil else { return }
        let trusted = AXIsProcessTrusted()
        autoSwitch.state = autoTile ? .on : .off
        if !trusted {
            statusDot.color = .systemGray
            statusLabel.stringValue = "未获得辅助功能权限"
            tilesPlaceholder.isHidden = false
            tilesStack.isHidden = true
        } else {
            // 面板显示主屏的磁贴；设置是全局一套
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let sid = screenID(screen)
            let st = settingsFor(screen)
            let windows = collectWindows(on: screen)
            let (stacks, active) = computeTiles(windows: windows, st: st, sid: sid)
            let windowCount = stacks.reduce(0) { $0 + $1.count }
            if stageManagerPaused {
                statusDot.color = .systemOrange
                statusLabel.stringValue = "Stage Manager paused"
            } else if autoTile {
                statusDot.color = .systemGreen
                statusLabel.stringValue = "Tiling \(windowCount) window\(windowCount == 1 ? "" : "s")"
            } else {
                statusDot.color = .systemGray
                statusLabel.stringValue = "Tiling off"
            }
            tilesPlaceholder.isHidden = !stacks.isEmpty
            tilesStack.isHidden = stacks.isEmpty
            if !stacks.isEmpty {
                let key = stacks.enumerated().map { "\($0.element.first?.pid ?? 0):\($0.element.count)" }.joined(separator: "|") + "@\(active)@\(sid)"
                if key != lastPanelTilesKey {
                    lastPanelTilesKey = key
                    for v in tilesStack.arrangedSubviews {
                        tilesStack.removeArrangedSubview(v)
                        v.removeFromSuperview()
                    }
                    for (i, stack) in stacks.enumerated() {
                        let top = stack[min(stackTops[stackTopKey(sid, i)] ?? 0, stack.count - 1)]
                        let icon = NSRunningApplication(processIdentifier: top.pid)?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                        let cell = TileCellView(icon: icon, name: top.appName)
                        cell.isActiveTile = (i == active)
                        cell.badgeCount = stack.count
                        cell.onClick = { [weak self] in self?.activateTile(top) }
                        tilesStack.addArrangedSubview(cell)
                    }
                } else {
                    // 仅刷新活动高亮（栈顶轮换时不重建格子）
                    for (i, v) in tilesStack.arrangedSubviews.enumerated() {
                        (v as? TileCellView)?.isActiveTile = (i == active)
                    }
                }
            }
        }
        // 面板控件反映全局设置
        let panelSt = globalSettings
        for b in countButtons {
            b.isSelected = (b.indexTag == panelSt.tileLimit)
            b.needsDisplay = true
        }
        if let app = frontRegularApp(), let bid = app.bundleIdentifier {
            let name = app.localizedName ?? bid
            tileAppLabel?.stringValue = "Tile \(name)"
            tileAppSwitch?.isEnabled = true
            tileAppSwitch?.state = excludedBundles.contains(bid) ? .off : .on
        } else {
            tileAppLabel?.stringValue = "Tile front app"
            tileAppSwitch?.isEnabled = false
            tileAppSwitch?.state = .off
        }
        restoreFloatsButton.isEnabled = !floatedKeys.isEmpty
        loginSwitch.state = loginItemEnabled() ? .on : .off
        requestAXButton.isHidden = trusted
        // 只有高度变化时才改 popover 尺寸，避免每秒抖动
        panelContainer.layoutSubtreeIfNeeded()
        let h = panelStack.fittingSize.height
        if abs(h - lastPanelHeight) > 0.5 {
            lastPanelHeight = h
            panelContainer.frame.size = NSSize(width: 320, height: max(h, 200))
            panelPopover.contentSize = NSSize(width: 320, height: max(h, 200))
        }
    }

    func activateTile(_ w: WinInfo) {
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: w.pid) { app.activate() }
        log("panel tile activated: \(w.appName)")
        panelPopover.close()
    }

    // 格子数上限是全局设置
    func applyLimit(_ v: Int) {
        var st = globalSettings
        if v > 4 {
            log("tileLimit \(v) rejected; max 4")
            refreshPanel()
            return
        }
        st.tileLimit = v
        setSettingsFor(st, screen: activeScreen())
        log("tileLimit -> \(v)")
        showToast("Up to \(v) window\(v == 1 ? "" : "s")", detail: "On this screen, in this Space.", on: activeScreen())
        forceTile()
        refreshPanel()
    }

    func countWord(_ n: Int) -> String {
        switch n {
        case 1: return "One"
        case 2: return "Two"
        case 3: return "Three"
        case 4: return "Four"
        default: return "\(n)"
        }
    }

    func frontRegularApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }



    @objc func panelToggleTileApp(_ sender: NSSwitch) {
        guard let app = frontRegularApp(), let bid = app.bundleIdentifier else { return }
        setAppExcluded(bid, sender.state != .on)
        log("tile app \(app.localizedName ?? bid) -> \(sender.state == .on)")
        forceTile()
        refreshPanel()
    }

    @objc func panelTileNow(_ sender: NSButton) {
        if focusKey != nil {
            disableFocus()
        }
        hideHoverBar()
        forceTile()
        showToast("Retiled", on: activeScreen())
        refreshPanel()
    }

    @objc func panelToggleAuto(_ sender: NSSwitch) {
        autoTile = (sender.state == .on)
        log("autoTile -> \(autoTile)")
        if autoTile {
            autoOffPlacedKeys.removeAll()
            forceTile()
        } else {
            // 关掉不恢复原位：窗口保持平铺位置；已见过的窗口记下，此后新开窗口才居中
            autoOffPlacedKeys = Set(collectWindows().map { winKey($0) })
            hideGrips()
        }
        refreshPanel()
    }


    @objc func panelToggleLogin(_ sender: NSSwitch) {
        setLoginItem(sender.state == .on)
        refreshPanel()
    }

    @objc func panelRestoreFloats(_ sender: NSButton) {
        guard !floatedKeys.isEmpty else { return }
        floatedKeys.removeAll()
        log("floated windows restored")
        forceTile()
        refreshPanel()
    }

    @objc func panelRequestAX(_ sender: NSButton) {
        requestAccessibility()
    }

    @objc func panelQuit(_ sender: NSButton) {
        NSApplication.shared.terminate(nil)
    }


    // MARK: - 排除列表

    func excludedFilePath() -> String {
        ("~/tileproto/excluded.txt" as NSString).expandingTildeInPath
    }

    func loadExcluded() {
        let text = (try? String(contentsOfFile: excludedFilePath())) ?? ""
        excludedBundles = Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    // 最小尺寸学习值的持久化：[应用名: ["w": 宽, "h": 高]]；启动时读回。
    func loadLearnedMinSizes() {
        guard let raw = UserDefaults.standard.dictionary(forKey: learnedMinDefaultsKey) else { return }
        var dropped = 0
        for (name, v) in raw {
            guard let d = v as? [String: Double], let w = d["w"], let h = d["h"] else { continue }
            // 任一维 ≤0 的条目是毒化数据（如瞬态窗口学出的 1512x0），丢弃，绝不按 0 用。
            guard w > 0, h > 0 else { dropped += 1; continue }
            learnedMinSizes[name] = CGSize(width: w, height: h)
        }
        if dropped > 0 { log("min-size learned dropped invalid entries: \(dropped)") }
        if !learnedMinSizes.isEmpty { log("min-size learned loaded: \(learnedMinSizes.count) apps") }
    }

    func saveLearnedMinSizes() {
        let raw = learnedMinSizes.mapValues { ["w": Double($0.width), "h": Double($0.height)] }
        UserDefaults.standard.set(raw, forKey: learnedMinDefaultsKey)
    }

    func setAppExcluded(_ bid: String, _ excluded: Bool) {
        let path = excludedFilePath()
        var set = Set((try? String(contentsOfFile: path))?.split(separator: "\n").map(String.init) ?? [])
        if excluded { set.insert(bid) } else { set.remove(bid) }
        let text = set.sorted().joined(separator: "\n")
        try? (text.isEmpty ? "" : text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let before = excludedBundles
        loadExcluded()
        if excludedBundles != before {
            log(excluded ? "excluded \(bid)" : "un-excluded \(bid)")
            forceTile()
        }
    }

    // MARK: - 辅助功能权限

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        log("Accessibility trusted: \(trusted)")
    }

    // MARK: - 主循环（带防抖）

    // C2：Stage Manager 开关信号——com.apple.WindowManager 的 GloballyEnabled
    // （未公开 API，系该域 Stage Manager 总开关的推断；读 plist 直读不走缓存，
    // 读不到时 fail-open 不暂停，与本项目其他探测失败策略一致）
    func stageManagerEnabled() -> Bool {
        let plist = NSHomeDirectory() + "/Library/Preferences/com.apple.WindowManager.plist"
        if let d = NSDictionary(contentsOfFile: plist) as? [String: Any],
           let v = d["GloballyEnabled"] as? Bool { return v }
        if let v = UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "GloballyEnabled") as? Bool { return v }
        return false
    }

    // 每 tick 调用一次：开关翻转时暂停/恢复平铺（暂停时不移动任何窗口、不改停放记录）
    func refreshStageManagerPause() {
        let on = stageManagerEnabled()
        guard on != stageManagerPaused else { return }
        stageManagerPaused = on
        log(on ? "Stage Manager on: tiling paused" : "Stage Manager off: tiling resumed")
        if on {
            hideGrips()
        } else if AXIsProcessTrusted(), autoTile {
            forceTile()
        }
    }

    func tick() {
        if panelPopover.isShown { refreshPanel() }
        guard autoTile else {
            hideGrips()
            hideDotHandles()
            hideStackMarkers()
            hideHighlights()
            removeDimLayers()
            closeStackPanel()
            // 关自动平铺：窗口保持平铺位置不动；此后新开的窗口居中浮动一次（50% 宽 × 60% 高）
            if AXIsProcessTrusted() {
                let live = collectWindows()
                let liveKeys = Set(live.map { winKey($0) })
                autoOffPlacedKeys = autoOffPlacedKeys.intersection(liveKeys)
                for w in live where !autoOffPlacedKeys.contains(winKey(w)) {
                    let scr = screenForFrame(w.frame)
                    let vf = scr.visibleFrame
                    let mh = mainHeight()
                    let fw = vf.width * 0.5, fh = vf.height * 0.6
                    let fx = vf.midX - fw / 2, fy = vf.midY - fh / 2
                    setSize(w.element, CGSize(width: fw, height: fh))
                    setPosition(w.element, CGPoint(x: fx, y: mh - (fy + fh)))
                    autoOffPlacedKeys.insert(winKey(w))
                }
            }
            return
        }
        // 未授权时菜单栏图标带 !，且只在状态变化时记一次日志，避免静默失效
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrustState {
            lastTrustState = trusted
            statusItem.button?.title = trusted ? "▦" : "▦!"
            log(trusted ? "Accessibility trusted: true"
                : "NOT TRUSTED: tiling disabled, re-grant in System Settings > Privacy & Security > Accessibility")
            if trusted {
                mouseTapFailedLogged = false
                setupMouseDragTap()
            }
        }
        guard trusted else {
            hideGrips()
            hideDotHandles()
            hideStackMarkers()
            hideHighlights()
            removeDimLayers()
            closeStackPanel()
            return
        }
        // C2：Stage Manager 开启时暂停一切平铺动作（窗口保持原样不动）
        refreshStageManagerPause()
        if stageManagerPaused {
            hideGrips()
            hideDotHandles()
            hideStackMarkers()
            hideHighlights()
            removeDimLayers()
            closeStackPanel()
            return
        }
        // pin 住的目标磁贴在用户切到别的 App 时放开，并重排一次。
        // 专注屏上 tile() 保持铺满，不把那扇窗口拉回格子。
        if pinnedActiveTile != nil, let pp = pinnedFrontmostPid,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != pp {
            pinnedActiveTile = nil
            pinnedScreenID = nil
            pinnedFrontmostPid = nil
            log("drag stack pin released")
            forceTile()
        }
        // 学到新最小尺寸后重排一次，让位/浮动随即生效；拖分隔线时不动手，免得和拖动打架。
        if learnedMinChanged, draggingDividerID == nil {
            learnedMinChanged = false
            forceTile()
        }
        tickCount += 1
        if tickCount % 5 == 0 { pruneFloated() }
        // C 批：活动磁贴跟随按屏算（用户点了别的窗口时暗色层/高亮移动，不等重排）；
        // 窗口集合没变时 tick 会在签名处提前返回，所以检查放前面
        // 收尾性能：每 tick 只枚举一次窗口再按屏分流（此前每屏各枚举一次，多屏时 N 倍浪费）
        var overlayChanged = false
        let tickWindows = collectWindows()
        for s in NSScreen.screens {
            let sid = screenID(s)
            let wins = tickWindows.filter { screenID(screenForFrame($0.frame)) == sid }
            let (_, active) = computeTiles(windows: wins, st: settingsFor(s), sid: sid)
            if lastActiveTileByScreen[sid] != active {
                lastActiveTileByScreen[sid] = active
                overlayChanged = true
            }
        }
        if overlayChanged {
            // 活动格子跟随前台窗口移动（不等重排）：高亮与变暗随之移动。
            refreshDimLayers()
            refreshHighlights()
        }
        // 普通拖动弹回：没按 ⌘ 拖已平铺窗口，松手后若仍在同一屏且位置或尺寸偏离落点，
        // 用同一条 0.5s 弹簧回到上次落点，并提示要按 ⌘ 才能交换。正在飞的窗口不参与。
        // 已经跨到另一块屏的不弹回，交给集合变化后在新屏重排。
        if NSEvent.pressedMouseButtons == 0, draggingDividerID == nil, dragState == nil, pendingDrag == nil {
            var toasted = false
            for (sid, tiles) in lastTilesByScreen {
                let live = tickWindows.filter { screenID(screenForFrame($0.frame)) == sid }
                for t in tiles {
                    let key = winKey(t.top)
                    guard key != focusKey else { continue }
                    guard frameMotions[key] == nil else { continue }
                    guard let placed = lastPlacedFrames[key],
                          let w = live.first(where: { winKey($0) == key }) else { continue }
                    // 只认位置偏离：尺寸偏离是应用最小尺寸顶住了（AX 成功但被系统按最小尺寸钳住），
                    // 不是用户拖的；把它也算进去会导致每秒误判、反复弹回并不断重置提示条 2.5s 计时，提示条就永远不消失。
                    let dx = w.frame.minX - placed.minX, dy = w.frame.minY - placed.minY
                    guard dx * dx + dy * dy > 16 else { continue }
                    guard screenID(screenForFrame(w.frame)) == sid else { continue }
                    placeFrame(w.element, placed, key: key, animated: true)
                    if !toasted {
                        let screen = NSScreen.screens.first(where: { screenID($0) == sid })
                        showToast("A plain drag never rearranges.", detail: "Hold ⌘ to swap.", on: screen)
                        toasted = true
                    }
                }
            }
        }
        let sig = fullSignature()
        if sig == lastSignature {
            pendingSignature = ""
            pendingTicks = 0
            return
        }
        // 集合变化（开窗/关窗）立即重排，不等防抖；拖动/动画中（鼠标按着、
        // 正在拖分隔线或 ⌘拖）仍走 2 周期防抖，避免拖动中途把窗口拽回磁贴
        let dragging = NSEvent.pressedMouseButtons != 0 || draggingDividerID != nil
            || dragState != nil || pendingDrag != nil
        if !dragging {
            lastSignature = sig
            pendingSignature = ""
            pendingTicks = 0
            tileAll()
            // 新窗口刚创建时可能还不接受位置设置，0.5 秒后补一次（仅当集合未再变化）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                if self.fullSignature() == self.lastSignature {
                    self.tileAll()
                }
            }
            return
        }
        if sig != pendingSignature {
            pendingSignature = sig
            pendingTicks = 0
            return
        }
        pendingTicks += 1
        if pendingTicks >= 2 {
            lastSignature = sig
            pendingSignature = ""
            pendingTicks = 0
            tileAll()
            // 新窗口刚创建时可能还不接受位置设置，0.5 秒后补一次（仅当集合未再变化）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                if self.fullSignature() == self.lastSignature {
                    self.tileAll()
                }
            }
        }
    }

    // 菜单触发的立即重排，不走防抖
    func forceTile() {
        guard AXIsProcessTrusted() else {
            log("forceTile skipped: not trusted")
            return
        }
        guard !stageManagerPaused else {
            log("forceTile skipped: Stage Manager paused")
            return
        }
        pruneFloated()
        lastSignature = fullSignature()
        pendingSignature = ""
        pendingTicks = 0
        tileAll()
    }

    // 签名只含每个 App 的窗口数：标题变化不触发重排，打开/关闭/最小化才触发
    func signature(_ windows: [WinInfo]) -> String {
        var counts: [pid_t: Int] = [:]
        for w in windows { counts[w.pid, default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "|")
    }

    // C 批全屏签名：每屏前缀屏 ID，窗口跨屏、开关屏都触发重排
    func fullSignature() -> String {
        let all = collectWindows()
        let grouped = Dictionary(grouping: all, by: { screenID(screenForFrame($0.frame)) })
        return NSScreen.screens.map { s in "\(screenID(s)):\(signature(grouped[screenID(s)] ?? []))" }.joined(separator: ";")
    }

    struct WinInfo {
        let pid: pid_t
        let appName: String
        let element: AXUIElement
        let title: String
        let frame: CGRect  // Cocoa 坐标（原点左下角）；读不到时为 .zero
    }

    // 单窗口标识：pid + 标题（AX 无公开稳定窗口 ID；同应用同标题的孪生窗口
    // 可能认错，属原型级折中；日志里只记应用名，不记标题）
    func winKey(_ w: WinInfo) -> String { "\(w.pid)|\(w.title)" }
    func winKey(pid: pid_t, title: String) -> String { "\(pid)|\(title)" }

    // 当前 Space 的在屏窗口（CG 窗口列表，onScreenOnly）：CG bounds 与 AX position
    // 同为 y 向下约定，可直接比对；CG 窗口名经常为空，故按 pid+bounds 匹配，不靠标题
    func onScreenCGWindows() -> [(pid: pid_t, bounds: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [(pid: pid_t, bounds: CGRect)] = []
        for w in list {
            guard let pidNum = w[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            guard let bd = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = (bd["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (bd["Y"] as? NSNumber)?.doubleValue ?? 0
            let ww = (bd["Width"] as? NSNumber)?.doubleValue ?? 0
            let hh = (bd["Height"] as? NSNumber)?.doubleValue ?? 0
            out.append((pidNum.int32Value, CGRect(x: x, y: y, width: ww, height: hh)))
        }
        return out
    }

    func collectWindows(includeFloated: Bool = false, onlyCurrentSpace: Bool = true) -> [WinInfo] {
        var out: [WinInfo] = []
        let myPid = ProcessInfo.processInfo.processIdentifier
        let mh = mainHeight()
        // CG 列表为空时 fail-open（不过滤），避免窗口服务器一时不可用导致全集消失
        let onScreen = onlyCurrentSpace ? onScreenCGWindows() : []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            guard app.processIdentifier != myPid else { continue }
            if let bid = app.bundleIdentifier, excludedBundles.contains(bid) { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let wins = value as? [AXUIElement] else { continue }
            for w in wins {
                if boolAttr(w, kAXMinimizedAttribute as CFString) { continue }
                if boolAttr(w, "AXFullScreen" as CFString) { continue }
                // 对话框、浮动窗默认不排（保存框、画中画、小面板之类）
                if let sub = stringAttr(w, kAXSubroleAttribute as CFString),
                   ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow"].contains(sub) { continue }
                let title = stringAttr(w, kAXTitleAttribute as CFString) ?? ""
                let frame = getFrame(w, screenHeight: mh) ?? .zero
                // 弹簧进行中 AX 与 CG 会差一帧以上，严格 2pt 比对会把正在飞的窗口从集合里丢掉，
                // 签名一变就会把动画打断。正在动画的窗口直接留下。
                let moving = frameMotions[winKey(pid: app.processIdentifier, title: title)] != nil
                // C 批 Space 过滤：只保留能在当前 Space 在屏列表里按 pid+bounds 对上的窗口；
                // AX frame（Cocoa 系）转回 y 向下系再比对：axY = 主屏高 - cocoaMaxY
                if onlyCurrentSpace, !onScreen.isEmpty, !moving {
                    let axY = mh - frame.maxY
                    let ok = onScreen.contains {
                        $0.pid == app.processIdentifier
                        && abs($0.bounds.minX - frame.minX) < 2 && abs($0.bounds.minY - axY) < 2
                        && abs($0.bounds.width - frame.width) < 2 && abs($0.bounds.height - frame.height) < 2
                    }
                    if !ok { continue }
                }
                let info = WinInfo(pid: app.processIdentifier, appName: app.localizedName ?? "?", element: w, title: title, frame: frame)
                // 手动 Float、超量居中浮动与最小尺寸浮动都不进平铺集合（includeFloated 时才带上）
                if !includeFloated && floatedKeys.contains(winKey(info)) { continue }
                out.append(info)
            }
        }
        return out
    }

    // 某屏的窗口：按 frame 中心点归属到所在屏
    func collectWindows(on screen: NSScreen, includeFloated: Bool = false) -> [WinInfo] {
        let sid = screenID(screen)
        return collectWindows(includeFloated: includeFloated).filter { screenID(screenForFrame($0.frame)) == sid }
    }

    // 定期清理已关闭的浮动窗口，避免之后同 pid+标题的新窗口被误当浮动；
    // C 批：用不过滤的集合，否则其他 Space 上的浮动窗口会被误判为已关闭
    func pruneFloated() {
        guard !floatedKeys.isEmpty, AXIsProcessTrusted() else { return }
        let all = collectWindows(includeFloated: true, onlyCurrentSpace: false)
        let keys = Set(all.map { winKey($0) })
        let before = floatedKeys.count
        floatedKeys = floatedKeys.intersection(keys)
        if floatedKeys.count != before {
            log("floated pruned: \(before) -> \(floatedKeys.count)")
        }
    }


    func boolAttr(_ el: AXUIElement, _ attr: CFString) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    func stringAttr(_ el: AXUIElement, _ attr: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &value) == .success else { return nil }
        return value as? String
    }

    func getAXPosition(_ el: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &value) == .success,
              let axv = value else { return nil }
        var pt = CGPoint.zero
        guard AXValueGetValue(axv as! AXValue, .cgPoint, &pt) else { return nil }
        return pt
    }

    // AX 坐标（原点主屏左上角，y 向下）-> Cocoa 坐标（原点左下角，y 向上）

    func getFrame(_ el: AXUIElement, screenHeight: CGFloat) -> CGRect? {
        guard let pt = getAXPosition(el) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &value) == .success,
              let axv = value else { return nil }
        var sz = CGSize.zero
        guard AXValueGetValue(axv as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(x: pt.x, y: screenHeight - (pt.y + sz.height), width: sz.width, height: sz.height)
    }

    // 最前应用在窗口列表中的下标；没有（前台 App 无可排窗口）时返回 nil
    func frontmostIndex(windows: [WinInfo]) -> Int? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return windows.firstIndex { $0.pid == app.processIdentifier }
    }

    // MARK: - 布局几何

    // 单一自适应布局（间距固定 8）：1 全屏、2 左右分、3 三列等分、4 田字。
    func tileFrames(count t: Int, vf: CGRect) -> [CGRect] {
        let g: CGFloat = 8
        switch min(t, 4) {
        case 1:
            return [vf]
        case 2:
            let w = (vf.width - 3 * g) / 2, h = vf.height - 2 * g
            return [
                CGRect(x: vf.minX + g, y: vf.minY + g, width: w, height: h),
                CGRect(x: vf.minX + g + w + g, y: vf.minY + g, width: w, height: h),
            ]
        case 3:
            let w = (vf.width - 4 * g) / 3, h = vf.height - 2 * g
            return (0..<3).map { CGRect(x: vf.minX + g + CGFloat($0) * (w + g), y: vf.minY + g, width: w, height: h) }
        case 4:
            let w = (vf.width - 3 * g) / 2, h = (vf.height - 3 * g) / 2
            let x0 = vf.minX + g, x1 = x0 + w + g
            let yTop = vf.maxY - g - h, yBot = vf.minY + g
            return [
                CGRect(x: x0, y: yTop, width: w, height: h),
                CGRect(x: x1, y: yTop, width: w, height: h),
                CGRect(x: x0, y: yBot, width: w, height: h),
                CGRect(x: x1, y: yBot, width: w, height: h),
            ]
        default:
            return []
        }
    }

    // 把窗口分到各磁贴：前 t 个窗口每磁贴一个，多余的堆进活动磁贴。
    // 活动磁贴 = 最前窗口所在的磁贴；最前窗口不在磁贴内（或没有）时为第 0 个。
    // 窗口顺序（⌘ 交换会改这张表）：先按 windowOrder 排，再把 Primary 移到首位；
    // 新窗口追加到末尾（未满时自成一格，满时进活动磁贴堆叠），消失的窗口剔除。
    // C 批：只追加新窗口，不裁剪——按屏调用 computeTiles 时不能误删别屏的顺序；
    // 消失窗口的裁剪由 tileAll 按全屏集合统一做
    func mergeWindowOrder(_ windows: [WinInfo]) {
        for w in windows where !windowOrder.contains(winKey(w)) { windowOrder.append(winKey(w)) }
    }

    func orderedWindows(_ windows: [WinInfo]) -> [WinInfo] {
        mergeWindowOrder(windows)
        var ordered = windows
        if !windowOrder.isEmpty {
            let rank = Dictionary(uniqueKeysWithValues: windowOrder.enumerated().map { ($0.element, $0.offset) })
            ordered = windows.sorted { (rank[winKey($0)] ?? Int.max) < (rank[winKey($1)] ?? Int.max) }
        }
        if let pk = primaryKey, let j = ordered.firstIndex(where: { winKey($0) == pk }), j > 0 {
            ordered.insert(ordered.remove(at: j), at: 0)
        }
        return ordered
    }

    /// 丢掉已经关闭的成员，把 A→B→C 收成 A→C，环（A→B→A）拆掉。
    /// 收完之后 host 自己一定不再是别人的成员。
    func normalizeStackedOnto(liveKeys: Set<String>) {
        stackedOnto = stackedOnto.filter { liveKeys.contains($0.key) && liveKeys.contains($0.value) && $0.key != $0.value }
        var guardN = 0
        var changed = true
        while changed && guardN < 8 {
            changed = false
            guardN += 1
            let snapshot = Array(stackedOnto)
            for (m, h) in snapshot {
                guard let hh = stackedOnto[h] else { continue }
                if hh == m || hh == h {
                    stackedOnto.removeValue(forKey: m)
                } else {
                    stackedOnto[m] = hh
                }
                changed = true
            }
        }
        stackedOnto = stackedOnto.filter { $0.key != $0.value && stackedOnto[$0.value] == nil }
    }

    /// ⌘ 交换两扇窗时对调它们的堆叠身份。其余窗口留在原来的磁贴：
    /// 原来跟着 A 的，改跟刚来到这块磁贴的 B。
    func exchangeStackRoles(_ a: String, _ b: String) {
        guard a != b else { return }
        let hostA = stackedOnto[a]
        let hostB = stackedOnto[b]
        if let hostB, hostB != a {
            stackedOnto[a] = hostB
        } else {
            stackedOnto.removeValue(forKey: a)
        }
        if let hostA, hostA != b {
            stackedOnto[b] = hostA
        } else {
            stackedOnto.removeValue(forKey: b)
        }
        if stackedOnto[a] == a { stackedOnto.removeValue(forKey: a) }
        if stackedOnto[b] == b { stackedOnto.removeValue(forKey: b) }
        var retarget: [String: String] = [:]
        for (m, h) in stackedOnto where m != a && m != b {
            if h == a { retarget[m] = b }
            else if h == b { retarget[m] = a }
        }
        for (m, h) in retarget where m != h {
            stackedOnto[m] = h
        }
        stackedOnto = stackedOnto.filter { $0.key != $0.value }
    }

    func computeTiles(windows: [WinInfo], st: ScreenSettings, sid: CGDirectDisplayID) -> (stacks: [[WinInfo]], active: Int) {
        let windows = orderedWindows(windows)
        normalizeStackedOnto(liveKeys: Set(windows.map { winKey($0) }))
        let roots = windows.filter { stackedOnto[winKey($0)] == nil }
        let rootPool = roots.isEmpty ? windows : roots
        let t = Swift.min(Swift.min(st.tileLimit, 4), rootPool.count)
        guard t > 0 else { return ([], 0) }
        var stacks: [[WinInfo]] = (0..<t).map { [rootPool[$0]] }
        // 活动磁贴：先记住上一轮。焦点如果落在一块已经占着格子的根窗口上，改跟它。
        // 刚打开、排在根窗口末尾的新窗口下标 ≥ t，不会把活动磁贴拽走。
        // 已经手动堆进别人磁贴的窗口也不是根，不能把活动磁贴拽走。
        var active = 0
        if let remembered = lastActiveTileByScreen[sid], remembered < t { active = remembered }
        if let fi = focusedIndex(windows: windows), windows.indices.contains(fi) {
            let fk = winKey(windows[fi])
            if stackedOnto[fk] == nil, let ti = stacks.firstIndex(where: { $0.contains { winKey($0) == fk } }) {
                active = ti
            }
        }
        // ⌃⌘ 拖进堆叠后 pin 住目标磁贴，直到用户切到别的 App 才放开。
        if let p = pinnedActiveTile, pinnedScreenID == sid { active = Swift.min(p, t - 1) }
        if rootPool.count > t {
            for w in rootPool[t...] { stacks[active].append(w) }
        }
        if !roots.isEmpty {
            for w in windows {
                guard let host = stackedOnto[winKey(w)] else { continue }
                if let ti = stacks.firstIndex(where: { $0.contains { winKey($0) == host } }) {
                    stacks[ti].append(w)
                } else {
                    stacks[active].append(w)
                }
            }
        }
        return (stacks, active)
    }

    // Primary 交换：指定窗口恒为 tile0 顶部，被换出的 tile0 顶部进该窗口原格子、接替其栈位。
    // 在 computeTiles 之后施加，因此重排后 Primary 不丢；窗口不存在（关闭/被浮动/跨屏）时裁剪该屏记录。
    func applyPrimarySwap(stacks: [[WinInfo]], sid: CGDirectDisplayID) -> [[WinInfo]] {
        guard let pk = primaryKeysByScreen[sid], !stacks.isEmpty else { return stacks }
        guard let pkTile = stacks.firstIndex(where: { $0.contains { winKey($0) == pk } }) else {
            primaryKeysByScreen.removeValue(forKey: sid)
            return stacks
        }
        var out = stacks
        let pkIdx = out[pkTile].firstIndex(where: { winKey($0) == pk })!
        let top0Idx = min(stackTops[stackTopKey(sid, 0)] ?? 0, out[0].count - 1)
        if pkTile == 0 {
            stackTops[stackTopKey(sid, 0)] = pkIdx
            return out
        }
        let b = out[0][top0Idx]
        out[0][top0Idx] = out[pkTile][pkIdx]
        out[pkTile][pkIdx] = b
        stackTops[stackTopKey(sid, 0)] = top0Idx
        stackTops[stackTopKey(sid, pkTile)] = pkIdx
        return out
    }

    /// 前台 App 的焦点窗口在这份列表里的下标。对不上时返回 nil，调用方再退回“该 App 的第一扇窗”。
    func focusedIndex(windows: [WinInfo]) -> Int? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return frontmostIndex(windows: windows)
        }
        let focused = raw as! AXUIElement
        let title = stringAttr(focused, kAXTitleAttribute as CFString) ?? ""
        let frame = getFrame(focused, screenHeight: mainHeight()) ?? .zero
        if let exact = windows.firstIndex(where: {
            $0.pid == app.processIdentifier && $0.title == title && framesClose($0.frame, frame)
        }) {
            return exact
        }
        return windows.firstIndex(where: { $0.pid == app.processIdentifier && $0.title == title })
            ?? frontmostIndex(windows: windows)
    }

    // MARK: - 平铺（C 批：按屏分治，每屏独立设置与磁贴）

    // 全屏重排：遍历当前全部屏；断开屏的残留磁贴/frame/活动记录一并清理，
    // 避免握把、高亮、暗色层留在已不存在的屏上
    func tileAll(windowsByScreen: [CGDirectDisplayID: [WinInfo]]? = nil) {
        // C2：Stage Manager 暂停时连 0.5 秒补铺也不执行
        guard !stageManagerPaused else { return }
        let screens = NSScreen.screens
        let liveIDs = Set(screens.map(screenID))
        lastTilesByScreen = lastTilesByScreen.filter { liveIDs.contains($0.key) }
        lastVFByScreen = lastVFByScreen.filter { liveIDs.contains($0.key) }
        lastScreenFrameByScreen = lastScreenFrameByScreen.filter { liveIDs.contains($0.key) }
        lastActiveTileByScreen = lastActiveTileByScreen.filter { liveIDs.contains($0.key) }
        var byScreen = windowsByScreen
        if byScreen == nil {
            let all = collectWindows()
            byScreen = Dictionary(grouping: all, by: { screenID(screenForFrame($0.frame)) })
        }
        let allWindows = byScreen!.values.flatMap { $0 }
        // 消失窗口：顺序与落点记录按全屏集合统一裁剪；Primary 全屏都不见才清
        windowOrder.removeAll { key in !allWindows.contains(where: { winKey($0) == key }) }
        lastPlacedFrames = lastPlacedFrames.filter { entry in allWindows.contains(where: { winKey($0) == entry.key }) }
        normalizeStackedOnto(liveKeys: Set(allWindows.map { winKey($0) }))
        if let pk = primaryKey, !allWindows.contains(where: { winKey($0) == pk }) {
            primaryKey = nil
        }
        primaryKeysByScreen = primaryKeysByScreen.filter { _, key in allWindows.contains(where: { winKey($0) == key }) }
        for s in screens {
            tile(screen: s, windows: byScreen![screenID(s)] ?? [], refreshOverlays: false)
        }
        refreshGrips()
        refreshDotHandles()
        refreshStackMarkers()
        // legacy 兜底：活动屏的磁贴/frame，供单屏路径（悬停条等）复用
        let act = activeScreen()
        lastTiles = lastTilesByScreen[screenID(act)] ?? []
        lastVF = act.visibleFrame
        lastScreenFrame = act.frame
        lastActiveTile = lastActiveTileByScreen[screenID(act)] ?? 0
    }

    // 最小尺寸让位：磁贴小于已学尺寸时，从相邻磁贴匀空间（不把邻居压到
    // 其已学最小尺寸或 160×120 底线以下）；匀完仍不够的由调用方判浮动
    // 分割线让位：按格子顶部窗口的学习最小尺寸移动分隔线。只看顶部窗口，
    // 堆叠里被盖住的不管（轮到它上浮时再触发）。双向都让：左/上不够向右/下
    // 移缝，右/下不够向左/上移缝；两轮收敛三列链。缝移动时两侧同量进退，8pt 缝不变。
    func applyGiveWay(frames: [CGRect], stacks: [[WinInfo]], sid: CGDirectDisplayID) -> [CGRect] {
        guard !frames.isEmpty, frames.count == stacks.count else { return frames }
        var out = frames
        func topMin(_ tile: Int) -> CGSize {
            let stack = stacks[tile]
            guard !stack.isEmpty else { return .zero }
            let top = stack[min(stackTops[stackTopKey(sid, tile)] ?? 0, stack.count - 1)]
            return learnedMinSizes[top.appName] ?? .zero
        }
        for _ in 0..<2 {
            let dividers = deriveDividers(frames: out, gap: 8, sid: sid)
            for d in dividers {
                if d.vertical {
                    let left = out.indices.filter { abs(out[$0].maxX - (d.center - 4)) < 1.5 }
                    let right = out.indices.filter { abs(out[$0].minX - (d.center + 4)) < 1.5 }
                    guard !left.isEmpty, !right.isEmpty else { continue }
                    var deficit = left.map { max(0, max(topMin($0).width, 160) - out[$0].width) }.max() ?? 0
                    var slack = right.map { out[$0].width - max(topMin($0).width, 160) }.min() ?? 0
                    var move = min(deficit, slack)
                    if move > 0 {
                        for i in left { out[i].size.width += move }
                        for i in right { out[i].origin.x += move; out[i].size.width -= move }
                    }
                    deficit = right.map { max(0, max(topMin($0).width, 160) - out[$0].width) }.max() ?? 0
                    slack = left.map { out[$0].width - max(topMin($0).width, 160) }.min() ?? 0
                    move = min(deficit, slack)
                    if move > 0 {
                        for i in right { out[i].origin.x -= move; out[i].size.width += move }
                        for i in left { out[i].size.width -= move }
                    }
                } else {
                    let above = out.indices.filter { abs(out[$0].minY - (d.center + 4)) < 1.5 }
                    let below = out.indices.filter { abs(out[$0].maxY - (d.center - 4)) < 1.5 }
                    guard !above.isEmpty, !below.isEmpty else { continue }
                    var deficit = above.map { max(0, max(topMin($0).height, 120) - out[$0].height) }.max() ?? 0
                    var slack = below.map { out[$0].height - max(topMin($0).height, 120) }.min() ?? 0
                    var move = min(deficit, slack)
                    if move > 0 {
                        for i in above { out[i].origin.y -= move; out[i].size.height += move }
                        for i in below { out[i].size.height -= move }
                    }
                    deficit = below.map { max(0, max(topMin($0).height, 120) - out[$0].height) }.max() ?? 0
                    slack = above.map { out[$0].height - max(topMin($0).height, 120) }.min() ?? 0
                    move = min(deficit, slack)
                    if move > 0 {
                        for i in below { out[i].size.height += move }
                        for i in above { out[i].origin.y += move; out[i].size.height -= move }
                    }
                }
            }
        }
        return out
    }

    func tile(screen: NSScreen, windows: [WinInfo], refreshOverlays: Bool = true) {
        let sid = screenID(screen)
        let st = settingsFor(screen)
        var windows = windows
        guard !windows.isEmpty else {
            lastTilesByScreen[sid] = []
            if refreshOverlays { refreshGrips(); refreshDimLayers(); refreshHighlights(); refreshDotHandles(); refreshStackMarkers() }
            return
        }
        let vf = screen.visibleFrame
        // Focus 盖住式：聚焦窗口铺满本屏可视区并置顶，其余窗口不动；
        // 聚焦窗口已不在集合里（关闭或被浮动排除）则退出 Focus，走正常平铺。
        if let fk = focusKey, focusScreen == sid {
            if let fw = windows.first(where: { winKey($0) == fk }) {
                AXUIElementPerformAction(fw.element, kAXRaiseAction as CFString)
                placeFrame(fw.element, vf, key: fk, animated: draggingDividerID == nil)
                lastPlacedFrames[fk] = vf
                if refreshOverlays { hideGrips(); hideStackMarkers(); hideHighlights(); removeDimLayers() }
                return
            }
            focusKey = nil
            focusScreen = nil
            focusSavedFrames = nil
            focusSavedTops = nil
            focusSavedActive = nil
            log("focus off: target gone")
        }
        let sig = signature(windows)
        let previousTiles = lastTilesByScreen[sid] ?? []
        let previousKeys = Set(previousTiles.flatMap { $0.stack.map { winKey($0) } })
        var preservedTopKeys: [String] = []
        let signatureChanged = sig != lastTiledSignatureByScreen[sid]
        if signatureChanged {
            for (i, tile) in previousTiles.enumerated() where !tile.stack.isEmpty {
                let idx = min(stackTops[stackTopKey(sid, i)] ?? 0, tile.stack.count - 1)
                preservedTopKeys.append(winKey(tile.stack[idx]))
            }
            // 下标会随关窗错位，按窗口键在新堆叠里再找回来；不要把每一叠都清成 0。
            stackTops = stackTops.filter { !$0.key.hasPrefix("\(sid):") }
            lastTiledSignatureByScreen[sid] = sig
        }
        var (stacks, origActive) = computeTiles(windows: windows, st: st, sid: sid)
        stacks = applyPrimarySwap(stacks: stacks, sid: sid)
        // 堆叠产生时提示一次（从无堆叠变为有堆叠才弹，不刷屏）
        let hasStack = stacks.contains { $0.count > 1 }
        if hasStack, lastStackByScreen[sid] != true {
            showToast("Stacked in this tile", detail: "Hover the top edge or click the orange marks to switch.", on: screen)
        }
        lastStackByScreen[sid] = hasStack
        let origFrames = applySplitOverrides(frames: tileFrames(count: stacks.count, vf: vf), tileCount: stacks.count, vf: vf, sid: sid)
        let activeTopKey = stacks.isEmpty ? "" : winKey(stacks[origActive][min(stackTops[stackTopKey(sid, origActive)] ?? 0, stacks[origActive].count - 1)])
        var frames: [CGRect] = origFrames
        let fitStacks = stacks
        let active = fitStacks.firstIndex(where: { $0.contains(where: { winKey($0) == activeTopKey }) }) ?? 0
        if signatureChanged {
            for (i, stack) in fitStacks.enumerated() {
                if let key = preservedTopKeys.first(where: { k in stack.contains { winKey($0) == k } }),
                   let idx = stack.firstIndex(where: { winKey($0) == key }) {
                    stackTops[stackTopKey(sid, i)] = idx
                }
            }
            // 新开的焦点窗口盖到它所在磁贴的最上面，而不是垫在旧窗口底下。
            if let fi = focusedIndex(windows: windows), windows.indices.contains(fi) {
                let fk = winKey(windows[fi])
                if !previousKeys.contains(fk) {
                    for (i, stack) in fitStacks.enumerated() {
                        if let idx = stack.firstIndex(where: { winKey($0) == fk }) {
                            stackTops[stackTopKey(sid, i)] = idx
                            AXUIElementPerformAction(windows[fi].element, kAXRaiseAction as CFString)
                        }
                    }
                }
            }
        }
        // 分割线让位：格子顶部窗口的学习最小尺寸大于格子时，移动相邻
        // 分隔线把格子扩到该下限，从邻格匀空间；邻格不被压到自己的学习下限
        // 以下，也不小于 160 宽/120 高、不侵占 8pt 缝。拖分隔线时跳过。
        if draggingDividerID == nil {
            frames = applyGiveWay(frames: frames, stacks: fitStacks, sid: sid)
        }
        // 装不下就居中浮动：让位后格子顶部窗口的学习最小尺寸仍大于格子，
        // 该窗口移到屏幕中央、按自然尺寸浮动，并进 floatedKeys（与悬停条 Float 同一套机制，
        // 面板“恢复浮动窗口”可恢复；下一轮 tick 收集窗口时它被跳过，格子随即重排干净）。
        // 恢复后若再次装不下会再次浮动，这是符合规则的行为，不另加状态。
        var floatedCenters: [String: CGRect] = [:]
        if draggingDividerID == nil {
            for (i, stack) in fitStacks.enumerated() where !stack.isEmpty {
                let top = stack[min(stackTops[stackTopKey(sid, i)] ?? 0, stack.count - 1)]
                guard let need = learnedMinSizes[top.appName] else { continue }
                let f = frames[i]
                guard need.width > f.width + 4 || need.height > f.height + 4 else { continue }
                // 未知维（0）按无约束处理：浮动目标该维用窗口当前尺寸，绝不按 0 用。
                let curSize = getSize(top.element) ?? top.frame.size
                let w = Swift.min(need.width > 0 ? need.width : curSize.width, vf.width - 16)
                let h = Swift.min(need.height > 0 ? need.height : curSize.height, vf.height - 16)
                floatedCenters[winKey(top)] = CGRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h)
                if floatedKeys.insert(winKey(top)).inserted {
                    logDiag("min-size float: \(top.appName) min=\(Int(need.width))x\(Int(need.height)) tile=\(Int(f.width))x\(Int(f.height))")
                }
            }
        }
        let animateMoves = draggingDividerID == nil
        for (i, stack) in fitStacks.enumerated() {
            for w in stack {
                let key = winKey(w)
                let target = floatedCenters[key] ?? frames[i]
                let preSize = getSize(w.element)
                placeFrame(w.element, target, key: key, animated: animateMoves, learnName: w.appName, preSize: preSize)
                // 记实际落点（浮动窗口记中央帧），否则下一轮 tick 会把浮动窗口当成
                // 被拖动的窗口弹回格子。
                if lastPlacedFrames[key] != target {
                    lastPlacedFrames[key] = target
                }
            }
        }
        lastVFByScreen[sid] = vf
        lastScreenFrameByScreen[sid] = screen.frame
        lastActiveTileByScreen[sid] = active
        lastTilesByScreen[sid] = fitStacks.enumerated().map { (i, s) in
            let top = s[min(stackTops[stackTopKey(sid, i)] ?? 0, s.count - 1)]
            let shown = inFlightFrame(key: winKey(top)) ?? frames[i]
            return (stack: s, frame: shown, top: top)
        }
        if refreshOverlays {
            refreshGrips()
            refreshDimLayers()
            refreshHighlights()
            refreshDotHandles()
            refreshStackMarkers()
        }
        let tileDesc = fitStacks.enumerated().map { (i, s) in
            let names = Dictionary(grouping: s, by: { $0.appName })
                .map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: "+")
            return "tile\(i)[\(s.count)]:\(names)"
        }.joined(separator: " ")
        if !dragQuiet {
            log("tiled screen=\(screenName(screen)) \(windows.count) windows limit=\(st.tileLimit) tiles=\(fitStacks.count) active=\(active) \(tileDesc)")
        }
    }

    // MARK: - 短弹簧（约 0.5s，轻微过冲，可被下一次布局打断）

    struct FrameMotion {
        let element: AXUIElement
        let key: String
        var from: CGRect
        var to: CGRect
        var start: CFTimeInterval
        let duration: CFTimeInterval
        let preSize: CGSize?
        let learnName: String
    }

    final class OpacityFade {
        weak var window: NSWindow?
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let done: (() -> Void)?
        init(window: NSWindow, from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval, done: (() -> Void)?) {
            self.window = window
            self.from = from
            self.to = to
            self.start = start
            self.duration = duration
            self.done = done
        }
    }

    var frameMotions: [String: FrameMotion] = [:]
    var motionTimer: Timer?
    var opacityFades: [OpacityFade] = []
    var toastPopStart: CFTimeInterval?

    /// easeOutBack，t=1 时精确落到 1，中途大约 5% 过冲。c1 取 1.15。
    func springUnit(_ t: CGFloat) -> CGFloat {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        let c1: CGFloat = 1.15
        let c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }

    func lerpRect(_ a: CGRect, _ b: CGRect, _ p: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * p,
            y: a.minY + (b.minY - a.minY) * p,
            width: max(1, a.width + (b.width - a.width) * p),
            height: max(1, a.height + (b.height - a.height) * p)
        )
    }

    func framesClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.75 && abs(a.minY - b.minY) < 0.75
            && abs(a.width - b.width) < 0.75 && abs(a.height - b.height) < 0.75
    }

    func applyAXFrame(_ el: AXUIElement, _ frame: CGRect) {
        // 落点目标钳制：任一维 <1 钳到 1，杜绝 0 高/0 宽目标导致的 AX 成批失败。
        var f = frame
        if f.width < 1 { logDiag("AX target clamped width: \(f.width) -> 1"); f.size.width = 1 }
        if f.height < 1 { logDiag("AX target clamped height: \(f.height) -> 1"); f.size.height = 1 }
        setSize(el, f.size)
        setPosition(el, CGPoint(x: f.minX, y: mainHeight() - f.maxY))
    }

    func inFlightFrame(key: String) -> CGRect? {
        guard let m = frameMotions[key] else { return nil }
        let t = CGFloat((CACurrentMediaTime() - m.start) / m.duration)
        if t >= 1 { return m.to }
        return lerpRect(m.from, m.to, springUnit(max(0, t)))
    }

    // 落点与目标差 4pt 以上就记一笔（拖动分隔线时不记，免得刷屏），
    // 并按维学习最小尺寸：只有 post 比 target 大 4pt 以上的维才记为该维下限（覆盖式），
    // 落准的维不改；学到新值就置位，下一轮 tick 重排一次（让位/浮动随即生效）。
    // 学习值永不为 0：未知维按无约束处理（消费处遇 0 用当前尺寸/底线兜底，绝不按 0 用）；
    // 瞬态小窗口与退化目标不学习，免得毒化按应用的学习值。
    func logPlacementMismatch(name: String, pre: CGSize, target: CGSize, post: CGSize?) {
        if draggingDividerID == nil, let post,
           abs(post.width - target.width) > 4 || abs(post.height - target.height) > 4 {
            logDiag("size mismatch: \(name) pre=\(Int(pre.width))x\(Int(pre.height)) target=\(Int(target.width))x\(Int(target.height)) post=\(Int(post.width))x\(Int(post.height))")
            if !name.isEmpty {
                // 退化目标（任一维 <1，如旧 0 高浮动目标）不学习：miss 本身无意义。
                guard target.width >= 1, target.height >= 1 else {
                    logDiag("min-size learn skipped degenerate target: \(name) target=\(Int(target.width))x\(Int(target.height))")
                    return
                }
                // 瞬态小窗口（条形弹窗类，如 1512x41、310x50）不学习：不得毒化按应用的学习值。
                guard post.width >= 160, post.height >= 120 else {
                    logDiag("min-size learn skipped transient window: \(name) post=\(Int(post.width))x\(Int(post.height))")
                    return
                }
                let maxW = NSScreen.screens.map { $0.visibleFrame.width }.max() ?? post.width
                let maxH = NSScreen.screens.map { $0.visibleFrame.height }.max() ?? post.height
                var cur = learnedMinSizes[name] ?? .zero
                var changed = false
                if post.width > target.width + 4, post.width > 0 {
                    let v = min(post.width, maxW)
                    if cur.width != v { cur.width = v; changed = true }
                }
                if post.height > target.height + 4, post.height > 0 {
                    let v = min(post.height, maxH)
                    if cur.height != v { cur.height = v; changed = true }
                }
                if changed {
                    learnedMinSizes[name] = cur
                    saveLearnedMinSizes()
                    learnedMinChanged = true
                    logDiag("min-size learned: \(name) \(Int(cur.width))x\(Int(cur.height))")
                }
            }
        }
    }

    /// 把一扇窗送到 target。animated 时从当前（或飞行中）帧起跳，同一目的地不重开弹簧。
    /// 分隔线拖动传 animated: false，手跟着走。
    func placeFrame(_ el: AXUIElement, _ target: CGRect, key: String, animated: Bool, learnName: String = "", preSize: CGSize? = nil) {
        if animated, let existing = frameMotions[key], framesClose(existing.to, target) {
            return
        }
        let from = inFlightFrame(key: key) ?? getFrame(el, screenHeight: mainHeight()) ?? target
        if !animated || framesClose(from, target) {
            frameMotions.removeValue(forKey: key)
            applyAXFrame(el, target)
            if let pre = preSize {
                logPlacementMismatch(name: learnName, pre: pre, target: target.size, post: getSize(el))
            }
            stopMotionTimerIfIdle()
            return
        }
        frameMotions[key] = FrameMotion(
            element: el, key: key, from: from, to: target,
            start: CACurrentMediaTime(), duration: 0.5,
            preSize: preSize, learnName: learnName
        )
        startMotionTimer()
    }

    func startMotionTimer() {
        if motionTimer != nil { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.stepMotion()
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    func stopMotionTimerIfIdle() {
        let popping = toastPopStart != nil
        if frameMotions.isEmpty, opacityFades.isEmpty, !popping {
            motionTimer?.invalidate()
            motionTimer = nil
        }
    }

    func stepMotion() {
        let now = CACurrentMediaTime()
        var finished: [String] = []
        for (key, m) in frameMotions {
            let t = CGFloat((now - m.start) / m.duration)
            if t >= 1 {
                applyAXFrame(m.element, m.to)
                if let pre = m.preSize {
                    logPlacementMismatch(name: m.learnName, pre: pre, target: m.to.size, post: getSize(m.element))
                }
                finished.append(key)
            } else {
                applyAXFrame(m.element, lerpRect(m.from, m.to, springUnit(t)))
            }
        }
        for key in finished { frameMotions.removeValue(forKey: key) }
        if !frameMotions.isEmpty { syncOverlayFramesToMotion() }
        var stillFading: [OpacityFade] = []
        var fadeDone: [() -> Void] = []
        for fade in opacityFades {
            guard let window = fade.window else { continue }
            let t = min(1, CGFloat((now - fade.start) / max(fade.duration, 0.0001)))
            window.alphaValue = fade.from + (fade.to - fade.from) * t
            if t < 1 {
                stillFading.append(fade)
            } else {
                window.alphaValue = fade.to
                if let done = fade.done { fadeDone.append(done) }
            }
        }
        opacityFades = stillFading
        // 完成回调里如果再登记一段淡入淡出，要落在上面的赋值之后，不然会被盖掉。
        for done in fadeDone { done() }
        if let pop = toastPopStart, let panel = toastPanel {
            let t = min(1, CGFloat((now - pop) / 0.2))
            panel.alphaValue = t
            if t >= 1 { toastPopStart = nil }
        }
        if frameMotions.isEmpty, opacityFades.isEmpty, toastPopStart == nil {
            motionTimer?.invalidate()
            motionTimer = nil
            refreshGrips()
            refreshStackMarkers()
        }
    }

    func syncOverlayFramesToMotion() {
        var changed = false
        for (sid, var tiles) in lastTilesByScreen {
            for i in tiles.indices {
                let key = winKey(tiles[i].top)
                if let live = inFlightFrame(key: key), !framesClose(tiles[i].frame, live) {
                    tiles[i].frame = live
                    changed = true
                }
            }
            lastTilesByScreen[sid] = tiles
        }
        if changed {
            let act = activeScreen()
            lastTiles = lastTilesByScreen[screenID(act)] ?? []
            refreshGrips()
            refreshStackMarkers()
        }
    }

    func fadeWindow(_ window: NSWindow, to: CGFloat, duration: CFTimeInterval = 0.35, done: (() -> Void)? = nil) {
        let job = OpacityFade(window: window, from: window.alphaValue, to: to, start: CACurrentMediaTime(), duration: duration, done: done)
        opacityFades.removeAll { $0.window === window }
        opacityFades.append(job)
        startMotionTimer()
    }

    func setPosition(_ el: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) {
            let err = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
            if err != .success { logDiag("AX setPosition failed: \(err.rawValue) target=\(Int(point.x)),\(Int(point.y))") }
        }
    }

    func setSize(_ el: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) {
            let err = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
            if err != .success { logDiag("AX setSize failed: \(err.rawValue) target=\(Int(size.width))x\(Int(size.height))") }
        }
    }

    // C2：回读窗口实际尺寸（读不到时返回 nil，调用方不计入学习）
    func getSize(_ el: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &value) == .success,
              let axv = value else { return nil }
        var sz = CGSize.zero
        guard AXValueGetValue(axv as! AXValue, .cgSize, &sz) else { return nil }
        return sz
    }

    func bundleID(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }


    // MARK: - 堆叠轮换


    // MARK: - v6 可拖分隔线

    struct Divider {
        let id: String          // v0.. / h0..，按中心坐标排序，同一直线多段合并成一条
        let vertical: Bool
        let center: CGFloat     // 竖线为 x，横线为 y（Cocoa 坐标）
        let lo: CGFloat         // 沿轴范围下限（竖线为 y，横线为 x）
        let hi: CGFloat
        let minCenter: CGFloat  // 拖动下限（保证两侧磁贴最小尺寸）
        let maxCenter: CGFloat
        let screenID: CGDirectDisplayID  // C 批：手柄所属屏
    }

    // 从一组磁贴 frame 里找共享边：竖边 = 左格右沿 + 间隙 ≈ 右格左沿；
    // 横边 = 上格下沿 + 间隙 ≈ 下格上沿（Cocoa y 向上，上格 minY 更大）。
    func deriveDividers(frames: [CGRect], gap g: CGFloat, sid: CGDirectDisplayID) -> [Divider] {
        var vRaw: [(x: CGFloat, lo: CGFloat, hi: CGFloat, leftMin: CGFloat, rightMax: CGFloat)] = []
        var hRaw: [(y: CGFloat, lo: CGFloat, hi: CGFloat, belowMin: CGFloat, aboveMax: CGFloat)] = []
        for i in frames.indices {
            for j in frames.indices where j > i {
                let a = frames[i], b = frames[j]
                if abs((a.maxX + g) - b.minX) < 1.5, min(a.maxY, b.maxY) - max(a.minY, b.minY) > 20 {
                    vRaw.append((x: (a.maxX + b.minX) / 2, lo: max(a.minY, b.minY), hi: min(a.maxY, b.maxY), leftMin: min(a.minX, b.minX), rightMax: max(a.maxX, b.maxX)))
                } else if abs((b.maxX + g) - a.minX) < 1.5, min(a.maxY, b.maxY) - max(a.minY, b.minY) > 20 {
                    vRaw.append((x: (b.maxX + a.minX) / 2, lo: max(a.minY, b.minY), hi: min(a.maxY, b.maxY), leftMin: min(a.minX, b.minX), rightMax: max(a.maxX, b.maxX)))
                }
                if abs(a.minY - (b.maxY + g)) < 1.5, min(a.maxX, b.maxX) - max(a.minX, b.minX) > 20 {
                    hRaw.append((y: (a.minY + b.maxY) / 2, lo: max(a.minX, b.minX), hi: min(a.maxX, b.maxX), belowMin: min(a.minY, b.minY), aboveMax: max(a.maxY, b.maxY)))
                } else if abs(b.minY - (a.maxY + g)) < 1.5, min(a.maxX, b.maxX) - max(a.minX, b.minX) > 20 {
                    hRaw.append((y: (b.minY + a.maxY) / 2, lo: max(a.minX, b.minX), hi: min(a.maxX, b.maxX), belowMin: min(a.minY, b.minY), aboveMax: max(a.maxY, b.maxY)))
                }
            }
        }
        var out: [Divider] = []
        for (k, l) in mergeV(vRaw).enumerated() {
            out.append(Divider(id: "v\(k)", vertical: true, center: l.x, lo: l.lo, hi: l.hi,
                               minCenter: l.leftMin + 160 + g / 2, maxCenter: l.rightMax - 160 - g / 2, screenID: sid))
        }
        for (k, l) in mergeH(hRaw).enumerated() {
            out.append(Divider(id: "h\(k)", vertical: false, center: l.y, lo: l.lo, hi: l.hi,
                               minCenter: l.belowMin + 120 + g / 2, maxCenter: l.aboveMax - 120 - g / 2, screenID: sid))
        }
        return out
    }

    private func mergeV(_ raw: [(x: CGFloat, lo: CGFloat, hi: CGFloat, leftMin: CGFloat, rightMax: CGFloat)])
        -> [(x: CGFloat, lo: CGFloat, hi: CGFloat, leftMin: CGFloat, rightMax: CGFloat)] {
        var out: [(x: CGFloat, lo: CGFloat, hi: CGFloat, leftMin: CGFloat, rightMax: CGFloat)] = []
        for l in raw.sorted(by: { $0.x < $1.x }) {
            if let last = out.last, abs(last.x - l.x) < 1.5 {
                out[out.count - 1] = (x: last.x, lo: min(last.lo, l.lo), hi: max(last.hi, l.hi),
                                      leftMin: min(last.leftMin, l.leftMin), rightMax: max(last.rightMax, l.rightMax))
            } else {
                out.append(l)
            }
        }
        return out
    }

    private func mergeH(_ raw: [(y: CGFloat, lo: CGFloat, hi: CGFloat, belowMin: CGFloat, aboveMax: CGFloat)])
        -> [(y: CGFloat, lo: CGFloat, hi: CGFloat, belowMin: CGFloat, aboveMax: CGFloat)] {
        var out: [(y: CGFloat, lo: CGFloat, hi: CGFloat, belowMin: CGFloat, aboveMax: CGFloat)] = []
        for l in raw.sorted(by: { $0.y < $1.y }) {
            if let last = out.last, abs(last.y - l.y) < 1.5 {
                out[out.count - 1] = (y: last.y, lo: min(last.lo, l.lo), hi: max(last.hi, l.hi),
                                      belowMin: min(last.belowMin, l.belowMin), aboveMax: max(last.aboveMax, l.aboveMax))
            } else {
                out.append(l)
            }
        }
        return out
    }

    // 把记忆的自定义分割套到默认 frame 上：按原始边判断格子贴着哪条线，
    // 再用当前边改宽/高；竖线与横线改不同轴，互不干扰。
    // C 批：key 带屏 ID；旧 key（无屏 ID）作 fallback，升级后单屏的自定义分割不丢
    func applySplitOverrides(frames: [CGRect], tileCount: Int, vf: CGRect, sid: CGDirectDisplayID) -> [CGRect] {
        guard !splitOverrides.isEmpty, !frames.isEmpty else { return frames }
        let g: CGFloat = 8
        let dividers = deriveDividers(frames: frames, gap: g, sid: sid)
        var out = frames
        for d in dividers {
            let key = "\(sid)-\(tileCount)-\(d.id)"
            guard let f = splitOverrides[key] ?? splitOverrides["\(tileCount)-\(d.id)"] else { continue }
            let rawCenter = d.vertical ? vf.minX + f * vf.width : vf.minY + f * vf.height
            let clamped = min(max(rawCenter, d.minCenter), d.maxCenter)
            for i in frames.indices {
                let o = frames[i]
                if d.vertical {
                    if abs(o.maxX - (d.center - g / 2)) < 1.5 {
                        out[i].size.width = clamped - g / 2 - out[i].minX
                    } else if abs(o.minX - (d.center + g / 2)) < 1.5 {
                        let nm = clamped + g / 2
                        out[i].size.width = out[i].maxX - nm
                        out[i].origin.x = nm
                    }
                } else {
                    if abs(o.minY - (d.center + g / 2)) < 1.5 {
                        let nm = clamped + g / 2
                        out[i].size.height = out[i].maxY - nm
                        out[i].origin.y = nm
                    } else if abs(o.maxY - (d.center - g / 2)) < 1.5 {
                        out[i].size.height = clamped - g / 2 - out[i].minY
                    }
                }
            }
        }
        return out
    }

    final class GripView: NSView {
        var divider: Divider!
        // phase：0 按下，1 拖动（值为新中心），2 松开；回调读 view.divider 的最新值
        var onDrag: ((GripView, Int, CGFloat) -> Void)?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        // 命中区就是整条缝，平时不画点；拖的是间隙本身。
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: (divider?.vertical ?? true) ? .resizeLeftRight : .resizeUpDown)
        }
        override func draw(_ dirtyRect: NSRect) {}
        override func mouseDown(with event: NSEvent) { onDrag?(self, 0, 0) }
        override func mouseDragged(with event: NSEvent) {
            let m = NSEvent.mouseLocation
            onDrag?(self, 1, divider.vertical ? m.x : m.y)
        }
        override func mouseUp(with event: NSEvent) { onDrag?(self, 2, 0) }
    }

    func refreshGrips() {
        guard AXIsProcessTrusted(), autoTile else {
            hideGrips()
            return
        }
        guard draggingDividerID == nil else { return }  // 拖动中不重建手柄
        var seen: Set<String> = []
        for (sid, tiles) in lastTilesByScreen where !tiles.isEmpty {
            guard let screen = NSScreen.screens.first(where: { screenID($0) == sid }) else { continue }
            let st = settingsFor(screen)
            let frames = tiles.map { $0.frame }
            let dividers = deriveDividers(frames: frames, gap: 8, sid: sid)
            for d in dividers {
                let key = "\(sid)-\(d.id)"
                seen.insert(key)
                let thickness: CGFloat = 8
                let span = max(8, d.hi - d.lo)
                let rect: NSRect = d.vertical
                    ? NSRect(x: d.center - thickness / 2, y: d.lo, width: thickness, height: span)
                    : NSRect(x: d.lo, y: d.center - thickness / 2, width: span, height: thickness)
                if let panel = gripPanels[key] {
                    panel.setFrame(rect, display: true)
                    (panel.contentView as? GripView)?.divider = d
                } else {
                    let view = GripView(frame: NSRect(origin: .zero, size: rect.size))
                    view.divider = d
                    view.onDrag = { [weak self] v, phase, value in
                        guard let self = self, let dd = v.divider else { return }
                        switch phase {
                        case 0:
                            self.draggingDividerID = dd.id
                            self.dragQuiet = true
                        case 1:
                            guard let scr = NSScreen.screens.first(where: { self.screenID($0) == dd.screenID }) else { return }
                            let vf = scr.visibleFrame
                            // 拖缝钳制：除现有 160/120 下限外，再按两侧格子顶部窗口的
                            // 学习最小尺寸收紧行程——被缩小的一侧不得小于其学习下限，
                            // 拖到最小尺寸就停住，而不是盖过去。按当前格子帧重算分隔线
                            // 位置（dd 是手柄创建时的快照，拖动中格子已移动）。
                            var lo = dd.minCenter, hi = dd.maxCenter
                            if let tiles = self.lastTilesByScreen[dd.screenID] {
                                let curDividers = self.deriveDividers(frames: tiles.map { $0.frame }, gap: 8, sid: dd.screenID)
                                if let cur = curDividers.first(where: { $0.id == dd.id }) {
                                    lo = max(lo, cur.minCenter); hi = min(hi, cur.maxCenter)
                                    for t in tiles {
                                        guard let minSize = self.learnedMinSizes[t.top.appName] else { continue }
                                        if dd.vertical {
                                            if abs(t.frame.maxX - (cur.center - 4)) < 1.5 {
                                                lo = max(lo, t.frame.minX + max(minSize.width, 160) + 4)
                                            } else if abs(t.frame.minX - (cur.center + 4)) < 1.5 {
                                                hi = min(hi, t.frame.maxX - max(minSize.width, 160) - 4)
                                            }
                                        } else {
                                            if abs(t.frame.minY - (cur.center + 4)) < 1.5 {
                                                hi = min(hi, t.frame.maxY - max(minSize.height, 120) - 4)
                                            } else if abs(t.frame.maxY - (cur.center - 4)) < 1.5 {
                                                lo = max(lo, t.frame.minY + max(minSize.height, 120) + 4)
                                            }
                                        }
                                    }
                                }
                            }
                            let clamped = min(max(value, lo), hi)
                            let f = dd.vertical
                                ? (clamped - vf.minX) / vf.width
                                : (clamped - vf.minY) / vf.height
                            let tileCount = self.lastTilesByScreen[dd.screenID]?.count ?? 0
                            self.splitOverrides["\(dd.screenID)-\(tileCount)-\(dd.id)"] = f
                            self.tile(screen: scr, windows: self.collectWindows(on: scr))
                            if dd.vertical {
                                v.window?.setFrameOrigin(NSPoint(x: clamped - v.bounds.width / 2, y: v.window?.frame.minY ?? 0))
                            } else {
                                v.window?.setFrameOrigin(NSPoint(x: v.window?.frame.minX ?? 0, y: clamped - v.bounds.height / 2))
                            }
                        default:
                            self.draggingDividerID = nil
                            self.dragQuiet = false
                            self.refreshGrips()
                            log("split dragged: \(dd.id)")
                            self.refreshPanel()
                        }
                    }
                    let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.level = .floating
                    panel.backgroundColor = .clear
                    panel.hasShadow = false
                    panel.contentView = view
                    panel.orderFront(nil)
                    gripPanels[key] = panel
                }
            }
        }
        for (id, panel) in gripPanels where !seen.contains(id) {
            panel.orderOut(nil)
            gripPanels.removeValue(forKey: id)
        }
    }

    func hideGrips() {
        for (_, panel) in gripPanels { panel.orderOut(nil) }
        gripPanels.removeAll()
    }

    // MARK: - 提示条（约 2.5 秒后消失）

    var toastPanel: NSPanel?
    var toastWork: DispatchWorkItem?

    func showToast(_ title: String, detail: String? = nil, sticky: Bool = false, on screen: NSScreen? = nil) {
        toastWork?.cancel()
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 11)
        let titleW = (title as NSString).size(withAttributes: [.font: titleFont]).width
        let detailW = detail.map { ($0 as NSString).size(withAttributes: [.font: detailFont]).width } ?? 0
        let screen = screen ?? activeScreen()
        let maxW = screen.visibleFrame.width - 48
        let w = min(max(max(titleW, detailW) + 36, 160), maxW)
        let h: CGFloat = detail == nil ? 36 : 58
        let vf = screen.visibleFrame
        let rect = NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2 - 36, width: w, height: h)
        let ink = NSColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x1a / 255, alpha: 0.96)
        if let p = toastPanel {
            p.setFrame(rect, display: false)
            if let box = p.contentView {
                box.layer?.backgroundColor = ink.cgColor
                let labels = box.subviews.compactMap { $0 as? NSTextField }
                if let first = labels.first { first.stringValue = title; first.font = titleFont }
                if detail != nil {
                    if labels.count > 1 {
                        labels[1].stringValue = detail ?? ""
                        labels[1].isHidden = false
                    }
                } else if labels.count > 1 {
                    labels[1].stringValue = ""
                    labels[1].isHidden = true
                }
            }
        } else {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = ink.cgColor
            v.layer?.cornerRadius = 16
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = titleFont
            titleLabel.textColor = .white
            titleLabel.alignment = .center
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            let detailLabel = NSTextField(wrappingLabelWithString: detail ?? "")
            detailLabel.font = detailFont
            detailLabel.textColor = NSColor.white.withAlphaComponent(0.82)
            detailLabel.alignment = .center
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            detailLabel.isHidden = detail == nil
            v.addSubview(titleLabel)
            v.addSubview(detailLabel)
            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: detail == nil ? 9 : 8),
                titleLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
                titleLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
                detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
                detailLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
                detailLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            ])
            let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary]
            p.contentView = v
            toastPanel = p
        }
        toastPanel?.alphaValue = 0
        toastPanel?.orderFront(nil)
        toastPopStart = CACurrentMediaTime()
        startMotionTimer()
        guard !sticky else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.toastPanel else { return }
            self.fadeWindow(panel, to: 0, duration: 0.15) {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func hideToast() {
        toastWork?.cancel()
        toastWork = nil
        toastPanel?.orderOut(nil)
    }

    // MARK: - 堆叠握把（活动格子不画常驻圆点，操作从窗口上沿悬停条进入）

    func refreshDotHandles() {
        hideDotHandles()
    }

    func hideDotHandles() {
        for (_, p) in dotPanels { p.orderOut(nil) }
        dotPanels.removeAll()
    }

    final class StackMarkerView: NSView {
        var count = 0
        var topIndex = 0
        var onClick: (() -> Void)?
        override func draw(_ dirtyRect: NSRect) {
            guard count > 1 else { return }
            let h: CGFloat = 5
            let gap: CGFloat = 3
            var widths: [CGFloat] = []
            for i in 0..<count { widths.append(i == topIndex ? 16 : 8) }
            let total = widths.reduce(0, +) + gap * CGFloat(max(0, count - 1))
            var x = (bounds.width - total) / 2
            let y = (bounds.height - h) / 2
            for i in 0..<count {
                let w = widths[i]
                let alpha: CGFloat = i == topIndex ? 1 : 0.55
                NSColor.systemOrange.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
                x += w + gap
            }
        }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    func stackGripWidth(count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        return 16 + CGFloat(count - 1) * 8 + CGFloat(count - 1) * 3 + 10
    }

    func refreshStackMarkers() {
        guard AXIsProcessTrusted(), autoTile else {
            hideStackMarkers()
            return
        }
        var seen: Set<String> = []
        for (sid, tiles) in lastTilesByScreen where !tiles.isEmpty {
            for (i, t) in tiles.enumerated() where t.stack.count > 1 {
                let key = "\(sid):\(i)"
                seen.insert(key)
                let topIdx = min(stackTops[stackTopKey(sid, i)] ?? 0, t.stack.count - 1)
                let w = stackGripWidth(count: t.stack.count)
                var rect = NSRect(x: t.frame.midX - w / 2, y: t.frame.maxY + 4, width: w, height: 14)
                if let screen = NSScreen.screens.first(where: { screenID($0) == sid }), rect.maxY > screen.frame.maxY - 2 {
                    rect.origin.y = t.frame.maxY - 16
                }
                if let panel = stackMarkerPanels[key] {
                    panel.setFrame(rect, display: true)
                    if let view = panel.contentView as? StackMarkerView {
                        view.count = t.stack.count
                        view.topIndex = topIdx
                    }
                    panel.contentView?.needsDisplay = true
                } else {
                    let view = StackMarkerView(frame: NSRect(origin: .zero, size: rect.size))
                    view.count = t.stack.count
                    view.topIndex = topIdx
                    view.onClick = { [weak self] in
                        guard let self else { return }
                        self.cycleStackAt(sid: sid, tile: i, dir: 1)
                        self.refreshStackMarkers()
                        self.refreshPanel()
                    }
                    let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.level = .floating
                    panel.backgroundColor = .clear
                    panel.isOpaque = false
                    panel.hasShadow = false
                    panel.contentView = view
                    panel.orderFront(nil)
                    stackMarkerPanels[key] = panel
                }
            }
        }
        for (k, p) in stackMarkerPanels where !seen.contains(k) {
            p.orderOut(nil)
            stackMarkerPanels.removeValue(forKey: k)
        }
    }

    func hideStackMarkers() {
        for (_, p) in stackMarkerPanels { p.orderOut(nil) }
        stackMarkerPanels.removeAll()
    }

    func showStackPanel(sid: CGDirectDisplayID, tile: Int) {
        guard let tiles = lastTilesByScreen[sid], tile < tiles.count else { return }
        let stack = tiles[tile].stack
        guard stack.count > 1 else { return }
        let frame = tiles[tile].frame
        closeStackPanel()
        stackPanelSid = sid
        stackPanelTile = tile
        let cur = min(stackTops[stackTopKey(sid, tile)] ?? 0, stack.count - 1)
        let doc = NSStackView()
        doc.orientation = .vertical
        doc.spacing = 6
        doc.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.widthAnchor.constraint(equalToConstant: 284).isActive = true
        let arrowRow = NSStackView()
        arrowRow.orientation = .horizontal
        arrowRow.spacing = 8
        let prevBtn = NSButton(title: "‹ 上一个", target: self, action: #selector(stackPanelPrev(_:)))
        let nextBtn = NSButton(title: "下一个 ›", target: self, action: #selector(stackPanelNext(_:)))
        prevBtn.bezelStyle = .inline
        nextBtn.bezelStyle = .inline
        arrowRow.addArrangedSubview(prevBtn)
        arrowRow.addArrangedSubview(nextBtn)
        doc.addArrangedSubview(arrowRow)
        for (idx, w) in stack.enumerated() {
            let b = NSButton(title: "\(w.appName) — \(w.title)", target: self, action: #selector(stackPanelPick(_:)))
            b.tag = idx
            b.image = NSRunningApplication(processIdentifier: w.pid)?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            b.imagePosition = .imageLeft
            b.bezelStyle = .rounded
            b.wantsLayer = true
            if idx == cur {
                b.layer?.borderColor = NSColor.systemOrange.cgColor
                b.layer?.borderWidth = 2
                b.layer?.cornerRadius = 6
            }
            doc.addArrangedSubview(b)
        }
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        bg.layer?.cornerRadius = 10
        bg.addSubview(doc)
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            doc.topAnchor.constraint(equalTo: bg.topAnchor),
            doc.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = bg
        panel.layoutIfNeeded()
        let h = doc.fittingSize.height
        let vf = NSScreen.screens.first(where: { screenID($0) == sid })?.visibleFrame ?? frame
        var x = frame.midX - 150
        x = min(max(x, vf.minX + 4), vf.maxX - 304)
        var y = frame.maxY - 24 - h
        if y < vf.minY + 4 { y = frame.maxY + 4 }
        panel.setFrame(NSRect(x: x, y: y, width: 300, height: h), display: true)
        panel.orderFront(nil)
        stackPanel = panel
    }

    func closeStackPanel() {
        stackPanel?.orderOut(nil)
        stackPanel = nil
    }

    func cycleStackAt(sid: CGDirectDisplayID, tile: Int, dir: Int) {
        guard let tiles = lastTilesByScreen[sid], tile < tiles.count else { return }
        let stack = tiles[tile].stack
        guard stack.count > 1 else { return }
        let key = stackTopKey(sid, tile)
        let cur = stackTops[key] ?? 0
        let next = (cur + dir + stack.count) % stack.count
        stackTops[key] = next
        let w = stack[next]
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: w.pid) { app.activate() }
        log("stack panel cycle tile=\(tile) -> \(w.appName)")
    }

    @objc func stackPanelPrev(_ sender: NSButton) {
        cycleStackAt(sid: stackPanelSid, tile: stackPanelTile, dir: -1)
        showStackPanel(sid: stackPanelSid, tile: stackPanelTile)
    }

    @objc func stackPanelNext(_ sender: NSButton) {
        cycleStackAt(sid: stackPanelSid, tile: stackPanelTile, dir: 1)
        showStackPanel(sid: stackPanelSid, tile: stackPanelTile)
    }

    @objc func stackPanelPick(_ sender: NSButton) {
        let idx = sender.tag
        if let tiles = lastTilesByScreen[stackPanelSid], stackPanelTile < tiles.count,
           idx < tiles[stackPanelTile].stack.count {
            let w = tiles[stackPanelTile].stack[idx]
            stackTops[stackTopKey(stackPanelSid, stackPanelTile)] = idx
            AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
            if let app = NSRunningApplication(processIdentifier: w.pid) { app.activate() }
        }
        closeStackPanel()
        forceTile()
    }

    // MARK: - 悬停条（格子上沿停留约 0.22 秒出现）
    // Primary / Focus / Float 只有文字。
    // 橙色堆叠标记保留。悬停条是直接挑窗口的入口，两者共存：条放在标记上方；
    // 顶行格子放不下时改放格子内、标记下方，不盖住标记。

    var hoverBarView: NSView!
    var hoverSid: CGDirectDisplayID = 0
    var hoverTile: Int = 0
    // 悬停条种类：0 普通格子条，1 专注条（仅 Focus），2 悬浮条（Tile + disabled 的 Primary/Focus）。
    var hoverBarKind: Int = 0
    var hoverFloatElement: AXUIElement? = nil  // 悬浮条目标窗口（keep-alive 用 live 帧，窗口可被拖动）
    var hoverZoneID: String?
    var hoverZoneSince: CFTimeInterval = 0

    func setupHoverBar() {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x1a / 255, alpha: 0.96).cgColor
        pill.layer?.cornerRadius = 12
        hoverBarView = pill
        hoverPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 34), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hoverPanel.level = .floating
        hoverPanel.backgroundColor = .clear
        hoverPanel.isOpaque = false
        hoverPanel.hasShadow = true
        pill.frame = NSRect(origin: .zero, size: hoverPanel.frame.size)
        pill.autoresizingMask = [.width, .height]
        hoverPanel.contentView = pill
    }

    func hoverChip(_ title: String, tag: Int, action: Selector, emphasized: Bool, enabled: Bool = true) -> NSButton {
        let font = NSFont.systemFont(ofSize: 11, weight: emphasized ? .semibold : .regular)
        let b = NSButton(title: title, target: self, action: action)
        b.tag = tag
        b.font = font
        b.isBordered = false
        b.bezelStyle = .inline
        b.isEnabled = enabled
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: enabled ? NSColor.white : NSColor.white.withAlphaComponent(0.35),
            .font: font,
        ])
        b.wantsLayer = true
        if emphasized {
            b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
            b.layer?.cornerRadius = 6
        }
        return b
    }

    func showHoverBar(for tile: (stack: [WinInfo], frame: CGRect, top: WinInfo), screen: NSScreen, sid: CGDirectDisplayID, tileIndex: Int) {
        guard hoverPanel != nil else { return }
        hoverSid = sid
        hoverTile = tileIndex
        hoverBarKind = 0
        let topIdx = min(stackTops[stackTopKey(sid, tileIndex)] ?? 0, tile.stack.count - 1)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        if tile.stack.count > 1 {
            row.addArrangedSubview(hoverChip("‹", tag: 0, action: #selector(hoverStackStep(_:)), emphasized: false))
            for (idx, w) in tile.stack.enumerated() {
                row.addArrangedSubview(hoverChip(w.appName, tag: idx, action: #selector(hoverPickStack(_:)), emphasized: idx == topIdx))
            }
            row.addArrangedSubview(hoverChip("›", tag: 1, action: #selector(hoverStackStep(_:)), emphasized: false))
        }
        // 三个按钮只有文字。
        // Primary：已是 tile0 顶部时 disabled（tileIndex == 0 即被点窗口就是 tile0 顶部）。
        row.addArrangedSubview(hoverChip("Primary", tag: 0, action: #selector(hoverPrimary(_:)), emphasized: false, enabled: tileIndex != 0))
        row.addArrangedSubview(hoverChip("Focus", tag: 0, action: #selector(hoverFocus(_:)), emphasized: false))
        row.addArrangedSubview(hoverChip("Float", tag: 0, action: #selector(hoverFloat(_:)), emphasized: false))
        let pill = hoverBarView ?? NSView()
        for v in pill.subviews { v.removeFromSuperview() }
        pill.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: pill.topAnchor),
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])
        pill.layoutSubtreeIfNeeded()
        let fit = row.fittingSize
        let barW = min(max(fit.width, 180), screen.visibleFrame.width - 16)
        let barH = max(fit.height, 32)
        let vf = screen.visibleFrame
        var x = tile.frame.midX - barW / 2
        x = min(max(x, vf.minX + 4), vf.maxX - barW - 4)
        // 条放橙色标记上方 4pt（标记在格子上沿外 4..18）；顶行格子放不下时
        // 改放格子内、标记下方 4pt（顶行标记在格子内上沿下 2..16，条顶贴到下沿 20 处）。
        var y = tile.frame.maxY + 22
        if y + barH > screen.frame.maxY - 2 { y = tile.frame.maxY - barH - 20 }
        hoverPanel.setFrame(NSRect(x: x, y: y, width: barW, height: barH), display: true)
        hoverPanel.orderFront(nil)
        hoverKey = winKey(tile.stack[topIdx])
        hoverTileFrame = tile.frame
    }

    func hideHoverBar() {
        hoverPanel?.orderOut(nil)
        hoverKey = nil
        hoverBarKind = 0
        hoverFloatElement = nil
    }

    // 手动 Float：窗口移到所在屏可视区中央（保持当前尺寸居中，不留在原地），其余窗口立即重排填空位。
    // 专注窗口被浮动时用进入 Focus 前保存的尺寸（避免全屏尺寸居中后仍盖住全部格子），
    // 并清掉 Focus 状态（不恢复——窗口是被浮动，不是退出还原）。
    func floatWindow(_ w: WinInfo, source: String) {
        let key = winKey(w)
        guard !floatedKeys.contains(key) else { return }
        let screen = screenForFrame(w.frame)
        let vf = screen.visibleFrame
        var size = getSize(w.element) ?? w.frame.size
        if key == focusKey, let saved = focusSavedFrames?[key] {
            size = saved.size
        }
        if key == focusKey {
            focusKey = nil
            focusScreen = nil
            focusSavedFrames = nil
            focusSavedTops = nil
            focusSavedActive = nil
            log("focus off: floated")
        }
        floatedKeys.insert(key)
        let cw = min(size.width, vf.width - 16), ch = min(size.height, vf.height - 16)
        let frame = CGRect(x: vf.midX - cw / 2, y: vf.midY - ch / 2, width: cw, height: ch)
        placeFrame(w.element, frame, key: key, animated: true)
        lastPlacedFrames[key] = frame
        log("\(source) float -> \(w.appName) centered")
        forceTile()
        refreshPanel()
    }

    // 悬浮窗口最小悬停条：Tile（点按重新进入平铺并重算，不是精确恢复）+ disabled 的 Primary/Focus。
    func showFloatedHoverBar(screen: NSScreen, floated: WinInfo) {
        guard hoverPanel != nil else { return }
        hoverSid = screenID(screen)
        hoverTile = -1
        hoverBarKind = 2
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(hoverChip("Tile", tag: 0, action: #selector(hoverTileBack(_:)), emphasized: false))
        row.addArrangedSubview(hoverChip("Primary", tag: 0, action: #selector(hoverPrimary(_:)), emphasized: false, enabled: false))
        row.addArrangedSubview(hoverChip("Focus", tag: 0, action: #selector(hoverFocus(_:)), emphasized: false, enabled: false))
        let pill = hoverBarView ?? NSView()
        for v in pill.subviews { v.removeFromSuperview() }
        pill.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: pill.topAnchor),
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])
        pill.layoutSubtreeIfNeeded()
        let fit = row.fittingSize
        let vf = screen.visibleFrame
        let barW = min(max(fit.width, 180), vf.width - 16)
        let barH = max(fit.height, 32)
        let frame = floated.frame
        var x = frame.midX - barW / 2
        x = min(max(x, vf.minX + 4), vf.maxX - barW - 4)
        var y = frame.maxY + 22
        if y + barH > screen.frame.maxY - 2 { y = frame.maxY - barH - 20 }
        hoverPanel.setFrame(NSRect(x: x, y: y, width: barW, height: barH), display: true)
        hoverPanel.orderFront(nil)
        hoverKey = winKey(floated)
        hoverTileFrame = frame
        hoverFloatElement = floated.element
    }

    @objc func hoverTileBack(_ sender: NSButton) {
        // 悬浮窗口重新进入平铺：按当前布局重算，不是精确恢复。
        guard let w = resolveHoverTarget() else { return }
        let key = winKey(w)
        guard floatedKeys.contains(key) else { return }
        floatedKeys.remove(key)
        hideHoverBar()
        forceTile()
        refreshPanel()
        log("hover tile back -> \(w.appName)")
    }

    // 专注模式最小悬停条：只放一个 Focus，用来退出。
    // 专注窗口铺满可视区、上方无缝隙，条放上沿内侧。
    func showFocusHoverBar(screen: NSScreen, focusKey fk: String) {
        guard hoverPanel != nil else { return }
        hoverSid = screenID(screen)
        hoverTile = -1
        hoverBarKind = 1
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(hoverChip("Focus", tag: 0, action: #selector(hoverFocus(_:)), emphasized: false))
        let pill = hoverBarView ?? NSView()
        for v in pill.subviews { v.removeFromSuperview() }
        pill.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: pill.topAnchor),
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])
        pill.layoutSubtreeIfNeeded()
        let fit = row.fittingSize
        let vf = screen.visibleFrame
        let barW = min(max(fit.width, 180), vf.width - 16)
        let barH = max(fit.height, 32)
        let x = min(max(vf.midX - barW / 2, vf.minX + 4), vf.maxX - barW - 4)
        let y = vf.maxY - barH - 4
        hoverPanel.setFrame(NSRect(x: x, y: y, width: barW, height: barH), display: true)
        hoverPanel.orderFront(nil)
        hoverKey = fk
        hoverTileFrame = vf
    }

    func tileUnderPointer(_ m: CGPoint) -> (sid: CGDirectDisplayID, index: Int, tile: (stack: [WinInfo], frame: CGRect, top: WinInfo), screen: NSScreen)? {
        // 上沿热区：格子顶部上下各伸一点；多块同时命中时取离自己上沿最近的那块。
        // 只做热区命中，不做 Hover focus 的窗体命中。
        var best: (sid: CGDirectDisplayID, index: Int, tile: (stack: [WinInfo], frame: CGRect, top: WinInfo), screen: NSScreen)?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (sid, tiles) in lastTilesByScreen {
            guard let screen = NSScreen.screens.first(where: { screenID($0) == sid }) else { continue }
            for (i, t) in tiles.enumerated() {
                let zone = CGRect(x: t.frame.minX, y: t.frame.maxY - 20, width: t.frame.width, height: 36)
                guard zone.contains(m) else { continue }
                let score = abs(m.y - t.frame.maxY)
                if score < bestScore { bestScore = score; best = (sid, i, t, screen) }
            }
        }
        return best
    }

    func updateHover() {
        let m = NSEvent.mouseLocation
        guard AXIsProcessTrusted(), autoTile, draggingDividerID == nil, dragState == nil, pendingDrag == nil else {
            hideHoverBar()
            hoverZoneID = nil
            return
        }
        // Focus 期间：只在专注窗口上沿出现仅含 Focus 的最小条（用于退出），
        // 不走普通格子条（该状态下 Primary/Float 不出现）；专注窗口帧即所在屏可视区，无需读 AX。
        if let fk = focusKey, let fsid = focusScreen,
           let screen = NSScreen.screens.first(where: { screenID($0) == fsid }) {
            let vf = screen.visibleFrame
            let zone = CGRect(x: vf.minX, y: vf.maxY - 20, width: vf.width, height: 36)
            let barFrame = (hoverPanel?.frame ?? .zero).insetBy(dx: -8, dy: -8)
            if zone.contains(m) || (hoverBarKind == 1 && hoverKey != nil && barFrame.contains(m)) {
                if hoverBarKind != 1 || hoverKey == nil {
                    showFocusHoverBar(screen: screen, focusKey: fk)
                }
                return
            }
            hideHoverBar()
            hoverZoneID = nil
            return
        }
        if hoverKey != nil {
            let barFrame = (hoverPanel?.frame ?? .zero).insetBy(dx: -8, dy: -8)
            if barFrame.contains(m) { return }
            // 悬浮条：指针仍在悬浮窗口上沿（live 帧，窗口可被拖动）才保留。
            if hoverBarKind == 2 {
                if let el = hoverFloatElement, let f = getFrame(el, screenHeight: mainHeight()) {
                    let zone = CGRect(x: f.minX, y: f.maxY - 20, width: f.width, height: 36)
                    if zone.contains(m) { return }
                }
                hideHoverBar()
                hoverZoneID = nil
                return
            }
            let stillOnTile = tileUnderPointer(m).map { "\($0.sid):\($0.index)" } == "\(hoverSid):\(hoverTile)"
            if stillOnTile { return }
            hideHoverBar()
            hoverZoneID = nil
            return
        }
        guard let hit = tileUnderPointer(m) else {
            // 无格子命中时试悬浮窗口：仅 floatedKeys 非空才枚举（避免每 0.12s 全量 AX 开销），
            // 命中后同样 0.22s 停留才出条。
            if !floatedKeys.isEmpty,
               let fw = collectWindows(includeFloated: true).first(where: {
                   floatedKeys.contains(winKey($0)) &&
                   CGRect(x: $0.frame.minX, y: $0.frame.maxY - 20, width: $0.frame.width, height: 36).contains(m)
               }) {
                let id = "float:\(winKey(fw))"
                if hoverZoneID != id {
                    hoverZoneID = id
                    hoverZoneSince = CACurrentMediaTime()
                    return
                }
                guard CACurrentMediaTime() - hoverZoneSince >= 0.22 else { return }
                if let screen = NSScreen.screens.first(where: { screenID($0) == screenID(screenForFrame(fw.frame)) }) {
                    showFloatedHoverBar(screen: screen, floated: fw)
                }
            } else {
                hoverZoneID = nil
            }
            return
        }
        let id = "\(hit.sid):\(hit.index)"
        if hoverZoneID != id {
            hoverZoneID = id
            hoverZoneSince = CACurrentMediaTime()
            return
        }
        guard CACurrentMediaTime() - hoverZoneSince >= 0.22 else { return }
        showHoverBar(for: hit.tile, screen: hit.screen, sid: hit.sid, tileIndex: hit.index)
    }

    @objc func hoverStackStep(_ sender: NSButton) {
        let dir = sender.tag == 0 ? -1 : 1
        cycleStackAt(sid: hoverSid, tile: hoverTile, dir: dir)
        refreshStackMarkers()
        if let tiles = lastTilesByScreen[hoverSid], hoverTile < tiles.count,
           let screen = NSScreen.screens.first(where: { screenID($0) == hoverSid }) {
            showHoverBar(for: tiles[hoverTile], screen: screen, sid: hoverSid, tileIndex: hoverTile)
        }
    }

    @objc func hoverPickStack(_ sender: NSButton) {
        let idx = sender.tag
        guard let tiles = lastTilesByScreen[hoverSid], hoverTile < tiles.count,
              idx >= 0, idx < tiles[hoverTile].stack.count else { return }
        let w = tiles[hoverTile].stack[idx]
        stackTops[stackTopKey(hoverSid, hoverTile)] = idx
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        refreshStackMarkers()
        if let screen = NSScreen.screens.first(where: { screenID($0) == hoverSid }),
           let fresh = lastTilesByScreen[hoverSid], hoverTile < fresh.count {
            showHoverBar(for: fresh[hoverTile], screen: screen, sid: hoverSid, tileIndex: hoverTile)
        }
    }

    // 悬停条点击时按 pid+标题重找窗口；找不到了就收条并记日志，不对错窗口动手。
    // 用 includeFloated 找：Float 按钮的关（恢复平铺）也要能找到已浮动的窗口。
    func resolveHoverTarget() -> WinInfo? {
        guard let key = hoverKey else { return nil }
        let windows = collectWindows(includeFloated: true)
        guard let w = windows.first(where: { winKey($0) == key }) else {
            hideHoverBar()
            log("hover target gone")
            return nil
        }
        return w
    }

    @objc func hoverPrimary(_ sender: NSButton) {
        // Primary 交换：被点窗口与 tile0 顶部互换格子（被点窗口进 tile0 并成为其顶部，
        // 被换出的 tile0 顶部进被点窗口原格子、接替其栈位，尺寸随格子变）。
        // 已是 tile0 顶部时按钮 disabled（守卫）；悬浮窗口不可 Primary（守卫）。
        guard let w = resolveHoverTarget() else { return }
        guard hoverTile != 0 else { return }
        let key = winKey(w)
        guard !floatedKeys.contains(key) else { return }
        guard let tiles = lastTilesByScreen[hoverSid], hoverTile < tiles.count, !tiles[0].stack.isEmpty else { return }
        // 先 raise 被换出的 tile0 顶部，forceTile 后再 raise 被点窗口并激活，使其视觉置顶。
        let top0 = tiles[0].stack[min(stackTops[stackTopKey(hoverSid, 0)] ?? 0, tiles[0].stack.count - 1)]
        AXUIElementPerformAction(top0.element, kAXRaiseAction as CFString)
        primaryKeysByScreen[hoverSid] = key
        hideHoverBar()
        forceTile()
        lastActiveTileByScreen[hoverSid] = 0
        refreshDimLayers()
        refreshHighlights()
        refreshStackMarkers()
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: w.pid) { app.activate() }
        refreshPanel()
        log("primary swap -> \(w.appName)")
    }

    @objc func hoverFocus(_ sender: NSButton) {
        if focusKey != nil {
            exitFocus()
            hideHoverBar()
        } else {
            guard let w = resolveHoverTarget() else { return }
            enableFocus(targetKey: winKey(w))
            hideHoverBar()
        }
        refreshPanel()
    }

    @objc func hoverFloat(_ sender: NSButton) {
        // 手动 Float：写入 floatedKeys。悬停条上的按钮只走这一条。
        guard let w = resolveHoverTarget() else { return }
        let key = winKey(w)
        if floatedKeys.contains(key) {
            floatedKeys.remove(key)
            log("hover float off -> \(w.appName) back to tiling")
            hideHoverBar()
            forceTile()
            refreshPanel()
        } else {
            hideHoverBar()
            floatWindow(w, source: "hover")
        }
    }

    // MARK: - 主窗口高亮 + 其他窗口变暗（固定值，不设开关）
    // 旧实现取自 origin/main（3de92674）refreshHighlights/refreshDimLayers，
    // 最小化：高亮只取 Accent 色 3pt 边框、只描活动格子（复用现存 HighlightBorderView，
    // 描边居中落在间隙里）；变暗只取纯黑 0.5，不做强度分档与 Blur；
    // 两者都不加面板开关与设置入口，固定开启。
    // 守卫沿用旧逻辑：未授权或 autoTile 关时不显示；Focus 盖住时按旧规则跳过。

    var dimPanels: [String: NSPanel] = [:]
    var highlightPanels: [String: NSPanel] = [:]

    func dimContent() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        return v
    }

    func refreshDimLayers() {
        guard AXIsProcessTrusted(), autoTile, focusKey == nil else {
            removeDimLayers()
            return
        }
        var seen: Set<String> = []
        for (sid, tiles) in lastTilesByScreen where !tiles.isEmpty {
            let active = min(lastActiveTileByScreen[sid] ?? 0, tiles.count - 1)
            for (i, t) in tiles.enumerated() where i != active {
                let key = "\(sid):\(i)"
                seen.insert(key)
                if let p = dimPanels[key] {
                    if p.frame != t.frame { p.setFrame(t.frame, display: true) }
                    if !p.isVisible { p.orderFront(nil) }
                } else {
                    let p = NSPanel(contentRect: t.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    p.level = .floating
                    p.backgroundColor = .clear
                    p.hasShadow = false
                    p.ignoresMouseEvents = true
                    p.contentView = dimContent()
                    p.orderFront(nil)
                    dimPanels[key] = p
                }
            }
        }
        for (k, p) in dimPanels where !seen.contains(k) {
            p.orderOut(nil)
            dimPanels.removeValue(forKey: k)
        }
    }

    func removeDimLayers() {
        for (_, p) in dimPanels { p.orderOut(nil) }
        dimPanels.removeAll()
    }

    func refreshHighlights() {
        guard AXIsProcessTrusted(), autoTile, focusKey == nil else {
            hideHighlights()
            return
        }
        var wanted: [String: CGRect] = [:]
        for (sid, tiles) in lastTilesByScreen where !tiles.isEmpty {
            let active = min(lastActiveTileByScreen[sid] ?? 0, tiles.count - 1)
            // 固定：只描活动格子，Accent 色，3pt；边框面板比格子每边大 3，描边居中落在间隙里。
            wanted["\(sid):\(active)"] = tiles[active].frame.insetBy(dx: -3, dy: -3)
        }
        for (i, frame) in wanted {
            if let p = highlightPanels[i] {
                if p.frame != frame { p.setFrame(frame, display: true) }
                if let v = p.contentView as? HighlightBorderView {
                    v.strokeColor = .controlAccentColor
                    v.thickness = 3
                    v.glow = false
                    v.needsDisplay = true
                }
                if !p.isVisible { p.orderFront(nil) }
            } else {
                let view = HighlightBorderView(frame: NSRect(origin: .zero, size: frame.size))
                view.strokeColor = .controlAccentColor
                view.thickness = 3
                view.glow = false
                let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                p.level = .floating
                p.backgroundColor = .clear
                p.hasShadow = false
                p.ignoresMouseEvents = true
                p.contentView = view
                p.orderFront(nil)
                highlightPanels[i] = p
            }
        }
        for (k, p) in highlightPanels where wanted[k] == nil {
            p.orderOut(nil)
            highlightPanels.removeValue(forKey: k)
        }
    }

    func hideHighlights() {
        for (_, p) in highlightPanels { p.orderOut(nil) }
        highlightPanels.removeAll()
    }

    // MARK: - Focus 模式
    // 盖住式最小行为：聚焦窗口铺满所在屏可视区盖住其他窗口，其余窗口不动；
    // 再点一次 Focus 按钮或 Retile 即退出并 forceTile 恢复平铺。
    // 其余窗口留在原处。退出时按进入前的快照还原；窗口集合变了就先还原还在的，再重排。

    var focusKey: String? = nil
    var focusScreen: CGDirectDisplayID? = nil
    // Focus 进入前快照：本屏各窗口精确帧、格子栈顶下标、活动格；退出精确还原用。
    var focusSavedFrames: [String: CGRect]? = nil
    var focusSavedTops: [String: Int]? = nil
    var focusSavedActive: Int? = nil

    func enableFocus(targetKey: String) {
        guard AXIsProcessTrusted() else { log("focus skipped: not trusted"); return }
        let all = collectWindows()
        guard let w = all.first(where: { winKey($0) == targetKey }) else {
            log("focus skipped: target window gone"); return
        }
        let screen = screenForFrame(w.frame)
        let sid = screenID(screen)
        // 进入前快照：本屏各窗口精确帧、格子栈顶、活动格；退出时精确还原用。
        // 其他屏不受 Focus 影响，不快照。
        let screenWindows = collectWindows(on: screen)
        focusSavedFrames = Dictionary(uniqueKeysWithValues: screenWindows.map { (winKey($0), $0.frame) })
        focusSavedTops = stackTops.filter { $0.key.hasPrefix("\(sid):") }
        focusSavedActive = lastActiveTileByScreen[sid]
        focusKey = targetKey
        focusScreen = sid
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: w.pid) { app.activate() }
        placeFrame(w.element, screen.visibleFrame, key: targetKey, animated: true)
        lastPlacedFrames[targetKey] = screen.visibleFrame
        hideGrips()
        hideHoverBar()
        hideDotHandles()
        hideStackMarkers()
        hideHighlights()
        removeDimLayers()
        closeStackPanel()
        showToast("Focus", detail: "Hover the top edge and click Focus to put it back.", on: screen)
        log("focus on: \(w.appName)")
    }

    // 只清状态不恢复（Retile 退出、目标消失等走重算的路径用）。
    func disableFocus() {
        focusKey = nil
        focusScreen = nil
        focusSavedFrames = nil
        focusSavedTops = nil
        focusSavedActive = nil
        log("focus off")
    }

    // Focus 退出：窗口集合与进入时一致则精确恢复保存的帧（不 forceTile 重算）；
    // 集合变了则幸存者先回保存帧，再 forceTile 收尾新集合。
    func exitFocus() {
        guard let fk = focusKey, let fsid = focusScreen else { return }
        let savedFrames = focusSavedFrames
        let savedTops = focusSavedTops
        let savedActive = focusSavedActive
        focusKey = nil
        focusScreen = nil
        focusSavedFrames = nil
        focusSavedTops = nil
        focusSavedActive = nil
        guard let savedFrames, let screen = NSScreen.screens.first(where: { screenID($0) == fsid }) else {
            log("focus off: no snapshot, retile")
            forceTile()
            return
        }
        let current = collectWindows(on: screen)
        let currentKeys = Set(current.map { winKey($0) })
        if currentKeys == Set(savedFrames.keys) {
            // 精确恢复：只有专注窗口动过（铺满），把它放回保存帧；其余窗口 Focus 期间没动过。
            if let fw = current.first(where: { winKey($0) == fk }), let frame = savedFrames[fk] {
                placeFrame(fw.element, frame, key: fk, animated: true)
                lastPlacedFrames[fk] = frame
                AXUIElementPerformAction(fw.element, kAXRaiseAction as CFString)
                if let app = NSRunningApplication(processIdentifier: fw.pid) { app.activate() }
            }
            if let savedTops { for (k, v) in savedTops { stackTops[k] = v } }
            if let savedActive { lastActiveTileByScreen[fsid] = savedActive }
            refreshGrips()
            refreshDimLayers()
            refreshHighlights()
            refreshDotHandles()
            refreshStackMarkers()
            log("focus off: exact restore")
        } else {
            for w in current {
                if let frame = savedFrames[winKey(w)] {
                    placeFrame(w.element, frame, key: winKey(w), animated: false)
                    lastPlacedFrames[winKey(w)] = frame
                }
            }
            log("focus off: set changed, restore survivors + retile")
            forceTile()
        }
    }



    // MARK: - 悬停条状态



    // MARK: - v9 高亮系统（自有穿透悬浮窗，画在间隙里，不遮窗口内容）




    /// 停在所有屏幕包围盒的下方，竖着叠两块屏时也不会落到下面那块上。







    // MARK: - 鼠标重排（会话事件 tap，只订阅鼠标）

    /// 创建过滤型事件 tap，识别按住 ⌘ / ⌃⌘ 的窗口拖动。
    /// 掩码只有左键按下、拖动、松开。
    /// 创建失败只记一次。辅助功能稍后变为已允许时，tick 会再试。
    func setupMouseDragTap() {
        guard !tapRunning else { return }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: mouseDragTapCallback,
                                          userInfo: nil) else {
            tapRunning = false
            if !mouseTapFailedLogged {
                mouseTapFailedLogged = true
                log("mouse drag tap unavailable; command-drag swap stays off until the session event tap can be created")
            }
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        tapSource = src
        tapRunning = true
        mouseTapFailedLogged = false
        log("mouse drag tap running")
    }

    // MARK: - D 批 ⌘拖交换 / ⌃⌘拖进堆叠

    // CGEvent 是 Quartz 全局坐标：原点在主显示器（screens[0]，菜单栏所在屏）左上角，y 向下。
    // Cocoa 全局坐标 y 向上，主屏顶边是 screens[0].frame.maxY。
    // 不用 NSScreen.main：那是关键窗口所在屏，副屏上会把命中点算偏。
    func cocoaPoint(fromQuartz q: CGPoint) -> CGPoint? {
        guard let primary = NSScreen.screens.first else { return nil }
        return CGPoint(x: q.x, y: primary.frame.maxY - q.y)
    }

    // 拖动起点是否落在我们自己的交互窗上（面板、悬停条、分隔缝、握把）；
    // 暗色层与高亮层是穿透视觉层，不算交互窗，落在它们上面仍视为落在下方磁贴上
    func pointOnOwnInteractiveWindow(_ p: CGPoint) -> Bool {
        if panelPopover.isShown,
           let w = panelPopover.contentViewController?.view.window, w.frame.contains(p) { return true }
        if hoverPanel.isVisible, hoverPanel.frame.contains(p) { return true }
        for (_, g) in gripPanels where g.isVisible && g.frame.contains(p) { return true }
        for (_, d) in dotPanels where d.isVisible && d.frame.contains(p) { return true }
        for (_, m) in stackMarkerPanels where m.isVisible && m.frame.contains(p) { return true }
        if let sp = stackPanel, sp.isVisible, sp.frame.contains(p) { return true }
        return false
    }

    // mouseDown：⌘ 按下且落在某磁贴上 → 只记录待定拖动，不吞这次按下；
    // 只有鼠标实际移动超过约 3pt 才进入拖动模式，未拖动时按下/松手原样放行
    func dragMouseDown(_ event: CGEvent) -> Bool {
        guard AXIsProcessTrusted(), autoTile else { return false }
        let flags = event.flags
        guard flags.contains(.maskCommand) else { return false }
        let p = cocoaPoint(fromQuartz: event.location) ?? event.location
        guard !pointOnOwnInteractiveWindow(p) else { return false }
        // C 批：拖动只在鼠标所在屏的磁贴上进行
        let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let sid = screenID(screen)
        let windows = collectWindows(on: screen)
        guard !windows.isEmpty else { return false }
        let (stacks, _) = computeTiles(windows: windows, st: settingsFor(screen), sid: sid)
        guard stacks.count > 1 else { return false }
        let vf = screen.visibleFrame
        let frames = applySplitOverrides(frames: tileFrames(count: stacks.count, vf: vf), tileCount: stacks.count, vf: vf, sid: sid)
        guard let src = frames.firstIndex(where: { $0.contains(p) }) else { return false }
        // ⌘ 交换；再按住 ⌃ 则加入堆叠。只认 control 与 command。
        let mode: DragMode = flags.contains(.maskControl) ? .stack : .swap
        // 当前栈顶（不用 stacks[].first，也不依赖可能滞后的 lastTilesByScreen）
        let top = stacks[src][min(stackTops[stackTopKey(sid, src)] ?? 0, stacks[src].count - 1)]
        pendingDrag = DragState(mode: mode, sourceTile: src, draggedKey: winKey(top), frames: frames, screenID: sid)
        pendingDragPoint = p
        return false
    }

    // 拖动中：待定拖动移动超 3pt 才转正并开始吞事件；转正后只更新目标磁贴与目标圈
    func dragMouseDragged(_ event: CGEvent) -> Bool {
        let p = cocoaPoint(fromQuartz: event.location) ?? event.location
        if dragState == nil, let pd = pendingDrag {
            let dx = p.x - pendingDragPoint.x, dy = p.y - pendingDragPoint.y
            guard dx * dx + dy * dy > 9 else { return false }
            pendingDrag = nil
            dragState = pd
            dragQuiet = true
            log("drag start mode=\(pd.mode == .swap ? "swap" : "stack") tile=\(pd.sourceTile)")
        }
        guard var d = dragState else { return false }
        let target = d.frames.firstIndex(where: { $0.contains(p) })
        if target != d.targetTile {
            d.targetTile = target
            dragState = d
            if let t = target, t != d.sourceTile {
                showDragRing(frame: d.frames[t])
            } else {
                hideDragRing()
            }
        }
        return true
    }

    // 松手：拖动模式中落在另一磁贴上执行交换或进堆叠，否则取消并吞掉这次松手；
    // 未进入拖动模式（⌘单击）时原样放行
    func dragMouseUp(_ event: CGEvent) -> Bool {
        guard let d = dragState else {
            pendingDrag = nil
            return false
        }
        dragState = nil
        dragQuiet = false
        hideDragRing()
        let p = cocoaPoint(fromQuartz: event.location) ?? event.location
        guard let target = d.frames.firstIndex(where: { $0.contains(p) }), target != d.sourceTile else {
            log("drag cancelled")
            return true
        }
        if d.mode == .swap { performDragSwap(from: d.sourceTile, to: target, screenID: d.screenID, draggedKey: d.draggedKey) }
        else { performDragStack(draggedKey: d.draggedKey, to: target, screenID: d.screenID) }
        return true
    }

    func dragCancel() {
        dragState = nil
        pendingDrag = nil
        dragQuiet = false
        hideDragRing()
    }

    // 拖动目标圈：复用高亮边框视图，画在目标磁贴的间隙里
    func showDragRing(frame: CGRect) {
        let f = frame.insetBy(dx: -3, dy: -3)
        if let p = dragRingPanel {
            if p.frame != f { p.setFrame(f, display: true) }
            if !p.isVisible { p.orderFront(nil) }
            return
        }
        let view = HighlightBorderView(frame: NSRect(origin: .zero, size: f.size))
        view.strokeColor = .controlAccentColor
        view.thickness = 3
        view.glow = false
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.contentView = view
        p.orderFront(nil)
        dragRingPanel = p
    }

    func hideDragRing() {
        dragRingPanel?.orderOut(nil)
    }

    // 拖动交换：对调两扇窗口。堆在同一磁贴里的其余窗口留在原磁贴，改跟新来的那扇。
    func performDragSwap(from src: Int, to dst: Int, screenID sid: CGDirectDisplayID, draggedKey: String) {
        guard AXIsProcessTrusted() else { return }
        let screen = NSScreen.screens.first(where: { screenID($0) == sid }) ?? NSScreen.main ?? NSScreen.screens[0]
        let windows = collectWindows(on: screen)
        guard !windows.isEmpty else { return }
        let (stacks, _) = computeTiles(windows: windows, st: settingsFor(screen), sid: sid)
        guard src < stacks.count, dst < stacks.count else { return }
        let topA: WinInfo
        if let w = windows.first(where: { winKey($0) == draggedKey }) { topA = w }
        else { topA = stacks[src][min(stackTops[stackTopKey(sid, src)] ?? 0, stacks[src].count - 1)] }
        let topB = stacks[dst][min(stackTops[stackTopKey(sid, dst)] ?? 0, stacks[dst].count - 1)]
        let keyA = winKey(topA)
        let keyB = winKey(topB)
        guard let ia = windowOrder.firstIndex(of: keyA),
              let ib = windowOrder.firstIndex(of: keyB) else { return }
        exchangeStackRoles(keyA, keyB)
        windowOrder.swapAt(ia, ib)
        log("drag swap tile \(src) <-> \(dst): \(topA.appName) <-> \(topB.appName)")
        forceTile()
        refreshPanel()
    }

    // 拖动进堆叠：被拖窗口并进目标磁贴（满格也并，原格子收掉重排），
    // 再把它 raise 到该磁贴最上层。目标磁贴 pin 到切走前台 App 为止。
    func performDragStack(draggedKey: String, to dst: Int, screenID sid: CGDirectDisplayID) {
        guard AXIsProcessTrusted() else { return }
        let screen = NSScreen.screens.first(where: { screenID($0) == sid }) ?? NSScreen.main ?? NSScreen.screens[0]
        let windows = collectWindows(on: screen)
        guard !windows.isEmpty else { return }
        let (stacks, _) = computeTiles(windows: windows, st: settingsFor(screen), sid: sid)
        guard dst < stacks.count else { return }
        guard let w = windows.first(where: { winKey($0) == draggedKey }) else {
            log("drag stack skipped: dragged window gone")
            return
        }
        guard let src = stacks.firstIndex(where: { $0.contains { winKey($0) == draggedKey } }) else {
            log("drag stack skipped: source tile gone")
            return
        }
        guard src != dst else { return }
        let destTop = stacks[dst][min(stackTops[stackTopKey(sid, dst)] ?? 0, stacks[dst].count - 1)]
        let destKey = winKey(destTop)
        guard destKey != draggedKey else { return }
        let remaining = stacks[src].filter { winKey($0) != draggedKey }
        if let newRoot = remaining.first(where: { stackedOnto[winKey($0)] == nil }) ?? remaining.first {
            let nr = winKey(newRoot)
            stackedOnto.removeValue(forKey: nr)
            let pointing = stackedOnto.filter { $0.value == draggedKey && $0.key != nr }.map { $0.key }
            for m in pointing { stackedOnto[m] = nr }
        } else {
            for m in stackedOnto.filter({ $0.value == draggedKey }).map({ $0.key }) {
                stackedOnto.removeValue(forKey: m)
            }
        }
        stackedOnto[draggedKey] = destKey
        if stackedOnto[destKey] == draggedKey { stackedOnto.removeValue(forKey: destKey) }
        normalizeStackedOnto(liveKeys: Set(windows.map { winKey($0) }))
        windowOrder.removeAll { $0 == draggedKey }
        windowOrder.append(draggedKey)
        let (stacks2, _) = computeTiles(windows: windows, st: settingsFor(screen), sid: sid)
        if let ti = stacks2.firstIndex(where: { $0.contains { winKey($0) == draggedKey } }),
           let idx = stacks2[ti].firstIndex(where: { winKey($0) == draggedKey }) {
            stackTops[stackTopKey(sid, ti)] = idx
            pinnedActiveTile = ti
            pinnedScreenID = sid
            pinnedFrontmostPid = w.pid
        }
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: w.pid) { app.activate() }
        log("drag stack -> tile \(dst): \(w.appName)")
        forceTile()
        refreshPanel()
    }

}


// 鼠标重排的事件 tap。只处理左键；手势确认之后才吞掉拖动和松开，其余原样放行。
// 系统停掉 tap 时重新打开，并取消进行中的手势。
func mouseDragTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        delegate.dragCancel()
        if let tap = delegate.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard delegate.tapRunning else { return Unmanaged.passUnretained(event) }
    switch type {
    case .leftMouseDown:
        if delegate.dragMouseDown(event) { return nil }
        return Unmanaged.passUnretained(event)
    case .leftMouseDragged:
        if delegate.dragMouseDragged(event) { return nil }
        return Unmanaged.passUnretained(event)
    case .leftMouseUp:
        if delegate.dragMouseUp(event) { return nil }
        return Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}

let delegate = TileProtoApp()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
