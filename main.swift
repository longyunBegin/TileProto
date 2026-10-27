import AppKit
import ApplicationServices
import Darwin
import QuartzCore

// TileProto：菜单栏自动平铺。操作只在鼠标和菜单栏面板上。
// 原理：Accessibility API（AXUIElement）枚举窗口并改 frame。
//  1. 布局：Grid / Columns / Rows / Side，数量 1–4，主格份额与间距可调。
//     格子数 = min(窗口数, 上限, 4)。一格铺满工作区，不留边。
//  2. 放不进格子的窗口先并进装得下的格子；整屏都装不下才按最小尺寸居中浮动。
//     写入 AX 的帧不会超出该格，避免窗口从格子里探出去。
//  3. 窗口多于格子时堆进活动格子。橙色握把点按轮换；悬停条上层是芯片，
//     下层是 Primary / Focus / Float。没有快捷键键帽。
//     ⌃⌘ 拖到某格子上时，即使刚好满格也并进去，空出的格子收掉。
//  4. ⌘ 拖到另一格子：被拖窗口抬起跟手，目标格子略向内收，松手后两边滑到最终帧。
//     普通拖动松手弹回，并提示要按住 ⌘。
//  5. Focus 铺满后再点悬停条上的 Focus，按进入前的帧还原。
//     No peek 压暗其它格子。Clean Space 只留当前窗口居中。Borders 是细描边。
// 布局、Focus、弹回约 0.5 秒短弹簧。交换用无过冲的落定。拖分隔线跟手。

// _AXUIElementGetWindow 按窗口返回稳定的 CGWindowID。公开 AX 没有窗口号；
// 同进程多扇同名窗口若只用 pid|标题，Focus 快照会在重复键上崩溃。
private let axWindowNumberFn: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32)? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32).self)
}()

private func copyAXWindowID(_ element: AXUIElement) -> CGWindowID {
    guard let fn = axWindowNumberFn else { return 0 }
    var wid: CGWindowID = 0
    let err = fn(element, &wid)
    return err == 0 ? wid : 0
}

// 布局族。Grid：1 全屏、2 左右、3 一块大两块小、4 田字。Columns / Rows 是条带。
// Side：左侧主格，右侧把其余窗口上下叠起来。
enum LayoutKind: Int {
    case grid = 0
    case columns = 1
    case rows = 2
    case side = 3
}

// 已知最小尺寸比格子大过这个容差，才算装不下。4pt 以内当成取整误差，不并堆、不浮动。
let tileFitTolerance: CGFloat = 4
// 格子比这还小就提示屏幕装不下这一档数量。一格铺满可视区，不受这条限制。
let cellFloorW: CGFloat = 160
let cellFloorH: CGFloat = 100

func axisShortfall(_ need: CGFloat, _ slot: CGFloat, tolerance: CGFloat = tileFitTolerance) -> CGFloat {
    guard need > 1 else { return 0 }
    return max(0, need - slot - tolerance)
}

func slotShortfall(_ need: CGSize, _ slot: CGRect, tolerance: CGFloat = tileFitTolerance) -> CGFloat {
    max(axisShortfall(need.width, slot.width, tolerance: tolerance),
        axisShortfall(need.height, slot.height, tolerance: tolerance))
}

/// 提议帧收进 slot。最小尺寸比 slot 大过容差时返回 nil，调用方改为并堆或浮动，不能硬写一个会探出的帧。
func frameContained(in slot: CGRect, proposed: CGRect, minSize: CGSize, tolerance: CGFloat = tileFitTolerance) -> CGRect? {
    guard slot.width >= 1, slot.height >= 1 else { return nil }
    if axisShortfall(minSize.width, slot.width, tolerance: tolerance) > 0 { return nil }
    if axisShortfall(minSize.height, slot.height, tolerance: tolerance) > 0 { return nil }
    var f = proposed
    let minW = minSize.width > 1 ? min(minSize.width, slot.width) : 1
    let minH = minSize.height > 1 ? min(minSize.height, slot.height) : 1
    f.size.width = min(max(f.width, minW), slot.width)
    f.size.height = min(max(f.height, minH), slot.height)
    if f.maxX > slot.maxX { f.origin.x -= f.maxX - slot.maxX }
    if f.maxY > slot.maxY { f.origin.y -= f.maxY - slot.maxY }
    if f.minX < slot.minX { f.origin.x = slot.minX }
    if f.minY < slot.minY { f.origin.y = slot.minY }
    return f
}

func maxSlotShortfall(needs: [CGSize], groups: [[Int]], frames: [CGRect]) -> CGFloat {
    guard frames.count == groups.count else { return CGFloat.greatestFiniteMagnitude }
    var worst: CGFloat = 0
    for (gi, group) in groups.enumerated() {
        for id in group where needs.indices.contains(id) {
            worst = max(worst, slotShortfall(needs[id], frames[gi]))
        }
    }
    return worst
}

/// 把装不下的窗口并进其它格子。先挪超限的那一组；格子数量不变、格子仍然不够大时，
/// 再把整格并进邻居，从而减少格子。并到只剩一整屏仍装不下就列入 floated。
/// bound 把手动堆叠绑在一起：member → root，合并时整组跟着走。
func planTileFit(
    needs: [CGSize],
    groups: [[Int]],
    bound: [Int: Int],
    frames: ([[Int]]) -> [CGRect],
    maxSteps: Int = 8
) -> (groups: [[Int]], floated: [Int]) {
    var groups = groups
    var floated: [Int] = []
    func root(of id: Int) -> Int {
        var seen = Set<Int>()
        var cur = id
        while let next = bound[cur], needs.indices.contains(next), !seen.contains(next) {
            seen.insert(cur)
            cur = next
        }
        return cur
    }
    func component(_ id: Int, inside groups: [[Int]]) -> [Int] {
        let present = Set(groups.flatMap { $0 })
        let r = root(of: id)
        return present.filter { root(of: $0) == r }.sorted()
    }
    func relocated(_ ids: [Int], host: Int, groups: [[Int]]) -> [[Int]]? {
        let moveSet = Set(ids)
        guard let anchor = groups[host].first(where: { !moveSet.contains($0) }) else { return nil }
        var trial = groups
        for i in trial.indices {
            trial[i].removeAll { moveSet.contains($0) }
        }
        trial.removeAll { $0.isEmpty }
        guard let hostIndex = trial.firstIndex(where: { $0.contains(anchor) }) else { return nil }
        for id in ids where !trial[hostIndex].contains(id) {
            trial[hostIndex].append(id)
        }
        return trial
    }
    for _ in 0..<maxSteps {
        let current = frames(groups)
        guard current.count == groups.count else { break }
        var worstAmt: CGFloat = 0
        var worstGroup = -1
        var worstID = -1
        for (gi, group) in groups.enumerated() {
            for id in group where needs.indices.contains(id) {
                let short = slotShortfall(needs[id], current[gi])
                if short > worstAmt {
                    worstAmt = short
                    worstGroup = gi
                    worstID = id
                }
            }
        }
        if worstID < 0 { break }
        if groups.count <= 1 {
            floated.append(worstID)
            groups[worstGroup].removeAll { $0 == worstID }
            if groups[worstGroup].isEmpty { groups.remove(at: worstGroup) }
            continue
        }
        let moving = component(worstID, inside: groups)
        let whole = groups[worstGroup]
        var best: [[Int]]?
        var bestScore = worstAmt
        func consider(_ trial: [[Int]]?) {
            guard let trial else { return }
            let score = maxSlotShortfall(needs: needs, groups: trial, frames: frames(trial))
            let improves = score + 0.5 < bestScore
            let moreTiles = best.map { trial.count > $0.count } ?? false
            let keepsMoreTiles = moreTiles && score <= bestScore + 0.5 && score + 0.5 < worstAmt
            if improves || keepsMoreTiles {
                bestScore = score
                best = trial
            }
        }
        for host in groups.indices where host != worstGroup {
            consider(relocated(moving, host: host, groups: groups))
            if Set(whole) != Set(moving) {
                consider(relocated(whole, host: host, groups: groups))
            }
        }
        if let best {
            groups = best
        } else {
            floated.append(worstID)
            groups[worstGroup].removeAll { $0 == worstID }
            if groups[worstGroup].isEmpty { groups.remove(at: worstGroup) }
        }
    }
    return (groups, floated)
}

// 份额为 Half（0.5）时条带按份数等分，三列不会变成「第一列占一半」。
// 60% 与 2/3 才把第一格拉大，其余格子分剩下的宽度或高度。Side 的左格始终用原始份额。
func spanShare(count: Int, share: CGFloat) -> CGFloat {
    let n = max(count, 1)
    if abs(share - 0.5) < 0.021 { return 1 / CGFloat(n) }
    return min(max(share, 0.4), 0.75)
}

func columnFrames(count n: Int, vf: CGRect, gap g: CGFloat, share: CGFloat) -> [CGRect] {
    guard n > 1 else { return [vf] }
    let inner = vf.width - g * CGFloat(n + 1)
    guard inner > n else { return Array(repeating: vf, count: n) }
    let fraction = spanShare(count: n, share: share)
    let floor = min(120, inner / CGFloat(n))
    var primary = inner * fraction
    let restCount = CGFloat(n - 1)
    if primary > inner - floor * restCount { primary = inner - floor * restCount }
    if primary < floor { primary = floor }
    let rest = (inner - primary) / restCount
    let h = max(1, vf.height - 2 * g)
    var x = vf.minX + g
    var out: [CGRect] = []
    for i in 0..<n {
        let w = max(1, i == 0 ? primary : rest)
        out.append(CGRect(x: x, y: vf.minY + g, width: w, height: h))
        x += w + g
    }
    return out
}

func rowFrames(count n: Int, vf: CGRect, gap g: CGFloat, share: CGFloat) -> [CGRect] {
    guard n > 1 else { return [vf] }
    let inner = vf.height - g * CGFloat(n + 1)
    guard inner > n else { return Array(repeating: vf, count: n) }
    let fraction = spanShare(count: n, share: share)
    let floor = min(80, inner / CGFloat(n))
    var primary = inner * fraction
    let restCount = CGFloat(n - 1)
    if primary > inner - floor * restCount { primary = inner - floor * restCount }
    if primary < floor { primary = floor }
    let rest = (inner - primary) / restCount
    let w = max(1, vf.width - 2 * g)
    var y = vf.maxY - g
    var out: [CGRect] = []
    for i in 0..<n {
        let h = max(1, i == 0 ? primary : rest)
        y -= h
        out.append(CGRect(x: vf.minX + g, y: y, width: w, height: h))
        y -= g
    }
    return out
}

func sideFrames(count n: Int, vf: CGRect, gap g: CGFloat, share: CGFloat) -> [CGRect] {
    guard n > 1 else { return [vf] }
    let rows = n - 1
    let innerW = vf.width - 3 * g
    guard innerW > 2 else { return Array(repeating: vf, count: n) }
    let fraction = min(max(share, 0.4), 0.75)
    let floor = min(160, innerW / 2)
    var leftW = innerW * fraction
    if leftW > innerW - floor { leftW = innerW - floor }
    if leftW < floor { leftW = floor }
    let rightW = max(1, innerW - leftW)
    let left = CGRect(x: vf.minX + g, y: vf.minY + g, width: max(1, leftW), height: max(1, vf.height - 2 * g))
    let innerH = vf.height - g * CGFloat(rows + 1)
    let rowH = max(1, innerH / CGFloat(rows))
    var y = vf.maxY - g
    var out = [left]
    let rightX = vf.minX + g + left.width + g
    for _ in 0..<rows {
        y -= rowH
        out.append(CGRect(x: rightX, y: y, width: rightW, height: rowH))
        y -= g
    }
    return out
}

func gridQuadFrames(vf: CGRect, gap g: CGFloat, share: CGFloat) -> [CGRect] {
    let innerW = vf.width - 3 * g
    let innerH = vf.height - 3 * g
    guard innerW > 2, innerH > 2 else { return Array(repeating: vf, count: 4) }
    let fraction = min(max(share, 0.4), 0.75)
    let floorW = min(160, innerW / 2)
    let floorH = min(80, innerH / 2)
    var leftW = innerW * fraction
    if leftW > innerW - floorW { leftW = innerW - floorW }
    if leftW < floorW { leftW = floorW }
    let rightW = max(1, innerW - leftW)
    var topH = innerH * fraction
    if topH > innerH - floorH { topH = innerH - floorH }
    if topH < floorH { topH = floorH }
    let botH = max(1, innerH - topH)
    let x0 = vf.minX + g
    let x1 = x0 + leftW + g
    let yTop = vf.maxY - g - topH
    let yBot = vf.minY + g
    return [
        CGRect(x: x0, y: yTop, width: max(1, leftW), height: max(1, topH)),
        CGRect(x: x1, y: yTop, width: rightW, height: max(1, topH)),
        CGRect(x: x0, y: yBot, width: max(1, leftW), height: botH),
        CGRect(x: x1, y: yBot, width: rightW, height: botH),
    ]
}

func layoutFrames(count: Int, vf: CGRect, kind: LayoutKind, share: CGFloat, gap: CGFloat) -> [CGRect] {
    let n = min(max(count, 0), 4)
    guard n > 0 else { return [] }
    if n == 1 || vf.width < 2 || vf.height < 2 { return [vf] }
    let g = min(max(0, gap), min(vf.width, vf.height) * 0.2)
    switch kind {
    case .columns:
        return columnFrames(count: n, vf: vf, gap: g, share: share)
    case .rows:
        return rowFrames(count: n, vf: vf, gap: g, share: share)
    case .side:
        return sideFrames(count: n, vf: vf, gap: g, share: share)
    case .grid:
        // 三格是「一块大、两块小」，不是三条等分。四格才是田字。
        if n == 3 { return sideFrames(count: 3, vf: vf, gap: g, share: share) }
        if n == 4 { return gridQuadFrames(vf: vf, gap: g, share: share) }
        return columnFrames(count: n, vf: vf, gap: g, share: share)
    }
}

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
        layer?.borderWidth = isActiveTile ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
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
    override var intrinsicContentSize: NSSize { NSSize(width: 68, height: 78) }
    override func mouseDown(with event: NSEvent) {
        if !isDisabled { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 2, dy: 2)
        let bg = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.08) : NSColor.controlBackgroundColor
        bg.setFill()
        NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10).fill()
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
            let outline = NSBezierPath(roundedRect: card.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            outline.lineWidth = 1
            outline.stroke()
        }
        // 数字在底部标签里。上面画这一档数量对应的窗口排列，不再是空框。
        let area = NSRect(x: card.minX + 8, y: card.minY + 22, width: max(4, card.width - 16), height: max(4, card.height - 30))
        let fill = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.72) : NSColor.labelColor.withAlphaComponent(0.72)
        let header = isSelected ? NSColor.white.withAlphaComponent(0.55) : NSColor.controlBackgroundColor.withAlphaComponent(0.9)
        for r in rects {
            let x = area.minX + r.minX * area.width
            let w = max(3, r.width * area.width)
            let h = max(3, r.height * area.height)
            let y = area.minY + (1 - r.minY - r.height) * area.height
            let pane = NSRect(x: x, y: y, width: w, height: h)
            fill.setFill()
            NSBezierPath(roundedRect: pane, xRadius: 2.5, yRadius: 2.5).fill()
            if h > 8 {
                header.setFill()
                NSBezierPath(rect: NSRect(x: pane.minX + 1.5, y: pane.maxY - 3.5, width: max(1, pane.width - 3), height: 2)).fill()
            }
        }
    }
    private func updateStyle() {
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        labelField.font = .systemFont(ofSize: 12, weight: .semibold)
        labelField.textColor = isSelected ? NSColor.controlAccentColor : NSColor.labelColor
    }
}

// v9：高亮颜色板（面板里一排小圆点）与高亮框视图（画边框或光晕）

