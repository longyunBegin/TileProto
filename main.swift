import AppKit
import ApplicationServices
import QuartzCore

// TileProto：菜单栏自动平铺。操作只在鼠标和菜单栏面板上。
// 原理：Accessibility API（AXUIElement）枚举窗口并改 frame。
//  1. 布局 Grid / Columns / Rows / Side。每块屏的磁贴数不超过可见区域容量；
//     上限 1–4 再与窗口数取 min。单磁贴铺满工作区，不留外边距。
//  2. 窗口多于磁贴时堆进活动磁贴（同一矩形）。点橙色握把，或悬停条上的芯片，切换栈顶。
//     ⌃⌘ 拖到某磁贴上时，即使刚好满格也并进去，空出的格子收掉。
//  3. 主窗口份额 Half / 60% / Two-thirds，用于有主格的布局。Grid 两格等分，四格 2×2，不看份额。
//  4. 间距 4 / 8 / 16 pt，窗口之间和屏幕边缘同一间距。
//  5. Focus：活动窗口弹簧铺满工作区，其余留在原处；再点一次按记下的 frame 缩回。
//     Dim：非活动窗口盖 50% 暗色，淡入淡出。菜单栏和 Dock 不动。
//     Present：其余窗口滑出所有屏幕之外，活动窗口居中，桌面铺深色；Dock 和菜单栏仍在。
//  6. 悬停条（窗口上沿约 0.2 秒）：Primary / Focus / Float，堆叠时还有芯片。
//     拖磁贴之间的整条缝改比例，拖动 1:1，松手记住。
//  7. ⌘ 拖到另一磁贴交换；普通拖动松手弹簧弹回，并提示要按住 ⌘。
// 布局、交换、Focus、弹回约 0.5 秒短弹簧，可被下一次布局打断。边框默认关。

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
    var indexTag = 0  // NSView.tag 只读，另用此字段存布局序号或数量值
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
final class SwatchView: NSView {
    var onClick: (() -> Void)?
    var isSelected = false {
        didSet { updateStyle() }
    }
    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 11
        updateStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    private func updateStyle() {
        layer?.borderWidth = isSelected ? 2 : 0
        layer?.borderColor = NSColor.labelColor.cgColor
    }
}

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
    enum Layout: String, CaseIterable {
        case grid, columns, rows, side
    }

    enum MainRatio: String, CaseIterable {
        case half, sixty, twoThirds
        var value: CGFloat {
            switch self {
            case .half: return 0.5
            case .sixty: return 0.6
            case .twoThirds: return 2.0 / 3.0
            }
        }
    }

    // B 批：屏幕满时模式（堆叠进活动磁贴 / 居中浮动）
    enum OverflowMode: String, CaseIterable {
        case stack, floatMiddle
    }

    var statusItem: NSStatusItem!
    var autoTile = true
    var autoOffPlacedKeys: Set<String> = []  // 关自动平铺后已见过的窗口：只给此后新开的窗口居中一次
    var layout: Layout = .grid
    var tileLimit = 4
    var mainRatio: MainRatio = .half
    var gap: CGFloat = 8
    var focusMode = false
    var focusSaved: [(element: AXUIElement, frame: CGRect, key: String)] = []
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
    var layoutButtons: [DiagramButton] = []
    var countButtons: [DiagramButton] = []
    var countHintLabel: NSTextField!
    var arrangementLabel: NSTextField!
    var bordersButton: NSButton!
    var hoverFocusButton: NSButton!
    var tileAppLabel: NSTextField!
    var tileAppSwitch: NSSwitch!
    var ratioSegment: NSSegmentedControl!
    var gapSegment: NSSegmentedControl!
    var focusButton: NSButton!
    var requestAXButton: NSButton!
    var lastPanelTilesKey = ""
    var lastPanelHeight: CGFloat = 0
    // v6 状态：悬停条 / 分隔线 / Float / Primary / 自定义分割
    var floatedKeys: Set<String> = []          // 单窗口 Float：pid|标题
    var primaryKey: String? = nil              // 主窗口：pid|标题，computeTiles 里移到首位
    var splitOverrides: [String: CGFloat] = [:] // key: 布局-磁贴数-分隔线id，值：分隔线中心占 visibleFrame 的比例
    var lastTiles: [(stack: [WinInfo], frame: CGRect, top: WinInfo)] = []
    var lastVF: CGRect = .zero
    var lastScreenFrame: CGRect = .zero
    var tickCount = 0
    var dragQuiet = false
    var draggingDividerID: String? = nil
    var hoverPanel: NSPanel!
    var hoverBarView: NSView!
    var hoverPrimaryButton: NSButton!
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
    var resetSizesButton: NSButton!
    // 鼠标重排：会话事件 tap 只订阅鼠标按下/拖动/松开，用来识别 ⌘ 交换和 ⌃⌘ 进堆叠。
    // 只看鼠标。tap 创建失败时交换手势不可用，普通拖动弹回仍靠 AX 帧比较。
    var eventTap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var tapRunning = false
    var mouseTapFailedLogged = false
    var windowOrder: [String] = []
    /// 手动堆叠：key 不占自己的磁贴，跟在 host 窗口所在的磁贴里。
    /// 窗口数刚好等于上限时，⌃⌘ 拖上去也靠这张表并进目标磁贴，原格子收掉。
    var stackedOnto: [String: String] = [:]
    // Dim / Present（悬停激活默认关、暗色固定 0.5、背景固定深灰）
    var noPeekOn = false
    var cleanSpaceOn = false
    var dimLevel: CGFloat = 0.5
    var dimPanels: [String: NSPanel] = [:]   // key：屏ID:磁贴下标，非活动磁贴各一层
    var lastActiveTile = 0
    var cleanBgPanel: NSPanel?
    var cleanSaved: [(element: AXUIElement, frame: CGRect, key: String)] = []
    var tileHoldUntil: CFTimeInterval = 0
    var noPeekSwitch: NSSwitch!
    var cleanSpaceSwitch: NSSwitch!
    // 高亮默认关。菜单 Borders 在无边框和活动窗口边框之间切换。
    enum HighlightMode: String, CaseIterable { case none, borderActive, borderAll, glow }
    enum HighlightColor: String, CaseIterable { case accent, purple, pink, orange, green, graphite }
    var highlightMode: HighlightMode = .none
    var highlightThickness: CGFloat = 3
    var highlightColor: HighlightColor = .accent
    var hoverActivate = false          // Hover focus：指针停在磁贴上才激活，默认关
    var hoverActivateKey: String?
    var hoverActivateSince: CFTimeInterval = 0
    var highlightPanels: [String: NSPanel] = [:]
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
    // B 批状态：居中浮动模式、超量居中浮动窗口、悬停条开关、设置窗口
    var overflowMode: OverflowMode = .stack
    var middleFloatedKeys: Set<String> = []  // 超量居中浮动窗口：pid|标题，与手动 Float 分开跟踪
    var middleFloatOrder: [String] = []  // 居中浮动顺序：空位出现时最早的先回平铺
    var hoverBarOn = true                    // 悬停条开关（默认开）
    var settingsWindow: NSWindow?
    var settingsTabView: NSTabView?
    var appsTabStack: NSStackView?
    // 上次平铺落点：普通拖动弹回、Focus / Present 还原都读它。只活在这次运行里。
    var lastPlacedFrames: [String: CGRect] = [:]  // winKey -> frame
    // C 批：多显示器 + Spaces（每屏独立设置、窗口集合与磁贴 frame；单屏时与旧行为一致）
    struct ScreenSettings {
        var layout: Layout = .grid
        var tileLimit = 4
        var mainRatio: MainRatio = .half
        var gap: CGFloat = 8
        var overflowMode: OverflowMode = .stack
    }
    var screenSettings: [CGDirectDisplayID: ScreenSettings] = [:]
    var panelScreenID: CGDirectDisplayID? = nil  // 面板选中的屏（nil = 主屏）；单屏时选择器隐藏
    var lastTilesByScreen: [CGDirectDisplayID: [(stack: [WinInfo], frame: CGRect, top: WinInfo)]] = [:]
    var lastVFByScreen: [CGDirectDisplayID: CGRect] = [:]
    var lastScreenFrameByScreen: [CGDirectDisplayID: CGRect] = [:]
    var lastActiveTileByScreen: [CGDirectDisplayID: Int] = [:]
    var lastTiledSignatureByScreen: [CGDirectDisplayID: String] = [:]
    var pinnedScreenID: CGDirectDisplayID? = nil
    // C 批第二部分：Stage Manager 暂停 + 最小尺寸学习
    var stageManagerPaused = false  // 当前是否因 Stage Manager 开启而暂停平铺
    var shrinkFailures: [String: Int] = [:]  // bid -> 连续缩小失败次数（仅内存内）
    var minSizeFloatedKeys: Set<String> = []  // 因最小尺寸退出网格、居中浮动的窗口
    var screenSegment: NSSegmentedControl? = nil

    func screenID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    func mainHeight() -> CGFloat { NSScreen.main?.frame.height ?? 0 }
    func isMainScreen(_ s: NSScreen) -> Bool {
        guard let m = NSScreen.main else { return false }
        return screenID(s) == screenID(m)
    }
    // 某屏的设置：首次访问时以当前全局值（即主屏设置）为模板
    func settingsFor(_ screen: NSScreen) -> ScreenSettings {
        let sid = screenID(screen)
        if let st = screenSettings[sid] { return st }
        let st = ScreenSettings(layout: layout, tileLimit: tileLimit, mainRatio: mainRatio, gap: gap, overflowMode: overflowMode)
        screenSettings[sid] = st
        return st
    }
    func setSettingsFor(_ st: ScreenSettings, screen: NSScreen) {
        screenSettings[screenID(screen)] = st
        if isMainScreen(screen) {
            layout = st.layout; tileLimit = st.tileLimit; mainRatio = st.mainRatio; gap = st.gap; overflowMode = st.overflowMode
        }
    }
    func panelScreen() -> NSScreen {
        if let sid = panelScreenID, let s = NSScreen.screens.first(where: { screenID($0) == sid }) { return s }
        return NSScreen.main ?? NSScreen.screens[0]
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
    // 边框模式下有效间隙取 max（所选间距，粗细），保证边框能画进间隙；光晕与无高亮不撑大
    func effectiveGapFor(_ st: ScreenSettings) -> CGFloat {
        switch highlightMode {
        case .borderActive, .borderAll: return max(st.gap, highlightThickness)
        default: return st.gap
        }
    }
    func stackTopKey(_ sid: CGDirectDisplayID, _ tile: Int) -> String { "\(sid):\(tile)" }

    // MARK: - 开机启动（LaunchAgent，应用自己写 plist）
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

    @objc func settingsLoginChanged(_ sender: NSSwitch) {
        setLoginItem(sender.state == .on)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadExcluded()
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
        // C 批：切 Space 与接/断屏时立即重排（不等 1 秒轮询）；Focus / Present 下 forceTile 会跳过
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            log("space changed")
            self?.forceTile()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            log("screen parameters changed")
            self?.forceTile()
        }
        tick()
        log("TileProto started, layout=\(layout.rawValue) limit=\(tileLimit) main=\(mainRatio.rawValue) gap=\(Int(gap)) excluded=\(excludedBundles.count)")
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
        arrangementLabel = NSTextField(labelWithString: "")
        arrangementLabel.font = .systemFont(ofSize: 11)
        arrangementLabel.textColor = .secondaryLabelColor
        arrangementLabel.alignment = .right
        arrangementLabel.lineBreakMode = .byTruncatingTail
        let captionSpacer = NSView()
        captionSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        captionRow.addArrangedSubview(windowsLabel)
        captionRow.addArrangedSubview(captionSpacer)
        captionRow.addArrangedSubview(arrangementLabel)
        stack.addArrangedSubview(w288(captionRow))

        // C 批：屏幕选择器（多屏时出现，单屏隐藏；切换后布局/上限/尺寸/间距改的是该屏）
        let scrRow = hRow()
        let scrLabel = sectionLabel("屏幕")
        scrLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let scrSpacer = NSView()
        scrSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        screenSegment = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: self, action: #selector(panelScreenChanged(_:)))
        screenSegment?.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        scrRow.addArrangedSubview(scrLabel)
        scrRow.addArrangedSubview(scrSpacer)
        scrRow.addArrangedSubview(screenSegment!)
        stack.addArrangedSubview(w288(scrRow))

        // 布局选择器
        let layoutRow = hRow(distribution: .fillEqually)
        let layoutDiagrams: [[CGRect]] = [
            [CGRect(x: 0, y: 0, width: 0.56, height: 1), CGRect(x: 0.62, y: 0, width: 0.38, height: 0.47), CGRect(x: 0.62, y: 0.53, width: 0.38, height: 0.47)],
            [CGRect(x: 0, y: 0, width: 0.30, height: 1), CGRect(x: 0.35, y: 0, width: 0.30, height: 1), CGRect(x: 0.70, y: 0, width: 0.30, height: 1)],
            [CGRect(x: 0, y: 0, width: 1, height: 0.47), CGRect(x: 0, y: 0.53, width: 1, height: 0.47)],
            [CGRect(x: 0, y: 0, width: 0.56, height: 1), CGRect(x: 0.62, y: 0, width: 0.38, height: 1)],
        ]
        for (i, l) in Layout.allCases.enumerated() {
            let b = DiagramButton(title: layoutName(l))
            b.rects = layoutDiagrams[i]
            b.indexTag = i
            let idx = i
            b.onClick = { [weak self] in self?.applyLayout(Layout.allCases[idx]) }
            layoutButtons.append(b)
            layoutRow.addArrangedSubview(b)
        }
        stack.addArrangedSubview(w288(layoutRow))

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
        countHintLabel = NSTextField(labelWithString: "")
        countHintLabel.font = .systemFont(ofSize: 11)
        countHintLabel.textColor = .secondaryLabelColor
        countHintLabel.isHidden = true
        stack.addArrangedSubview(w288(countHintLabel))
        stack.addArrangedSubview(w288(separator()))

        // 主窗口尺寸 + 间距
        let ratioRow = hRow()
        let ratioLabel = sectionLabel("主窗口尺寸")
        ratioLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        ratioSegment = NSSegmentedControl(labels: ["Half", "60%", "Two-thirds"], trackingMode: .selectOne, target: self, action: #selector(panelRatioChanged(_:)))
        ratioRow.addArrangedSubview(ratioLabel)
        ratioRow.addArrangedSubview(ratioSegment)
        stack.addArrangedSubview(w288(ratioRow))
        let gapRow = hRow()
        let gapLabel = sectionLabel("间距")
        gapLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        gapSegment = NSSegmentedControl(labels: ["4 pt", "8 pt", "16 pt"], trackingMode: .selectOne, target: self, action: #selector(panelGapChanged(_:)))
        gapRow.addArrangedSubview(gapLabel)
        gapRow.addArrangedSubview(gapSegment)
        stack.addArrangedSubview(w288(gapRow))
        stack.addArrangedSubview(w288(separator()))

        // Retile / Borders / Hover focus
        let actionRow = hRow(distribution: .fillEqually)
        let tileNowBtn = NSButton(title: "Retile", target: self, action: #selector(panelTileNow(_:)))
        bordersButton = NSButton(title: "Borders", target: self, action: #selector(panelToggleBorders(_:)))
        bordersButton.setButtonType(.pushOnPushOff)
        hoverFocusButton = NSButton(title: "Hover focus", target: self, action: #selector(panelToggleHoverFocus(_:)))
        hoverFocusButton.setButtonType(.pushOnPushOff)
        for b in [tileNowBtn, bordersButton!, hoverFocusButton!] { actionRow.addArrangedSubview(b) }
        stack.addArrangedSubview(w288(actionRow))

        // v6 第二动作行：恢复浮动窗口、重置尺寸（上面已有行不动）
        let actionRow2 = hRow(distribution: .fillEqually)
        focusButton = NSButton(title: "Focus", target: self, action: #selector(panelToggleFocus(_:)))
        restoreFloatsButton = NSButton(title: "恢复浮动窗口", target: self, action: #selector(panelRestoreFloats(_:)))
        resetSizesButton = NSButton(title: "重置尺寸", target: self, action: #selector(panelResetSizes(_:)))
        actionRow2.addArrangedSubview(focusButton!)
        actionRow2.addArrangedSubview(restoreFloatsButton!)
        actionRow2.addArrangedSubview(resetSizesButton!)
        stack.addArrangedSubview(w288(actionRow2))

        // Dim：非活动窗口 50% 暗色，淡入淡出。没有按键开关。
        let npRow = hRow()
        let npLabel = NSTextField(labelWithString: "减弱其他")
        npLabel.font = .systemFont(ofSize: 12)
        npLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        noPeekSwitch = NSSwitch()
        noPeekSwitch.target = self
        noPeekSwitch.action = #selector(panelToggleNoPeek(_:))
        noPeekSwitch.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let npSpacer = NSView()
        npSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        npRow.addArrangedSubview(npLabel)
        npRow.addArrangedSubview(npSpacer)
        npRow.addArrangedSubview(noPeekSwitch)
        stack.addArrangedSubview(w288(npRow))

        // Present：只留当前窗口在深色桌面中央。没有按键开关。
        let csRow = hRow()
        let csLabel = NSTextField(labelWithString: "演示")
        csLabel.font = .systemFont(ofSize: 12)
        csLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        cleanSpaceSwitch = NSSwitch()
        cleanSpaceSwitch.target = self
        cleanSpaceSwitch.action = #selector(panelToggleCleanSpace(_:))
        cleanSpaceSwitch.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let csSpacer = NSView()
        csSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        csRow.addArrangedSubview(csLabel)
        csRow.addArrangedSubview(csSpacer)
        csRow.addArrangedSubview(cleanSpaceSwitch)
        stack.addArrangedSubview(w288(csRow))

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

        let settingsRow = hRow(distribution: .fillEqually)
        let settingsBtn = NSButton(title: "设置", target: self, action: #selector(panelOpenSettings(_:)))
        settingsRow.addArrangedSubview(settingsBtn)
        stack.addArrangedSubview(w288(settingsRow))

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

    func layoutNameCN(_ l: Layout) -> String {
        switch l {
        case .grid: return "网格"
        case .columns: return "多列"
        case .rows: return "多行"
        case .side: return "主次"
        }
    }

    func layoutName(_ l: Layout) -> String {
        switch l {
        case .grid: return "Grid"
        case .columns: return "Columns"
        case .rows: return "Rows"
        case .side: return "Side"
        }
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
            // C 批：面板显示选中屏的磁贴与设置（单屏时即主屏）
            let screen = panelScreen()
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
        // C 批：面板控件反映选中屏的设置；屏幕选择器只在多屏时出现
        let panelSt = settingsFor(panelScreen())
        for (i, b) in layoutButtons.enumerated() {
            b.isSelected = (Layout.allCases[i] == panelSt.layout)
            b.needsDisplay = true
        }
        let cap = capacity(panelSt.layout, sid: screenID(panelScreen()))
        arrangementLabel?.stringValue = arrangementCaption(panelSt.layout, count: min(panelSt.tileLimit, cap))
        for b in countButtons {
            b.rects = countDiagram(panelSt.layout, count: b.indexTag)
            b.isSelected = (b.indexTag == panelSt.tileLimit)
            b.isDisabled = (b.indexTag > cap)
            b.needsDisplay = true
        }
        if let hint = fitHintLine(panelSt.layout, fit: cap) {
            countHintLabel.stringValue = hint
            countHintLabel.isHidden = false
        } else {
            countHintLabel.isHidden = true
        }
        ratioSegment.selectedSegment = MainRatio.allCases.firstIndex(of: panelSt.mainRatio) ?? 0
        gapSegment.selectedSegment = [4, 8, 16].firstIndex(of: Int(panelSt.gap)) ?? 1
        if let seg = screenSegment {
            let screens = NSScreen.screens
            seg.isHidden = screens.count <= 1
            if screens.count > 1 {
                // 标签数变化时重建（屏插拔后）
                let labels = screens.map { screenName($0) }
                if seg.segmentCount != labels.count {
                    seg.segmentCount = labels.count
                    for (i, l) in labels.enumerated() { seg.setLabel(l, forSegment: i) }
                }
                seg.selectedSegment = screens.firstIndex(where: { screenID($0) == screenID(panelScreen()) }) ?? 0
            }
        }
        focusButton.title = focusMode ? "Focus on" : "Focus"
        bordersButton?.state = highlightMode == .none ? .off : .on
        hoverFocusButton?.state = hoverActivate ? .on : .off
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
        restoreFloatsButton.isEnabled = !floatedKeys.isEmpty || !middleFloatedKeys.isEmpty
        resetSizesButton.isHidden = splitOverrides.isEmpty
        noPeekSwitch.state = noPeekOn ? .on : .off
        cleanSpaceSwitch.state = cleanSpaceOn ? .on : .off
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

    @objc func panelScreenChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0, sender.selectedSegment < NSScreen.screens.count else { return }
        panelScreenID = screenID(NSScreen.screens[sender.selectedSegment])
        log("panel screen -> \(screenName(panelScreen()))")
        refreshPanel()
    }

    // C 批：布局/上限/尺寸/间距/满屏模式改的都是面板选中屏的设置
    // （主屏时同时同步全局镜像，保持单屏路径与旧行为一致）
    func applyLayout(_ l: Layout) {
        let screen = panelScreen()
        var st = settingsFor(screen)
        st.layout = l
        let cap = capacity(l, sid: screenID(screen))
        if st.tileLimit > cap { st.tileLimit = cap }
        setSettingsFor(st, screen: screen)
        log("layout -> \(l.rawValue) screen=\(screenName(screen)) fit=\(cap)")
        let toast = layoutToast(l, fit: cap)
        showToast(toast.0, detail: toast.1, on: screen)
        forceTile()
        refreshPanel()
    }

    func applyLimit(_ v: Int, screen: NSScreen? = nil) {
        let target = screen ?? panelScreen()
        var st = settingsFor(target)
        let cap = capacity(st.layout, sid: screenID(target))
        if v > cap {
            if let hint = fitHintLine(st.layout, fit: cap) {
                showToast(hint, on: target)
            }
            log("tileLimit \(v) rejected; \(st.layout.rawValue) fits \(cap) on \(screenName(target))")
            refreshPanel()
            return
        }
        st.tileLimit = v
        setSettingsFor(st, screen: target)
        log("tileLimit -> \(v) screen=\(screenName(target))")
        showToast("Up to \(v) window\(v == 1 ? "" : "s")", detail: "On this screen, in this Space.", on: target)
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

    func arrangementCaption(_ l: Layout, count: Int) -> String {
        let w = countWord(max(1, min(4, count)))
        switch l {
        case .columns: return "Columns · \(w) column\(count == 1 ? "" : "s")"
        case .rows: return "Rows · \(w) row\(count == 1 ? "" : "s")"
        case .side: return "Side · \(w)"
        case .grid: return "Grid · \(w)"
        }
    }

    /// 数量按钮的小图，跟着当前布局变（Columns 是竖条，Rows 是横带，Grid/Side 是对应分法）。
    /// 坐标 y 从上往下，与 DiagramButton 的约定一致。
    func countDiagram(_ l: Layout, count: Int) -> [CGRect] {
        let n = max(1, min(4, count))
        let g: CGFloat = 0.08
        func strips(_ vertical: Bool) -> [CGRect] {
            let span = (1 - g * CGFloat(n - 1)) / CGFloat(n)
            return (0..<n).map { i in
                let o = CGFloat(i) * (span + g)
                return vertical
                    ? CGRect(x: o, y: 0, width: span, height: 1)
                    : CGRect(x: 0, y: o, width: 1, height: span)
            }
        }
        switch l {
        case .columns: return strips(true)
        case .rows: return strips(false)
        case .grid:
            switch n {
            case 1: return [CGRect(x: 0, y: 0, width: 1, height: 1)]
            case 2:
                return [CGRect(x: 0, y: 0, width: 0.47, height: 1), CGRect(x: 0.53, y: 0, width: 0.47, height: 1)]
            case 3:
                return [
                    CGRect(x: 0, y: 0, width: 0.56, height: 1),
                    CGRect(x: 0.62, y: 0, width: 0.38, height: 0.47),
                    CGRect(x: 0.62, y: 0.53, width: 0.38, height: 0.47),
                ]
            default:
                return [
                    CGRect(x: 0, y: 0, width: 0.47, height: 0.47),
                    CGRect(x: 0.53, y: 0, width: 0.47, height: 0.47),
                    CGRect(x: 0, y: 0.53, width: 0.47, height: 0.47),
                    CGRect(x: 0.53, y: 0.53, width: 0.47, height: 0.47),
                ]
            }
        case .side:
            switch n {
            case 1: return [CGRect(x: 0, y: 0, width: 1, height: 1)]
            case 2:
                return [CGRect(x: 0, y: 0, width: 0.58, height: 1), CGRect(x: 0.66, y: 0, width: 0.34, height: 1)]
            default:
                var rects = [CGRect(x: 0, y: 0, width: 0.58, height: 1)]
                let gap: CGFloat = 0.04
                let h = (1 - gap * CGFloat(n - 2)) / CGFloat(n - 1)
                for i in 0..<(n - 1) {
                    rects.append(CGRect(x: 0.66, y: CGFloat(i) * (h + gap), width: 0.34, height: h))
                }
                return rects
            }
        }
    }

    func fitHintLine(_ l: Layout, fit: Int) -> String? {
        guard l != .grid, fit < 4 else { return nil }
        switch l {
        case .columns: return "This screen fits \(fit) columns. Pick Grid for four."
        case .rows: return "This screen fits \(fit) rows. Pick Grid for four."
        case .side: return "This screen fits \(fit). Pick Grid for four."
        case .grid: return nil
        }
    }

    func layoutToast(_ l: Layout, fit: Int) -> (String, String) {
        switch l {
        case .grid: return ("Grid", "One main window, the rest share the side. This screen fits \(fit).")
        case .columns: return ("Columns", "Side by side. This screen fits \(fit).")
        case .rows: return ("Rows", "Full width, one above the other. This screen fits \(fit).")
        case .side: return ("Side", "One big window, the others in a column. This screen fits \(fit).")
        }
    }

    func frontRegularApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    @objc func panelToggleBorders(_ sender: NSButton) {
        highlightMode = (highlightMode == .none) ? .borderActive : .none
        log("borders -> \(highlightMode.rawValue)")
        refreshHighlights()
        refreshPanel()
    }

    @objc func panelToggleHoverFocus(_ sender: NSButton) {
        hoverActivate = (sender.state == .on)
        hoverActivateKey = nil
        log("hover focus -> \(hoverActivate)")
        refreshPanel()
    }

    @objc func panelToggleTileApp(_ sender: NSSwitch) {
        guard let app = frontRegularApp(), let bid = app.bundleIdentifier else { return }
        setAppExcluded(bid, sender.state != .on)
        log("tile app \(app.localizedName ?? bid) -> \(sender.state == .on)")
        forceTile()
        refreshPanel()
    }

    @objc func panelRatioChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        let r = MainRatio.allCases[sender.selectedSegment]
        var st = settingsFor(panelScreen())
        st.mainRatio = r
        setSettingsFor(st, screen: panelScreen())
        log("mainRatio -> \(r.rawValue)")
        forceTile()
        refreshPanel()
    }

    @objc func panelGapChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        var st = settingsFor(panelScreen())
        st.gap = CGFloat([4, 8, 16][sender.selectedSegment])
        setSettingsFor(st, screen: panelScreen())
        log("gap -> \(Int(st.gap))")
        forceTile()
        refreshPanel()
    }

    @objc func panelTileNow(_ sender: NSButton) {
        forceTile()
        showToast("Retiled", on: panelScreen())
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
            hideHoverBar()
            hideHighlights()
        }
        refreshPanel()
    }

    @objc func panelToggleFocus(_ sender: NSButton) {
        if focusMode {
            disableFocus()
        } else {
            enableFocus()
        }
        refreshPanel()
    }

    // B 批：屏幕满时模式切换；切回堆叠时超量浮动窗口自动放回平铺
    // C 批：改的是面板选中屏的满屏模式
    func applyOverflowMode(_ m: OverflowMode) {
        var st = settingsFor(panelScreen())
        st.overflowMode = m
        setSettingsFor(st, screen: panelScreen())
        if m == .stack, !middleFloatedKeys.isEmpty {
            middleFloatedKeys.removeAll()
            middleFloatOrder.removeAll()
            log("overflow mode -> stack, middle-floated windows returned")
        } else {
            log("overflow mode -> \(m.rawValue)")
        }
        forceTile()
        refreshPanel()
    }

    @objc func panelOpenSettings(_ sender: NSButton) {
        panelPopover.close()
        openSettings()
    }

    @objc func panelRestoreFloats(_ sender: NSButton) {
        guard !floatedKeys.isEmpty || !middleFloatedKeys.isEmpty || !minSizeFloatedKeys.isEmpty else { return }
        floatedKeys.removeAll()
        middleFloatedKeys.removeAll()
        middleFloatOrder.removeAll()
        minSizeFloatedKeys.removeAll()
        log("floated windows restored (incl. middle-floated and min-size-floated)")
        forceTile()
        refreshPanel()
    }

    @objc func panelResetSizes(_ sender: NSButton) {
        guard !splitOverrides.isEmpty else { return }
        splitOverrides.removeAll()
        log("split overrides cleared")
        forceTile()
        refreshPanel()
    }

    @objc func panelRequestAX(_ sender: NSButton) {
        requestAccessibility()
    }

    @objc func panelQuit(_ sender: NSButton) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - B 批设置窗口（NSWindow + NSTabView，控件全部接到现成状态）

    func stRow(label: String, control: NSView) -> NSView {
        let row = hRow()
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 13)
        l.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        row.addArrangedSubview(l)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(control)
        row.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return row
    }

    func stSwitch(state: Bool, action: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.state = state ? .on : .off
        s.target = self
        s.action = action
        return s
    }

    func stSegment(labels: [String], selected: Int, action: Selector) -> NSSegmentedControl {
        let s = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
        s.selectedSegment = selected
        return s
    }

    func stNote(_ text: String) -> NSView {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        l.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return l
    }

    func stSection(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return l
    }

    func stTab(_ stack: NSStackView) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -40),
        ])
        return scroll
    }

    func stStack(_ views: [NSView]) -> NSStackView {
        let st = NSStackView(views: views)
        st.orientation = .vertical
        st.spacing = 12
        return st
    }

    func openSettings(select tab: String? = nil) {
        if let w = settingsWindow {
            if let tab, let tv = settingsTabView,
               let item = tv.tabViewItems.first(where: { ($0.identifier as? String) == tab || $0.label == tab }) {
                tv.selectTabViewItem(item)
            }
            w.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate()
            return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "TileProto 设置"
        win.delegate = self
        win.isReleasedWhenClosed = false
        let tabs = NSTabView()
        func item(_ label: String, _ view: NSView) -> NSTabViewItem {
            let it = NSTabViewItem(identifier: label)
            it.label = label
            it.view = view
            return it
        }
        // General：自动平铺、开机启动、减弱其他、辅助功能只读状态、版本
        let general = stStack([
            stRow(label: "自动平铺", control: stSwitch(state: autoTile, action: #selector(panelToggleAuto(_:)))),
            stRow(label: "开机启动", control: stSwitch(state: loginItemEnabled(), action: #selector(settingsLoginChanged(_:)))),
            stRow(label: "减弱其他", control: stSwitch(state: noPeekOn, action: #selector(panelToggleNoPeek(_:)))),
            stRow(label: "辅助功能", control: {
                let l = NSTextField(labelWithString: AXIsProcessTrusted() ? "已允许" : "未允许")
                l.font = .systemFont(ofSize: 13)
                return l
            }()),
            stRow(label: "版本", control: {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
                let l = NSTextField(labelWithString: "TileProto \(version)")
                l.font = .systemFont(ofSize: 13)
                return l
            }()),
            stNote("本机运行，不经过服务器、不连接云端。"),
            stNote("不读窗口内容，不收集、不上传数据。移动和缩放窗口只需要辅助功能权限。"),
        ])
        tabs.addTabViewItem(item("General", stTab(general)))
        // Layout：布局、主尺寸、磁贴上限、屏幕满时、间距（全部复用现成处理）；
        // C 批：读的是面板选中屏的设置，多屏时顶部提示当前在编哪块屏
        let pst = settingsFor(panelScreen())
        var layoutRows: [NSView] = []
        if NSScreen.screens.count > 1 {
            layoutRows.append(stNote("正在编辑：\(screenName(panelScreen()))（在菜单栏面板的“屏幕”里切换）。"))
        }
        layoutRows.append(contentsOf: [
            stRow(label: "布局", control: stSegment(labels: ["Grid", "Columns", "Rows", "Side"], selected: Layout.allCases.firstIndex(of: pst.layout) ?? 0, action: #selector(settingsLayoutChanged(_:)))),
            stRow(label: "主窗口尺寸", control: stSegment(labels: ["Half", "60%", "Two-thirds"], selected: MainRatio.allCases.firstIndex(of: pst.mainRatio) ?? 0, action: #selector(panelRatioChanged(_:)))),
            stNote("主窗口从这里起步，其余窗口分剩下的空间。Grid 两格是等分，四格是田字，不受这项影响。"),
            stRow(label: "磁贴上限", control: stSegment(labels: ["1", "2", "3", "4"], selected: max(0, pst.tileLimit - 1), action: #selector(settingsLimitChanged(_:)))),
            stRow(label: "屏幕满时", control: stSegment(labels: ["堆叠进活动磁贴", "居中浮动"], selected: pst.overflowMode == .stack ? 0 : 1, action: #selector(settingsOverflowChanged(_:)))),
            stNote("堆叠：新窗口盖到活动磁贴最上面。居中浮动：先浮在中间，直到有空位再归位。"),
            stNote("Columns 在 MacBook 上放得下三列，更宽的屏幕四列；Rows 两行或三行；Side 三个或四个。竖屏一律按行往下堆。"),
            stRow(label: "间距", control: stSegment(labels: ["4 pt", "8 pt", "16 pt"], selected: [4, 8, 16].firstIndex(of: Int(pst.gap)) ?? 1, action: #selector(panelGapChanged(_:)))),
            stNote("窗口之间和屏幕边缘用同一间距。单窗全屏磁贴不留边。"),
        ])
        let layoutTab = stStack(layoutRows)
        tabs.addTabViewItem(item("Layout", stTab(layoutTab)))
        tabs.addTabViewItem(item("Mouse", stTab(buildMouseTab())))
        let appsStack = stStack([])
        appsTabStack = appsStack
        rebuildAppsSettings()
        tabs.addTabViewItem(item("Apps", stTab(appsStack)))
        tabs.frame = win.contentView!.bounds
        tabs.autoresizingMask = [.width, .height]
        win.contentView!.addSubview(tabs)
        settingsTabView = tabs
        if let tab, let item = tabs.tabViewItems.first(where: { ($0.identifier as? String) == tab || $0.label == tab }) {
            tabs.selectTabViewItem(item)
        }
        win.center()
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate()
        log("settings opened")
    }

    @objc func settingsLayoutChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        applyLayout(Layout.allCases[sender.selectedSegment])
    }

    @objc func settingsLimitChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        applyLimit(sender.selectedSegment + 1)
    }

    @objc func settingsOverflowChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        applyOverflowMode(sender.selectedSegment == 0 ? .stack : .floatMiddle)
    }

    func buildMouseTab() -> NSStackView {
        return stStack([
            stRow(label: "悬停条", control: stSwitch(state: hoverBarOn, action: #selector(settingsToggleHoverBar(_:)))),
            stNote("指针在窗口上沿停留约 0.2 秒后出现深色条。堆叠里有 ‹ › 和每个窗口的芯片，再加上 Primary、Focus、Float。"),
            stRow(label: "悬停激活", control: stSwitch(state: hoverActivate, action: #selector(settingsToggleHoverActivate(_:)))),
            stNote("指针停在窗口上就激活，不用再点。默认关。"),
            stNote("缝：拖两块磁贴之间的间隙，整列或整行一起缩放，间隙宽度保持不变。拖动跟手，不走弹簧。"),
            stNote("交换：按住 ⌘ 把一个窗口拖到另一个磁贴上，松手对调。"),
            stNote("加入堆叠：按住 ⌃⌘ 把窗口拖到某块磁贴上，松手堆进去，空出的格子收掉。"),
            stNote("普通拖动不会重排。松手后窗口弹簧回到原磁贴，并提示按住 ⌘ 才能交换。"),
        ])
    }

    @objc func settingsToggleHoverBar(_ sender: NSSwitch) {
        hoverBarOn = (sender.state == .on)
        if !hoverBarOn { hideHoverBar() }
        log("hoverBar -> \(hoverBarOn)")
    }

    @objc func settingsToggleHoverActivate(_ sender: NSSwitch) {
        hoverActivate = (sender.state == .on)
        hoverActivateKey = nil
        hoverFocusButton?.state = hoverActivate ? .on : .off
        log("hover focus -> \(hoverActivate)")
    }

    func appDisplayName(for bid: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
            return app.localizedName ?? bid
        }
        return bid
    }

    func rebuildAppsSettings() {
        guard let stack = appsTabStack else { return }
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        stack.addArrangedSubview(stSection("不平铺应用"))
        if excludedBundles.isEmpty {
            stack.addArrangedSubview(stNote("暂无不平铺的应用。"))
        } else {
            for bid in excludedBundles.sorted() {
                let btn = NSButton(title: "移除", target: self, action: #selector(settingsRemoveExcluded(_:)))
                btn.identifier = NSUserInterfaceItemIdentifier(bid)
                stack.addArrangedSubview(stRow(label: appDisplayName(for: bid), control: btn))
            }
        }
        let addBtn = NSButton(title: "添加前台应用", target: self, action: #selector(settingsAddFrontApp(_:)))
        let addRow = hRow()
        addRow.addArrangedSubview(addBtn)
        addRow.widthAnchor.constraint(equalToConstant: 520).isActive = true
        stack.addArrangedSubview(addRow)
        if !excludedBundles.isEmpty {
            let clearBtn = NSButton(title: "清除全部", target: self, action: #selector(settingsClearExcluded(_:)))
            let clearRow = hRow()
            clearRow.addArrangedSubview(clearBtn)
            clearRow.widthAnchor.constraint(equalToConstant: 520).isActive = true
            stack.addArrangedSubview(clearRow)
        }
        stack.addArrangedSubview(stSection("无法缩小应用"))
        let mins = learnedMinSizes()
        if mins.isEmpty {
            stack.addArrangedSubview(stNote("暂无（窗口连续两次缩不到磁贴尺寸时，会在这里学会它的最小尺寸）。"))
        } else {
            for bid in mins.keys.sorted(by: { appDisplayName(for: $0) < appDisplayName(for: $1) }) {
                let a = mins[bid]!
                let btn = NSButton(title: "遗忘", target: self, action: #selector(settingsForgetMinSize(_:)))
                btn.identifier = NSUserInterfaceItemIdentifier(bid)
                stack.addArrangedSubview(stRow(label: "\(appDisplayName(for: bid)) — 最小 \(Int(a[0]))×\(Int(a[1]))", control: btn))
            }
        }
    }

    @objc func settingsClearExcluded(_ sender: NSButton) {
        try? FileManager.default.removeItem(atPath: excludedFilePath())
        loadExcluded()
        log("excluded list cleared")
        rebuildAppsSettings()
        forceTile()
    }

    @objc func settingsForgetMinSize(_ sender: NSButton) {
        let bid = sender.identifier?.rawValue ?? ""
        guard !bid.isEmpty else { return }
        forgetLearnedMinSize(bid: bid)
        // 该应用已居中浮动的窗口放回平铺集合，下次重排即归位
        let all = collectWindows(includeFloated: true, onlyCurrentSpace: false)
        var drop: Set<String> = []
        for w in all where bundleID(for: w.pid) == bid { drop.insert(winKey(w)) }
        minSizeFloatedKeys.subtract(drop)
        rebuildAppsSettings()
        forceTile()
    }

    @objc func settingsRemoveExcluded(_ sender: NSButton) {
        let bid = sender.identifier?.rawValue ?? ""
        guard !bid.isEmpty else { return }
        setAppExcluded(bid, false)
        rebuildAppsSettings()
    }

    @objc func settingsAddFrontApp(_ sender: NSButton) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier else { return }
        setAppExcluded(bid, true)
        rebuildAppsSettings()
    }

    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow, w === settingsWindow {
            settingsWindow = nil
        }
    }

    // MARK: - 排除列表

    func excludedFilePath() -> String {
        ("~/tileproto/excluded.txt" as NSString).expandingTildeInPath
    }

    func loadExcluded() {
        let text = (try? String(contentsOfFile: excludedFilePath())) ?? ""
        excludedBundles = Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
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
            hideGrips(); hideHoverBar(); removeDimLayers(); hideHighlights()
        } else if AXIsProcessTrusted(), autoTile, !focusMode, !cleanSpaceOn {
            forceTile()
        }
    }

    func tick() {
        if panelPopover.isShown { refreshPanel() }
        guard autoTile else {
            hideGrips()
            hideHoverBar()
            hideHighlights()
            hideDotHandles()
            hideStackMarkers()
            closeStackPanel()
            // 关自动平铺：窗口保持平铺位置不动；此后新开的窗口居中浮动一次（50% 宽 × 60% 高）
            if AXIsProcessTrusted(), !focusMode, !cleanSpaceOn {
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
            hideHoverBar()
            hideHighlights()
            hideDotHandles()
            hideStackMarkers()
            closeStackPanel()
            return
        }
        // C2：Stage Manager 开启时暂停一切平铺动作（窗口保持原样不动）
        refreshStageManagerPause()
        if stageManagerPaused {
            hideGrips()
            hideHoverBar()
            removeDimLayers()
            hideHighlights()
            hideDotHandles()
            hideStackMarkers()
            closeStackPanel()
            return
        }
        // D 批：pin 住的目标磁贴在用户切到别的 App 时放开，并重排一次；
        // Focus / Present 期间只清 pin、不重排（退出后正常流程会重排）
        if pinnedActiveTile != nil, let pp = pinnedFrontmostPid,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != pp {
            pinnedActiveTile = nil
            pinnedScreenID = nil
            pinnedFrontmostPid = nil
            log("drag stack pin released")
            if !focusMode, !cleanSpaceOn { forceTile() }
        }
        // Focus / Present 期间自动平铺暂停。还原弹簧的前 0.6s 也先别重排，
        // 否则离屏窗口还没回到磁贴，签名会把布局打乱。
        if CACurrentMediaTime() < tileHoldUntil { return }
        guard !focusMode, !cleanSpaceOn else {
            hideGrips()
            hideHoverBar()
            removeDimLayers()
            hideHighlights()
            hideDotHandles()
            hideStackMarkers()
            closeStackPanel()
            return
        }
        tickCount += 1
        if tickCount % 5 == 0 { pruneFloated(); pruneMiddleFloated(); pruneMinSizeFloated() }
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
                    guard frameMotions[key] == nil else { continue }
                    guard let placed = lastPlacedFrames[key],
                          let w = live.first(where: { winKey($0) == key }) else { continue }
                    let dx = w.frame.minX - placed.minX, dy = w.frame.minY - placed.minY
                    let dw = w.frame.width - placed.width, dh = w.frame.height - placed.height
                    guard dx * dx + dy * dy + dw * dw + dh * dh > 16 else { continue }
                    guard screenID(screenForFrame(w.frame)) == sid else { continue }
                    placeFrame(w.element, placed, key: key, animated: true)
                    if !toasted {
                        let screen = NSScreen.screens.first(where: { screenID($0) == sid })
                        showToast("普通拖动不会重排。", detail: "按住 ⌘ 拖到另一块磁贴上才会交换。", on: screen)
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
        guard !focusMode, !cleanSpaceOn else {
            log("forceTile skipped: focus/clean space on")
            return
        }
        pruneFloated()
        pruneMiddleFloated()
        pruneMinSizeFloated()
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
                if !includeFloated && (floatedKeys.contains(winKey(info)) || middleFloatedKeys.contains(winKey(info)) || minSizeFloatedKeys.contains(winKey(info))) { continue }
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

    // 定期清理已关闭的超量居中浮动窗口（与手动 Float 分开跟踪；同上，不过滤 Space）
    func pruneMiddleFloated() {
        guard !middleFloatedKeys.isEmpty, AXIsProcessTrusted() else { return }
        let all = collectWindows(includeFloated: true, onlyCurrentSpace: false)
        let keys = Set(all.map { winKey($0) })
        let before = middleFloatedKeys.count
        middleFloatedKeys = middleFloatedKeys.intersection(keys)
        middleFloatOrder = middleFloatOrder.filter { middleFloatedKeys.contains($0) }
        if middleFloatedKeys.count != before {
            log("middle-floated pruned: \(before) -> \(middleFloatedKeys.count)")
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
    // 定期清理已关闭的最小尺寸浮动窗口（与手动 Float 分开跟踪；同上，不过滤 Space）
    func pruneMinSizeFloated() {
        guard !minSizeFloatedKeys.isEmpty, AXIsProcessTrusted() else { return }
        let all = collectWindows(includeFloated: true, onlyCurrentSpace: false)
        let keys = Set(all.map { winKey($0) })
        let before = minSizeFloatedKeys.count
        minSizeFloatedKeys = minSizeFloatedKeys.intersection(keys)
        if minSizeFloatedKeys.count != before {
            log("min-size-floated pruned: \(before) -> \(minSizeFloatedKeys.count)")
        }
    }

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

    /// 这块屏在该布局下能放下几块磁贴。
    /// 阈值按可见区域的点算（菜单栏和 Dock 已经不在 visibleFrame 里）。
    /// 笔记本宽度（<1800pt）Columns 3、Rows 在高度 <1100pt 时为 2、Side 3，Grid 恒为 4。
    /// 更宽（≥1800pt）Columns 到 4；更高（≥1100pt）Rows 到 3；宽和高都过线 Side 才到 4。
    /// 竖屏（高大于宽）一律按行堆：Columns 降到 2，Rows 在高度 ≥900pt 时为 3。
    func fitCount(_ layout: Layout, visible vf: CGRect) -> Int {
        let w = vf.width
        let h = vf.height
        let tall = h > w
        switch layout {
        case .grid:
            return 4
        case .columns:
            if tall { return 2 }
            return w >= 1800 ? 4 : 3
        case .rows:
            if tall { return h >= 900 ? 3 : 2 }
            return h >= 1100 ? 3 : 2
        case .side:
            if !tall, w >= 1800, h >= 1100 { return 4 }
            return 3
        }
    }

    func capacity(_ l: Layout, sid: CGDirectDisplayID) -> Int {
        let vf: CGRect
        if let s = NSScreen.screens.first(where: { screenID($0) == sid }) {
            vf = s.visibleFrame
        } else {
            vf = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        return fitCount(l, visible: vf)
    }

    // 主窗口在左 + 右列 sideRows 个磁贴（Grid 3 磁贴与 Side 3 磁贴共用）
    func mainAndSideFrames(vf: CGRect, sideRows: Int, st: ScreenSettings) -> [CGRect] {
        let g = effectiveGapFor(st)
        let aw = vf.width - 2 * g
        let mw = (aw - g) * st.mainRatio.value
        let sw = aw - g - mw
        let main = CGRect(x: vf.minX + g, y: vf.minY + g, width: mw, height: vf.height - 2 * g)
        let x2 = vf.minX + g + mw + g
        let h = (vf.height - g * CGFloat(sideRows + 1)) / CGFloat(sideRows)
        var out = [main]
        for i in 0..<sideRows {
            out.append(CGRect(x: x2, y: vf.maxY - g - CGFloat(i + 1) * h - CGFloat(i) * g, width: sw, height: h))
        }
        return out
    }

    func tileFrames(count t: Int, vf: CGRect, st: ScreenSettings) -> [CGRect] {
        // 单窗口真全屏：全部布局 1 窗时不 inset gap
        if t == 1 { return [vf] }
        let g = effectiveGapFor(st)
        switch st.layout {
        case .grid:
            switch t {
            case 2:
                let w = (vf.width - 3 * g) / 2, h = vf.height - 2 * g
                return [
                    CGRect(x: vf.minX + g, y: vf.minY + g, width: w, height: h),
                    CGRect(x: vf.minX + g + w + g, y: vf.minY + g, width: w, height: h),
                ]
            case 3:
                return mainAndSideFrames(vf: vf, sideRows: 2, st: st)
            default: // 4，以及不是 2/3 的数量：2×2。t == 1 已在上面返回整屏
                let w = (vf.width - 3 * g) / 2, h = (vf.height - 3 * g) / 2
                let x0 = vf.minX + g, x1 = x0 + w + g
                let yTop = vf.maxY - g - h, yBot = vf.minY + g
                return [
                    CGRect(x: x0, y: yTop, width: w, height: h),
                    CGRect(x: x1, y: yTop, width: w, height: h),
                    CGRect(x: x0, y: yBot, width: w, height: h),
                    CGRect(x: x1, y: yBot, width: w, height: h),
                ]
            }
        case .columns:
            let w = (vf.width - g * CGFloat(t + 1)) / CGFloat(t)
            return (0..<t).map { CGRect(x: vf.minX + g + CGFloat($0) * (w + g), y: vf.minY + g, width: w, height: vf.height - 2 * g) }
        case .rows:
            let h = (vf.height - g * CGFloat(t + 1)) / CGFloat(t)
            return (0..<t).map { CGRect(x: vf.minX + g, y: vf.maxY - g - CGFloat($0 + 1) * h - CGFloat($0) * g, width: vf.width - 2 * g, height: h) }
        case .side:
            switch t {
            case 2:
                let aw = vf.width - 2 * g
                let mw = (aw - g) * st.mainRatio.value, sw = aw - g - mw
                return [
                    CGRect(x: vf.minX + g, y: vf.minY + g, width: mw, height: vf.height - 2 * g),
                    CGRect(x: vf.minX + g + mw + g, y: vf.minY + g, width: sw, height: vf.height - 2 * g),
                ]
            default:
                // Side 3 = 主窗 + 右侧 2 格；Side 4 = 主窗 + 右侧 3 格。
                return mainAndSideFrames(vf: vf, sideRows: max(1, t - 1), st: st)
            }
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
        let t = Swift.min(Swift.min(st.tileLimit, capacity(st.layout, sid: sid)), rootPool.count)
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
        let stacking = st.overflowMode == .stack
        if stacking, rootPool.count > t {
            for w in rootPool[t...] { stacks[active].append(w) }
        }
        if !roots.isEmpty {
            for w in windows {
                guard let host = stackedOnto[winKey(w)] else { continue }
                if let ti = stacks.firstIndex(where: { $0.contains { winKey($0) == host } }) {
                    stacks[ti].append(w)
                } else if stacking {
                    stacks[active].append(w)
                }
            }
        }
        return (stacks, active)
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
        for s in screens {
            tile(screen: s, windows: byScreen![screenID(s)] ?? [], refreshOverlays: false)
        }
        refreshGrips()
        refreshDimLayers()
        refreshHighlights()
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
    func giveWayFrames(frames: [CGRect], stacks: [[WinInfo]], tops: [WinInfo], minSizes: [String: [CGFloat]]) -> [CGRect] {
        var out = frames
        func floorSize(_ i: Int) -> CGSize {
            if let bid = bundleID(for: tops[i].pid), let a = minSizes[bid], a.count == 2 {
                return CGSize(width: a[0], height: a[1])
            }
            return CGSize(width: 160, height: 120)
        }
        for i in out.indices {
            guard let bid = bundleID(for: tops[i].pid), let a = minSizes[bid], a.count == 2 else { continue }
            var dw = max(0, a[0] - out[i].width)
            var dh = max(0, a[1] - out[i].height)
            if dw <= 0 && dh <= 0 { continue }
            if dw > 0 {
                for j in out.indices where j != i {
                    if dw <= 0 { break }
                    let overlap = min(out[i].maxY, out[j].maxY) - max(out[i].minY, out[j].minY)
                    guard overlap > 20 else { continue }
                    if abs(out[j].minX - out[i].maxX) < 1.5 {
                        let take = min(dw, max(0, out[j].width - floorSize(j).width))
                        if take > 0 { out[j].origin.x += take; out[j].size.width -= take; out[i].size.width += take; dw -= take }
                    } else if abs(out[j].maxX - out[i].minX) < 1.5 {
                        let take = min(dw, max(0, out[j].width - floorSize(j).width))
                        if take > 0 { out[j].size.width -= take; out[i].origin.x -= take; out[i].size.width += take; dw -= take }
                    }
                }
            }
            if dh > 0 {
                for j in out.indices where j != i {
                    if dh <= 0 { break }
                    let overlap = min(out[i].maxX, out[j].maxX) - max(out[i].minX, out[j].minX)
                    guard overlap > 20 else { continue }
                    if abs(out[j].minY - out[i].maxY) < 1.5 {
                        let take = min(dh, max(0, out[j].height - floorSize(j).height))
                        if take > 0 { out[j].origin.y += take; out[j].size.height -= take; out[i].size.height += take; dh -= take }
                    } else if abs(out[j].maxY - out[i].minY) < 1.5 {
                        let take = min(dh, max(0, out[j].height - floorSize(j).height))
                        if take > 0 { out[j].size.height -= take; out[i].origin.y -= take; out[i].size.height += take; dh -= take }
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
        // 居中浮动回位：空位出现时，居中浮动窗口按浮动顺序自动回到平铺
        if st.overflowMode == .floatMiddle, !middleFloatedKeys.isEmpty {
            let live = collectWindows(includeFloated: true).filter {
                middleFloatedKeys.contains(winKey($0)) && screenID(screenForFrame($0.frame)) == sid
            }
            let ordered = middleFloatOrder.filter { k in live.contains(where: { winKey($0) == k }) }
                + live.map { winKey($0) }.filter { !middleFloatOrder.contains($0) }
            for key in ordered {
                guard windows.count < min(st.tileLimit, capacity(st.layout, sid: sid)) else { break }
                guard let w = live.first(where: { winKey($0) == key }) else { continue }
                middleFloatedKeys.remove(key)
                middleFloatOrder.removeAll { $0 == key }
                windows.append(w)
                log("middle-floated returned: \(w.appName)")
            }
        }
        guard !windows.isEmpty else {
            lastTilesByScreen[sid] = []
            if refreshOverlays { refreshGrips(); refreshDimLayers(); refreshHighlights(); refreshDotHandles(); refreshStackMarkers() }
            return
        }
        let vf = screen.visibleFrame
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
        let (stacks, origActive) = computeTiles(windows: windows, st: st, sid: sid)
        // 堆叠产生时提示一次（从无堆叠变为有堆叠才弹，不刷屏）
        let hasStack = stacks.contains { $0.count > 1 }
        if hasStack, lastStackByScreen[sid] != true {
            showToast("已堆进这块磁贴", detail: "点磁贴上方的握把切换。", on: screen)
        }
        lastStackByScreen[sid] = hasStack
        let origFrames = applySplitOverrides(frames: tileFrames(count: stacks.count, vf: vf, st: st), tileCount: stacks.count, vf: vf, st: st, sid: sid)
        // 最小尺寸先让位（调分隔线从相邻磁贴匀空间），实在放不下
        // 才整栈退出网格、栈顶居中浮动；每轮至少退出一栈，循环必收敛
        let minSizes = learnedMinSizes()
        let activeTopKey = stacks.isEmpty ? "" : winKey(stacks[origActive][min(stackTops[stackTopKey(sid, origActive)] ?? 0, stacks[origActive].count - 1)])
        var remaining: [(orig: Int, stack: [WinInfo])] = stacks.enumerated().map { ($0.offset, $0.element) }
        var minFloatTops: [(win: WinInfo, min: CGSize)] = []
        var frames: [CGRect] = origFrames
        var firstPass = true
        while !remaining.isEmpty {
            let curFrames = firstPass ? origFrames : tileFrames(count: remaining.count, vf: vf, st: st)
            firstPass = false
            let tops = remaining.map { $0.stack[min(stackTops[stackTopKey(sid, $0.orig)] ?? 0, $0.stack.count - 1)] }
            let adj = giveWayFrames(frames: curFrames, stacks: remaining.map { $0.stack }, tops: tops, minSizes: minSizes)
            var fit: [(orig: Int, stack: [WinInfo])] = []
            var violated = false
            for (j, r) in remaining.enumerated() {
                let top = tops[j]
                if let bid = bundleID(for: top.pid), let a = minSizes[bid], a.count == 2,
                   (adj[j].width < a[0] - 4 || adj[j].height < a[1] - 4) {
                    violated = true
                    minFloatTops.append((top, CGSize(width: a[0], height: a[1])))
                    for w in r.stack { minSizeFloatedKeys.insert(winKey(w)) }
                } else { fit.append(r) }
            }
            if !violated {
                frames = adj
                break
            }
            remaining = fit
            if remaining.isEmpty { frames = []; break }
        }
        let fitStacks = remaining.map { $0.stack }
        // stackTops 重映射：只在有整栈退出时做（无退出时保持原样）
        if !minFloatTops.isEmpty {
            var remapped: [String: Int] = [:]
            for (newIdx, r) in remaining.enumerated() {
                if let v = stackTops[stackTopKey(sid, r.orig)] {
                    remapped[stackTopKey(sid, newIdx)] = min(v, r.stack.count - 1)
                }
            }
            stackTops = stackTops.filter { !$0.key.hasPrefix("\(sid):") }
            for (k, v) in remapped { stackTops[k] = v }
            log("min-size floated: \(minFloatTops.map { $0.win.appName }.joined(separator: ","))")
        }
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
        let animateMoves = draggingDividerID == nil
        for (i, stack) in fitStacks.enumerated() {
            for w in stack {
                let target = frames[i]
                let preSize = getSize(w.element)
                let key = winKey(w)
                placeFrame(w.element, target, key: key, animated: animateMoves, learnBid: bundleID(for: w.pid), learnName: w.appName, preSize: preSize)
                if lastPlacedFrames[key] != frames[i] {
                    lastPlacedFrames[key] = frames[i]
                }
            }
        }
        // C2：最小尺寸居中浮动（按学到的最小尺寸，超屏则 clamp 到 visibleFrame）
        for (w, mn) in minFloatTops {
            let fw = min(mn.width, vf.width), fh = min(mn.height, vf.height)
            let fx = vf.midX - fw / 2, fy = vf.midY - fh / 2
            placeFrame(w.element, CGRect(x: fx, y: fy, width: fw, height: fh), key: winKey(w), animated: animateMoves)
        }
        // B 批：居中浮动模式——超量窗口不进堆叠，改为居中偏右的浮动小窗口，
        // 压在布局之上，平铺布局本身不重排；已浮动的窗口下次 tick 不再进集合
        var middleCount = 0
        if st.overflowMode == .floatMiddle {
            let ordered = orderedWindows(windows)
            let placed = Set(fitStacks.flatMap { $0.map { winKey($0) } })
            let extras = ordered.filter { !placed.contains(winKey($0)) && !minSizeFloatedKeys.contains(winKey($0)) }
            if !extras.isEmpty {
                let fw = vf.width * 0.45, fh = vf.height * 0.6
                let fx = vf.midX - fw / 2
                let fy = vf.midY - fh / 2
                for w in extras {
                    middleFloatedKeys.insert(winKey(w))
                    if !middleFloatOrder.contains(winKey(w)) { middleFloatOrder.append(winKey(w)) }
                    placeFrame(w.element, CGRect(x: fx, y: fy, width: fw, height: fh), key: winKey(w), animated: animateMoves)
                    middleCount += 1
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
            let midSuffix = (st.overflowMode == .floatMiddle && middleCount > 0) ? " middleFloated=\(middleCount)" : ""
            let minSuffix = minFloatTops.isEmpty ? "" : " minFloated=\(minFloatTops.count)"
            log("tiled screen=\(screenName(screen)) \(windows.count) windows layout=\(st.layout.rawValue) limit=\(st.tileLimit) tiles=\(fitStacks.count) active=\(active) main=\(st.mainRatio.rawValue) gap=\(Int(st.gap))\(midSuffix)\(minSuffix) \(tileDesc)")
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
        let learnBid: String?
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
        setSize(el, frame.size)
        setPosition(el, CGPoint(x: frame.minX, y: mainHeight() - frame.maxY))
    }

    func inFlightFrame(key: String) -> CGRect? {
        guard let m = frameMotions[key] else { return nil }
        let t = CGFloat((CACurrentMediaTime() - m.start) / m.duration)
        if t >= 1 { return m.to }
        return lerpRect(m.from, m.to, springUnit(max(0, t)))
    }

    func noteShrink(bid: String, name: String, pre: CGSize, target: CGSize, post: CGSize?) {
        if let post,
           pre.width >= target.width - 4, pre.height >= target.height - 4,
           (post.width < target.width - 4 || post.height < target.height - 4) {
            shrinkFailures[bid, default: 0] += 1
            if shrinkFailures[bid]! >= 2 {
                setLearnedMinSize(bid: bid, size: post)
                shrinkFailures[bid] = 0
                log("min-size learned: \(name) \(Int(post.width))x\(Int(post.height))")
            }
        } else if post != nil {
            shrinkFailures[bid] = 0
        }
    }

    /// 把一扇窗送到 target。animated 时从当前（或飞行中）帧起跳，同一目的地不重开弹簧。
    /// 分隔线拖动传 animated: false，手跟着走。
    func placeFrame(_ el: AXUIElement, _ target: CGRect, key: String, animated: Bool, learnBid: String? = nil, learnName: String = "", preSize: CGSize? = nil) {
        if animated, let existing = frameMotions[key], framesClose(existing.to, target) {
            return
        }
        let from = inFlightFrame(key: key) ?? getFrame(el, screenHeight: mainHeight()) ?? target
        if !animated || framesClose(from, target) {
            frameMotions.removeValue(forKey: key)
            applyAXFrame(el, target)
            if let bid = learnBid, let pre = preSize {
                noteShrink(bid: bid, name: learnName, pre: pre, target: target, post: getSize(el))
            }
            stopMotionTimerIfIdle()
            return
        }
        frameMotions[key] = FrameMotion(
            element: el, key: key, from: from, to: target,
            start: CACurrentMediaTime(), duration: 0.5,
            preSize: preSize, learnBid: learnBid, learnName: learnName
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
                if let bid = m.learnBid, let pre = m.preSize {
                    noteShrink(bid: bid, name: m.learnName, pre: pre, target: m.to, post: getSize(m.element))
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
            refreshDimLayers()
            refreshHighlights()
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
            refreshDimLayers()
            refreshHighlights()
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
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
        }
    }

    func setSize(_ el: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
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

    // C2：最小尺寸学习数据（UserDefaults，bundle ID 不变则换二进制不丢数）
    func learnedMinSizes() -> [String: [CGFloat]] {
        UserDefaults.standard.dictionary(forKey: "minSizes") as? [String: [CGFloat]] ?? [:]
    }

    func setLearnedMinSize(bid: String, size: CGSize) {
        var d = learnedMinSizes()
        d[bid] = [size.width, size.height]
        UserDefaults.standard.set(d, forKey: "minSizes")
    }

    func forgetLearnedMinSize(bid: String) {
        var d = learnedMinSizes()
        d.removeValue(forKey: bid)
        UserDefaults.standard.set(d, forKey: "minSizes")
    }

    // MARK: - 可拖分隔线

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
    func applySplitOverrides(frames: [CGRect], tileCount: Int, vf: CGRect, st: ScreenSettings, sid: CGDirectDisplayID) -> [CGRect] {
        guard !splitOverrides.isEmpty, !frames.isEmpty else { return frames }
        let g = effectiveGapFor(st)
        let dividers = deriveDividers(frames: frames, gap: g, sid: sid)
        var out = frames
        for d in dividers {
            let key = "\(sid)-\(st.layout.rawValue)-\(tileCount)-\(d.id)"
            guard let f = splitOverrides[key] ?? splitOverrides["\(st.layout.rawValue)-\(tileCount)-\(d.id)"] else { continue }
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
        guard AXIsProcessTrusted(), autoTile, !focusMode, !cleanSpaceOn else {
            hideGrips()
            return
        }
        guard draggingDividerID == nil else { return }  // 拖动中不重建手柄
        var seen: Set<String> = []
        for (sid, tiles) in lastTilesByScreen where !tiles.isEmpty {
            guard let screen = NSScreen.screens.first(where: { screenID($0) == sid }) else { continue }
            let st = settingsFor(screen)
            let frames = tiles.map { $0.frame }
            let dividers = deriveDividers(frames: frames, gap: effectiveGapFor(st), sid: sid)
            for d in dividers {
                let key = "\(sid)-\(d.id)"
                seen.insert(key)
                let thickness = max(effectiveGapFor(st), 8)
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
                            let clamped = min(max(value, dd.minCenter), dd.maxCenter)
                            let f = dd.vertical
                                ? (clamped - vf.minX) / vf.width
                                : (clamped - vf.minY) / vf.height
                            let tileCount = self.lastTilesByScreen[dd.screenID]?.count ?? 0
                            self.splitOverrides["\(dd.screenID)-\(self.settingsFor(scr).layout.rawValue)-\(tileCount)-\(dd.id)"] = f
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

    // MARK: - 提示条（底部偏下，非粘滞的约 2.5 秒后消失）

    var toastPanel: NSPanel?
    var toastWork: DispatchWorkItem?
    var toastIsSticky = false

    func showToast(_ title: String, detail: String? = nil, sticky: Bool = false, on screen: NSScreen? = nil) {
        // Focus / Present 的提示要留到退出。这期间的短提示不覆盖它。
        if toastIsSticky && !sticky { return }
        toastWork?.cancel()
        toastIsSticky = sticky
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
        toastIsSticky = false
        toastPanel?.orderOut(nil)
    }

    // MARK: - 堆叠握把与浮层（活动磁贴不画常驻圆点，操作从窗口上沿悬停条进入）

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
        guard AXIsProcessTrusted(), autoTile, !focusMode, !cleanSpaceOn else {
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
        let actRow = NSStackView()
        actRow.orientation = .horizontal
        actRow.spacing = 8
        let primBtn = NSButton(title: "Make primary", target: self, action: #selector(stackPanelPrimary(_:)))
        let focBtn = NSButton(title: "Focus", target: self, action: #selector(stackPanelFocus(_:)))
        let floBtn = NSButton(title: "Float", target: self, action: #selector(stackPanelFloat(_:)))
        for b in [primBtn, focBtn, floBtn] { b.bezelStyle = .inline; actRow.addArrangedSubview(b) }
        doc.addArrangedSubview(actRow)
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

    func stackPanelTop() -> WinInfo? {
        guard let tiles = lastTilesByScreen[stackPanelSid], stackPanelTile < tiles.count else { return nil }
        let stack = tiles[stackPanelTile].stack
        guard !stack.isEmpty else { return nil }
        return stack[min(stackTops[stackTopKey(stackPanelSid, stackPanelTile)] ?? 0, stack.count - 1)]
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

    @objc func stackPanelPrimary(_ sender: NSButton) {
        guard let w = stackPanelTop() else { closeStackPanel(); return }
        let key = winKey(w)
        let screen = screenForFrame(w.frame)
        let (stacks, _) = computeTiles(windows: collectWindows(on: screen), st: settingsFor(screen), sid: screenID(screen))
        if let first = stacks.first?.first, winKey(first) != key {
            primaryKey = key
            log("stack panel primary -> \(w.appName)")
        }
        closeStackPanel()
        forceTile()
        refreshPanel()
    }

    @objc func stackPanelFocus(_ sender: NSButton) {
        guard let w = stackPanelTop() else { closeStackPanel(); return }
        closeStackPanel()
        if focusMode { disableFocus(); forceTile() } else { enableFocus(targetKey: winKey(w)) }
        refreshPanel()
    }

    @objc func stackPanelFloat(_ sender: NSButton) {
        guard let w = stackPanelTop() else { closeStackPanel(); return }
        floatedKeys.insert(winKey(w))
        log("stack panel float: \(w.appName)")
        closeStackPanel()
        forceTile()
        refreshPanel()
    }

    // MARK: - 悬停条（轮询鼠标位置）

    var hoverSid: CGDirectDisplayID = 0
    var hoverTile = 0
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

    func hoverChip(_ title: String, tag: Int, action: Selector, emphasized: Bool) -> NSButton {
        let font = NSFont.systemFont(ofSize: 11, weight: emphasized ? .semibold : .regular)
        let b = NSButton(title: title, target: self, action: action)
        b.tag = tag
        b.font = font
        b.isBordered = false
        b.bezelStyle = .inline
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
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
        hoverSid = sid
        hoverTile = tileIndex
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
        let primary = hoverChip("Primary", tag: 0, action: #selector(hoverPrimary(_:)), emphasized: false)
        let (stacks, _) = computeTiles(windows: collectWindows(on: screen), st: settingsFor(screen), sid: sid)
        let isPrimary = stacks.first?.first.map { winKey($0) == winKey(tile.stack[topIdx]) } ?? false
        primary.isEnabled = !isPrimary
        hoverPrimaryButton = primary
        row.addArrangedSubview(primary)
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
        var y = tile.frame.maxY + 8
        if y + barH > screen.frame.maxY - 2 { y = tile.frame.maxY - barH - 4 }
        hoverPanel.setFrame(NSRect(x: x, y: y, width: barW, height: barH), display: true)
        hoverPanel.orderFront(nil)
        hoverKey = winKey(tile.stack[topIdx])
        hoverTileFrame = tile.frame
    }

    func hideHoverBar() {
        hoverPanel?.orderOut(nil)
        hoverKey = nil
    }

    func tileUnderPointer(_ m: CGPoint) -> (sid: CGDirectDisplayID, index: Int, tile: (stack: [WinInfo], frame: CGRect, top: WinInfo), screen: NSScreen)? {
        // 上沿热区会伸进上面那块磁贴几磅。多块同时命中时，取离自己上沿最近的那块，
        // 不要跟着字典顺序碰运气。Hover focus 的窗体命中只在没有上沿热区时才用。
        var best: (sid: CGDirectDisplayID, index: Int, tile: (stack: [WinInfo], frame: CGRect, top: WinInfo), screen: NSScreen)?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (sid, tiles) in lastTilesByScreen {
            guard let screen = NSScreen.screens.first(where: { screenID($0) == sid }) else { continue }
            for (i, t) in tiles.enumerated() {
                let zone = CGRect(x: t.frame.minX, y: t.frame.maxY - 20, width: t.frame.width, height: 36)
                let inZone = zone.contains(m)
                let inBody = hoverActivate && t.frame.contains(m)
                guard inZone || inBody else { continue }
                let score = inZone ? abs(m.y - t.frame.maxY) : 10_000 + abs(m.y - t.frame.midY)
                if score < bestScore {
                    bestScore = score
                    best = (sid, i, t, screen)
                }
            }
        }
        return best
    }

    func updateHover() {
        guard hoverPanel != nil else { return }
        let m = NSEvent.mouseLocation
        if hoverActivate, AXIsProcessTrusted(), autoTile, !focusMode, !cleanSpaceOn, draggingDividerID == nil,
           dragState == nil, NSEvent.pressedMouseButtons == 0 {
            if let hit = tileUnderPointer(m), hit.tile.frame.contains(m) {
                let key = winKey(hit.tile.top)
                if hoverActivateKey != key {
                    hoverActivateKey = key
                    hoverActivateSince = CACurrentMediaTime()
                } else if CACurrentMediaTime() - hoverActivateSince > 0.4 {
                    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    if hit.tile.top.pid != front {
                        AXUIElementPerformAction(hit.tile.top.element, kAXRaiseAction as CFString)
                        NSRunningApplication(processIdentifier: hit.tile.top.pid)?.activate()
                        hoverActivateSince = CACurrentMediaTime() + 10
                    }
                }
            } else {
                hoverActivateKey = nil
            }
        }
        guard hoverBarOn, AXIsProcessTrusted(), autoTile, !focusMode, !cleanSpaceOn, draggingDividerID == nil,
              panelPopover == nil || !panelPopover.isShown else {
            hideHoverBar()
            hoverZoneID = nil
            return
        }
        if hoverKey != nil {
            let barFrame = hoverPanel.frame.insetBy(dx: -8, dy: -8)
            let stillOnTile = tileUnderPointer(m).map { "\($0.sid):\($0.index)" } == "\(hoverSid):\(hoverTile)"
            if barFrame.contains(m) || stillOnTile { return }
            hideHoverBar()
            hoverZoneID = nil
            return
        }
        guard let hit = tileUnderPointer(m) else {
            hoverZoneID = nil
            return
        }
        let zone = CGRect(x: hit.tile.frame.minX, y: hit.tile.frame.maxY - 20, width: hit.tile.frame.width, height: 36)
        guard zone.contains(m) else { return }
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

    // 悬停条点击时按 pid+标题重找窗口；找不到了就收条并记日志，不对错窗口动手
    func resolveHoverTarget() -> WinInfo? {
        guard let key = hoverKey else { return nil }
        let windows = collectWindows()
        guard let w = windows.first(where: { winKey($0) == key }) else {
            hideHoverBar()
            log("hover target gone")
            return nil
        }
        return w
    }

    @objc func hoverPrimary(_ sender: NSButton) {
        guard let w = resolveHoverTarget() else { return }
        let key = winKey(w)
        let screen = screenForFrame(w.frame)
        let (stacks, _) = computeTiles(windows: collectWindows(on: screen), st: settingsFor(screen), sid: screenID(screen))
        if let first = stacks.first?.first, winKey(first) == key {
            log("hover primary: already primary (\(w.appName))")
            return
        }
        stackedOnto.removeValue(forKey: key)
        primaryKey = key
        log("hover primary -> \(w.appName)")
        forceTile()
        refreshPanel()
    }

    @objc func hoverFocus(_ sender: NSButton) {
        if focusMode {
            disableFocus()
            forceTile()
        } else {
            guard let w = resolveHoverTarget() else { return }
            enableFocus(targetKey: winKey(w))
        }
        hideHoverBar()
        refreshPanel()
    }

    @objc func hoverFloat(_ sender: NSButton) {
        guard let w = resolveHoverTarget() else { return }
        floatedKeys.insert(winKey(w))
        log("hover float: \(w.appName)")
        hideHoverBar()
        forceTile()
        refreshPanel()
    }

    // MARK: - Focus 模式

    func enableFocus(targetKey: String? = nil) {
        if cleanSpaceOn { disableCleanSpace() }  // 与 Present 互斥
        guard AXIsProcessTrusted() else {
            log("focus skipped: not trusted")
            return
        }
        // C 批：Focus 只针对目标/前台窗口所在屏，别屏的窗口不动、继续平铺
        let all = collectWindows()
        guard !all.isEmpty else {
            log("focus skipped: no windows")
            return
        }
        var frontIdxAll: Int? = nil
        if let tk = targetKey {
            frontIdxAll = all.firstIndex(where: { winKey($0) == tk })
            guard frontIdxAll != nil else {
                log("focus skipped: target window gone")
                return
            }
        } else {
            frontIdxAll = frontmostIndex(windows: all)
        }
        let frontAll = all[min(frontIdxAll ?? 0, all.count - 1)]
        let screen = screenForFrame(frontAll.frame)
        let windows = collectWindows(on: screen)
        guard !windows.isEmpty else {
            log("focus skipped: no windows on this screen")
            return
        }
        focusSaved = windows.compactMap { w -> (AXUIElement, CGRect, String)? in
            let key = winKey(w)
            let f = lastPlacedFrames[key] ?? frameMotions[key]?.to ?? getFrame(w.element, screenHeight: mainHeight())
            guard let f else { return nil }
            return (w.element, f, key)
        }
        let frontIdx = windows.firstIndex(where: { winKey($0) == winKey(frontAll) }) ?? 0
        let front = windows[min(frontIdx, windows.count - 1)]
        let vf = screen.visibleFrame
        focusMode = true
        AXUIElementPerformAction(front.element, kAXRaiseAction as CFString)
        // 其余窗口留在原磁贴上，被放大的活动窗口盖住；还原时它们的 frame 没被动过。
        placeFrame(front.element, vf, key: winKey(front), animated: true)
        log("focus on: front=\(front.appName)")
        hideGrips()
        hideHoverBar()
        hideDotHandles()
        hideStackMarkers()
        closeStackPanel()
        removeDimLayers()
        hideHighlights()
        showToast("Focus", detail: "再点一次 Focus，窗口回到进入前的位置。", sticky: true, on: screen)
    }

    func disableFocus() {
        let saved = focusSaved
        focusSaved = []
        focusMode = false
        tileHoldUntil = CACurrentMediaTime() + 0.6
        var restored = 0
        for (el, f, key) in saved {
            placeFrame(el, f, key: key, animated: true)
            restored += 1
        }
        // 恢复是 best-effort：Focus 期间已关闭的窗口 AX 设置会静默失败
        log("focus off: restored frames for \(restored) windows (best-effort)")
        hideToast()  // Focus 退出时直接撤掉 pill，不新弹
        refreshDimLayers()  // 退出后 Dim 暗色层按需回来
        refreshHighlights()  // v9：退出后高亮按当前模式恢复
        refreshDotHandles()
        refreshStackMarkers()
    }

    // MARK: - 悬停激活 / Dim / Present

    func setNoPeek(_ on: Bool) {
        noPeekOn = on
        if on {
            refreshDimLayers()
            for (_, p) in dimPanels {
                p.alphaValue = 0
                fadeWindow(p, to: 1, duration: 0.35, done: nil)
            }
            showToast("减弱其他", detail: "非活动窗口变暗。再点一次关闭。")
            log("dim on (level=\(dimLevel))")
        } else {
            let panels = Array(dimPanels.values)
            for p in panels { fadeWindow(p, to: 0, duration: 0.25, done: nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                guard let self, !self.noPeekOn else { return }
                self.removeDimLayers()
            }
            showToast("减弱其他已关闭")
            log("dim off")
        }
    }

    // 暗色层按磁贴盖（同磁贴窗口共用一个 frame，视觉上与按窗口盖等价）；
    // 层级用 floating + 穿透点击：只变暗、不拦截操作；对话框等浮动窗若压在暗色区
    // 上会被一并罩暗，属原型级视觉折中
    func dimContent() -> NSView {
        // Dim 固定 0.5、Blur 固定关：纯黑半透明层
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(dimLevel).cgColor
        return v
    }

    func refreshDimLayers() {
        guard noPeekOn, AXIsProcessTrusted(), autoTile, !focusMode, !cleanSpaceOn else {
            let fading = Set(opacityFades.compactMap { $0.window.map { ObjectIdentifier($0) } })
            if dimPanels.values.contains(where: { fading.contains(ObjectIdentifier($0)) }) { return }
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
                    p.setFrame(t.frame, display: true)
                    p.contentView = dimContent()
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

    // MARK: - v9 高亮系统（自有穿透悬浮窗，画在间隙里，不遮窗口内容）

    func highlightColorValue(_ c: HighlightColor) -> NSColor {
        switch c {
        case .accent: return .controlAccentColor
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .orange: return .systemOrange
        case .green: return .systemGreen
        case .graphite: return .systemGray
        }
    }

    func refreshHighlights() {
        guard highlightMode != .none, AXIsProcessTrusted(), autoTile,
              !focusMode, !cleanSpaceOn else {
            hideHighlights()
            return
        }
        var wanted: [String: CGRect] = [:]
        for (sid, tiles) in lastTilesByScreen where !tiles.isEmpty {
            let active = min(lastActiveTileByScreen[sid] ?? 0, tiles.count - 1)
            for (i, t) in tiles.enumerated() {
                let show: Bool
                switch highlightMode {
                case .borderAll: show = true
                case .borderActive, .glow: show = (i == active)
                case .none: show = false
                }
                guard show else { continue }
                // 边框面板比磁贴每边大 thickness，描边居中正好落在间隙里；
                // 光晕面板比磁贴每边大 8，阴影向间隙扩散
                wanted["\(sid):\(i)"] = highlightMode == .glow
                    ? t.frame.insetBy(dx: -8, dy: -8)
                    : t.frame.insetBy(dx: -highlightThickness, dy: -highlightThickness)
            }
        }
        for (i, frame) in wanted {
            if let p = highlightPanels[i] {
                if p.frame != frame { p.setFrame(frame, display: true) }
                if let v = p.contentView as? HighlightBorderView {
                    v.strokeColor = highlightColorValue(highlightColor)
                    v.thickness = highlightThickness
                    v.glow = (highlightMode == .glow)
                    v.needsDisplay = true
                }
                if !p.isVisible { p.orderFront(nil) }
            } else {
                let view = HighlightBorderView(frame: NSRect(origin: .zero, size: frame.size))
                view.strokeColor = highlightColorValue(highlightColor)
                view.thickness = highlightThickness
                view.glow = (highlightMode == .glow)
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

    /// 停在所有屏幕包围盒的下方，竖着叠两块屏时也不会落到下面那块上。
    func parkedBelowAllScreens(size: CGSize, near screen: NSScreen) -> CGRect {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let x = screen.frame.midX - width / 2
        let y = union.minY - height - 80
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func cleanBgColor() -> NSColor {
        // Present 的桌面底色固定为深灰，不再分档。
        return NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    }

    func setCleanSpace(_ on: Bool) {
        if on { enableCleanSpace() } else { disableCleanSpace() }
    }

    func enableCleanSpace() {
        guard !cleanSpaceOn else { return }
        if focusMode { disableFocus() }  // v8：与 Focus 互斥
        guard AXIsProcessTrusted() else {
            log("cleanSpace skipped: not trusted")
            return
        }
        // Present 只针对前台窗口所在屏，别屏的窗口不动
        let all = collectWindows()
        guard !all.isEmpty else {
            log("cleanSpace skipped: no windows")
            return
        }
        let frontAll = all[min(frontmostIndex(windows: all) ?? 0, all.count - 1)]
        let screen = screenForFrame(frontAll.frame)
        let windows = collectWindows(on: screen)
        guard !windows.isEmpty else {
            log("cleanSpace skipped: no windows on this screen")
            return
        }
        cleanSaved = windows.compactMap { w -> (AXUIElement, CGRect, String)? in
            let key = winKey(w)
            let f = lastPlacedFrames[key] ?? frameMotions[key]?.to ?? getFrame(w.element, screenHeight: mainHeight())
            guard let f else { return nil }
            return (w.element, f, key)
        }
        let frontKey = winKey(frontAll)
        let front = windows.first(where: { winKey($0) == frontKey }) ?? windows[0]
        let vf = screen.visibleFrame
        cleanSpaceOn = true
        let margin: CGFloat = 48
        let src = cleanSaved.first(where: { $0.key == frontKey })?.frame ?? front.frame
        let fw = min(src.width, max(200, vf.width - margin * 2))
        let fh = min(src.height, max(160, vf.height - margin * 2))
        let centered = CGRect(x: vf.midX - fw / 2, y: vf.midY - fh / 2, width: fw, height: fh)
        AXUIElementPerformAction(front.element, kAXRaiseAction as CFString)
        placeFrame(front.element, centered, key: frontKey, animated: true)
        for w in windows where winKey(w) != frontKey {
            let key = winKey(w)
            let cur = cleanSaved.first(where: { $0.key == key })?.frame ?? w.frame
            placeFrame(w.element, parkedBelowAllScreens(size: cur.size, near: screen), key: key, animated: true)
        }
        // 桌面层级盖住壁纸，Dock 和菜单栏在更高层，仍然可见。
        if cleanBgPanel == nil {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = true
            let v = NSView()
            v.wantsLayer = true
            p.contentView = v
            cleanBgPanel = p
        }
        cleanBgPanel?.contentView?.wantsLayer = true
        cleanBgPanel?.contentView?.layer?.backgroundColor = cleanBgColor().cgColor
        cleanBgPanel?.setFrame(screen.frame, display: true)
        cleanBgPanel?.alphaValue = 0
        cleanBgPanel?.orderFront(nil)
        if let bg = cleanBgPanel { fadeWindow(bg, to: 1, duration: 0.35, done: nil) }
        removeDimLayers()
        hideGrips()
        hideHoverBar()
        hideDotHandles()
        hideStackMarkers()
        closeStackPanel()
        hideHighlights()
        showToast("演示", detail: "只留当前窗口在深色桌面中央。再点一次关闭。", sticky: true, on: screen)
        log("present on: front=\(front.appName), centered")
    }

    func disableCleanSpace() {
        let saved = cleanSaved
        cleanSaved = []
        cleanSpaceOn = false
        tileHoldUntil = CACurrentMediaTime() + 0.6
        var restored = 0
        for (el, f, key) in saved {
            placeFrame(el, f, key: key, animated: true)
            restored += 1
        }
        if let bg = cleanBgPanel {
            fadeWindow(bg, to: 0, duration: 0.25) { [weak bg] in bg?.orderOut(nil); bg?.alphaValue = 1 }
        }
        log("present off: restored frames for \(restored) windows (best-effort)")
        hideToast()
        refreshDimLayers()
        refreshHighlights()  // v9：退出后高亮按当前模式恢复
        refreshDotHandles()
        refreshStackMarkers()
    }

    @objc func panelToggleNoPeek(_ sender: NSSwitch) {
        setNoPeek(sender.state == .on)
        refreshPanel()
    }

    @objc func panelToggleCleanSpace(_ sender: NSSwitch) {
        setCleanSpace(sender.state == .on)
        refreshPanel()
    }

    // MARK: - 鼠标重排（会话事件 tap，只订阅鼠标）

    /// 创建过滤型事件 tap，识别按住 ⌘ / ⌃⌘ 的窗口拖动。
    /// 掩码只有左键按下、拖动、松开。
    /// 创建失败只记一次：平铺本身靠辅助功能；稍后变为已允许时 tick 会再试。
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
    // 不能用 NSScreen.main：那是关键窗口所在屏，副屏上会把命中点算偏。
    func cocoaPoint(fromQuartz q: CGPoint) -> CGPoint? {
        guard let primary = NSScreen.screens.first else { return nil }
        return CGPoint(x: q.x, y: primary.frame.maxY - q.y)
    }

    // 拖动起点是否落在我们自己的交互窗上（面板、悬停条、分隔缝、握把、设置窗）。
    // 暗色层与高亮层穿透点击，落在它们上面仍视为落在下方磁贴上。
    func pointOnOwnInteractiveWindow(_ p: CGPoint) -> Bool {
        if panelPopover.isShown,
           let w = panelPopover.contentViewController?.view.window, w.frame.contains(p) { return true }
        if hoverPanel.isVisible, hoverPanel.frame.contains(p) { return true }
        for (_, g) in gripPanels where g.isVisible && g.frame.contains(p) { return true }
        for (_, d) in dotPanels where d.isVisible && d.frame.contains(p) { return true }
        for (_, m) in stackMarkerPanels where m.isVisible && m.frame.contains(p) { return true }
        if let sp = stackPanel, sp.isVisible, sp.frame.contains(p) { return true }
        if let s = settingsWindow, s.isVisible, s.frame.contains(p) { return true }
        return false
    }

    // mouseDown：⌘ 按下且落在某磁贴上 → 只记录待定拖动，不吞这次按下；
    // 只有鼠标实际移动超过约 3pt 才进入拖动模式，未拖动时按下/松手原样放行
    func dragMouseDown(_ event: CGEvent) -> Bool {
        guard AXIsProcessTrusted(), autoTile, !focusMode, !cleanSpaceOn else { return false }
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
        let frames = applySplitOverrides(frames: tileFrames(count: stacks.count, vf: vf, st: settingsFor(screen)), tileCount: stacks.count, vf: vf, st: settingsFor(screen), sid: sid)
        guard let src = frames.firstIndex(where: { $0.contains(p) }) else { return false }
        // ⌘ 交换；再按住 ⌃ 则加入堆叠。只认 control 与 command，不看 option。
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
        guard AXIsProcessTrusted(), !focusMode, !cleanSpaceOn else { return }
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
        guard AXIsProcessTrusted(), !focusMode, !cleanSpaceOn else { return }
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
// 系统停掉 tap 时重新打开，并取消进行中的手势，避免窗口停在半拖状态。
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