final class HighlightBorderView: NSView {
    var strokeColor: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.4)
    var lineWidth: CGFloat = 1
    /// 面板比格子每边大出的量。描边画在格子外侧、缝隙里，不压住窗口内容。
    var pad: CGFloat = 3
    var outset: CGFloat = 1.5
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = max(0.5, pad - outset)
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 2, rect.height > 2 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        strokeColor.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

final class TileProtoApp: NSObject, NSApplicationDelegate, NSWindowDelegate {

    var statusItem: NSStatusItem!
    var autoTile = true
    var autoOffPlacedKeys: Set<String> = []  // 关自动平铺后已见过的窗口：只给此后新开的窗口居中一次
    var tileLimit = 4
    var noPeek = true
    var dimStrength: CGFloat = 0.28
    var showBorders = true
    var hoverFocus = false
    var cleanSpaceOn = false
    var cleanSpaceSavedFrames: [String: CGRect] = [:]
    var cleanSpaceScreen: CGDirectDisplayID?
    var cleanSpaceHole: CGRect = .zero
    var cleanDimPanels: [NSPanel] = []
    var tabPanel: NSPanel?
    var familyButtons: [DiagramButton] = []
    var shareButtons: [NSButton] = []
    var gapSlider: NSSlider!
    var gapValueLabel: NSTextField!
    var dimSlider: NSSlider!
    var dimValueLabel: NSTextField!
    var fitWarningLabel: NSTextField!
    var noPeekSwitch: NSSwitch!
    var bordersSwitch: NSSwitch!
    var hoverFocusSwitch: NSSwitch!
    var cleanSpaceSwitch: NSSwitch!
    var panelButtonSymbols: [ObjectIdentifier: String] = [:]
    let tileBorderPad: CGFloat = 3
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
    var tileAppIconView: NSImageView!
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
    // 自动堆叠（最小尺寸放不下时并进更大的格子）。key → host。手动堆叠不在这张表里。
    var autoStackHost: [String: String] = [:]
    var loggedMissingWindowID = false
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

    // 活动格子细描边由 Borders 控制，其余格子的暗色由 No peek 和 Dim 控制。
    var lastActiveTile = 0

    // D 批状态：⌘拖交换 / ⌃⌘拖进堆叠
    enum DragMode { case swap, stack }
    /// spring：日常重排，约 5% 过冲。settle：交换/抬起，精确落到终点，不过冲、不互相穿透。
    enum MotionEase { case spring, settle }
    struct DragState {
        let mode: DragMode
        let sourceTile: Int
        let draggedKey: String
        let frames: [CGRect]  // mouseDown 时的磁贴 frame（Cocoa 坐标）
        let screenID: CGDirectDisplayID  // C 批：拖动发生的屏；跨屏松手按取消处理
        var targetTile: Int? = nil
        var grabOffset: CGPoint = .zero   // 指针相对窗口原点，抬起后保持抓取点
        var originFrame: CGRect = .zero   // 松手取消时弹回的格子帧
        var reactKey: String? = nil
        var reactHome: CGRect = .zero
        var ownsDrag: Bool = false        // 按下时已按 ⌘：事件由我们吞掉并自己移动窗口
        var tileTopKeys: [String] = []    // 与 frames 对齐的栈顶键，松手时按这个找目标窗
    }
    var dragState: DragState? = nil
    var dragLiftElement: AXUIElement? = nil
    var dragReactElement: AXUIElement? = nil
    // 抬起/目标内缩期间 AX 帧已离开格子，CG 列表对不上。这些键跳过在屏过滤，避免窗口从集合里消失。
    var gestureHeldKeys: Set<String> = []
    var dimsSuppressed = false
    // forceTile 路径上指定落定曲线（交换），用完即删。
    var preferredEase: [String: MotionEase] = [:]
    var pendingDrag: DragState? = nil  // ⌘按下未移动时的待定拖动：不吞事件，移动超 3pt 才转正
    var pendingDragPoint: CGPoint = .zero
    // 抓后按 ⌘：按下时没按 ⌘，记下按下点，拖动中按住 ⌘时从按下点重建拖动。
    var plainDownPoint: CGPoint? = nil
    var plainDownScreenID: CGDirectDisplayID? = nil
    var suppressSnapToastUntil: Date? = nil
    // mouse tap 重试退避（2s/5s/10s/30s，最多 4 次）；成功或授权翻转时重置。
    var tapRetryAttempt = 0
    var tapNextRetryAt: Date? = nil
    var tapRetryToastShown = false
    var dragRingPanel: NSPanel? = nil
    var pinnedActiveTile: Int? = nil
    var pinnedFrontmostPid: pid_t? = nil

    // 上次平铺落点：普通拖动弹回、Focus 还原都读它。只活在这次运行里。
    var lastPlacedFrames: [String: CGRect] = [:]  // winKey -> frame
    // C 批：多显示器 + Spaces（每屏独立设置、窗口集合与磁贴 frame；单屏时与旧行为一致）
    struct ScreenSettings {
        var tileLimit = 4
        var kind: LayoutKind = .grid
        var share: CGFloat = 0.5
        var gap: CGFloat = 8
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
        saveLayoutSettings()
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
        loadLayoutSettings()
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

    func panelTileButton(_ title: String, symbol name: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .shadowlessSquare
        b.isBordered = false
        b.imagePosition = .imageAbove
        b.imageHugsTitle = true
        b.imageScaling = .scaleProportionallyDown
        b.font = .systemFont(ofSize: 11, weight: .medium)
        b.image = tintedSymbol(name, point: 16, color: .labelColor)
        panelButtonSymbols[ObjectIdentifier(b)] = name
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        b.layer?.cornerRadius = 10
        b.heightAnchor.constraint(equalToConstant: 58).isActive = true
        return b
    }

    func settingCard(icon: NSImage?, label: NSTextField, control: NSControl) -> NSView {
        let iv = NSImageView()
        iv.image = icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        return settingCard(iconView: iv, label: label, control: control)
    }

    func settingCard(iconView: NSImageView, label: NSTextField, control: NSControl) -> NSView {
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        control.setContentHuggingPriority(.required, for: .horizontal)
        let row = hRow(spacing: 8)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(control)
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        wrap.layer?.cornerRadius = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -6),
        ])
        return wrap
    }

    func buildPanelContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panelStack = stack
        panelStack.detachesHiddenViews = true

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
        let captionSpacer = NSView()
        captionSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        captionRow.addArrangedSubview(windowsLabel)
        captionRow.addArrangedSubview(captionSpacer)
        captionRow.addArrangedSubview(sectionLabel("Layout"))
        stack.addArrangedSubview(w288(captionRow))

        let familyRow = hRow(distribution: .fillEqually)
        let familySpecs: [(String, LayoutKind, [CGRect])] = [
            ("Grid", .grid, [
                CGRect(x: 0, y: 0, width: 0.47, height: 0.47),
                CGRect(x: 0.53, y: 0, width: 0.47, height: 0.47),
                CGRect(x: 0, y: 0.53, width: 0.47, height: 0.47),
                CGRect(x: 0.53, y: 0.53, width: 0.47, height: 0.47),
            ]),
            ("Cols", .columns, [
                CGRect(x: 0, y: 0, width: 0.30, height: 1),
                CGRect(x: 0.35, y: 0, width: 0.30, height: 1),
                CGRect(x: 0.70, y: 0, width: 0.30, height: 1),
            ]),
            ("Rows", .rows, [
                CGRect(x: 0, y: 0, width: 1, height: 0.30),
                CGRect(x: 0, y: 0.35, width: 1, height: 0.30),
                CGRect(x: 0, y: 0.70, width: 1, height: 0.30),
            ]),
            ("Side", .side, [
                CGRect(x: 0, y: 0, width: 0.58, height: 1),
                CGRect(x: 0.64, y: 0, width: 0.36, height: 0.47),
                CGRect(x: 0.64, y: 0.53, width: 0.36, height: 0.47),
            ]),
        ]
        for (i, spec) in familySpecs.enumerated() {
            let b = DiagramButton(title: spec.0)
            b.rects = spec.2
            b.indexTag = i
            b.onClick = { [weak self] in self?.applyLayoutKind(spec.1) }
            familyButtons.append(b)
            familyRow.addArrangedSubview(b)
        }
        stack.addArrangedSubview(w288(familyRow))

        // 数量按钮。图跟当前布局族走：Grid 的 3 是一块大、两块小。
        let countRow = hRow(distribution: .fillEqually)
        for c in 1...4 {
            let b = DiagramButton(title: "\(c)")
            b.rects = countDiagram(c, kind: globalSettings.kind)
            b.indexTag = c
            b.onClick = { [weak self] in self?.applyLimit(c) }
            countButtons.append(b)
            countRow.addArrangedSubview(b)
        }
        stack.addArrangedSubview(w288(countRow))

        let shareRow = hRow(distribution: .fillEqually, spacing: 6)
        for (title, value) in [("1/2", 0.5), ("60%", 0.6), ("2/3", 2.0 / 3.0)] {
            let b = NSButton(title: title, target: self, action: #selector(panelShare(_:)))
            b.bezelStyle = .inline
            b.isBordered = false
            b.font = .systemFont(ofSize: 12, weight: .semibold)
            b.tag = Int((value * 100).rounded())
            shareButtons.append(b)
            shareRow.addArrangedSubview(b)
        }
        stack.addArrangedSubview(w288(shareRow))

        let gapRow = hRow(spacing: 8)
        gapRow.addArrangedSubview(sectionLabel("Gap"))
        gapSlider = NSSlider(value: 8, minValue: 0, maxValue: 16, target: self, action: #selector(panelGap(_:)))
        gapSlider.isContinuous = false
        gapValueLabel = NSTextField(labelWithString: "8")
        gapValueLabel.font = .systemFont(ofSize: 12, weight: .medium)
        gapValueLabel.alignment = .right
        gapValueLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true
        gapRow.addArrangedSubview(gapSlider)
        gapRow.addArrangedSubview(gapValueLabel)
        stack.addArrangedSubview(w288(gapRow))
        let resetRow = hRow()
        let resetBtn = NSButton(title: "Reset sizes", target: self, action: #selector(panelResetSizes(_:)))
        resetBtn.bezelStyle = .inline
        resetBtn.isBordered = false
        resetBtn.font = .systemFont(ofSize: 12, weight: .medium)
        resetRow.addArrangedSubview(resetBtn)
        stack.addArrangedSubview(w288(resetRow))
        fitWarningLabel = NSTextField(labelWithString: "")
        fitWarningLabel.font = .systemFont(ofSize: 11)
        fitWarningLabel.textColor = .secondaryLabelColor
        fitWarningLabel.maximumNumberOfLines = 2
        fitWarningLabel.lineBreakMode = .byWordWrapping
        fitWarningLabel.isHidden = true
        stack.addArrangedSubview(w288(fitWarningLabel))
        stack.addArrangedSubview(w288(separator()))

        // 动作格：图标在上，文字在下。没有键盘设置页。
        let actionRow = hRow(distribution: .fillEqually, spacing: 8)
        actionRow.addArrangedSubview(panelTileButton("Retile", symbol: "arrow.clockwise", action: #selector(panelTileNow(_:))))
        restoreFloatsButton = panelTileButton("恢复浮动", symbol: "arrow.uturn.backward", action: #selector(panelRestoreFloats(_:)))
        actionRow.addArrangedSubview(restoreFloatsButton)
        stack.addArrangedSubview(w288(actionRow))
        stack.addArrangedSubview(w288(panelTileButton("Tab view", symbol: "square.grid.2x2", action: #selector(panelTabView(_:)))))

        noPeekSwitch = NSSwitch()
        noPeekSwitch.target = self
        noPeekSwitch.action = #selector(panelToggleNoPeek(_:))
        stack.addArrangedSubview(w288(settingCard(icon: tintedSymbol("eye.slash", point: 14, color: .labelColor), label: NSTextField(labelWithString: "No peek"), control: noPeekSwitch)))
        let dimRow = hRow(spacing: 8)
        dimRow.addArrangedSubview(sectionLabel("Dim"))
        dimSlider = NSSlider(value: 28, minValue: 12, maxValue: 55, target: self, action: #selector(panelDim(_:)))
        dimSlider.isContinuous = false
        dimValueLabel = NSTextField(labelWithString: "28")
        dimValueLabel.font = .systemFont(ofSize: 12, weight: .medium)
        dimValueLabel.alignment = .right
        dimValueLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        dimRow.addArrangedSubview(dimSlider)
        dimRow.addArrangedSubview(dimValueLabel)
        stack.addArrangedSubview(w288(dimRow))

        bordersSwitch = NSSwitch()
        bordersSwitch.target = self
        bordersSwitch.action = #selector(panelToggleBorders(_:))
        stack.addArrangedSubview(w288(settingCard(icon: tintedSymbol("rectangle", point: 14, color: .labelColor), label: NSTextField(labelWithString: "Borders"), control: bordersSwitch)))

        hoverFocusSwitch = NSSwitch()
        hoverFocusSwitch.target = self
        hoverFocusSwitch.action = #selector(panelToggleHoverFocus(_:))
        stack.addArrangedSubview(w288(settingCard(icon: tintedSymbol("cursorarrow.rays", point: 14, color: .labelColor), label: NSTextField(labelWithString: "Hover focus"), control: hoverFocusSwitch)))

        cleanSpaceSwitch = NSSwitch()
        cleanSpaceSwitch.target = self
        cleanSpaceSwitch.action = #selector(panelToggleCleanSpace(_:))
        stack.addArrangedSubview(w288(settingCard(icon: tintedSymbol("moon", point: 14, color: .labelColor), label: NSTextField(labelWithString: "Clean Space"), control: cleanSpaceSwitch)))

        loginSwitch = NSSwitch()
        loginSwitch.target = self
        loginSwitch.action = #selector(panelToggleLogin(_:))
        let loginLabel = NSTextField(labelWithString: "开机启动")
        stack.addArrangedSubview(w288(settingCard(icon: tintedSymbol("power", point: 14, color: .labelColor), label: loginLabel, control: loginSwitch)))

        tileAppLabel = NSTextField(labelWithString: "Tile")
        tileAppLabel.lineBreakMode = .byTruncatingTail
        tileAppIconView = NSImageView()
        tileAppIconView.image = tintedSymbol("macwindow", point: 14, color: .labelColor)
        tileAppSwitch = NSSwitch()
        tileAppSwitch.target = self
        tileAppSwitch.action = #selector(panelToggleTileApp(_:))
        stack.addArrangedSubview(w288(settingCard(iconView: tileAppIconView, label: tileAppLabel, control: tileAppSwitch)))
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
            fitWarningLabel.isHidden = true
            for b in countButtons { b.isDisabled = false }
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
            if focusKey != nil { statusLabel.stringValue += " · Focus" }
            if cleanSpaceOn { statusLabel.stringValue += " · Clean Space" }
            if autoTile && !stageManagerPaused && !tapRunning {
                statusLabel.stringValue += " · 拖交换暂不可用"
            }
            let warning = fitWarning(on: screen, windows: windows)
            fitWarningLabel.stringValue = warning ?? ""
            fitWarningLabel.isHidden = warning == nil
            let fitCap = maxFitCount(on: screen)
            for b in countButtons {
                b.isDisabled = b.indexTag > fitCap
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
            b.rects = countDiagram(b.indexTag, kind: panelSt.kind)
            b.isSelected = (b.indexTag == panelSt.tileLimit)
            b.needsDisplay = true
        }
        dimSlider.superview?.isHidden = !noPeek
        if let app = frontRegularApp(), let bid = app.bundleIdentifier {
            let name = app.localizedName ?? bid
            tileAppLabel?.stringValue = "Tile \(name)"
            tileAppSwitch?.isEnabled = true
            tileAppSwitch?.state = excludedBundles.contains(bid) ? .off : .on
            if let url = app.bundleURL {
                tileAppIconView?.image = NSWorkspace.shared.icon(forFile: url.path)
            }
        } else {
            tileAppLabel?.stringValue = "Tile front app"
            tileAppSwitch?.isEnabled = false
            tileAppSwitch?.state = .off
            tileAppIconView?.image = tintedSymbol("macwindow", point: 14, color: .labelColor)
        }
        stylePanelButton(restoreFloatsButton, enabled: !floatedKeys.isEmpty)
        for b in familyButtons {
            let kinds: [LayoutKind] = [.grid, .columns, .rows, .side]
            b.isSelected = kinds.indices.contains(b.indexTag) && kinds[b.indexTag] == globalSettings.kind
        }
        for b in shareButtons {
            let selected = abs(CGFloat(b.tag) / 100 - globalSettings.share) < 0.03
            b.contentTintColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.85) : .labelColor
            let font = NSFont.systemFont(ofSize: 12, weight: selected ? .bold : .medium)
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .foregroundColor: selected ? NSColor.controlAccentColor.withAlphaComponent(0.85) : NSColor.labelColor,
                .font: font,
            ])
        }
        if NSEvent.pressedMouseButtons == 0 {
            gapSlider.doubleValue = Double(globalSettings.gap)
            gapValueLabel.stringValue = "\(Int(globalSettings.gap.rounded()))"
            dimSlider.doubleValue = Double(dimStrength * 100)
            dimValueLabel.stringValue = "\(Int((dimStrength * 100).rounded()))"
        }
        noPeekSwitch.state = noPeek ? .on : .off
        bordersSwitch.state = showBorders ? .on : .off
        hoverFocusSwitch.state = hoverFocus ? .on : .off
        cleanSpaceSwitch.state = cleanSpaceOn ? .on : .off
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
        let screen = activeScreen()
        if v < 1 || v > 4 {
            log("tileLimit \(v) rejected; max 4")
            refreshPanel()
            return
        }
        if !countFits(v, on: screen) {
            log("tileLimit \(v) rejected; cells would be under \(Int(cellFloorW))x\(Int(cellFloorH))")
            showToast("This screen fits fewer cells", on: screen)
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

    func stylePanelButton(_ b: NSButton, enabled: Bool) {
        let color: NSColor = enabled ? .labelColor : .secondaryLabelColor
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ])
        if let name = panelButtonSymbols[ObjectIdentifier(b)] {
            b.image = tintedSymbol(name, point: 16, color: color)
        }
        b.alphaValue = 1
    }

    func layoutName(_ kind: LayoutKind) -> String {
        switch kind {
        case .grid: return "Grid"
        case .columns: return "Columns"
        case .rows: return "Rows"
        case .side: return "Side"
        }
    }

    /// 数量按钮上的示意图。单位坐标，y 从上往下。Grid 的 3 格是左大右二。
    func countDiagram(_ n: Int, kind: LayoutKind) -> [CGRect] {
        let count = min(max(n, 1), 4)
        if count == 1 { return [CGRect(x: 0, y: 0, width: 1, height: 1)] }
        let gap: CGFloat = 0.06
        func strips(_ n: Int, vertical: Bool) -> [CGRect] {
            let pane = (1 - gap * CGFloat(n - 1)) / CGFloat(n)
            return (0..<n).map { i in
                let origin = CGFloat(i) * (pane + gap)
                if vertical { return CGRect(x: 0, y: origin, width: 1, height: pane) }
                return CGRect(x: origin, y: 0, width: pane, height: 1)
            }
        }
        switch kind {
        case .columns:
            return strips(count, vertical: false)
        case .rows:
            return strips(count, vertical: true)
        case .side:
            let rows = count - 1
            let pane = (1 - gap * CGFloat(max(rows - 1, 0))) / CGFloat(rows)
            var out = [CGRect(x: 0, y: 0, width: 0.58, height: 1)]
            for i in 0..<rows {
                out.append(CGRect(x: 0.64, y: CGFloat(i) * (pane + gap), width: 0.36, height: pane))
            }
            return out
        case .grid:
            if count == 2 { return strips(2, vertical: false) }
            if count == 3 {
                return [
                    CGRect(x: 0, y: 0, width: 0.58, height: 1),
                    CGRect(x: 0.64, y: 0, width: 0.36, height: 0.47),
                    CGRect(x: 0.64, y: 0.53, width: 0.36, height: 0.47),
                ]
            }
            return [
                CGRect(x: 0, y: 0, width: 0.47, height: 0.47),
                CGRect(x: 0.53, y: 0, width: 0.47, height: 0.47),
                CGRect(x: 0, y: 0.53, width: 0.47, height: 0.47),
                CGRect(x: 0.53, y: 0.53, width: 0.47, height: 0.47),
            ]
        }
    }

    func minimumCell(on screen: NSScreen, count: Int) -> CGSize {
        let st = globalSettings
        let frames = layoutFrames(count: count, vf: screen.visibleFrame, kind: st.kind, share: st.share, gap: st.gap)
        let width = frames.map(\.width).min() ?? 0
        let height = frames.map(\.height).min() ?? 0
        return CGSize(width: width, height: height)
    }

    /// 一格始终可用。更多格时，最窄的一格要能放下大约 160×100，否则这档数量变灰。
    func countFits(_ count: Int, on screen: NSScreen) -> Bool {
        if count <= 1 { return true }
        let cell = minimumCell(on: screen, count: count)
        return cell.width + tileFitTolerance >= cellFloorW && cell.height + tileFitTolerance >= cellFloorH
    }

    func maxFitCount(on screen: NSScreen) -> Int {
        var cap = 1
        for n in 1...4 {
            if countFits(n, on: screen) { cap = n } else { break }
        }
        return cap
    }

    func fitWarning(on screen: NSScreen, windows: [WinInfo]) -> String? {
        let st = globalSettings
        if !countFits(st.tileLimit, on: screen) {
            return "This screen is tight for \(st.tileLimit) cells."
        }
        let count = min(max(windows.count, 1), st.tileLimit, 4)
        let frames = layoutFrames(count: count, vf: screen.visibleFrame, kind: st.kind, share: st.share, gap: st.gap)
        guard !frames.isEmpty else { return nil }
        var overflow = 0
        for w in windows {
            let need = effectiveMin(for: w)
            let fits = frames.contains { slotShortfall(need, $0) == 0 }
            if !fits { overflow += 1 }
        }
        if overflow == 0 { return nil }
        let noun = overflow == 1 ? "window" : "windows"
        return "\(overflow) \(noun) will stack or float. A cell is smaller than the window minimum."
    }

    func applyLayoutKind(_ kind: LayoutKind) {
        var st = globalSettings
        st.kind = kind
        setSettingsFor(st, screen: activeScreen())
        log("layout -> \(layoutName(kind))")
        showToast(layoutName(kind), on: activeScreen())
        forceTile()
        refreshPanel()
    }

    @objc func panelShare(_ sender: NSButton) {
        let value = CGFloat(sender.tag) / 100
        var st = globalSettings
        st.share = value
        setSettingsFor(st, screen: activeScreen())
        log("share -> \(sender.title)")
        showToast("Primary \(sender.title)", on: activeScreen())
        forceTile()
        refreshPanel()
    }

    @objc func panelGap(_ sender: NSSlider) {
        var st = globalSettings
        st.gap = CGFloat(sender.integerValue)
        gapValueLabel?.stringValue = "\(sender.integerValue)"
        setSettingsFor(st, screen: activeScreen())
        log("gap -> \(sender.integerValue)")
        forceTile()
        refreshPanel()
    }

    @objc func panelResetSizes(_ sender: NSButton) {
        guard !splitOverrides.isEmpty else {
            showToast("Sizes already even", on: activeScreen())
            return
        }
        splitOverrides.removeAll()
        log("sizes reset")
        showToast("Sizes reset", on: activeScreen())
        forceTile()
        refreshPanel()
    }

    @objc func panelDim(_ sender: NSSlider) {
        let pct = min(55, max(12, sender.integerValue))
        dimStrength = CGFloat(pct) / 100
        dimValueLabel?.stringValue = "\(pct)"
        saveLayoutSettings()
        log("dim -> \(pct)")
        removeDimLayers()
        if noPeek { refreshDimLayers() }
    }

    @objc func panelToggleNoPeek(_ sender: NSSwitch) {
        noPeek = sender.state == .on
        saveLayoutSettings()
        log(noPeek ? "no peek on" : "no peek off")
        if noPeek { refreshDimLayers() } else { removeDimLayers() }
        refreshPanel()
    }

    @objc func panelToggleBorders(_ sender: NSSwitch) {
        showBorders = sender.state == .on
        saveLayoutSettings()
        log(showBorders ? "borders on" : "borders off")
        if showBorders { refreshHighlights() } else { hideHighlights() }
    }

    @objc func panelToggleHoverFocus(_ sender: NSSwitch) {
        hoverFocus = sender.state == .on
        saveLayoutSettings()
        log(hoverFocus ? "hover focus on" : "hover focus off")
    }

    @objc func panelToggleCleanSpace(_ sender: NSSwitch) {
        if sender.state == .on {
            enableCleanSpace()
        } else {
            exitCleanSpace()
        }
        refreshPanel()
    }

    @objc func panelTabView(_ sender: NSButton) {
        panelPopover?.close()
        showTabView()
    }

    @objc func panelTileNow(_ sender: NSButton) {
        if focusKey != nil {
            disableFocus()
        }
        if cleanSpaceOn {
            cancelCleanSpace()
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
        let maxW = NSScreen.screens.map { $0.visibleFrame.width }.max() ?? 0
        let maxH = NSScreen.screens.map { $0.visibleFrame.height }.max() ?? 0
        var dropped = 0
        var clamped = 0
        for (name, v) in raw {
            guard let d = v as? [String: Double], let rawW = d["w"], let rawH = d["h"] else { continue }
            // 两维都 ≤0 是毒化数据（如 1512x0 整条无意义），丢弃。
            // 只有一维 >0 时留下，另一维记 0，消费处把 0 当未知，绝不当成高度 0。
            var w = rawW
            var h = rawH
            guard w > 0 || h > 0 else { dropped += 1; continue }
            if w < 0 { w = 0 }
            if h < 0 { h = 0 }
            if maxW > 0, w > maxW * 0.85 { w = maxW * 0.85; clamped += 1 }
            if maxH > 0, h > maxH * 0.85 { h = maxH * 0.85; clamped += 1 }
            learnedMinSizes[name] = CGSize(width: w, height: h)
        }
        if dropped > 0 { log("min-size learned dropped invalid entries: \(dropped)") }
        if clamped > 0 { log("min-size learned clamped oversized entries: \(clamped)") }
        if !learnedMinSizes.isEmpty { log("min-size learned loaded: \(learnedMinSizes.count) apps") }
    }

    func saveLearnedMinSizes() {
        let raw = learnedMinSizes.mapValues { ["w": Double($0.width), "h": Double($0.height)] }
        UserDefaults.standard.set(raw, forKey: learnedMinDefaultsKey)
    }

    func loadLayoutSettings() {
        let d = UserDefaults.standard
        var st = globalSettings
        if d.object(forKey: "tileproto.tileLimit") != nil {
            let v = d.integer(forKey: "tileproto.tileLimit")
            if (1...4).contains(v) { st.tileLimit = v }
        }
        if d.object(forKey: "tileproto.layoutKind") != nil {
            st.kind = LayoutKind(rawValue: d.integer(forKey: "tileproto.layoutKind")) ?? .grid
        }
        if d.object(forKey: "tileproto.share") != nil {
            let s = CGFloat(d.double(forKey: "tileproto.share"))
            if s > 0.3, s < 0.85 { st.share = s }
        }
        if d.object(forKey: "tileproto.gap") != nil {
            st.gap = min(16, max(0, CGFloat(d.double(forKey: "tileproto.gap"))))
        }
        globalSettings = st
        tileLimit = st.tileLimit
        if d.object(forKey: "tileproto.noPeek") != nil { noPeek = d.bool(forKey: "tileproto.noPeek") }
        if d.object(forKey: "tileproto.dimStrength") != nil {
            let v = CGFloat(d.double(forKey: "tileproto.dimStrength"))
            if v >= 0.08, v <= 0.6 { dimStrength = v }
        }
        if d.object(forKey: "tileproto.borders") != nil { showBorders = d.bool(forKey: "tileproto.borders") }
        hoverFocus = d.bool(forKey: "tileproto.hoverFocus")
    }

    func saveLayoutSettings() {
        let d = UserDefaults.standard
        d.set(globalSettings.tileLimit, forKey: "tileproto.tileLimit")
        d.set(globalSettings.kind.rawValue, forKey: "tileproto.layoutKind")
        d.set(Double(globalSettings.share), forKey: "tileproto.share")
        d.set(Double(globalSettings.gap), forKey: "tileproto.gap")
        d.set(noPeek, forKey: "tileproto.noPeek")
        d.set(Double(dimStrength), forKey: "tileproto.dimStrength")
        d.set(showBorders, forKey: "tileproto.borders")
        d.set(hoverFocus, forKey: "tileproto.hoverFocus")
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
                tapRetryAttempt = 0; tapNextRetryAt = nil; tapRetryToastShown = false
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
        // mouse tap 重试：创建失败时按短退避重试几次（2s/5s/10s/30s），
        // 而不是只在授权翻转时试一次；否则启动竞态失败后 ⌘ 拖会静默失效到下次重启。
        // 重试耗尽时发一次 toast；面板状态行也会同步提示（见 refreshPanel）。
        if !tapRunning {
            if let next = tapNextRetryAt {
                if Date() >= next, tapRetryAttempt < 4 {
                    tapRetryAttempt += 1
                    tapNextRetryAt = Date().addingTimeInterval([2, 5, 10, 30][min(tapRetryAttempt - 1, 3)])
                    setupMouseDragTap()
                    if tapRunning {
                        tapRetryAttempt = 0; tapNextRetryAt = nil; tapRetryToastShown = false
                    } else if tapRetryAttempt >= 4, !tapRetryToastShown {
                        tapRetryToastShown = true
                        showToast("拖交换暂不可用", detail: "鼠标 tap 未建立，重开应用或检查 Input Monitoring 后再试。", on: NSScreen.main ?? NSScreen.screens.first)
                    }
                }
            } else {
                tapNextRetryAt = Date().addingTimeInterval(2)
            }
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
        // 学到新最小尺寸后重排一次，让位/堆叠随即生效；拖分隔线或 ⌘ 拖时不动手。
        if learnedMinChanged, draggingDividerID == nil, dragState == nil {
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
                    let toastBlocked = suppressSnapToastUntil.map { Date() < $0 } ?? false
                    if !toasted, !toastBlocked {
                        let screen = NSScreen.screens.first(where: { screenID($0) == sid })
                        showToast("A plain drag stays put.", detail: "Hold Command and drag to swap.", on: screen)
                        toasted = true
                    }
                }
            }
        }
        // ⌘ 拖已经把窗口抬离格子。这里若重排，会把抬起的窗口拽回原格，
        // 松手再弹一次，看起来像闪一下或有一扇窗消失。手势自己负责落点。
        if dragState != nil {
            return
        }
        let sig = fullSignature()
        if sig == lastSignature {
            pendingSignature = ""
            pendingTicks = 0
            return
        }
        // 集合变化（开窗/关窗）立即重排，不等防抖；拖动/动画中（鼠标按着、
        // 正在拖分隔线或待定 ⌘ 按下）仍走 2 周期防抖，避免拖动中途把窗口拽回磁贴
        let dragging = NSEvent.pressedMouseButtons != 0 || draggingDividerID != nil
            || pendingDrag != nil
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
        var windowID: CGWindowID
        var tieBreak: Int  // 同一基础键的第几扇；0 不写进键。只在拿不到窗口号时才会 >0
    }

    // 窗口号优先：同进程多扇同名窗口（几扇访达）不会撞成同一个键。
    // 拿不到窗口号时退回 pid|标题；仍重复则加 tieBreak，避免 Dictionary 唯一键断言崩溃。
    func winKey(_ w: WinInfo) -> String {
        let base = w.windowID != 0 ? "\(w.pid)#\(w.windowID)" : "\(w.pid)|\(w.title)"
        if w.tieBreak == 0 { return base }
        return "\(base)#\(w.tieBreak)"
    }

    func baseWindowKey(pid: pid_t, title: String, windowID: CGWindowID) -> String {
        windowID != 0 ? "\(pid)#\(windowID)" : "\(pid)|\(title)"
    }

    func keyIsInFlight(_ base: String) -> Bool {
        if frameMotions[base] != nil || gestureHeldKeys.contains(base) { return true }
        let prefix = base + "#"
        if frameMotions.keys.contains(where: { $0.hasPrefix(prefix) }) { return true }
        if gestureHeldKeys.contains(where: { $0.hasPrefix(prefix) }) { return true }
        return false
    }

    struct CGWinSnap {
        let pid: pid_t
        let bounds: CGRect
        let number: CGWindowID
    }

    // 当前 Space 的在屏窗口（CG 窗口列表，onScreenOnly）：CG bounds 与 AX position
    // 同为 y 向下约定，可直接比对；CG 窗口名经常为空，故按 pid+bounds 匹配，不靠标题
    func cgWindowSnaps() -> [CGWinSnap] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [CGWinSnap] = []
        for w in list {
            guard let pidNum = w[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            guard let num = w[kCGWindowNumber as String] as? NSNumber else { continue }
            guard let bd = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = (bd["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (bd["Y"] as? NSNumber)?.doubleValue ?? 0
            let ww = (bd["Width"] as? NSNumber)?.doubleValue ?? 0
            let hh = (bd["Height"] as? NSNumber)?.doubleValue ?? 0
            out.append(CGWinSnap(pid: pidNum.int32Value, bounds: CGRect(x: x, y: y, width: ww, height: hh), number: num.uint32Value))
        }
        return out
    }

    func onScreenCGWindows() -> [(pid: pid_t, bounds: CGRect)] {
        cgWindowSnaps().map { ($0.pid, $0.bounds) }
    }

    // 先问 AX 窗口号；失败再用 pid+bounds 对上 CG 列表里还没被占用的窗口号。
    func resolveWindowID(_ element: AXUIElement, pid: pid_t, frame: CGRect, screenHeight: CGFloat, snaps: [CGWinSnap], used: inout Set<CGWindowID>) -> CGWindowID {
        let spi = copyAXWindowID(element)
        if spi != 0, !used.contains(spi) {
            used.insert(spi)
            return spi
        }
        if axWindowNumberFn == nil, !loggedMissingWindowID {
            loggedMissingWindowID = true
            log("window id symbol unavailable; falling back to frame match")
        }
        let axY = screenHeight - frame.maxY
        if let hit = snaps.first(where: { snap in
            snap.pid == pid && snap.number != 0 && !used.contains(snap.number)
                && abs(snap.bounds.minX - frame.minX) < 2 && abs(snap.bounds.minY - axY) < 2
                && abs(snap.bounds.width - frame.width) < 2 && abs(snap.bounds.height - frame.height) < 2
        }) {
            used.insert(hit.number)
            return hit.number
        }
        return 0
    }

    func collectWindows(includeFloated: Bool = false, onlyCurrentSpace: Bool = true) -> [WinInfo] {
        var out: [WinInfo] = []
        let myPid = ProcessInfo.processInfo.processIdentifier
        let mh = mainHeight()
        let snaps = onlyCurrentSpace ? cgWindowSnaps() : []
        // CG 列表为空时 fail-open（不过滤），避免窗口服务器一时不可用导致全集消失
        let onScreen = snaps.map { (pid: $0.pid, bounds: $0.bounds) }
        var usedIDs: Set<CGWindowID> = []
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
                let wid = resolveWindowID(w, pid: app.processIdentifier, frame: frame, screenHeight: mh, snaps: snaps, used: &usedIDs)
                let base = baseWindowKey(pid: app.processIdentifier, title: title, windowID: wid)
                // 弹簧或 ⌘ 抬起进行中，AX 与 CG 会差一帧以上。正在动的窗口直接留下。
                let moving = keyIsInFlight(base)
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
                let info = WinInfo(pid: app.processIdentifier, appName: app.localizedName ?? "?", element: w, title: title, frame: frame, windowID: wid, tieBreak: 0)
                out.append(info)
            }
        }
        // 同一基础键的后续窗口加 tieBreak，保证本次数组里键唯一。
        var seen: [String: Int] = [:]
        for i in out.indices {
            let base = baseWindowKey(pid: out[i].pid, title: out[i].title, windowID: out[i].windowID)
            let n = seen[base, default: 0]
            seen[base] = n + 1
            out[i].tieBreak = n
        }
        if !includeFloated {
            out.removeAll { floatedKeys.contains(winKey($0)) }
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

    // 当前布局族、份额和间距。一格始终铺满可视区。
    func tileFrames(count t: Int, vf: CGRect) -> [CGRect] {
        layoutFrames(count: t, vf: vf, kind: globalSettings.kind, share: globalSettings.share, gap: globalSettings.gap)
    }

    // 把 total 分给 n 段。want≤1 表示这一段没有最小尺寸，按均分权重。
    // 每段落在 [floor, total*capFraction] 里；总和精确等于 total。做不到时退回均分。
    func splitLengths(total: CGFloat, wants: [CGFloat], floor: CGFloat, capFraction: CGFloat) -> [CGFloat] {
        let n = wants.count
        guard n > 0 else { return [] }
        if n == 1 { return [max(total, 1)] }
        guard total > 1 else { return Array(repeating: max(total, 1) / CGFloat(n), count: n) }
        let cap = total * capFraction
        let fl = min(floor, total / CGFloat(n))
        var out = Array(repeating: fl, count: n)
        let remain = total - fl * CGFloat(n)
        let weights = wants.map { $0 > 1 ? $0 : fl }
        let wsum = weights.reduce(0, +)
        if remain > 0, wsum > 0 {
            for i in 0..<n { out[i] += remain * (weights[i] / wsum) }
        }
        for _ in 0..<4 {
            var overflow: CGFloat = 0
            var room: [Int] = []
            for i in 0..<n {
                if out[i] > cap {
                    overflow += out[i] - cap
                    out[i] = cap
                } else if out[i] < cap - 0.01 {
                    room.append(i)
                }
            }
            if overflow <= 0.01 || room.isEmpty { break }
            let add = overflow / CGFloat(room.count)
            for i in room { out[i] += add }
        }
        let sum = out.reduce(0, +)
        if abs(sum - total) > 0.5, let i = out.indices.max(by: { out[$0] < out[$1] }) {
            out[i] += total - sum
        }
        return out
    }

    // 骨架按布局族生成。最小尺寸不在这里把某一格撑破上限，交给让位和并堆。
    func biasedFrames(count: Int, vf: CGRect, claims: [CGSize]) -> [CGRect] {
        _ = claims
        return tileFrames(count: count, vf: vf)
    }

    func axMinSize(_ el: AXUIElement) -> CGSize {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXMinSize" as CFString, &value) == .success,
              let axv = value else { return .zero }
        var sz = CGSize.zero
        guard AXValueGetValue(axv as! AXValue, .cgSize, &sz) else { return .zero }
        if sz.width < 1 { sz.width = 0 }
        if sz.height < 1 { sz.height = 0 }
        return sz
    }

    // 一维上取已学值和 AX 最小值里更大的那个。≤1 表示这一维未知，不参与，也不会把另一维拉成 0。
    func effectiveMin(for w: WinInfo) -> CGSize {
        let learned = learnedMinSizes[w.appName] ?? .zero
        let ax = axMinSize(w.element)
        func axis(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            if a > 1, b > 1 { return max(a, b) }
            if a > 1 { return a }
            if b > 1 { return b }
            return 0
        }
        return CGSize(width: axis(learned.width, ax.width), height: axis(learned.height, ax.height))
    }

    // 偏置用的声明值：未知维保持 0；已知维不超过可视区的 78%，避免一扇窗把邻居挤没。
    func layoutClaim(_ raw: CGSize, vf: CGRect) -> CGSize {
        let capW = max(1, vf.width * 0.78)
        let capH = max(1, vf.height * 0.78)
        return CGSize(
            width: raw.width > 1 ? min(raw.width, capW) : 0,
            height: raw.height > 1 ? min(raw.height, capH) : 0
        )
    }

    func stackNeed(_ stack: [WinInfo]) -> CGSize {
        var w: CGFloat = 0
        var h: CGFloat = 0
        for win in stack {
            let m = effectiveMin(for: win)
            if m.width > w { w = m.width }
            if m.height > h { h = m.height }
        }
        return CGSize(width: w, height: h)
    }

    func releaseAutoStacks(on _: CGDirectDisplayID, live: [WinInfo]) {
        // live 已经是这一屏的窗口。只拆成员在本屏的自动堆叠，下一轮按当前最小尺寸重算。
        // 不能因为 host 在本屏就把另一屏的成员关系拆掉：tileAll 按屏依次调用，先跑的屏会把后跑的屏的堆叠清掉。
        let liveKeys = Set(live.map { winKey($0) })
        let drop = autoStackHost.filter { liveKeys.contains($0.key) }
        for (k, host) in drop {
            if stackedOnto[k] == host { stackedOnto.removeValue(forKey: k) }
            autoStackHost.removeValue(forKey: k)
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
            var rank: [String: Int] = [:]
            for (i, k) in windowOrder.enumerated() where rank[k] == nil { rank[k] = i }
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
        let liveKeys = Set(allWindows.map { winKey($0) })
        normalizeStackedOnto(liveKeys: liveKeys)
        autoStackHost = autoStackHost.filter { liveKeys.contains($0.key) && liveKeys.contains($0.value) }
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
    // 其已学最小尺寸或 160×120 底线以下）；匀完仍不够的由调用方并堆或浮动。
    // 看整叠里最大的最小尺寸。双向都让：左/上不够向右/下移缝，右/下不够向左/上
    // 移缝；两轮收敛多列链。缝移动时两侧同量进退，当前间距不变。
    func applyGiveWay(frames: [CGRect], stacks: [[WinInfo]], sid: CGDirectDisplayID) -> [CGRect] {
        guard !frames.isEmpty, frames.count == stacks.count else { return frames }
        var out = frames
        func topMin(_ tile: Int) -> CGSize {
            guard stacks.indices.contains(tile) else { return .zero }
            // 整叠里最大的最小尺寸，被盖住的大窗口也不会从格子后面探出来。
            return stackNeed(stacks[tile])
        }
        let g = globalSettings.gap
        let half = g / 2
        for _ in 0..<2 {
            let dividers = deriveDividers(frames: out, gap: g, sid: sid)
            for d in dividers {
                if d.vertical {
                    let left = out.indices.filter { abs(out[$0].maxX - (d.center - half)) < 1.5 }
                    let right = out.indices.filter { abs(out[$0].minX - (d.center + half)) < 1.5 }
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
                    let above = out.indices.filter { abs(out[$0].minY - (d.center + half)) < 1.5 }
                    let below = out.indices.filter { abs(out[$0].maxY - (d.center - half)) < 1.5 }
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

    func framesFor(stacks: [[WinInfo]], screen: NSScreen, sid: CGDirectDisplayID) -> [CGRect] {
        let vf = screen.visibleFrame
        guard !stacks.isEmpty else { return [] }
        let claims = stacks.map { layoutClaim(stackNeed($0), vf: vf) }
        var frames = biasedFrames(count: stacks.count, vf: vf, claims: claims)
        frames = applySplitOverrides(frames: frames, tileCount: stacks.count, vf: vf, sid: sid)
        if draggingDividerID == nil {
            frames = applyGiveWay(frames: frames, stacks: stacks, sid: sid)
        }
        return frames
    }

    /// 整屏都装不下时居中浮动，并从平铺集合里拿掉。下一轮 tick 不会再把它塞回格子。
    func floatOversized(_ w: WinInfo, on screen: NSScreen) {
        let key = winKey(w)
        let vf = screen.visibleFrame
        let need = effectiveMin(for: w)
        let cur = getSize(w.element) ?? w.frame.size
        var width = max(need.width > 1 ? need.width : 0, cur.width > 1 ? cur.width : 0)
        var height = max(need.height > 1 ? need.height : 0, cur.height > 1 ? cur.height : 0)
        if width < 1 { width = min(480, vf.width - 16) }
        if height < 1 { height = min(320, vf.height - 16) }
        width = min(width, max(1, vf.width - 16))
        height = min(height, max(1, vf.height - 16))
        let frame = CGRect(x: vf.midX - width / 2, y: vf.midY - height / 2, width: width, height: height)
        let inserted = floatedKeys.insert(key).inserted
        placeFrame(w.element, frame, key: key, animated: draggingDividerID == nil, learnName: w.appName, preSize: cur)
        lastPlacedFrames[key] = frame
        if inserted {
            log("min-size float: \(w.appName) min=\(Int(need.width))x\(Int(need.height)) screen=\(Int(vf.width))x\(Int(vf.height))")
        }
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
        if cleanSpaceOn, cleanSpaceScreen == sid {
            if refreshOverlays {
                hideGrips()
                hideStackMarkers()
                hideHighlights()
                removeDimLayers()
                if cleanSpaceHole.width > 1 { showCleanDim(on: screen, hole: cleanSpaceHole) }
            }
            return
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
        // 先拆掉上一轮的自动堆叠，再按当前最小尺寸决定要不要重新并进去。
        // 手动堆叠不在 autoStackHost 里，不会被拆。
        let previousAuto = autoStackHost
        if draggingDividerID == nil, dragState == nil {
            releaseAutoStacks(on: sid, live: windows)
        }
        var (stacks, origActive) = computeTiles(windows: windows, st: st, sid: sid)
        stacks = applyPrimarySwap(stacks: stacks, sid: sid)
        if draggingDividerID == nil, dragState == nil, !stacks.isEmpty {
            let activeIdx = min(origActive, stacks.count - 1)
            let activeStack = stacks[activeIdx]
            let activeTop = activeStack[min(stackTops[stackTopKey(sid, activeIdx)] ?? 0, activeStack.count - 1)]
            let activeTopKeyBefore = winKey(activeTop)
            let beforeGroup: [String: Int] = {
                var map: [String: Int] = [:]
                for (i, stack) in stacks.enumerated() {
                    for w in stack { map[winKey(w)] = i }
                }
                return map
            }()
            var flat: [WinInfo] = []
            var indexOf: [String: Int] = [:]
            for stack in stacks {
                for w in stack {
                    let key = winKey(w)
                    if indexOf[key] == nil {
                        indexOf[key] = flat.count
                        flat.append(w)
                    }
                }
            }
            let needs = flat.map { effectiveMin(for: $0) }
            let groups: [[Int]] = stacks.map { stack in stack.compactMap { indexOf[winKey($0)] } }
            var bound: [Int: Int] = [:]
            for (member, host) in stackedOnto where autoStackHost[member] == nil {
                if let mi = indexOf[member], let hi = indexOf[host] { bound[mi] = hi }
            }
            let plan = planTileFit(needs: needs, groups: groups, bound: bound) { ids in
                let grouped: [[WinInfo]] = ids.map { group in group.compactMap { flat.indices.contains($0) ? flat[$0] : nil } }
                return self.framesFor(stacks: grouped, screen: screen, sid: sid)
            }
            var planned: [[WinInfo]] = plan.groups.map { group in group.compactMap { flat.indices.contains($0) ? flat[$0] : nil } }
            planned.removeAll { $0.isEmpty }
            for id in plan.floated where flat.indices.contains(id) {
                let w = flat[id]
                let key = winKey(w)
                for i in planned.indices { planned[i].removeAll { winKey($0) == key } }
                planned.removeAll { $0.isEmpty }
                floatOversized(w, on: screen)
            }
            for (i, stack) in planned.enumerated() {
                let moved = stack.filter { w in
                    guard let from = beforeGroup[winKey(w)] else { return false }
                    return from != i
                }
                guard !moved.isEmpty,
                      let host = stack.first(where: { beforeGroup[winKey($0)] == i }) else { continue }
                let hostKey = winKey(host)
                let visible = moved.max { a, b in
                    let aa = effectiveMin(for: a)
                    let bb = effectiveMin(for: b)
                    return aa.width * aa.height < bb.width * bb.height
                }
                if let visible, let idx = stack.firstIndex(where: { winKey($0) == winKey(visible) }) {
                    stackTops[stackTopKey(sid, i)] = idx
                }
                for w in moved {
                    let mk = winKey(w)
                    guard mk != hostKey else { continue }
                    if previousAuto[mk] != hostKey {
                        log("overflow stack: \(w.appName) joins \(host.appName)")
                    }
                    autoStackHost[mk] = hostKey
                    // 已经有手动堆叠关系的成员跟着根走，不改写成自动 host。
                    if stackedOnto[mk] == nil { stackedOnto[mk] = hostKey }
                }
            }
            stacks = planned
            if let idx = stacks.firstIndex(where: { $0.contains { winKey($0) == activeTopKeyBefore } }) {
                origActive = idx
            } else {
                origActive = 0
            }
        }
        // 堆叠产生时提示一次（从无堆叠变为有堆叠才弹，不刷屏）
        let hasStack = stacks.contains { $0.count > 1 }
        if hasStack, lastStackByScreen[sid] != true {
            showToast("Stacked in this tile", detail: "Hover the top edge or click the orange marks to switch.", on: screen)
        }
        lastStackByScreen[sid] = hasStack
        let activeTopKey = stacks.isEmpty ? "" : winKey(stacks[min(origActive, stacks.count - 1)][min(stackTops[stackTopKey(sid, min(origActive, stacks.count - 1))] ?? 0, stacks[min(origActive, stacks.count - 1)].count - 1)])
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
        // 新并进去的大窗口放到该格最上面，用户才看得见它。同一对 host 下一轮不再改栈顶。
        for (key, host) in autoStackHost where previousAuto[key] != host {
            for (i, stack) in fitStacks.enumerated() {
                if let idx = stack.firstIndex(where: { winKey($0) == key }) {
                    stackTops[stackTopKey(sid, i)] = idx
                }
            }
        }
        let frames = framesFor(stacks: fitStacks, screen: screen, sid: sid)
        let animateMoves = draggingDividerID == nil
        var placedStacks: [[WinInfo]] = Array(repeating: [], count: fitStacks.count)
        for (i, stack) in fitStacks.enumerated() {
            let slot = frames.indices.contains(i) ? frames[i] : vf
            for w in stack {
                let key = winKey(w)
                let minSize = effectiveMin(for: w)
                // 装不进这一格就居中浮动，并从这一格拿掉，避免半截探进邻居。
                guard frameContained(in: slot, proposed: slot, minSize: minSize) != nil else {
                    floatOversized(w, on: screen)
                    continue
                }
                let preSize = getSize(w.element)
                placeFrame(w.element, slot, key: key, animated: animateMoves, learnName: w.appName, preSize: preSize, slot: slot, minSize: minSize)
                lastPlacedFrames[key] = slot
                placedStacks[i].append(w)
            }
        }
        let shownStacks = placedStacks.enumerated().filter { !$0.element.isEmpty }
        lastVFByScreen[sid] = vf
        lastScreenFrameByScreen[sid] = screen.frame
        let shownActive = shownStacks.firstIndex(where: { fitStacks.indices.contains($0.offset) && active == $0.offset }) ?? 0
        lastActiveTileByScreen[sid] = shownStacks.isEmpty ? 0 : shownActive
        lastTilesByScreen[sid] = shownStacks.map { pair in
            let s = pair.element
            let topIndex = min(stackTops[stackTopKey(sid, pair.offset)] ?? 0, s.count - 1)
            let top = s[max(0, topIndex)]
            let shown = inFlightFrame(key: winKey(top)) ?? (frames.indices.contains(pair.offset) ? frames[pair.offset] : vf)
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
        let ease: MotionEase
        let slot: CGRect?
        let minSize: CGSize
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

    /// 三次缓出。t=1 时精确为 1，中间不过冲，交换时两扇窗不会互相穿过去。
    func easeOutCubic(_ t: CGFloat) -> CGFloat {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        let u = 1 - t
        return 1 - u * u * u
    }

    func motionUnit(_ ease: MotionEase, _ t: CGFloat) -> CGFloat {
        switch ease {
        case .spring: return springUnit(t)
        case .settle: return easeOutCubic(t)
        }
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
        return containedOrRaw(lerpRect(m.from, m.to, motionUnit(m.ease, max(0, t))), slot: m.slot, minSize: m.minSize)
    }

    // 落点与目标差 4pt 以上就记一笔（拖动分隔线时不记，免得刷屏），
    // 并按维学习最小尺寸：只有 post 比 target 大 4pt 以上的维才记为该维下限（覆盖式），
    // 落准的维不改；学到新值就置位，下一轮 tick 重排一次（让位/浮动随即生效）。
    // 学习值永不为 0：未知维按无约束处理（消费处遇 0 用当前尺寸/底线兜底，绝不按 0 用）；
    // 瞬态小窗口与退化目标不学习，免得毒化按应用的学习值。
    func logPlacementMismatch(name: String, pre: CGSize, target: CGSize, post: CGSize?) {
        if draggingDividerID == nil, let post,
           abs(post.width - target.width) > 4 || abs(post.height - target.height) > 4 {
            let learned = name.isEmpty ? .zero : (learnedMinSizes[name] ?? .zero)
            let widthKnown = abs(post.width - target.width) <= 4
                || (learned.width > 1 && abs(post.width - learned.width) <= 4 && post.width + 1 >= target.width)
            let heightKnown = abs(post.height - target.height) <= 4
                || (learned.height > 1 && abs(post.height - learned.height) <= 4 && post.height + 1 >= target.height)
            // 已经学过的下限再撞上同一尺寸时不再刷屏。新的差值才记。
            if !(widthKnown && heightKnown) {
                logDiag("size mismatch: \(name) pre=\(Int(pre.width))x\(Int(pre.height)) target=\(Int(target.width))x\(Int(target.height)) post=\(Int(post.width))x\(Int(post.height))")
            }
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
                // 这一维已经落进比已学值更小的格子：旧下限是虚高的，忘掉，下一轮按未知再试。
                if cur.width > 1, target.width + 4 < cur.width, abs(post.width - target.width) <= 4 {
                    cur.width = 0
                    changed = true
                }
                if cur.height > 1, target.height + 4 < cur.height, abs(post.height - target.height) <= 4 {
                    cur.height = 0
                    changed = true
                }
                // 窗口比目标大，才可能是最小尺寸。没离开接近全屏的原尺寸，不当成下限（那是拒绝缩小，不是最小值）。
                if post.width > target.width + 4, post.width > 0 {
                    let refusedFullscreen = abs(post.width - pre.width) <= 4 && maxW > 0 && post.width > maxW * 0.80
                    if !refusedFullscreen {
                        let v = min(post.width, maxW > 0 ? maxW * 0.92 : post.width)
                        if v > 1, abs(cur.width - v) > 0.5 { cur.width = v; changed = true }
                    }
                }
                if post.height > target.height + 4, post.height > 0 {
                    let refusedFullscreen = abs(post.height - pre.height) <= 4 && maxH > 0 && post.height > maxH * 0.80
                    if !refusedFullscreen {
                        let v = min(post.height, maxH > 0 ? maxH * 0.92 : post.height)
                        if v > 1, abs(cur.height - v) > 0.5 { cur.height = v; changed = true }
                    }
                }
                if changed {
                    if cur.width <= 0, cur.height <= 0 {
                        learnedMinSizes.removeValue(forKey: name)
                    } else {
                        learnedMinSizes[name] = cur
                    }
                    saveLearnedMinSizes()
                    learnedMinChanged = true
                    logDiag("min-size learned: \(name) \(Int(cur.width))x\(Int(cur.height))")
                }
            }
        }
    }

    /// 把一扇窗送到 target。animated 时从当前（或飞行中）帧起跳，同一目的地不重开弹簧。
    /// 分隔线拖动传 animated: false，手跟着走。
    func containedOrRaw(_ proposed: CGRect, slot: CGRect?, minSize: CGSize) -> CGRect {
        guard let slot else { return proposed }
        return frameContained(in: slot, proposed: proposed, minSize: minSize) ?? slot
    }

    func placeFrame(_ el: AXUIElement, _ target: CGRect, key: String, animated: Bool, learnName: String = "", preSize: CGSize? = nil, ease: MotionEase? = nil, duration: CFTimeInterval? = nil, slot: CGRect? = nil, minSize: CGSize = .zero) {
        let chosen = ease ?? preferredEase[key] ?? .spring
        preferredEase.removeValue(forKey: key)
        let dur = duration ?? (chosen == .settle ? 0.34 : 0.5)
        let final = containedOrRaw(target, slot: slot, minSize: minSize)
        if animated, let existing = frameMotions[key], framesClose(existing.to, final), existing.ease == chosen {
            return
        }
        let from = inFlightFrame(key: key) ?? getFrame(el, screenHeight: mainHeight()) ?? final
        if !animated || framesClose(from, final) {
            frameMotions.removeValue(forKey: key)
            applyAXFrame(el, final)
            if let pre = preSize {
                logPlacementMismatch(name: learnName, pre: pre, target: final.size, post: getSize(el))
            }
            stopMotionTimerIfIdle()
            return
        }
        frameMotions[key] = FrameMotion(
            element: el, key: key, from: from, to: final,
            start: CACurrentMediaTime(), duration: dur,
            preSize: preSize, learnName: learnName, ease: chosen,
            slot: slot, minSize: minSize
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
                let raw = lerpRect(m.from, m.to, motionUnit(m.ease, t))
                applyAXFrame(m.element, containedOrRaw(raw, slot: m.slot, minSize: m.minSize))
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
            if dimsSuppressed, dragState == nil {
                dimsSuppressed = false
            }
            refreshGrips()
            refreshStackMarkers()
            refreshDimLayers()
            refreshHighlights()
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
        let g = globalSettings.gap
        let dividers = deriveDividers(frames: frames, gap: g, sid: sid)
        var out = frames
        for d in dividers {
            let key = "\(sid)-\(globalSettings.kind.rawValue)-\(tileCount)-\(d.id)"
            guard let f = splitOverrides[key] ?? splitOverrides["\(sid)-\(tileCount)-\(d.id)"] ?? splitOverrides["\(tileCount)-\(d.id)"] else { continue }
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
        // 命中区就是整条 8pt 缝。画一条细握把，完全透明的窗口不会出现在窗口列表里。
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: (divider?.vertical ?? true) ? .resizeLeftRight : .resizeUpDown)
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
        override func draw(_ dirtyRect: NSRect) {
            let vertical = divider?.vertical ?? true
            let pill = vertical ? bounds.insetBy(dx: 2.5, dy: 8) : bounds.insetBy(dx: 8, dy: 2.5)
            guard pill.width > 1, pill.height > 1 else { return }
            NSColor.labelColor.withAlphaComponent(0.55).setFill()
            let r = min(pill.width, pill.height) / 2
            NSBezierPath(roundedRect: pill, xRadius: r, yRadius: r).fill()
        }
        override func mouseDown(with event: NSEvent) { onDrag?(self, 0, 0) }
        // 面板平时不是 key window；首击也必须送达，否则缝手柄永远拖不起来。
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDragged(with event: NSEvent) {
            let m = NSEvent.mouseLocation
            onDrag?(self, 1, divider.vertical ? m.x : m.y)
        }
        override func mouseUp(with event: NSEvent) { onDrag?(self, 2, 0) }
    }

    // 菜单栏应用经常不是前台，NSPanel 默认 hidesOnDeactivate 会把缝藏掉。
    // 握把用 statusBar，盖在暗色层（floating）上面；悬停条再用更高的一级。
    func prepareOverlay(_ panel: NSPanel, level: NSWindow.Level, ignoresMouse: Bool) {
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.ignoresMouseEvents = ignoresMouse
    }

    func raiseGrips() {
        for (_, panel) in gripPanels where panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func framesOverlap(_ frames: [CGRect]) -> Bool {
        for i in frames.indices {
            for j in frames.indices where j > i {
                let inter = frames[i].intersection(frames[j])
                if !inter.isNull, inter.width > 1, inter.height > 1 { return true }
            }
        }
        return false
    }

    // 拖缝：按当前格子重算两侧帧，先缩后涨，任意时刻不相交。不走 tile()，
    // 避免中途重新收集窗口把还没跟上的那一侧丢掉。
    func applyDividerDrag(screen: NSScreen, dividerID: String, vertical: Bool, proposed: CGFloat) {
        let sid = screenID(screen)
        guard var tiles = lastTilesByScreen[sid], tiles.count >= 2 else { return }
        let vf = screen.visibleFrame
        let oldFrames = tiles.map { $0.frame }
        let g = globalSettings.gap
        let half = g / 2
        guard let d = deriveDividers(frames: oldFrames, gap: g, sid: sid).first(where: { $0.id == dividerID && $0.vertical == vertical }) else { return }
        var lo = d.minCenter
        var hi = d.maxCenter
        for t in tiles {
            let need = stackNeed(t.stack)
            let minW = max(need.width > 1 ? need.width : 0, 160)
            let minH = max(need.height > 1 ? need.height : 0, 120)
            if d.vertical {
                if abs(t.frame.maxX - (d.center - half)) < 1.5 {
                    lo = max(lo, t.frame.minX + minW + half)
                } else if abs(t.frame.minX - (d.center + half)) < 1.5 {
                    hi = min(hi, t.frame.maxX - minW - half)
                }
            } else {
                if abs(t.frame.minY - (d.center + half)) < 1.5 {
                    hi = min(hi, t.frame.maxY - minH - half)
                } else if abs(t.frame.maxY - (d.center - half)) < 1.5 {
                    lo = max(lo, t.frame.minY + minH + half)
                }
            }
        }
        for t in tiles {
            guard frameMotions[winKey(t.top)] == nil,
                  let actual = getFrame(t.top.element, screenHeight: mainHeight()) else { continue }
            if d.vertical {
                if abs(t.frame.maxX - (d.center - half)) < 1.5, actual.maxX > t.frame.maxX + tileFitTolerance {
                    lo = max(lo, actual.maxX + half)
                } else if abs(t.frame.minX - (d.center + half)) < 1.5, actual.minX < t.frame.minX - tileFitTolerance {
                    hi = min(hi, actual.minX - half)
                }
            } else {
                if abs(t.frame.minY - (d.center + half)) < 1.5, actual.minY < t.frame.minY - tileFitTolerance {
                    hi = min(hi, actual.minY - half)
                } else if abs(t.frame.maxY - (d.center - half)) < 1.5, actual.maxY > t.frame.maxY + tileFitTolerance {
                    lo = max(lo, actual.maxY + half)
                }
            }
        }
        // 两侧下限打架时停在原缝。min(max(value, lo), hi) 在 lo>hi 时会落到 hi，把另一侧盖住。
        let clamped: CGFloat = lo <= hi ? min(max(proposed, lo), hi) : d.center
        var newFrames = oldFrames
        for i in oldFrames.indices {
            let o = oldFrames[i]
            if d.vertical {
                if abs(o.maxX - (d.center - g / 2)) < 1.5 {
                    newFrames[i].size.width = max(1, clamped - g / 2 - o.minX)
                } else if abs(o.minX - (d.center + g / 2)) < 1.5 {
                    let nm = clamped + g / 2
                    newFrames[i].size.width = max(1, o.maxX - nm)
                    newFrames[i].origin.x = nm
                }
            } else {
                if abs(o.minY - (d.center + g / 2)) < 1.5 {
                    let nm = clamped + g / 2
                    newFrames[i].size.height = max(1, o.maxY - nm)
                    newFrames[i].origin.y = nm
                } else if abs(o.maxY - (d.center - g / 2)) < 1.5 {
                    newFrames[i].size.height = max(1, clamped - g / 2 - o.minY)
                }
            }
        }
        if framesOverlap(newFrames) { return }
        struct Job {
            let el: AXUIElement
            let old: CGRect
            let new: CGRect
            let key: String
            let shrinking: Bool
        }
        var jobs: [Job] = []
        for (i, t) in tiles.enumerated() {
            let newF = newFrames[i]
            for w in t.stack {
                let key = winKey(w)
                let old = lastPlacedFrames[key] ?? t.frame
                let shrinking = newF.width <= old.width + 0.5 && newF.height <= old.height + 0.5
                jobs.append(Job(el: w.element, old: old, new: newF, key: key, shrinking: shrinking))
                frameMotions.removeValue(forKey: key)
            }
            tiles[i].frame = newF
        }
        let mh = mainHeight()
        for j in jobs where j.shrinking {
            setSize(j.el, j.new.size)
            setPosition(j.el, CGPoint(x: j.new.minX, y: mh - j.new.maxY))
        }
        for j in jobs where !j.shrinking {
            let step = CGSize(width: min(j.old.width, j.new.width), height: min(j.old.height, j.new.height))
            setSize(j.el, step)
            setPosition(j.el, CGPoint(x: j.new.minX, y: mh - j.new.maxY))
            setSize(j.el, j.new.size)
        }
        for j in jobs { lastPlacedFrames[j.key] = j.new }
        lastTilesByScreen[sid] = tiles
        if screenID(activeScreen()) == sid { lastTiles = tiles }
        let frac = vertical
            ? (clamped - vf.minX) / max(vf.width, 1)
            : (clamped - vf.minY) / max(vf.height, 1)
        splitOverrides["\(sid)-\(globalSettings.kind.rawValue)-\(tiles.count)-\(dividerID)"] = frac
        if let panel = gripPanels["\(sid)-\(dividerID)"] {
            if vertical {
                panel.setFrameOrigin(NSPoint(x: clamped - panel.frame.width / 2, y: panel.frame.minY))
            } else {
                panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: clamped - panel.frame.height / 2))
            }
        }
        for (i, f) in newFrames.enumerated() {
            let dk = "\(sid):\(i)"
            dimPanels[dk]?.setFrame(f, display: true)
            if let hp = highlightPanels[dk] {
                hp.setFrame(f.insetBy(dx: -tileBorderPad, dy: -tileBorderPad), display: true)
            }
        }
        raiseGrips()
    }

    func refreshGrips() {
        guard AXIsProcessTrusted(), autoTile else {
            hideGrips()
            return
        }
        guard draggingDividerID == nil else { return }  // 拖动中不重建手柄
        var seen: Set<String> = []
        for (sid, tiles) in lastTilesByScreen where !tiles.isEmpty {
            guard NSScreen.screens.contains(where: { screenID($0) == sid }) else { continue }
            let frames = tiles.map { $0.frame }
            let dividers = deriveDividers(frames: frames, gap: globalSettings.gap, sid: sid)
            for d in dividers {
                let key = "\(sid)-\(d.id)"
                seen.insert(key)
                let thickness = max(globalSettings.gap, 8)
                let span = max(8, d.hi - d.lo)
                let rect: NSRect = d.vertical
                    ? NSRect(x: d.center - thickness / 2, y: d.lo, width: thickness, height: span)
                    : NSRect(x: d.lo, y: d.center - thickness / 2, width: span, height: thickness)
                if let panel = gripPanels[key] {
                    panel.setFrame(rect, display: true)
                    prepareOverlay(panel, level: .statusBar, ignoresMouse: false)
                    (panel.contentView as? GripView)?.divider = d
                    panel.contentView?.needsDisplay = true
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
                            self.applyDividerDrag(screen: scr, dividerID: dd.id, vertical: dd.vertical, proposed: value)
                        default:
                            self.draggingDividerID = nil
                            self.dragQuiet = false
                            self.refreshGrips()
                            log("split dragged: \(dd.id)")
                            self.refreshPanel()
                        }
                    }
                    let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    prepareOverlay(panel, level: .statusBar, ignoresMouse: false)
                    panel.contentView = view
                    panel.orderFrontRegardless()
                    gripPanels[key] = panel
                }
            }
        }
        for (id, panel) in gripPanels where !seen.contains(id) {
            panel.orderOut(nil)
            gripPanels.removeValue(forKey: id)
        }
        raiseGrips()
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
            p.level = .popUpMenu
            p.hidesOnDeactivate = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
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
        // 面板平时不是 key window；首击也必须送达，否则握把点按时灵时不灵。
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
                    prepareOverlay(panel, level: .popUpMenu, ignoresMouse: false)
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
                b.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.7).cgColor
                b.layer?.borderWidth = 1
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
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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
    // Primary / Focus / Float 是图标加文字，没有快捷键键帽。堆叠芯片带应用图标。
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
    var hoverFocusDoneFor: String?

    func setupHoverBar() {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x1a / 255, alpha: 0.96).cgColor
        pill.layer?.cornerRadius = 12
        hoverBarView = pill
        hoverPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 34), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hoverPanel.level = .popUpMenu
        hoverPanel.hidesOnDeactivate = false
        hoverPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hoverPanel.backgroundColor = .clear
        hoverPanel.isOpaque = false
        hoverPanel.hasShadow = true
        pill.frame = NSRect(origin: .zero, size: hoverPanel.frame.size)
        pill.autoresizingMask = [.width, .height]
        hoverPanel.contentView = pill
    }

    func tintedSymbol(_ name: String, point: CGFloat, color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: point, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        let size = base.size.width > 1 && base.size.height > 1 ? base.size : NSSize(width: point, height: point)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        base.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    func appIcon(pid: pid_t, side: CGFloat) -> NSImage? {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    func hoverChip(_ title: String, tag: Int, action: Selector, emphasized: Bool, enabled: Bool = true, icon: NSImage? = nil) -> NSButton {
        let font = NSFont.systemFont(ofSize: 11, weight: emphasized ? .semibold : .regular)
        let b = NSButton(title: title, target: self, action: action)
        b.tag = tag
        b.font = font
        b.isBordered = false
        b.bezelStyle = .inline
        b.isEnabled = enabled
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        b.imageScaling = .scaleProportionallyDown
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: enabled ? NSColor.white : NSColor.white.withAlphaComponent(0.35),
            .font: font,
        ])
        if let icon {
            b.image = icon
        }
        b.wantsLayer = true
        if emphasized {
            b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
            b.layer?.cornerRadius = 6
        }
        return b
    }

    func rowContentWidth(_ row: NSStackView) -> CGFloat {
        row.layoutSubtreeIfNeeded()
        let fit = row.fittingSize.width
        if fit > 24 { return ceil(fit) }
        var w = row.edgeInsets.left + row.edgeInsets.right
        for v in row.arrangedSubviews {
            let iw = v.intrinsicContentSize.width
            w += iw > 1 ? iw : 44
        }
        if row.arrangedSubviews.count > 1 {
            w += row.spacing * CGFloat(row.arrangedSubviews.count - 1)
        }
        return ceil(max(w, 36))
    }

    /// 图标在上、文字在下。不能点的时候仍用高对比文字，避免 Primary 被灰成看不见。
    func hoverColumn(_ title: String, symbol: String, action: Selector, strong: Bool) -> NSButton {
        let ink = NSColor.white.withAlphaComponent(strong ? 1 : 0.86)
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .inline
        b.imagePosition = .imageAbove
        b.imageHugsTitle = true
        b.imageScaling = .scaleProportionallyDown
        b.font = font
        b.image = tintedSymbol(symbol, point: 15, color: ink)
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: ink,
            .font: font,
        ])
        b.isEnabled = true
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(strong ? 0.12 : 0.06).cgColor
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        return b
    }

    func showHoverBar(for tile: (stack: [WinInfo], frame: CGRect, top: WinInfo), screen: NSScreen, sid: CGDirectDisplayID, tileIndex: Int) {
        guard hoverPanel != nil else { return }
        hoverSid = sid
        hoverTile = tileIndex
        hoverBarKind = 0
        let topIdx = min(stackTops[stackTopKey(sid, tileIndex)] ?? 0, tile.stack.count - 1)
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        column.translatesAutoresizingMaskIntoConstraints = false
        var chipWidth: CGFloat = 0
        if tile.stack.count > 1 {
            let chips = NSStackView()
            chips.orientation = .horizontal
            chips.spacing = 4
            chips.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
            chips.addArrangedSubview(hoverChip("‹", tag: 0, action: #selector(hoverStackStep(_:)), emphasized: false))
            for (idx, w) in tile.stack.enumerated() {
                chips.addArrangedSubview(hoverChip(w.appName, tag: idx, action: #selector(hoverPickStack(_:)), emphasized: idx == topIdx, icon: appIcon(pid: w.pid, side: 14)))
            }
            chips.addArrangedSubview(hoverChip("›", tag: 1, action: #selector(hoverStackStep(_:)), emphasized: false))
            chipWidth = rowContentWidth(chips)
            chips.frame = NSRect(x: 0, y: 0, width: max(chipWidth, 40), height: 28)
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = chips
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            scroll.heightAnchor.constraint(equalToConstant: 28).isActive = true
            column.addArrangedSubview(scroll)
            let line = NSBox()
            line.boxType = .separator
            column.addArrangedSubview(line)
        }
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false
        // 已在第 0 格顶部时 Primary 不交换，但文字保持可读。点击由 hoverPrimary 自己拦住。
        let primaryWorks = tileIndex != 0
        actions.addArrangedSubview(hoverColumn("Primary", symbol: "sidebar.left", action: #selector(hoverPrimary(_:)), strong: primaryWorks))
        actions.addArrangedSubview(hoverColumn("Focus", symbol: "arrow.up.left.and.arrow.down.right", action: #selector(hoverFocus(_:)), strong: true))
        actions.addArrangedSubview(hoverColumn("Float", symbol: "square.on.square", action: #selector(hoverFloat(_:)), strong: true))
        column.addArrangedSubview(actions)
        let pill = hoverBarView ?? NSView()
        for v in pill.subviews { v.removeFromSuperview() }
        pill.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: pill.topAnchor),
            column.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])
        pill.layoutSubtreeIfNeeded()
        let vf = screen.visibleFrame
        let barW = min(max(300, chipWidth + 16), vf.width - 16)
        let barH = max(column.fittingSize.height, tile.stack.count > 1 ? 92 : 60)
        var x = tile.frame.midX - barW / 2
        x = min(max(x, vf.minX + 4), vf.maxX - barW - 4)
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

    // 手动 Float：放到所在屏可视区中央，宽约 60%、高约 75%。
    // 已知最小尺寸更大时抬到最小尺寸，四周仍留在可视区 16pt 以内。其余窗口立即重排填空位。
    // 专注窗口被浮动时清掉 Focus 状态：窗口是被浮动，不是按进入前的帧还原。
    func floatWindow(_ w: WinInfo, source: String) {
        let key = winKey(w)
        guard !floatedKeys.contains(key) else { return }
        let screen = screenForFrame(w.frame)
        let vf = screen.visibleFrame
        if key == focusKey {
            focusKey = nil
            focusScreen = nil
            focusSavedFrames = nil
            focusSavedTops = nil
            focusSavedActive = nil
            log("focus off: floated")
        }
        floatedKeys.insert(key)
        let need = effectiveMin(for: w)
        var cw = min(vf.width * 0.60, vf.width - 16)
        var ch = min(vf.height * 0.75, vf.height - 16)
        if need.width > 1 { cw = min(max(cw, need.width), vf.width - 16) }
        if need.height > 1 { ch = min(max(ch, need.height), vf.height - 16) }
        let frame = CGRect(x: vf.midX - cw / 2, y: vf.midY - ch / 2, width: cw, height: ch)
        placeFrame(w.element, frame, key: key, animated: true)
        lastPlacedFrames[key] = frame
        log("\(source) float -> \(w.appName) centered")
        forceTile()
        refreshPanel()
    }

    // 悬浮窗口最小悬停条：只有 Tile（点按重新进入平铺并重算，不是精确恢复）；
    // 灰掉的 Primary/Focus 会让整条看起来像坏了，故不画。
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
        row.addArrangedSubview(hoverChip("Tile", tag: 0, action: #selector(hoverTileBack(_:)), emphasized: false, icon: tintedSymbol("square.grid.2x2", point: 11, color: .white)))
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
        let vf = screen.visibleFrame
        // 单按钮按内容宽，不再垫到 180，避免「Tile」左边一个字、右边空一截。
        let barW = min(rowContentWidth(row), vf.width - 16)
        let barH = max(row.fittingSize.height, 32)
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
        row.addArrangedSubview(hoverChip("Focus", tag: 0, action: #selector(hoverFocus(_:)), emphasized: false, icon: tintedSymbol("arrow.up.left.and.arrow.down.right", point: 11, color: .white)))
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
        let vf = screen.visibleFrame
        let barW = min(rowContentWidth(row), vf.width - 16)
        let barH = max(row.fittingSize.height, 32)
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
                let zone = CGRect(x: t.frame.minX, y: t.frame.maxY - 24, width: t.frame.width, height: 44)
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
            let zone = CGRect(x: vf.minX, y: vf.maxY - 24, width: vf.width, height: 44)
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
            if barFrame.contains(m) {
                // 后建的握把/标记/暗色层不得盖住条：悬停期间把条顶回最前。
                hoverPanel?.orderFront(nil)
                return
            }
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
                   CGRect(x: $0.frame.minX, y: $0.frame.maxY - 24, width: $0.frame.width, height: 44).contains(m)
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
            hoverFocusDoneFor = nil
            return
        }
        guard CACurrentMediaTime() - hoverZoneSince >= 0.22 else { return }
        if hoverFocus, hoverFocusDoneFor != id {
            hoverFocusDoneFor = id
            let top = hit.tile.top
            AXUIElementPerformAction(top.element, kAXRaiseAction as CFString)
            NSRunningApplication(processIdentifier: top.pid)?.activate()
            log("hover focus -> \(top.appName)")
        }
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

    // 活动格细描边（Borders）和其他格子的暗色层（No peek，强度由 Dim 决定）。
    // 描边画在格子外侧的缝里。Focus 和 Clean Space 时两者都拿掉。

    var dimPanels: [String: NSPanel] = [:]
    var highlightPanels: [String: NSPanel] = [:]

    func dimContent() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(dimStrength).cgColor
        return v
    }

    func refreshDimLayers() {
        guard noPeek, !dimsSuppressed else {
            removeDimLayers()
            return
        }
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
                    prepareOverlay(p, level: .floating, ignoresMouse: true)
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
        // 暗色层后建，会盖住同级窗口。握把在更高的一级，这里再顶一次。
        raiseGrips()
    }

    func removeDimLayers() {
        for (_, p) in dimPanels { p.orderOut(nil) }
        dimPanels.removeAll()
    }

    func refreshHighlights() {
        guard showBorders, AXIsProcessTrusted(), autoTile, focusKey == nil, !cleanSpaceOn else {
            hideHighlights()
            return
        }
        let ink = NSColor.controlAccentColor.withAlphaComponent(0.4)
        var wanted: [String: CGRect] = [:]
        for (sid, tiles) in lastTilesByScreen where !tiles.isEmpty {
            let active = min(lastActiveTileByScreen[sid] ?? 0, tiles.count - 1)
            wanted["\(sid):\(active)"] = tiles[active].frame.insetBy(dx: -tileBorderPad, dy: -tileBorderPad)
        }
        for (i, frame) in wanted {
            if let p = highlightPanels[i] {
                if p.frame != frame { p.setFrame(frame, display: true) }
                if let v = p.contentView as? HighlightBorderView {
                    v.strokeColor = ink
                    v.lineWidth = 1
                    v.pad = tileBorderPad
                    v.outset = 1.5
                    v.needsDisplay = true
                }
                if !p.isVisible { p.orderFront(nil) }
            } else {
                let view = HighlightBorderView(frame: NSRect(origin: .zero, size: frame.size))
                view.strokeColor = ink
                view.lineWidth = 1
                view.pad = tileBorderPad
                view.outset = 1.5
                let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                prepareOverlay(p, level: .floating, ignoresMouse: true)
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

    func enableCleanSpace() {
        guard AXIsProcessTrusted() else { return }
        if focusKey != nil { exitFocus() }
        let screen = activeScreen()
        let sid = screenID(screen)
        let windows = collectWindows(on: screen)
        guard let top = windows.first(where: { $0.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier }) ?? windows.first else {
            log("clean space skipped: no window")
            cleanSpaceSwitch?.state = .off
            return
        }
        var saved: [String: CGRect] = [:]
        for w in windows {
            let key = winKey(w)
            if saved[key] == nil { saved[key] = w.frame }
        }
        cleanSpaceSavedFrames = saved
        cleanSpaceOn = true
        cleanSpaceScreen = sid
        let vf = screen.visibleFrame
        let need = effectiveMin(for: top)
        let cur = top.frame.size
        var width = min(max(cur.width, need.width > 1 ? need.width : 0), vf.width * 0.72)
        var height = min(max(cur.height, need.height > 1 ? need.height : 0), vf.height * 0.72)
        if width < 1 { width = vf.width * 0.6 }
        if height < 1 { height = vf.height * 0.6 }
        width = min(width, vf.width - 16)
        height = min(height, vf.height - 16)
        let hole = CGRect(x: vf.midX - width / 2, y: vf.midY - height / 2, width: width, height: height)
        cleanSpaceHole = hole
        for w in windows where winKey(w) != winKey(top) {
            AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            if !boolAttr(w.element, kAXMinimizedAttribute as CFString) {
                let lowest = NSScreen.screens.map { $0.frame.minY }.min() ?? 0
                let parked = CGRect(x: w.frame.minX, y: lowest - w.frame.height - 120, width: max(w.frame.width, 80), height: max(w.frame.height, 60))
                placeFrame(w.element, parked, key: winKey(w), animated: false)
            }
        }
        placeFrame(top.element, hole, key: winKey(top), animated: true)
        lastPlacedFrames[winKey(top)] = hole
        AXUIElementPerformAction(top.element, kAXRaiseAction as CFString)
        hideGrips()
        hideHoverBar()
        hideHighlights()
        removeDimLayers()
        showCleanDim(on: screen, hole: hole)
        log("clean space on: \(top.appName)")
        showToast("Clean Space", detail: "Turn it off in the menu to put windows back.", on: screen)
    }

    func showCleanDim(on screen: NSScreen, hole: CGRect) {
        removeCleanDim()
        let vf = screen.visibleFrame
        let rects = [
            CGRect(x: vf.minX, y: hole.maxY, width: vf.width, height: max(0, vf.maxY - hole.maxY)),
            CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: max(0, hole.minY - vf.minY)),
            CGRect(x: vf.minX, y: hole.minY, width: max(0, hole.minX - vf.minX), height: hole.height),
            CGRect(x: hole.maxX, y: hole.minY, width: max(0, vf.maxX - hole.maxX), height: hole.height),
        ]
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        for r in rects where r.width > 1 && r.height > 1 {
            let p = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            prepareOverlay(p, level: level, ignoresMouse: true)
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
            p.contentView = v
            p.orderFront(nil)
            cleanDimPanels.append(p)
        }
    }

    func removeCleanDim() {
        for p in cleanDimPanels { p.orderOut(nil) }
        cleanDimPanels.removeAll()
    }

    func restoreCleanSpaceFrames() {
        let saved = cleanSpaceSavedFrames
        let all = collectWindows(includeFloated: true, onlyCurrentSpace: false)
        for (key, frame) in saved {
            guard let w = all.first(where: { winKey($0) == key }) else { continue }
            if boolAttr(w.element, kAXMinimizedAttribute as CFString) {
                AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            placeFrame(w.element, frame, key: key, animated: true)
            lastPlacedFrames[key] = frame
        }
    }

    func exitCleanSpace() {
        guard cleanSpaceOn || !cleanSpaceSavedFrames.isEmpty else { return }
        cleanSpaceOn = false
        cleanSpaceScreen = nil
        removeCleanDim()
        restoreCleanSpaceFrames()
        let saved = cleanSpaceSavedFrames
        log("clean space off: restore")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.cleanSpaceOn else { return }
            let again = self.collectWindows(includeFloated: true, onlyCurrentSpace: false)
            for (key, frame) in saved {
                guard let w = again.first(where: { self.winKey($0) == key }) else { continue }
                self.placeFrame(w.element, frame, key: key, animated: false)
                self.lastPlacedFrames[key] = frame
            }
            self.cleanSpaceSavedFrames = [:]
            self.cleanSpaceHole = .zero
            self.lastSignature = self.fullSignature()
            self.refreshGrips()
            self.refreshDimLayers()
            self.refreshHighlights()
        }
    }

    /// Retile 退出：先把窗口请回来，再按当前布局重排，不保留进入前的帧。
    func cancelCleanSpace() {
        cleanSpaceOn = false
        cleanSpaceScreen = nil
        removeCleanDim()
        restoreCleanSpaceFrames()
        cleanSpaceSavedFrames = [:]
        cleanSpaceHole = .zero
        log("clean space cancelled")
    }

    func showTabView() {
        tabPanel?.orderOut(nil)
        let windows = collectWindows()
        let screen = activeScreen()
        let vf = screen.visibleFrame
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 280), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        prepareOverlay(panel, level: .popUpMenu, ignoresMouse: false)
        panel.hasShadow = true
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layer?.cornerRadius = 12
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        column.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Tab view")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        column.addArrangedSubview(title)
        if windows.isEmpty {
            let empty = NSTextField(labelWithString: "No tiled windows")
            empty.textColor = .secondaryLabelColor
            column.addArrangedSubview(empty)
        }
        for w in windows.prefix(16) {
            let b = NSButton(title: w.appName, target: self, action: #selector(tabViewPick(_:)))
            b.bezelStyle = .inline
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.image = appIcon(pid: w.pid, side: 20) ?? tintedSymbol("macwindow", point: 14, color: .labelColor)
            b.alignment = .left
            b.identifier = NSUserInterfaceItemIdentifier(winKey(w))
            column.addArrangedSubview(b)
        }
        let close = NSButton(title: "Close", target: self, action: #selector(tabViewClose(_:)))
        close.bezelStyle = .inline
        column.addArrangedSubview(close)
        root.addSubview(column)
        panel.contentView = root
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.widthAnchor.constraint(equalToConstant: 340),
        ])
        root.layoutSubtreeIfNeeded()
        let h = min(max(column.fittingSize.height, 120), vf.height - 40)
        let frame = NSRect(x: vf.midX - 180, y: vf.midY - h / 2, width: 360, height: h)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        tabPanel = panel
    }

    @objc func tabViewClose(_ sender: NSButton) {
        tabPanel?.orderOut(nil)
        tabPanel = nil
    }

    @objc func tabViewPick(_ sender: NSButton) {
        let key = sender.identifier?.rawValue ?? ""
        tabPanel?.orderOut(nil)
        tabPanel = nil
        guard let w = collectWindows(includeFloated: true).first(where: { winKey($0) == key }) else { return }
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        log("tab view -> \(w.appName)")
    }

    func enableFocus(targetKey: String) {
        guard AXIsProcessTrusted() else { log("focus skipped: not trusted"); return }
        if cleanSpaceOn { cancelCleanSpace() }
        let all = collectWindows()
        guard let w = all.first(where: { winKey($0) == targetKey }) else {
            log("focus skipped: target window gone"); return
        }
        let screen = screenForFrame(w.frame)
        let sid = screenID(screen)
        // 进入前快照：本屏各窗口精确帧、格子栈顶、活动格；退出时精确还原用。
        // 其他屏不受 Focus 影响，不快照。
        let screenWindows = collectWindows(on: screen)
        // 同名多窗时 winKey 仍可能撞车（拿不到窗口号）。逐个写入，重复键留下先看到的那扇，绝不 uniqueKeys 断言。
        var saved: [String: CGRect] = [:]
        for w in screenWindows {
            let k = winKey(w)
            if saved[k] == nil {
                saved[k] = w.frame
            } else {
                log("focus snapshot duplicate key skipped: \(w.appName)")
            }
        }
        focusSavedFrames = saved
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
        // 窗口号键不随标题变。对得上就按键还原。对不上时再退回 pid 多重集
        // （标题变了、又没拿到窗口号），只还原专注那一扇，其余窗口 Focus 期间没动过。
        let pidOfKey: (String) -> String = { key in
            let cut = key.firstIndex(where: { $0 == "#" || $0 == "|" }) ?? key.endIndex
            return String(key[..<cut])
        }
        let keysMatch = current.map { winKey($0) }.sorted() == savedFrames.keys.sorted()
        let pidMatch = current.map { "\($0.pid)" }.sorted() == savedFrames.keys.map(pidOfKey).sorted()
        let setUnchanged = keysMatch || (pidMatch && current.count == savedFrames.count)
        if setUnchanged {
            // 精确恢复：只有专注窗口动过（铺满），把它放回保存帧；其余窗口 Focus 期间没动过。
            // 专注窗口按 pid 兜底：标题变了也要还原它；同 pid 多窗时取帧最接近可见区的（即铺满的那扇）。
            let vf = screen.visibleFrame
            let fw = current.first(where: { winKey($0) == fk })
                ?? current.filter { pidOfKey(winKey($0)) == pidOfKey(fk) }
                    .min(by: { abs($0.frame.width - vf.width) + abs($0.frame.height - vf.height) < abs($1.frame.width - vf.width) + abs($1.frame.height - vf.height) })
            if let fw, let frame = savedFrames[fk] {
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

    // 拖动起点是否落在我们自己的交互窗上（面板、分隔缝）；
    // 暗色层与高亮层是穿透视觉层，不算交互窗，落在它们上面仍视为落在下方磁贴上。
    // 悬停条与橙色握把不算阻挡：⌘ 按下已明确是拖动意图（不是点按钮），
    // 悬停条会在拖动开始后收起；否则在标题栏区停留 0.22s 出条后，
    // ⌘ 抓标题栏必被条挡住、交换永远触发不了。
    func pointOnOwnInteractiveWindow(_ p: CGPoint) -> Bool {
        if panelPopover.isShown,
           let w = panelPopover.contentViewController?.view.window, w.frame.contains(p) { return true }
        for (_, g) in gripPanels where g.isVisible && g.frame.contains(p) { return true }
        for (_, d) in dotPanels where d.isVisible && d.frame.contains(p) { return true }
        if let sp = stackPanel, sp.isVisible, sp.frame.contains(p) { return true }
        return false
    }

    // mouseDown：⌘ 按下且落在某磁贴上 → 只记录待定拖动，不吞这次按下；
    // 只有鼠标实际移动超过约 3pt 才进入拖动模式，未拖动时按下/松手原样放行
    func dragMouseDown(_ event: CGEvent) -> Bool {
        guard AXIsProcessTrusted(), autoTile else { return false }
        let flags = event.flags
        // 按下时没按 ⌘也记下按下点：拖动中才按住 ⌘时，可从按下点重建拖动。
        if !flags.contains(.maskCommand) {
            let dp = cocoaPoint(fromQuartz: event.location) ?? event.location
            if !pointOnOwnInteractiveWindow(dp) {
                plainDownPoint = dp
                plainDownScreenID = screenID(NSScreen.screens.first(where: { $0.frame.contains(dp) }) ?? NSScreen.main ?? NSScreen.screens[0])
            } else {
                plainDownPoint = nil; plainDownScreenID = nil
            }
            return false
        }
        let p = cocoaPoint(fromQuartz: event.location) ?? event.location
        guard !pointOnOwnInteractiveWindow(p) else { return false }
        // C 批：拖动只在鼠标所在屏的磁贴上进行
        let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let sid = screenID(screen)
        guard let tiles = lastTilesByScreen[sid], tiles.count > 1 else { return false }
        let frames = tiles.map { $0.frame }
        guard let src = frames.firstIndex(where: { $0.contains(p) }) else { return false }
        // ⌘ 交换；再按住 ⌃ 则加入堆叠。只认 control 与 command。
        let mode: DragMode = flags.contains(.maskControl) ? .stack : .swap
        let top = tiles[src].top
        var pending = DragState(mode: mode, sourceTile: src, draggedKey: winKey(top), frames: frames, screenID: sid)
        pending.tileTopKeys = tiles.map { winKey($0.top) }
        pendingDrag = pending
        pendingDragPoint = p
        return false
    }

    // 按下时已经按着 ⌘：3pt 以内也吞掉拖动，系统不会另开一次窗口拖拽跟我们抢位置。
    // 超过 3pt 才抬起窗口跟手。抓后才按 ⌘ 的那条路径系统已经在拖，我们不再搬窗口。
    func dragMouseDragged(_ event: CGEvent) -> Bool {
        let p = cocoaPoint(fromQuartz: event.location) ?? event.location
        if dragState == nil, pendingDrag == nil, event.flags.contains(.maskCommand),
           let dp = plainDownPoint, let dsid = plainDownScreenID {
            let dx = p.x - dp.x, dy = p.y - dp.y
            if dx * dx + dy * dy > 9,
               let screen = NSScreen.screens.first(where: { screenID($0) == dsid }),
               let tiles = lastTilesByScreen[dsid], tiles.count > 1 {
                let frames = tiles.map { $0.frame }
                if let src = frames.firstIndex(where: { $0.contains(dp) }) {
                    let mode: DragMode = event.flags.contains(.maskControl) ? .stack : .swap
                    var d = DragState(mode: mode, sourceTile: src, draggedKey: winKey(tiles[src].top), frames: frames, screenID: dsid)
                    d.tileTopKeys = tiles.map { winKey($0.top) }
                    d.ownsDrag = false
                    d.originFrame = lastPlacedFrames[d.draggedKey] ?? frames[src]
                    dragState = d
                    dragQuiet = true
                    dimsSuppressed = true
                    removeDimLayers()
                    plainDownPoint = nil; plainDownScreenID = nil
                    hideHoverBar()
                    log("drag start mode=\(mode == .swap ? "swap" : "stack") tile=\(src) (mid-drag ⌘)")
                }
            }
        }
        if dragState == nil, let pd = pendingDrag {
            let dx = p.x - pendingDragPoint.x, dy = p.y - pendingDragPoint.y
            if dx * dx + dy * dy <= 9 { return true }
            pendingDrag = nil
            var d = pd
            beginOwnedDrag(&d, pointer: pendingDragPoint)
            dragState = d
            dragQuiet = true
            log("drag start mode=\(pd.mode == .swap ? "swap" : "stack") tile=\(pd.sourceTile)")
        }
        guard var d = dragState else { return false }
        if d.ownsDrag { trackOwnedDrag(&d, pointer: p) }
        updateDragTarget(&d, pointer: p)
        return true
    }

    // 松手：落到另一磁贴就交换或进堆叠，两边从当前帧落定到最终格子。
    // 否则把抬起的窗口放回原格。按下时已按 ⌘ 的拖动吞掉这次松手；系统已经在拖的不吞。
    func dragMouseUp(_ event: CGEvent) -> Bool {
        guard let d = dragState else {
            pendingDrag = nil
            plainDownPoint = nil; plainDownScreenID = nil
            return false
        }
        dragState = nil
        dragQuiet = false
        hideDragRing()
        let p = cocoaPoint(fromQuartz: event.location) ?? event.location
        let target = d.frames.firstIndex(where: { $0.contains(p) })
        let targetKey = target.flatMap { d.tileTopKeys.indices.contains($0) ? d.tileTopKeys[$0] : nil }
        guard let target, target != d.sourceTile, targetKey != d.draggedKey else {
            settleDragHome(d)
            suppressSnapToastUntil = Date().addingTimeInterval(1.5)
            log("drag cancelled")
            return d.ownsDrag
        }
        prepareSettle(d)
        let ok: Bool
        if d.mode == .swap {
            ok = performDragSwap(from: d.sourceTile, to: target, screenID: d.screenID, draggedKey: d.draggedKey, targetKey: targetKey ?? "")
        } else {
            performDragStack(draggedKey: d.draggedKey, to: target, screenID: d.screenID)
            ok = true
        }
        if !ok { settleDragHome(d) }
        gestureHeldKeys.remove(d.draggedKey)
        if let k = d.reactKey { gestureHeldKeys.remove(k) }
        dragLiftElement = nil
        dragReactElement = nil
        if frameMotions.isEmpty, dragState == nil {
            dimsSuppressed = false
            refreshDimLayers()
            refreshHighlights()
        }
        return d.ownsDrag
    }

    func dragCancel() {
        let d = dragState
        dragState = nil
        pendingDrag = nil
        plainDownPoint = nil; plainDownScreenID = nil
        dragQuiet = false
        hideDragRing()
        if let d {
            settleDragHome(d)
        } else {
            dimsSuppressed = false
            dragLiftElement = nil
            dragReactElement = nil
            gestureHeldKeys.removeAll()
            refreshDimLayers()
        }
    }

    func beginOwnedDrag(_ d: inout DragState, pointer: CGPoint) {
        d.ownsDrag = true
        hideHoverBar()
        dimsSuppressed = true
        removeDimLayers()
        gestureHeldKeys.insert(d.draggedKey)
        let screen = NSScreen.screens.first(where: { screenID($0) == d.screenID }) ?? NSScreen.screens.first
        let home = d.frames.indices.contains(d.sourceTile) ? d.frames[d.sourceTile] : .zero
        d.originFrame = lastPlacedFrames[d.draggedKey] ?? home
        let found = screen.flatMap { collectWindows(on: $0).first(where: { winKey($0) == d.draggedKey }) }
            ?? collectWindows().first(where: { winKey($0) == d.draggedKey })
        if let w = found {
            dragLiftElement = w.element
            let live = getFrame(w.element, screenHeight: mainHeight()) ?? d.originFrame
            d.grabOffset = CGPoint(x: pointer.x - live.minX, y: pointer.y - live.minY)
            frameMotions.removeValue(forKey: d.draggedKey)
            AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
            let vf = screen?.visibleFrame ?? .zero
            if vf.width > 1 {
                applyAXFrame(w.element, liftFrame(origin: d.originFrame, grab: d.grabOffset, pointer: pointer, vf: vf))
            }
        } else {
            d.grabOffset = CGPoint(x: pointer.x - d.originFrame.minX, y: pointer.y - d.originFrame.minY)
        }
    }

    func liftFrame(origin: CGRect, grab: CGPoint, pointer: CGPoint, vf: CGRect) -> CGRect {
        let s: CGFloat = 0.94
        let w = max(80, origin.width * s)
        let h = max(60, origin.height * s)
        var x = pointer.x - grab.x * s
        var y = pointer.y - grab.y * s
        if vf.width > w + 8 { x = min(max(x, vf.minX + 4), vf.maxX - w - 4) }
        if vf.height > h + 8 { y = min(max(y, vf.minY + 4), vf.maxY - h - 4) }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func reactedFrame(_ home: CGRect) -> CGRect {
        let dx = min(12, max(0, home.width * 0.06))
        let dy = min(12, max(0, home.height * 0.06))
        let inset = home.insetBy(dx: dx, dy: dy)
        if inset.width < 80 || inset.height < 60 { return home }
        return inset
    }

    func trackOwnedDrag(_ d: inout DragState, pointer: CGPoint) {
        guard d.ownsDrag, let el = dragLiftElement else { return }
        let screen = NSScreen.screens.first(where: { screenID($0) == d.screenID })
        let vf = screen?.visibleFrame ?? .zero
        guard vf.width > 1, d.originFrame.width > 1 else { return }
        frameMotions.removeValue(forKey: d.draggedKey)
        applyAXFrame(el, liftFrame(origin: d.originFrame, grab: d.grabOffset, pointer: pointer, vf: vf))
    }

    func updateDragTarget(_ d: inout DragState, pointer: CGPoint) {
        let target = d.frames.firstIndex(where: { $0.contains(pointer) })
        if target == d.targetTile {
            dragState = d
            return
        }
        if let old = d.reactKey, let el = dragReactElement {
            frameMotions.removeValue(forKey: old)
            placeFrame(el, d.reactHome, key: old, animated: true, ease: .settle, duration: 0.16)
            gestureHeldKeys.remove(old)
        }
        d.reactKey = nil
        d.reactHome = .zero
        dragReactElement = nil
        d.targetTile = target
        if let t = target, t != d.sourceTile {
            showDragRing(frame: d.frames[t])
            if d.mode == .swap, d.tileTopKeys.indices.contains(t), d.tileTopKeys[t] != d.draggedKey,
               let screen = NSScreen.screens.first(where: { screenID($0) == d.screenID }),
               let top = collectWindows(on: screen).first(where: { winKey($0) == d.tileTopKeys[t] }) {
                let key = winKey(top)
                d.reactKey = key
                d.reactHome = d.frames[t]
                dragReactElement = top.element
                gestureHeldKeys.insert(key)
                frameMotions.removeValue(forKey: key)
                placeFrame(top.element, reactedFrame(d.frames[t]), key: key, animated: true, ease: .settle, duration: 0.16)
            }
        } else {
            hideDragRing()
        }
        dragState = d
    }

    func settleDragHome(_ d: DragState) {
        if let el = dragLiftElement, d.originFrame.width > 1, d.originFrame.height > 1 {
            frameMotions.removeValue(forKey: d.draggedKey)
            placeFrame(el, d.originFrame, key: d.draggedKey, animated: true, ease: .settle, duration: 0.28)
        }
        if let key = d.reactKey, let el = dragReactElement, d.reactHome.width > 1 {
            frameMotions.removeValue(forKey: key)
            placeFrame(el, d.reactHome, key: key, animated: true, ease: .settle, duration: 0.2)
        }
        gestureHeldKeys.remove(d.draggedKey)
        if let key = d.reactKey { gestureHeldKeys.remove(key) }
        dragLiftElement = nil
        dragReactElement = nil
        if frameMotions.isEmpty {
            dimsSuppressed = false
            refreshDimLayers()
            refreshHighlights()
            refreshGrips()
        }
    }

    func prepareSettle(_ d: DragState) {
        frameMotions.removeValue(forKey: d.draggedKey)
        preferredEase[d.draggedKey] = .settle
        gestureHeldKeys.insert(d.draggedKey)
        if let key = d.reactKey {
            frameMotions.removeValue(forKey: key)
            preferredEase[key] = .settle
            gestureHeldKeys.insert(key)
        }
        if let el = dragLiftElement {
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        }
    }

    // 拖动目标圈：复用高亮边框视图，画在目标磁贴的间隙里
    func showDragRing(frame: CGRect) {
        let f = frame.insetBy(dx: -tileBorderPad, dy: -tileBorderPad)
        if let p = dragRingPanel {
            if p.frame != f { p.setFrame(f, display: true) }
            if !p.isVisible { p.orderFront(nil) }
            return
        }
        let view = HighlightBorderView(frame: NSRect(origin: .zero, size: f.size))
        view.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.4)
        view.lineWidth = 1
        view.pad = tileBorderPad
        view.outset = 1.5
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        prepareOverlay(p, level: .popUpMenu, ignoresMouse: true)
        p.contentView = view
        p.orderFront(nil)
        dragRingPanel = p
    }

    func hideDragRing() {
        dragRingPanel?.orderOut(nil)
    }

    // 拖动交换：对调两扇窗口。堆在同一磁贴里的其余窗口留在原磁贴，改跟新来的那扇。
    // 调用前已把 preferredEase 设成 settle，forceTile 会从抬起/内缩的当前位置落到新格子，不过冲。
    @discardableResult
    func performDragSwap(from src: Int, to dst: Int, screenID sid: CGDirectDisplayID, draggedKey: String, targetKey: String) -> Bool {
        guard AXIsProcessTrusted() else { log("drag swap skipped: not trusted"); return false }
        let screen = NSScreen.screens.first(where: { screenID($0) == sid }) ?? NSScreen.main ?? NSScreen.screens[0]
        let windows = collectWindows(on: screen)
        guard !windows.isEmpty else { log("drag swap skipped: no windows"); return false }
        let (stacks, _) = computeTiles(windows: windows, st: settingsFor(screen), sid: sid)
        guard let topA = windows.first(where: { winKey($0) == draggedKey }) else {
            log("drag swap skipped: dragged window gone")
            return false
        }
        let topB: WinInfo
        if let w = windows.first(where: { winKey($0) == targetKey }), winKey(w) != winKey(topA) {
            topB = w
        } else if stacks.indices.contains(dst) {
            topB = stacks[dst][min(stackTops[stackTopKey(sid, dst)] ?? 0, stacks[dst].count - 1)]
        } else {
            log("drag swap skipped: target window gone")
            return false
        }
        let keyA = winKey(topA)
        let keyB = winKey(topB)
        guard keyA != keyB else { log("drag swap skipped: same window"); return false }
        mergeWindowOrder(windows)
        guard let ia = windowOrder.firstIndex(of: keyA),
              let ib = windowOrder.firstIndex(of: keyB) else { log("drag swap skipped: key not in windowOrder"); return false }
        exchangeStackRoles(keyA, keyB)
        windowOrder.swapAt(ia, ib)
        preferredEase[keyA] = .settle
        preferredEase[keyB] = .settle
        frameMotions.removeValue(forKey: keyA)
        frameMotions.removeValue(forKey: keyB)
        log("drag swap tile \(src) <-> \(dst): \(topA.appName) <-> \(topB.appName)")
        AXUIElementPerformAction(topA.element, kAXRaiseAction as CFString)
        forceTile()
        refreshPanel()
        return true
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

#if TILEPROTO_SELFTEST
private func tileProtoFail(_ msg: String) -> Never {
    fputs("SELFTEST FAIL: \(msg)\n", stderr)
    exit(1)
}

private func tileProtoCheck(_ cond: Bool, _ msg: String) {
    if !cond { tileProtoFail(msg) }
}

private func runTileProtoSelfTest() {
    let vf = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let gap: CGFloat = 8

    let grid3 = layoutFrames(count: 3, vf: vf, kind: .grid, share: 0.5, gap: gap)
    tileProtoCheck(grid3.count == 3, "grid 3 count")
    tileProtoCheck(grid3[0].height > grid3[1].height + 1 && grid3[0].height > grid3[2].height + 1, "grid 3 left is the tall pane")
    tileProtoCheck(grid3[0].width * grid3[0].height > grid3[1].width * grid3[1].height, "grid 3 left area")
    tileProtoCheck(grid3[0].width * grid3[0].height > grid3[2].width * grid3[2].height, "grid 3 left area vs second small")

    let cols = layoutFrames(count: 3, vf: vf, kind: .columns, share: 0.5, gap: gap)
    tileProtoCheck(cols.count == 3, "columns 3 count")
    tileProtoCheck(abs(cols[0].width - cols[1].width) < 0.6 && abs(cols[1].width - cols[2].width) < 0.6, "half share keeps three equal columns")
    let colSum = cols.reduce(CGFloat(0)) { $0 + $1.width } + gap * 4
    tileProtoCheck(abs(colSum - vf.width) < 0.6, "columns plus gaps fill the width")

    let wide = layoutFrames(count: 3, vf: vf, kind: .columns, share: 0.6, gap: gap)
    tileProtoCheck(wide[0].width > wide[1].width + 20, "60% enlarges the first column")

    let rows = layoutFrames(count: 3, vf: vf, kind: .rows, share: 0.5, gap: gap)
    let rowSum = rows.reduce(CGFloat(0)) { $0 + $1.height } + gap * 4
    tileProtoCheck(abs(rowSum - vf.height) < 0.6, "rows plus gaps fill the height")

    let quads = layoutFrames(count: 4, vf: vf, kind: .grid, share: 0.5, gap: gap)
    tileProtoCheck(quads.count == 4, "grid 4 count")
    tileProtoCheck(abs(quads[0].width - quads[1].width) < 0.6, "half share keeps equal quad widths")
    tileProtoCheck(abs(quads[0].height - quads[2].height) < 0.6, "half share keeps equal quad heights")

    let side = layoutFrames(count: 3, vf: vf, kind: .side, share: 0.6, gap: gap)
    tileProtoCheck(side[0].width > side[1].width && side[0].height > side[1].height, "side keeps a larger primary")

    let slot = CGRect(x: 10, y: 20, width: 100, height: 80)
    tileProtoCheck(frameContained(in: slot, proposed: slot, minSize: CGSize(width: 200, height: 40)) == nil, "min wider than the slot is not applied")
    let stuck = CGRect(x: 0, y: 0, width: 140, height: 90)
    guard let clamped = frameContained(in: slot, proposed: stuck, minSize: .zero) else {
        tileProtoFail("overshoot should clamp")
    }
    tileProtoCheck(clamped.minX >= slot.minX - 0.01 && clamped.maxX <= slot.maxX + 0.01, "clamped x stays in the slot")
    tileProtoCheck(clamped.minY >= slot.minY - 0.01 && clamped.maxY <= slot.maxY + 0.01, "clamped y stays in the slot")
    tileProtoCheck(clamped.width <= slot.width + 0.01 && clamped.height <= slot.height + 0.01, "clamped size stays in the slot")

    let needs = [
        CGSize(width: 900, height: 400),
        CGSize(width: 200, height: 200),
        CGSize(width: 200, height: 200),
    ]
    let merged = planTileFit(needs: needs, groups: [[0], [1], [2]], bound: [:]) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .columns, share: 0.5, gap: gap)
    }
    tileProtoCheck(merged.floated.isEmpty, "a 900pt window on a 1200pt screen stacks instead of floating")
    tileProtoCheck(merged.groups.count == 1, "stacking continues until the window fits")
    let host = layoutFrames(count: merged.groups.count, vf: vf, kind: .columns, share: 0.5, gap: gap)
    tileProtoCheck(host.count == 1 && host[0].width + tileFitTolerance >= 900, "the remaining cell holds 900pt")

    let boundPlan = planTileFit(needs: needs, groups: [[0], [1], [2]], bound: [1: 0]) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .columns, share: 0.5, gap: gap)
    }
    let together = boundPlan.groups.contains { $0.contains(0) && $0.contains(1) }
    tileProtoCheck(together && boundPlan.floated.isEmpty, "a manual stack moves with its root")

    let huge = planTileFit(needs: [CGSize(width: 1300, height: 400)], groups: [[0]], bound: [:]) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .columns, share: 0.5, gap: gap)
    }
    tileProtoCheck(huge.floated == [0] && huge.groups.isEmpty, "wider than the screen floats and leaves the tiling")

    let already = planTileFit(
        needs: [CGSize(width: 200, height: 200), CGSize(width: 200, height: 200), CGSize(width: 200, height: 200)],
        groups: [[0], [1], [2]],
        bound: [:]
    ) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .columns, share: 0.5, gap: gap)
    }
    tileProtoCheck(already.groups.count == 3 && already.floated.isEmpty, "windows that fit stay in their own cells")

    let sideNeeds = [
        CGSize(width: 400, height: 500),
        CGSize(width: 200, height: 200),
        CGSize(width: 200, height: 200),
    ]
    let sidePlan = planTileFit(needs: sideNeeds, groups: [[1], [0], [2]], bound: [:]) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .side, share: 0.5, gap: gap)
    }
    let joinedPrimary = sidePlan.groups.contains { $0.contains(0) && $0.contains(1) }
    let keptNeighbor = sidePlan.groups.contains { $0.contains(2) && !$0.contains(0) }
    tileProtoCheck(sidePlan.floated.isEmpty && joinedPrimary && keptNeighbor, "a tall window joins the large cell and leaves the other cell")

    fputs("SELFTEST OK\n", stdout)
    exit(0)
}
runTileProtoSelfTest()
#endif

let delegate = TileProtoApp()
#if !TILEPROTO_SELFTEST
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
#endif
