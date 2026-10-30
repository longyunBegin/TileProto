import AppKit
import ApplicationServices
import Darwin
import QuartzCore

// TileProto：菜单栏自动平铺。操作只在鼠标和菜单栏面板上。
// 原理：Accessibility API（AXUIElement）枚举窗口并改 frame。
//  1. 布局：Grid / Columns / Rows / Side，数量 1–4，默认 4。主格份额与间距可调。
//     格子数 = min(窗口数, 上限, 这一屏装得下的档, 4)。间距同时是四边 inset。装不下的数量变灰。
//     点选布局时，上限若低于这一族要露出来的格数就升上去。旧默认 3 在第一次启动时同样升一次。
//     Grid 用 4 格才不会和 Side 叠成同一张图。
//  2. 放不进当前格的窗口，只挪到同一布局里装得下、并且不会少掉一格的另一格。
//     不为了最小尺寸把整屏并成一格。整屏都装不下的那一扇才居中浮动。
//     写入 AX 的帧是该格的矩形，不会超出该格。
//  3. 窗口多于格子时按顺序分进每一格，每格一叠。橙色握把点按轮换；悬停条上层是芯片，
//     下层是 Primary / Focus / Float / Pin。界面不放键帽。
//     Option+Command 拖到某格子上时，即使刚好满格也并进去，空出的格子收掉。
//     Control+Command 仍是交换，不是进叠。
//  4. Command 拖到另一格子：被拖窗口抬起跟手，目标格子略向内收，松手后两边滑到最终帧。
//     普通拖动松手弹回，并提示按住 Command 才能交换。满格时新窗可堆叠或居中浮动。
//  5. Focus 铺满后再点悬停条上的 Focus，按进入前的帧还原。
//     No peek 默认关，打开后压暗其它格子。Clean Space 用石墨色帘子只留当前窗口。
//     格子之间只用留白分隔，不画描边。
// 入格与换布局约 0.62 秒、过冲约 0.16。交换用无过冲的落定。拖分隔线跟手。

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

/// 满格时新窗口：堆进活动格，或居中浮动直到有空位。
enum WhenFull: Int {
    case stack = 0
    case float = 1
}

// 已知最小尺寸比格子大过这个容差，才算装不下。4pt 以内当成取整误差，不并堆、不浮动。
let tileFitTolerance: CGFloat = 4
// 格子比参考最小尺寸还小，这一档数量在面板里变灰。一格不受限。
// 参考屏是 1440×798 的工作区（1440×900 去掉菜单栏和 Dock）。
// 最小格子 480×320；Columns 的宽下限是 440。比参考屏更小的屏按比例缩小这两条线，
// 更大的屏不再把线抬高，否则列越宽门槛越高，四列永远过不了。
// MacBook：Columns 3 宽 ≈469 过 440，Columns 4 宽 ≈350 不过；
// Rows 2 高 ≈387 过 320，Rows 3 高 ≈255 不过。Side 4 与 Rows 3 一样变灰。
// Grid 4 约 708×387，只有它在这块屏上能到 4。Rows 最多 3 排。高屏（高>宽）强制 Rows。
// 新装时的数量上限。4 是面板能选的最大档。
// 每一族再用 effectiveTileLimit 收到这块屏装得下的格数：
// MacBook 上 Grid 是 4、Columns 是 3、Rows 是 2、Side 是 3，四族外形互不相同。
// 上限停在 3 时，Grid 的三格和 Side 的三格是同一张图。
let defaultTileLimit = 4
let tileSpringDuration: CFTimeInterval = 0.62
let hoverShowDelay: CFTimeInterval = 0.15
let hoverArmDelay: CFTimeInterval = 0.40
let hoverHideDelay: CFTimeInterval = 0.35
let cleanSpaceFade: CFTimeInterval = 0.38

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

/// 把装不进当前格子的窗口挪到同一布局里装得下的另一格。
/// 格子数是布局族的形状，这里不减少它：源格会被搬空、或者目的格并不更大时，都不搬。
/// 只有整屏那一格也装不下，才把那一扇放进 floated。其余窗口留在自己的格子里叠着。
/// bound 把手动堆叠绑在一起：member → root，能搬时整组跟着走。
func planTileFit(
    needs: [CGSize],
    groups: [[Int]],
    bound: [Int: Int],
    frames: ([[Int]]) -> [CGRect],
    maxSteps: Int = 8
) -> (groups: [[Int]], floated: [Int]) {
    var groups = groups.filter { !$0.isEmpty }
    var floated: [Int] = []
    // 这一轮已经确认「留在原格」的窗口。跳过后继续看别的窗口，避免一扇很宽的窗挡住后面还能搬家的窗。
    var skipped: Set<Int> = []
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
    func signature(_ groups: [[Int]]) -> String {
        groups.map { $0.sorted().map(String.init).joined(separator: ",") }.joined(separator: "/")
    }
    func fitsWorkArea(_ id: Int) -> Bool {
        let solo = frames([[id]])
        return solo.count == 1 && slotShortfall(needs[id], solo[0]) == 0
    }
    // 见过的分法。搬家必须落到新的分法上，防止来回搬。
    var seen: Set<String> = [signature(groups)]
    let budget = max(maxSteps, max(needs.count, 1) * 2)
    var steps = 0
    while steps < budget {
        steps += 1
        if groups.isEmpty { break }
        let current = frames(groups)
        guard current.count == groups.count else { break }
        var worstAmt: CGFloat = 0
        var worstGroup = -1
        var worstID = -1
        for (gi, group) in groups.enumerated() {
            for id in group where needs.indices.contains(id) && !skipped.contains(id) && !floated.contains(id) {
                let short = slotShortfall(needs[id], current[gi])
                if short > worstAmt {
                    worstAmt = short
                    worstGroup = gi
                    worstID = id
                }
            }
        }
        if worstID < 0 { break }
        // 只剩一整屏时，装不下就浮动。这里不再有别的格子可以收留它。
        if groups.count <= 1 {
            floated.append(worstID)
            groups[worstGroup].removeAll { $0 == worstID }
            if groups[worstGroup].isEmpty { groups.remove(at: worstGroup) }
            if !seen.insert(signature(groups)).inserted { break }
            continue
        }
        let moving = component(worstID, inside: groups)
        var best: [[Int]]?
        var bestScore = worstAmt
        for host in groups.indices where host != worstGroup {
            // relocated 会丢掉搬空的格子。格子数变了就拒绝：那是把布局并掉。
            guard let trial = relocated(moving, host: host, groups: groups) else { continue }
            guard trial.count == groups.count else { continue }
            let trialFrames = frames(trial)
            guard trialFrames.count == trial.count else { continue }
            let score = maxSlotShortfall(needs: needs, groups: trial, frames: trialFrames)
            if score + 0.5 < bestScore {
                bestScore = score
                best = trial
            }
        }
        if let best {
            guard seen.insert(signature(best)).inserted else { break }
            groups = best
            skipped.removeAll()
            continue
        }
        if !fitsWorkArea(worstID) {
            floated.append(worstID)
            for i in groups.indices {
                groups[i].removeAll { $0 == worstID }
            }
            groups.removeAll { $0.isEmpty }
            if !seen.insert(signature(groups)).inserted { break }
            continue
        }
        // 整屏装得下，但没有任何一格能在保持格数的前提下装下它。留在原格。
        skipped.insert(worstID)
    }
    return (groups, floated)
}

/// 满格时的分格：前 tileCount 扇窗各占一格，多出来的全部叠进活动格。
/// 与 demo 一致：格子数和几何都不变，只是活动格变厚，新窗压在这一叠的最上面。
func overflowStackTargets(windowCount: Int, tileCount: Int, active: Int) -> [Int] {
    let n = tileCount > 0 ? tileCount : 1
    let act = min(max(active, 0), n - 1)
    guard windowCount > 0 else { return [] }
    return (0..<windowCount).map { $0 < n ? $0 : act }
}

/// 这一族要露出来才叫这个布局的格数。Grid 的完整外形是 4 格；3 格时 Grid 是上一条下两格，与 Side 的「一块大、两块小」不再是同一张图。
/// Columns / Rows / Side 从 3 格起才不是「左右对半分」或「一整屏」。
func familyShapeCount(_ kind: LayoutKind) -> Int {
    switch kind {
    case .grid: return 4
    case .columns, .rows, .side: return 3
    }
}

/// 点选这一族时，至少要达到的格数：想要的外形，再收到这块工作区装得下的档。
func visiblePaneTarget(kind: LayoutKind, vf: CGRect, gap: CGFloat) -> Int {
    effectiveTileLimit(familyShapeCount(kind), kind: kind, vf: vf, gap: gap)
}

/// 点选布局族之后的上限。只升不降：用户已经选过更大的上限时留着，换一块屏还能用。
/// 屏幕装不下的档由 effectiveTileLimit 在平铺时收回，不写进这个返回值。
func tileLimitForFamilyChange(saved: Int, kind: LayoutKind, vf: CGRect, gap: CGFloat) -> Int {
    let savedClamped = min(max(saved, 1), 4)
    return max(savedClamped, visiblePaneTarget(kind: kind, vf: vf, gap: gap))
}

// 份额为 Half（0.5）时条带按份数等分，三列不会变成「第一列占一半」。
// 60% 与 2/3 才把第一格拉大，其余格子分剩下的宽度或高度。Side 的左格始终用原始份额。
func spanShare(count: Int, share: CGFloat) -> CGFloat {
    let n = max(count, 1)
    if abs(share - 0.5) < 0.021 { return 1 / CGFloat(n) }
    return min(max(share, 0.4), 0.75)
}

/// 退化均分：剩余空间连 gap 都放不下时仍把屏幕切成互不相交的条带
/// （均分、贴边），绝不返回“全部格子等于整个可见区”。格子小于最小尺寸
/// 的窗按尺寸适配规则进 Dock，而不是靠格子重叠来放。
func degenerateStripFrames(vf: CGRect, count n: Int, horizontal: Bool) -> [CGRect] {
    let c = max(n, 1)
    if horizontal {
        let w = max(1, vf.width / CGFloat(c))
        return (0..<c).map { CGRect(x: vf.minX + CGFloat($0) * w, y: vf.minY, width: w, height: max(1, vf.height)) }
    }
    let h = max(1, vf.height / CGFloat(c))
    return (0..<c).map { CGRect(x: vf.minX, y: vf.minY + CGFloat($0) * h, width: max(1, vf.width), height: h) }
}

/// 退化 2×2 网格（左上、右上、右下、左下），均分贴边、互不相交。
func degenerateGrid2x2Frames(vf: CGRect) -> [CGRect] {
    let colW = max(1, vf.width / 2)
    let rowH = max(1, vf.height / 2)
    return [
        CGRect(x: vf.minX, y: vf.minY + rowH, width: colW, height: rowH),
        CGRect(x: vf.minX + colW, y: vf.minY + rowH, width: colW, height: rowH),
        CGRect(x: vf.minX + colW, y: vf.minY, width: colW, height: rowH),
        CGRect(x: vf.minX, y: vf.minY, width: colW, height: rowH),
    ]
}

func columnFrames(count n: Int, vf: CGRect, gap g: CGFloat, share: CGFloat) -> [CGRect] {
    guard n > 1 else { return [vf] }
    let inner = vf.width - g * CGFloat(n + 1)
    guard inner > CGFloat(n) else { return degenerateStripFrames(vf: vf, count: n, horizontal: true) }
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
    guard inner > CGFloat(n) else { return degenerateStripFrames(vf: vf, count: n, horizontal: false) }
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
    guard innerW > 2 else {
        // 退化：左格 + 右列均分贴边，左右贴边、上下贴边，互不相交。
        let leftW = max(1, vf.width / 2)
        let left = CGRect(x: vf.minX, y: vf.minY, width: leftW, height: max(1, vf.height))
        let rightX = vf.minX + leftW
        let rightW = max(1, vf.width - leftW)
        let rowH = max(1, vf.height / CGFloat(rows))
        var out = [left]
        for r in 0..<rows {
            out.append(CGRect(x: rightX, y: vf.minY + CGFloat(r) * rowH, width: rightW, height: rowH))
        }
        return out
    }
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

/// Grid 三格：上排一整条，下排并排两格。铺满整屏，形状与四格的 2×2 不重合，
/// 也不与 Side 的「一块大、两块小」同形——切格子必须看得出变化。
/// 上下两行的高度按面板份额分配（Half 对半，60%/2/3 时上排更大）。
func grid3Frames(vf: CGRect, gap g: CGFloat, share: CGFloat) -> [CGRect] {
    let innerW = vf.width - 3 * g
    let innerH = vf.height - 3 * g
    guard innerW > 2, innerH > 2 else {
        // 退化：2×2 缺右上，均分贴边、互不相交。
        let cells = degenerateGrid2x2Frames(vf: vf)
        return [cells[0], cells[3], cells[2]]
    }
    let fraction = spanShare(count: 2, share: share)
    let topH = max(1, (innerH * fraction).rounded())
    let botH = max(1, innerH - topH)
    let halfW = innerW / 2
    let leftX = vf.minX + g
    let topY = vf.maxY - g - topH
    let botY = vf.minY + g
    return [
        CGRect(x: leftX, y: topY, width: max(1, vf.width - 2 * g), height: topH),
        CGRect(x: leftX, y: botY, width: max(1, halfW), height: botH),
        CGRect(x: leftX + halfW + g, y: botY, width: max(1, innerW - halfW), height: botH),
    ]
}

/// Grid 四格：先做成左大右二，再把左侧竖直对半。主格份额只拉宽左列，左右列内部高度各一半。
func gridFold4Frames(vf: CGRect, gap g: CGFloat, share: CGFloat) -> [CGRect] {
    let tri = sideFrames(count: 3, vf: vf, gap: g, share: share)
    guard tri.count == 3 else { return degenerateGrid2x2Frames(vf: vf) }
    let left = tri[0]
    let innerH = left.height - g
    guard innerH > 2 else { return degenerateGrid2x2Frames(vf: vf) }
    let topH = (innerH * 0.5).rounded()
    let botH = max(1, innerH - topH)
    let bot = CGRect(x: left.minX, y: left.minY, width: left.width, height: botH)
    let top = CGRect(x: left.minX, y: left.minY + botH + g, width: left.width, height: max(1, topH))
    // 顺序：左上、右上、右下、左下
    return [top, tri[1], tri[2], bot]
}

func layoutFrames(count: Int, vf: CGRect, kind: LayoutKind, share: CGFloat, gap: CGFloat) -> [CGRect] {
    let n = min(max(count, 0), 4)
    guard n > 0 else { return [] }
    let g = min(max(0, gap), min(vf.width, vf.height) * 0.2)
    if vf.width < 2 || vf.height < 2 {
        // 极小可见区也不得让多格共用同一帧：均分贴边（单格仍返回自身）。
        if n <= 1 { return [vf] }
        return degenerateStripFrames(vf: vf, count: n, horizontal: kind != .rows)
    }
    // 一格也走间距：边距与窗缝同一套。
    if n == 1 {
        if g < 0.5 { return [vf] }
        let inset = vf.insetBy(dx: g, dy: g)
        return inset.width > 1 && inset.height > 1 ? [inset] : [vf]
    }
    switch kind {
    case .columns:
        return columnFrames(count: n, vf: vf, gap: g, share: share)
    case .rows:
        return rowFrames(count: n, vf: vf, gap: g, share: share)
    case .side:
        return sideFrames(count: n, vf: vf, gap: g, share: share)
    case .grid:
        // 三格是上一条 + 下两格，四格是左列对半 + 右列两格（2×2）。
        if n == 3 { return grid3Frames(vf: vf, gap: g, share: share) }
        if n == 4 { return gridFold4Frames(vf: vf, gap: g, share: share) }
        return columnFrames(count: n, vf: vf, gap: g, share: share)
    }
}

/// 比参考工作区更小才缩小门槛。返回值 ∈ (0, 1]。
func layoutReferenceScale(_ vf: CGRect) -> CGFloat {
    guard vf.width > 1, vf.height > 1 else { return 1 }
    return min(1, min(vf.width / 1440, vf.height / 798))
}

func layoutMinWidth(kind: LayoutKind, vf: CGRect) -> CGFloat {
    let scale = layoutReferenceScale(vf)
    if kind == .columns { return 440 * scale }
    return 480 * scale
}

func layoutMinHeight(vf: CGRect) -> CGFloat {
    320 * layoutReferenceScale(vf)
}

/// 高屏（高大于宽）只排成 Rows。横屏保持用户选的族。
func resolvedLayoutKind(_ kind: LayoutKind, vf: CGRect) -> LayoutKind {
    if vf.height > vf.width + 0.5 { return .rows }
    return kind
}

/// 这一档的格子是否都达到最小宽高。count 为 1 时始终可以。
/// 判断用 Half 份额：主窗份额只在同一档里重分，不把数量变灰。
func layoutCountFits(_ count: Int, kind: LayoutKind, vf: CGRect, gap: CGFloat) -> Bool {
    if count <= 1 { return count == 1 }
    if count > 4 { return false }
    let frames = layoutFrames(count: count, vf: vf, kind: kind, share: 0.5, gap: gap)
    guard frames.count == count else { return false }
    let minW = layoutMinWidth(kind: kind, vf: vf)
    let minH = layoutMinHeight(vf: vf)
    for frame in frames {
        if frame.width + tileFitTolerance < minW { return false }
        if frame.height + tileFitTolerance < minH { return false }
    }
    return true
}

/// 把各格的屏幕帧按比例放进预览画布。宽高用同一比例，画布有余量时居中。
/// 空帧或退化画布返回空数组。返回的矩形与 frames 一一对应。
func minimapLayout(work: CGRect, frames: [CGRect], canvas: CGRect) -> [CGRect] {
    guard work.width > 1, work.height > 1, canvas.width > 1, canvas.height > 1 else { return [] }
    let scale = min(canvas.width / work.width, canvas.height / work.height)
    guard scale > 0, scale.isFinite else { return [] }
    let usedW = work.width * scale
    let usedH = work.height * scale
    let ox = canvas.minX + (canvas.width - usedW) / 2
    let oy = canvas.minY + (canvas.height - usedH) / 2
    return frames.map { frame in
        CGRect(
            x: ox + (frame.minX - work.minX) * scale,
            y: oy + (frame.minY - work.minY) * scale,
            width: max(2, frame.width * scale),
            height: max(2, frame.height * scale)
        )
    }
}

/// 排进去之前就要浮动的唯一情况：这一扇的最小尺寸连整屏工作区都装不下。
/// 比一格大但仍能放进整屏的，先走缝让位（applyGiveWay）与 planTileFit；
/// 仍装不下的由 tile() 的不变量验算移出平铺（见 enforcePaneFit 注释），不在这里提前放弃。
func shouldFloatBeforePlace(minSize: CGSize, slot: CGRect, workCell: CGRect) -> Bool {
    _ = slot
    return frameContained(in: workCell, proposed: workCell, minSize: minSize) == nil
}

/// 点面板以外的地方应当关面板。命中面板自己或菜单栏图标都不算「外面」：
/// 前者交给控件，后者交给 togglePanel，避免一次点击被算成两下开关。
func panelClickIsOutside(_ point: CGPoint, panelFrame: CGRect?, statusFrame: CGRect?) -> Bool {
    if let p = panelFrame, p.contains(point) { return false }
    if let s = statusFrame, s.contains(point) { return false }
    return true
}

/// 栈顶复核：栈顶的实际帧不在格子里时，从这一叠里挑一扇真的落进格子的成员当新栈顶。
/// 挑不到就返回 nil，保持原栈顶（宁可叠着，也不把整叠赶出格子）。
func stackTopToPromote(top: Int, frames: [CGRect], pane: CGRect) -> Int? {
    guard frames.indices.contains(top), !frameIsInsidePane(frames[top], pane: pane) else { return nil }
    return frames.indices.first { $0 != top && frameIsInsidePane(frames[$0], pane: pane) }
}

/// 格子是硬边界。任何窗口写出的目标帧都是这块矩形，不按最小尺寸放大。
func hardPaneFrame(_ pane: CGRect) -> CGRect {
    guard pane.width >= 1, pane.height >= 1 else { return pane }
    return pane
}

/// 实际帧是否落在格子内。容差只吃取整，不吃探出缝的几十点。
/// 1.5pt 是参与不变量判定的统一口径：AX 写整数像素，Retina 上偶尔差半点。
func frameIsInsidePane(_ frame: CGRect, pane: CGRect, tolerance: CGFloat = 1.5) -> Bool {
    frame.minX >= pane.minX - tolerance &&
        frame.minY >= pane.minY - tolerance &&
        frame.maxX <= pane.maxX + tolerance &&
        frame.maxY <= pane.maxY + tolerance
}

/// 精确一致：实际帧与格子帧四边都在 1.5pt 内才算相等。只吃取整/半点误差，
/// 不吃探出与欠尺寸（230x408 的小窗留在 744x435 格子里同样算违规）。
func frameMatchesSlot(_ frame: CGRect, pane: CGRect, tolerance: CGFloat = 1.5) -> Bool {
    abs(frame.minX - pane.minX) <= tolerance &&
        abs(frame.minY - pane.minY) <= tolerance &&
        abs(frame.maxX - pane.maxX) <= tolerance &&
        abs(frame.maxY - pane.maxY) <= tolerance
}

/// 两个不同格子的窗口帧是否相交。同一格的堆叠不走这里。
func differentPanesIntersect(_ a: CGRect, _ b: CGRect) -> Bool {
    let inter = a.intersection(b)
    if inter.isNull { return false }
    return inter.width > 1 && inter.height > 1
}

/// 实际帧探出自己的格子，并且探到了另一格的矩形里。同一格里的堆叠不算。
func frameCrossesPane(_ actual: CGRect, cell: CGRect, neighbor: CGRect, tolerance: CGFloat = tileFitTolerance) -> Bool {
    let over = max(cell.minX - actual.minX, cell.minY - actual.minY,
                   actual.maxX - cell.maxX, actual.maxY - cell.maxY)
    guard over > tolerance else { return false }
    let inter = actual.intersection(neighbor)
    if inter.isNull { return false }
    return inter.width > 1 && inter.height > 1
}

/// 拖缝时，实际帧探出格子的窗口要被按回格子，不是浮走，也不收回份额。
func windowIsSeamOffender(cell: CGRect, actual: CGRect, tolerance: CGFloat = tileFitTolerance) -> Bool {
    !frameIsInsidePane(actual, pane: cell, tolerance: tolerance)
}

/// 拖缝结算：任一侧有成员探出新格子就整步撤销，不留下半格超出的中间态。
/// 拖动中的实时预览不受这条约束，松手时以它为准。
func seamMustRevert(_ pairs: [(offenderA: Bool, offenderB: Bool)]) -> Bool {
    pairs.contains { $0.offenderA || $0.offenderB }
}

/// 放宽格数时，把要拆出来的那一扇排到现有格主之后，下一格就是它。
/// owners 是当前每一格的根，promoted 是从最满的叠里拆出的那一扇。
func windowOrderPromoting(_ order: [String], owners: [String], promoted: String) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for key in owners where key != promoted && seen.insert(key).inserted {
        out.append(key)
    }
    if seen.insert(promoted).inserted { out.append(promoted) }
    for key in order where seen.insert(key).inserted { out.append(key) }
    return out
}

/// 把用户选的上限收到这块工作区实际装得下的最大档。
/// 高屏先改成 Rows。Rows 最多 3 排。装得下时，在这些上限之内原样返回。
func effectiveTileLimit(_ limit: Int, kind: LayoutKind, vf: CGRect, gap: CGFloat) -> Int {
    let kind = resolvedLayoutKind(kind, vf: vf)
    var n = min(max(limit, 1), 4)
    if kind == .rows { n = min(n, 3) }
    while n > 1 && !layoutCountFits(n, kind: kind, vf: vf, gap: gap) {
        n -= 1
    }
    return n
}

enum CleanSpaceColor: Int {
    case graphite = 0
    case stone = 1
    case mist = 2
}

/// 排版用的间距：格子之间只靠留白分隔，不画描边。用户设的间距夹在 0–24。
func effectiveLayoutGap(setGap: CGFloat) -> CGFloat {
    min(24, max(0, setGap))
}

/// 默认份额装不下、又没有自定义缝时，用 12 轮二分找仍能装下的最大主窗份额。
/// 连 0.4 都装不下就保持原份额，交给并堆，不把主格再压小。
func convergedMainShare(start: CGFloat, count: Int, vf: CGRect, kind: LayoutKind, gap: CGFloat, claims: [CGSize]) -> CGFloat {
    let base = min(max(start, 0.4), 0.75)
    func fits(_ share: CGFloat) -> Bool {
        let frames = layoutFrames(count: count, vf: vf, kind: kind, share: share, gap: gap)
        guard frames.count == count, frames.count == claims.count else { return false }
        for i in frames.indices {
            if slotShortfall(claims[i], frames[i]) > 0 { return false }
        }
        return true
    }
    if fits(base) { return base }
    var lo: CGFloat = 0.4
    var hi = base
    if !fits(lo) { return base }
    var best = lo
    var round = 0
    while round < 12 {
        let mid = (lo + hi) / 2
        if fits(mid) {
            best = mid
            lo = mid
        } else {
            hi = mid
        }
        round += 1
    }
    return best
}

func layoutFamilyName(_ kind: LayoutKind) -> String {
    switch kind {
    case .grid: return "Grid"
    case .columns: return "Columns"
    case .rows: return "Rows"
    case .side: return "Side"
    }
}

/// 面板右侧布局名。数量不同，句子不同；不要把每一种都写成「一大两小」。
func layoutCaption(kind: LayoutKind, count: Int) -> String {
    let n = min(max(count, 1), 4)
    let phrase: String
    switch kind {
    case .grid:
        switch n {
        case 1: phrase = "Full screen"
        case 2: phrase = "Side by side"
        case 3: phrase = "One on top, two below"
        default: phrase = "Grid of four"
        }
    case .columns:
        switch n {
        case 1: phrase = "Full screen"
        case 2: phrase = "Side by side"
        case 3: phrase = "Three columns"
        default: phrase = "Four columns"
        }
    case .rows:
        switch n {
        case 1: phrase = "Full screen"
        case 2: phrase = "Two rows"
        case 3: phrase = "Three rows"
        default: phrase = "Four rows"
        }
    case .side:
        switch n {
        case 1: phrase = "Full screen"
        case 2: phrase = "Side by side"
        case 3: phrase = "One big, two beside"
        default: phrase = "One big, three beside"
        }
    }
    return "\(layoutFamilyName(kind)) · \(phrase)"
}

/// 当前布局族到不了 4 时的脚注。Grid 自己到不了 4 时不再写「Pick Grid」。
func capacityNote(kind: LayoutKind, fitted: Int) -> String? {
    guard fitted >= 1, fitted < 4 else { return nil }
    switch kind {
    case .columns:
        let noun = fitted == 1 ? "column" : "columns"
        return "This screen fits \(fitted) \(noun). Pick Grid for four."
    case .rows:
        let noun = fitted == 1 ? "row" : "rows"
        return "This screen fits \(fitted) \(noun). Pick Grid for four."
    case .side:
        let noun = fitted == 1 ? "window" : "windows"
        return "This screen fits \(fitted) \(noun) in Side. Pick Grid for four."
    case .grid:
        let noun = fitted == 1 ? "window" : "windows"
        return "This screen fits \(fitted) \(noun)."
    }
}

/// 拖动和弦。进叠只认 Option+Command。Control 不是 Option。
enum DragChord: Equatable {
    case plain
    case swap
    case stack
}

func dragChord(command: Bool, option: Bool, control: Bool) -> DragChord {
    // Option+Command 才是进叠，多按着 Control 也仍然是进叠。
    if command && option { return .stack }
    // Control+Command、单独 Command 都是交换。Control 自己什么都不重排。
    if command { return .swap }
    if control || option { return .plain }
    return .plain
}

/// 间距 0–24，2pt 一档。奇数落到下一档更小的偶数。
func snappedGap(_ raw: Int) -> Int {
    let clamped = min(24, max(0, raw))
    return (clamped / 2) * 2
}

/// easeOutBack。c1 = 2.255 时峰值约 1.16，t = 1 时精确为 1。
func tileSpringUnit(_ t: CGFloat) -> CGFloat {
    if t <= 0 { return 0 }
    if t >= 1 { return 1 }
    let c1: CGFloat = 2.255
    let c3 = c1 + 1
    return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
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

/// 滚动容器里的文档视图：坐标从上往下，内容不够高时也贴着顶。
final class FlippedBox: NSView {
    override var isFlipped: Bool { true }
}

/// 菜单栏里的这一屏缩略图。格子按真实帧的比例画，不按个数等分。
final class MinimapView: NSView {
    struct Pane {
        var rect: CGRect
        var title: String
        var count: Int
        var active: Bool
        var focused: Bool
        var dimmed: Bool
    }
    var panes: [Pane] = [] {
        didSet { needsDisplay = true }
    }
    var onSelect: ((Int) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor
        layer?.cornerRadius = 8
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 288, height: 168) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let index = panes.firstIndex(where: { $0.rect.contains(p) }) else { return }
        onSelect?(index)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).fill()
        for pane in panes {
            let rect = pane.rect.integral
            guard rect.width > 1, rect.height > 1 else { continue }
            let fill: NSColor
            if pane.dimmed {
                fill = NSColor.black.withAlphaComponent(0.28)
            } else if pane.active || pane.focused {
                fill = NSColor.controlAccentColor.withAlphaComponent(0.22)
            } else {
                fill = NSColor.labelColor.withAlphaComponent(0.10)
            }
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            if pane.active || pane.focused {
                NSColor.controlAccentColor.setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                outline.lineWidth = 1.5
                outline.stroke()
            }
            if pane.focused, rect.height > 16 {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: NSColor.controlAccentColor,
                ]
                let label = "Focus" as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            }
            if pane.count > 1 {
                let badge = "\(pane.count)" as NSString
                let font = NSFont.systemFont(ofSize: 9, weight: .bold)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white,
                ]
                let size = badge.size(withAttributes: attrs)
                let bw = max(14, size.width + 6)
                let bh: CGFloat = 14
                let badgeRect = NSRect(x: rect.maxX - bw - 2, y: rect.maxY - bh - 2, width: bw, height: bh)
                NSColor.systemOrange.setFill()
                NSBezierPath(roundedRect: badgeRect, xRadius: 7, yRadius: 7).fill()
                badge.draw(at: NSPoint(x: badgeRect.midX - size.width / 2, y: badgeRect.midY - size.height / 2), withAttributes: attrs)
            }
        }
    }
}

/// 悬停条上的堆叠芯片。点按激活；拖过 4pt 再松手，落在别的格子上就并进那一叠。
final class ChipControl: NSView {
    var title: String = ""
    var icon: NSImage?
    var emphasized = false
    var chipIndex = 0
    var windowKey: String = ""
    var onTrack: ((ChipControl, NSPoint) -> Void)?
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 11, weight: emphasized ? .semibold : .regular)
        let text = (title as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: 22 + text + 10, height: 28)
    }
    override func draw(_ dirtyRect: NSRect) {
        if emphasized {
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        var x: CGFloat = 6
        if let icon {
            icon.draw(in: NSRect(x: x, y: (bounds.height - 14) / 2, width: 14, height: 14))
            x += 16
        }
        let font = NSFont.systemFont(ofSize: 11, weight: emphasized ? .semibold : .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) {
        onTrack?(self, NSEvent.mouseLocation)
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
    // 面板刚弹出时窗口还不是 key：不接 first mouse 的话，第一次点布局/数量会被吞掉，
    // 看起来像「面板上点布局没反应」。Settings 里能点，正是因为那边窗口已经是 key。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if !isDisabled { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 2, dy: 2)
        let bg = isSelected ? NSColor.white : NSColor.controlBackgroundColor
        bg.setFill()
        NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10).fill()
        if isSelected {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(roundedRect: card.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            outline.lineWidth = 2
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

final class TileProtoApp: NSObject, NSApplicationDelegate, NSWindowDelegate {

    var statusItem: NSStatusItem!
    var autoTile = true
    var autoOffPlacedKeys: Set<String> = []  // 关自动平铺后已见过的窗口：只给此后新开的窗口居中一次
    var tileLimit = defaultTileLimit
    var noPeek = false
    var dimStrength: CGFloat = 0.50
    var cleanTone: CleanSpaceColor = .graphite
    var hoverBarEnabled = true
    var statPlaced = 0
    var statMoves = 0
    var hoverFocus = false
    var cleanSpaceOn = false
    var cleanSpaceSavedFrames: [String: CGRect] = [:]
    var cleanSpaceScreen: CGDirectDisplayID?
    var cleanSpaceHole: CGRect = .zero
    var cleanSpaceShownHole: CGRect = .zero
    var cleanDimPanels: [NSPanel] = []
    var tabPanel: NSPanel?
    var familyButtons: [DiagramButton] = []
    var shareButtons: [NSButton] = []
    var gapSlider: NSSlider!
    var gapValueLabel: NSTextField!
    var whenFullButtons: [NSButton] = []
    var fitWarningLabel: NSTextField!
    var layoutCaptionLabel: NSTextField!
    var tidyButton: NSButton!
    var resetSizesRow: NSStackView!
    var didShowStackToast = false
    var noPeekSwitch: NSSwitch!
    var hoverFocusSwitch: NSSwitch!
    var cleanSpaceSwitch: NSSwitch!
    var panelButtonSymbols: [ObjectIdentifier: String] = [:]
    let tileBorderPad: CGFloat = 4
    var stackTops: [String: Int] = [:]  // C 批：key 为“屏ID:磁贴下标”，多屏不串位
    // 用户亲手选的栈顶（key 同上，值是窗口键）。弹簧结束后复核时不要把这些又换掉。
    var pinnedTops: [String: String] = [:]
    var lastPanesByScreen: [CGDirectDisplayID: [CGRect]] = [:]
    var lastSignature = ""
    var pendingSignature = ""
    var pendingTicks = 0
    var excludedBundles: Set<String> = []
    var lastTrustState: Bool? = nil
    var panelPopover: NSPopover!
    var panelDismissMonitors: [Any] = []
    var panelContainer: NSView!
    var panelScroll: NSScrollView?
    var panelDocHeight: NSLayoutConstraint?
    var panelHeightConstraint: NSLayoutConstraint?
    var panelStack: NSStackView!
    var autoSwitch: NSSwitch!
    var statusDot: DotView!
    var statusLabel: NSTextField!
    var minimapView: MinimapView!
    var tilesPlaceholder: NSTextField!
    var countButtons: [DiagramButton] = []

    var tileAppLabel: NSTextField!
    var tileAppSwitch: NSSwitch!
    var tileAppIconView: NSImageView!
    var requestAXButton: NSButton!
    // 面板/设置窗成为 key 后前台是 TileProto 自己，frontRegularApp 会返回 nil，
    // 「Tile <App>」行随之退化成灰掉的「Tile front app」。记住最后一次真正的常规前台 App 兜底。
    var lastRegularFrontApp: NSRunningApplication?
    // 对 AX 交了空窗口列表、却在屏上有窗口的应用：每种应用每次启动只记一次日志。
    var loggedAXEmptyApps: Set<pid_t> = []
    var lastPanelTilesKey = ""
    var lastPanelHeight: CGFloat = 0
    // v6 状态：悬停条 / 分隔线 / Float / Primary / 自定义分割
    var floatedKeys: Set<String> = []          // 单窗口 Float：pid|标题
    // 折叠到 Dock（瞬时，不持久化，重启解除）：
    // foldedKeys = 已折叠窗口键；折叠窗保留在原格堆叠成员身份（翻堆顺序不动），
    // 只是不摆位、真窗口最小化隐藏；格顶取第一个未折叠成员。
    // 折叠态按 AX 键追踪：最小化窗不在 CG 在屏列表里，但仍在 AX 窗口列表里，
    // 采集放行 + 裁剪宽口径（.optionAll）都按它存在处理，不依赖 CG 在屏出现。
    // 窄条已撤（2026-10-29 用户批准）：折叠窗不再有任何面板呈现，恢复走 Dock +
    // 焦点取消折叠；手风琴展开（展开一个、其余全折）已随条一并撤掉。
    var foldedKeys: Set<String> = []
    var foldedScreenByKey: [String: CGDirectDisplayID] = [:]  // 折叠时记录的原属屏（最小化后 AX 帧不可靠，tileAll 据此归位）
    var foldedMinimizedKeys: Set<String> = []    // 已验证最小化的折叠窗（避免每轮重复 AX 写）
    var foldedElements: [String: AXUIElement] = [:]  // 折叠窗的 AX 元素（解除时据此取消最小化）
    var pinnedWindowKeys: Set<String> = []  // 固定窗键（瞬时，不持久化；与拖动栈 pin 的 pinnedTops 不同）。
    // 固定语义：豁免全部折叠门（与焦点窗同级别），摆位不动（不像 Float 居中重排），
    // 超格就盖邻格直至取消固定；取消固定后若仍超格且非焦点，下一轮正常门折叠。
    var frontFocusKeyForPass: String? = nil  // 本轮前台焦点窗键（焦点规则用；与 Focus 功能的 focusKey 不同）
    var geometryChangedAt: Date = Date()  // 任一屏几何变化时刻（启动时即 Date()，首 2 秒不折叠）
    var lastGeometrySkipLogAt: Date = .distantPast  // 几何不稳定跳过日志的节流时刻
    var screenChangeRetileTimer: Timer? = nil  // 屏幕参数变化去抖计时器
    var tilingInProgress: Bool = false  // tileAll 防重入
    var tileAllPending: Bool = false  // 防重入期间又有重排请求时补跑一次
    var lastFrontmostPid: pid_t? = nil        // tick 激活检测：折叠窗 App 被前台激活时普通恢复
    // 帧依据折叠去抖：同一窗同一格连续 2 轮 tick 安置超格才折（安定态，非动画瞬态）。
    // 键为窗口键，值为（格子标识，连续次数）；格子变了重新计；窗不在任何格里时清掉（防 pid 复用串号）。
    var frameOversizeWatch: [String: (slot: String, count: Int)] = [:]
    // 约束自适应平铺：没有自动独占组、没有自动按组 Hide、没有自动逐窗最小化。
    // 所有打开的窗都要被排：当不了顶的窗进堆叠当成员（oversizeStacked 机制复用），
    // 可见的顶必须精确等于格子，格子按顶的最小尺寸算。
    // 固定尺寸窗判定（落点验算确认后记入）：格子必须按其精确尺寸给，否则不当顶。
    var fixedSizeKeys: Set<String> = []
    // tick 卡住重算去抖：同一扇窗卡住只触发一次重算，贴合后清掉（否则 1Hz 重排循环）。
    var solveForcedStuckKeys: Set<String> = []
    // 求解降格提示去抖：只在降格数变化时 toast，不在每轮重算时刷屏。
    var lastSolvedCountByScreen: [CGDirectDisplayID: Int] = [:]
    // 落点验算的“稳定帧”观察：同一扇窗两次观测实际帧不变 → 拒绝改尺寸（固定尺寸窗的判定）。
    var exactWatch: [String: CGRect] = [:]
    var paneRefusals: [String: Int] = [:]
    var lastRefusedFrame: [String: (target: CGRect, frame: CGRect)] = [:]  // 上次被拒的目标与实际帧（顽固窗停写用）
    var refusalRetileScheduled = false
    // 最小尺寸学习：key = 应用名（learnName 已在两条落点路径上传入），
    // 值 = 观测到的落点下限（每维独立）；存 UserDefaults 持久化本机。
    var learnedMinSizes: [String: CGSize] = [:]
    var axMinCache: [String: CGSize] = [:]  // AX 最小值缓存（每轮 tick / 每次 tileAll 清空）
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
    var dividerRevertLogged = false // 同一拖动会话里“divider drag reverted”只记一次
    // 缝拖动事件合并：mouseDragged 只记最新位置并调度一次主队列异步处理，
    // 多个事件到达时只覆盖 pending，不排队跑重活；异步块用最新位置跑一步。
    // 否则每事件同步跑完 100+ 次 AX（130–400ms），远跟不上 8–16ms 的事件间隔，
    // 主线程被拖住，缝只能滞后、跳跃地跟鼠标。
    var dividerDragPending: CGFloat? = nil
    var dividerLastApplied: [String: CGFloat] = [:]  // 缝上次落点（去重写用）
    var dividerDragScheduled = false
    var dividerDragCurrent: (screenID: CGDirectDisplayID, id: String, vertical: Bool)? = nil
    // 缝拖动 phase 0 快照：拖前两侧格子帧 + 各成员实际帧 + 缝中心 + splitOverrides 原值。
    // 拖动中成员不动，松手结算与整步撤销都以它为准；成员集合变了则取消本次拖动。
    struct DividerDragSnapshot {
        let sid: CGDirectDisplayID
        let dividerID: String
        let vertical: Bool
        let seamCenter: CGFloat
        let tiles: [(keys: Set<String>, frame: CGRect)]  // 两侧两格：成员 key 集 + 拖前格子帧
        let memberKeys: Set<String>                      // 两侧两格全部成员 key（变化检测用）
        let memberFrames: [String: CGRect]               // 各成员拖前实际帧（撤销落点用）
        let splitOverrideKey: String
        let splitOverrideValue: CGFloat?                 // 拖前 splitOverrides 原值（无则 nil，撤销时删键）
        let snapLo: CGFloat?  // 快照实际帧顶回对 lo 的贡献（无则 nil）
        let snapHi: CGFloat?  // 快照实际帧顶回对 hi 的贡献（无则 nil）
    }
    var dividerDragSnapshot: DividerDragSnapshot? = nil
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
    // 鼠标重排：会话事件 tap 只订阅左键，用来识别 ⌘ 交换和 ⌥⌘ 进堆叠。
    var eventTap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var tapRunning = false
    var mouseTapFailedLogged = false
    var windowOrder: [String] = []
    /// 手动堆叠：key 不占自己的磁贴，跟在 host 窗口所在的磁贴里。
    /// 窗口数刚好等于上限时，⌥⌘ 拖上去也靠这张表并进目标磁贴，原格子收掉。
    var stackedOnto: [String: String] = [:]

    // 其余格子的暗色由 No peek 和 Dim 控制。
    var lastActiveTile = 0

    // D 批状态：⌘拖交换 / ⌥⌘拖进堆叠
    enum DragMode { case swap, stack }
    /// spring：日常重排，约 5% 过冲。settle：交换/抬起，精确落到终点，不过冲、不互相穿透。
    enum MotionEase { case spring, settle }
    struct DragState {
        var mode: DragMode  // 拖动中可随 ⌥ 在 swap↔stack 间切换
        let sourceTile: Int
        let draggedKey: String
        var frames: [CGRect]  // 落点判定用的磁贴 frame（Cocoa 坐标）；拖动中按现势刷新，源格身份与原点不动
        let screenID: CGDirectDisplayID  // C 批：拖动发生的屏；跨屏松手按取消处理
        var targetTile: Int? = nil
        var grabOffset: CGPoint = .zero   // 指针相对窗口原点，抬起后保持抓取点
        var originFrame: CGRect = .zero   // 松手取消时弹回的格子帧
        var reactKey: String? = nil
        var reactHome: CGRect = .zero
        var ownsDrag: Bool = false        // 按下时已按 ⌘：事件由我们吞掉并自己移动窗口
        var tileTopKeys: [String] = []    // 与 frames 对齐的栈顶键，松手时按这个找目标窗；拖动中随 frames 一起刷新
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
    // owned 跟手合并（与缝拖动同一模式）：只记最新指针，主队列异步块按最新指针写一次 AX 帧。
    var dragFollowPending: CGPoint? = nil
    var dragFollowScheduled = false
    var dragLastWritten: (key: String, frame: CGRect)? = nil  // 跟手上次写出的帧（同手势内去重写用）
    // 本手势内拖中按⌘转换拒绝原因已记过一次（转换分支每事件重试，只记首因，不刷屏）。
    var dragConvertDeclineLogged = false
    // 抓后按 ⌘：按下时没按 ⌘，记下按下点，拖动中按住 ⌘时从按下点重建拖动。
    var plainDownPoint: CGPoint? = nil
    var plainDownScreenID: CGDirectDisplayID? = nil
    // 普通拖整叠跟随快照：按下时记下格顶与同叠成员的起始帧；拖动中格顶一动，成员按同一 delta 平移。
    // 格顶本身由系统原生拖动，我们不动它；格顶不动（框选、拖悬浮窗、点按）则 delta 为 0，不跟随。
    struct PlainDragTrack {
        let sid: CGDirectDisplayID
        let tileFrame: CGRect
        let topKey: String
        let topElement: AXUIElement
        let topStart: CGRect
        let followers: [(key: String, el: AXUIElement, start: CGRect)]
        var lastDelta: CGPoint = .zero
    }
    var plainDragTrack: PlainDragTrack? = nil
    var suppressSnapToastUntil: Date? = nil
    // 原生 resize 兜底：上次修复后仍卡在同一帧的窗口不再重复修（AX 拒绝或应用抢回位置时防每秒重试）。
    // 值是修复时记下的实际帧；帧变了或不再超出即清除，下一轮才允许再修。
    var overflowSnapStuck: [String: CGRect] = [:]
    // 普通拖弹回冷却与卡住抑制：与 overflowSnapStuck 同思路。
    // 盖邻格守卫的去抖：上次处理（记 member-only / 记日志）时的成员帧。
    // 已处理且帧未变时跳过，不再每秒重复记日志与无用的 AX 顶回；帧变化或不再盖住时清掉。
    var coverLoggedFrame: [String: CGRect] = [:]
    // 「顶不精确一致」日志去抖：同一帧只记一次，帧变化才再记，避免每秒一行把日志刷爆。
    var stuckLoggedFrame: [String: CGRect] = [:]
    // snapStuck 记上次弹回时的实际帧（同帧卡住不再重复放置、不再弹提示、不再记日志）；
    // snapToastAt 记每扇窗上次弹提示的时间（跨 tick 冷却 10 秒，冷却期内只弹回不弹提示，
    // 且绝不调用 showToast，避免重置 2.5s 消失计时）。
    var snapStuck: [String: CGRect] = [:]
    var snapToastAt: [String: Date] = [:]
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
        var tileLimit = defaultTileLimit
        var kind: LayoutKind = .grid
        var share: CGFloat = 0.5
        var gap: CGFloat = 8
        var whenFull: WhenFull = .stack
    }
    var globalSettings = ScreenSettings()  // 全局一套设置（按屏的平铺状态 lastTilesByScreen、stackTops 不动）
    var lastTilesByScreen: [CGDirectDisplayID: [(stack: [WinInfo], frame: CGRect, top: WinInfo)]] = [:]
    // 最小尺寸装不进任何格子的窗口：并进最近格子的堆叠里，靠悬停条芯片切换，
    // 不再浮到屏幕中央。它们不参与格子几何的申领，否则同一批窗口会在格子间来回跳。
    var oversizeStacked: Set<String> = []
    // 成员键 → 它并进的那一格的顶层窗口键（每轮据此挂回去，保证不来回换格）。
    var oversizeHost: [String: String] = [:]
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
    /// 这一屏实际用的数量、族和间距。不改已保存的上限和用户设的间距。
    /// 高屏把族收成 Rows。
    func layoutSettings(for screen: NSScreen) -> ScreenSettings {
        var st = settingsFor(screen)
        let vf = screen.visibleFrame
        st.kind = resolvedLayoutKind(st.kind, vf: vf)
        st.gap = gapForLayout()
        st.tileLimit = effectiveTileLimit(st.tileLimit, kind: st.kind, vf: vf, gap: st.gap)
        return st
    }

    func gapForLayout() -> CGFloat {
        effectiveLayoutGap(setGap: globalSettings.gap)
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

    // 整叠交换置换：显示格 i 装计算格 perm[i] 的叠，无记录 = 恒等。
    // stackTops 一律按计算格键存取；显示侧（堆叠面板、圆点、悬停条、格顶读取）读写显示格时经 permSrcSlot 翻译，
    // 计算侧（computeTiles/applyPrimarySwap/tile 内部）直接用计算格下标，不翻译。
    // 置换只换每格里装哪一叠，不动 windowOrder/stackedOnto/Primary，因此后续重算不会把交换 undo。
    var tileSwapPermByScreen: [CGDirectDisplayID: [Int]] = [:]

    /// 显示格 -> 计算格（无置换或越界时返回自身，永不崩）。
    func permSrcSlot(_ displayed: Int, sid: CGDirectDisplayID) -> Int {
        guard displayed >= 0, let perm = tileSwapPermByScreen[sid],
              displayed < perm.count else { return displayed }
        return perm[displayed]
    }

    /// 计算格 -> 显示格（无置换或找不到时返回自身，永不崩）。
    func permDisplaySlot(_ compute: Int, sid: CGDirectDisplayID) -> Int {
        guard compute >= 0, let perm = tileSwapPermByScreen[sid] else { return compute }
        return perm.firstIndex(of: compute) ?? compute
    }

    /// 置换消毒：去重、去越界、补齐缺失下标（窗口增减后尽力保持相对顺序，不崩不丢格）。
    func sanitizedSwapPerm(_ perm: [Int]?, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var seen = Set<Int>()
        var out: [Int] = []
        if let perm {
            for v in perm where v >= 0 && v < count && !seen.contains(v) { seen.insert(v); out.append(v) }
        }
        for v in 0..<count where !seen.contains(v) { out.append(v) }
        return out
    }







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
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateHover()
        }
        // 切 Space 与接/断屏时立即重排。Focus 期间 forceTile 会跳过。
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            log("space changed")
            self?.forceTile()
        }
        // 约束自适应平铺没有自动可见性状态机：前台变化不再翻组（切 App 只改活动格，不藏窗），
        // 退出时也没有藏过的 App 需要放出；故这两路监听随自动独占路径一并删除。
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            log("screen parameters changed")
            self?.scheduleScreenChangeRetile()
        }
        tick()
        log("TileProto started, limit=\(tileLimit) excluded=\(excludedBundles.count)")
    }

    // MARK: - 菜单栏面板

    // 菜单栏图标：与应用图标同款的一大两小磁贴，程序化绘制的模板图（无深色底）。
    // isTemplate = true，系统按浅色/深色菜单栏自动反白。未授权时右上角加感叹号
    // 徽标：实心圆 + 透明 ! 镂空（模板图只认 alpha，红点在模板模式下不会显红，
    // 故不用红点），授权恢复后回到干净模板图。
    func menuBarIcon(untrusted: Bool) -> NSImage {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSColor.black.setFill()
        let m: CGFloat = 1, g: CGFloat = 2
        let bigW = (s - m * 2 - g) * 0.56
        let smallX = m + bigW + g
        let smallW = s - m - smallX
        let smallH = (s - m * 2 - g) / 2
        func tile(_ r: NSRect) {
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
        tile(NSRect(x: m, y: m, width: bigW, height: s - m * 2))
        tile(NSRect(x: smallX, y: m + smallH + g, width: smallW, height: smallH))
        tile(NSRect(x: smallX, y: m, width: smallW, height: smallH))
        if untrusted {
            // 右上角徽标：直径 8 的实心圆，圆内用 destinationOut 镂出 !（竖条 + 圆点）
            NSBezierPath(ovalIn: NSRect(x: s - 8, y: s - 8, width: 8, height: 8)).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(roundedRect: NSRect(x: s - 4.75, y: s - 5, width: 1.5, height: 3.5), xRadius: 0.75, yRadius: 0.75).fill()
            NSBezierPath(ovalIn: NSRect(x: s - 4.75, y: s - 7, width: 1.5, height: 1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    func setupPanelUI() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ""
        statusItem.button?.image = menuBarIcon(untrusted: false)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))
        buildPanelContent()
        let vc = NSViewController()
        vc.view = panelContainer
        panelPopover = NSPopover()
        panelPopover.contentViewController = vc
        // 用 .applicationDefined 而不是 .transient：平铺要 AXRaise 别人的窗口，
        // 面板会因为本应用被切到后台而自动收起，用户点一次布局就得重开一次。
        // 关闭交给下面的全局/本地 mouseDown 监听（点面板外才关）。
        panelPopover.behavior = .applicationDefined
        panelPopover.animates = true
        installPanelDismissMonitors()
        refreshPanel()
    }

    // 点面板以外的地方立刻关面板。NSPopover 的 .transient 在辅助功能 App 上常常收不到外部点击
    // （面板弹出后应用不是 active，第一次点击被系统吞掉），于是要再点一次菜单栏图标才关得上。
    // 只监听鼠标按下；命中面板或菜单栏图标时不动手，避免把一次开/关变成两次。
    func installPanelDismissMonitors() {
        guard panelDismissMonitors.isEmpty else { return }
        let handle: (NSEvent) -> Bool = { [weak self] _ in
            guard let self, self.panelPopover?.isShown == true else { return false }
            let point = NSEvent.mouseLocation
            let panelFrame = self.panelPopover.contentViewController?.view.window?.frame
            let statusFrame = self.statusItem?.button?.window?.frame
            guard panelClickIsOutside(point, panelFrame: panelFrame, statusFrame: statusFrame) else { return false }
            self.panelPopover.close()
            return false
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ = handle($0) }) {
            panelDismissMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            _ = handle(e)
            return e
        }) {
            panelDismissMonitors.append(local)
        }
    }

    @objc func togglePanel(_ sender: NSButton) {
        guard let button = statusItem.button else { return }
        if panelPopover.isShown {
            panelPopover.close()
        } else {
            refreshPanel()
            panelPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // 面板内容可能高于屏高上限：每次打开都从顶部开始，先看到状态与布局族。
            scrollPanelToTop()
        }
    }

    /// 面板打开时把内容滚回顶部：文档视图从下往上翻之前留下的位置可能停在半截。
    func scrollPanelToTop() {
        guard let scroll = panelScroll else { return }
        DispatchQueue.main.async {
            scroll.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
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
        header.addArrangedSubview(sectionLabel("Automatic tiling"))
        header.addArrangedSubview(autoSwitch)
        stack.addArrangedSubview(w288(header))

        // 状态行
        let statusRow = hRow(spacing: 6)
        statusDot = DotView(frame: .zero)
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tidyButton = NSButton(title: "Tidy it", target: self, action: #selector(panelTidy(_:)))
        tidyButton.bezelStyle = .inline
        tidyButton.isBordered = false
        tidyButton.font = .systemFont(ofSize: 12, weight: .semibold)
        tidyButton.isHidden = true
        statusRow.detachesHiddenViews = true
        statusRow.addArrangedSubview(statusDot)
        statusRow.addArrangedSubview(statusLabel)
        statusRow.addArrangedSubview(tidyButton)
        stack.addArrangedSubview(w288(statusRow))

        // 磁贴预览：按这一屏真实格子的比例画，不按个数等分。放在布局与主操作之后，
        // 面板第一眼先看到状态和布局，而不是一大幅图。
        minimapView = MinimapView(frame: NSRect(x: 0, y: 0, width: 288, height: 168))
        minimapView.heightAnchor.constraint(equalToConstant: 168).isActive = true
        tilesPlaceholder = NSTextField(labelWithString: "No windows to tile on this screen")
        tilesPlaceholder.font = .systemFont(ofSize: 12)
        tilesPlaceholder.textColor = .secondaryLabelColor
        tilesPlaceholder.isHidden = true

        let resetRow = hRow()
        let resetBtn = NSButton(title: "Reset sizes", target: self, action: #selector(panelResetSizes(_:)))
        resetBtn.bezelStyle = .inline
        resetBtn.isBordered = false
        resetBtn.font = .systemFont(ofSize: 12, weight: .medium)
        resetRow.addArrangedSubview(resetBtn)
        resetRow.isHidden = true
        resetRow.detachesHiddenViews = true
        resetSizesRow = resetRow
        stack.addArrangedSubview(w288(resetRow))

        let captionRow = hRow()
        let windowsLabel = sectionLabel("Windows on this screen")
        windowsLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        windowsLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let captionSpacer = NSView()
        captionSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        layoutCaptionLabel = sectionLabel("Grid · Grid of four")
        layoutCaptionLabel.alignment = .right
        layoutCaptionLabel.lineBreakMode = .byTruncatingTail
        layoutCaptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionRow.addArrangedSubview(windowsLabel)
        captionRow.addArrangedSubview(captionSpacer)
        captionRow.addArrangedSubview(layoutCaptionLabel)
        stack.addArrangedSubview(w288(captionRow))

        let familyRow = hRow(distribution: .fillEqually)
        let familySpecs: [(String, LayoutKind, String, [CGRect])] = [
            ("Grid", .grid, "One big window, the rest beside it", [
                CGRect(x: 0, y: 0, width: 0.47, height: 0.47),
                CGRect(x: 0.53, y: 0, width: 0.47, height: 0.47),
                CGRect(x: 0, y: 0.53, width: 0.47, height: 0.47),
                CGRect(x: 0.53, y: 0.53, width: 0.47, height: 0.47),
            ]),
            ("Columns", .columns, "Every window side by side", [
                CGRect(x: 0, y: 0, width: 0.30, height: 1),
                CGRect(x: 0.35, y: 0, width: 0.30, height: 1),
                CGRect(x: 0.70, y: 0, width: 0.30, height: 1),
            ]),
            ("Rows", .rows, "Every window full width, one above the other", [
                CGRect(x: 0, y: 0, width: 1, height: 0.30),
                CGRect(x: 0, y: 0.35, width: 1, height: 0.30),
                CGRect(x: 0, y: 0.70, width: 1, height: 0.30),
            ]),
            ("Side", .side, "One big window, the others in one column beside it", [
                CGRect(x: 0, y: 0, width: 0.58, height: 1),
                CGRect(x: 0.64, y: 0, width: 0.36, height: 0.47),
                CGRect(x: 0.64, y: 0.53, width: 0.36, height: 0.47),
            ]),
        ]
        for (i, spec) in familySpecs.enumerated() {
            let b = DiagramButton(title: spec.0)
            b.rects = spec.3
            b.toolTip = spec.2
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

        fitWarningLabel = NSTextField(labelWithString: "")
        fitWarningLabel.font = .systemFont(ofSize: 11)
        fitWarningLabel.textColor = .secondaryLabelColor
        fitWarningLabel.maximumNumberOfLines = 2
        fitWarningLabel.lineBreakMode = .byWordWrapping
        fitWarningLabel.isHidden = true
        stack.addArrangedSubview(w288(fitWarningLabel))

        // 动作格：图标在上，文字在下。主窗份额、间距和满格策略在设置页。
        let actionRow = hRow(distribution: .fillEqually, spacing: 8)
        actionRow.addArrangedSubview(panelTileButton("Retile", symbol: "arrow.clockwise", action: #selector(panelTileNow(_:))))
        restoreFloatsButton = panelTileButton("Restore floats", symbol: "arrow.uturn.backward", action: #selector(panelRestoreFloats(_:)))
        actionRow.addArrangedSubview(restoreFloatsButton)
        stack.addArrangedSubview(w288(actionRow))
        stack.addArrangedSubview(w288(panelTileButton("Tab view", symbol: "square.grid.2x2", action: #selector(panelTabView(_:)))))

        // 布局预览跟在主操作后面：面板从上到下是「状态 → 布局 → 操作 → 预览 → 开关」。
        stack.addArrangedSubview(w288(minimapView))
        stack.addArrangedSubview(w288(tilesPlaceholder))

        noPeekSwitch = NSSwitch()
        noPeekSwitch.target = self
        noPeekSwitch.action = #selector(panelToggleNoPeek(_:))
        stack.addArrangedSubview(w288(settingCard(icon: tintedSymbol("eye.slash", point: 14, color: .labelColor), label: NSTextField(labelWithString: "No peek mode"), control: noPeekSwitch)))

        hoverFocusSwitch = NSSwitch()
        hoverFocusSwitch.target = self
        hoverFocusSwitch.action = #selector(panelToggleHoverFocus(_:))
        stack.addArrangedSubview(w288(settingCard(icon: tintedSymbol("cursorarrow.rays", point: 14, color: .labelColor), label: NSTextField(labelWithString: "Hover focus"), control: hoverFocusSwitch)))

        cleanSpaceSwitch = NSSwitch()
        cleanSpaceSwitch.target = self
        cleanSpaceSwitch.action = #selector(panelToggleCleanSpace(_:))
        stack.addArrangedSubview(w288(settingCard(icon: tintedSymbol("moon", point: 14, color: .labelColor), label: NSTextField(labelWithString: "Clean Space"), control: cleanSpaceSwitch)))

        tileAppLabel = NSTextField(labelWithString: "Tile")
        tileAppLabel.lineBreakMode = .byTruncatingTail
        tileAppIconView = NSImageView()
        tileAppIconView.image = tintedSymbol("macwindow", point: 14, color: .labelColor)
        tileAppSwitch = NSSwitch()
        tileAppSwitch.target = self
        tileAppSwitch.action = #selector(panelToggleTileApp(_:))
        stack.addArrangedSubview(w288(settingCard(iconView: tileAppIconView, label: tileAppLabel, control: tileAppSwitch)))
        stack.addArrangedSubview(w288(panelTileButton("Settings", symbol: "gearshape", action: #selector(panelOpenSettings(_:)))))

        // 底部（重新请求权限仅在未授权时显示）
        let footerRow = hRow(distribution: .fillEqually)
        requestAXButton = NSButton(title: "Allow Accessibility", target: self, action: #selector(panelRequestAX(_:)))
        let quitBtn = NSButton(title: "Quit TileProto", target: self, action: #selector(panelQuit(_:)))
        footerRow.addArrangedSubview(requestAXButton!)
        footerRow.addArrangedSubview(quitBtn)
        stack.addArrangedSubview(w288(footerRow))

        // 面板高度被屏高上限压住时，让内容去滚动：每一行都按自己的高度顶着，不被挤成 0。
        // 少了这一步，顶部的状态行与布局族会被压缩掉，用户以为面板里没有这些控件。
        for view in stack.arrangedSubviews {
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        stack.setContentCompressionResistancePriority(.required, for: .vertical)

        // 面板内容比屏幕还高时，NSPopover 会把它顶到菜单栏上方、露出屏外。
        // 放进可滚动容器，并给容器一个不超过可见区的最大高度。
        let scroll = NSScrollView()
        panelScroll = scroll
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedBox()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        panelContainer = NSView()
        panelContainer.addSubview(scroll)
        panelContainer.widthAnchor.constraint(equalToConstant: 320).isActive = true
        // 面板与文档高度都由 refreshPanel 按内容真实高度写死（窗口不超过屏高上限）。
        // 只让视口裁剪、内部滚动，不去压缩行：压下去会把状态行挤掉半行字。
        let ph = panelContainer.heightAnchor.constraint(equalToConstant: 600)
        ph.isActive = true
        panelHeightConstraint = ph
        let dh = doc.heightAnchor.constraint(equalToConstant: 600)
        dh.isActive = true
        panelDocHeight = dh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: panelContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: panelContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panelContainer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: panelContainer.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    func refreshPanel() {
        guard panelContainer != nil, panelPopover != nil else { return }
        let trusted = AXIsProcessTrusted()
        autoSwitch.state = autoTile ? .on : .off
        tidyButton?.isHidden = trusted
        var captionCount = min(max(globalSettings.tileLimit, 1), 4)
        if !trusted {
            statusDot.color = .systemGray
            statusLabel.stringValue = "Waiting for setup to finish"
            tilesPlaceholder.isHidden = false
            minimapView.isHidden = true
            fitWarningLabel.isHidden = true
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                captionCount = effectiveTileLimit(globalSettings.tileLimit, kind: globalSettings.kind, vf: screen.visibleFrame, gap: gapForLayout())
            }
        } else {
            // 面板显示主屏的磁贴；设置是全局一套。数量先收到这块屏装得下的档。
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let sid = screenID(screen)
            let st = layoutSettings(for: screen)
            let windows = collectWindows(on: screen)
            let (rawStacks, rawActive, _) = computeTiles(windows: windows, st: st, sid: sid)
            // 面板按显示顺序列磁贴：整叠交换后行序与屏上格序一致，活动行也跟着翻译。
            let panelPerm = sanitizedSwapPerm(tileSwapPermByScreen[sid], count: rawStacks.count)
            let stacks = panelPerm.map { rawStacks[$0] }
            let active = panelPerm.firstIndex(of: rawActive) ?? rawActive
            let windowCount = stacks.reduce(0) { $0 + $1.count }
            captionCount = stacks.isEmpty ? st.tileLimit : stacks.count
            if stageManagerPaused {
                statusDot.color = .systemOrange
                statusLabel.stringValue = "Stage Manager paused"
            } else if autoTile {
                statusDot.color = .systemGreen
                statusLabel.stringValue = "Tiling \(windowCount) window\(windowCount == 1 ? "" : "s")"
            } else {
                statusDot.color = .systemGray
                statusLabel.stringValue = "Automatic tiling is off"
            }
            if focusKey != nil { statusLabel.stringValue += " · Focus" }
            if cleanSpaceOn { statusLabel.stringValue += " · Clean Space" }
            if autoTile && !stageManagerPaused && !tapRunning {
                statusLabel.stringValue += " · drag-to-swap unavailable"
            }
            let warning = fitWarning(on: screen, windows: windows)
            fitWarningLabel.stringValue = warning ?? ""
            fitWarningLabel.isHidden = warning == nil
            if !autoTile {
                tilesPlaceholder.stringValue = "Tiling is off"
                tilesPlaceholder.isHidden = false
                minimapView.isHidden = true
            } else {
                tilesPlaceholder.stringValue = "No windows to tile on this screen"
                tilesPlaceholder.isHidden = !stacks.isEmpty
                minimapView.isHidden = stacks.isEmpty
            }
            if autoTile, !stacks.isEmpty {
                let live = lastTilesByScreen[sid] ?? []
                let useLive = live.count == stacks.count && live.allSatisfy { $0.frame.width > 1 && $0.frame.height > 1 }
                let sourceFrames: [CGRect]
                let tops: [WinInfo]
                let counts: [Int]
                let focusFlags: [Bool]
                if useLive {
                    sourceFrames = live.map { $0.frame }
                    tops = live.map { $0.top }
                    counts = live.map { $0.stack.count }
                    focusFlags = live.map { tile in
                        focusKey != nil && focusScreen == sid && tile.stack.contains { winKey($0) == focusKey }
                    }
                } else {
                    let kind = resolvedLayoutKind(st.kind, vf: screen.visibleFrame)
                    sourceFrames = layoutFrames(count: stacks.count, vf: screen.visibleFrame, kind: kind, share: st.share, gap: st.gap)
                    tops = stacks.enumerated().map { i, stack in
                        let src = permSrcSlot(i, sid: sid)
                        let idx = min(max(stackTops[stackTopKey(sid, src)] ?? 0, 0), stack.count - 1)
                        return stack[idx]
                    }
                    counts = stacks.map { $0.count }
                    focusFlags = stacks.map { stack in
                        focusKey != nil && focusScreen == sid && stack.contains { winKey($0) == focusKey }
                    }
                }
                let canvas = minimapView.bounds.width > 2
                    ? minimapView.bounds.insetBy(dx: 6, dy: 6)
                    : CGRect(x: 6, y: 6, width: 276, height: 156)
                let mapped = minimapLayout(work: screen.visibleFrame, frames: sourceFrames, canvas: canvas)
                let focusHere = focusFlags.contains(true)
                var panes: [MinimapView.Pane] = []
                for i in mapped.indices {
                    let focused = i < focusFlags.count && focusFlags[i]
                    panes.append(MinimapView.Pane(
                        rect: mapped[i],
                        title: i < tops.count ? tops[i].appName : "",
                        count: i < counts.count ? counts[i] : 1,
                        active: i == active && !focusHere,
                        focused: focused,
                        dimmed: focusHere && !focused
                    ))
                }
                minimapView.panes = panes
                let picked = tops
                minimapView.onSelect = { [weak self] index in
                    guard let self, picked.indices.contains(index) else { return }
                    self.activateTile(picked[index])
                }
            }
        }
        // 面板控件反映全局设置：高亮的是用户保存的那一档，不是钳制后的引擎档。
        // 以前这里高亮 min(保存值, fitCap) 并把超 fitCap 的档位禁用，导致“面板明明设了 4、
        // 却显示 3 且点不回 4”；族/fitCap 的钳制只在引擎用时算，由脚注 capacityNote 明示。
        let panelSt = globalSettings
        let fitScreen = NSScreen.main ?? NSScreen.screens.first
        let fitCap = fitScreen.map { maxFitCount(on: $0) } ?? 4
        if let note = capacityNote(kind: panelSt.kind, fitted: fitCap) {
            fitWarningLabel.stringValue = note
            fitWarningLabel.isHidden = false
        }
        let captionScreen = fitScreen?.visibleFrame ?? .zero
        let captionKind = captionScreen.width > 1 ? resolvedLayoutKind(panelSt.kind, vf: captionScreen) : panelSt.kind
        layoutCaptionLabel?.stringValue = layoutCaption(kind: captionKind, count: captionCount)
        resetSizesRow?.isHidden = splitOverrides.isEmpty
        for b in countButtons {
            b.rects = countDiagram(b.indexTag, kind: panelSt.kind)
            b.isDisabled = false
            b.isSelected = (b.indexTag == panelSt.tileLimit)
            if b.indexTag == 1 {
                b.toolTip = "1 window"
            } else if b.indexTag > fitCap, let note = capacityNote(kind: panelSt.kind, fitted: fitCap) {
                b.toolTip = note
            } else {
                b.toolTip = "Up to \(b.indexTag) windows"
            }
            b.needsDisplay = true
        }
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
        let shareValues: [CGFloat] = [0.5, 0.6, 2.0 / 3.0]
        for b in shareButtons {
            let selected = shareValues.indices.contains(b.tag) && abs(shareValues[b.tag] - globalSettings.share) < 0.02
            b.contentTintColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.85) : .labelColor
            let font = NSFont.systemFont(ofSize: 12, weight: selected ? .bold : .medium)
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .foregroundColor: selected ? NSColor.controlAccentColor.withAlphaComponent(0.85) : NSColor.labelColor,
                .font: font,
            ])
        }
        for b in whenFullButtons {
            let selected = b.tag == globalSettings.whenFull.rawValue
            let font = NSFont.systemFont(ofSize: 12, weight: selected ? .bold : .medium)
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .foregroundColor: selected ? NSColor.controlAccentColor.withAlphaComponent(0.85) : NSColor.labelColor,
                .font: font,
            ])
        }
        if NSEvent.pressedMouseButtons == 0 {
            gapSlider?.doubleValue = Double(globalSettings.gap)
            gapValueLabel?.stringValue = "\(Int(globalSettings.gap.rounded()))"
        }
        noPeekSwitch?.state = noPeek ? .on : .off
        hoverFocusSwitch?.state = hoverFocus ? .on : .off
        cleanSpaceSwitch?.state = cleanSpaceOn ? .on : .off
        loginSwitch?.state = loginItemEnabled() ? .on : .off
        requestAXButton.isHidden = trusted
        // 只有高度变化时才改 popover 尺寸，避免每秒抖动
        panelContainer.layoutSubtreeIfNeeded()
        // 内容真实高度按行逐个累加（不读被视口压过的 fittingSize），
        // 文档高度跟着写死，滚动查看剩余内容，行本身不被压扁。
        let rows = panelStack.arrangedSubviews.filter { !$0.isHidden }
        let contentH = panelStack.edgeInsets.top + panelStack.edgeInsets.bottom
            + rows.reduce(CGFloat(0)) { $0 + $1.fittingSize.height }
            + panelStack.spacing * CGFloat(max(0, rows.count - 1))
        let maxH = min(660, (NSScreen.main ?? NSScreen.screens[0]).visibleFrame.height - 90)
        let docH = max(contentH, 200)
        let winH = min(docH, maxH)
        panelDocHeight?.constant = docH
        panelHeightConstraint?.constant = winH
        if abs(winH - lastPanelHeight) > 0.5 {
            lastPanelHeight = winH
            panelPopover.contentSize = NSSize(width: 320, height: winH)
        }
    }

    func activateTile(_ w: WinInfo) {
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: w.pid) { app.activate() }
        log("panel tile activated: \(w.appName)")
        panelPopover.close()
    }

    // 格子数上限是全局设置：用户点的档位照单存下。族/fitCap 导致的引擎钳制只在用时算
    // （layoutSettings），这里绝不拒收、绝不静默改值；钳制时用 capacityNote 明示原因。
    func applyLimit(_ v: Int) {
        var st = globalSettings
        let screen = activeScreen()
        if v < 1 || v > 4 {
            log("tileLimit \(v) rejected; max 4")
            refreshPanel()
            return
        }
        let fitsNow = countFits(v, on: screen)
        if v > st.tileLimit {
            promoteBuriedWindowForNewPane(on: screen)
        }
        st.tileLimit = v
        setSettingsFor(st, screen: activeScreen())
        log("tileLimit -> \(v)")
        if !fitsNow, let note = capacityNote(kind: st.kind, fitted: maxFitCount(on: screen)) {
            showToast(v == 1 ? "1 window" : "Up to \(v) windows", detail: note, on: activeScreen())
        } else {
            showToast(v == 1 ? "1 window" : "Up to \(v) windows", detail: "On this screen.", on: activeScreen())
        }
        applyLayoutSwitchOneShot()
        refreshPanel()
        refreshSettingsIfOpen()
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

    /// 格数变多时，从人数最多的那一叠里拆出最久没被用到的非顶层窗口，让它占新开的格子。
    func promoteBuriedWindowForNewPane(on screen: NSScreen) {
        let sid = screenID(screen)
        guard let tiles = lastTilesByScreen[sid], !tiles.isEmpty else { return }
        guard let fullest = tiles.max(by: { $0.stack.count < $1.stack.count }), fullest.stack.count > 1 else { return }
        let topKey = winKey(fullest.top)
        let buried = fullest.stack.filter { winKey($0) != topKey }
        guard !buried.isEmpty else { return }
        func rank(_ w: WinInfo) -> Int {
            windowOrder.firstIndex(of: winKey(w)) ?? -1
        }
        guard let oldest = buried.min(by: { rank($0) < rank($1) }) else { return }
        let promoted = winKey(oldest)
        var owners: [String] = []
        for tile in tiles {
            if let root = tile.stack.first(where: { stackedOnto[winKey($0)] == nil }) {
                owners.append(winKey(root))
            } else {
                owners.append(winKey(tile.top))
            }
        }
        if stackedOnto[promoted] != nil {
            let children = stackedOnto.filter { $0.value == promoted }.map { $0.key }
            stackedOnto.removeValue(forKey: promoted)
            for child in children where child != topKey {
                stackedOnto[child] = topKey
            }
            normalizeStackedOnto(liveKeys: Set(tiles.flatMap { $0.stack.map { winKey($0) } }))
        }
        windowOrder = windowOrderPromoting(windowOrder, owners: owners, promoted: promoted)
        log("limit widened: \(oldest.appName) leaves the fullest stack")
    }

    func frontRegularApp() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let app = NSWorkspace.shared.frontmostApplication,
           app.activationPolicy == .regular,
           app.processIdentifier != me {
            lastRegularFrontApp = app
            return app
        }
        // 面板或设置窗拿到 key 时前台变成辅助型的 TileProto，退回最后一次真正的常规前台 App。
        if let cached = lastRegularFrontApp, !cached.isTerminated,
           cached.activationPolicy == .regular,
           cached.processIdentifier != me {
            return cached
        }
        return nil
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

    /// 一格始终可用。更多格按参考最小尺寸判断，装不下就变灰。高屏按 Rows 判断。
    func countFits(_ count: Int, on screen: NSScreen) -> Bool {
        let vf = screen.visibleFrame
        let kind = resolvedLayoutKind(globalSettings.kind, vf: vf)
        return layoutCountFits(count, kind: kind, vf: vf, gap: gapForLayout())
    }

    func maxFitCount(kind: LayoutKind, on screen: NSScreen) -> Int {
        let vf = screen.visibleFrame
        let kind = resolvedLayoutKind(kind, vf: vf)
        var cap = 1
        let limit = kind == .rows ? 3 : 4
        for n in 1...limit where layoutCountFits(n, kind: kind, vf: vf, gap: gapForLayout()) {
            cap = n
        }
        return cap
    }

    func maxFitCount(on screen: NSScreen) -> Int {
        maxFitCount(kind: globalSettings.kind, on: screen)
    }

    func fitWarning(on screen: NSScreen, windows: [WinInfo]) -> String? {
        let st = globalSettings
        let vf = screen.visibleFrame
        let kind = resolvedLayoutKind(st.kind, vf: vf)
        let gap = gapForLayout()
        let limit = effectiveTileLimit(st.tileLimit, kind: kind, vf: vf, gap: gap)
        let count = min(max(windows.count, 1), limit, 4)
        let frames = layoutFrames(count: count, vf: vf, kind: kind, share: st.share, gap: gap)
        guard !frames.isEmpty else { return nil }
        var overflow = 0
        for w in windows {
            let need = effectiveMin(for: w)
            let fits = frames.contains { slotShortfall(need, $0) == 0 }
            if !fits { overflow += 1 }
        }
        if overflow == 0 { return nil }
        if overflow == 1 {
            return "1 window is larger than its cell. It stays in the tile as a stacked member."
        }
        return "\(overflow) windows are larger than their cells. They stay in their tiles as stacked members."
    }

    func applyLayoutKind(_ kind: LayoutKind) {
        var st = globalSettings
        let screen = activeScreen()
        st.kind = kind
        // 上限是用户在面板里定的，不随族改动：以前这里把上限抬到族形数并存回，
        // 导致“面板设 3、切 Grid 后存成 4、切回 Rows 引擎又跑 3”，三值打架。族形只在用时算
        // （layoutSettings 的 effectiveTileLimit），绝不把钳制值存回覆盖用户设置。
        setSettingsFor(st, screen: screen)
        let fitted = maxFitCount(kind: kind, on: screen)
        log("layout -> \(layoutName(kind)) fitted=\(fitted) limit=\(st.tileLimit)")
        if resolvedLayoutKind(kind, vf: screen.visibleFrame) != kind {
            showToast("Rows", detail: "Tall screens stack windows in rows.", on: screen)
        } else if let note = capacityNote(kind: kind, fitted: fitted) {
            showToast(layoutName(kind), detail: note, on: screen)
        } else {
            showToast(layoutName(kind), on: screen)
        }
        applyLayoutSwitchOneShot()
        refreshPanel()
        refreshSettingsIfOpen()
    }

    @objc func panelShare(_ sender: NSButton) {
        let values: [CGFloat] = [0.5, 0.6, 2.0 / 3.0]
        guard values.indices.contains(sender.tag) else { return }
        let value = values[sender.tag]
        var st = globalSettings
        st.share = value
        setSettingsFor(st, screen: activeScreen())
        log("share -> \(sender.title)")
        showToast("Main window \(sender.title)", detail: "The others share the rest.", on: activeScreen())
        // 份额是格子几何参数：改份额必须全量重算并重记冻结布局，
        // 否则冻结轮次会把格子写回旧份额帧。
        oneShotFreshScreens.insert(screenID(activeScreen()))
        forceTile()
        refreshPanel()
        refreshSettingsIfOpen()
    }

    @objc func panelGap(_ sender: NSSlider) {
        var st = globalSettings
        // 间距按 2pt 档，范围 0–24，与面板刻度一致。
        let g = CGFloat(snappedGap(sender.integerValue))
        st.gap = g
        sender.doubleValue = Double(g)
        gapValueLabel?.stringValue = "\(Int(g))"
        setSettingsFor(st, screen: activeScreen())
        log("gap -> \(Int(g))")
        // 间距同为几何参数：改间距必须全量重算并重记冻结布局。
        oneShotFreshScreens.insert(screenID(activeScreen()))
        forceTile()
        refreshPanel()
        refreshSettingsIfOpen()
    }

    @objc func panelWhenFull(_ sender: NSButton) {
        guard let mode = WhenFull(rawValue: sender.tag) else { return }
        var st = globalSettings
        guard st.whenFull != mode else { return }
        st.whenFull = mode
        setSettingsFor(st, screen: activeScreen())
        log("whenFull -> \(mode == .stack ? "stack" : "float")")
        showToast(mode == .stack ? "Stack in the active tile" : "Float in the middle",
                  detail: mode == .stack
                    ? "Extra windows go on top of the tile you’re in."
                    : "A new window floats in the middle until there’s room.",
                  on: activeScreen())
        forceTile()
        refreshPanel()
        refreshSettingsIfOpen()
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

    @objc func panelToggleNoPeek(_ sender: NSSwitch) {
        noPeek = sender.state == .on
        saveLayoutSettings()
        log(noPeek ? "no peek on" : "no peek off")
        if noPeek { refreshDimLayers() } else { removeDimLayers() }
        showToast(noPeek ? "No peek mode on" : "No peek mode off",
                  detail: "Other tiles dim. They still work. Turn the switch again to go back.",
                  on: activeScreen())
        refreshPanel()
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
        showToast("Arranged again", on: activeScreen())
        refreshPanel()
    }

    @objc func panelTidy(_ sender: NSButton) {
        if !AXIsProcessTrusted() {
            requestAccessibility()
            return
        }
        panelTileNow(sender)
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
        // 自动可见性路径已删：退出时没有藏过的 App 需要放出，直接退出。
        NSApplication.shared.terminate(nil)
    }

    @objc func panelOpenSettings(_ sender: NSButton) {
        panelPopover?.close()
        openSettings()
    }

    var settingsWindow: NSWindow?
    var settingsPageHost: NSView?
    var settingsPage = 0
    var settingsSidebarButtons: [NSButton] = []
    var tourWindow: NSPanel?
    var tourStep = 0

    let settingsPageNames = ["General", "Layout", "Mouse", "Keyboard", "Apps", "Activity", "About"]

    func openSettings() {
        if settingsWindow == nil { buildSettingsWindow() }
        showSettingsPage(settingsPage)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshSettingsIfOpen() {
        guard settingsWindow?.isVisible == true else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.settingsWindow?.isVisible == true else { return }
            self.showSettingsPage(self.settingsPage)
        }
    }

    func buildSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        let root = NSView()
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 4
        sidebar.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        settingsSidebarButtons = []
        for (i, name) in settingsPageNames.enumerated() {
            let b = NSButton(title: name, target: self, action: #selector(settingsPickPage(_:)))
            b.tag = i
            b.bezelStyle = .inline
            b.isBordered = false
            b.alignment = .left
            b.font = .systemFont(ofSize: 13, weight: .medium)
            settingsSidebarButtons.append(b)
            sidebar.addArrangedSubview(b)
        }
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        settingsPageHost = host
        root.addSubview(sidebar)
        root.addSubview(host)
        window.contentView = root
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 168),
            host.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            host.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 8),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        settingsWindow = window
        window.center()
    }

    @objc func settingsPickPage(_ sender: NSButton) {
        showSettingsPage(sender.tag)
    }

    func showSettingsPage(_ page: Int) {
        settingsPage = min(max(page, 0), settingsPageNames.count - 1)
        guard let host = settingsPageHost else { return }
        for v in host.subviews { v.removeFromSuperview() }
        let body = makeSettingsPage(settingsPage)
        body.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: host.topAnchor),
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor),
        ])
        for (i, b) in settingsSidebarButtons.enumerated() {
            let on = i == settingsPage
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .foregroundColor: on ? NSColor.controlAccentColor : NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 13, weight: on ? .bold : .medium),
            ])
        }
    }

    func settingsColumn(_ title: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(heading)
        return stack
    }

    func settingsNote(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 500
        return l
    }

    func settingsChoice(_ title: String, tag: Int, action: Selector, on: Bool) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.tag = tag
        b.bezelStyle = .inline
        b.isBordered = false
        b.font = .systemFont(ofSize: 13, weight: on ? .bold : .medium)
        b.contentTintColor = on ? .controlAccentColor : .labelColor
        return b
    }

    func makeSettingsPage(_ page: Int) -> NSView {
        switch page {
        case 0: return settingsGeneralPage()
        case 1: return settingsLayoutPage()
        case 2: return settingsMousePage()
        case 3: return settingsKeyboardPage()
        case 4: return settingsAppsPage()
        case 5: return settingsActivityPage()
        default: return settingsAboutPage()
        }
    }

    func settingsGeneralPage() -> NSView {
        let stack = settingsColumn("General")
        let auto = NSSwitch()
        auto.state = autoTile ? .on : .off
        auto.target = self
        auto.action = #selector(panelToggleAuto(_:))
        stack.addArrangedSubview(settingCard(icon: tintedSymbol("rectangle.grid.2x2", point: 14, color: .labelColor), label: NSTextField(labelWithString: "Automatic tiling"), control: auto))
        loginSwitch = NSSwitch()
        loginSwitch.target = self
        loginSwitch.action = #selector(panelToggleLogin(_:))
        loginSwitch.state = loginItemEnabled() ? .on : .off
        stack.addArrangedSubview(settingCard(icon: tintedSymbol("power", point: 14, color: .labelColor), label: NSTextField(labelWithString: "Open at login"), control: loginSwitch))
        let tones = NSStackView()
        tones.orientation = .horizontal
        tones.spacing = 8
        for (i, name) in ["Graphite", "Stone", "Mist"].enumerated() {
            tones.addArrangedSubview(settingsChoice(name, tag: i, action: #selector(settingsCleanTone(_:)), on: cleanTone.rawValue == i))
        }
        stack.addArrangedSubview(NSTextField(labelWithString: "Clean Space background"))
        stack.addArrangedSubview(tones)
        let ax = NSTextField(labelWithString: AXIsProcessTrusted() ? "Accessibility access: Allowed" : "Accessibility access: Not allowed")
        ax.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(ax)
        stack.addArrangedSubview(settingsNote("TileProto arranges windows. It never reads what is inside them."))
        let tour = NSButton(title: "Welcome tour", target: self, action: #selector(settingsWelcomeTour(_:)))
        tour.bezelStyle = .rounded
        stack.addArrangedSubview(tour)
        stack.addArrangedSubview(settingsNote("App icon packs are not in this build."))
        return stack
    }

    func settingsLayoutPage() -> NSView {
        let stack = settingsColumn("Layout")
        let families = NSStackView()
        families.orientation = .horizontal
        families.spacing = 8
        for (i, kind) in [LayoutKind.grid, .columns, .rows, .side].enumerated() {
            let b = settingsChoice(layoutFamilyName(kind), tag: i, action: #selector(settingsPickFamily(_:)), on: globalSettings.kind == kind)
            families.addArrangedSubview(b)
        }
        stack.addArrangedSubview(NSTextField(labelWithString: "Layout"))
        stack.addArrangedSubview(families)
        stack.addArrangedSubview(settingsNote("Tall screens always stack windows in rows. Columns fit three on a MacBook and four on a bigger screen. Rows fit two or three. Side fits three or four."))
        shareButtons = []
        let shares = NSStackView()
        shares.orientation = .horizontal
        shares.spacing = 8
        for (i, title) in ["Half", "60%", "Two-thirds"].enumerated() {
            let values: [CGFloat] = [0.5, 0.6, 2.0 / 3.0]
            let b = settingsChoice(title, tag: i, action: #selector(panelShare(_:)), on: abs(globalSettings.share - values[i]) < 0.02)
            b.toolTip = "Where the main window starts. The others share the rest."
            shareButtons.append(b)
            shares.addArrangedSubview(b)
        }
        stack.addArrangedSubview(NSTextField(labelWithString: "Main window size"))
        stack.addArrangedSubview(shares)
        let counts = NSStackView()
        counts.orientation = .horizontal
        counts.spacing = 8
        let screen = NSScreen.main ?? NSScreen.screens.first
        let cap = screen.map { maxFitCount(on: $0) } ?? 4
        for n in 1...4 {
            let b = settingsChoice(n == 1 ? "1" : "\(n)", tag: n, action: #selector(settingsPickCount(_:)), on: globalSettings.tileLimit == n)
            b.isEnabled = n <= cap
            counts.addArrangedSubview(b)
        }
        stack.addArrangedSubview(NSTextField(labelWithString: "Windows per screen"))
        stack.addArrangedSubview(counts)
        stack.addArrangedSubview(settingsNote("Every screen starts with this number. Change it for one screen in the menu bar panel."))
        whenFullButtons = []
        let full = NSStackView()
        full.orientation = .horizontal
        full.spacing = 8
        for (title, mode) in [("Stack in the active tile", WhenFull.stack), ("Float in the middle", WhenFull.float)] {
            let b = settingsChoice(title, tag: mode.rawValue, action: #selector(panelWhenFull(_:)), on: globalSettings.whenFull == mode)
            whenFullButtons.append(b)
            full.addArrangedSubview(b)
        }
        stack.addArrangedSubview(NSTextField(labelWithString: "When a screen is full"))
        stack.addArrangedSubview(full)
        stack.addArrangedSubview(settingsNote("Stack puts extra windows into the tile you’re in. Float keeps a new window in the middle until there is room."))
        let gapRow = hRow(spacing: 8)
        gapRow.addArrangedSubview(sectionLabel("Space between windows"))
        gapSlider = NSSlider(value: Double(globalSettings.gap), minValue: 0, maxValue: 24, target: self, action: #selector(panelGap(_:)))
        gapSlider.isContinuous = false
        gapSlider.numberOfTickMarks = 13
        gapSlider.allowsTickMarkValuesOnly = true
        gapSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        gapValueLabel = NSTextField(labelWithString: "\(Int(globalSettings.gap.rounded()))")
        gapValueLabel.font = .systemFont(ofSize: 12, weight: .medium)
        gapRow.addArrangedSubview(gapSlider)
        gapRow.addArrangedSubview(gapValueLabel)
        stack.addArrangedSubview(gapRow)
        stack.addArrangedSubview(settingsNote("Also used around the screen’s edges. 0 to 24, in steps of 2."))
        let clearLearned = NSButton(title: "Clear learned minimum sizes", target: self, action: #selector(settingsClearLearnedMins(_:)))
        clearLearned.bezelStyle = .rounded
        clearLearned.toolTip = "Forget every per-app size TileProto learned. Layout falls back to what the app reports."
        stack.addArrangedSubview(clearLearned)
        stack.addArrangedSubview(settingsNote("Learned sizes are per app on this Mac. Clearing them is the fix when one app refuses to sit in its tile."))
        return stack
    }

    @objc func settingsClearLearnedMins(_ sender: NSButton) {
        learnedMinSizes.removeAll()
        saveLearnedMinSizes()
        log("min-size learned cleared by user")
        forceTile()
        refreshPanel()
    }

    @objc func settingsPickFamily(_ sender: NSButton) {
        let kinds: [LayoutKind] = [.grid, .columns, .rows, .side]
        guard kinds.indices.contains(sender.tag) else { return }
        applyLayoutKind(kinds[sender.tag])
    }

    @objc func settingsPickCount(_ sender: NSButton) {
        applyLimit(sender.tag)
    }

    @objc func settingsCleanTone(_ sender: NSButton) {
        cleanTone = CleanSpaceColor(rawValue: sender.tag) ?? .graphite
        saveLayoutSettings()
        if cleanSpaceOn, let screen = NSScreen.screens.first(where: { screenID($0) == cleanSpaceScreen }) {
            removeCleanDim()
            showCleanDim(on: screen, hole: cleanSpaceHole)
        }
        refreshSettingsIfOpen()
    }

    func settingsMousePage() -> NSView {
        let stack = settingsColumn("Mouse")
        let quick = NSSwitch()
        quick.state = hoverBarEnabled ? .on : .off
        quick.target = self
        quick.action = #selector(settingsHoverBar(_:))
        stack.addArrangedSubview(settingCard(icon: tintedSymbol("rectangle.topthird.inset.filled", point: 14, color: .labelColor), label: NSTextField(labelWithString: "Quick actions above windows"), control: quick))
        let hover = NSSwitch()
        hover.state = hoverFocus ? .on : .off
        hover.target = self
        hover.action = #selector(panelToggleHoverFocus(_:))
        stack.addArrangedSubview(settingCard(icon: tintedSymbol("cursorarrow.rays", point: 14, color: .labelColor), label: NSTextField(labelWithString: "Activate windows on hover"), control: hover))
        stack.addArrangedSubview(settingsNote("Always available"))
        stack.addArrangedSubview(settingsNote("Swap two windows. Hold Command and drag onto another window."))
        stack.addArrangedSubview(settingsNote("Add to a stack. Hold Option and Command and drag onto a tile."))
        stack.addArrangedSubview(settingsNote("Resize. Drag the edge between two windows. At rest that edge is only wallpaper. A tip shows while the pointer is on it."))
        stack.addArrangedSubview(settingsNote("Move to another screen. Drag a window onto the other screen."))
        return stack
    }

    @objc func settingsHoverBar(_ sender: NSSwitch) {
        hoverBarEnabled = sender.state == .on
        saveLayoutSettings()
        if !hoverBarEnabled { hideHoverBar() }
        log(hoverBarEnabled ? "hover bar on" : "hover bar off")
    }

    func settingsKeyboardPage() -> NSView {
        let stack = settingsColumn("Keyboard")
        stack.addArrangedSubview(settingsNote("Shortcuts stay off. TileProto is driven from the menu bar and the hover bar. This list is only a reminder of what those controls do."))
        let rows = [
            "Make primary — hover bar, Primary",
            "Focus, and leave it — hover bar, Focus",
            "Float, and tile it again — hover bar, Float",
            "Swap with the window you drag onto — hold Command",
            "Add to that tile’s stack — hold Option and Command",
            "Resize — drag the seam",
            "Reset sizes — menu bar, after a seam has been dragged",
            "No peek — menu bar switch",
            "Clean Space — menu bar switch",
            "How many windows — menu bar, 1 to 4",
        ]
        for row in rows {
            let l = NSTextField(labelWithString: row)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            stack.addArrangedSubview(l)
        }
        return stack
    }

    func settingsAppsPage() -> NSView {
        let stack = settingsColumn("Apps")
        stack.addArrangedSubview(settingsNote("Don’t tile these apps. A window you leave out keeps the frame it already has."))
        if excludedBundles.isEmpty {
            stack.addArrangedSubview(settingsNote("TileProto tiles every app."))
        } else {
            for bid in excludedBundles.sorted() {
                let row = hRow(spacing: 8)
                let name = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.localizedName ?? bid
                row.addArrangedSubview(NSTextField(labelWithString: name))
                let b = NSButton(title: "Tile \(name) again", target: self, action: #selector(settingsUnexclude(_:)))
                b.identifier = NSUserInterfaceItemIdentifier(bid)
                b.bezelStyle = .inline
                b.isBordered = false
                row.addArrangedSubview(b)
                stack.addArrangedSubview(row)
            }
        }
        let add = NSButton(title: "Add the front app", target: self, action: #selector(settingsExcludeFront(_:)))
        add.bezelStyle = .rounded
        stack.addArrangedSubview(add)
        return stack
    }

    @objc func settingsUnexclude(_ sender: NSButton) {
        let bid = sender.identifier?.rawValue ?? ""
        guard !bid.isEmpty else { return }
        setAppExcluded(bid, false)
        refreshPanel()
        refreshSettingsIfOpen()
    }

    @objc func settingsExcludeFront(_ sender: NSButton) {
        guard let app = frontRegularApp(), let bid = app.bundleIdentifier else { return }
        setAppExcluded(bid, true)
        refreshPanel()
        refreshSettingsIfOpen()
    }

    func settingsActivityPage() -> NSView {
        let stack = settingsColumn("Activity")
        stack.addArrangedSubview(NSTextField(labelWithString: "Windows placed: \(statPlaced)"))
        stack.addArrangedSubview(NSTextField(labelWithString: "Moves: \(statMoves)"))
        stack.addArrangedSubview(settingsNote("Shortcuts used: No shortcuts yet."))
        stack.addArrangedSubview(settingsNote("These totals stay on this Mac. They are not split by week, and there is no time-saved estimate."))
        stack.addArrangedSubview(settingsNote("Numbers only, kept on this Mac. Never window titles or app names."))
        return stack
    }

    func settingsAboutPage() -> NSView {
        let stack = settingsColumn("About")
        stack.addArrangedSubview(NSTextField(labelWithString: "Runs on this Mac"))
        stack.addArrangedSubview(NSTextField(labelWithString: "Never reads windows"))
        stack.addArrangedSubview(NSTextField(labelWithString: "Sends nothing"))
        stack.addArrangedSubview(settingsNote("TileProto arranges windows without looking inside them."))
        return stack
    }

    @objc func settingsWelcomeTour(_ sender: NSButton) {
        tourStep = 0
        showTourStep()
    }

    func showTourStep() {
        tourWindow?.orderOut(nil)
        let steps: [(String, String)] = [
            ("Look familiar?", "Windows overlap until tiling puts each one in its own pane."),
            ("Prefer a different layout?", "Open the menu bar panel and pick Grid, Columns, Rows, or Side, and how many panes."),
            ("Need another window too?", "When the screen is full, extra windows stack in the tile you’re in. The orange grip and the chips switch which one is in front."),
            ("Want them the other way round?", "Hold Command and drag a window onto another pane to swap. A plain drag snaps back."),
            ("One window feels cramped?", "Drag the seam between two windows. The other side gives way, and the gap stays open."),
            ("Time to concentrate?", "On the hover bar, Focus fills the work area. Exit focus puts that window back exactly."),
            ("Make it yours", "No peek dims the other panes. Clean Space leaves the front window on a plain background."),
        ]
        guard tourStep >= 0, tourStep < steps.count else {
            showToast("You’ve got it.", on: activeScreen())
            return
        }
        let step = steps[tourStep]
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        prepareOverlay(panel, level: .popUpMenu, ignoresMouse: false)
        panel.hasShadow = true
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layer?.cornerRadius = 12
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false
        let progress = NSTextField(labelWithString: "Step \(tourStep + 1) of \(steps.count)")
        progress.font = .systemFont(ofSize: 11)
        progress.textColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: step.0)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        column.addArrangedSubview(progress)
        column.addArrangedSubview(title)
        // 导览面板内容宽 400（左右各留 14），而 settingsNote 默认按 500 换行，
        // 400~500 之间的文案会单行画出面板被裁掉；这里按真实可用宽度重设换行宽。
        let note = settingsNote(step.1)
        note.preferredMaxLayoutWidth = 372
        column.addArrangedSubview(note)
        let buttons = hRow(spacing: 8)
        let skip = NSButton(title: "Skip", target: self, action: #selector(tourSkip(_:)))
        skip.bezelStyle = .inline
        skip.isBordered = false
        let next = NSButton(title: tourStep == 1 ? "Show me" : (tourStep == steps.count - 1 ? "Done" : "Next"), target: self, action: #selector(tourNext(_:)))
        next.bezelStyle = .rounded
        buttons.addArrangedSubview(skip)
        buttons.addArrangedSubview(next)
        column.addArrangedSubview(buttons)
        root.addSubview(column)
        panel.contentView = root
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.widthAnchor.constraint(equalToConstant: 400),
        ])
        let vf = activeScreen().visibleFrame
        panel.setFrame(NSRect(x: vf.midX - 210, y: vf.minY + 48, width: 420, height: 180), display: true)
        panel.orderFrontRegardless()
        tourWindow = panel
    }

    @objc func tourSkip(_ sender: NSButton) {
        tourWindow?.orderOut(nil)
        tourWindow = nil
    }

    @objc func tourNext(_ sender: NSButton) {
        if tourStep == 1 {
            if let button = statusItem.button {
                refreshPanel()
                panelPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
        tourStep += 1
        if tourStep >= 7 {
            tourWindow?.orderOut(nil)
            tourWindow = nil
            showToast("You’ve got it.", on: activeScreen())
            return
        }
        showTourStep()
    }


    // MARK: - 排除列表

    func excludedFilePath() -> String {
        ("~/tileproto/excluded.txt" as NSString).expandingTildeInPath
    }

    func loadExcluded() {
        let text = (try? String(contentsOf: URL(fileURLWithPath: excludedFilePath()), encoding: .utf8)) ?? ""
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
            // 已知维低于一扇正常窗口的最小可能尺寸（宽 160 / 高 120，与运行时学习的瞬态守卫同一口径），
            // 说明整条记录来自一次条状瞬态帧（例如 Chrome 的 1285x50），另一维也多半是同一次误学的。
            // 整条丢掉，不能只清这一维：留下的另一维会让这扇窗永远装不进格子、永远浮着。
            if (w > 0 && w < 160) || (h > 0 && h < 120) { dropped += 1; continue }
            // 超过可视区 85% 的值更可能是「拒绝从全屏缩小」，不是最小尺寸：这一维按未知处理。
            // 不能削成 85%——削出来的值（如 1285.2）随后会被当成真实下限，把窗口永久挡在平铺之外。
            if maxW > 0, w > maxW * 0.85 { w = 0; clamped += 1 }
            if maxH > 0, h > maxH * 0.85 { h = 0; clamped += 1 }
            // 超过半屏 55% 的维，任何多格布局都放不下：那是「拒绝缩小」的痕迹，不是可用下限。
            // 这一维按未知处理；真的缩不下去时 AXMinSize 仍然会挡住，不需要这条记录。
            // 留着会让这一格的申领值虚高，把邻格挤窄，切一次布局乱一次。
            if maxW > 0, w > maxW * 0.55 { w = 0; clamped += 1 }
            if maxH > 0, h > maxH * 0.55 { h = 0; clamped += 1 }
            guard w > 0 || h > 0 else { dropped += 1; continue }
            learnedMinSizes[name] = CGSize(width: w, height: h)
        }
        if dropped > 0 { log("min-size learned dropped invalid entries: \(dropped)") }
        if clamped > 0 { log("min-size learned dropped oversized dims: \(clamped)") }
        // 过滤后的值写回：不清盘的话，被丢掉的荒谬维每次启动都要再过滤一遍，越攒越多。
        if dropped > 0 || clamped > 0 { saveLearnedMinSizes() }
        if !learnedMinSizes.isEmpty { log("min-size learned loaded: \(learnedMinSizes.count) apps") }
    }

    func saveLearnedMinSizes() {
        let raw = learnedMinSizes.mapValues { ["w": Double($0.width), "h": Double($0.height)] }
        UserDefaults.standard.set(raw, forKey: learnedMinDefaultsKey)
    }

    func loadLayoutSettings() {
        let d = UserDefaults.standard
        // 唯一源：只读 tileproto.* 前缀键。裸键 tileLimit 是旧版残留，代码从不读写它，
        // 这里删掉，免得 defaults 里两键并存、数值打架时误导诊断。
        d.removeObject(forKey: "tileLimit")
        d.removeObject(forKey: "tileproto.familyPaneRaised")
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
            let raw = min(24, max(0, CGFloat(d.double(forKey: "tileproto.gap"))))
            st.gap = CGFloat((Int(raw.rounded()) / 2) * 2)
        }
        if d.object(forKey: "tileproto.whenFull") != nil {
            st.whenFull = WhenFull(rawValue: d.integer(forKey: "tileproto.whenFull")) ?? .stack
        }
        // 上限是用户在面板里定的，不随族首启抬升：以前这里首启把 3 抬到族形数并存回，
        // 是“面板设 3、存成 4”的另一条静默改值路径，现已废止（族形只在用时算）。
        globalSettings = st
        tileLimit = st.tileLimit
        if d.object(forKey: "tileproto.noPeek") != nil { noPeek = d.bool(forKey: "tileproto.noPeek") }
        if d.object(forKey: "tileproto.dimStrength") != nil {
            let v = CGFloat(d.double(forKey: "tileproto.dimStrength"))
            if v >= 0.10, v <= 0.90 { dimStrength = v }
        }
        if d.object(forKey: "tileproto.cleanTone") != nil {
            cleanTone = CleanSpaceColor(rawValue: d.integer(forKey: "tileproto.cleanTone")) ?? .graphite
        }
        if d.object(forKey: "tileproto.hoverBar") != nil {
            hoverBarEnabled = d.bool(forKey: "tileproto.hoverBar")
        }
        statPlaced = max(0, d.integer(forKey: "tileproto.statPlaced"))
        statMoves = max(0, d.integer(forKey: "tileproto.statMoves"))
        // Hover focus 默认关：指针划过窗口就抢焦点会打断正在进行的操作。
        // 换 key 让旧的「已打开」状态也回到默认，需要时在设置里手动打开。
        hoverFocus = d.bool(forKey: "tileproto.hoverFocus.v2")
    }

    func saveLayoutSettings() {
        let d = UserDefaults.standard
        d.set(globalSettings.tileLimit, forKey: "tileproto.tileLimit")
        d.set(globalSettings.kind.rawValue, forKey: "tileproto.layoutKind")
        d.set(Double(globalSettings.share), forKey: "tileproto.share")
        d.set(Double(globalSettings.gap), forKey: "tileproto.gap")
        d.set(globalSettings.whenFull.rawValue, forKey: "tileproto.whenFull")
        d.set(noPeek, forKey: "tileproto.noPeek")
        d.set(Double(dimStrength), forKey: "tileproto.dimStrength")
        d.set(cleanTone.rawValue, forKey: "tileproto.cleanTone")
        d.set(hoverBarEnabled, forKey: "tileproto.hoverBar")
        d.set(statPlaced, forKey: "tileproto.statPlaced")
        d.set(statMoves, forKey: "tileproto.statMoves")
        d.set(hoverFocus, forKey: "tileproto.hoverFocus.v2")
    }

    func notePlaced(_ n: Int) {
        guard n > 0 else { return }
        statPlaced += n
        UserDefaults.standard.set(statPlaced, forKey: "tileproto.statPlaced")
    }

    func noteMove() {
        statMoves += 1
        UserDefaults.standard.set(statMoves, forKey: "tileproto.statMoves")
    }

    func setAppExcluded(_ bid: String, _ excluded: Bool) {
        let path = excludedFilePath()
        var set = Set((try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [])
        if excluded { set.insert(bid) } else { set.remove(bid) }
        let text = set.sorted().joined(separator: "\n")
        try? (text.isEmpty ? "" : text + "\n").write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
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
        axMinCache.removeAll()  // 每轮 tick 重新查 AX 最小值，缓存只活一轮
        if panelPopover.isShown { refreshPanel() }
        guard autoTile else {
            hideGrips()
            hideDotHandles()
            hideStackMarkers()
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
            statusItem.button?.image = menuBarIcon(untrusted: !trusted)
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
        // 折叠窗的 App 被前台激活时恢复（Dock 点开）：只取消这一扇窗的最小化，
        // 不折其他窗。能缩进格就缩；塞不进的窗一律折在 Dock 里，所以点开即进入
        // Focus 单独看——退出 Focus 时仍塞不进就重新折回 Dock（见 exitFocus）。
        // 拖动中不恢复；恢复失败则保持折叠态（仍在 Dock 里，不丢窗）。
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != lastFrontmostPid {
            lastFrontmostPid = front.processIdentifier
            if front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               dragState == nil, draggingDividerID == nil, NSEvent.pressedMouseButtons == 0 {
                let (target, _) = resolveCurrentTarget()
                if let t = target, foldedKeys.contains(winKey(t)) {
                    let key = winKey(t)
                    if unminimizeFoldedWindow(element: t.element, key: key) {
                        foldedKeys.remove(key)
                        foldedMinimizedKeys.remove(key)
                        foldedElements.removeValue(forKey: key)
                        foldedScreenByKey.removeValue(forKey: key)
                        userOpenedKeys.insert(key)
                        log("fold restore: \(t.appName) (user opened, focus)")
                        enableFocus(targetKey: key)
                    } else {
                        log("fold restore skipped: cannot unminimize \(t.appName)")
                    }
                }
            }
        }
        // 学到新最小尺寸后重排一次，让位/堆叠随即生效；拖分隔线或 ⌘ 拖时不动手。
        if learnedMinChanged, draggingDividerID == nil, dragState == nil {
            learnedMinChanged = false
            forceTile()
        }
        tickCount += 1
        if tickCount % 5 == 0 { pruneFloated(); prunePinned() }
        // C 批：活动磁贴跟随按屏算（用户点了别的窗口时暗色层/高亮移动，不等重排）；
        // 窗口集合没变时 tick 会在签名处提前返回，所以检查放前面
        // 收尾性能：每 tick 只枚举一次窗口再按屏分流（此前每屏各枚举一次，多屏时 N 倍浪费）
        var overlayChanged = false
        let tickWindows = collectWindows()
        // 用户从 Dock 点开窗：上一轮最小化、这一轮可见，就是用户亲手恢复的。
        // 记一笔，写阶段若判定它塞不进格子就不折、改进入 Focus——点开的窗必须留下来看。
        if dragState == nil, draggingDividerID == nil {
            let nowKeys = Set(tickWindows.map { winKey($0) })
            let missing = lastTickLiveKeys.subtracting(nowKeys)
            if !missing.isEmpty {
                // 用 AX 的最小化状态区分三种"看不见"：最小化（还活着，记下来等它被点开）、
                // 切到别的 Space（AX 根本不列，不记）、关闭（不记，交给剪格逻辑）。
                let mins = minimizedWindowKeys()
                for k in missing {
                    if isMinimizedKey(k, mins: mins) { minimizedSeenKeys.insert(k) } else { minimizedSeenKeys.remove(k) }
                }
            }
            for w in tickWindows {
                let k = winKey(w)
                if minimizedSeenKeys.remove(k) != nil, !userOpenedKeys.contains(k) {
                    userRestoredKeys.insert(k)
                    userOpenedKeys.insert(k)
                    log("dock restore: \(w.appName)")
                }
            }
            lastTickLiveKeys = nowKeys
        }
        // 本轮前台焦点窗（焦点规则用）：帧门/盖邻格守卫读它，不重复枚举。
        frontFocusKeyForPass = frontFocusKey(windows: tickWindows)
        for s in NSScreen.screens {
            let sid = screenID(s)
            let wins = tickWindows.filter { screenID(screenForFrame($0.frame)) == sid }
            let (_, active, _) = computeTiles(windows: wins, st: layoutSettings(for: s), sid: sid)
            let displayActive = permDisplaySlot(active, sid: sid)
            if lastActiveTileByScreen[sid] != displayActive {
                lastActiveTileByScreen[sid] = displayActive
                overlayChanged = true
            }
        }
        if overlayChanged {
            // 活动格子跟随前台窗口移动（不等重排）：高亮与变暗随之移动。
            refreshDimLayers()
        }
        // 缝手柄安全清除：GripView 的 mouseUp 是唯一清除点；万一某次 mouseUp 丢失，
        // draggingDividerID 会永久卡住（手柄不重建、弹回被跳过）。正常拖缝时按钮是按下的，
        // 所以按钮已松开且 ID 还在，只可能是丢失，直接清掉，不影响正常拖动。
        if NSEvent.pressedMouseButtons == 0, draggingDividerID != nil {
            draggingDividerID = nil
            dividerDragCurrent = nil
            dividerDragPending = nil
            dividerDragScheduled = false
            dividerDragSnapshot = nil
            dragQuiet = false
            dividerRevertLogged = false
            refreshGrips()
        }
        // 普通拖动弹回：没按 ⌘ 拖已平铺窗口，松手后若仍在同一屏且位置或尺寸偏离落点，
        // 用入格弹簧回到上次落点，并提示要按住 Command 才能交换。正在飞的窗口不参与。
        // 已经跨到另一块屏的不弹回，交给集合变化后在新屏重排。
        if NSEvent.pressedMouseButtons == 0, draggingDividerID == nil, dragState == nil, pendingDrag == nil {
            var toasted = false
            var tickNeedsSolve = false
            var zOrderCache: [String: Int]? = nil
            // 帧依据自动折叠：min 门（isFoldOversize）只看记录的最小尺寸，数据低估时不触发
            // （如邮箱 1114 宽被 loader 钳制清零、AX 上报又 ≤744），此处补一档帧依据：
            // 安置后实际尺寸仍超格（任一轴超 1.5pt）即计一次，同一窗同一格连续 2 轮 tick
            // 都超格才折。外层已排除鼠标按下/分缝/⌘拖，飞行中弹簧不计，专注/
            // 浮动/已折叠窗不计；折后下一轮摆位即最小化隐藏到 Dock。
            do {
                var seenFrameWatchKeys = Set<String>()
                for (sid, tiles) in lastTilesByScreen {
                    let live = tickWindows.filter { screenID(screenForFrame($0.frame)) == sid }
                    // 名义格帧（等分基线）：帧门只判真超格，让位后的小格不触发误折。
                    let nominalFrames: [CGRect]
                    if let screen = NSScreen.screens.first(where: { screenID($0) == sid }) {
                        nominalFrames = nominalTileFrames(count: tiles.count, screen: screen)
                    } else {
                        nominalFrames = []
                    }
                    for (tileIndex, t) in tiles.enumerated() {
                        for m in t.stack {
                            let mk = winKey(m)
                            seenFrameWatchKeys.insert(mk)
                            // 用户打开窗：留存期内不计数（tick 不重折、不推回）；
                            // 留存只在切族/改上限、窗关闭、用户亲手最小化时清掉。
                            // 已落位冻结窗同样不计数：tick 的名义格帧按 shown 叠数
                            // 等分，与冻结格帧未必一致，误计会把已落位窗折掉。
                            if userOpenedKeys.contains(mk) || isFrozenWindowKey(mk) {
                                frameOversizeWatch.removeValue(forKey: mk)
                                continue
                            }
                            // 固定窗豁免：固定期间不折，且清掉帧门计数（取消固定后重新计 2 轮，不立刻折）。
                            if pinnedWindowKeys.contains(mk) {
                                frameOversizeWatch.removeValue(forKey: mk)
                                continue
                            }
                            // 几何不稳定期不计数（瞬态几何不触发连锁折叠）。
                            if !geometryStable() {
                                frameOversizeWatch.removeValue(forKey: mk)
                                continue
                            }
                            guard mk != focusKey, !foldedKeys.contains(mk),
                                  !floatedKeys.contains(mk), frameMotions[mk] == nil,
                                  let mw = live.first(where: { winKey($0) == mk }) else { continue }
                            let slotFrame = nominalFrames.indices.contains(tileIndex) ? nominalFrames[tileIndex] : t.frame
                            let slotID = "\(sid):\(Int(slotFrame.minX))x\(Int(slotFrame.minY)):\(Int(slotFrame.width))x\(Int(slotFrame.height))"
                            let oversize = mw.frame.width > slotFrame.width + 1.5 || mw.frame.height > slotFrame.height + 1.5
                            if !oversize {
                                frameOversizeWatch.removeValue(forKey: mk)
                                continue
                            }
                            let prev = frameOversizeWatch[mk]
                            let count = (prev?.slot == slotID) ? prev!.count + 1 : 1
                            frameOversizeWatch[mk] = (slotID, count)
                            guard count >= 2 else { continue }
                            frameOversizeWatch.removeValue(forKey: mk)
                            // 先藏再记：最小化失败不进折叠集（fail-safe），旧守卫继续处理。
                            guard hideFoldedWindow(mw) else { continue }
                            markFolded(key: mk, sid: sid)
                            tickNeedsSolve = true
                            log("fold (frame): \(mw.appName) frame \(Int(mw.frame.width))x\(Int(mw.frame.height)) > tile \(Int(slotFrame.width))x\(Int(slotFrame.height))")
                        }
                    }
                }
                frameOversizeWatch = frameOversizeWatch.filter { seenFrameWatchKeys.contains($0.key) }
            }
            for (sid, tiles) in lastTilesByScreen {
                let live = tickWindows.filter { screenID(screenForFrame($0.frame)) == sid }
                for (tileIndex, t) in tiles.enumerated() {
                    let key = winKey(t.top)
                    // 折叠窗不受弹回/盖邻格守卫摆布：折叠窗已最小化隐藏，
                    // 不是“偏离落点的格顶”。
                    guard key != focusKey, !foldedKeys.contains(key) else { continue }
                    guard frameMotions[key] == nil else { continue }
                    guard let placed = lastPlacedFrames[key],
                          let w = live.first(where: { winKey($0) == key }) else { continue }
                    // 只认位置偏离：尺寸偏离是应用最小尺寸顶住了（AX 成功但被系统按最小尺寸钳住），
                    // 不是用户拖的；把它也算进去会导致每秒误判、反复弹回并不断重置提示条 2.5s 计时，提示条就永远不消失。
                    let dx = w.frame.minX - placed.minX, dy = w.frame.minY - placed.minY
                    if dx * dx + dy * dy > 16 {
                        guard screenID(screenForFrame(w.frame)) == sid else { continue }
                        // 卡住抑制：仍偏离且实际帧与上次弹回时四边都在 ±1.5pt 内，不再重复放置、不再弹提示、不再记日志。
                        if let stuck = snapStuck[key],
                           abs(w.frame.minX - stuck.minX) < 1.5, abs(w.frame.minY - stuck.minY) < 1.5,
                           abs(w.frame.maxX - stuck.maxX) < 1.5, abs(w.frame.maxY - stuck.maxY) < 1.5 {
                            continue
                        }
                        snapStuck[key] = w.frame
                        log("snap back: \(w.appName) dev=\(Int((dx * dx + dy * dy).squareRoot().rounded()))pt" + (t.stack.count > 1 ? " stack=\(t.stack.count)" : ""))
                        placeFrame(w.element, placed, key: key, animated: true)
                        // 整叠弹回：同叠成员只回位置、不改尺寸（最小尺寸顶住的成员保持原尺寸，只纠位置）。
                        // 跳过飞行中与专注窗；卡住抑制仍只按格顶键（跟随者拒动时下次重算修复）。
                        if t.stack.count > 1 {
                            let mh = mainHeight()
                            for m in t.stack {
                                let mk = winKey(m)
                                guard mk != key, mk != focusKey, !foldedKeys.contains(mk),
                                      frameMotions[mk] == nil else { continue }
                                setPosition(m.element, CGPoint(x: t.frame.minX, y: mh - t.frame.maxY))
                            }
                        }
                        let toastBlocked = suppressSnapToastUntil.map { Date() < $0 } ?? false
                        // 跨 tick 冷却：同一扇窗两次提示至少间隔 10 秒；冷却期内只弹回不弹提示，
                        // 且不调用 showToast（调用即取消上一次的 2.5s 消失计时，提示条永不消失）。
                        let cooled = snapToastAt[key].map { Date().timeIntervalSince($0) < 10 } ?? false
                        if !toasted, !toastBlocked, !cooled {
                            let screen = NSScreen.screens.first(where: { screenID($0) == sid })
                            showToast("A plain drag never rearranges.", detail: "Hold Command to swap.", on: screen)
                            toasted = true
                            snapToastAt[key] = Date()
                        }
                        continue
                    }
                    // 位置已回落：清除卡住记录，下一轮偏离可正常弹回。
                    snapStuck.removeValue(forKey: key)
                    // 探出自己的格子并盖进另一格：不再把窗口按回它装不下的矩形。
                    // 那一次 AX 会被最小尺寸顶住，下一拍还是盖着，于是反复 size mismatch。
                    // 格子和份额留下，只把这扇窗记成员-only（求解不再选它当顶）。飞行中的弹簧不判。
                    if t.stack.count > 1 {
                        for m in t.stack {
                            let mk = winKey(m)
                            guard mk != key, mk != focusKey,
                                  !floatedKeys.contains(mk), !foldedKeys.contains(mk),
                                  frameMotions[mk] == nil,
                                  let mw = live.first(where: { winKey($0) == mk }) else { continue }
                            // 已落位冻结窗：tick 不动它（顶归属由冻结布局定）。
                            // 用户打开窗与固定窗不再豁免：盖住邻格同样推回/折叠
                            // （窗口之间不得重叠）。
                            if isFrozenWindowKey(mk) { continue }
                            guard coversAnyOtherPane(mw.frame, cellIndex: tileIndex, tiles: tiles) else {
                                overflowSnapStuck.removeValue(forKey: mk)
                                coverLoggedFrame.removeValue(forKey: mk)
                                continue
                            }
                            // z 序感知 + 去抖：已被邻格顶盖住（不可见）不算违规；
                            // 已处理且帧未变时跳过，不再每秒重复顶回与记日志。
                            // 归一化后成员本应在顶之下，此处只剩真正的可见盖住。
                            if zOrderCache == nil { zOrderCache = zOrderPositions() }
                            let zOrder = zOrderCache ?? [:]
                            if !coversNeighborVisibly(mw, cellIndex: tileIndex, tiles: tiles, zOrder: zOrder) {
                                overflowSnapStuck.removeValue(forKey: mk)
                                coverLoggedFrame.removeValue(forKey: mk)
                                continue
                            }
                            if let logged = coverLoggedFrame[mk],
                               abs(mw.frame.minX - logged.minX) < 1.5, abs(mw.frame.minY - logged.minY) < 1.5,
                               abs(mw.frame.maxX - logged.maxX) < 1.5, abs(mw.frame.maxY - logged.maxY) < 1.5 {
                                continue
                            }
                            hardenPaneFrame(mw.element, t.frame)
                            lastPlacedFrames[mk] = t.frame
                            if let actual = getFrame(mw.element, screenHeight: mainHeight()), !frameIsInsidePane(actual, pane: t.frame) {
                                noteClampRefused(mw.appName, actual, t.frame, key: mk)
                                // 最后一道防线：按回原位仍盖着（最小尺寸顶住）→ 记成员-only，
                                // 求解不再选它当顶，不再推回原位反复顶、不踢出格子。Focus 期间不动。
                                // 只在状态转变时记日志：已记录且帧未变时不再重复。
                                if focusKey == nil {
                                    if !oversizeStacked.contains(mk) {
                                        oversizeStacked.insert(mk)
                                        tickNeedsSolve = true
                                    }
                                    // 已触发 member-only 标记视同安定超格：按回原位仍盖着即尺寸顶住，
                                    // 立即折叠到 Dock（不另等帧门 2 轮）；旧标记保留作 fallback。
                                    // 先藏再记：最小化失败不进折叠集（fail-safe），旧守卫继续处理。
                                    if !foldedKeys.contains(mk), geometryStable(), hideFoldedWindow(mw) {
                                        markFolded(key: mk, sid: sid)
                                        log("fold (cover): \(mw.appName) still covers neighbor pane")
                                    }
                                    if coverLoggedFrame[mk] == nil {
                                        log("tick member marked member-only: \(mw.appName) still covers neighbor pane")
                                    }
                                    coverLoggedFrame[mk] = mw.frame
                                }
                            } else {
                                coverLoggedFrame.removeValue(forKey: mk)
                            }
                        }
                    }
                    guard frameMotions[key] == nil else { continue }
                    // 顶层精确一致：实际帧与格子差 >1.5pt 且卡住 → 记固定尺寸嫌疑（若符合）、
                    // 触发一次重算让求解处理（换顶/并格/成员-only），不再进独占（Focus 期间不动）。
                    // 精确一致时清掉稳定帧观察与重算标记；被盖住的成员不管（视觉上不可见，抬升时再验）。
                    if focusKey == nil {
                        if frameMatchesSlot(w.frame, pane: t.frame) {
                            exactWatch.removeValue(forKey: key)
                            solveForcedStuckKeys.remove(key)
                            stuckLoggedFrame.removeValue(forKey: key)
                        } else if exactnessStuck(key: key, actual: w.frame, slot: t.frame, need: effectiveMin(for: w)) {
                            if let logged = stuckLoggedFrame[key], framesClose(logged, w.frame) {
                                // 同一帧已记过：窗口物理尺寸顶住格子，不再每秒重记。
                            } else {
                                stuckLoggedFrame[key] = w.frame
                                log("tick top stuck: \(w.appName) cannot match its tile, left for solve")
                            }
                            if noteFixedSizeIfSuspected(w, actual: w.frame, slot: t.frame) { tickNeedsSolve = true }
                            if !solveForcedStuckKeys.contains(key) {
                                solveForcedStuckKeys.insert(key)
                                tickNeedsSolve = true
                            }
                            continue
                        }
                    }
                    guard coversAnyOtherPane(w.frame, cellIndex: tileIndex, tiles: tiles) else {
                        overflowSnapStuck.removeValue(forKey: key)
                        coverLoggedFrame.removeValue(forKey: key)
                        continue
                    }
                    // z 序感知 + 去抖（同成员守卫）：已被邻格顶盖住时不算违规；
                    // 已处理且帧未变时跳过，不再每秒重复顶回与记日志。
                    if zOrderCache == nil { zOrderCache = zOrderPositions() }
                    let zOrder = zOrderCache ?? [:]
                    if !coversNeighborVisibly(w, cellIndex: tileIndex, tiles: tiles, zOrder: zOrder) {
                        overflowSnapStuck.removeValue(forKey: key)
                        coverLoggedFrame.removeValue(forKey: key)
                        continue
                    }
                    if let logged = coverLoggedFrame[key],
                       abs(w.frame.minX - logged.minX) < 1.5, abs(w.frame.minY - logged.minY) < 1.5,
                       abs(w.frame.maxX - logged.maxX) < 1.5, abs(w.frame.maxY - logged.maxY) < 1.5 {
                        continue
                    }
                    // 窗口之间不得重叠：用户打开窗 / 固定窗盖邻格一视同仁，
                    // 同样推回自己的格子；推不回去就折进 Dock（见下）。
                    hardenPaneFrame(w.element, t.frame)
                    lastPlacedFrames[key] = t.frame
                    if let actual = getFrame(w.element, screenHeight: mainHeight()), !frameIsInsidePane(actual, pane: t.frame) {
                        noteClampRefused(w.appName, actual, t.frame, key: key)
                        // 最后一道防线：按回原位仍盖着（最小尺寸顶住）→ 记成员-only，
                        // 求解不再选它当顶，不再推回原位反复顶、不踢出格子。Focus 期间不动。
                        // 只在状态转变时记日志：已记录且帧未变时不再重复。
                        if focusKey == nil {
                            if !oversizeStacked.contains(key) {
                                oversizeStacked.insert(key)
                                tickNeedsSolve = true
                            }
                            // 同成员守卫：已触发 member-only 标记视同安定超格，立即折叠到 Dock。
                            // 先藏再记：最小化失败不进折叠集（fail-safe），旧守卫继续处理。
                            if !foldedKeys.contains(key), geometryStable(), hideFoldedWindow(w) {
                                markFolded(key: key, sid: sid)
                                userOpenedKeys.remove(key)
                                log("fold (cover): \(w.appName) still covers neighbor pane")
                            }
                            if coverLoggedFrame[key] == nil {
                                log("tick top marked member-only: \(w.appName) still covers neighbor pane")
                            }
                            coverLoggedFrame[key] = w.frame
                        }
                    } else {
                        coverLoggedFrame.removeValue(forKey: key)
                    }
                }
            }
            // 新标记/新卡住才异步重算（求解循环接手）；已处理过的卡住不再触发，避免 1Hz 重排循环。
            if tickNeedsSolve {
                DispatchQueue.main.async { [weak self] in self?.forceTile() }
            }
        }
        // ⌘ 拖已经把窗口抬离格子。这里若重排，会把抬起的窗口拽回原格，
        // 松手再弹一次，看起来像闪一下或有一扇窗消失。手势自己负责落点。
        if dragState != nil {
            return
        }
        // 拖缝期间不重排：重排会重算分组，把相邻格的成员集合改掉，
        // 正在进行的这一次拖动就被判成「stack changed」取消掉（竖缝尤其容易踩到）。
        if draggingDividerID != nil {
            pendingSignature = ""
            pendingTicks = 0
            return
        }
        // 几何不稳定期推迟的折叠：稳定后签名未变、tick 门也不会开，
        // 这里单独补一次 forceTile；deferredFoldDue 内已复核仍超格才触发，
        // 补完即走当轮求解的正常折叠路径，不循环。
        if deferredFoldDue(windows: tickWindows) {
            forceTile()
            return
        }
        // 关窗补剪：关窗那一瞬窗口号可能还挂在窗口服务器上（optionAll 有延迟），
        // 当轮剪格剪不掉；而 tick 签名（每 pid 窗口数）此后不再变化，剪格就再没
        // 机会，格子会留着空洞。这里每轮复核一次冻结归属：只有窗口号真从窗口
        // 服务器消失才补一次重排，最小化 / 切到别的 Space 的窗都还活着，一律不动。
        if dragState == nil, draggingDividerID == nil,
           frozenLayoutHasDeadWindows(windows: tickWindows) {
            log("close prune retile triggered")
            forceTile()
            return
        }
        let sig = screenSignature(windows: tickWindows)
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
            // 集合变化立即重算：一shot 方案一次算好、一次写完，写后基线即应用后状态。
            runOneShot(source: "tick")
            // 新窗口刚创建时可能还不接受位置设置，0.5 秒后只补写（不重算）：
            // 仍偏离上一轮方案目标帧的窗各写一次，格数/格子/顶不重新定。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                let all = self.collectWindows()
                if self.screenSignature(windows: all) == self.lastSignature {
                    self.reapplyOneShotPlan()
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
            // 防抖后重算：同样走一shot，写后基线即应用后状态。
            runOneShot(source: "tick")
            // 0.5 秒后只补写不重算（见上）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                let all = self.collectWindows()
                if self.screenSignature(windows: all) == self.lastSignature {
                    self.reapplyOneShotPlan()
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
        // 平时重算统一走一shot：一次算好完整方案 → 一次写完即停。
        // 面板、悬停条、拖动落点、折叠恢复、屏幕/拒写定时器、demote 异步补跑等
        // 全部经此入口，不再走逐窗写帧 + 落定复核 + 异步补跑的老路径。
        runOneShot(source: "forceTile")
    }

    // 签名只含每个 App 的窗口数：标题变化不触发重排，打开/关闭/最小化才触发
    func signature(_ windows: [WinInfo]) -> String {
        var counts: [pid_t: Int] = [:]
        for w in windows { counts[w.pid, default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "|")
    }

    // 窗口键签名：每扇窗一个键（含窗口号），关一扇又开一扇也算新的窗口集合。
    func keySignature(_ windows: [WinInfo]) -> String {
        windows.map { winKey($0) }.sorted().joined(separator: ",")
    }

    // C 批全屏签名：每屏前缀屏 ID，窗口跨屏、开关屏都触发重排。
    // 签名只含每屏各 pid 的窗口数（不含帧），故同一批已采集窗口算出的签名与重采一致；
    // tick / forceTile / 延迟重试可直接复用已采集的窗口，省掉每轮重复的 CG+AX 全量枚举。
    func screenSignature(windows: [WinInfo]) -> String {
        let grouped = Dictionary(grouping: windows, by: { screenID(screenForFrame($0.frame)) })
        return NSScreen.screens.map { s in "\(screenID(s)):\(signature(grouped[screenID(s)] ?? []))" }.joined(separator: ";")
    }

    func fullSignature() -> String {
        screenSignature(windows: collectWindows())
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

    /// 指针下最上层普通窗口（layer 0）的 pid。CG 坐标（左上原点，y 向下）。
    /// 用来确认「指针真的压在这扇窗上」：被设置窗、面板、别家浮窗盖住时不许抢焦点。
    func topmostWindowPid(at cgPoint: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha <= 0.01 { continue }
            guard let pidNum = w[kCGWindowOwnerPID as String] as? NSNumber,
                  let bd = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            let r = CGRect(x: (bd["X"] as? NSNumber)?.doubleValue ?? 0,
                           y: (bd["Y"] as? NSNumber)?.doubleValue ?? 0,
                           width: (bd["Width"] as? NSNumber)?.doubleValue ?? 0,
                           height: (bd["Height"] as? NSNumber)?.doubleValue ?? 0)
            if r.contains(cgPoint) { return pidNum.int32Value }
        }
        return nil
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
        // 窗口号始终用 CG 列表补；跨 Space 收集时不拿它做在屏过滤。
        // 少了这一步，别的 Space 上的窗口拿不到窗口号，键会退回 pid|标题，
        // 和浮动表里 pid#窗口号 的键对不上，pruneFloated 会把浮窗整批当成已关闭。
        let snaps = cgWindowSnaps()
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
            // 有的应用（微信就遇到过）偶尔对 AX 返回空窗口列表，窗却在屏上：既排不进格、
            // 也看不出为什么。每种应用每次启动只记一次，方便对照是应用没给窗口还是被规则筛掉。
            if wins.isEmpty {
                if onScreen.contains(where: { $0.pid == app.processIdentifier
                    && $0.bounds.width >= 160 && $0.bounds.height >= 120 }),
                   loggedAXEmptyApps.insert(app.processIdentifier).inserted {
                    log("collect: \(app.localizedName ?? "?") on screen but AX window list is empty")
                }
                continue
            }
            for w in wins {
                if boolAttr(w, "AXFullScreen" as CFString) { continue }
                // 对话框、浮动窗默认不排（保存框、画中画、小面板之类）
                if let sub = stringAttr(w, kAXSubroleAttribute as CFString),
                   ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow"].contains(sub) { continue }
                let title = stringAttr(w, kAXTitleAttribute as CFString) ?? ""
                let frame = getFrame(w, screenHeight: mh) ?? .zero
                let wid = resolveWindowID(w, pid: app.processIdentifier, frame: frame, screenHeight: mh, snaps: snaps, used: &usedIDs)
                let base = baseWindowKey(pid: app.processIdentifier, title: title, windowID: wid)
                // 最小化窗默认不排；但折叠窗的隐藏正是最小化：已折叠的最小化窗必须留在采集里，
                // 否则叠成员身份、存活裁剪、展开恢复全对不上。窗口号走 AX SPI，不依赖 CG 在屏出现，
                // 故最小化前后键稳定（pid#窗口号）。
                let minimized = boolAttr(w, kAXMinimizedAttribute as CFString)
                // 折叠窗已最小化，不在 CG 在屏列表里：按折叠键放行在屏过滤，
                // 否则下一轮就被当成别的 Space 的窗丢掉（tieBreak 键按前缀一并放行）。
                let folded = foldedKeys.contains(base) || foldedKeys.contains(where: { $0.hasPrefix(base + "#") })
                if minimized, !folded { continue }
                // 弹簧或 ⌘ 抬起进行中，AX 与 CG 会差一帧以上。正在动的窗口直接留下。
                let moving = keyIsInFlight(base)
                // 只剩标题栏的残影窗（Chrome 之类会留 1512x41 / 1512x81 这种条状窗口）不参与分格：
                // 它们缩不成格子，AX 写尺寸会一直失败，却会先占掉格子，把真正的窗口挤到平铺之外。
                // 阈值与学习时的瞬态守卫同一口径；正在弹簧里的小窗口例外，免得中途掉出布局。
                // 折叠的最小化窗 AX 帧不可靠（可能为零帧），不受残影过滤约束。
                if !moving, !folded, frame.width < 160 || frame.height < 120 { continue }
                // C 批 Space 过滤：只保留能在当前 Space 在屏列表里按 pid+bounds 对上的窗口；
                // AX frame（Cocoa 系）转回 y 向下系再比对：axY = 主屏高 - cocoaMaxY
                // （自动藏窗路径已删：不再有“亲手藏起的平铺窗”需要放行；别的 Space 的窗 AX 本来就不列，不会漏进来。）
                if onlyCurrentSpace, !onScreen.isEmpty, !moving, !folded {
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

    // 所有 Space 的窗口号与进程号。AX 只列当前 Space 的窗口，切换 Space 之后
    // 别的 Space 上的窗口在 AX 里等于消失；判活只能靠 CG 的 optionAll。
    func allSpaceWindowKeys() -> (keys: Set<String>, pids: Set<pid_t>) {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return ([], [])
        }
        var keys: Set<String> = []
        var pids: Set<pid_t> = []
        for w in list {
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let number = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value, number != 0 else { continue }
            pids.insert(pid)
            keys.insert("\(pid)#\(number)")
        }
        return (keys, pids)
    }

    // 冻结布局的归属里有没有窗口号真从窗口服务器消失的窗（关闭）。
    // 最小化与别的 Space 上的窗会被 CG 的 optionAll 列出来，算活着，不剪。
    func frozenLayoutHasDeadWindows(windows: [WinInfo]) -> Bool {
        let live = Set(windows.map { winKey($0) })
        var missing: Set<String> = []
        for f in frozenLayoutByScreen.values {
            missing.formUnion(Set(f.assignment.flatMap { $0 }).subtracting(live))
        }
        guard !missing.isEmpty else { return false }
        let wide = allSpaceWindowKeys()
        return missing.contains { !windowKeyStillAlive($0, wide: wide) }
    }

    // 键对应的窗口在窗口服务器里是否还活着（最小化 / 别的 Space 都算活着）。
    // 键形如 pid#窗口号[#tieBreak]；拿不到窗口号的 pid|标题 键退化为"该进程还有窗口"。
    func windowKeyStillAlive(_ key: String, wide: (keys: Set<String>, pids: Set<pid_t>)) -> Bool {
        if wide.keys.contains(key) { return true }
        if let r = key.range(of: "#", options: .backwards), r.lowerBound > key.startIndex {
            let base = String(key[key.startIndex..<r.lowerBound])
            if wide.keys.contains(base) { return true }
        }
        guard let bar = key.firstIndex(of: "|"), let pid = pid_t(key[key.startIndex..<bar]) else { return false }
        return wide.pids.contains(pid)
    }

    // 当前 Space 各常规应用里处于最小化的窗口键（pid#窗口号）与所属进程。
    // 只用来判断"消失的窗是被最小化还是关了/在别的 Space"，不参与平铺。
    func minimizedWindowKeys() -> (keys: Set<String>, pids: Set<pid_t>) {
        var keys: Set<String> = []
        var pids: Set<pid_t> = []
        guard let fn = axWindowNumberFn else { return (keys, pids) }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &v) == .success,
                  let wins = v as? [AXUIElement] else { continue }
            for w in wins where boolAttr(w, kAXMinimizedAttribute as CFString) {
                var num: CGWindowID = 0
                if fn(w, &num) == 0, num != 0 {
                    keys.insert("\(app.processIdentifier)#\(num)")
                    pids.insert(app.processIdentifier)
                }
            }
        }
        return (keys, pids)
    }

    func isMinimizedKey(_ key: String, mins: (keys: Set<String>, pids: Set<pid_t>)) -> Bool {
        if mins.keys.contains(key) { return true }
        let parts = key.split(separator: "#", omittingEmptySubsequences: false)
        if parts.count >= 3, mins.keys.contains(parts.dropLast().joined(separator: "#")) { return true }
        guard let bar = key.firstIndex(of: "|"), let pid = pid_t(key[key.startIndex..<bar]) else { return false }
        return mins.pids.contains(pid)
    }

    // 定期清理已关闭的浮动窗口，避免之后同 pid+标题的新窗口被误当浮动；
    // C 批：用不过滤的集合，否则其他 Space 上的浮动窗口会被误判为已关闭
    func pruneFloated() {
        guard !floatedKeys.isEmpty, AXIsProcessTrusted() else { return }
        let all = collectWindows(includeFloated: true, onlyCurrentSpace: false)
        let wide = allSpaceWindowKeys()
        var alive = Set(all.map { winKey($0) })
        alive.formUnion(wide.keys)
        let alivePids = wide.pids
        // pid|标题 形式的键（拿不到窗口号时）：该进程还有窗口就留着，不按标题判死。
        func isAlive(_ key: String) -> Bool {
            if alive.contains(key) { return true }
            guard let bar = key.firstIndex(of: "|"), let pid = pid_t(key[key.startIndex..<bar]) else { return false }
            return alivePids.contains(pid)
        }
        let before = floatedKeys.count
        floatedKeys = floatedKeys.filter(isAlive)
        paneRefusals = paneRefusals.filter { isAlive($0.key) }
        if floatedKeys.count != before {
            log("floated pruned: \(before) -> \(floatedKeys.count)")
        }
    }

    /// 固定键裁剪（仿 pruneFloated 的宽口径）：已关窗口的固定键清掉，不留死键。
    func prunePinned() {
        guard !pinnedWindowKeys.isEmpty, AXIsProcessTrusted() else { return }
        let all = collectWindows(includeFloated: true, onlyCurrentSpace: false)
        let wide = allSpaceWindowKeys()
        var alive = Set(all.map { winKey($0) })
        alive.formUnion(wide.keys)
        let alivePids = wide.pids
        func isAlive(_ key: String) -> Bool {
            if alive.contains(key) { return true }
            guard let bar = key.firstIndex(of: "|"), let pid = pid_t(key[key.startIndex..<bar]) else { return false }
            return alivePids.contains(pid)
        }
        let before = pinnedWindowKeys.count
        pinnedWindowKeys = pinnedWindowKeys.filter(isAlive)
        if pinnedWindowKeys.count != before {
            log("pinned pruned: \(before) -> \(pinnedWindowKeys.count)")
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

    // 当前布局族、份额和有效间距。一格也留四边间距；间距为 0 且没有高亮时才铺满可视区。
    // 高屏强制 Rows。没有自定义缝、默认份额又装不下声明尺寸时，二分收敛主窗份额。
    func tileFrames(count t: Int, vf: CGRect, claims: [CGSize] = []) -> [CGRect] {
        let kind = resolvedLayoutKind(globalSettings.kind, vf: vf)
        let gap = gapForLayout()
        var share = globalSettings.share
        if splitOverrides.isEmpty, claims.count == t, t > 1 {
            share = convergedMainShare(start: share, count: t, vf: vf, kind: kind, gap: gap, claims: claims)
        }
        return layoutFrames(count: t, vf: vf, kind: kind, share: share, gap: gap)
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

    // 骨架按布局族生成。声明尺寸只用来收敛主窗份额；装不进的窗口交给让位和并堆。
    func biasedFrames(count: Int, vf: CGRect, claims: [CGSize]) -> [CGRect] {
        tileFrames(count: count, vf: vf, claims: claims)
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
        let key = winKey(w)
        let ax: CGSize
        if let cached = axMinCache[key] {
            ax = cached
        } else {
            ax = axMinSize(w.element)
            axMinCache[key] = ax
        }
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
        // 整叠都申领空间：让位算法才有机会把这一格撑到成员最小尺寸，
        // 否则大窗口永远塞不进来、只能被落点复核踢去浮动。
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

    // 把窗口分到各磁贴：前 t 个窗口每磁贴一个，其余全部叠进活动格（demo 的满格策略）。
    // 活动磁贴只决定多出来的窗口堆进哪一格，格子数和几何都不变。
    // 窗口顺序（⌘ 交换会改这张表）：先按 windowOrder 排，再把 Primary 移到首位；
    // 新窗口追加到末尾（未满时自成一格，满时压进活动格的最上面），消失的窗口剔除。
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

    func computeTiles(windows: [WinInfo], st: ScreenSettings, sid: CGDirectDisplayID) -> (stacks: [[WinInfo]], active: Int, overflow: [WinInfo]) {
        let windows = orderedWindows(windows)
        normalizeStackedOnto(liveKeys: Set(windows.map { winKey($0) }))
        // 装不进任何格子的窗口不参与「一格一窗」的分配：它们固定作为堆叠成员挂回原格，
        // 否则每轮都会被重新分到独立格子、再被验算移走，格子数在 3/4 之间来回跳。
        let roots = windows.filter { stackedOnto[winKey($0)] == nil && !oversizeStacked.contains(winKey($0)) }
        let rootPool = roots.isEmpty ? windows : roots
        let t = Swift.min(Swift.min(st.tileLimit, 4), rootPool.count)
        guard t > 0 else { return ([], 0, []) }
        var stacks: [[WinInfo]] = (0..<t).map { [rootPool[$0]] }
        // 活动磁贴：先记住上一轮。焦点如果落在一块已经占着格子的根窗口上，改跟它。
        // 刚打开、排在根窗口末尾的新窗口下标 ≥ t，不会把活动磁贴拽走。
        // 已经手动堆进别人磁贴的窗口也不是根，不能把活动磁贴拽走。
        var active = 0
        // lastActiveTileByScreen 存的是显示格下标；计算侧用前先翻译回计算格并钳到范围内。
        if let remembered = lastActiveTileByScreen[sid], remembered < t {
            active = min(permSrcSlot(remembered, sid: sid), t - 1)
        }
        if let fi = focusedIndex(windows: windows), windows.indices.contains(fi) {
            let fk = winKey(windows[fi])
            if stackedOnto[fk] == nil, let ti = stacks.firstIndex(where: { $0.contains { winKey($0) == fk } }) {
                active = ti
            }
        }
        // ⌥⌘ 拖进堆叠后 pin 住目标磁贴，直到用户切到别的 App 才放开。
        if let p = pinnedActiveTile, pinnedScreenID == sid { active = Swift.min(p, t - 1) }
        var overflow: [WinInfo] = []
        if rootPool.count > t {
            if st.whenFull == .float {
                overflow = Array(rootPool[t...])
            } else {
                // demo：多出来的窗口叠进活动格，格子数与几何都不变。
                let targets = overflowStackTargets(windowCount: rootPool.count, tileCount: t, active: active)
                for (ordinal, w) in rootPool.enumerated() where ordinal >= t {
                    stacks[targets[ordinal]].append(w)
                }
            }
        }
        if !roots.isEmpty {
            // 手动堆叠的 host 不在本屏格子里时，整组并进活动格，不另开分法。
            var orphans: [String: [WinInfo]] = [:]
            for w in windows {
                guard let host = stackedOnto[winKey(w)] else { continue }
                if let ti = stacks.firstIndex(where: { $0.contains { winKey($0) == host } }) {
                    stacks[ti].append(w)
                } else if st.whenFull == .float {
                    overflow.append(w)
                } else {
                    orphans[host, default: []].append(w)
                }
            }
            for host in orphans.keys.sorted() {
                for w in orphans[host] ?? [] {
                    stacks[active].append(w)
                }
            }
        }
        return (stacks, active, overflow)
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
    // MARK: - 换布局一shot（v0.1.1 底本上新增，2026-10-29）
    // 换族（applyLayoutKind）与改上限（applyLimit）专用，两阶段，缺一不可：
    // 1. 算阶段：tileAll(oneShot: true) → tile() 的求解段（computeTiles → planTileFit →
    //    solveTopFit → 自动折叠判定）算出完整方案，全程不写 AX。快照只采一次
    //    （collectWindows + 一次前台焦点判定 + 每轮 AX 最小尺寸缓存）；算阶段内
    //    不重读实时帧、不重解、不触发重排。装不下的判定是算阶段的一部分：
    //    用窗口已知最小尺寸（AX 最小值 / 已学最小尺寸，v0.1.1 已有的 effectiveMin）
    //    对照分到的名义格子（nominalTileFrames，等分基线；与 v0.1.1 自动折叠门同口径，
    //    让位后的小格不触发误折），格子小于最小尺寸的窗口在算方案时就定为
    //    折叠（非焦点）或保留盖邻格（焦点 / Pin），不等写帧时才发现写不进去再返工。
    // 2. 写阶段：applyOneShotPlan 按稳定顺序把方案各写一次（帧用
    //    hardenPaneFrame 直接写，不读回校验）、折叠决定各执行一次（沿用 v0.1.1
    //    已有的最小化验证），写完即停；本轮本身不触发第二轮。
    // 平时重算已统一走同一套机器：forceTile 与 tick 的重算入口全部经 runOneShot，
    // 与切换布局共用算方案 + 写方案函数，不另起第二套机器；手势自有帧
    // （拖动、⌘交换、悬停条拖动中的 placeFrame）不在重算入口内，保持原样。
    struct OneShotPlacement { let win: WinInfo; let frame: CGRect }
    struct OneShotFold { let win: WinInfo; let sid: CGDirectDisplayID; let need: CGSize; let slot: CGRect }
    var oneShotActive = false
    var oneShotApplying = false  // 写阶段内到达的重算请求直接丢弃，不排队、不异步补跑
    var oneShotLastPlacements: [OneShotPlacement] = []  // 上一轮方案的帧，供 0.5 秒补写只重写不重算
    var oneShotPlacements: [OneShotPlacement] = []
    var oneShotFolds: [OneShotFold] = []
    var oneShotRaiseTops: [WinInfo] = []
    var oneShotFocusCaptions: [NSScreen] = []
    // 写阶段的一次读回复核对象就是 oneShotPlacements 全体（浮窗、已折叠窗除外）。
    // 栈内非顶成员同样占着格子外的面积，藏在邻格窗口后面不算合规——窗口之间不得重叠。
    // 本轮冻结窗键：供写阶段过滤 0.5 秒补写（补写不得把已落位窗写回冻结帧，
    // 冻结窗的帧由冻结布局定、补写只保护本轮新落点的窗）。
    var oneShotFrozenKeys: Set<String> = []
    // 几何不稳定期推迟的折叠键：求解时超格但因几何不稳定没折的窗，
    // 稳定后由 tick 补折，不静默丢失（基线更新不会吞掉它）。
    var deferredFoldKeys: Set<String> = []
    // 拒缩折叠失败记忆：键 -> 失败时的全屏签名。同一签名下不再重尝试折叠，
    // 只在真实变化（切族/改上限/窗口集合变化）时再试，避免每 2 秒重触发整轮。
    var foldFailedKeys: [String: String] = [:]
    // 用户亲手从 Dock 点开的窗（留存态）：能缩进格就缩，缩不进折回 Dock，
    // 点开时自动进入 Focus 单独看；只在切族/改上限、窗关闭、用户亲手最小化时清掉。
    // 屏幕集合变化、焦点切换、其他窗开/关一律不得清掉（旧宽限“签名一变即清”的口子已删）。
    var userOpenedKeys: Set<String> = []
    // 用户亲手从 Dock 恢复（上一轮还最小化、这轮可见）的窗：写阶段若判定它塞不进格子，
    // 不再折回去，改为进入 Focus 单独看（"点开的窗必须留下来看"）。
    var userRestoredKeys: Set<String> = []
    // 上一轮 tick 里处于最小化的窗键：用于识别"用户把它从 Dock 点开了"这一状态跃迁。
    var minimizedSeenKeys: Set<String> = []
    // 上一轮 tick 采到的可见窗键：与这一轮做差，找出"消失"的窗再按 CG 判活，
    // 区分最小化（还活着）与关闭（真没了）。
    var lastTickLiveKeys: Set<String> = []
    // 已落位冻结：上次全量布局（切族/改上限/首次铺格）定死的格子帧与窗口归属，
    // 计算格顺序存（显示侧经置换翻译）。tick、焦点切换、屏幕通知、开窗/关窗
    // 都不得重算已落位窗，只有换布局全量重算；几何失效（冻结帧超出当前可视区）
    // 时自动退回全量重算并重新记录（外接屏插拔/分辨率变化的安全阀）。
    struct FrozenLayout {
        var tileFrames: [CGRect]      // 计算格顺序的格子帧
        var assignment: [[String]]    // 计算格顺序的窗口键（栈顺序）
        var topKeys: [String?]        // 计算格顺序的显示顶键（栈顶下标漂移时的兜底）
    }
    var frozenLayoutByScreen: [CGDirectDisplayID: FrozenLayout] = [:]
    // 冻结布局扩容尝试记录：同一窗口集合签名只允许扩容一次。
    // 求解并格（窗口塞不进）会让冻结格数回落，没有这条记录会每轮重算。
    var expandAttemptedSignatureByScreen: [CGDirectDisplayID: String] = [:]
    // 某键是否在任一屏的冻结归属里（tick 守卫、非一shot 摆位用；格数小，线性查即可）。
    func isFrozenWindowKey(_ key: String) -> Bool {
        for layout in frozenLayoutByScreen.values {
            if layout.assignment.contains(where: { $0.contains(key) }) { return true }
        }
        return false
    }
    // 切换族/上限时从头重算的屏：本轮 tile() 忽略上一布局的求解态（活动格、
    // 超格成员-only 标记、栈顶、格子置换）；手动堆叠与 Primary 是用户态，保留。
    // 只在本轮存活，runOneShot 返回时（即使因写阶段门提前返回）清空。
    var oneShotFreshScreens: Set<CGDirectDisplayID> = []

    /// 满格浮动窗的纯计算落点：与 floatWhenFull 同一套几何（工作区内缩、当前尺寸
    /// 夹取、按步错开），但只用快照帧尺寸，不读 AX、不写 AX。step 为本轮之前
    /// 已浮动窗的数量，与 floatWhenFull 插入顺序一致。
    func oneShotFloatFrame(_ w: WinInfo, on screen: NSScreen, step: Int) -> CGRect {
        let box = insetWorkArea(on: screen)
        let cur = w.frame.size
        let width = min(max(cur.width > 1 ? cur.width : 480, 80), box.width)
        let height = min(max(cur.height > 1 ? cur.height : 320, 60), box.height)
        var frame = CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
        if step > 0 {
            let col = CGFloat(step % 5)
            let row = CGFloat(step / 5)
            frame.origin.x = min(max(frame.minX + col * 30, box.minX), max(box.minX, box.maxX - width))
            frame.origin.y = min(max(frame.minY - row * 30, box.minY), max(box.minY, box.maxY - height))
        }
        return frame
    }

    /// 平时重算与切换布局共用的一shot入口：一次算好完整方案 → 一次写完即停。
    /// 算阶段 tileAll(oneShot: true) 只记方案不写 AX；写阶段 applyOneShotPlan 同步执行。
    /// 写阶段内到达的重算请求直接丢弃（oneShotApplying 门），不排队、不异步补跑；
    /// 只有窗口集合、布局族/上限、Space、显示器确实变化了的新事件，才能触发下一轮。
    /// 写完后把签名基线更新为应用后状态（折叠窗已离开可见集合），下一轮 tick
    /// 见不到差异就不再重算；焦点变化本身不改变签名，故不触发重写帧。
    func runOneShot(source: String) {
        // 从头重算标记只活本轮：写阶段门提前返回、正常返回都清，不残留到下一轮。
        defer { oneShotFreshScreens.removeAll() }
        if oneShotApplying {
            log("oneshot: re-tile dropped during apply, source=\(source)")
            return
        }
        pruneFloated()
        let all = collectWindows()
        // 推迟集与留存集只对仍在世的窗有效；已折叠的窗不再是推迟对象
        // （帧门已把它藏好，推迟集留着只会误触发）。已关闭的窗清掉留存态。
        let allKeys = Set(all.map { winKey($0) })
        deferredFoldKeys.formIntersection(allKeys)
        deferredFoldKeys.subtract(foldedKeys)
        foldFailedKeys = foldFailedKeys.filter { allKeys.contains($0.key) }
        userOpenedKeys.formIntersection(allKeys)
        log("oneshot begin: source=\(source) windows=\(all.count)")
        lastSignature = screenSignature(windows: all)
        pendingSignature = ""
        pendingTicks = 0
        tileAll(windowsByScreen: Dictionary(grouping: all, by: { screenID(screenForFrame($0.frame)) }), oneShot: true)
        log("oneshot plan: placements=\(oneShotPlacements.count) folds=\(oneShotFolds.count)")
        applyOneShotPlan(source: source)
        // 应用后基线：直接用本轮输入快照算签名，不再减去已折叠/新浮动的窗。
        // collectWindows 会把已折叠的最小化窗留在采集里（折叠放行），减掉它们
        // 的基线永远对不上次轮采集，tick 每秒误触发——这是循环的驱动之一。
        // 不减基线时：折叠粘住后次轮采集与基线一致，tick 即停；开窗/关窗等
        // 真实变化仍会改变签名并触发新一轮，不会被基线吞掉。
        lastSignature = screenSignature(windows: all)
        pendingSignature = ""
        pendingTicks = 0
    }

    /// 写阶段：按稳定顺序把算阶段的方案各执行一次即停。
    /// 已在目标帧上的窗口直接跳过不写（v0.1.1 的 frameMatchesSlot，1.5pt 口径，不引入新容差）。
    /// 折叠决定各执行一次（沿用最小化验证）；保留窗不写不折，只记快照帧为已落点。
    func applyOneShotPlan(source: String) {
        oneShotApplying = true
        defer { oneShotApplying = false }
        var written = 0
        var skipped = 0
        for p in oneShotPlacements {
            if frameMatchesSlot(p.win.frame, pane: p.frame) {
                skipped += 1
                continue
            }
            hardenPaneFrame(p.win.element, p.frame)
            lastPlacedFrames[winKey(p.win)] = p.frame
            written += 1
        }
        for f in oneShotFolds {
            let k = winKey(f.win)
            if hideFoldedWindow(f.win) {
                log("fold (oversize): \(f.win.appName) min \(Int(f.need.width))x\(Int(f.need.height)) > slot \(Int(f.slot.width))x\(Int(f.slot.height))")
            } else {
                foldedKeys.remove(k)
                foldedMinimizedKeys.remove(k)
                foldedElements.removeValue(forKey: k)
                foldedScreenByKey.removeValue(forKey: k)
                log("fold minimize failed: \(f.win.appName), unfolded for fallback")
            }
        }
        // AX 拒缩复核（当轮两次读回，不循环、不重解）：直写后 0.2 秒读回仍超格的窗，
        // 再等 0.8 秒二次读回（区分动画没跟上与真拒缩）；仍超格一律折进 Dock。
        // 复核对象是全体落位窗（含栈内非顶成员）：成员藏在邻格窗口后面同样占着
        // 格子外的面积，窗口之间不得重叠。浮窗（用户主动覆盖态）与已折叠窗不复核。
        // 复核折叠同样记入 oneShotFolds（恰好执行一次、应用日志里计数一致），
        // 且不进 0.5 秒补写（补写不得把已折的窗再写回格子帧）。
        let verifyTargets = oneShotPlacements.filter {
            !floatedKeys.contains(winKey($0.win)) && !foldedKeys.contains(winKey($0.win))
        }
        if !verifyTargets.isEmpty {
            // 诊断帧格式：x,y WxH；axMin 读不到（两维都 ≤1）写 unknown，单维未知写 ?。
            func fmtFrame(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }
            func fmtAxMin(_ s: CGSize) -> String {
                if s.width > 1, s.height > 1 { return "\(Int(s.width))x\(Int(s.height))" }
                if s.width > 1 { return "\(Int(s.width))x?" }
                if s.height > 1 { return "?x\(Int(s.height))" }
                return "unknown"
            }
            func overSlot(_ frame: CGRect, _ slot: CGRect) -> Bool {
                frame.width > slot.width + 1.5 || frame.height > slot.height + 1.5
            }
            // 写后读回前先静置一次：AX 写入可能是动画/排队落点，立即读回会
            // 读到旧帧、误判拒缩。只静置一次，不轮询、不重解。
            Thread.sleep(forTimeInterval: 0.2)
            var live = collectWindows()
            let liveSig = screenSignature(windows: live)
            var firstFrames: [String: CGRect] = [:]
            var pending: [OneShotPlacement] = []
            for p in verifyTargets {
                let k = winKey(p.win)
                guard let w0 = live.first(where: { winKey($0) == k }) else { continue }
                firstFrames[k] = w0.frame
                if overSlot(w0.frame, p.frame) { pending.append(p) }
            }
            // 一次读回仍超格：再等 0.8 秒统一二次读回（所有待验窗共用一次等待与采集）。
            if !pending.isEmpty {
                Thread.sleep(forTimeInterval: 0.8)
                live = collectWindows()
            }
            for p in verifyTargets {
                let k = winKey(p.win)
                guard let f0 = firstFrames[k] else { continue }
                guard !foldedKeys.contains(k), let w = live.first(where: { winKey($0) == k }) else { continue }
                let secondReadback = overSlot(f0, p.frame)
                // 已缩进格子：若已学值高于本次实测帧，该已学值就是错的，当场纠正
                // （只忘不学：错维记 0、当未知处理，AX 真下限仍会挡住）。
                if !overSlot(w.frame, p.frame) {
                    // 尺寸进格不等于位置也对：AX 偶尔吞掉同一窗的 position 写入（切布局时
                    // 会把下排的窗留在原位、只改宽高）。这里按格子帧补写一次，让窗口回到自己格子。
                    if !frameMatchesSlot(w.frame, pane: p.frame) {
                        // 只补位置，尺寸保持当前（已通过 overSlot 检查）——固定尺寸窗
                        // （系统设置这类 740x470）不能被整格帧拉宽，否则它自己顶回、白折腾。
                        var target = p.frame
                        target.size = CGSize(width: min(w.frame.width, p.frame.width),
                                             height: min(w.frame.height, p.frame.height))
                        let before = w.frame
                        hardenPaneFrame(w.element, target)
                        lastPlacedFrames[k] = target
                        log("reposition: \(w.appName) \(fmtFrame(before)) -> \(fmtFrame(target))")
                    }
                    if var cur = learnedMinSizes[w.appName] {
                        let old = cur
                        var changed = false
                        if cur.width > 1, cur.width > w.frame.width + 4 { cur.width = 0; changed = true }
                        if cur.height > 1, cur.height > w.frame.height + 4 { cur.height = 0; changed = true }
                        if changed {
                            if cur.width <= 0, cur.height <= 0 { learnedMinSizes.removeValue(forKey: w.appName) } else { learnedMinSizes[w.appName] = cur }
                            saveLearnedMinSizes()
                            log("min-size corrected: \(w.appName) \(Int(old.width))x\(Int(old.height)) -> \(Int(cur.width))x\(Int(cur.height)) (shrank to \(Int(w.frame.width))x\(Int(w.frame.height)))")
                        }
                    }
                    if secondReadback {
                        log("diag: \(w.appName) axMin=\(fmtAxMin(axMinSize(w.element))) write=\(fmtFrame(p.frame)) readback0.2s=\(fmtFrame(f0)) readback1s=\(fmtFrame(w.frame)) result=placed")
                    }
                    // 从 Dock 点开的窗已经塞回格子：留存意图兑现，清掉标记，
                    // 免得日后某轮塞不进时莫名其妙地跳进 Focus。
                    userRestoredKeys.remove(k)
                    continue
                }
                // 到这里一定是二次读回仍超格（一次读回即缩进的已在上面 continue）。
                // 一律折进 Dock：任何窗都不例外，绝不留一扇超格窗压在邻格上。
                // 留存态到此结束，用户再从 Dock 点开时由 fold restore 自动进入 Focus 单独看。
                guard secondReadback else { continue }
                let vsid = screenID(screenForFrame(p.frame))
                // 用户亲手从 Dock 点开的窗、却塞不进格子：不折回去，直接进入 Focus 单独看。
                // 点开的窗必须留下来看；退出 Focus 时仍塞不进再折回 Dock（见 exitFocus）。
                if userRestoredKeys.contains(k) {
                    userRestoredKeys.remove(k)
                    log("dock restore: \(w.appName) does not fit the tile, focus")
                    DispatchQueue.main.async { [weak self] in self?.enableFocus(targetKey: k) }
                    continue
                }
                userOpenedKeys.remove(k)
                // 失败记忆：同一窗口集合下折叠失败过的不再每轮重试，
                // 只在集合变化（签名不同）时再试，避免失败窗每 2 秒重触发整轮。
                if let failSig = foldFailedKeys[k], failSig == liveSig {
                    log("diag: \(w.appName) axMin=\(fmtAxMin(axMinSize(w.element))) write=\(fmtFrame(p.frame)) readback0.2s=\(fmtFrame(f0)) readback1s=\(fmtFrame(w.frame)) result=refused")
                    continue
                }
                if hideFoldedWindow(w) {
                    foldedKeys.insert(k)
                    foldedScreenByKey[k] = vsid
                    foldFailedKeys.removeValue(forKey: k)
                    oneShotFolds.append(OneShotFold(win: w, sid: vsid, need: effectiveMin(for: w), slot: p.frame))
                    log("fold (refused): \(w.appName) still \(Int(w.frame.width))x\(Int(w.frame.height)) > slot \(Int(p.frame.width))x\(Int(p.frame.height))")
                    log("diag: \(w.appName) axMin=\(fmtAxMin(axMinSize(w.element))) write=\(fmtFrame(p.frame)) readback0.2s=\(fmtFrame(f0)) readback1s=\(fmtFrame(w.frame)) result=refused")
                } else {
                    foldFailedKeys[k] = liveSig
                    log("fold refused failed: \(w.appName), left visible for fallback")
                    log("diag: \(w.appName) axMin=\(fmtAxMin(axMinSize(w.element))) write=\(fmtFrame(p.frame)) readback0.2s=\(fmtFrame(f0)) readback1s=\(fmtFrame(w.frame)) result=refused")
                }
            }
        }
        for top in oneShotRaiseTops {
            // 本轮已折叠的顶不得再提：AXRaise 会把刚最小化的窗恢复可见，
            // 折叠当轮即蒸发、次轮原样重算——这是循环的直接恢复者。
            // 已最小化的顶同样不提（防任何路径的折叠被提回）。
            let tk = winKey(top)
            if foldedKeys.contains(tk) { continue }
            if boolAttr(top.element, kAXMinimizedAttribute as CFString) { continue }
            AXUIElementPerformAction(top.element, kAXRaiseAction as CFString)
        }
        for screen in oneShotFocusCaptions {
            showFocusCaption(on: screen, frame: focusFrame(on: screen))
        }
        // 补写不过滤已落位窗：冻结窗的帧由冻结布局定，补写只保护本轮新落点的窗。
        oneShotLastPlacements = oneShotPlacements.filter { !foldedKeys.contains(winKey($0.win)) && !oneShotFrozenKeys.contains(winKey($0.win)) }
        if source == "switch" {
            log("oneshot switch applied: placed=\(written) folded=\(oneShotFolds.count)")
        } else {
            log("oneshot retile applied: placed=\(written) folded=\(oneShotFolds.count) skipped=\(skipped) source=\(source)")
        }
        refreshGrips()
        refreshDotHandles()
        refreshStackMarkers()
        refreshDimLayers()
    }

    /// 0.5 秒补写：不重算、只重写上一轮方案里仍偏离目标帧的窗。
    /// 格数、格子、顶的归属全部沿用上一轮方案一次定死的结果，不并格、不换顶、不重解；
    /// 集合变化时 tick 的签名门会挡住本函数（调用方已判签名一致才进）。
    func reapplyOneShotPlan() {
        guard AXIsProcessTrusted(), !stageManagerPaused else { return }
        let live = collectWindows()
        var written = 0
        for p in oneShotLastPlacements {
            let key = winKey(p.win)
            guard let w = live.first(where: { winKey($0) == key }) else { continue }
            if frameMatchesSlot(w.frame, pane: p.frame) { continue }
            hardenPaneFrame(w.element, p.frame)
            lastPlacedFrames[key] = p.frame
            written += 1
        }
        if written > 0 {
            log("oneshot reapply: wrote=\(written)")
        }
    }

    /// 换布局一shot入口：算阶段（tileAll oneShot）+ 写阶段（一次写完）。
    /// 写阶段只写方案：帧直接写（hardenPaneFrame，不读回、不重解、不因单窗
    /// 失败重算整轮）；折叠执行沿用 v0.1.1 最小化验证；焦点 / Pin 超格窗不写
    /// 不折，只把快照帧记为已落点（tick 不会把它弹回旧格）；最后各栈顶各提一次。
    func applyLayoutSwitchOneShot() {
        guard AXIsProcessTrusted() else {
            log("oneshot switch skipped: not trusted")
            return
        }
        guard !stageManagerPaused else {
            log("oneshot switch skipped: Stage Manager paused")
            return
        }
        oneShotFreshScreens.insert(screenID(activeScreen()))
        // 模式切换 / 上限变化是重算触发：全部用户打开窗的留存期到此为止，
        // 本轮即按尺寸适配规则重算（能缩进格就缩，缩不进按通用规则处理）。
        userOpenedKeys.removeAll()
        // 切族/改上限是真实变化：失败记忆到此为止，本轮可再试折叠。
        foldFailedKeys.removeAll()
        runOneShot(source: "switch")
    }

    func tileAll(windowsByScreen: [CGDirectDisplayID: [WinInfo]]? = nil, oneShot: Bool = false) {
        // C2：Stage Manager 暂停时连 0.5 秒补铺也不执行
        guard !stageManagerPaused else { return }
        // 防重入：重排中又有重排请求时只记 pending，当前这轮结束后补跑一次，
        // 避免嵌套求解互相覆盖几何与折叠状态（2026-10-29 级联防御）。
        if tilingInProgress {
            tileAllPending = true
            return
        }
        tilingInProgress = true
        if oneShot {
            // 一shot算阶段的缓冲：tile() 的求解段只往里记方案，不写 AX；
            // 写阶段由 applyLayoutSwitchOneShot 在 tileAll 返回后统一执行。
            oneShotActive = true
            oneShotPlacements = []
            oneShotFolds = []
            oneShotRaiseTops = []
            oneShotFocusCaptions = []
            oneShotFrozenKeys = []
        }
        defer {
            tilingInProgress = false
            oneShotActive = false
            if tileAllPending {
                tileAllPending = false
                if oneShot {
                    // 切换本身不产生第二轮：算阶段不写 AX，没有任何嵌套重排可挂起；
                    // 万一有挂起请求也直接丢弃并记日志，不排异步 forceTile。
                    log("oneshot: pending re-tile dropped, switch applies once")
                } else {
                    DispatchQueue.main.async { [weak self] in self?.forceTile() }
                }
            }
        }
        axMinCache.removeAll()  // 每次求解重新查 AX 最小值，缓存只活一轮
        // 约束自适应平铺没有逐窗最小化冻结：最小化窗本来就不在采集里（collectWindows 跳过），
        // 不再有“恢复时回不去原格”的冻结问题，重算永远放行。
        let screens = NSScreen.screens
        let liveIDs = Set(screens.map(screenID))
        lastTilesByScreen = lastTilesByScreen.filter { liveIDs.contains($0.key) }
        frozenLayoutByScreen = frozenLayoutByScreen.filter { liveIDs.contains($0.key) }
        expandAttemptedSignatureByScreen = expandAttemptedSignatureByScreen.filter { liveIDs.contains($0.key) }
        lastVFByScreen = lastVFByScreen.filter { liveIDs.contains($0.key) }
        lastScreenFrameByScreen = lastScreenFrameByScreen.filter { liveIDs.contains($0.key) }
        lastActiveTileByScreen = lastActiveTileByScreen.filter { liveIDs.contains($0.key) }
        var byScreen = windowsByScreen
        if byScreen == nil {
            let all = collectWindows()
            byScreen = Dictionary(grouping: all, by: { screenID(screenForFrame($0.frame)) })
        }
        // 折叠窗最小化后 AX 帧不可靠、screenForFrame 可能 fallback 主屏：按折叠时记录的原属屏归位，
        // 否则多屏下收起/展开会把副屏窗错分到主屏（单屏时 fallback 本就是主屏，无影响）。
        // 注意顺序：归位必须在裁剪之前——收起时 foldedKeys 已清、只剩这张表能指认原属屏，
        // 归位后 pruneFolded 再按折叠集裁掉它。
        if !foldedScreenByKey.isEmpty {
            for (key, sid) in foldedScreenByKey {
                guard NSScreen.screens.contains(where: { screenID($0) == sid }) else { continue }
                guard let w = byScreen!.values.flatMap({ $0 }).first(where: { winKey($0) == key }) else { continue }
                if screenID(screenForFrame(w.frame)) == sid { continue }
                for s in byScreen!.keys { byScreen![s]?.removeAll { winKey($0) == key } }
                byScreen![sid, default: []].append(w)
            }
        }
        let allWindows = byScreen!.values.flatMap { $0 }
        // 几何变化戳：任一屏可视区/屏帧与上一轮不同即记时刻，2 秒内折叠门全停
        // （显示切换瞬态几何不触发连锁折叠）；比较在 tile() 覆盖旧值之前做。
        for s in screens {
            let sid = screenID(s)
            if let prevVF = lastVFByScreen[sid], prevVF != s.visibleFrame {
                geometryChangedAt = Date()
                log("screen geometry changed: vf \(prevVF) -> \(s.visibleFrame)")
            }
            if let prevF = lastScreenFrameByScreen[sid], prevF != s.frame {
                geometryChangedAt = Date()
                log("screen geometry changed: frame \(prevF) -> \(s.frame)")
            }
        }
        // 本轮前台焦点窗（焦点规则用）：tile()/demote 各折叠点读它，不重复枚举。
        frontFocusKeyForPass = frontFocusKey(windows: allWindows)
        // 消失窗口：顺序与落点记录按全屏集合统一裁剪；Primary 全屏都不见才清
        windowOrder.removeAll { key in !allWindows.contains(where: { winKey($0) == key }) }
        lastPlacedFrames = lastPlacedFrames.filter { entry in allWindows.contains(where: { winKey($0) == entry.key }) }
        // 固定尺寸判定与落点稳定帧观察随窗口关闭一起裁剪，免得已关窗口的旧键一直占着判定。
        fixedSizeKeys.formIntersection(Set(allWindows.map { winKey($0) }))
        exactWatch = exactWatch.filter { entry in allWindows.contains(where: { winKey($0) == entry.key }) }
        solveForcedStuckKeys.formIntersection(Set(allWindows.map { winKey($0) }))
        stuckLoggedFrame = stuckLoggedFrame.filter { entry in allWindows.contains(where: { winKey($0) == entry.key }) }
        let liveKeys = Set(allWindows.map { winKey($0) })
        pruneFolded(allKeys: liveKeys)
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
        refreshDimLayers()
        // legacy 兜底：活动屏的磁贴/frame，供单屏路径（悬停条等）复用
        let act = activeScreen()
        lastTiles = lastTilesByScreen[screenID(act)] ?? []
        lastVF = act.visibleFrame
        lastScreenFrame = act.frame
        lastActiveTile = lastActiveTileByScreen[screenID(act)] ?? 0
    }

    // 最小尺寸让位：磁贴小于已学尺寸时，从相邻磁贴匀空间（不把邻居压到
    // 其已学最小尺寸或 160×120 底线以下）；匀完仍不够的由调用方并堆或降格。
    // 需求由调用方给：旧路径（framesFor）给整叠最大最小尺寸；求解路径（framesForTops）
    // 只给每格顶的最小尺寸——被盖住的成员不申领几何，格子按顶定。
    // 双向都让：左/上不够向右/下移缝，右/下不够向左/上移缝；两轮收敛多列链。
    // 缝移动时两侧同量进退，当前间距不变。
    func applyGiveWay(frames: [CGRect], needs: [CGSize], sid: CGDirectDisplayID) -> [CGRect] {
        guard !frames.isEmpty, frames.count == needs.count else { return frames }
        var out = frames
        func topMin(_ tile: Int) -> CGSize {
            guard needs.indices.contains(tile) else { return .zero }
            return needs[tile]
        }
        let g = gapForLayout()
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
            frames = applyGiveWay(frames: frames, needs: stacks.map { stackNeed($0) }, sid: sid)
        }
        return frames
    }

    /// 求解用帧：与 framesFor 同一套（份额收敛 + 缝覆盖 + 让位），但需求只取每格顶。
    /// tops 与 stacks 一一对应；nil 表示该格暂无可当顶的成员（求解中会被并掉）。
    func framesForTops(stacks: [[WinInfo]], tops: [WinInfo?], screen: NSScreen, sid: CGDirectDisplayID) -> [CGRect] {
        let vf = screen.visibleFrame
        guard !stacks.isEmpty, stacks.count == tops.count else { return [] }
        let needs: [CGSize] = stacks.indices.map { i in
            guard let t = tops[i] else { return .zero }
            return effectiveMin(for: t)
        }
        let claims = needs.map { layoutClaim($0, vf: vf) }
        var frames = biasedFrames(count: stacks.count, vf: vf, claims: claims)
        frames = applySplitOverrides(frames: frames, tileCount: stacks.count, vf: vf, sid: sid)
        if draggingDividerID == nil {
            frames = applyGiveWay(frames: frames, needs: needs, sid: sid)
        }
        return frames
    }

    /// 顶能否精确等于格子（容差 1.5pt，与 frameMatchesSlot 同口径）。
    /// 固定尺寸窗：格子尺寸必须等于其精确尺寸（只比尺寸不比位置，位置由摆位写）。
    func topFitsSlot(_ w: WinInfo, _ slot: CGRect) -> Bool {
        let need = effectiveMin(for: w)
        if fixedSizeKeys.contains(winKey(w)) {
            return abs(slot.width - need.width) <= 1.5 && abs(slot.height - need.height) <= 1.5
        }
        return slotShortfall(need, slot, tolerance: 1.5) == 0
    }

    /// 约束自适应求解循环（布局核心）。
    /// 输入：族（面板 layoutKind，framesForTops 内经 biasedFrames/layoutFrames 体现）
    /// ＋格数上限（保存值，绝不改写；降格只影响本轮引擎值）＋每格顶＋所有窗的 effectiveMin。
    /// 步骤：
    /// 1. 按顶出格：framesForTops 按每格顶的 effectiveMin 申领份额（格子按顶定）。
    /// 2. 逐格验证：顶不能精确等于格子时，先看同格有没有别的成员能当顶（换贴合顶）；
    /// 3. 换顶仍不行，并格降数：把该格成员并进活动格（活动格成员数 +1），格数 -1，回到 1 重算；
    ///    降到 1 格（整屏）仍不能的顶记成员-only（oversizeStacked，永不当顶，物理上限，记日志）。
    /// 4. 输出：格子（显示顺序）、每格顶、帧、降格原因（nil 表示未降格）。
    /// 注意：被盖住的成员不验算；固定尺寸顶的格子按其精确尺寸给（topFitsSlot 内分支）。
    /// 调用方在显示顺序上跑本函数（displayStacks），stackTops 写回时按 permSrcSlot 换算回计算格下标。
    func solveTopFit(stacks inStacks: [[WinInfo]], tops inTops: [WinInfo?], screen: NSScreen, sid: CGDirectDisplayID, openedKeys: Set<String> = []) -> (stacks: [[WinInfo]], tops: [WinInfo?], frames: [CGRect], reduceNote: String?) {
        let vf = screen.visibleFrame
        var stacks = inStacks
        var tops = inTops
        var reduceNote: String? = nil
        let savedCount = max(1, stacks.count)
        // 空格子先并掉（不占格数），再进入验证循环。
        func dropEmpty() {
            var i = 0
            while i < stacks.count {
                if stacks[i].isEmpty || tops[i] == nil {
                    stacks.remove(at: i)
                    tops.remove(at: i)
                } else { i += 1 }
            }
        }
        dropEmpty()
        if stacks.isEmpty { return ([[]], [nil], [], nil) }
        // 顶在成员里的下标（摆位后 stackTops 写回用）；tops 元素本身即顶窗口。
        var guardRounds = 0
        while true {
            guardRounds += 1
            if guardRounds > 64 { break }
            let frames = framesForTops(stacks: stacks, tops: tops, screen: screen, sid: sid)
            guard frames.count == stacks.count else { break }
            var badTile: Int? = nil
            for i in stacks.indices {
                guard let t = tops[i] else { badTile = i; break }
                // 用户打开顶：本轮不动它（不换顶、不并格），下一触发再适配。
                if openedKeys.contains(winKey(t)) { continue }
                if !topFitsSlot(t, frames[i]) { badTile = i; break }
            }
            guard let bad = badTile else {
                // 全格通过：顶已确认。固定尺寸判定只由落点验算（exactnessStuck）写入，
                // 求解这里不自动记，避免把“格子恰好等于最小尺寸”误判成固定尺寸。
                return (stacks, tops, frames, reduceNote)
            }
            // 先换贴合顶：同格里找能精确等于该格的成员（优先贴合、其次最小尺寸最小）。
            // 用户刚翻上来的顶（pinned）不换：布局要围绕它变（并格），而不是把它换下去。
            let slot = frames[bad]
            let stack = stacks[bad]
            let badKey = tops[bad].map { winKey($0) } ?? ""
            // 折叠窗不 sticky：它不显示，求解应提未折叠成员当顶，而不是为它并格。
            let isSticky = !foldedKeys.contains(badKey) && pinnedTops[stackTopKey(sid, permSrcSlot(bad, sid: sid))] == badKey
            var candidates: [WinInfo] = []
            if !isSticky {
                candidates = stack.filter { winKey($0) != badKey && !oversizeStacked.contains(winKey($0)) && !foldedKeys.contains(winKey($0)) }
                    .filter { topFitsSlot($0, slot) }
            }
            if let best = candidates.min(by: { a, b in
                let na = effectiveMin(for: a); let nb = effectiveMin(for: b)
                return na.width * na.height < nb.width * nb.height
            }) {
                log("solve: tile \(bad) top \(tops[bad]?.appName ?? "") does not fit, promote \(best.appName)")
                tops[bad] = best
                continue
            }
            // 换顶不行：并格降数（该格成员并进活动格；活动格取第 0 格，格数 -1）。
            if stacks.count > 1 {
                // 并掉的格的 pin 一并清掉（格子没了，pin 再指旧格下标下轮会错指别的格）。
                pinnedTops.removeValue(forKey: stackTopKey(sid, permSrcSlot(bad, sid: sid)))
                let merged = stacks.remove(at: bad)
                tops.remove(at: bad)
                let host = 0
                // 被并格的顶若整屏都装不下，记成员-only（下次不再当顶候选，除非它是某格唯一成员）。
                if let bt = merged.first(where: { winKey($0) == badKey }) {
                    let whole = vf
                    if slotShortfall(effectiveMin(for: bt), whole, tolerance: 1.5) > 0 {
                        oversizeStacked.insert(badKey)
                        oversizeHost[badKey] = stacks[host].first.map { winKey($0) } ?? ""
                        log("solve: \(bt.appName) exceeds whole work area, member-only")
                    }
                }
                // 成员并进活动格：原顶放最后（不抢活动格顶），其余成员跟在后面。
                let rest = merged.filter { winKey($0) != badKey }
                stacks[host].append(contentsOf: rest)
                if let bt = merged.first(where: { winKey($0) == badKey }) { stacks[host].append(bt) }
                let badName = merged.first(where: { winKey($0) == badKey })?.appName ?? "a window"
                reduceNote = "Tile count reduced from \(savedCount) to \(stacks.count) to fit \(badName)"
                log("solve: merge tile \(bad) into tile \(host), tiles now \(stacks.count)")
                dropEmpty()
                continue
            }
            // 降到 1 格仍不能：该顶永不当顶（物理上限），记成员-only，换格里别的成员当顶；
            // 格里没有别人时，顶保持原窗但记日志（单格单窗是 degenerate 情形，摆位仍写格子帧，
            // 下一轮 tick 的 transient 守卫会复核；不自动隐藏、不自动浮动）。
            if let bt = tops[bad] {
                let key = winKey(bt)
                if stack.count > 1 {
                    oversizeStacked.insert(key)
                    oversizeHost[key] = stack.first(where: { winKey($0) != key }).map { winKey($0) } ?? ""
                    pinnedTops.removeValue(forKey: stackTopKey(sid, permSrcSlot(bad, sid: sid)))
                    log("solve: \(bt.appName) cannot fit even fullscreen, member-only")
                    if let alt = stack.first(where: { winKey($0) != key && !oversizeStacked.contains(winKey($0)) && !foldedKeys.contains(winKey($0)) }) {
                        tops[bad] = alt
                        continue
                    }
                    // 格里别的成员也都被标记：放宽到任意非原顶成员再试一轮（自纠，避免死标记）。
                    if let alt = stack.first(where: { winKey($0) != key }) {
                        tops[bad] = alt
                        continue
                    }
                } else {
                    log("solve: single window \(bt.appName) cannot fit fullscreen, kept as top (physical limit)")
                }
            }
            return (stacks, tops, frames, reduceNote)
        }
        // 防护轮数耗尽：返回当前帧（不崩），下轮重算再试。
        let frames = framesForTops(stacks: stacks, tops: tops, screen: screen, sid: sid)
        return (stacks, tops, frames, reduceNote)
    }

    /// 工作区四边再内缩当前间距。间距大到没有剩余时退回可视区。
    func insetWorkArea(on screen: NSScreen) -> CGRect {
        let vf = screen.visibleFrame
        let gap = gapForLayout()
        let box = vf.insetBy(dx: gap, dy: gap)
        if box.width > 80, box.height > 80 { return box }
        return vf
    }

    /// Focus 铺满工作区，四边留出间距，不盖住菜单栏和 Dock。
    func focusFrame(on screen: NSScreen) -> CGRect {
        insetWorkArea(on: screen)
    }

    /// 手动 Float：工作区内缩后取 60% 宽、75% 高，居中。已知最小尺寸更大时抬高，仍留在这块区域内。
    func manualFloatFrame(on screen: NSScreen, need: CGSize) -> CGRect {
        let box = insetWorkArea(on: screen)
        var cw = box.width * 0.60
        var ch = box.height * 0.75
        if need.width > 1 { cw = min(max(cw, need.width), box.width) }
        if need.height > 1 { ch = min(max(ch, need.height), box.height) }
        cw = max(1, cw)
        ch = max(1, ch)
        return CGRect(x: box.midX - cw / 2, y: box.midY - ch / 2, width: cw, height: ch)
    }

    /// 满格策略为 float 时：新窗口按当前尺寸居中浮动，不进任何格。有空位后重算会把它收回来。
    func floatWhenFull(_ w: WinInfo, on screen: NSScreen) {
        let key = winKey(w)
        let step = floatedKeys.count
        guard floatedKeys.insert(key).inserted else { return }
        let box = insetWorkArea(on: screen)
        let cur = getSize(w.element) ?? w.frame.size
        let width = min(max(cur.width > 1 ? cur.width : 480, 80), box.width)
        let height = min(max(cur.height > 1 ? cur.height : 320, 60), box.height)
        var frame = CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
        // 与最小尺寸浮动同一套错开排列：满格溢出可能一次好几扇。
        if step > 0 {
            let col = CGFloat(step % 5)
            let row = CGFloat(step / 5)
            frame.origin.x = min(max(frame.minX + col * 30, box.minX), max(box.minX, box.maxX - width))
            frame.origin.y = min(max(frame.minY - row * 30, box.minY), max(box.minY, box.maxY - height))
        }
        placeFrame(w.element, frame, key: key, animated: draggingDividerID == nil, learnName: w.appName)
        lastPlacedFrames[key] = frame
        log("when-full float -> \(w.appName)")
    }

    // 已落位冻结重建（只在非换布局轮次调用）：不重解、不并格、不改格子帧。
    // 输入冻结布局（计算格顺序）与本轮 live 窗，输出显示顺序的叠 + 帧 + 顶，
    // 与 solveTopFit 同构，可直接替其输出。
    // 规则：已落位窗回原格原位（关掉的留空格子）；新窗进空格（无可见成员的格），
    // 无空格叠进活动格（当轮 whenFull 为浮动时改浮动）；Dock 点开的窗只算它自己
    // （同规则进空格或叠栈，顶优先）；顶选择：用户打开窗 > stackTops > 记录顶键
    // > 首位未折叠成员。选定后写回 stackTops，使提窗与 lastTiles 的顶口径一致。
    func frozenSolve(screen: NSScreen, sid: CGDirectDisplayID, windows: [WinInfo], frozen: FrozenLayout, activeTopKey: String) -> (stacks: [[WinInfo]], tops: [WinInfo?], frames: [CGRect], reduceNote: String?) {
        let tileCount = frozen.tileFrames.count
        guard tileCount > 0, frozen.assignment.count == tileCount else { return ([[]], [nil], [], nil) }
        let st = layoutSettings(for: screen)
        var byKey: [String: WinInfo] = [:]
        for w in windows { byKey[winKey(w)] = w }
        let assignedKeys = Set(frozen.assignment.flatMap { $0 })
        // 计算格叠：按冻结归属回填 live 窗（关掉的自然脱落，格子留空）。
        var computeStacks: [[WinInfo]] = frozen.assignment.map { keys in keys.compactMap { byKey[$0] } }
        // 本轮冻结窗键（供 0.5 秒补写过滤）；新落点的窗不在此列，补写仍保护它。
        var frozenKeysThisRound: Set<String> = []
        for stack in computeStacks { for w in stack { frozenKeysThisRound.insert(winKey(w)) } }
        oneShotFrozenKeys.formUnion(frozenKeysThisRound)
        // 活动格：含前台窗的格 > 含原活动顶的格 > 首个有可见成员的格 > 0。
        func activeTileIndex() -> Int {
            if let front = frontFocusKeyForPass, !front.isEmpty, let i = computeStacks.firstIndex(where: { $0.contains { winKey($0) == front && !foldedKeys.contains(winKey($0)) } }) { return i }
            if !activeTopKey.isEmpty, let i = computeStacks.firstIndex(where: { $0.contains { winKey($0) == activeTopKey } }) { return i }
            if let i = computeStacks.firstIndex(where: { $0.contains { !foldedKeys.contains(winKey($0)) } }) { return i }
            return 0
        }
        // 新窗（不在冻结归属里：新开、切 Space 后首次见、Dock 点开后原格被占等）
        // 只算它自己：有空格进空格，无空格叠进活动格（whenFull 为浮动时改浮动）。
        var floatedFresh = false
        for w in windows where !assignedKeys.contains(winKey(w)) {
            let key = winKey(w)
            // 空格 = 无 live 可见成员（只剩折叠成员的格也算空格：折叠窗不可见，
            // 它日后点开回原格时与新窗同叠、顶优先用户打开窗）。
            if let empty = computeStacks.firstIndex(where: { stack in
                !stack.contains { m in !foldedKeys.contains(winKey(m)) }
            }) {
                computeStacks[empty].append(w)
                if key == frontFocusKeyForPass {
                    stackTops[stackTopKey(sid, empty)] = computeStacks[empty].count - 1
                }
            } else if st.whenFull == .float {
                // 满格浮动：与 computeTiles 的 whenFullOverflow 同口径（只在选了
                // 居中浮动时浮动；叠栈设置下走下面的叠栈分支）。
                let step = floatedKeys.count
                floatedKeys.insert(key)
                if oneShotActive {
                    oneShotPlacements.append(OneShotPlacement(win: w, frame: oneShotFloatFrame(w, on: screen, step: step)))
                } else {
                    floatWhenFull(w, on: screen)
                }
                floatedFresh = true
            } else {
                let ai = activeTileIndex()
                computeStacks[ai].append(w)
                if key == frontFocusKeyForPass {
                    stackTops[stackTopKey(sid, ai)] = computeStacks[ai].count - 1
                }
            }
        }
        if floatedFresh {
            showToast("This Space is full", detail: "⌘-drag a window onto a pane to swap.", on: screen)
        }
        // Primary 镜像（applyPrimarySwap 的计算格版）：冻结轮次跳过了
        // 原调用，这里补做，否则 Primary 换顶在冻结轮次失效。
        if let pk = primaryKeysByScreen[sid] {
            if let pkTile = computeStacks.firstIndex(where: { $0.contains { winKey($0) == pk } }) {
                let pkIdx = computeStacks[pkTile].firstIndex(where: { winKey($0) == pk })!
                if pkTile == 0 {
                    stackTops[stackTopKey(sid, 0)] = pkIdx
                } else {
                    let top0Idx = min(stackTops[stackTopKey(sid, 0)] ?? 0, computeStacks[0].count - 1)
                    if computeStacks[0].indices.contains(top0Idx) {
                        let b = computeStacks[0][top0Idx]
                        computeStacks[0][top0Idx] = computeStacks[pkTile][pkIdx]
                        computeStacks[pkTile][pkIdx] = b
                        stackTops[stackTopKey(sid, 0)] = top0Idx
                        stackTops[stackTopKey(sid, pkTile)] = pkIdx
                    }
                }
            } else {
                primaryKeysByScreen.removeValue(forKey: sid)
            }
        }
        // 显示顺序：经当前置换（冻结格数口径）翻译。
        let perm = sanitizedSwapPerm(tileSwapPermByScreen[sid], count: tileCount)
        let displayStacks = perm.map { computeStacks[$0] }
        let displayFrames = perm.map { frozen.tileFrames[$0] }
        // 顶选择（显示顺序）：用户打开窗 > stackTops（计算格键）>
        // 记录顶键 > 首位未折叠成员 > 首位；选定后写回 stackTops。
        var tops: [WinInfo?] = []
        for di in displayStacks.indices {
            let stack = displayStacks[di]
            guard !stack.isEmpty else { tops.append(nil); continue }
            let ci = perm[di]
            var chosen: WinInfo? = nil
            var chosenIdx = 0
            if let g = stack.first(where: { userOpenedKeys.contains(winKey($0)) }) {
                chosen = g
                chosenIdx = stack.firstIndex(where: { winKey($0) == winKey(g) }) ?? 0
            } else if let cur = stackTops[stackTopKey(sid, ci)], stack.indices.contains(cur),
                      !foldedKeys.contains(winKey(stack[cur])) {
                chosen = stack[cur]
                chosenIdx = cur
            } else if ci < frozen.topKeys.count, let rk = frozen.topKeys[ci],
                      let idx = stack.firstIndex(where: { winKey($0) == rk }) {
                chosen = stack[idx]
                chosenIdx = idx
            } else if let alt = stack.first(where: { !foldedKeys.contains(winKey($0)) }) {
                chosen = alt
                chosenIdx = stack.firstIndex(where: { winKey($0) == winKey(alt) }) ?? 0
            } else {
                chosen = stack[0]
                chosenIdx = 0
            }
            tops.append(chosen)
            stackTops[stackTopKey(sid, ci)] = chosenIdx
        }
        return (displayStacks, tops, displayFrames, nil)
    }

    // 拖缝后冻结记录跟帧：拖缝直接改帧不走 tile()，冻结记录须跟着拖后的帧走，
    // 否则下次事件触发冻结轮次会把拖过的窗写回拖前帧。按成员键认格
    // （shown 顺序与计算格顺序未必一致，空位格不动）；撤销时同样跟回拖前帧。
    func syncFrozenFramesFromShownTiles(sid: CGDirectDisplayID) {
        guard var frozen = frozenLayoutByScreen[sid], let tiles = lastTilesByScreen[sid] else { return }
        for t in tiles {
            let keys = Set(t.stack.map { winKey($0) })
            guard !keys.isEmpty else { continue }
            if let ci = frozen.assignment.firstIndex(where: { !Set($0).isDisjoint(with: keys) }),
               frozen.tileFrames.indices.contains(ci) {
                frozen.tileFrames[ci] = t.frame
            }
        }
        frozenLayoutByScreen[sid] = frozen
    }

    func tile(screen: NSScreen, windows: [WinInfo], refreshOverlays: Bool = true) {
        let sid = screenID(screen)
        let st = layoutSettings(for: screen)
        guard !windows.isEmpty else {
            lastTilesByScreen[sid] = []
            if refreshOverlays { refreshGrips(); refreshDimLayers(); refreshDotHandles(); refreshStackMarkers() }
            return
        }
        let vf = screen.visibleFrame
        // Focus 盖住式：聚焦窗口铺满本屏可视区并置顶，其余窗口不动；
        // 聚焦窗口已不在集合里（关闭或被浮动排除）则退出 Focus，走正常平铺。
        if let fk = focusKey, focusScreen == sid {
            if let fw = windows.first(where: { winKey($0) == fk }) {
                let full = focusFrame(on: screen)
                if oneShotActive {
                    // 一shot算阶段：Focus 窗只记方案（精确帧 = focusFrame），不写 AX；
                    // 写阶段统一写帧并补专注提示。
                    oneShotPlacements.append(OneShotPlacement(win: fw, frame: full))
                    oneShotFocusCaptions.append(screen)
                    if refreshOverlays { hideGrips(); hideStackMarkers(); removeDimLayers() }
                    return
                }
                AXUIElementPerformAction(fw.element, kAXRaiseAction as CFString)
                placeFrame(fw.element, full, key: fk, animated: draggingDividerID == nil)
                lastPlacedFrames[fk] = full
                showFocusCaption(on: screen, frame: full)
                if refreshOverlays { hideGrips(); hideStackMarkers(); removeDimLayers() }
                return
            }
            focusKey = nil
            focusScreen = nil
            focusSavedFrames = nil
            focusSavedTops = nil
            focusSavedActive = nil
            hideFocusCaption()
            log("focus off: target gone")
        }
        if cleanSpaceOn, cleanSpaceScreen == sid {
            if refreshOverlays {
                hideGrips()
                hideStackMarkers()
                removeDimLayers()
                if cleanSpaceHole.width > 1 { showCleanDim(on: screen, hole: cleanSpaceHole) }
            }
            return
        }
        // 关掉/移走的窗口从「并进堆叠」名单里清掉，同键的新窗口要重新验算。
        // 盖邻格去抖记录同理裁剪：已关窗口的旧键若被新窗口复用，不得误去抖。
        let liveKeys = Set(windows.map { winKey($0) })
        // 切换族/上限从头重算：上一布局的求解态（活动格、超格成员-only 标记、
        // 栈顶、格子置换）不带进新族；手动堆叠（stackedOnto）与 Primary 是
        // 用户态，不是上一布局的残留，保留。格子帧本身每轮重算，不复用。
        let freshSwitch = oneShotFreshScreens.contains(sid)
        if freshSwitch {
            oversizeStacked.subtract(liveKeys)
            lastActiveTileByScreen.removeValue(forKey: sid)
            stackTops = stackTops.filter { !$0.key.hasPrefix("\(sid):") }
            pinnedTops = pinnedTops.filter { !$0.key.hasPrefix("\(sid):") }
            tileSwapPermByScreen.removeValue(forKey: sid)
        }
        // 已落位冻结判定：非换布局轮次、本屏有冻结布局、格数一致、
        // 且全部冻结帧仍在当前可视区内（1.5pt 容差）。任一条件不满足
        // 即走全量重算（并在 tile 末尾重新记录）。
        let sig = signature(windows)
        let frozenLayoutForRound = frozenLayoutByScreen[sid]
        let frozenFramesValid: Bool = {
            guard var f = frozenLayoutForRound, !f.tileFrames.isEmpty, f.tileFrames.count == f.assignment.count else { return false }
            // 关掉的窗只从它自己那一叠里剪掉，其余窗的格子与归属保持冻结——绝不整屏重排。
            // 一叠被关空时丢掉那一格并按剩余格数重排帧（格数回落，不留空洞）。
            let assigned = Set(f.assignment.flatMap { $0 })
            let missingKeys = assigned.subtracting(liveKeys)
            if !missingKeys.isEmpty {
                // 只是最小化 / 切到别的 Space 的窗还活着：不剪格，格子留给它恢复时回位。
                // 只有窗口号真从窗口服务器消失（关闭）的才剪。
                let wide = allSpaceWindowKeys()
                let goneKeys = missingKeys.filter { !windowKeyStillAlive($0, wide: wide) }
                if !goneKeys.isEmpty {
                    let byKey = Dictionary(windows.map { (winKey($0), $0) }, uniquingKeysWith: { a, _ in a })
                    var keptAssignment: [[String]] = []
                    var keptFrames: [CGRect] = []
                    var keptTops: [String?] = []
                    var winStacks: [[WinInfo]] = []
                    var winTops: [WinInfo?] = []
                    for (i, stack) in f.assignment.enumerated() {
                        let kept = stack.filter { !goneKeys.contains($0) }
                        guard !kept.isEmpty else { continue }
                        let wantedTop = f.topKeys.indices.contains(i) ? f.topKeys[i] : nil
                        keptAssignment.append(kept)
                        keptFrames.append(f.tileFrames[i])
                        keptTops.append(wantedTop)
                        let members = kept.compactMap { byKey[$0] }
                        guard members.count == kept.count else { return false }
                        winStacks.append(members)
                        let top = members.first { winKey($0) == wantedTop }
                            ?? members.first { !foldedKeys.contains(winKey($0)) } ?? members[0]
                        winTops.append(top)
                    }
                    guard !keptAssignment.isEmpty else { return false }
                    if keptAssignment.count != f.assignment.count {
                        // 格数回落：用和正常求解同一套自适应几何重算（每格顶按最小尺寸申领份额），
                        // 免得不经求解的等分基线把固定尺寸窗（系统设置之类）误判成塞不下而折进 Dock。
                        let adaptive = framesForTops(stacks: winStacks, tops: winTops, screen: screen, sid: sid)
                        keptFrames = adaptive.count == keptAssignment.count
                            ? adaptive
                            : layoutFrames(count: keptAssignment.count, vf: vf, kind: st.kind, share: st.share, gap: st.gap)
                        guard keptFrames.count == keptAssignment.count else { return false }
                    }
                    f.assignment = keptAssignment
                    f.tileFrames = keptFrames
                    f.topKeys = keptTops
                    frozenLayoutByScreen[sid] = f
                    log("frozen pruned: tiles=\(keptAssignment.count) after close")
                }
            }
            return f.tileFrames.allSatisfy { fr in
                fr.minX >= vf.minX - 1.5 && fr.maxX <= vf.maxX + 1.5 &&
                fr.minY >= vf.minY - 1.5 && fr.maxY <= vf.maxY + 1.5
            }
        }()
        // 冻结布局按需扩容：格数还没铺到上限（上限内还有可成格的根窗）时，允许本轮
        // 全量重算把新窗铺进新格，而不是一律叠进活动格；铺满上限后才冻结。
        // 同一窗口集合只尝试扩容一次：求解可能因窗口塞不进并格回落，不能因此每轮重算。
        let expandRoots = windows.filter { stackedOnto[winKey($0)] == nil && !oversizeStacked.contains(winKey($0)) }.count
        let expandTarget = min(min(st.tileLimit, 4), expandRoots)
        // 扩容尝试记录用「窗口键」签名，不用每 pid 计数签名：关一扇又开一扇（计数不变）
        // 也是新的窗口集合，仍该允许一次扩容，否则新窗永远只能叠进活动磁贴。
        let expandSig = keySignature(windows)
        // 有窗正贴着自己的物理下限（如系统设置 740x470 正好占满 744x470 的格子）时本轮不扩容：
        // 扩容会重分格子，把它的格子改小，缩不动的它只能折进 Dock——为了多铺一格把一扇
        // 已经摆好的窗踢走，不如不扩。关窗剪格后也走这条，剪格结果不会被同一轮扩容抹掉。
        let hasAtFloorWindow = windows.contains { w in
            guard w.frame.width > 1, w.frame.height > 1 else { return false }
            let need = effectiveMin(for: w)
            return need.width > 1 && need.height > 1
                && abs(w.frame.width - need.width) <= 1.5 && abs(w.frame.height - need.height) <= 1.5
        }
        let needsExpansion = (frozenLayoutForRound?.tileFrames.count ?? 0) < expandTarget
            && expandAttemptedSignatureByScreen[sid] != expandSig
            && !hasAtFloorWindow
        let isFrozenRound = !freshSwitch && frozenFramesValid && !needsExpansion
        if needsExpansion, !isFrozenRound { expandAttemptedSignatureByScreen[sid] = expandSig }
        oversizeStacked.formIntersection(liveKeys)
        oversizeHost = oversizeHost.filter { oversizeStacked.contains($0.key) }
        coverLoggedFrame = coverLoggedFrame.filter { liveKeys.contains($0.key) }
        // 恢复后可见的折叠窗：Dock 点出 / 激活恢复后它已不在最小化态，
        // 但折叠记账还留着——先清账，再按正常窗走本轮求解（本轮即重算触发，
        // 尺寸适配规则直接适用；不合尺寸的在这里就会折，而不是留到下一轮）。
        // 注意：仍最小化的折叠窗不在此列（仍藏在 Dock 里，继续按折叠处理）。
        for w in windows where foldedKeys.contains(winKey(w)) {
            if !boolAttr(w.element, kAXMinimizedAttribute as CFString) {
                let k = winKey(w)
                foldedKeys.remove(k)
                foldedMinimizedKeys.remove(k)
                foldedElements.removeValue(forKey: k)
                foldedScreenByKey.removeValue(forKey: k)
            }
        }
        // 用户亲手最小化：留存期到此为止，且不得自动恢复（恢复块只动
        // 折叠集成员，留存窗不在折叠集里，天然不恢复）。屏幕集合变化、
        // 焦点切换、其他窗开/关一律不得清掉留存态——旧宽限“签名一变
        // 即清”的逻辑已删，留存只在这里、切族/改上限、窗关闭时清掉。
        for w in windows where userOpenedKeys.contains(winKey(w)) {
            if boolAttr(w.element, kAXMinimizedAttribute as CFString) {
                userOpenedKeys.remove(winKey(w))
                log("user opened cleared: \(w.appName) minimized by user")
            }
        }
        let previousTiles = lastTilesByScreen[sid] ?? []
        let previousKeys = Set(previousTiles.flatMap { $0.stack.map { winKey($0) } })
        var preservedTopKeys: [String] = []
        let signatureChanged = sig != lastTiledSignatureByScreen[sid]
        if signatureChanged {
            let fresh = windows.reduce(0) { $0 + (previousKeys.contains(winKey($1)) ? 0 : 1) }
            notePlaced(fresh)
            for tile in previousTiles where !tile.stack.isEmpty && !freshSwitch {
                // 三元组自带显示顶，置换下也正确；不再按格下标反查 stackTops。
                // 从头重算时跳过：上一布局的顶不得带进新族。
                preservedTopKeys.append(winKey(tile.top))
            }
            // 下标会随关窗错位，按窗口键在新堆叠里再找回来；不要把每一叠都清成 0。
            // 冻结轮次不清除栈顶/固定顶：冻结重建靠 stackTops 认顶，清掉会丢
            // 用户翻过的栈顶；签名基线照常更新（tick 门仍工作）。
            if !isFrozenRound {
                stackTops = stackTops.filter { !$0.key.hasPrefix("\(sid):") }
                pinnedTops = pinnedTops.filter { !$0.key.hasPrefix("\(sid):") }
            }
            lastTiledSignatureByScreen[sid] = sig
        }
        // 先拆掉上一轮的自动堆叠，再按当前最小尺寸决定要不要重新并进去。
        // 手动堆叠不在 autoStackHost 里，不会被拆。
        let previousAuto = autoStackHost
        // 冻结轮次不拆自动堆叠：冻结归属里已含自动堆叠关系，拆掉后
        // 本轮不再重推（planTileFit 已跳过），会丢归属。
        if draggingDividerID == nil, dragState == nil, !isFrozenRound {
            releaseAutoStacks(on: sid, live: windows)
        }
        var (stacks, origActive, whenFullOverflow) = computeTiles(windows: windows, st: st, sid: sid)
        // 满格且选了居中浮动：多出来的根窗口立刻浮动，不进任何叠。
        var floatedNewWindow = false
        // 冻结轮次跳过满格浮动：computeTiles 的溢出是按重算分布算的，
        // 冻结轮次里满格新窗由 frozenSolve 按当轮 whenFull 定（叠栈或浮动）。
        for w in whenFullOverflow where !isFrozenRound && !floatedKeys.contains(winKey(w)) {
            if !previousKeys.contains(winKey(w)) { floatedNewWindow = true }
            if oneShotActive {
                // 一shot算阶段：满格浮动窗只记方案（纯计算落点），不写 AX；
                // 浮动记账（floatedKeys）是方案状态，算阶段即可写入。
                let step = floatedKeys.count
                floatedKeys.insert(winKey(w))
                oneShotPlacements.append(OneShotPlacement(win: w, frame: oneShotFloatFrame(w, on: screen, step: step)))
            } else {
                floatWhenFull(w, on: screen)
            }
        }
        if floatedNewWindow {
            showToast("This Space is full", detail: "⌘-drag a window onto a pane to swap.", on: screen)
        }
        // 冻结轮次跳过 Primary 交换：输入叠是重算的旧分布，在其上交换
        // 会写错栈顶；Primary 由 frozenSolve 内按计算格镜像处理。
        if !isFrozenRound {
            stacks = applyPrimarySwap(stacks: stacks, sid: sid)
        }
        // 冻结轮次跳过约束重推：本轮叠分布由 frozenSolve 从冻结归属重建，
        // 这里按重算分布推 planTileFit 只会写错栈顶与自动堆叠关系。
        if draggingDividerID == nil, dragState == nil, !stacks.isEmpty, !isFrozenRound {
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
            if planned.isEmpty { planned = [[]] }
            // 约束自适应平铺：整屏工作区都装不下的那一扇也不自动消失。
            // 它仍进格子当成员（不做顶、靠芯片翻堆），整屏装不下只是“永不当顶”的物理上限。
            // plan.floated 的窗若已在 planned 里是成员身份就留着；不在任何格里时挂进活动格。
            for id in plan.floated where flat.indices.contains(id) {
                let w = flat[id]
                let key = winKey(w)
                log("min-size member: \(w.appName) exceeds the whole work area, stays stacked")
                oversizeStacked.insert(key)
                if !planned.contains(where: { $0.contains { winKey($0) == key } }) {
                    let ai = min(origActive, planned.count - 1)
                    if planned.indices.contains(ai) { planned[ai].append(w) }
                }
            }
            planned.removeAll { $0.isEmpty }
            if planned.isEmpty { planned = [[]] }
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
            // 上一轮判定的超格窗口挂回原格（首选）；原格不在了才按几何最近选。
            // 它们既不做根、也不申领几何，只作为堆叠成员存在，靠悬停条芯片切换。
            if !oversizeStacked.isEmpty {
                var byKey: [String: WinInfo] = [:]
                for w in windows { byKey[winKey(w)] = w }
                let ref = framesFor(stacks: stacks, screen: screen, sid: sid)
                for key in oversizeStacked {
                    guard let w = byKey[key] else { continue }
                    // 已在格里（plan 成员身份）的只留原位，不重复挂——否则同一窗在同一格出现两次。
                    if stacks.contains(where: { $0.contains { winKey($0) == key } }) { continue }
                    var hi: Int? = nil
                    if let host = oversizeHost[key] {
                        hi = stacks.firstIndex { $0.contains { winKey($0) == host } }
                    }
                    if hi == nil {
                        let cx = w.frame.midX
                        let cy = w.frame.midY
                        hi = stacks.indices.min { a, b in
                            let da = ref.indices.contains(a) ? hypot(ref[a].midX - cx, ref[a].midY - cy) : .greatestFiniteMagnitude
                            let db = ref.indices.contains(b) ? hypot(ref[b].midX - cx, ref[b].midY - cy) : .greatestFiniteMagnitude
                            return da < db
                        }
                    }
                    guard let h = hi, stacks.indices.contains(h) else { continue }
                    stacks[h].append(w)
                    if let host = stacks[h].first(where: { !oversizeStacked.contains(winKey($0)) }) {
                        oversizeHost[key] = winKey(host)
                    }
                }
            }
            // 约束自适应平铺：这里不再做“装不下进独占”的 pane-fit 验算。
            // 顶能否精确等于格子由求解循环（solveTopFit，摆位前）逐格验证：
            // 调份额 → 降格子数 → 当不了顶的进堆当成员；被盖住的成员不验算。
            // （旧 pane-fit 块随自动独占路径一并删除。）
            if let idx = stacks.firstIndex(where: { $0.contains { winKey($0) == activeTopKeyBefore } }) {
                origActive = idx
            } else {
                origActive = 0
            }
            // 自动独占入组已删：没有需要异步入组的窗。
        }
        // 堆叠提示每会话一次。面板开关不走这里。文案不放键帽。
        let hasStack = stacks.contains { $0.count > 1 }
        if hasStack, !didShowStackToast {
            didShowStackToast = true
            showToast("Stacked in this tile", detail: "Click the orange grip above the window to switch.", on: screen)
        }
        lastStackByScreen[sid] = hasStack
        let activeTopKey = stacks.isEmpty ? "" : winKey(stacks[min(origActive, stacks.count - 1)][min(stackTops[stackTopKey(sid, min(origActive, stacks.count - 1))] ?? 0, stacks[min(origActive, stacks.count - 1)].count - 1)])
        let fitStacks = stacks
        let active = fitStacks.firstIndex(where: { $0.contains(where: { winKey($0) == activeTopKey }) }) ?? 0
        // 冻结轮次跳过顶恢复：fitStacks 是重算分布，其下标与冻结格错位，
        // 按它写 stackTops 会错指；冻结轮次的顶由 frozenSolve 定。
        if signatureChanged && !isFrozenRound {
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
                            if oneShotActive {
                                // 一shot算阶段不提窗：记到写阶段统一提一次。
                                oneShotRaiseTops.append(windows[fi])
                            } else {
                                AXUIElementPerformAction(windows[fi].element, kAXRaiseAction as CFString)
                            }
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
        // 约束自适应求解（显示顺序）：整叠交换置换先算，显示格 i 装计算格 permSrcSlot(i) 的叠；
        // 求解在显示顺序上跑（格子几何按显示格固定），顶下标写回时按 permSrcSlot 换算回计算格。
        // 每一扇标准窗口都写入自己的格子；当不了顶的进堆当成员，不自动隐藏、不自动浮动。
        // 栈顶下标按计算格存，随叠走；求解并格后置换失效（格数变了），直接清掉置换、按显示格存。
        let swapPerm = sanitizedSwapPerm(tileSwapPermByScreen[sid], count: fitStacks.count)
        if swapPerm == Array(0..<fitStacks.count) { tileSwapPermByScreen.removeValue(forKey: sid) } else { tileSwapPermByScreen[sid] = swapPerm }
        // 冻结轮次：置换按冻结格数重新消毒（fitStacks 数随开窗/关窗变，
        // 冻结格数不变；旧置换若按旧数存会错指），供冻结重建与下游
        // permSrcSlot 共用同一口径。
        if isFrozenRound, let f = frozenLayoutByScreen[sid] {
            let fp = sanitizedSwapPerm(tileSwapPermByScreen[sid], count: f.tileFrames.count)
            if fp == Array(0..<f.tileFrames.count) { tileSwapPermByScreen.removeValue(forKey: sid) } else { tileSwapPermByScreen[sid] = fp }
        }
        var displayStacks = swapPerm.map { fitStacks[$0] }
        var displayActive = displayStacks.firstIndex(where: { $0.contains(where: { winKey($0) == activeTopKey }) }) ?? active
        // 求解 provisional 顶：沿用计算格栈顶（经 permSrcSlot 换算），跳过成员-only 标记；
        // 某格没有未标记成员时放宽到任意成员再试（自纠，避免死标记），都没有则该格并掉。
        // 格顶取第一个未折叠且贴合的成员：折叠窗不进求解顶候选（格子按显示顶定，
        // 否则折叠窗的最小尺寸会把格子撑大，显示顶反而填不满）。
        let provisionalTops: [WinInfo?] = displayStacks.indices.map { di in
            let stack = displayStacks[di]
            // 用户打开窗优先当顶：点开后要正常展示，不能被求解换成成员藏起来。
            if let g = stack.first(where: { userOpenedKeys.contains(winKey($0)) }) { return g }
            let ci = permSrcSlot(di, sid: sid)
            let cur = stackTops[stackTopKey(sid, ci)] ?? 0
            if stack.indices.contains(cur), !oversizeStacked.contains(winKey(stack[cur])), !foldedKeys.contains(winKey(stack[cur])) { return stack[cur] }
            if let alt = stack.first(where: { !oversizeStacked.contains(winKey($0)) && !foldedKeys.contains(winKey($0)) }) { return alt }
            return stack.first
        }
        // 已落位冻结：非换布局轮次且本屏冻结布局有效时，不重解——只按冻结归属
        // 与新窗规则重建方案（frozenSolve），已落位窗的格子、帧、栈归属一律不动；
        // 换布局或几何失效时走正常求解并重新记录冻结布局（见 tile 末尾）。
        let solved: (stacks: [[WinInfo]], tops: [WinInfo?], frames: [CGRect], reduceNote: String?)
        if isFrozenRound, let frozen = frozenLayoutByScreen[sid] {
            solved = frozenSolve(screen: screen, sid: sid, windows: windows, frozen: frozen, activeTopKey: activeTopKey)
        } else {
            solved = solveTopFit(stacks: displayStacks, tops: provisionalTops, screen: screen, sid: sid, openedKeys: userOpenedKeys)
        }
        let didMerge = isFrozenRound ? false : solved.stacks.count != displayStacks.count
        displayStacks = solved.stacks
        let frames = solved.frames
        if didMerge {
            tileSwapPermByScreen.removeValue(forKey: sid)
            // 置换清掉后计算格下标全部重排，旧 pin 会错指别的格，并格时一并清掉（重钉只需再点一次芯片）。
            pinnedTops = pinnedTops.filter { !$0.key.hasPrefix("\(sid):") }
        }
        // 尺寸适配（两步）：格子两维都 ≥ 窗的最小尺寸 → 缩到格子帧置入
        // （摆位循环里写尺寸 + 位置）；任一维 < 最小尺寸 → 折进 Dock。
        // 焦点窗与非焦点窗同一规则（昨日“焦点窗绝不折”已作废）。
        // 折叠不改变所属格与堆叠顺序，只是一个状态旗标；解除只由 Dock 恢复 /
        // 激活恢复触发，格子尺寸变化不自动解折（避免布局一变就弹回盖邻格）。
        // 名义格帧（等分基线）：min 门只判真超格，让位后的小格不触发误折。
        // 冻结轮次：名义格帧即冻结帧（按显示格数等分会算错：关窗留空
        // 的格子不占 shown 叠数，等分基线与冻结几何不一致）。
        let nominalFrames = isFrozenRound ? frames : nominalTileFrames(count: displayStacks.count, screen: screen)
        for (i, stack) in displayStacks.enumerated() {
            let slot = frames.indices.contains(i) ? frames[i] : vf
            let nominalSlot = nominalFrames.indices.contains(i) ? nominalFrames[i] : slot
            // 几何不稳定期不折（瞬态几何不触发连锁折叠），但超格窗记入
            // 推迟集、稳定后由 tick 补折，不再静默丢失。
            if !geometryStable() {
                // 一shot 模式不进推迟集：先试缩流程下，超格与否由写后读回定，
                // 推迟集只会让 deferredFoldDue 在稳定后误触发 forceTile。
                for w in stack where !oneShotActive && isFoldOversize(w, slot: nominalSlot) {
                    let k = winKey(w)
                    if deferredFoldKeys.insert(k).inserted {
                        log("fold deferred: \(w.appName) (geometry unstable, retry when stable)")
                    }
                }
                continue
            }
            // 推迟集清账：已不超格的窗不再是推迟对象，否则稳定后 tick 会反复误触发 forceTile。
            for w in stack where !isFoldOversize(w, slot: nominalSlot) {
                deferredFoldKeys.remove(winKey(w))
            }
            // 超格一律折：Pin / 用户打开窗都不豁免（窗口之间不得重叠）。
            for w in stack where isFoldOversize(w, slot: nominalSlot) {
                let k = winKey(w)
                if oneShotActive {
                    // 一shot算阶段：不再凭最小尺寸在写前判折叠。已学最小尺寸
                    // 可能不准（快照帧、旧版本学值、AX 未报），写前判折会把能缩
                    // 的窗也折掉。先试缩流程：本轮只记摆位，写后读回一次，
                    // 真拒缩才由写阶段复核定为 Dock（见 applyOneShotPlan）。
                    continue
                }
                // 先藏再记：最小化失败不进折叠集（fail-safe），仍按旧守卫处理。
                guard hideFoldedWindow(w) else { continue }
                if !foldedKeys.contains(k) {
                    markFolded(key: k, sid: sid)
                    userOpenedKeys.remove(k)
                    let need = effectiveMin(for: w)
                    log("fold (oversize): \(w.appName) min \(Int(need.width))x\(Int(need.height)) > slot \(Int(nominalSlot.width))x\(Int(nominalSlot.height))")
                }
            }
        }
        // 每格显示顶：第一个未折叠成员（从求解顶起循环找）；整格全折时回退首位（仅记账，不摆位）。
        // 预检（焦点扩格、两两复核）会折叠捐格并拨动显示顶，故为 var。
        var displayTopIdx: [Int] = displayStacks.indices.map { i in
            let stack = displayStacks[i]
            guard !stack.isEmpty else { return 0 }
            let start = (solved.tops.indices.contains(i) ? solved.tops[i] : nil).flatMap { t in
                stack.firstIndex(where: { winKey($0) == winKey(t) })
            } ?? 0
            for off in 0..<stack.count {
                let idx = (start + off) % stack.count
                if !foldedKeys.contains(winKey(stack[idx])) { return idx }
            }
            return 0
        }
        // 一shot算阶段收尾：互不重叠校验（纯计算，不写 AX）。
        // 可见帧只算各格显示顶：栈内非顶成员共用格帧、只露顶，算遮挡不算
        // 重叠，不进校验；Float 居中帧、Focus 功能铺满帧是用户主动的覆盖态。
        // 窗口之间绝不重叠：相交就折掉后一格，Pin / 用户打开窗都不豁免。
        // effFrames 恒等于求解帧（焦点扩格已拆，不再有扩格帧）。
        let effFrames = frames
        if oneShotActive {
            // 本轮可见顶：从显示顶起循环找第一个未折叠成员；整格全折则无可见顶。
            func visibleTopIndex(_ stack: [WinInfo], start: Int) -> Int? {
                guard !stack.isEmpty else { return nil }
                for off in 0..<stack.count {
                    let idx = (start + off) % stack.count
                    if !foldedKeys.contains(winKey(stack[idx])) { return idx }
                }
                return nil
            }
            // 折一格全部未折叠成员，并把显示顶拨到首个剩余未折叠成员；
            // 整格全折时回退首位（仅记账）。折掉的窗留存态一并结束。
            func foldWholeStack(_ j: Int, slot: CGRect, why: String) {
                guard displayStacks.indices.contains(j) else { return }
                for m in displayStacks[j] where !foldedKeys.contains(winKey(m)) {
                    let need = effectiveMin(for: m)
                    oneShotFolds.append(OneShotFold(win: m, sid: sid, need: need, slot: slot))
                    foldedKeys.insert(winKey(m))
                    foldedScreenByKey[winKey(m)] = sid
                    userOpenedKeys.remove(winKey(m))
                }
                if let nt = visibleTopIndex(displayStacks[j], start: 0) {
                    displayTopIdx[j] = nt
                } else if displayStacks[j].indices.contains(0) {
                    displayTopIdx[j] = 0
                }
                log("oneshot overlap resolved: \(why)")
            }
            // 一格是否可整格折掉：只要还有未折叠成员即可。
            // Pin / 用户打开窗都不再豁免——任何窗都不许盖住邻格。
            func foldableStack(_ j: Int) -> Bool {
                guard displayStacks.indices.contains(j) else { return false }
                return displayStacks[j].contains { !foldedKeys.contains(winKey($0)) }
            }
            // 焦点窗与非焦点窗同一规则：焦点窗不再靠扩格、压邻格、
            // 折邻格或盖邻格留在屏上；超格即按尺寸适配规则折进 Dock。
            // （昨日焦点硬约束机器已拆：压邻格 / 折邻格 / 清同带 /
            //  焦点格扩格 effFrames 全部删除，effFrames 恒等于求解帧。）
            // 两两复核（安全网）：可见顶之间不得相交。格子帧本身互不相
            // 交，正常情况零相交；残留相交时折后一格整格。
            struct VisibleEntry { let idx: Int; let key: String; let frame: CGRect }
            var visible: [VisibleEntry] = []
            for j in displayStacks.indices {
                guard let ti = visibleTopIndex(displayStacks[j], start: displayTopIdx.indices.contains(j) ? displayTopIdx[j] : 0) else { continue }
                let top = displayStacks[j][ti]
                let frame = effFrames.indices.contains(j) ? effFrames[j] : vf
                visible.append(VisibleEntry(idx: j, key: winKey(top), frame: frame))
            }
            for a in visible.indices {
                for b in visible.indices where b > a {
                    let ea = visible[a], eb = visible[b]
                    // 同格的顶与成员共用一格、只露顶，算遮挡不算重叠，不复核。
                    guard ea.idx != eb.idx else { continue }
                    // 本轮已折空的格不再参与复核（快照已旧）。
                    guard !displayStacks[ea.idx].allSatisfy({ foldedKeys.contains(winKey($0)) }),
                          !displayStacks[eb.idx].allSatisfy({ foldedKeys.contains(winKey($0)) }) else { continue }
                    guard differentPanesIntersect(ea.frame, eb.frame) else { continue }
                    if foldableStack(eb.idx) {
                        foldWholeStack(eb.idx, slot: eb.frame, why: "pairwise overlap, later tile folded")
                    } else if foldableStack(ea.idx) {
                        foldWholeStack(ea.idx, slot: ea.frame, why: "pairwise overlap, earlier tile folded")
                    } else {
                        log("oneshot overlap kept: no foldable tile (\(ea.key) vs \(eb.key))")
                    }
                }
            }
        }
        // 顶下标写回计算格（并格后置换已清，显示格即计算格）；写回的是显示顶（未折叠），
        // 故后续 lastTilesByScreen 的顶与摆位提顶读到的都是显示顶。
        for (di, stack) in displayStacks.enumerated() {
            guard displayTopIdx.indices.contains(di), stack.indices.contains(displayTopIdx[di]) else { continue }
            let ci = didMerge ? di : permSrcSlot(di, sid: sid)
            stackTops[stackTopKey(sid, ci)] = displayTopIdx[di]
        }
        // 并格后活动格按含活动窗的格重算；降格只在格数变化时 toast 一次（capacity note 口径）。
        displayActive = displayStacks.firstIndex(where: { $0.contains(where: { winKey($0) == activeTopKey }) }) ?? min(displayActive, max(0, displayStacks.count - 1))
        if let note = solved.reduceNote {
            if lastSolvedCountByScreen[sid] != displayStacks.count {
                lastSolvedCountByScreen[sid] = displayStacks.count
                showToast("Tile count reduced", detail: note, on: screen)
            }
        } else {
            lastSolvedCountByScreen[sid] = displayStacks.count
        }
        let animateMoves = draggingDividerID == nil
        lastPanesByScreen[sid] = displayStacks.indices.map { effFrames.indices.contains($0) ? effFrames[$0] : vf }
        var placedStacks: [[WinInfo]] = Array(repeating: [], count: displayStacks.count)
        for (i, stack) in displayStacks.enumerated() {
            let slot = effFrames.indices.contains(i) ? effFrames[i] : vf
            for w in stack {
                let key = winKey(w)
                if oneShotActive, foldedKeys.contains(key) {
                    // 已折叠 / 本轮新定的折叠：算阶段不摆位，写阶段统一执行。
                    // Pin 不解除折叠：折进 Dock 的窗不许再回来盖邻格。
                    placedStacks[i].append(w)
                    continue
                }
                if foldedKeys.contains(key) {
                    // 折叠窗不摆位：真窗口最小化隐藏；仍保留在叠里（翻堆顺序不动）。
                    // 最小化失败（或被系统恢复可见后又拒绝再藏）时 fail-safe：撤出折叠集、
                    // 落到下面的普通摆位，旧守卫（demote / member-only）继续处理它；
                    // 绝不出现“以为折了、窗还看得见”。Pin 不再解除折叠。
                    if hideFoldedWindow(w) {
                        placedStacks[i].append(w)
                        continue
                    } else {
                        foldedKeys.remove(key)
                        foldedMinimizedKeys.remove(key)
                        foldedElements.removeValue(forKey: key)
                        log("fold minimize failed: \(w.appName), unfolded for fallback")
                    }
                }
                if oneShotActive {
                    // 一shot算阶段：只记方案，不写 AX。每扇窗都记目标格帧，
                    // 写阶段按稳定顺序一次写完；真拒缩的由写阶段读回复核折进 Dock。
                    // 尺寸适配两步：格子两维 ≥ 最小尺寸即缩到格子帧置入（本行），
                    // 任一维 < 最小尺寸的已在折叠循环里定为 Dock，不会走到这里。
                    // 复核对象是全体落位窗（含栈内非顶成员）：成员藏在邻格窗口后面
                    // 也不算合规，读回超格同样折进 Dock。
                    oneShotPlacements.append(OneShotPlacement(win: w, frame: slot))
                    placedStacks[i].append(w)
                    continue
                }
                // 已落位冻结窗：非一shot 路径也不重写（冻结帧即落点；当前帧
                // 记为已落点，tick 不弹回）。一shot 路径由写阶段 frameMatchesSlot 跳过。
                if isFrozenWindowKey(key) {
                    lastPlacedFrames[key] = w.frame
                    placedStacks[i].append(w)
                    continue
                }
                // 最小尺寸再大也写入这一格。AX 若拒绝缩小，harden 会再写几次。
                let preSize = getSize(w.element)
                placeFrame(w.element, slot, key: key, animated: animateMoves, learnName: w.appName, preSize: preSize, slot: slot, minSize: .zero)
                lastPlacedFrames[key] = slot
                placedStacks[i].append(w)
            }
        }
        let shownStacks = placedStacks.enumerated().filter { !$0.element.isEmpty }
        // 摆完一叠后把栈顶提到最前：写帧时系统可能把刚动过的成员提到前面，
        // 不显式提一次的话，用户看到的是压在格子外面的大窗口，而不是铺满格子的那扇。
        if oneShotActive {
            // 一shot算阶段不提窗：各栈顶记到写阶段统一提一次。
            for (i, stack) in displayStacks.enumerated() {
                let topIndex = min(stackTops[stackTopKey(sid, permSrcSlot(i, sid: sid))] ?? 0, stack.count - 1)
                if stack.indices.contains(max(0, topIndex)) {
                    oneShotRaiseTops.append(stack[max(0, topIndex)])
                }
            }
        } else {
            for (i, stack) in displayStacks.enumerated() where stack.count > 1 {
                let topIndex = min(stackTops[stackTopKey(sid, permSrcSlot(i, sid: sid))] ?? 0, stack.count - 1)
                AXUIElementPerformAction(stack[max(0, topIndex)].element, kAXRaiseAction as CFString)
            }
        }
        // AX 拒绝缩到格子里的窗口：布局时求解循环已按顶验证（调份额/并格/成员-only），落点后仍不精确一致的
        // 由落定复核（demote）与 tick 守卫按“卡住”记标记、触发重算，不留在格子里违规、不盖住邻格。
        lastVFByScreen[sid] = vf
        lastScreenFrameByScreen[sid] = screen.frame
        let shownActive = shownStacks.firstIndex(where: { displayStacks.indices.contains($0.offset) && displayActive == $0.offset }) ?? 0
        lastActiveTileByScreen[sid] = shownStacks.isEmpty ? 0 : shownActive
        lastTilesByScreen[sid] = shownStacks.map { pair in
            let s = pair.element
            let topIndex = min(stackTops[stackTopKey(sid, permSrcSlot(pair.offset, sid: sid))] ?? 0, s.count - 1)
            let top = s[max(0, topIndex)]
            let shown = oneShotActive
                ? (effFrames.indices.contains(pair.offset) ? effFrames[pair.offset] : vf)
                : (inFlightFrame(key: winKey(top)) ?? (frames.indices.contains(pair.offset) ? frames[pair.offset] : vf))
            return (stack: s, frame: shown, top: top)
        }
        if refreshOverlays {
            refreshGrips()
            refreshDimLayers()
            refreshDotHandles()
            refreshStackMarkers()
        }
        let tileDesc = displayStacks.enumerated().map { (i, s) in
            let names = Dictionary(grouping: s, by: { $0.appName })
                .map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: "+")
            return "tile\(i)[\(s.count)]:\(names)"
        }.joined(separator: " ")
        if !dragQuiet {
            log("tiled screen=\(screenName(screen)) \(windows.count) windows limit=\(st.tileLimit) saved=\(globalSettings.tileLimit) tiles=\(displayStacks.count) active=\(displayActive) \(tileDesc)")
        }
        // 已落位冻结记录：本轮终态（显示顺序）翻回计算格顺序存档。
        // 全量轮次重算几何+归属；冻结轮次几何不变、只更新归属
        // （新窗进格/关窗留空/点开回格都由此沉淀，下轮不再重算）。
        // Focus/清屏提前返回的轮次不到这里，不动旧记录。
        do {
            // 空格子不写回冻结布局：空格只可能是那一叠的窗全从 live 列表消失，
            // 但关窗当轮 CG 可能还列着它，剪格没能落地。这时若把空归属写回去，
            // 死窗的键就被抹掉，下一轮补验找不到证据，格子会永久留空洞。
            // 保留旧记录，等 CG 真丢掉它后由剪格逻辑把这一格剪掉。
            let hasEmptyStack = displayStacks.contains { $0.isEmpty }
            var computeFrames: [CGRect] = Array(repeating: vf, count: displayStacks.count)
            var computeAssignment: [[String]] = Array(repeating: [], count: displayStacks.count)
            var computeTopKeys: [String?] = Array(repeating: nil, count: displayStacks.count)
            for di in displayStacks.indices {
                let ci = permSrcSlot(di, sid: sid)
                if computeFrames.indices.contains(ci) {
                    computeFrames[ci] = effFrames.indices.contains(di) ? effFrames[di] : vf
                    computeAssignment[ci] = displayStacks[di].map { winKey($0) }
                    if displayTopIdx.indices.contains(di), displayStacks[di].indices.contains(displayTopIdx[di]) {
                        computeTopKeys[ci] = winKey(displayStacks[di][displayTopIdx[di]])
                    }
                }
            }
            // 置换已清（并格）时 permSrcSlot 即恒等，存档与显示顺序一致。
            if !hasEmptyStack {
                frozenLayoutByScreen[sid] = FrozenLayout(tileFrames: computeFrames, assignment: computeAssignment, topKeys: computeTopKeys)
            }
        }
        // 自动可见性路径已删：tile 末尾只剩落定复核（transient 守卫），不再有独占→浮动转换分发。
        // 一shot算阶段跳过落定复核与 z 序归一化：两者都读实时帧 / 写 AX 并可能异步
        // 触发下一轮重算，会破坏“切换写完即停”；写阶段统一提栈顶一次。
        if !oneShotActive {
            demoteOverflowingStackTops()
        }
        // z 序归一化：格顶一律高于成员（见 normalizeTopZOrder），覆盖求解/摆位/换顶后经 forceTile 的一切路径。
        // 一shot算阶段跳过（见上）；写阶段统一提栈顶一次。
        if !oneShotActive {
            normalizeTopZOrder(sid: sid)
        }
    }

    // 弹簧落定后复核每叠栈顶：应用拒绝缩小的成员会顶在格子外面，横着盖住邻格。
    // 这时把栈顶换成这一叠里「实际落进格子」的另一扇并提到最前，让用户看到的是铺满格子的那扇；
    // 大窗口仍留在叠里，用悬停条芯片切。用户亲手选过的栈顶不动。
    // 约束自适应平铺补两条：无可抬成员且卡住 → 记成员-only、异步重算（求解接手）；
    // 单窗格卡住 → 只记固定尺寸嫌疑（若符合），最小尺寸拒绝交给求解并格。Focus 期间这两条不动。
    /// 固定尺寸嫌疑：实际帧 ≈ 最小尺寸、且至少一轴小于格子（拒绝放大）→ 记 fixedSizeKeys，
    /// 求解下次对它按精确尺寸判（格子按它定）。超格轴顶在最小尺寸是普通最小尺寸拒绝，不记。
    /// 返回 true 表示新记入（调用方据此触发重算）。
    func noteFixedSizeIfSuspected(_ w: WinInfo, actual: CGRect, slot: CGRect) -> Bool {
        let need = effectiveMin(for: w)
        let key = winKey(w)
        guard !fixedSizeKeys.contains(key) else { return false }
        guard abs(actual.width - need.width) <= 1.5, abs(actual.height - need.height) <= 1.5 else { return false }
        guard actual.width < slot.width - 1.5 || actual.height < slot.height - 1.5 else { return false }
        fixedSizeKeys.insert(key)
        log("fixed-size suspected: \(w.appName) \(Int(actual.width))x\(Int(actual.height)) refuses to enlarge")
        return true
    }

    // Transient 守卫（约束自适应平铺）：平时不应触发，只覆盖摆位/动画中途与窗口最小尺寸突变。
    // 主路径是求解循环（solveTopFit）；这里只做两件事：
    // 1. 顶在摆位中途探出格子且有贴合成员 → 换顶（旧 demote 行为，瞬态）；
    // 2. 顶卡住（exactnessStuck）→ 记标记、异步重算，让求解循环处理（换顶/并格/成员-only），
    //    不再进独占组、不隐藏、不最小化。Focus 期间不动。
    func demoteOverflowingStackTops() {
        guard frameMotions.isEmpty else { return }
        let mh = mainHeight()
        var changed = false
        var newMarks = false
        for (sid, tiles) in lastTilesByScreen {
            guard let panes = lastPanesByScreen[sid], panes.count >= tiles.count else { continue }
            var arr = tiles
            var localChanged = false
            for i in arr.indices where arr[i].stack.count > 1 {
                let key = stackTopKey(sid, permSrcSlot(i, sid: sid))
                let stack = arr[i].stack
                let top = arr[i].top
                // 折叠顶不复核：它已最小化隐藏，帧与格子必然不匹配，复核只会误记标记。
                guard !foldedKeys.contains(winKey(top)) else { continue }
                // 焦点顶不复核：焦点规则——正在用的窗不 demote、不折叠，焦点离开后再正常处理。
                // 已落位冻结顶同豁免：推回是恢复冻结帧（非重算）。
                // 固定顶与用户打开顶不再豁免：盖住邻格同样要换顶/折叠（窗口之间不得重叠）。
                if winKey(top) == frontFocusKeyForPass || isFrozenWindowKey(winKey(top)) { continue }
                if let pin = pinnedTops[key] {
                    if stack.contains(where: { winKey($0) == pin }) { continue }
                    pinnedTops.removeValue(forKey: key)
                }
                guard let actual = getFrame(top.element, screenHeight: mh) else { continue }
                if frameMatchesSlot(actual, pane: panes[i]) {
                    exactWatch.removeValue(forKey: winKey(top))
                }
                let memberFrames = stack.map { getFrame($0.element, screenHeight: mh) ?? .zero }
                let cur = stack.firstIndex(where: { winKey($0) == winKey(top) }) ?? 0
                if let alt = stackTopToPromote(top: cur, frames: memberFrames, pane: panes[i]) {
                    stackTops[key] = alt
                    AXUIElementPerformAction(stack[alt].element, kAXRaiseAction as CFString)
                    arr[i].top = stack[alt]
                    localChanged = true
                    logDiag("stack top demoted: \(top.appName) \(Int(actual.width))x\(Int(actual.height)) outside \(Int(panes[i].width))x\(Int(panes[i].height)), raised \(stack[alt].appName)")
                    // 已触发 demote 视同安定超格：被换下的顶不再以成员身份留在格里盖邻格，
                    // 立即折叠到 Dock（新标记触发异步重算）；旧 demote 逻辑不动。
                    // 先藏再记：最小化失败不进折叠集（fail-safe），旧守卫继续处理。
                    let dtkey = winKey(top)
                    if !foldedKeys.contains(dtkey), geometryStable(), hideFoldedWindow(top) {
                        markFolded(key: dtkey, sid: sid)
                        newMarks = true
                        log("fold (demoted): \(top.appName) demoted from its tile")
                    }
                } else if focusKey == nil,
                          !frameMatchesSlot(actual, pane: panes[i]),
                          exactnessStuck(key: winKey(top), actual: actual, slot: panes[i], need: effectiveMin(for: top)) {
                    // 无可抬成员且卡住：记成员-only（求解下次跳过它当顶），固定尺寸嫌疑另记；
                    // Focus 期间不动（落定复核也可能由弹簧完成回调进来，Focus 屏不归这里管）。
                    if noteFixedSizeIfSuspected(top, actual: actual, slot: panes[i]) { newMarks = true }
                    let tkey = winKey(top)
                    if !oversizeStacked.contains(tkey) {
                        oversizeStacked.insert(tkey)
                        oversizeHost[tkey] = stack.first(where: { winKey($0) != tkey }).map { winKey($0) } ?? ""
                        newMarks = true
                    }
                    // 同换顶分支：已触发 member-only 标记视同安定超格，立即折叠到 Dock。
                    // 先藏再记：最小化失败不进折叠集（fail-safe），旧守卫继续处理。
                    if !foldedKeys.contains(tkey), geometryStable(), hideFoldedWindow(top) {
                        markFolded(key: tkey, sid: sid)
                        newMarks = true
                        log("fold (stuck): \(top.appName) cannot match its tile")
                    }
                    log("stack top marked member-only: \(top.appName) cannot match its tile")
                }
            }
            // 独占格（只有一扇）：卡住时只记固定尺寸嫌疑（若符合），最小尺寸拒绝交给求解并格；
            // 不再踢出格子。Focus 期间不动。
            if focusKey == nil {
                for i in arr.indices where arr[i].stack.count == 1 {
                    let w = arr[i].top
                    // 折叠窗不复核（同上）。
                    guard !foldedKeys.contains(winKey(w)) else { continue }
                    guard let actual = getFrame(w.element, screenHeight: mh) else { continue }
                    let pane = panes[i]
                    if frameMatchesSlot(actual, pane: pane) {
                        exactWatch.removeValue(forKey: winKey(w))
                        continue
                    }
                    if exactnessStuck(key: winKey(w), actual: actual, slot: pane, need: effectiveMin(for: w)) {
                        if noteFixedSizeIfSuspected(w, actual: actual, slot: pane) { newMarks = true }
                        log("lone tile stuck: \(w.appName) cannot match its tile, left for solve")
                    }
                }
            }
            if localChanged { lastTilesByScreen[sid] = arr; changed = true }
        }
        if changed {
            refreshGrips()
            refreshDotHandles()
            refreshStackMarkers()
        }
        // 新标记才异步重算（求解循环接手）；无新标记不触发，避免 demote → tile → demote 循环。
        if newMarks {
            DispatchQueue.main.async { [weak self] in self?.forceTile() }
        }
    }

    // z 序归一化：把本屏所有格的顶一律抬到所有堆叠成员之上。
    // 成员帧再大（最小尺寸顶住、无法缩小）也被顶集合完全盖住，不可见——
    // 这才是「成员被顶盖住」成立的 z 序前提；只靠帧几何（同格同帧）不够，
    // 成员若最近激活过，z 序可能高于邻格顶，右侧就可见地盖住邻格。
    // 单窗格的顶也一并提（旧循环只提多窗叠的顶）。
    // 调用点：tile() 末尾（demote 之后）。弹簧落定后的 demote 本身只提新顶，
    // 不另做归一化：新顶被提到最前已满足本屏不变量，其余成员仍在上次归一化确立的顶之下。
    // Focus 期间不动（专注窗必须在最上）；前台在布局之外的 App 时顺延到下次重排，
    // 避免把用户正在用的非布局窗口埋到格顶之下。
    // 手动浮动窗最后再提一次，保持在布局之上（collectWindows 默认只列当前 Space）。
    func normalizeTopZOrder(sid: CGDirectDisplayID) {
        guard focusKey == nil else { return }
        guard let tiles = lastTilesByScreen[sid], !tiles.isEmpty else { return }
        let tiledPids = Set(tiles.flatMap { $0.stack.map { $0.pid } })
        let floatedPids: Set<pid_t> = Set(floatedKeys.compactMap { key in
            guard let bar = key.firstIndex(of: "#") ?? key.firstIndex(of: "|"),
                  let pid = pid_t(key[key.startIndex..<bar]) else { return nil }
            return pid
        })
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           front != ProcessInfo.processInfo.processIdentifier,
           !tiledPids.contains(front), !floatedPids.contains(front) {
            return
        }
        for t in tiles {
            AXUIElementPerformAction(t.top.element, kAXRaiseAction as CFString)
        }
        if !floatedKeys.isEmpty {
            for w in collectWindows(includeFloated: true)
                where floatedKeys.contains(winKey(w)) && screenID(screenForFrame(w.frame)) == sid {
                AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
            }
        }
        // 固定窗最后再提一次：固定窗超格盖邻格，须在格顶之上才可见，否则会被邻格顶
        // 盖住、固定看起来像没生效。Focus 期间本函数已提前返回，不干扰专注窗。
        if !pinnedWindowKeys.isEmpty {
            for w in collectWindows(includeFloated: true)
                where pinnedWindowKeys.contains(winKey(w)) && screenID(screenForFrame(w.frame)) == sid {
                AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
            }
        }
    }

    // MARK: - 焦点规则 / 折叠记账 / 几何稳定（2026-10-29 三件同轮）
    /// 本轮前台焦点窗键：复用 resolveCurrentTarget 的口径（前台 App 的 AX 焦点窗，
    /// 对不上退回该 App 第一扇受管窗），但用调用方本轮已采集的窗口，不重复枚举。
    /// 定不出返回 nil（调用方只跳过折叠，不 fallback 到别的窗）。
    /// 注意与 Focus 功能的 focusKey 不同：那是专注模式目标，这里是“正在用的窗”。
    func frontFocusKey(windows: [WinInfo]) -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        if let idx = focusedIndex(windows: windows), windows[idx].pid == app.processIdentifier {
            return winKey(windows[idx])
        }
        return windows.first(where: { $0.pid == app.processIdentifier }).map { winKey($0) }
    }

    /// 折叠记账统一口：调用方已验 hideFoldedWindow 成功（先藏）再记；同时记原属屏
    /// （最小化后 AX 帧不可靠，tileAll 据此归位）。
    func markFolded(key: String, sid: CGDirectDisplayID) {
        foldedKeys.insert(key)
        foldedScreenByKey[key] = sid
    }

    /// 名义格帧：等分基线（share 0.5），不含求解器的份额收敛与让位调整。
    /// 折叠门（min 门/帧门）以此为准：只有真正超名义格的窗才算超格；
    /// 仅超让位后小格的窗是求解器的事（重分份额/并格），不由折叠门处理
    /// （2026-10-29 级联：让位把格压到 738，正常窗 744 被帧门误折）。
    func nominalTileFrames(count: Int, screen: NSScreen) -> [CGRect] {
        let st = layoutSettings(for: screen)
        return layoutFrames(count: count, vf: screen.visibleFrame, kind: st.kind, share: 0.5, gap: st.gap)
    }

    /// 几何不稳定期推迟的折叠是否已可补：稳定、且仍有推迟窗可见并超格。
    /// 顺带裁剪已不存在 / 已折叠 / 已不超格的推迟键，避免误触发。
    /// 注意不用 geometryStable()（它在不稳定期记节流日志，这里只是复核，不记）。
    func deferredFoldDue(windows: [WinInfo]) -> Bool {
        guard Date().timeIntervalSince(geometryChangedAt) >= 2.0, !deferredFoldKeys.isEmpty else { return false }
        var due = false
        for key in Array(deferredFoldKeys) {
            guard let w = windows.first(where: { winKey($0) == key }), !foldedKeys.contains(key),
                  !pinnedWindowKeys.contains(key), !userOpenedKeys.contains(key) else {
                deferredFoldKeys.remove(key)
                continue
            }
            let sid = screenID(screenForFrame(w.frame))
            guard let screen = NSScreen.screens.first(where: { screenID($0) == sid }),
                  let tiles = lastTilesByScreen[sid],
                  let idx = tiles.firstIndex(where: { $0.stack.contains { winKey($0) == key } }) else { continue }
            let nominal = nominalTileFrames(count: tiles.count, screen: screen)
            guard nominal.indices.contains(idx), isFoldOversize(w, slot: nominal[idx]) else {
                deferredFoldKeys.remove(key)
                continue
            }
            due = true
        }
        return due
    }

    /// 几何稳定：任一屏可视区/屏帧变化后 2 秒内不折叠（显示切换瞬态几何不触发连锁折叠）。
    /// 节流日志：不稳定期间每秒最多记一次，避免洪水刷屏。
    func geometryStable() -> Bool {
        let stable = Date().timeIntervalSince(geometryChangedAt) >= 2.0
        if !stable, Date().timeIntervalSince(lastGeometrySkipLogAt) >= 1.0 {
            lastGeometrySkipLogAt = Date()
            log("fold skipped: geometry unstable")
        }
        return stable
    }

    /// 屏幕参数变化去抖：显示切换常连发多次通知，逐条立即重排会用瞬态几何连锁折叠；
    /// 0.5 秒安静后只重排一次（日志仍逐条记，保留诊断信号）。
    func scheduleScreenChangeRetile() {
        screenChangeRetileTimer?.invalidate()
        screenChangeRetileTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.screenChangeRetileTimer = nil
            // 屏幕通知是放大器不是根因：无真实变化时不重排，否则每轮写帧
            // 激起的通知会 0.5 秒后又触发 forceTile，绕过 tick 签名门。
            // 真实变化 = 窗口集合签名变，或任一屏可视区/屏帧变（Dock 显隐
            // 只改可视区不改窗口数，也必须重排）。
            let sigChanged = self.fullSignature() != self.lastSignature
            var geoChanged = false
            for s in NSScreen.screens {
                let sid = self.screenID(s)
                if let prevVF = self.lastVFByScreen[sid], prevVF != s.visibleFrame { geoChanged = true }
                if let prevF = self.lastScreenFrameByScreen[sid], prevF != s.frame { geoChanged = true }
            }
            if sigChanged || geoChanged { self.forceTile() }
        }
    }

    // MARK: - 折叠记账（最小化到 Dock）
    /// 超尺寸判定：任一轴最小尺寸超出格子（容差 1.5pt，与 topFitsSlot 同口径）。
    /// 注意不用 topFitsSlot：固定尺寸窗（格子大于其精确尺寸）不算超格，不能折。
    func isFoldOversize(_ w: WinInfo, slot: CGRect) -> Bool {
        // 实际帧已经在格内：不论最小尺寸记录怎么写都不折（固定尺寸窗被误折的根因——
        // 它声明 0x0 / 报错的下限却拒绝放大，记录和现实不一致）。
        if frameIsInsidePane(w.frame, pane: slot) { return false }
        let need = effectiveMin(for: w)
        if need.width > 1, need.width > slot.width + 1.5 { return true }
        if need.height > 1, need.height > slot.height + 1.5 { return true }
        return false
    }

    /// 折叠窗隐藏：最小化（AX kAXMinimizedAttribute 置 true），并轮询验确实已最小化（上限约 1 秒）。
    /// 返回 true = 确实藏起来了；false = 最小化失败，调用方不得将其置入 foldedKeys
    /// （fail-safe：求解器绝不能以为折了、窗还看得见；失败窗仍按旧守卫处理）。
    /// 已最小化的窗不再重复写（Dock 动画只跑一次）；用户亲手从 Dock 恢复的折叠窗，
    /// 留存期内不重折（固定窗豁免同理；留存只在切族/改上限、窗关闭、用户亲手最小化时清掉）。
    /// 旧屏外停放已删：系统会挡回屏外位置却写进尺寸（800x600 的块堆在格子原点），
    /// 求解器以为折走、现实还在屏上，模型一脱节布局就炸掉——最小化是唯一可靠的隐藏。
    func hideFoldedWindow(_ w: WinInfo) -> Bool {
        let key = winKey(w)
        if boolAttr(w.element, kAXMinimizedAttribute as CFString) {
            foldedMinimizedKeys.insert(key)
            foldedElements[key] = w.element
            return true
        }
        let err = AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        // 最小化是异步提交的：置属性只代表请求被接受，WindowServer/目标应用实际藏起
        // 窗口需要一段时间；立即重读会看到还没藏起来的窗，全应用 err=0 失败就是这么
        // 来的（2026-10-29 真机：授权已到、置调用无错、读已最小化窗本身是好的——采集
        // 里 Dock 窗能正确跳过）。故置成功后轮询复核（40×25ms，上限约 1 秒，早到早返），
        // 只有确实读到已最小化才算藏好；上限内没翻过来仍判失败，fail-safe 不变。
        // 轮询只走置属性这条新折叠路径；已折叠窗每轮的复核走上面的已最小化早返，
        // 不轮询、不阻塞稳态 tick。
        if err == .success {
            for _ in 0..<40 {
                if boolAttr(w.element, kAXMinimizedAttribute as CFString) {
                    foldedMinimizedKeys.insert(key)
                    foldedElements[key] = w.element
                    return true
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
        log("fold minimize failed: \(w.appName) err=\(err.rawValue)")
        return false
    }

    /// 取消一扇折叠窗的最小化（展开路径用）。返回 true = 已恢复可见（或本来就可见）。
    func unminimizeFoldedWindow(element: AXUIElement, key: String) -> Bool {
        if !boolAttr(element, kAXMinimizedAttribute as CFString) {
            foldedMinimizedKeys.remove(key)
            return true
        }
        let err = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        // 与最小化同理：取消最小化也是异步提交，立即重读会误判；置成功后轮询复核。
        if err == .success {
            for _ in 0..<40 {
                if !boolAttr(element, kAXMinimizedAttribute as CFString) {
                    foldedMinimizedKeys.remove(key)
                    return true
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
        log("fold unminimize failed: key=\(key) err=\(err.rawValue)")
        return false
    }

    /// 折叠存活裁剪（仿 pruneFloated 的宽口径：当前 Space AX 列表 + 全 Space CG 列表，
    /// 否则切 Space 后折叠态会被误清；单按存活判）。
    func pruneFolded(allKeys: Set<String>) {
        guard AXIsProcessTrusted() else { return }
        let wide = allSpaceWindowKeys()
        var alive = allKeys
        alive.formUnion(wide.keys)
        let alivePids = wide.pids
        func isAlive(_ key: String) -> Bool {
            if alive.contains(key) { return true }
            guard let bar = key.firstIndex(of: "|"), let pid = pid_t(key[key.startIndex..<bar]) else { return false }
            return alivePids.contains(pid)
        }
        // 原属屏表不随 foldedKeys 为空而残留：解除后窗帧已真实，残留条目会在跨屏后错分；
        // 同一 tileAll 内归位已先跑过（归位在裁剪之前），此处清掉不影响过渡。
        foldedScreenByKey = foldedScreenByKey.filter { foldedKeys.contains($0.key) }
        guard !foldedKeys.isEmpty else { return }
        let before = foldedKeys.count
        foldedKeys = foldedKeys.filter(isAlive)
        foldedMinimizedKeys.formIntersection(foldedKeys)
        foldedElements = foldedElements.filter { foldedKeys.contains($0.key) }
        if foldedKeys.count != before {
            log("folded pruned: \(before) -> \(foldedKeys.count)")
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
    var motionLastWritten: [String: (start: CFTimeInterval, frame: CGRect)] = [:]  // 弹簧每窗上次写出的帧（去重写用，以 motion.start 校验代次）
    var opacityFades: [OpacityFade] = []
    var toastPopStart: CFTimeInterval?

    /// 入格弹簧：过冲约 0.16，终点精确为 1。交换不走这条曲线。
    func springUnit(_ t: CGFloat) -> CGFloat {
        tileSpringUnit(t)
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

    /// 精确一致的“卡住”判定：实际帧与格子差 >1.5pt，且窗口已无办法靠自己贴到格子。
    /// - 超格轴（实际比格子大）：实际已顶在 effectiveMin（已知维）→ 缩不下去，立即算卡住。
    ///   未顶最小尺寸的可能是摆位未完成，落到稳定帧判定。
    /// - 欠尺寸轴（实际比格子小）：最小尺寸是下限不是上限，顶在最小尺寸不说明长不大；
    ///   只认“两次观测实际帧不变”（摆位后 post 稳定）→ 拒绝改尺寸，算卡住。
    /// 否则视为摆位/动画中间态：记一笔等下一轮再验，不误判。调用方只在“不精确一致”时调这里。
    /// （类方法：要访问 exactWatch 与 framesClose，不能放在类外的自由函数区。）
    func exactnessStuck(key: String, actual: CGRect, slot: CGRect, need: CGSize) -> Bool {
        let overX = actual.width > slot.width + 1.5
        let overY = actual.height > slot.height + 1.5
        if overX || overY {
            let xStuck = !overX || (need.width > 1 && actual.width <= need.width + 1.5)
            let yStuck = !overY || (need.height > 1 && actual.height <= need.height + 1.5)
            if xStuck && yStuck { return true }
        }
        if let prev = exactWatch[key], framesClose(prev, actual) { return true }
        exactWatch[key] = actual
        return false
    }

    func applyAXFrame(_ el: AXUIElement, _ frame: CGRect) {
        writePaneFrame(el, frame, passes: 1, enhanced: false)
    }

    /// 格子是硬边。按「先尺寸、后位置、再尺寸」写几次。
    /// 很多应用只在第一次 setSize 时用自己的最小尺寸顶回来，跟着再写一次才会停在格子上。
    /// 普通写落不准时才补一次辅助功能增强写（顺序在 writePaneFrame 里）。
    var clampRefusedLog: Set<String> = []
    var lastMismatchLog: [String: String] = [:]  // size mismatch 上次记过的（目标>实际）

    func noteClampRefused(_ name: String, _ actual: CGRect, _ pane: CGRect, key: String) {
        let before = paneRefusals[key] ?? 0
        paneRefusals[key] = before + 1
        lastRefusedFrame[key] = (target: pane, frame: actual)
        let line = "\(name) \(Int(actual.width))x\(Int(actual.height))@\(Int(actual.minX)),\(Int(actual.minY)) pane \(Int(pane.width))x\(Int(pane.height))@\(Int(pane.minX)),\(Int(pane.minY))"
        if clampRefusedLog.insert(line).inserted {
            log("pane clamp refused: \(line)")
        }
        // 落点在重排结束后才量到，下一次重排才会被看到：新拒绝先排一次重排（去抖），让浮动判定拿到这一笔。
        // 拖缝期间不排：重排会重算分组，正在进行的这一次拖动会被判成「stack changed」取消掉。
        if before == 0, draggingDividerID == nil, dragState == nil { scheduleRefusalRetile() }
    }

    func scheduleRefusalRetile() {
        guard !refusalRetileScheduled else { return }
        refusalRetileScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.refusalRetileScheduled = false
            // 0.25 秒里去拖缝了：让这一笔留到松手后的 tick，别把拖动中途的成员集合换掉。
            guard self.draggingDividerID == nil, self.dragState == nil else { return }
            self.forceTile()
        }
    }

    func hardenPaneFrame(_ el: AXUIElement, _ frame: CGRect) {
        writePaneFrame(el, frame, passes: 4, enhanced: true)
    }

    func writePaneFrame(_ el: AXUIElement, _ frame: CGRect, passes: Int, enhanced: Bool) {
        var f = frame
        if f.width < 1 { f.size.width = 1 }
        if f.height < 1 { f.size.height = 1 }
        let pos = CGPoint(x: f.minX, y: mainHeight() - f.maxY)
        let write = {
            let n = max(passes, 1)
            for _ in 0..<n {
                self.setSize(el, f.size)
                self.setPosition(el, pos)
            }
            self.setSize(el, f.size)
        }
        // 普通写先行：Finder 这类应用在 AXEnhancedUserInterface 被恢复的瞬间会把窗口
        // 弹回原帧，Focus 的整屏窗就此落到屏幕外（实测 -9,33 而非 8,41）。
        // 先写普通帧，落准了就不碰 enhanced，省掉这场回弹。
        write()
        guard enhanced else { return }
        if let actual = getFrame(el, screenHeight: mainHeight()), framesClose(actual, f) { return }
        // 少数应用（Chromium/Electron 之类）只有 enhanced 才吃得下写：补一次。
        withEnhancedUserInterface(el, write)
    }

    /// 只包住这一次写入。写完把原来的值放回去，避免把应用的辅助功能状态改掉。
    func withEnhancedUserInterface(_ el: AXUIElement, _ body: () -> Void) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { body(); return }
        let app = AXUIElementCreateApplication(pid)
        let attr = "AXEnhancedUserInterface" as CFString
        var old: CFTypeRef?
        AXUIElementCopyAttributeValue(app, attr, &old)
        AXUIElementSetAttributeValue(app, attr, kCFBooleanTrue)
        body()
        if let old {
            AXUIElementSetAttributeValue(app, attr, old)
        }
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
        // 阈值分两档：1.5pt 起就当作「顶住了」去学下限（终端这类按字符格量化的应用会多出 3pt，
        // 学到之后让位会把格子放大到它真的装得下）；4pt 以上才写诊断日志，免得刷屏。
        if draggingDividerID == nil, let post,
           abs(post.width - target.width) > 1.5 || abs(post.height - target.height) > 1.5 {
            let learned = name.isEmpty ? .zero : (learnedMinSizes[name] ?? .zero)
            let widthKnown = abs(post.width - target.width) <= 4
                || (learned.width > 1 && abs(post.width - learned.width) <= 4 && post.width + 1 >= target.width)
            let heightKnown = abs(post.height - target.height) <= 4
                || (learned.height > 1 && abs(post.height - learned.height) <= 4 && post.height + 1 >= target.height)
            // 已经学过的下限再撞上同一尺寸时不再刷屏。新的差值才记；小差值只学不记。
            // 同一窗同一目标同一实际尺寸只记一次（变化时再记）；学习分支不受影响，照常跑。
            if !(widthKnown && heightKnown),
               abs(post.width - target.width) > 4 || abs(post.height - target.height) > 4 {
                let sig = "\(Int(target.width))x\(Int(target.height))>\(Int(post.width))x\(Int(post.height))"
                if lastMismatchLog[name] != sig {
                    lastMismatchLog[name] = sig
                    logDiag("size mismatch: \(name) pre=\(Int(pre.width))x\(Int(pre.height)) target=\(Int(target.width))x\(Int(target.height)) post=\(Int(post.width))x\(Int(post.height))")
                }
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
                // 只在「真的缩进了更小的格」时忘掉虚高下限；拒绝缩小不学新下限。
                // 把拒缩后的实际尺寸写成下限会毒化整叠：格子被撑大、让位被卡死，
                // 下一次切布局又把它当证据，越用越乱。
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

    /// 缝拖动成功落点后的虚高遗忘：只忘不学。
    /// 条件与 logPlacementMismatch 里的遗忘一致（目标比已学值小 4pt 以上、
    /// 实际落准即与目标差 ≤4pt），但不学新的下限——缝拖动里不写学习值。
    /// 退化目标与瞬态尺寸同样不处理，与 logPlacementMismatch 的守卫一致。
    func forgetInflatedMin(name: String, post: CGSize, target: CGSize) {
        guard !name.isEmpty, var cur = learnedMinSizes[name] else { return }
        guard target.width >= 1, target.height >= 1 else { return }
        guard post.width >= 160, post.height >= 120 else { return }
        var changed = false
        if cur.width > 1, target.width + 4 < cur.width, abs(post.width - target.width) <= 4 {
            cur.width = 0
            changed = true
        }
        if cur.height > 1, target.height + 4 < cur.height, abs(post.height - target.height) <= 4 {
            cur.height = 0
            changed = true
        }
        guard changed else { return }
        if cur.width <= 0, cur.height <= 0 {
            learnedMinSizes.removeValue(forKey: name)
        } else {
            learnedMinSizes[name] = cur
        }
        saveLearnedMinSizes()
        learnedMinChanged = true
        logDiag("min-size forgotten after divider drop: \(name) \(Int(cur.width))x\(Int(cur.height))")
    }

    // 松开（phase 2）时跑一次的虚高遗忘结算：对缝两侧两格的每个成员各读一次
    // 实际帧，按与 logPlacementMismatch 相同的条件清掉虚高下限（只忘不学）。
    // 之所以能放在落点做，是因为缝拖动中已学值不再用来预夹——拖动中不结算，
    // 不影响缝的活动界；落点时结算一次，下次 tile() 就不再按旧值排。
    // AX 未 settled 时读到旧的大尺寸只会跳过遗忘，不会误清。
    func forgetInflatedMinsForDividerDrop(screen: NSScreen, dividerID: String, vertical: Bool) {
        let sid = screenID(screen)
        guard let tiles = lastTilesByScreen[sid], tiles.count >= 2 else { return }
        let frames = tiles.map { $0.frame }
        let g = gapForLayout()
        let half = g / 2
        guard let d = deriveDividers(frames: frames, gap: g, sid: sid).first(where: { $0.id == dividerID && $0.vertical == vertical }) else { return }
        let mh = mainHeight()
        for t in tiles {
            let adjacent = vertical
                ? abs(t.frame.maxX - (d.center - half)) < 1.5 || abs(t.frame.minX - (d.center + half)) < 1.5
                : abs(t.frame.minY - (d.center + half)) < 1.5 || abs(t.frame.maxY - (d.center - half)) < 1.5
            guard adjacent else { continue }
            for w in t.stack {
                guard let post = getFrame(w.element, screenHeight: mh) else { continue }
                forgetInflatedMin(name: w.appName, post: post.size, target: t.frame.size)
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
        let dur = duration ?? (chosen == .settle ? 0.34 : tileSpringDuration)
        let final = containedOrRaw(target, slot: slot, minSize: minSize)
        if animated, let existing = frameMotions[key], framesClose(existing.to, final), existing.ease == chosen {
            return
        }
        let live = inFlightFrame(key: key)
        let from = live ?? getFrame(el, screenHeight: mainHeight()) ?? final
        // 顽固窗停写：上次同一目标已被拒、且当前帧与被拒时一致（布局与窗口都没变），
        // 不再重开弹簧、不再写目标帧、不再验、不再记日志；观测仍在（tick 每轮照常读帧，
        // 折叠帧门依赖观测不受影响）。目标或帧一变即恢复正常重试。
        if live == nil, let refused = lastRefusedFrame[key],
           framesClose(refused.target, final), framesClose(refused.frame, from) {
            stopMotionTimerIfIdle()
            return
        }
        if !animated || framesClose(from, final) {
            frameMotions.removeValue(forKey: key)
            motionLastWritten.removeValue(forKey: key)
            if live == nil, framesClose(from, final) {
                // 已在目标（刚读到的实测帧）：跳过全部 AX 写；验算直接复用刚读到的帧，
                // 拒绝记录与学习与原来走同一分支（学习只在帧确实变化时动作，复用无影响）。
                if let slot, !slot.isEmpty, !frameIsInsidePane(from, pane: final) {
                    noteClampRefused(learnName.isEmpty ? "window" : learnName, from, final, key: key)
                } else if slot != nil {
                    paneRefusals.removeValue(forKey: key)
                    lastRefusedFrame.removeValue(forKey: key)
                }
                if let pre = preSize {
                    logPlacementMismatch(name: learnName, pre: pre, target: final.size, post: from.size)
                }
                stopMotionTimerIfIdle()
                return
            }
            hardenPaneFrame(el, final)
            // 只有写格子时才清点拒绝；浮动落点没有格子可守，量到的差不算顶回。
            if let slot, !slot.isEmpty,
               let actual = getFrame(el, screenHeight: mainHeight()), !frameIsInsidePane(actual, pane: final) {
                noteClampRefused(learnName.isEmpty ? "window" : learnName, actual, final, key: key)
            } else if slot != nil {
                paneRefusals.removeValue(forKey: key)
                lastRefusedFrame.removeValue(forKey: key)
            }
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
        motionLastWritten.removeValue(forKey: key)
        startMotionTimer()
    }

    func startMotionTimer() {
        if motionTimer != nil { return }
        // 节拍对齐显示刷新率：60Hz 定时器在 120Hz ProMotion 屏上每两帧重复一帧，看着抖。
        // 每次建 timer 时重读当前显示能力（ProMotion 会变），上限 120Hz，避免超高刷屏上 AX 写过密；
        // 动画本身按时间插值，节拍只改采样密度，不改时长与曲线。
        let fps = NSScreen.screens.map { $0.maximumFramesPerSecond }.max() ?? 0
        let rate = fps > 0 ? min(fps, 120) : 60
        let timer = Timer(timeInterval: 1.0 / Double(rate), repeats: true) { [weak self] _ in
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
            motionLastWritten.removeAll()
        }
    }

    func stepMotion() {
        let now = CACurrentMediaTime()
        var finished: [String] = []
        // 落定收尾（t>=1 与提前收尾共用）：写最终帧 + 验一次 + 记学习，落点帧与原来完全一致。
        let finishMotion: (String, FrameMotion) -> Void = { key, m in
            self.hardenPaneFrame(m.element, m.to)
            if let slot = m.slot, !slot.isEmpty,
               let actual = self.getFrame(m.element, screenHeight: self.mainHeight()), !frameIsInsidePane(actual, pane: m.to) {
                self.noteClampRefused(m.learnName.isEmpty ? "window" : m.learnName, actual, m.to, key: key)
            } else if m.slot != nil {
                self.paneRefusals.removeValue(forKey: key)
                self.lastRefusedFrame.removeValue(forKey: key)
            }
            if let pre = m.preSize {
                self.logPlacementMismatch(name: m.learnName, pre: pre, target: m.to.size, post: self.getSize(m.element))
            }
            self.motionLastWritten.removeValue(forKey: key)
            finished.append(key)
        }
        for (key, m) in frameMotions {
            let t = CGFloat((now - m.start) / m.duration)
            if t >= 1 {
                finishMotion(key, m)
            } else {
                let raw = lerpRect(m.from, m.to, motionUnit(m.ease, t))
                let frame = containedOrRaw(raw, slot: m.slot, minSize: m.minSize)
                if framesClose(frame, m.to) {
                    // 弹簧尾巴已在容差内：直接收尾，不再逐帧写趋近 0 的微差。
                    finishMotion(key, m)
                } else if let last = motionLastWritten[key], last.start == m.start,
                          abs(last.frame.minX - frame.minX) < 0.5, abs(last.frame.minY - frame.minY) < 0.5,
                          abs(last.frame.width - frame.width) < 0.5, abs(last.frame.height - frame.height) < 0.5 {
                    // 本帧与上次写出几乎无差：跳过 AX 写（下一帧插值变大后自然再写）。
                } else {
                    applyAXFrame(m.element, frame)
                    motionLastWritten[key] = (m.start, frame)
                }
            }
        }
        for key in finished { frameMotions.removeValue(forKey: key) }
        if !frameMotions.isEmpty { syncOverlayFramesToMotion() }
        if !finished.isEmpty { demoteOverflowingStackTops() }
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
            motionLastWritten.removeAll()
            if dimsSuppressed, dragState == nil {
                dimsSuppressed = false
            }
            refreshGrips()
            refreshStackMarkers()
            refreshDimLayers()
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

    /// 跟随专用静默版：拖动中每事件都调，拒绝对端不得刷日志。
    func setPositionQuiet(_ el: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
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
        let g = gapForLayout()
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
        private var hovered = false
        private var dragging = false
        private var tracking: NSTrackingArea?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        // 命中区就是整条 8pt 缝。平时不画任何线条与色块（16:30 定）；
        // 但鼠标放上来时要像 demo 那样出现一条细提示线，否则缝找不到、
        // 用户一拖就抓成窗本身、窗盖到另一扇上面去。提示只在悬停与拖动时画。
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: (divider?.vertical ?? true) ? .resizeLeftRight : .resizeUpDown)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = tracking { removeTrackingArea(t) }
            // 面板不是 key window，必须 activeAlways，否则 mouseEntered 永远不来。
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
            addTrackingArea(t)
            tracking = t
        }
        override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
        override func draw(_ dirtyRect: NSRect) {
            guard hovered || dragging else { return }
            let vertical = divider?.vertical ?? true
            let pill: NSRect
            if vertical {
                pill = NSRect(x: (bounds.width - 3) / 2, y: 2, width: 3, height: bounds.height - 4)
            } else {
                pill = NSRect(x: 2, y: (bounds.height - 3) / 2, width: bounds.width - 4, height: 3)
            }
            NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 1.5, yRadius: 1.5).fill()
        }
        override func mouseDown(with event: NSEvent) { dragging = true; needsDisplay = true; onDrag?(self, 0, 0) }
        // 面板平时不是 key window；首击也必须送达，否则缝手柄永远拖不起来。
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDragged(with event: NSEvent) {
            let m = NSEvent.mouseLocation
            onDrag?(self, 1, divider.vertical ? m.x : m.y)
        }
        override func mouseUp(with event: NSEvent) { dragging = false; needsDisplay = true; onDrag?(self, 2, 0) }
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

    // CG 窗口列表的顺序即屏幕 z 序（前→后）：编号越小越在上。
    // 同一拍内只取一次，供盖邻格守卫的 z 序感知复用。
    func zOrderPositions() -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, snap) in cgWindowSnaps().enumerated() where snap.number != 0 {
            out["\(snap.pid)#\(snap.number)"] = i
        }
        return out
    }

    // 盖邻格守卫的 z 序感知版：几何上伸进邻格还不够，必须真的可见——
    // 即在每一个被它几何盖住的邻格里，它都要高于该格的顶（或该格无顶信息）。
    // 已被邻格顶盖住（不可见）的伸进不算违规，不再当作待处理项。
    func coversNeighborVisibly(_ w: WinInfo, cellIndex: Int, tiles: [(stack: [WinInfo], frame: CGRect, top: WinInfo)], zOrder: [String: Int]) -> Bool {
        let key = winKey(w)
        for (j, t) in tiles.enumerated() where j != cellIndex {
            guard t.frame.intersects(w.frame) else { continue }
            guard let myPos = zOrder[key] else { return true }
            if let topPos = zOrder[winKey(t.top)] {
                if myPos < topPos { return true }
            } else {
                return true
            }
        }
        return false
    }

    func coversAnyOtherPane(_ actual: CGRect, cellIndex: Int, tiles: [(stack: [WinInfo], frame: CGRect, top: WinInfo)]) -> Bool {
        guard tiles.indices.contains(cellIndex) else { return false }
        let cell = tiles[cellIndex].frame
        for (i, other) in tiles.enumerated() where i != cellIndex {
            if frameCrossesPane(actual, cell: cell, neighbor: other.frame) { return true }
        }
        return false
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
    // 缝两侧两格在 tiles 里的下标（按当前帧与缝中心判定，1.5pt 容差，与旧顶回同口径）。
    // side -1：竖线为左格（maxX == center-half），横线为 minY == center+half 的格；
    // side 1：竖线为右格（minX == center+half），横线为 maxY == center-half 的格。
    func dividerAdjacentIndices(tiles: [(stack: [WinInfo], frame: CGRect, top: WinInfo)], divider d: Divider, gap g: CGFloat) -> [Int] {
        let half = g / 2
        var out: [Int] = []
        for (i, t) in tiles.enumerated() {
            if d.vertical {
                if abs(t.frame.maxX - (d.center - half)) < 1.5 || abs(t.frame.minX - (d.center + half)) < 1.5 { out.append(i) }
            } else {
                if abs(t.frame.minY - (d.center + half)) < 1.5 || abs(t.frame.maxY - (d.center - half)) < 1.5 { out.append(i) }
            }
        }
        return out
    }

    // phase 0 快照：两侧两格成员各读一次实际帧（每拖一次，可接受），并算好
    // 快照实际帧顶回（拖动中成员不动，顶回贡献是常量，不必每步重读）。
    func makeDividerDragSnapshot(screenID sid: CGDirectDisplayID, dividerID: String, vertical: Bool) -> DividerDragSnapshot? {
        guard let tiles = lastTilesByScreen[sid], tiles.count >= 2 else { return nil }
        let frames = tiles.map { $0.frame }
        let g = gapForLayout()
        let half = g / 2
        guard let d = deriveDividers(frames: frames, gap: g, sid: sid).first(where: { $0.id == dividerID && $0.vertical == vertical }) else { return nil }
        let mh = mainHeight()
        var snapTiles: [(keys: Set<String>, frame: CGRect)] = []
        var memberKeys = Set<String>()
        var memberFrames: [String: CGRect] = [:]
        var snapLo: CGFloat? = nil
        var snapHi: CGFloat? = nil
        for i in dividerAdjacentIndices(tiles: tiles, divider: d, gap: g) {
            let t = tiles[i]
            var keys = Set<String>()
            for w in t.stack {
                let key = winKey(w)
                keys.insert(key)
                memberKeys.insert(key)
                memberFrames[key] = getFrame(w.element, screenHeight: mh) ?? lastPlacedFrames[key] ?? t.frame
            }
            snapTiles.append((keys: keys, frame: t.frame))
            // 快照实际帧顶回：已超宽成员的拖前实际帧就是一堵固定的墙。
            for w in t.stack {
                guard let actual = memberFrames[winKey(w)] else { continue }
                if d.vertical {
                    if abs(t.frame.maxX - (d.center - half)) < 1.5, actual.maxX > t.frame.maxX + tileFitTolerance {
                        snapLo = max(snapLo ?? -CGFloat.greatestFiniteMagnitude, actual.maxX + half)
                    } else if abs(t.frame.minX - (d.center + half)) < 1.5, actual.minX < t.frame.minX - tileFitTolerance {
                        snapHi = min(snapHi ?? CGFloat.greatestFiniteMagnitude, actual.minX - half)
                    }
                } else {
                    if abs(t.frame.minY - (d.center + half)) < 1.5, actual.minY < t.frame.minY - tileFitTolerance {
                        snapHi = min(snapHi ?? CGFloat.greatestFiniteMagnitude, actual.minY - half)
                    } else if abs(t.frame.maxY - (d.center - half)) < 1.5, actual.maxY > t.frame.maxY + tileFitTolerance {
                        snapLo = max(snapLo ?? -CGFloat.greatestFiniteMagnitude, actual.maxY + half)
                    }
                }
            }
        }
        // 2×2 布局里一条合并后的缝两侧各有两格，adj 可能是 4 格；只要找得到两侧格子即可。
        guard snapTiles.count >= 2 else { return nil }
        let key = "\(sid)-\(globalSettings.kind.rawValue)-\(tiles.count)-\(dividerID)"
        return DividerDragSnapshot(sid: sid, dividerID: dividerID, vertical: vertical, seamCenter: d.center,
                                   tiles: snapTiles, memberKeys: memberKeys, memberFrames: memberFrames,
                                   splitOverrideKey: key, splitOverrideValue: splitOverrides[key],
                                   snapLo: snapLo, snapHi: snapHi)
    }

    // 取消本次缝拖动：不清已摆的顶部（就停在那儿），只清状态，让 tick 重排接管。
    func cancelDividerDrag() {
        dividerDragSnapshot = nil
        dividerDragCurrent = nil
        dividerDragPending = nil
        dividerDragScheduled = false
        draggingDividerID = nil
        dragQuiet = false
        dividerRevertLogged = false
        refreshGrips()
        log("divider drag cancelled: stack changed")
    }

    /// 跨格重叠里，装不进自己格子的窗口。两边都装得下却仍重叠时，整条缝才收回。
    func classifySeamOverlap(_ samples: [(tile: Int, window: WinInfo, actual: CGRect, cell: CGRect)]) -> (revert: Bool, offenders: [WinInfo]) {
        var pairs: [(offenderA: Bool, offenderB: Bool)] = []
        var offenders: [String: WinInfo] = [:]
        for a in samples.indices {
            for b in samples.indices where b > a && samples[b].tile != samples[a].tile {
                let inter = samples[a].actual.intersection(samples[b].actual)
                guard !inter.isNull, inter.width > 1, inter.height > 1 else { continue }
                let aOff = windowIsSeamOffender(cell: samples[a].cell, actual: samples[a].actual)
                let bOff = windowIsSeamOffender(cell: samples[b].cell, actual: samples[b].actual)
                pairs.append((offenderA: aOff, offenderB: bOff))
                if aOff { offenders[winKey(samples[a].window)] = samples[a].window }
                if bOff { offenders[winKey(samples[b].window)] = samples[b].window }
            }
        }
        return (seamMustRevert(pairs), Array(offenders.values))
    }

    /// 把探出格子的窗口按回格子。不浮走，不从叠里拿掉，不改份额。
    func ejectSeamOffender(_ w: WinInfo, tileIndex: Int, screen: NSScreen, sid: CGDirectDisplayID, tiles: inout [(stack: [WinInfo], frame: CGRect, top: WinInfo)]) {
        _ = screen
        guard tiles.indices.contains(tileIndex) else { return }
        let pane = tiles[tileIndex].frame
        hardenPaneFrame(w.element, pane)
        lastPlacedFrames[winKey(w)] = pane
        if let actual = getFrame(w.element, screenHeight: mainHeight()), !frameIsInsidePane(actual, pane: pane) {
            noteClampRefused(w.appName, actual, pane, key: winKey(w))
        } else {
            log("pane clamp: \(w.appName) back inside its pane")
        }
        lastTilesByScreen[sid] = tiles
    }

    // 松手结算：两侧两格全部成员按最终帧摆一次，再读实际帧复核。
    // 返回 true 表示落定（调用方记 split dragged），false 表示整步撤销或取消。
    // 装不下新格子的窗口整步撤销，不把用户拖过的份额收回。
    func settleDividerDrag(screen: NSScreen, dividerID: String, vertical: Bool) -> Bool {
        let sid = screenID(screen)
        guard var tiles = lastTilesByScreen[sid], tiles.count >= 2,
              let snap = dividerDragSnapshot, snap.sid == sid, snap.dividerID == dividerID, snap.vertical == vertical else {
            return false
        }
        let frames = tiles.map { $0.frame }
        let g = gapForLayout()
        guard let d = deriveDividers(frames: frames, gap: g, sid: sid).first(where: { $0.id == dividerID && $0.vertical == vertical }) else {
            cancelDividerDrag()
            return false
        }
        let adj = dividerAdjacentIndices(tiles: tiles, divider: d, gap: g)
        // 成员集合变了：取消，不摆不撤销，tick 重排接管。
        var curKeys = Set<String>()
        for i in adj { for w in tiles[i].stack { curKeys.insert(winKey(w)) } }
        guard curKeys == snap.memberKeys else {
            cancelDividerDrag()
            return false
        }
        let mh = mainHeight()
        struct SettleJob {
            let el: AXUIElement
            let old: CGRect
            let new: CGRect
            let key: String
            let shrinking: Bool
            let need: CGSize
            let topOrLone: Bool
            let preActual: CGRect?
            let preSlot: CGRect?
        }
        var jobs: [SettleJob] = []
        for i in adj {
            let newF = tiles[i].frame
            for w in tiles[i].stack { frameMotions.removeValue(forKey: winKey(w)) }
            for w in tiles[i].stack {
                let key = winKey(w)
                let old = lastPlacedFrames[key] ?? tiles[i].frame
                let shrinking = newF.width <= old.width + 0.5 && newF.height <= old.height + 0.5
                let topOrLone = winKey(tiles[i].top) == key || tiles[i].stack.count == 1
                let preActual = snap.memberFrames[key]
                let preSlot = snap.tiles.first(where: { $0.keys.contains(key) })?.frame
                jobs.append(SettleJob(el: w.element, old: old, new: newF, key: key, shrinking: shrinking, need: effectiveMin(for: w), topOrLone: topOrLone, preActual: preActual, preSlot: preSlot))
            }
        }
        // 落点复核：任一成员（含堆叠非顶层）顶在最小尺寸还探出新格 → 整步撤销，份额也不收。
        // 未顶最小尺寸的视为摆位/动画中间态，交给下一 tick 的落点守卫再验，避免误判。
        // 精确一致补一条：在格子里但不够精确（欠尺寸，如固定尺寸窗）且拖动没让它动过（实际帧等于拖前）
        // → 同样撤销；顶层/单窗格任何卡住都撤销，被盖住的只在“拖前精确、拖后不精确”（回归）时撤销，
        // 避免拖前已有的隐藏违规把缝永久冻住。
        var offenders: [(offenderA: Bool, offenderB: Bool)] = []
        var exactOffender = false
        for j in jobs {
            hardenPaneFrame(j.el, j.new)
            lastPlacedFrames[j.key] = j.new
            guard let actual = getFrame(j.el, screenHeight: mh) else { continue }
            if !frameIsInsidePane(actual, pane: j.new) {
                let name = tiles.flatMap { $0.stack }.first { winKey($0) == j.key }?.appName ?? "window"
                noteClampRefused(name, actual, j.new, key: j.key)
                let atMin = actual.width <= j.need.width + 1.5 && actual.height <= j.need.height + 1.5
                if atMin { offenders.append((true, false)) }
            } else if !frameMatchesSlot(actual, pane: j.new) {
                let name = tiles.flatMap { $0.stack }.first { winKey($0) == j.key }?.appName ?? "window"
                let unchanged = j.preActual.map { framesClose($0, actual) } ?? false
                let regressed = j.preActual != nil && j.preSlot != nil && frameMatchesSlot(j.preActual!, pane: j.preSlot!)
                if unchanged, j.topOrLone || regressed {
                    log("divider exact offender: \(name) stays \(Int(actual.width))x\(Int(actual.height)) vs new cell \(Int(j.new.width))x\(Int(j.new.height))")
                    exactOffender = true
                    offenders.append((true, false))
                }
            } else {
                paneRefusals.removeValue(forKey: j.key)
            }
        }
        if seamMustRevert(offenders) {
            // 整步撤销：窗口写回拖前帧，两侧格子帧与份额恢复快照，不留半格超出的中间态。
            for j in jobs {
                hardenPaneFrame(j.el, j.old)
                lastPlacedFrames[j.key] = j.old
            }
            for i in adj {
                let keys = Set(tiles[i].stack.map { winKey($0) })
                if let before = snap.tiles.first(where: { $0.keys == keys }) {
                    tiles[i].frame = before.frame
                }
            }
            lastTilesByScreen[sid] = tiles
            if screenID(activeScreen()) == sid { lastTiles = tiles }
            // 撤销后冻结记录也要回拖前帧，否则下次冻结轮次写回拖中帧。
            syncFrozenFramesFromShownTiles(sid: sid)
            if let v = snap.splitOverrideValue {
                splitOverrides[snap.splitOverrideKey] = v
            } else {
                splitOverrides.removeValue(forKey: snap.splitOverrideKey)
            }
            for (i, t) in tiles.enumerated() {
                dimPanels["\(sid):\(i)"]?.setFrame(t.frame, display: true)
            }
            if exactOffender {
                log("divider revert: a member cannot match the new cell exactly")
            } else {
                log("divider revert: a member cannot shrink into the new cell")
            }
            raiseGrips()
            return false
        }
        lastTilesByScreen[sid] = tiles
        forgetInflatedMinsForDividerDrop(screen: screen, dividerID: dividerID, vertical: vertical)
        return true
    }

    func applyDividerDrag(screen: NSScreen, dividerID: String, vertical: Bool, proposed: CGFloat) {
        let sid = screenID(screen)
        guard var tiles = lastTilesByScreen[sid], tiles.count >= 2 else { return }
        let vf = screen.visibleFrame
        let oldFrames = tiles.map { $0.frame }
        let g = gapForLayout()
        guard let d = deriveDividers(frames: oldFrames, gap: g, sid: sid).first(where: { $0.id == dividerID && $0.vertical == vertical }) else { return }
        // 成员集合变了（窗口增减）：取消本次拖动，不清已摆的顶部，tick 重排接管。
        let adj = dividerAdjacentIndices(tiles: tiles, divider: d, gap: g)
        if let snap = dividerDragSnapshot, snap.sid == sid, snap.dividerID == dividerID, snap.vertical == vertical {
            var curKeys = Set<String>()
            for i in adj { for w in tiles[i].stack { curKeys.insert(winKey(w)) } }
            guard curKeys == snap.memberKeys else {
                cancelDividerDrag()
                return
            }
        }
        // 缝只受几何下限约束（每侧大约 160×120）。某扇窗自己的最小尺寸不是墙：
        // 它装不下新格子就在落点浮走，不能把整条缝钉死，也不能在松手时把份额收回。
        // 两侧几何下限打架（格子已经小于 160/120）时停在原缝，避免 min/max 交叉后盖住另一侧。
        let clamped: CGFloat = d.minCenter <= d.maxCenter
            ? min(max(proposed, d.minCenter), d.maxCenter)
            : d.center
        // 上次已落到同一位置（<0.5pt）：跳过整步 AX 写；快照已验成员未变，跳过即等价。
        if let last = dividerLastApplied[dividerID], abs(clamped - last) < 0.5 { return }
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
        // 拖动中只摆每格看得见的顶部一扇：堆叠成员被顶部完全盖住，拖动中不动
        // 它们、视觉上无差别；lastPlacedFrames 也只写顶部，成员留到松手结算。
        // 飞行中的弹簧仍要取消，否则 tick 会把窗往旧目的地拖、与缝打架。
        var jobs: [Job] = []
        for i in adj {
            let newF = newFrames[i]
            for w in tiles[i].stack { frameMotions.removeValue(forKey: winKey(w)) }
            tiles[i].frame = newF
            guard !tiles[i].stack.isEmpty else { continue }
            let top = tiles[i].top
            let key = winKey(top)
            let old = lastPlacedFrames[key] ?? oldFrames[i]
            let shrinking = newF.width <= old.width + 0.5 && newF.height <= old.height + 0.5
            jobs.append(Job(el: top.element, old: old, new: newF, key: key, shrinking: shrinking))
        }
        let mh = mainHeight()
        for j in jobs {
            hardenPaneFrame(j.el, j.new)
            lastPlacedFrames[j.key] = j.new
            if let actual = getFrame(j.el, screenHeight: mh), !frameIsInsidePane(actual, pane: j.new) {
                noteClampRefused(tiles.flatMap { $0.stack }.first { winKey($0) == j.key }?.appName ?? "window", actual, j.new, key: j.key)
            }
        }
        dividerLastApplied[dividerID] = clamped
        lastTilesByScreen[sid] = tiles
        if screenID(activeScreen()) == sid { lastTiles = tiles }
        let frac = vertical
            ? (clamped - vf.minX) / max(vf.width, 1)
            : (clamped - vf.minY) / max(vf.height, 1)
        splitOverrides["\(sid)-\(globalSettings.kind.rawValue)-\(tiles.count)-\(dividerID)"] = frac
        // 拖缝直接改帧不走 tile()：冻结记录跟拖后的帧走，否则下次事件
        // 触发冻结轮次会把拖过的窗写回拖前帧。
        syncFrozenFramesFromShownTiles(sid: sid)
        if let panel = gripPanels["\(sid)-\(dividerID)"] {
            if vertical {
                panel.setFrameOrigin(NSPoint(x: clamped - panel.frame.width / 2, y: panel.frame.minY))
            } else {
                panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: clamped - panel.frame.height / 2))
            }
        }
        for (i, f) in newFrames.enumerated() {
            dimPanels["\(sid):\(i)"]?.setFrame(f, display: true)
        }
        raiseGrips()
    }

    func refreshGrips() {
        guard AXIsProcessTrusted(), autoTile, focusKey == nil, !cleanSpaceOn else {
            hideGrips()
            return
        }
        guard draggingDividerID == nil else { return }  // 拖动中不重建手柄
        var seen: Set<String> = []
        for (sid, tiles) in lastTilesByScreen where !tiles.isEmpty {
            guard NSScreen.screens.contains(where: { screenID($0) == sid }) else { continue }
            let frames = tiles.map { $0.frame }
            let dividers = deriveDividers(frames: frames, gap: gapForLayout(), sid: sid)
            for d in dividers {
                let key = "\(sid)-\(d.id)"
                seen.insert(key)
                // 热区固定 12pt，画在缝的正中。静止时 GripView 不描线，缝里只剩墙纸。
                let thickness: CGFloat = 12
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
                            self.dividerDragCurrent = (screenID: dd.screenID, id: dd.id, vertical: dd.vertical)
                            self.dividerDragPending = nil
                            self.dividerDragScheduled = false
                            self.dragQuiet = true
                            self.dividerRevertLogged = false
                            self.dividerDragSnapshot = self.makeDividerDragSnapshot(screenID: dd.screenID, dividerID: dd.id, vertical: dd.vertical)
                        case 1:
                            // 事件合并：只记最新位置，不直接跑 applyDividerDrag。
                            // 主队列异步块用最新位置跑一步；多个事件到达时只覆盖
                            // pending，不排队。位置是绝对坐标（非增量），
                            // 所以丢弃中间值不丢行程，缝跟的是当前鼠标位置。
                            self.dividerDragPending = value
                            if !self.dividerDragScheduled {
                                self.dividerDragScheduled = true
                                DispatchQueue.main.async { [weak self] in
                                    guard let self = self else { return }
                                    self.dividerDragScheduled = false
                                    guard let pending = self.dividerDragPending else { return }
                                    self.dividerDragPending = nil
                                    guard let cur = self.dividerDragCurrent,
                                          let scr = NSScreen.screens.first(where: { self.screenID($0) == cur.screenID }) else { return }
                                    self.applyDividerDrag(screen: scr, dividerID: cur.id, vertical: cur.vertical, proposed: pending)
                                }
                            }
                        default:
                            // 松开：先同步刷掉未处理的 pending 位置，保证落点不丢
                            // 最后一段；已入队的异步块届时见 pending 为 nil 即空转。
                            // 顺序不能反：applyDividerDrag 期间 draggingDividerID
                            // 必须仍非空（tick 弹回与 refreshGrips 都以此为界），
                            // 且虚高遗忘要在最终帧上结算。
                            if let pending = self.dividerDragPending {
                                self.dividerDragPending = nil
                                self.dividerDragScheduled = false
                                if let cur = self.dividerDragCurrent,
                                   let scr = NSScreen.screens.first(where: { self.screenID($0) == cur.screenID }) {
                                    self.applyDividerDrag(screen: scr, dividerID: cur.id, vertical: cur.vertical, proposed: pending)
                                }
                            }
                            // 松手结算：两侧两格全部成员按最终帧摆一次并复核；整步撤销
                            // 或成员集合变化时 settle 返回 false，不记 split dragged。
                            var settled = false
                            if let cur = self.dividerDragCurrent,
                               let scr = NSScreen.screens.first(where: { self.screenID($0) == cur.screenID }) {
                                settled = self.settleDividerDrag(screen: scr, dividerID: cur.id, vertical: cur.vertical)
                            }
                            self.dividerDragSnapshot = nil
                            self.dividerDragCurrent = nil
                            self.draggingDividerID = nil
                            self.dragQuiet = false
                            self.dividerRevertLogged = false
                            self.refreshGrips()
                            if settled { log("split dragged: \(dd.id)") }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
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
        var count = 1
        var topIndex = 0
        /// 活动格的握把更大。非活动堆叠格用小圆点。
        var prominent = false
        var onClick: (() -> Void)?
        override func draw(_ dirtyRect: NSRect) {
            let shown: CGFloat = count <= 1 ? (prominent ? 32 : 0) : (prominent ? 26 : 16)
            guard shown > 0 else { return }
            let rest: CGFloat = prominent ? 10 : 7
            let h: CGFloat = count <= 1 ? 5 : 6
            let gap: CGFloat = 4
            var widths: [CGFloat] = []
            if count <= 1 {
                widths = [shown]
            } else {
                for i in 0..<count { widths.append(i == topIndex ? shown : rest) }
            }
            let total = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1))
            var x = (bounds.width - total) / 2
            let y = (bounds.height - h) / 2
            for i in 0..<widths.count {
                let w = widths[i]
                let alpha: CGFloat = (count <= 1 || i == topIndex) ? 1 : 0.55
                NSColor.systemOrange.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
                x += w + gap
            }
        }
        override func mouseDown(with event: NSEvent) { onClick?() }
        // 面板平时不是 key window；首击也必须送达，否则握把点按时灵时不灵。
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func stackGripWidth(count: Int, prominent: Bool) -> CGFloat {
        if count <= 1 { return prominent ? 48 : 0 }
        let shown: CGFloat = prominent ? 26 : 16
        let rest: CGFloat = prominent ? 10 : 7
        let gap: CGFloat = 4
        let dots = shown + CGFloat(max(0, count - 1)) * (rest + gap)
        return dots + (prominent ? 16 : 8)
    }

    func refreshStackMarkers() {
        guard AXIsProcessTrusted(), autoTile, focusKey == nil, !cleanSpaceOn else {
            hideStackMarkers()
            return
        }
        var seen: Set<String> = []
        for (sid, tiles) in lastTilesByScreen where !tiles.isEmpty {
            let active = min(lastActiveTileByScreen[sid] ?? 0, tiles.count - 1)
            for (i, t) in tiles.enumerated() {
                let prominent = i == active
                if !prominent && t.stack.count <= 1 { continue }
                let key = "\(sid):\(i)"
                seen.insert(key)
                let topIdx = t.stack.firstIndex(where: { winKey($0) == winKey(t.top) }) ?? 0
                let w = stackGripWidth(count: t.stack.count, prominent: prominent)
                let h: CGFloat = prominent ? 18 : 12
                let rect: NSRect
                if prominent {
                    rect = NSRect(x: t.frame.midX - w / 2, y: t.frame.maxY - h / 2, width: w, height: h)
                } else {
                    let lift = gapForLayout() / 2 + 7
                    rect = NSRect(x: t.frame.midX - w / 2, y: t.frame.maxY + lift - h / 2, width: w, height: h)
                }
                if let panel = stackMarkerPanels[key] {
                    panel.setFrame(rect, display: true)
                    if let view = panel.contentView as? StackMarkerView {
                        view.count = t.stack.count
                        view.topIndex = topIdx
                        view.prominent = prominent
                    }
                    panel.contentView?.needsDisplay = true
                } else {
                    let view = StackMarkerView(frame: NSRect(origin: .zero, size: rect.size))
                    view.count = t.stack.count
                    view.topIndex = topIdx
                    view.prominent = prominent
                    view.onClick = { [weak self] in
                        guard let self, t.stack.count > 1 else { return }
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
        let cur = stack.firstIndex(where: { winKey($0) == winKey(tiles[tile].top) }) ?? 0
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
        // 显示格的栈顶下标按计算格存；读用三元组的顶（置换下也正确），写经置换翻译。
        let key = stackTopKey(sid, permSrcSlot(tile, sid: sid))
        let cur = stack.firstIndex(where: { winKey($0) == winKey(tiles[tile].top) }) ?? 0
        let next = (cur + dir + stack.count) % stack.count
        stackTops[key] = next
        pinnedTops[key] = winKey(stack[next])
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
            let key = stackTopKey(stackPanelSid, permSrcSlot(stackPanelTile, sid: stackPanelSid))
            stackTops[key] = idx
            pinnedTops[key] = winKey(w)
            AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
            if let app = NSRunningApplication(processIdentifier: w.pid) { app.activate() }
        }
        closeStackPanel()
        forceTile()
    }

    // MARK: - 悬停条（格子上沿停留约 0.15 秒出现）
    // Primary / Focus / Float 是图标加文字，没有快捷键键帽。堆叠芯片带应用图标。
    // 橙色堆叠标记保留。悬停条是直接挑窗口的入口，两者共存：条放在标记上方；
    // 顶行格子放不下时改放格子内、标记下方，不盖住标记。

    var hoverBarView: NSView!
    var hoverSid: CGDirectDisplayID = 0
    var hoverTile: Int = 0
    // 悬停条种类：0 普通格子，1 专注（Exit focus），2 悬浮（Primary/Focus 不可点，第三钮是 Tile）。
    var hoverBarKind: Int = 0
    var hoverFloatElement: AXUIElement? = nil  // 悬浮条目标窗口（keep-alive 用 live 帧，窗口可被拖动）
    var hoverZoneID: String?
    var hoverZoneSince: CFTimeInterval = 0
    var hoverShownAt: CFTimeInterval = 0
    var hoverHideArmedAt: CFTimeInterval = 0
    var chipDrag: (key: String, sid: CGDirectDisplayID, source: Int, ghost: NSPanel?)?
    var hoverFocusDoneFor: String?
    var hoverFocusZoneID: String?
    var hoverFocusZoneSince: CFTimeInterval = 0

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

    /// 图标在上、文字在下。不能点的时候文字仍然可读，按钮不接收点击。
    /// emphasized = 激活态底色（如已固定的 Pin），即状态指示，不另加覆盖层。
    func hoverColumn(_ title: String, symbol: String, action: Selector, enabled: Bool, emphasized: Bool = false) -> NSButton {
        let ink = NSColor.white.withAlphaComponent(enabled ? 1 : 0.55)
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
        b.isEnabled = enabled
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(emphasized ? 0.18 : (enabled ? 0.12 : 0.06)).cgColor
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    /// 条以握把中心为锚，夹在工作区内，四周留 6pt。宽 440。有堆叠芯片时高 90，否则 54。
    func placeHoverBar(anchor: CGPoint, screen: NSScreen, stacked: Bool) {
        let vf = screen.visibleFrame
        let margin: CGFloat = 6
        let barW = min(440, max(160, vf.width - margin * 2))
        let barH: CGFloat = stacked ? 90 : 54
        var x = anchor.x - barW / 2
        var y = anchor.y - barH / 2
        x = min(max(x, vf.minX + margin), vf.maxX - barW - margin)
        y = min(max(y, vf.minY + margin), vf.maxY - barH - margin)
        hoverPanel.setFrame(NSRect(x: x, y: y, width: barW, height: barH), display: true)
        hoverPanel.orderFront(nil)
    }

    func showHoverBar(for tile: (stack: [WinInfo], frame: CGRect, top: WinInfo), screen: NSScreen, sid: CGDirectDisplayID, tileIndex: Int, floated: Bool = false, focus: Bool = false) {
        guard hoverPanel != nil, !tile.stack.isEmpty else { return }
        hoverSid = sid
        hoverTile = tileIndex
        hoverBarKind = focus ? 1 : (floated ? 2 : 0)
        let topIdx = tile.stack.firstIndex(where: { winKey($0) == winKey(tile.top) }) ?? 0
        let stacked = !floated && !focus && tile.stack.count > 1
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        column.translatesAutoresizingMaskIntoConstraints = false
        if stacked {
            let chips = NSStackView()
            chips.orientation = .horizontal
            chips.spacing = 4
            chips.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
            chips.addArrangedSubview(hoverChip("‹", tag: 0, action: #selector(hoverStackStep(_:)), emphasized: false))
            for (idx, w) in tile.stack.enumerated() {
                let chip = ChipControl(frame: .zero)
                chip.title = w.appName
                chip.icon = appIcon(pid: w.pid, side: 14)
                chip.emphasized = idx == topIdx
                chip.chipIndex = idx
                chip.windowKey = winKey(w)
                chip.toolTip = "Click to show it, or drag it onto another tile"
                chip.onTrack = { [weak self] control, start in
                    self?.trackChip(control, start: start, sid: sid, sourceTile: tileIndex)
                }
                chips.addArrangedSubview(chip)
            }
            chips.addArrangedSubview(hoverChip("›", tag: 1, action: #selector(hoverStackStep(_:)), emphasized: false))
            let chipWidth = rowContentWidth(chips)
            chips.frame = NSRect(x: 0, y: 0, width: max(chipWidth, 40), height: 36)
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = chips
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: 36).isActive = true
            column.addArrangedSubview(scroll)
        }
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.heightAnchor.constraint(equalToConstant: 54).isActive = true
        // Primary 亮暗跟当前窗口走（与 hoverPrimary 的动作目标同一解析器）：
        // 亮 ⟺ 定得出受管当前窗口、且当前窗口在格子里、且未浮动、且不是 tile0 的顶。
        // 定不出、已浮动、不在格子里、已是 tile0 的顶时暗（55% 透明度画法不变）。
        // 注意：亮暗只在条出现/重建时按当时前台算一次；条可见期间前台变了，亮暗未跟上
        // （条在悬停移动/切芯片时会重建），属已知边角，不另加前台监听。
        let primaryOn: Bool = {
            guard !floated && !focus else { return false }
            let (wOpt, _) = resolveCurrentTarget()
            guard let w = wOpt else { return false }
            let key = winKey(w)
            if floatedKeys.contains(key) { return false }
            guard let tiles = lastTilesByScreen[sid], !tiles.isEmpty, !tiles[0].stack.isEmpty else { return false }
            guard let tileIdx = tiles.firstIndex(where: { $0.stack.contains { winKey($0) == key } }) else { return false }
            return !(tileIdx == 0 && winKey(tiles[0].top) == key)
        }()
        let focusOn = !floated
        let thirdTitle = floated ? "Unfloat" : "Float"
        let thirdSymbol = floated ? "square.grid.2x2" : "square.on.square"
        let thirdAction: Selector = floated ? #selector(hoverTileBack(_:)) : #selector(hoverFloat(_:))
        // Pin 列：当前窗口已固定时高亮（按钮状态即固定指示，不新增常驻覆盖层）。
        // 条出现/重建时按当时前台算一次（与 Primary 亮暗同一已知边角）。
        let pinOn: Bool = {
            let (wOpt, _) = resolveCurrentTarget()
            guard let w = wOpt else { return false }
            return pinnedWindowKeys.contains(winKey(w))
        }()
        actions.addArrangedSubview(hoverColumn("Primary", symbol: "sidebar.left", action: #selector(hoverPrimary(_:)), enabled: primaryOn))
        actions.addArrangedSubview(hoverColumn(focus ? "Exit focus" : "Focus", symbol: "arrow.up.left.and.arrow.down.right", action: #selector(hoverFocus(_:)), enabled: focusOn))
        actions.addArrangedSubview(hoverColumn(thirdTitle, symbol: thirdSymbol, action: thirdAction, enabled: true))
        actions.addArrangedSubview(hoverColumn(pinOn ? "Unpin" : "Pin", symbol: pinOn ? "pin.fill" : "pin", action: #selector(hoverPin(_:)), enabled: true, emphasized: pinOn))
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
        placeHoverBar(anchor: CGPoint(x: tile.frame.midX, y: tile.frame.maxY), screen: screen, stacked: stacked)
        hoverKey = winKey(tile.stack[topIdx])
        hoverTileFrame = tile.frame
        if floated { hoverFloatElement = tile.top.element }
        markHoverVisible()
    }

    func hideHoverBar() {
        hoverPanel?.orderOut(nil)
        hoverKey = nil
        hoverBarKind = 0
        hoverFloatElement = nil
        hoverShownAt = 0
        hoverHideArmedAt = 0
    }

    /// 条第一次出现时记下时刻。同一条重建（切芯片）不重新计时，避免 400ms 误点保护被反复清掉。
    func markHoverVisible() {
        if hoverShownAt == 0 { hoverShownAt = CACurrentMediaTime() }
        hoverHideArmedAt = 0
    }

    /// 打开后约 400ms 内的点击丢掉，防止条刚弹出时点到按钮。
    func hoverActionArmed() -> Bool {
        hoverShownAt == 0 || CACurrentMediaTime() - hoverShownAt >= hoverArmDelay
    }

    /// 指针离开后约 350ms 再收。中途回到热区会把计时清掉。
    func considerHoverHide() {
        if chipDrag != nil { return }
        guard hoverKey != nil else {
            hoverHideArmedAt = 0
            return
        }
        if hoverHideArmedAt == 0 { hoverHideArmedAt = CACurrentMediaTime() }
        if CACurrentMediaTime() - hoverHideArmedAt >= hoverHideDelay {
            hideHoverBar()
        }
    }

    // 手动 Float：放到所在屏可视区中央，宽约 60%、高约 75%。
    // 已知最小尺寸更大时抬到最小尺寸，四周仍留在可视区 16pt 以内。其余窗口立即重排填空位。
    // 专注窗口被浮动时清掉 Focus 状态：窗口是被浮动，不是按进入前的帧还原。
    func floatWindow(_ w: WinInfo, source: String, retile: Bool = true, cascade: Int = 0) {
        let key = winKey(w)
        guard !floatedKeys.contains(key) else { return }
        let screen = screenForFrame(w.frame)
        if key == focusKey {
            focusKey = nil
            focusScreen = nil
            focusSavedFrames = nil
            focusSavedTops = nil
            focusSavedActive = nil
            hideFocusCaption()
            log("focus off: floated")
        }
        floatedKeys.insert(key)
        var frame = manualFloatFrame(on: screen, need: effectiveMin(for: w))
        // 多扇同时浮起时按 5 列错开排列，别叠成一摞看不出有几扇。
        if cascade > 0 {
            let box = insetWorkArea(on: screen)
            let step: CGFloat = 30
            let col = CGFloat(cascade % 5)
            let row = CGFloat(cascade / 5)
            let x = frame.minX + col * step - row * step / 2
            let y = frame.minY - row * step - col * step / 2
            frame.origin.x = min(max(x, box.minX), max(box.minX, box.maxX - frame.width))
            frame.origin.y = min(max(y, box.minY), max(box.minY, box.maxY - frame.height))
        }
        placeFrame(w.element, frame, key: key, animated: true)
        lastPlacedFrames[key] = frame
        log("\(source) float -> \(w.appName) centered")
        if retile {
            forceTile()
            refreshPanel()
        }
    }

    // 悬浮窗用同一条：Primary 和 Focus 不可点，第三个按钮是 Tile。点 Tile 按当前布局重算。
    func showFloatedHoverBar(screen: NSScreen, floated: WinInfo) {
        showHoverBar(for: (stack: [floated], frame: floated.frame, top: floated), screen: screen, sid: screenID(screen), tileIndex: -1, floated: true, focus: false)
    }

    func showFocusHoverBar(screen: NSScreen, focusKey fk: String) {
        let frame = focusFrame(on: screen)
        guard let w = collectWindows(includeFloated: true).first(where: { winKey($0) == fk }) else { return }
        showHoverBar(for: (stack: [w], frame: frame, top: w), screen: screen, sid: screenID(screen), tileIndex: -1, floated: false, focus: true)
    }

    @objc func hoverTileBack(_ sender: NSButton) {
        guard hoverActionArmed() else { return }
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

    /// 活动格顶缘中央的握把。热区 48×18，条以它的中心为锚。
    /// 悬停条的触发区：整条窗口顶边，向内 14pt、向外 8pt。
    /// 以前只有正中 48pt 宽，指针很难压准，看起来就像「顶部那排按钮没了」。
    func gripZone(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.maxY - 14, width: max(48, frame.width), height: 22)
    }

    func tileUnderPointer(_ m: CGPoint) -> (sid: CGDirectDisplayID, index: Int, tile: (stack: [WinInfo], frame: CGRect, top: WinInfo), screen: NSScreen)? {
        // 任何格子的顶边都认，不再只认前台 App：指针压到哪一格的上沿，就出哪一格的条。
        for (sid, tiles) in lastTilesByScreen {
            guard let screen = NSScreen.screens.first(where: { screenID($0) == sid }) else { continue }
            for (i, t) in tiles.enumerated() where !t.stack.isEmpty {
                if gripZone(of: t.frame).contains(m) {
                    return (sid, i, t, screen)
                }
            }
        }
        return nil
    }

    /// 指针是否压在本程序自己的可交互窗口上（设置窗、菜单栏面板、欢迎导览、Tab 列表、
    /// 悬停条、堆叠面板）。暗帘（Clean Space / No peek）是 ignoresMouseEvents 的整屏面板，
    /// 不计入：它不该挡住悬停聚焦。
    func pointIsOnOwnChrome(_ p: CGPoint) -> Bool {
        for w in NSApp.windows where w.isVisible && !w.ignoresMouseEvents {
            if w.alphaValue <= 0.05 { continue }
            if w.frame.contains(p) { return true }
        }
        if let pw = panelPopover?.contentViewController?.view.window, panelPopover.isShown,
           pw.frame.contains(p) {
            return true
        }
        return false
    }

    /// Hover focus：指针在某扇窗上停留约 0.15 秒就把它提到前面。和悬停条是两件事。
    func activateHoveredWindow(_ m: CGPoint) {
        guard hoverFocus, focusKey == nil, !cleanSpaceOn else { return }
        // 指针压在本程序自己的可交互窗口上（设置窗、菜单栏面板、欢迎导览、Tab 列表、
        // 悬停条、堆叠面板）时绝不抢焦点：暗帘用 ignoresMouseEvents 的整屏面板，不在此列。
        if pointIsOnOwnChrome(m) {
            hoverFocusZoneID = nil
            return
        }
        var found: (id: String, win: WinInfo)?
        for (sid, tiles) in lastTilesByScreen {
            for (i, t) in tiles.enumerated() where t.frame.contains(m) {
                found = ("hf:\(sid):\(i)", t.top)
                break
            }
            if found != nil { break }
        }
        if found == nil, !floatedKeys.isEmpty {
            for w in collectWindows(includeFloated: true) where floatedKeys.contains(winKey(w)) && w.frame.contains(m) {
                found = ("hf:float:\(winKey(w))", w)
                break
            }
        }
        guard let found else {
            hoverFocusZoneID = nil
            return
        }
        if hoverFocusDoneFor == found.id { return }
        if hoverFocusZoneID != found.id {
            hoverFocusZoneID = found.id
            hoverFocusZoneSince = CACurrentMediaTime()
            return
        }
        guard CACurrentMediaTime() - hoverFocusZoneSince >= hoverShowDelay else { return }
        // 到点时再确认指针真的压在这扇窗上：设置窗、菜单栏面板、欢迎导览、别家浮窗
        // 盖住格子时不许抢焦点，否则点面板控件会被背后的窗口抢走 key，下一次点击只剩激活。
        let cgPoint = CGPoint(x: m.x, y: mainHeight() - m.y)
        guard topmostWindowPid(at: cgPoint) == found.win.pid else {
            hoverFocusZoneSince = CACurrentMediaTime()
            return
        }
        hoverFocusDoneFor = found.id
        AXUIElementPerformAction(found.win.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: found.win.pid)?.activate()
        log("hover focus -> \(found.win.appName)")
    }

    func updateHover() {
        let m = NSEvent.mouseLocation
        updateFocusCaption(mouse: m)
        guard AXIsProcessTrusted(), autoTile, draggingDividerID == nil, dragState == nil, pendingDrag == nil, !cleanSpaceOn else {
            hideHoverBar()
            hoverZoneID = nil
            return
        }
        if chipDrag != nil { return }
        activateHoveredWindow(m)
        guard hoverBarEnabled else {
            hideHoverBar()
            return
        }
        // Focus：握把在专注窗顶缘中央。条上是 Exit focus，Primary 不可点。
        if let fk = focusKey, let fsid = focusScreen,
           let screen = NSScreen.screens.first(where: { screenID($0) == fsid }) {
            let zone = gripZone(of: focusFrame(on: screen))
            let barFrame = (hoverPanel?.frame ?? .zero).insetBy(dx: -8, dy: -8)
            if zone.contains(m) || (hoverBarKind == 1 && hoverKey != nil && barFrame.contains(m)) {
                hoverHideArmedAt = 0
                if hoverBarKind == 1 && hoverKey != nil { return }
                let id = "focus:\(fk)"
                if hoverZoneID != id {
                    hoverZoneID = id
                    hoverZoneSince = CACurrentMediaTime()
                    return
                }
                guard CACurrentMediaTime() - hoverZoneSince >= hoverShowDelay else { return }
                showFocusHoverBar(screen: screen, focusKey: fk)
                return
            }
            considerHoverHide()
            hoverZoneID = nil
            return
        }
        if hoverKey != nil {
            let barFrame = (hoverPanel?.frame ?? .zero).insetBy(dx: -8, dy: -8)
            if barFrame.contains(m) {
                hoverHideArmedAt = 0
                // 后建的握把/标记/暗色层不得盖住条：悬停期间把条顶回最前。
                hoverPanel?.orderFront(nil)
                return
            }
            // 悬浮条：指针仍在悬浮窗口上沿（live 帧，窗口可被拖动）才保留。
            if hoverBarKind == 2 {
                if let el = hoverFloatElement, let f = getFrame(el, screenHeight: mainHeight()) {
                    let zone = gripZone(of: f)
                    if zone.contains(m) {
                        hoverHideArmedAt = 0
                        return
                    }
                }
                considerHoverHide()
                hoverZoneID = nil
                return
            }
            let stillOnTile = tileUnderPointer(m).map { "\($0.sid):\($0.index)" } == "\(hoverSid):\(hoverTile)"
            if stillOnTile {
                hoverHideArmedAt = 0
                return
            }
            considerHoverHide()
            hoverZoneID = nil
            return
        }
        guard let hit = tileUnderPointer(m) else {
            // 无格子命中时试悬浮窗口：仅 floatedKeys 非空才枚举，命中后同样停留才出条。
            // 同样不要求它是前台 App，指针压到哪个窗口的上沿就出哪个的条。
            if !floatedKeys.isEmpty,
               let fw = collectWindows(includeFloated: true).first(where: {
                   floatedKeys.contains(winKey($0)) && gripZone(of: $0.frame).contains(m)
               }) {
                let id = "float:\(winKey(fw))"
                if hoverZoneID != id {
                    hoverZoneID = id
                    hoverZoneSince = CACurrentMediaTime()
                    return
                }
                guard CACurrentMediaTime() - hoverZoneSince >= hoverShowDelay else { return }
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
        guard CACurrentMediaTime() - hoverZoneSince >= hoverShowDelay else { return }
        showHoverBar(for: hit.tile, screen: hit.screen, sid: hit.sid, tileIndex: hit.index)
    }

    func fwMatchesFront(_ w: WinInfo, _ front: pid_t?) -> Bool {
        guard let front else { return true }
        return w.pid == front
    }

    @objc func hoverStackStep(_ sender: NSButton) {
        guard hoverActionArmed() else { return }
        let dir = sender.tag == 0 ? -1 : 1
        cycleStackAt(sid: hoverSid, tile: hoverTile, dir: dir)
        refreshStackMarkers()
        if let tiles = lastTilesByScreen[hoverSid], hoverTile < tiles.count,
           let screen = NSScreen.screens.first(where: { screenID($0) == hoverSid }) {
            showHoverBar(for: tiles[hoverTile], screen: screen, sid: hoverSid, tileIndex: hoverTile)
        }
    }

    /// 芯片拖动。没移动就激活；移动后落在另一格就并进那一叠，没落到格子上只激活。
    func trackChip(_ chip: ChipControl, start: NSPoint, sid: CGDirectDisplayID, sourceTile: Int) {
        guard hoverActionArmed() else { return }
        var moved = false
        let host = hoverPanel
        while let ev = host?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date.distantFuture, inMode: .eventTracking, dequeue: true) {
            let p = NSEvent.mouseLocation
            if ev.type == .leftMouseUp {
                if moved {
                    endChipDrag(at: p)
                } else {
                    activateChip(index: chip.chipIndex, sid: sid, tile: sourceTile)
                }
                break
            }
            let dx = p.x - start.x
            let dy = p.y - start.y
            if !moved, dx * dx + dy * dy >= 16 {
                moved = true
                beginChipDrag(key: chip.windowKey, title: chip.title, sid: sid, source: sourceTile, at: p)
            }
            if moved { updateChipDrag(to: p) }
        }
    }

    func beginChipDrag(key: String, title: String, sid: CGDirectDisplayID, source: Int, at point: NSPoint) {
        let ghost = NSPanel(contentRect: NSRect(x: point.x + 8, y: point.y - 16, width: 140, height: 28), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        prepareOverlay(ghost, level: .popUpMenu, ignoresMouse: true)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 140, height: 28))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 0.96).cgColor
        box.layer?.cornerRadius = 8
        label.frame = box.bounds.insetBy(dx: 8, dy: 4)
        label.autoresizingMask = [.width, .height]
        box.addSubview(label)
        ghost.contentView = box
        ghost.orderFrontRegardless()
        chipDrag = (key: key, sid: sid, source: source, ghost: ghost)
    }

    func updateChipDrag(to point: NSPoint) {
        guard var drag = chipDrag else { return }
        drag.ghost?.setFrameOrigin(NSPoint(x: point.x + 8, y: point.y - 16))
        chipDrag = drag
        let target = chipDropTile(at: point, sid: drag.sid, source: drag.source)
        if let target, let tiles = lastTilesByScreen[drag.sid], tiles.indices.contains(target) {
            showDragRing(frame: tiles[target].frame, label: "Move here")
        } else {
            hideDragRing()
        }
    }

    func chipDropTile(at point: NSPoint, sid: CGDirectDisplayID, source: Int) -> Int? {
        guard let tiles = lastTilesByScreen[sid] else { return nil }
        guard let index = tiles.firstIndex(where: { $0.frame.contains(point) }) else { return nil }
        return index == source ? nil : index
    }

    func endChipDrag(at point: NSPoint) {
        guard let drag = chipDrag else { return }
        drag.ghost?.orderOut(nil)
        chipDrag = nil
        hideDragRing()
        hideHoverBar()
        if let target = chipDropTile(at: point, sid: drag.sid, source: drag.source) {
            performDragStack(draggedKey: drag.key, to: target, screenID: drag.sid)
            log("chip drag stacked")
        } else if let tiles = lastTilesByScreen[drag.sid], tiles.indices.contains(drag.source),
                  let w = tiles[drag.source].stack.first(where: { winKey($0) == drag.key }) {
            AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
            NSRunningApplication(processIdentifier: w.pid)?.activate()
            log("chip drag released outside a tile")
        }
    }

    func activateChip(index: Int, sid: CGDirectDisplayID, tile: Int) {
        guard let tiles = lastTilesByScreen[sid], tile < tiles.count, index >= 0, index < tiles[tile].stack.count else { return }
        let w = tiles[tile].stack[index]
        let topKey = stackTopKey(sid, permSrcSlot(tile, sid: sid))
        stackTops[topKey] = index
        pinnedTops[topKey] = winKey(w)
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        // 换顶即重算：求解围绕新顶验证（格子为它变大、邻格让位或进堆），pinned 顶不被换顶步骤换下去。
        forceTile()
        refreshStackMarkers()
        if let screen = NSScreen.screens.first(where: { screenID($0) == sid }),
           let fresh = lastTilesByScreen[sid], tile < fresh.count {
            showHoverBar(for: fresh[tile], screen: screen, sid: sid, tileIndex: tile)
        }
    }

    @objc func hoverPickStack(_ sender: NSButton) {
        guard hoverActionArmed() else { return }
        let idx = sender.tag
        guard let tiles = lastTilesByScreen[hoverSid], hoverTile < tiles.count,
              idx >= 0, idx < tiles[hoverTile].stack.count else { return }
        let w = tiles[hoverTile].stack[idx]
        let topKey = stackTopKey(hoverSid, permSrcSlot(hoverTile, sid: hoverSid))
        stackTops[topKey] = idx
        pinnedTops[topKey] = winKey(w)
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        // 换顶即重算（同 activateChip）。
        forceTile()
        refreshStackMarkers()
        if let screen = NSScreen.screens.first(where: { screenID($0) == hoverSid }),
           let fresh = lastTilesByScreen[hoverSid], hoverTile < fresh.count {
            showHoverBar(for: fresh[hoverTile], screen: screen, sid: hoverSid, tileIndex: hoverTile)
        }
    }

    // 悬浮条回铺按钮（hoverTileBack）用：按条出现时记下的 hoverKey 重找窗口；
    // 找不到了就收条并记日志，不对错窗口动手。用 includeFloated 找，因为回铺的目标本身就是已浮动的窗口。
    // 主按钮（Primary/Focus/Float）已改走 resolveCurrentTarget，不再用它。
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

    /// 点按时刻的当前窗口：前台 App 在 TileProto 管理范围内的窗口（平铺或已浮动、当前 Space）。
    /// 优先该 App 的 AX 焦点窗口，对不上时退回该 App 在列表里的第一扇窗。
    /// 不用条出现时记下的 hoverKey；定不出时返回 failure 原因，调用方只记日志不动手，
    /// 绝不退回 hoverKey 去动一个错窗口。悬停条是非激活面板，点按时前台仍是用户 App。
    func resolveCurrentTarget() -> (window: WinInfo?, failure: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return (nil, "no frontmost application")
        }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return (nil, "frontmost is TileProto itself")
        }
        let windows = collectWindows(includeFloated: true)
        if let idx = focusedIndex(windows: windows), windows[idx].pid == app.processIdentifier {
            return (windows[idx], nil)
        }
        if let w = windows.first(where: { $0.pid == app.processIdentifier }) {
            return (w, nil)
        }
        return (nil, "frontmost app \(app.localizedName ?? "?") has no managed window on current Space")
    }

    @objc func hoverPrimary(_ sender: NSButton) {
        guard hoverActionArmed() else { log("primary skipped: not armed (400ms guard)"); return }
        // Primary 交换：当前窗口与 tile0 顶部互换格子（当前窗口进 tile0 并成为其顶部，
        // 被换出的 tile0 顶部进当前窗口原格子、接替其栈位，尺寸随格子变）。
        // 目标跟着当前窗口走，不用条出现时记下的 hoverKey；原格子按当前窗口在
        // lastTilesByScreen 里的实际所在格推导，不沿用可能已过期的 hoverTile。
        // 当前窗口已是 tile0 顶部时属合法 no-op；悬浮窗口不可 Primary。
        let (wOpt, failure) = resolveCurrentTarget()
        guard let w = wOpt else { log("primary skipped: no current target (\(failure ?? "unknown"))"); return }
        let key = winKey(w)
        guard !floatedKeys.contains(key) else { log("primary skipped: floated window (\(w.appName))"); return }
        let sid = screenID(screenForFrame(w.frame))
        guard let tiles = lastTilesByScreen[sid], !tiles.isEmpty, !tiles[0].stack.isEmpty else { log("primary skipped: no tiles for screen"); return }
        guard let tileIdx = tiles.firstIndex(where: { $0.stack.contains { winKey($0) == key } }) else { log("primary skipped: current window not in tiles (\(w.appName))"); return }
        if tileIdx == 0 && winKey(tiles[0].top) == key {
            log("primary skipped: already tile0 top (\(w.appName))")
            return
        }
        // 先 raise 被换出的 tile0 顶部，forceTile 后再 raise 当前窗口并激活，使其视觉置顶。
        let top0 = tiles[0].top
        AXUIElementPerformAction(top0.element, kAXRaiseAction as CFString)
        primaryKeysByScreen[sid] = key
        // 新 Primary 指定胜过旧的整叠置换：否则新 Primary 会被置换带到别的格，看起来像没生效。
        tileSwapPermByScreen.removeValue(forKey: sid)
        hideHoverBar()
        forceTile()
        lastActiveTileByScreen[sid] = 0
        refreshDimLayers()
        refreshStackMarkers()
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: w.pid) { app.activate() }
        refreshPanel()
        log("primary swap -> \(w.appName)")
    }

    @objc func hoverFocus(_ sender: NSButton) {
        guard hoverActionArmed() else { log("focus skipped: not armed (400ms guard)"); return }
        if focusKey != nil {
            exitFocus()
            hideHoverBar()
        } else {
            // 目标跟着当前窗口走，不用条出现时记下的 hoverKey。
            let (wOpt, failure) = resolveCurrentTarget()
            guard let w = wOpt else { log("focus skipped: no current target (\(failure ?? "unknown"))"); return }
            enableFocus(targetKey: winKey(w))
            hideHoverBar()
        }
        refreshPanel()
    }

    @objc func hoverFloat(_ sender: NSButton) {
        guard hoverActionArmed() else { log("float skipped: not armed (400ms guard)"); return }
        // 手动 Float：写入 floatedKeys。悬停条上的按钮只走这一条。
        // 目标跟着当前窗口走，不用条出现时记下的 hoverKey。
        let (wOpt, failure) = resolveCurrentTarget()
        guard let w = wOpt else { log("float skipped: no current target (\(failure ?? "unknown"))"); return }
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

    @objc func hoverPin(_ sender: NSButton) {
        guard hoverActionArmed() else { log("pin skipped: not armed (400ms guard)"); return }
        // 固定：把这扇窗钉成它所在格的显示顶（求解不换顶），尺寸仍受格子约束——
        // 塞不进格就折进 Dock，不允许它盖住邻格（窗口之间不得重叠）。
        // 与 Focus/Float 正交，互不干扰。
        // 目标跟着当前窗口走，不用条出现时记下的 hoverKey。
        let (wOpt, failure) = resolveCurrentTarget()
        guard let w = wOpt else { log("pin skipped: no current target (\(failure ?? "unknown"))"); return }
        let key = winKey(w)
        if pinnedWindowKeys.contains(key) {
            pinnedWindowKeys.remove(key)
            log("unpin: \(w.appName)")
            hideHoverBar()
            forceTile()
            refreshPanel()
            return
        }
        // 已折叠的窗先取消最小化再固定，让人看得见自己固定的窗；恢复失败则不固定。
        if foldedKeys.contains(key) {
            guard unminimizeFoldedWindow(element: w.element, key: key) else {
                log("pin skipped: cannot unminimize \(w.appName)")
                return
            }
            foldedKeys.remove(key)
            foldedMinimizedKeys.remove(key)
            foldedElements.removeValue(forKey: key)
            foldedScreenByKey.removeValue(forKey: key)
        }
        pinnedWindowKeys.insert(key)
        log("pin: \(w.appName)")
        hideHoverBar()
        forceTile()
        refreshPanel()
    }

    // 其他格子的暗色层（No peek，强度由 Dim 决定）。Focus 和 Clean Space 时拿掉。

    var dimPanels: [String: NSPanel] = [:]

    /// 活动格是一个洞。洞外是暗色，点击穿过这层，菜单栏和 Dock 不在这块画布里。
    final class NoPeekDimView: NSView {
        var hole: CGRect = .zero
        var strength: CGFloat = 0.5
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds)
            if hole.width > 1, hole.height > 1, bounds.intersects(hole) {
                path.append(NSBezierPath(roundedRect: hole, xRadius: 8, yRadius: 8))
                path.windingRule = .evenOdd
            }
            NSColor.black.withAlphaComponent(min(0.9, max(0.1, strength))).setFill()
            path.fill()
        }
    }

    func veilMask(bounds: CGRect, hole: CGRect) -> CAShapeLayer {
        let mask = CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(bounds)
        if hole.width > 1, hole.height > 1 { path.addRoundedRect(in: hole, cornerWidth: 8, cornerHeight: 8) }
        mask.path = path
        mask.fillRule = .evenOdd
        return mask
    }

    func installVeil(on panel: NSPanel, hole: CGRect, strength: CGFloat) {
        let size = panel.frame.size
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let fx = NSVisualEffectView(frame: root.bounds)
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.autoresizingMask = [.width, .height]
        root.addSubview(fx)
        let dim = NoPeekDimView(frame: root.bounds)
        dim.hole = hole
        dim.strength = strength
        dim.autoresizingMask = [.width, .height]
        root.addSubview(dim)
        fx.wantsLayer = true
        fx.layer?.mask = veilMask(bounds: root.bounds, hole: hole)
        panel.contentView = root
    }

    func refreshDimLayers() {
        guard noPeek, !dimsSuppressed, AXIsProcessTrusted(), autoTile, focusKey == nil, !cleanSpaceOn else {
            removeDimLayers()
            return
        }
        var seen: Set<String> = []
        for screen in NSScreen.screens {
            let sid = screenID(screen)
            guard let tiles = lastTilesByScreen[sid], !tiles.isEmpty else { continue }
            let key = "veil:\(sid)"
            seen.insert(key)
            let active = min(lastActiveTileByScreen[sid] ?? 0, tiles.count - 1)
            let vf = screen.visibleFrame
            let tile = tiles[active].frame
            let hole = CGRect(x: tile.minX - vf.minX, y: tile.minY - vf.minY, width: tile.width, height: tile.height)
            if let p = dimPanels[key],
               p.frame == vf,
               let dim = p.contentView?.subviews.compactMap({ $0 as? NoPeekDimView }).first,
               dim.hole == hole,
               abs(dim.strength - dimStrength) < 0.001 {
                if !p.isVisible { p.orderFront(nil) }
            } else if let p = dimPanels[key] {
                if p.frame != vf { p.setFrame(vf, display: false) }
                installVeil(on: p, hole: hole, strength: dimStrength)
                if !p.isVisible { p.orderFront(nil) }
            } else {
                let p = NSPanel(contentRect: vf, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                prepareOverlay(p, level: .floating, ignoresMouse: true)
                installVeil(on: p, hole: hole, strength: dimStrength)
                p.orderFront(nil)
                dimPanels[key] = p
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
        // 其它窗口留在原位。帘子盖住它们，不最小化，也不把它们挪出屏幕。
        placeFrame(top.element, hole, key: winKey(top), animated: true)
        lastPlacedFrames[winKey(top)] = hole
        AXUIElementPerformAction(top.element, kAXRaiseAction as CFString)
        hideGrips()
        hideHoverBar()
        removeDimLayers()
        showCleanDim(on: screen, hole: hole)
        log("clean space on: \(top.appName)")
        showToast("Clean Space", detail: "Turn it off in the menu to put windows back.", on: screen)
    }

    /// 清屏帘子的颜色。不透明，盖住墙纸；菜单栏和 Dock 在可视区之外，保持原样。
    func cleanSpaceGraphite() -> NSColor {
        switch cleanTone {
        case .graphite:
            return NSColor(srgbRed: 42.0 / 255, green: 42.0 / 255, blue: 45.0 / 255, alpha: 1)
        case .stone:
            return NSColor(srgbRed: 110.0 / 255, green: 108.0 / 255, blue: 104.0 / 255, alpha: 1)
        case .mist:
            return NSColor(srgbRed: 217.0 / 255, green: 216.0 / 255, blue: 212.0 / 255, alpha: 1)
        }
    }

    func showCleanDim(on screen: NSScreen, hole: CGRect) {
        let vf = screen.visibleFrame
        let rects = [
            CGRect(x: vf.minX, y: hole.maxY, width: vf.width, height: max(0, vf.maxY - hole.maxY)),
            CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: max(0, hole.minY - vf.minY)),
            CGRect(x: vf.minX, y: hole.minY, width: max(0, hole.minX - vf.minX), height: hole.height),
            CGRect(x: hole.maxX, y: hole.minY, width: max(0, vf.maxX - hole.maxX), height: hole.height),
        ].filter { $0.width > 1 && $0.height > 1 }
        if !cleanDimPanels.isEmpty, cleanSpaceShownHole == hole, cleanDimPanels.count == rects.count {
            return
        }
        removeCleanDim()
        cleanSpaceShownHole = hole
        // 高于普通窗口，挡住两侧和上下的格子。洞里的活动窗口仍然能点。
        // 左右两块从屏幕外滑进来。菜单栏和 Dock 在可视区之外，不盖。
        for r in rects {
            let slidesFromLeft = abs(r.maxX - hole.minX) < 1.5 && abs(r.height - hole.height) < 1.5
            let slidesFromRight = abs(r.minX - hole.maxX) < 1.5 && abs(r.height - hole.height) < 1.5
            var start = r
            if slidesFromLeft { start.origin.x = vf.minX - r.width }
            if slidesFromRight { start.origin.x = vf.maxX }
            let p = NSPanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            prepareOverlay(p, level: .floating, ignoresMouse: false)
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = cleanSpaceGraphite().cgColor
            p.contentView = v
            p.alphaValue = 0
            p.orderFront(nil)
            fadeWindow(p, to: 1, duration: cleanSpaceFade)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = cleanSpaceFade
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(r, display: true)
            }
            cleanDimPanels.append(p)
        }
    }

    func removeCleanDim() {
        for p in cleanDimPanels { p.orderOut(nil) }
        cleanDimPanels.removeAll()
        cleanSpaceShownHole = .zero
    }

    func restoreCleanSpaceFrames() {
        let saved = cleanSpaceSavedFrames
        let all = collectWindows(includeFloated: true, onlyCurrentSpace: false)
        for (key, frame) in saved {
            guard let w = all.first(where: { winKey($0) == key }) else { continue }
            if framesClose(w.frame, frame) { continue }
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
                if self.framesClose(w.frame, frame) { continue }
                self.placeFrame(w.element, frame, key: key, animated: false)
                self.lastPlacedFrames[key] = frame
            }
            self.cleanSpaceSavedFrames = [:]
            self.cleanSpaceHole = .zero
            self.lastSignature = self.fullSignature()
            self.refreshGrips()
            self.refreshDimLayers()
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
        let full = focusFrame(on: screen)
        placeFrame(w.element, full, key: targetKey, animated: true)
        lastPlacedFrames[targetKey] = full
        hideGrips()
        hideHoverBar()
        hideDotHandles()
        hideStackMarkers()
        removeDimLayers()
        closeStackPanel()
        showFocusCaption(on: screen, frame: full)
        log("focus on: \(w.appName)")
    }

    var focusCaptionPanel: NSPanel?

    // Focus caption 瞬时提示状态（不常驻）：进入 Focus 显示 3 秒后淡出，
    // 鼠标进 caption 区外扩 24pt 再现，离开后 1 秒宽限再淡出。
    var focusCaptionShownAt: Date? = nil
    var focusCaptionFadedOut = false
    var focusCaptionZoneOutSince: Date? = nil

    func showFocusCaption(on screen: NSScreen, frame: CGRect) {
        let text = "Focus · click to put it back"
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let w = min((text as NSString).size(withAttributes: [.font: font]).width + 28, screen.visibleFrame.width - 24)
        let h: CGFloat = 28
        let rect = NSRect(x: frame.midX - w / 2, y: frame.maxY - h - 36, width: w, height: h)
        let button = NSButton(title: text, target: self, action: #selector(focusCaptionClick(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = font
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.white,
            .font: font,
        ])
        let v = NSView(frame: NSRect(origin: .zero, size: rect.size))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 0.92).cgColor
        v.layer?.cornerRadius = 8
        button.frame = v.bounds
        button.autoresizingMask = [.width, .height]
        v.addSubview(button)
        if let p = focusCaptionPanel {
            p.setFrame(rect, display: true)
            p.contentView = v
            if p.ignoresMouseEvents { p.ignoresMouseEvents = false }
            p.orderFrontRegardless()
            armFocusCaptionTransient(panel: p)
            return
        }
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        prepareOverlay(p, level: .popUpMenu, ignoresMouse: false)
        p.contentView = v
        p.orderFrontRegardless()
        focusCaptionPanel = p
        armFocusCaptionTransient(panel: p)
    }

    /// 瞬时提示计时起点：显示满 3 秒后淡出；区外计时起点默认为显示时刻，
    /// 故鼠标从未进区时恰在 3 秒处淡出。并清掉在途的旧淡入淡出、恢复不透明可点。
    func armFocusCaptionTransient(panel p: NSPanel) {
        opacityFades.removeAll { $0.window === p }
        p.alphaValue = 1
        p.ignoresMouseEvents = false
        focusCaptionShownAt = Date()
        focusCaptionFadedOut = false
        focusCaptionZoneOutSince = focusCaptionShownAt
    }

    /// Focus caption 瞬时提示的状态机，由 updateHover 的 20Hz 鼠标轮询驱动，
    /// 不新增全局事件监听或 tap。淡出后不 orderOut/nil 面板（供再现），
    /// 只把 ignoresMouseEvents 置 true，使其不挡住其下方的 Focus 握把/条；
    /// 淡入时恢复接收点击。点 caption 仍走 focusCaptionClick 退出 Focus。
    func updateFocusCaption(mouse m: NSPoint) {
        guard focusKey != nil, let panel = focusCaptionPanel, let shownAt = focusCaptionShownAt else { return }
        let zone = panel.frame.insetBy(dx: -24, dy: -24)
        if zone.contains(m) {
            // 在区内：若已淡出则淡入再现并恢复接收点击；清除离开计时。
            focusCaptionZoneOutSince = nil
            if focusCaptionFadedOut {
                focusCaptionFadedOut = false
                panel.ignoresMouseEvents = false
                panel.orderFrontRegardless()
                fadeWindow(panel, to: 1, duration: 0.3)
            }
            return
        }
        // 在区外：已淡出则无事可做。
        if focusCaptionFadedOut { return }
        // 淡出条件：显示满 3 秒，且离开区外满 1 秒宽限（防边缘抖动）。
        let outSince = focusCaptionZoneOutSince ?? shownAt
        let now = Date()
        if now.timeIntervalSince(shownAt) >= 3.0, now.timeIntervalSince(outSince) >= 1.0 {
            focusCaptionFadedOut = true
            fadeWindow(panel, to: 0, duration: 0.3) { [weak panel] in
                panel?.ignoresMouseEvents = true
            }
            return
        }
        // 首次离开区外：记下离开时刻（初始显示时 zoneOutSince 已是 shownAt，
        // 故此分支只在进区后再离开时走到）。
        if focusCaptionZoneOutSince == nil {
            focusCaptionZoneOutSince = now
        }
    }

    @objc func focusCaptionClick(_ sender: NSButton) {
        exitFocus()
        hideHoverBar()
        refreshPanel()
    }

    func hideFocusCaption() {
        if let p = focusCaptionPanel { opacityFades.removeAll { $0.window === p } }
        focusCaptionPanel?.orderOut(nil)
        focusCaptionPanel = nil
        focusCaptionShownAt = nil
        focusCaptionFadedOut = false
        focusCaptionZoneOutSince = nil
    }

    // 只清状态不恢复（Retile 退出、目标消失等走重算的路径用）。
    func disableFocus() {
        focusKey = nil
        focusScreen = nil
        focusSavedFrames = nil
        focusSavedTops = nil
        focusSavedActive = nil
        hideFocusCaption()
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
        hideFocusCaption()
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
                // Dock 点开触发的 Focus：退出时这扇窗仍须留在自己的格子里。
                // 尺寸塞得进格 → 直接落到格子帧（快照帧可能停在别处，会压邻格）；
                // 塞不进 → 重新折回 Dock，不再留在屏上盖邻居。
                if userOpenedKeys.contains(fk),
                   let tiles = lastTilesByScreen[fsid],
                   let idx = tiles.firstIndex(where: { $0.stack.contains { winKey($0) == fk } }),
                   let panes = lastPanesByScreen[fsid], panes.indices.contains(idx) {
                    let pane = panes[idx]
                    let fitsSize = frame.width <= pane.width + 1.5 && frame.height <= pane.height + 1.5
                    if fitsSize {
                        placeFrame(fw.element, pane, key: fk, animated: true)
                        lastPlacedFrames[fk] = pane
                    } else if hideFoldedWindow(fw) {
                        markFolded(key: fk, sid: fsid)
                        userOpenedKeys.remove(fk)
                        log("focus off: \(fw.appName) still oversize, folded back to Dock")
                    }
                }
            }
            if let savedTops { for (k, v) in savedTops { stackTops[k] = v } }
            if let savedActive { lastActiveTileByScreen[fsid] = savedActive }
            refreshGrips()
            refreshDimLayers()
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

    /// 创建过滤型事件 tap，识别按住 ⌘ / ⌥⌘ 的窗口拖动。
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

    // MARK: - D 批 ⌘拖交换 / ⌥⌘拖进堆叠

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
    // 悬停条会在拖动开始后收起；否则在标题栏区停留 0.15s 出条后，
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
    /// 普通拖跟随候选：点落在某格内、该格多窗时记下快照；单窗格、Focus/Clean 下不跟随。
    /// 抓的是格顶（可见窗），跟随者是叠内其余成员；起始帧取上次摆铺帧，缺失则取格帧。
    func plainTrackCandidate(at p: CGPoint, sid: CGDirectDisplayID) -> PlainDragTrack? {
        guard focusKey == nil, !cleanSpaceOn,
              let tiles = lastTilesByScreen[sid],
              let tile = tiles.first(where: { $0.frame.contains(p) }),
              tile.stack.count > 1 else { return nil }
        let topKey = winKey(tile.top)
        let followers = tile.stack.filter { winKey($0) != topKey }.map {
            (key: winKey($0), el: $0.element, start: lastPlacedFrames[winKey($0)] ?? tile.frame)
        }
        guard !followers.isEmpty else { return nil }
        return PlainDragTrack(sid: sid, tileFrame: tile.frame, topKey: topKey,
                              topElement: tile.top.element, topStart: lastPlacedFrames[topKey] ?? tile.frame,
                              followers: followers)
    }

    // 拖动对象解析（与悬停条按钮同一语义）：拖的是点按/转换时刻的受管前台窗口，
    // 不是鼠标所在格的账面顶。返回（窗口键，所在格下标，所在屏，失败原因）。
    // 前台窗口已浮动或不在任何格里时返回失败——调用方不启动 TileProto 拖动，放行系统原生拖动。
    func resolveDragSubject() -> (key: String, tile: Int, sid: CGDirectDisplayID, failure: String?) {
        let (wOpt, failure) = resolveCurrentTarget()
        guard let w = wOpt else { return ("", -1, 0, failure) }
        let key = winKey(w)
        let sid = screenID(screenForFrame(w.frame))
        guard let tiles = lastTilesByScreen[sid],
              let tile = tiles.firstIndex(where: { $0.stack.contains { winKey($0) == key } }) else {
            return ("", -1, 0, "frontmost window \(w.appName) not in tiles")
        }
        return (key, tile, sid, nil)
    }

    func dragMouseDown(_ event: CGEvent) -> Bool {
        guard AXIsProcessTrusted(), autoTile else { return false }
        plainDragTrack = nil
        dragFollowPending = nil
        dragLastWritten = nil
        dragConvertDeclineLogged = false
        let flags = event.flags
        // 按下时没按 ⌘也记下按下点：拖动中才按住 ⌘时，可从按下点重建拖动。
        if !flags.contains(.maskCommand) {
            let dp = cocoaPoint(fromQuartz: event.location) ?? event.location
            if !pointOnOwnInteractiveWindow(dp) {
                plainDownPoint = dp
                let sid = screenID(NSScreen.screens.first(where: { $0.frame.contains(dp) }) ?? NSScreen.main ?? NSScreen.screens[0])
                plainDownScreenID = sid
                plainDragTrack = plainTrackCandidate(at: dp, sid: sid)
            } else {
                plainDownPoint = nil; plainDownScreenID = nil
            }
            return false
        }
        let p = cocoaPoint(fromQuartz: event.location) ?? event.location
        guard !pointOnOwnInteractiveWindow(p) else { return false }
        // C 批：拖动只在鼠标所在屏的磁贴上进行（拦截边界仍按鼠标点，不扩大到桌面/其他 App 的 ⌘拖）。
        let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let sid = screenID(screen)
        guard let tiles = lastTilesByScreen[sid], tiles.count > 1 else { return false }
        let frames = tiles.map { $0.frame }
        guard frames.contains(where: { $0.contains(p) }) else { return false }
        // 拖动对象为点按时刻的受管前台窗口（与悬停条按钮同一语义），不是鼠标所在格的账面顶。
        // 字面语义：按住 ⌘抓一扇后台窗时，拖的仍是前台窗口（见回报边角）。
        let (dragKey, src, subSid, failure) = resolveDragSubject()
        guard failure == nil else {
            log("drag skipped: \(failure ?? "unknown")")
            return false
        }
        guard subSid == sid, src < tiles.count else {
            log("drag skipped: frontmost window on another screen")
            return false
        }
        // ⌘ 交换；再按住 ⌥ 则加入堆叠。只认 option 与 command。
        let mode = dragMode(from: flags)
        var pending = DragState(mode: mode, sourceTile: src, draggedKey: dragKey, frames: frames, screenID: sid)
        pending.tileTopKeys = tiles.map { winKey($0.top) }
        pendingDrag = pending
        pendingDragPoint = p
        return false
    }

    // 按下时已经按着 ⌘：3pt 以内也吞掉拖动，系统不会另开一次窗口拖拽跟我们抢位置。
    // 超过 3pt 才抬起窗口跟手。抓后才按 ⌘ 的那条路径系统已经在拖，我们不再搬窗口。
    func dragMouseDragged(_ event: CGEvent) -> Bool {
        let p = cocoaPoint(fromQuartz: event.location) ?? event.location
        if focusKey != nil {
            if let origin = plainDownPoint ?? (pendingDrag != nil ? pendingDragPoint : nil) {
                let dx = p.x - origin.x
                let dy = p.y - origin.y
                if dx * dx + dy * dy > 16 {
                    exitFocus()
                    pendingDrag = nil
                    dragState = nil
                    plainDragTrack = nil
                    plainDownPoint = p
                    log("focus off: drag")
                    return false
                }
            }
        }
        // 普通拖整叠跟随：格顶实际移动了才跟随（delta 驱动）；格顶不动不跟随。
        // 格子变了（窗口增减重算、成员集合不等）或格顶帧已读不到时丢弃快照。
        // 缝拖动时 draggingDividerID 非空，跳过；tick 弹回只在松手后跑，不与跟随打架。
        if dragState == nil, pendingDrag == nil, !event.flags.contains(.maskCommand),
           draggingDividerID == nil, var tr = plainDragTrack {
            var valid = false
            if let tiles = lastTilesByScreen[tr.sid],
               let tile = tiles.first(where: { $0.frame == tr.tileFrame }) {
                valid = Set(tile.stack.map { winKey($0) }) == Set([tr.topKey] + tr.followers.map { $0.key })
            }
            if !valid {
                plainDragTrack = nil
            } else if let live = getFrame(tr.topElement, screenHeight: mainHeight()) {
                let dx = live.minX - tr.topStart.minX, dy = live.minY - tr.topStart.minY
                if abs(dx - tr.lastDelta.x) >= 1 || abs(dy - tr.lastDelta.y) >= 1 {
                    tr.lastDelta = CGPoint(x: dx, y: dy)
                    plainDragTrack = tr
                    let mh = mainHeight()
                    for f in tr.followers {
                        // 只平移、不改尺寸：最小尺寸顶住的成员保持原尺寸。
                        setPositionQuiet(f.el, CGPoint(x: f.start.minX + dx, y: mh - (f.start.maxY + dy)))
                    }
                }
            }
        }
        if dragState == nil, pendingDrag == nil, event.flags.contains(.maskCommand),
           let dp = plainDownPoint, let dsid = plainDownScreenID {
            let dx = p.x - dp.x, dy = p.y - dp.y
            if dx * dx + dy * dy > 9,
               NSScreen.screens.contains(where: { screenID($0) == dsid }),
               let tiles = lastTilesByScreen[dsid], tiles.count > 1 {
                let frames = tiles.map { $0.frame }
                // 转换门限仍按原始按下点在格内（不扩大到其他 App 的拖动）；对象按转换时刻的前台窗口解析。
                if frames.contains(where: { $0.contains(dp) }) {
                    let (dragKey, src, subSid, failure) = resolveDragSubject()
                    if failure != nil || subSid != dsid || src >= tiles.count {
                        if !dragConvertDeclineLogged {
                            dragConvertDeclineLogged = true
                            log("drag convert skipped: \(failure ?? "frontmost window on another screen")")
                        }
                    } else {
                        let mode = dragMode(from: event.flags)
                        var d = DragState(mode: mode, sourceTile: src, draggedKey: dragKey, frames: frames, screenID: dsid)
                        d.tileTopKeys = tiles.map { winKey($0.top) }
                        d.ownsDrag = false
                        d.originFrame = lastPlacedFrames[dragKey] ?? frames[src]
                        dragState = d
                        dragQuiet = true
                        dimsSuppressed = true
                        removeDimLayers()
                        plainDownPoint = nil; plainDownScreenID = nil
                        plainDragTrack = nil
                        hideHoverBar()
                        log("drag start mode=\(mode == .swap ? "swap" : "stack") tile=\(src) (mid-drag ⌘)")
                    }
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
        // 拖动中布局变了就刷新落点快照（帧与顶），原点与源格身份不动。
        refreshDragSnapshot(&d)
        // 拖动中按住或松开 ⌥：松手那一刻的组合决定交换还是进叠。
        applyDragMode(&d, flags: event.flags)
        if d.ownsDrag { trackOwnedDrag(&d, pointer: p) }
        updateDragTarget(&d, pointer: p)
        return true
    }

    /// 松手时的修饰键决定交换还是进叠。进叠必须同时按着 Option 和 Command。
    func dragMode(from flags: CGEventFlags) -> DragMode {
        let chord = dragChord(command: flags.contains(.maskCommand),
                              option: flags.contains(.maskAlternate),
                              control: flags.contains(.maskControl))
        return chord == .stack ? .stack : .swap
    }

    func applyDragMode(_ d: inout DragState, flags: CGEventFlags) {
        let mode = dragMode(from: flags)
        guard mode != d.mode else { return }
        if d.mode == .swap, mode == .stack, let old = d.reactKey, let el = dragReactElement {
            frameMotions.removeValue(forKey: old)
            placeFrame(el, d.reactHome, key: old, animated: true, ease: .settle, duration: 0.16)
            gestureHeldKeys.remove(old)
            d.reactKey = nil
            d.reactHome = .zero
            dragReactElement = nil
        }
        d.mode = mode
        dragState = d
    }

    // 拖动中刷新落点快照：按 lastTilesByScreen 的现势校验格数/帧/顶，变了就刷新
    // frames 与 tileTopKeys；originFrame 与源格身份保持拖开始时不动。
    // 帧变了时目标下标清零，迫使 updateDragTarget 按新帧重算圈与反应，避免旧下标指错格。
    func refreshDragSnapshot(_ d: inout DragState) {
        guard let tiles = lastTilesByScreen[d.screenID] else { return }
        let frames = tiles.map { $0.frame }
        let tops = tiles.map { winKey($0.top) }
        guard frames != d.frames || tops != d.tileTopKeys else { return }
        if let rk = d.reactKey, let idx = tops.firstIndex(of: rk) {
            d.reactHome = frames[idx]
        }
        d.frames = frames
        d.tileTopKeys = tops
        d.targetTile = nil
    }

    // 松手：落到另一磁贴就交换或进堆叠，两边从当前帧落定到最终格子。
    // 否则把抬起的窗口放回原格。按下时已按 ⌘ 的拖动吞掉这次松手；系统已经在拖的不吞。
    // 交换还是进叠看松手时的修饰键，拖到一半也可以改。
    func dragMouseUp(_ event: CGEvent) -> Bool {
        guard var d = dragState else {
            pendingDrag = nil
            plainDownPoint = nil; plainDownScreenID = nil
            plainDragTrack = nil
            dragFollowPending = nil
            dragLastWritten = nil
            dragConvertDeclineLogged = false
            return false
        }
        applyDragMode(&d, flags: event.flags)
        dragState = nil
        plainDragTrack = nil
        dragQuiet = false
        hideDragRing()
        // 跟手合并的未写指针直接丢弃（落定/交换会重排，不需要补写最后一帧）。
        dragFollowPending = nil
        dragLastWritten = nil
        dragConvertDeclineLogged = false
        // 落点前按现势刷新一次快照，再判定目标。
        refreshDragSnapshot(&d)
        let p = cocoaPoint(fromQuartz: event.location) ?? event.location
        var target = d.frames.firstIndex(where: { $0.contains(p) })
        if target == nil,
           let screen = NSScreen.screens.first(where: { screenID($0) == d.screenID }),
           screen.visibleFrame.contains(p) {
            // 缝上吸附：指针落在 8pt 缝里（不属于任何格子帧）时不再直接取消，
            // 吸附到最近的格子（源格除外）；落到菜单栏/Dock/屏外仍取消。
            var best: Int? = nil
            var bestDist = CGFloat.greatestFiniteMagnitude
            for (i, f) in d.frames.enumerated() where i != d.sourceTile {
                let dx = max(max(f.minX - p.x, 0), p.x - f.maxX)
                let dy = max(max(f.minY - p.y, 0), p.y - f.maxY)
                let dist = dx * dx + dy * dy
                if dist < bestDist { bestDist = dist; best = i }
            }
            target = best
        }
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
        }
        return d.ownsDrag
    }

    func dragCancel() {
        let d = dragState
        dragState = nil
        pendingDrag = nil
        plainDownPoint = nil; plainDownScreenID = nil
        plainDragTrack = nil
        dragFollowPending = nil
        dragLastWritten = nil
        dragConvertDeclineLogged = false
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
        guard d.ownsDrag, dragLiftElement != nil else { return }
        let screen = NSScreen.screens.first(where: { screenID($0) == d.screenID })
        let vf = screen?.visibleFrame ?? .zero
        guard vf.width > 1, d.originFrame.width > 1 else { return }
        // 跟手合并（与缝拖动同一模式）：只记最新指针，主队列异步块按最新指针写一次 AX 帧；
        // 多个事件到达时只覆盖 pending，不排队。94% 抬起缩放比例不动。
        // 手势边界（按下/松手/取消）都会清 pending，旧块见 pending 为空或 dragState 为空即空转，
        // 不会把旧指针写到新拖动上。
        dragFollowPending = pointer
        if !dragFollowScheduled {
            dragFollowScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.dragFollowScheduled = false
                guard let p = self.dragFollowPending else { return }
                self.dragFollowPending = nil
                guard let dd = self.dragState, dd.ownsDrag, let el = self.dragLiftElement else { return }
                let screen = NSScreen.screens.first(where: { self.screenID($0) == dd.screenID })
                let vf = screen?.visibleFrame ?? .zero
                guard vf.width > 1, dd.originFrame.width > 1 else { return }
                self.frameMotions.removeValue(forKey: dd.draggedKey)
                let frame = self.liftFrame(origin: dd.originFrame, grab: dd.grabOffset, pointer: p, vf: vf)
                // 指针微动（<0.5pt）且上次已写过同一帧：跳过 AX 写；手势边界已清缓存，
                // 故跨手势不会误跳，窗在格子里被弹回后下一笔也必然重写。
                if let last = self.dragLastWritten, last.key == dd.draggedKey,
                   abs(last.frame.minX - frame.minX) < 0.5, abs(last.frame.minY - frame.minY) < 0.5,
                   abs(last.frame.width - frame.width) < 0.5, abs(last.frame.height - frame.height) < 0.5 {
                    return
                }
                self.applyAXFrame(el, frame)
                self.dragLastWritten = (dd.draggedKey, frame)
            }
        }
    }

    func updateDragTarget(_ d: inout DragState, pointer: CGPoint) {
        let target = d.frames.firstIndex(where: { $0.contains(pointer) })
        if target == d.targetTile {
            dragState = d
            return
        }
        if let old = d.reactKey, let el = dragReactElement {
            // 旧反应直接取消、不带动画恢复：快速换目标时新旧 0.16s 动画不再重叠闪烁。
            frameMotions.removeValue(forKey: old)
            placeFrame(el, d.reactHome, key: old, animated: false)
            gestureHeldKeys.remove(old)
        }
        d.reactKey = nil
        d.reactHome = .zero
        dragReactElement = nil
        d.targetTile = target
        if let t = target, t != d.sourceTile {
            let label = d.mode == .stack ? "Add to stack" : nil
            showDragRing(frame: d.frames[t], label: label)
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

    final class DragRingView: NSView {
        var label: String? = nil {
            didSet { needsDisplay = true }
        }
        override func draw(_ dirtyRect: NSRect) {
            let pad: CGFloat = 3
            let stroke = NSBezierPath(roundedRect: bounds.insetBy(dx: pad * 0.35, dy: pad * 0.35), xRadius: 10, yRadius: 10)
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
            stroke.lineWidth = 2
            stroke.stroke()
            guard let label, !label.isEmpty else { return }
            let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            let bubble = NSRect(
                x: (bounds.width - size.width - 16) / 2,
                y: (bounds.height - size.height - 10) / 2,
                width: size.width + 16,
                height: size.height + 10
            )
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 8, yRadius: 8).fill()
            (label as NSString).draw(at: NSPoint(x: bubble.minX + 8, y: bubble.minY + 5), withAttributes: attrs)
        }
    }

    // 拖动目标圈：落点高亮；进叠时中央写 Add to stack。
    func showDragRing(frame: CGRect, label: String? = nil) {
        let f = frame.insetBy(dx: -tileBorderPad, dy: -tileBorderPad)
        if let p = dragRingPanel {
            if p.frame != f { p.setFrame(f, display: true) }
            (p.contentView as? DragRingView)?.label = label
            p.contentView?.needsDisplay = true
            if !p.isVisible { p.orderFront(nil) }
            return
        }
        let view = DragRingView(frame: NSRect(origin: .zero, size: f.size))
        view.label = label
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        prepareOverlay(p, level: .popUpMenu, ignoresMouse: true)
        p.contentView = view
        p.orderFront(nil)
        dragRingPanel = p
    }

    func hideDragRing() {
        dragRingPanel?.orderOut(nil)
        (dragRingPanel?.contentView as? DragRingView)?.label = nil
    }

    // 整叠交换：对调源格与目标格的全部成员（叠内顺序与栈顶随叠走），而非只换两扇顶窗。
    // 只换显示格的置换：格子几何不动、windowOrder/stackedOnto/Primary 都不动，
    // 因此后续重算不会把交换 undo；Primary 窗随其所在叠一起走，仍是该叠的顶。
    // 单窗格对调一扇窗，与旧行为一致。落点判定与失败日志语义不动。
    // 调用前已把 preferredEase 设成 settle，forceTile 会从抬起/内缩的当前位置落到新格子，不过冲。
    @discardableResult
    func performDragSwap(from src: Int, to dst: Int, screenID sid: CGDirectDisplayID, draggedKey: String, targetKey: String) -> Bool {
        guard AXIsProcessTrusted() else { log("drag swap skipped: not trusted"); return false }
        guard let tiles = lastTilesByScreen[sid], src < tiles.count, dst < tiles.count, src != dst else {
            log("drag swap skipped: bad tiles"); return false
        }
        let screen = NSScreen.screens.first(where: { screenID($0) == sid }) ?? NSScreen.main ?? NSScreen.screens[0]
        let windows = collectWindows(on: screen)
        guard !windows.isEmpty else { log("drag swap skipped: no windows"); return false }
        guard let topA = windows.first(where: { winKey($0) == draggedKey }) else {
            log("drag swap skipped: dragged window gone")
            return false
        }
        var perm = sanitizedSwapPerm(tileSwapPermByScreen[sid], count: tiles.count)
        perm.swapAt(src, dst)
        if perm == Array(0..<tiles.count) { tileSwapPermByScreen.removeValue(forKey: sid) } else { tileSwapPermByScreen[sid] = perm }
        let srcStack = tiles[src].stack, dstStack = tiles[dst].stack
        let targetApp = windows.first(where: { winKey($0) == targetKey })?.appName ?? tiles[dst].top.appName
        for w in srcStack + dstStack {
            preferredEase[winKey(w)] = .settle
            frameMotions.removeValue(forKey: winKey(w))
        }
        log("drag swap tile \(src) <-> \(dst): \(topA.appName) <-> \(targetApp) (stacks \(srcStack.count) <-> \(dstStack.count))")
        noteMove()
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
        let (stacks, _, _) = computeTiles(windows: windows, st: layoutSettings(for: screen), sid: sid)
        guard dst < stacks.count else { return }
        // 进堆目标是显示格；计算侧用计算格下标（置换翻译），日志仍用显示格。
        let rawDst = permSrcSlot(dst, sid: sid)
        guard let w = windows.first(where: { winKey($0) == draggedKey }) else {
            log("drag stack skipped: dragged window gone")
            return
        }
        guard let src = stacks.firstIndex(where: { $0.contains { winKey($0) == draggedKey } }) else {
            log("drag stack skipped: source tile gone")
            return
        }
        guard src != rawDst else { return }
        let destTop = stacks[rawDst][min(stackTops[stackTopKey(sid, rawDst)] ?? 0, stacks[rawDst].count - 1)]
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
        let (stacks2, _, _) = computeTiles(windows: windows, st: layoutSettings(for: screen), sid: sid)
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
        noteMove()
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
    tileProtoCheck(abs(grid3[0].width - (vf.width - 2 * gap)) < 0.6, "grid 3 top spans the full width")
    tileProtoCheck(grid3[0].minY > grid3[1].maxY && abs(grid3[0].minY - grid3[1].maxY - gap) < 0.6, "grid 3 top row sits one gap above the bottom row")
    tileProtoCheck(abs(grid3[1].minY - grid3[2].minY) < 0.6 && abs(grid3[1].width - grid3[2].width) < 0.6, "grid 3 bottom row is two equal cells")

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
    tileProtoCheck(abs(quads[0].width - quads[3].width) < 0.6 && abs(quads[0].height - quads[3].height) < 0.6, "grid 4 left column is a vertical pair")

    let wide4 = layoutFrames(count: 4, vf: vf, kind: .grid, share: 0.6, gap: gap)
    tileProtoCheck(wide4[0].width > wide4[1].width + 20, "60% widens the left column in grid 4")
    tileProtoCheck(abs(wide4[0].height - wide4[3].height) < 0.6, "grid 4 splits the left column evenly")
    tileProtoCheck(abs(wide4[0].width - wide4[3].width) < 0.6, "grid 4 left cells share one width")

    let one = layoutFrames(count: 1, vf: vf, kind: .grid, share: 0.5, gap: gap)
    tileProtoCheck(one.count == 1, "single tile count")
    tileProtoCheck(abs(one[0].minX - (vf.minX + gap)) < 0.6, "single tile keeps the left gap")
    tileProtoCheck(abs(one[0].width - (vf.width - 2 * gap)) < 0.6, "single tile keeps both edge gaps")
    let oneFlush = layoutFrames(count: 1, vf: vf, kind: .grid, share: 0.5, gap: 0)
    tileProtoCheck(oneFlush[0] == vf, "zero gap fills the work area")

    tileProtoCheck(WhenFull.stack.rawValue == 0 && WhenFull.float.rawValue == 1, "when-full raw values")

    // 点面板外关面板：面板内、菜单栏图标上都不算外侧，其它任何位置都算。
    let panelRect = CGRect(x: 100, y: 400, width: 320, height: 500)
    let statusRect = CGRect(x: 1300, y: 950, width: 30, height: 30)
    tileProtoCheck(!panelClickIsOutside(CGPoint(x: 200, y: 500), panelFrame: panelRect, statusFrame: statusRect), "click inside the panel keeps it open")
    tileProtoCheck(!panelClickIsOutside(CGPoint(x: 1310, y: 960), panelFrame: panelRect, statusFrame: statusRect), "click on the menu bar item is left to the toggle")
    tileProtoCheck(panelClickIsOutside(CGPoint(x: 20, y: 20), panelFrame: panelRect, statusFrame: statusRect), "click elsewhere dismisses the panel")
    tileProtoCheck(panelClickIsOutside(CGPoint(x: 900, y: 500), panelFrame: panelRect, statusFrame: statusRect), "click beside the panel dismisses it")

    // 栈顶复核：目标格装不下栈顶时，换成真的落进格子的成员；全都不进格就保持原样。
    let paneRect = CGRect(x: 8, y: 41, width: 744, height: 431)
    let tallTop = CGRect(x: 8, y: 41, width: 744, height: 520)
    let insideMember = CGRect(x: 8, y: 41, width: 744, height: 431)
    tileProtoCheck(stackTopToPromote(top: 0, frames: [tallTop, insideMember], pane: paneRect) == 1, "an overflowing stack top hands over to a member that fits")
    tileProtoCheck(stackTopToPromote(top: 0, frames: [tallTop, tallTop], pane: paneRect) == nil, "no member fits, so the stack top stays")
    tileProtoCheck(stackTopToPromote(top: 0, frames: [insideMember, tallTop], pane: paneRect) == nil, "a stack top inside its pane is left alone")
    tileProtoCheck(stackTopToPromote(top: 5, frames: [insideMember], pane: paneRect) == nil, "an out-of-range top index is ignored")

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
    let narrow = layoutFrames(count: 3, vf: vf, kind: .columns, share: 0.5, gap: gap)
    tileProtoCheck(narrow[0].width + tileFitTolerance < 900, "a column is narrower than 900pt")
    let onePane = layoutFrames(count: 1, vf: vf, kind: .columns, share: 0.5, gap: gap)
    tileProtoCheck(onePane[0].width + tileFitTolerance >= 900, "one pane still holds 900pt")
    let merged = planTileFit(needs: needs, groups: [[0], [1], [2]], bound: [:]) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .columns, share: 0.5, gap: gap)
    }
    tileProtoCheck(merged.floated.isEmpty, "a 900pt window on a 1200pt screen stays tiled")
    tileProtoCheck(merged.groups.count == 3, "a wide window does not collapse the layout to one pane")
    tileProtoCheck(merged.groups.contains { $0 == [0] }, "the wide window stays in its own pane")

    let boundPlan = planTileFit(needs: needs, groups: [[0], [1], [2]], bound: [1: 0]) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .columns, share: 0.5, gap: gap)
    }
    tileProtoCheck(boundPlan.groups.count == 3 && boundPlan.floated.isEmpty, "a manual stack does not erase panes to stay together")

    let huge = planTileFit(needs: [CGSize(width: 1300, height: 400)], groups: [[0]], bound: [:]) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .columns, share: 0.5, gap: gap)
    }
    tileProtoCheck(huge.floated == [0] && huge.groups.isEmpty, "wider than the screen floats and leaves the tiling")

    let mixedHuge = planTileFit(
        needs: [CGSize(width: 1300, height: 400), CGSize(width: 200, height: 200), CGSize(width: 200, height: 200)],
        groups: [[0], [1], [2]],
        bound: [:]
    ) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .columns, share: 0.5, gap: gap)
    }
    tileProtoCheck(mixedHuge.floated == [0], "one oversized window floats out of a multi-pane layout")
    tileProtoCheck(mixedHuge.groups.count == 2, "the panes that still fit stay on screen")

    let already = planTileFit(
        needs: [CGSize(width: 200, height: 200), CGSize(width: 200, height: 200), CGSize(width: 200, height: 200)],
        groups: [[0], [1], [2]],
        bound: [:]
    ) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .columns, share: 0.5, gap: gap)
    }
    tileProtoCheck(already.groups.count == 3 && already.floated.isEmpty, "windows that fit stay in their own cells")

    let sidePreview = layoutFrames(count: 3, vf: vf, kind: .side, share: 0.5, gap: gap)
    tileProtoCheck(sidePreview[1].height + tileFitTolerance < 500, "side small cell is shorter than the tall window")
    tileProtoCheck(sidePreview[0].height + tileFitTolerance >= 500, "side primary holds the tall window")
    // 高窗独自占着一小格时，搬去大格会少掉一格。布局保持三格，高窗留在原格。
    let sideAlone = planTileFit(
        needs: [
            CGSize(width: 400, height: 500),
            CGSize(width: 200, height: 200),
            CGSize(width: 200, height: 200),
        ],
        groups: [[1], [0], [2]],
        bound: [:]
    ) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .side, share: 0.5, gap: gap)
    }
    tileProtoCheck(sideAlone.groups.count == 3 && sideAlone.floated.isEmpty, "a lone tall window does not erase its pane")
    tileProtoCheck(sideAlone.groups.contains { $0 == [0] }, "the lone tall window stays where it was")
    // 小格里还有别的窗口时，高窗可以进大格，小格留下那一扇，格数不变。
    let sideJoined = planTileFit(
        needs: [
            CGSize(width: 400, height: 500),
            CGSize(width: 200, height: 200),
            CGSize(width: 200, height: 200),
            CGSize(width: 200, height: 200),
        ],
        groups: [[1], [0, 3], [2]],
        bound: [:]
    ) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .side, share: 0.5, gap: gap)
    }
    let joinedPrimary = sideJoined.groups.contains { $0.contains(0) && $0.contains(1) }
    let keptSource = sideJoined.groups.contains { $0.contains(3) && !$0.contains(0) }
    let keptNeighbor = sideJoined.groups.contains { $0.contains(2) && !$0.contains(0) }
    tileProtoCheck(sideJoined.groups.count == 3 && sideJoined.floated.isEmpty && joinedPrimary && keptSource && keptNeighbor, "a tall window joins the large cell and leaves the other panes")

    let manualNeeds = [
        CGSize(width: 400, height: 500),
        CGSize(width: 200, height: 200),
        CGSize(width: 200, height: 200),
        CGSize(width: 200, height: 200),
        CGSize(width: 200, height: 200),
    ]
    let manualPlan = planTileFit(needs: manualNeeds, groups: [[2], [0, 1, 3], [4]], bound: [1: 0]) { groups in
        layoutFrames(count: groups.count, vf: vf, kind: .side, share: 0.5, gap: gap)
    }
    let movedTogether = manualPlan.groups.contains { $0.contains(0) && $0.contains(1) && $0.contains(2) }
    let leftSpare = manualPlan.groups.contains { $0.contains(3) && !$0.contains(0) }
    tileProtoCheck(manualPlan.groups.count == 3 && manualPlan.floated.isEmpty && movedTogether && leftSpare, "a manual stack follows its root into a cell that fits")

    let mac = CGRect(x: 0, y: 78, width: 1440, height: 798)
    let macGap: CGFloat = 8
    for n in 1...4 {
        tileProtoCheck(layoutCountFits(n, kind: .grid, vf: mac, gap: macGap), "macbook grid \(n) fits")
    }
    tileProtoCheck(layoutCountFits(3, kind: .columns, vf: mac, gap: macGap), "macbook columns 3 fits")
    tileProtoCheck(!layoutCountFits(4, kind: .columns, vf: mac, gap: macGap), "macbook columns 4 does not fit")
    tileProtoCheck(layoutCountFits(2, kind: .rows, vf: mac, gap: macGap), "macbook rows 2 fits")
    tileProtoCheck(!layoutCountFits(3, kind: .rows, vf: mac, gap: macGap), "macbook rows 3 does not fit")
    tileProtoCheck(!layoutCountFits(4, kind: .rows, vf: mac, gap: macGap), "macbook rows 4 does not fit")
    tileProtoCheck(layoutCountFits(3, kind: .side, vf: mac, gap: macGap), "macbook side 3 fits")
    tileProtoCheck(!layoutCountFits(4, kind: .side, vf: mac, gap: macGap), "macbook side 4 does not fit")
    tileProtoCheck(effectiveTileLimit(4, kind: .columns, vf: mac, gap: macGap) == 3, "columns limit clamps to 3")
    tileProtoCheck(effectiveTileLimit(4, kind: .grid, vf: mac, gap: macGap) == 4, "grid keeps 4")
    tileProtoCheck(effectiveTileLimit(4, kind: .rows, vf: mac, gap: macGap) == 2, "rows limit clamps to 2")
    tileProtoCheck(effectiveTileLimit(4, kind: .side, vf: mac, gap: macGap) == 3, "side limit clamps to 3")
    tileProtoCheck(defaultTileLimit == 4, "default tile limit is 4")
    tileProtoCheck(visiblePaneTarget(kind: .grid, vf: mac, gap: macGap) == 4, "grid shows 4 panes on a macbook")
    tileProtoCheck(visiblePaneTarget(kind: .columns, vf: mac, gap: macGap) == 3, "columns show 3 panes on a macbook")
    tileProtoCheck(visiblePaneTarget(kind: .rows, vf: mac, gap: macGap) == 2, "rows show 2 panes on a macbook")
    tileProtoCheck(visiblePaneTarget(kind: .side, vf: mac, gap: macGap) == 3, "side shows 3 panes on a macbook")
    tileProtoCheck(tileLimitForFamilyChange(saved: 3, kind: .grid, vf: mac, gap: macGap) == 4, "picking grid raises a saved limit of 3")
    tileProtoCheck(tileLimitForFamilyChange(saved: 3, kind: .side, vf: mac, gap: macGap) == 3, "picking side keeps a saved limit of 3")
    tileProtoCheck(tileLimitForFamilyChange(saved: 4, kind: .rows, vf: mac, gap: macGap) == 4, "picking rows does not lower a saved limit of 4")
    tileProtoCheck(tileLimitForFamilyChange(saved: 1, kind: .columns, vf: mac, gap: macGap) == 3, "picking columns raises a one-pane layout to 3")
    tileProtoCheck(effectiveTileLimit(tileLimitForFamilyChange(saved: 4, kind: .rows, vf: mac, gap: macGap), kind: .rows, vf: mac, gap: macGap) == 2, "saved 4 still draws 2 rows on a macbook")

    let overflowTargets = overflowStackTargets(windowCount: 17, tileCount: 3, active: 1)
    tileProtoCheck(Array(overflowTargets.prefix(3)) == [0, 1, 2], "the first three windows open their own panes")
    tileProtoCheck(overflowTargets.dropFirst(3).allSatisfy { $0 == 1 }, "every extra window stacks in the active pane")
    tileProtoCheck(overflowStackTargets(windowCount: 3, tileCount: 0, active: 5) == [0, 0, 0], "zero panes does not divide by zero")
    tileProtoCheck(overflowStackTargets(windowCount: 0, tileCount: 3, active: 0).isEmpty, "no windows means no targets")

    func stackedGroups(_ total: Int, panes: Int, active: Int = 0) -> [[Int]] {
        let targets = overflowStackTargets(windowCount: total, tileCount: panes, active: active)
        var grouped = Array(repeating: [Int](), count: panes)
        for ordinal in 0..<total { grouped[targets[ordinal]].append(ordinal) }
        return grouped
    }
    let busyNeeds = (0..<17).map { _ in CGSize(width: 280, height: 180) }
    for kind in [LayoutKind.grid, .columns, .rows, .side] {
        let panes = effectiveTileLimit(defaultTileLimit, kind: kind, vf: mac, gap: macGap)
        let plan = planTileFit(needs: busyNeeds, groups: stackedGroups(17, panes: panes), bound: [:]) { groups in
            layoutFrames(count: groups.count, vf: mac, kind: kind, share: 0.5, gap: macGap)
        }
        let name = layoutFamilyName(kind)
        tileProtoCheck(plan.groups.count == panes, "busy \(name) keeps \(panes) panes")
        tileProtoCheck(plan.floated.isEmpty, "busy \(name) keeps normal windows tiled")
        let counts = plan.groups.map { $0.count }
        tileProtoCheck(counts == [18 - panes] + Array(repeating: 1, count: panes - 1), "busy \(name) stacks the extras in the active pane")
    }
    let wideNeeds = (0..<9).map { _ in CGSize(width: 800, height: 220) }
    let wideColumns = planTileFit(needs: wideNeeds, groups: stackedGroups(9, panes: 3), bound: [:]) { groups in
        layoutFrames(count: groups.count, vf: mac, kind: .columns, share: 0.5, gap: macGap)
    }
    tileProtoCheck(wideColumns.groups.count == 3 && wideColumns.floated.isEmpty, "800pt windows stay in three columns")
    let wideGrid = planTileFit(needs: wideNeeds, groups: stackedGroups(9, panes: 4), bound: [:]) { groups in
        layoutFrames(count: groups.count, vf: mac, kind: .grid, share: 0.5, gap: macGap)
    }
    tileProtoCheck(wideGrid.groups.count == 4 && wideGrid.floated.isEmpty, "800pt windows do not collapse a grid of four")

    func familySignature(_ kind: LayoutKind) -> String {
        let panes = effectiveTileLimit(defaultTileLimit, kind: kind, vf: mac, gap: macGap)
        return layoutFrames(count: panes, vf: mac, kind: kind, share: 0.5, gap: macGap).map { frame in
            "\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())),\(Int(frame.width.rounded())),\(Int(frame.height.rounded()))"
        }.joined(separator: "|")
    }
    var familyShapes: Set<String> = []
    for kind in [LayoutKind.grid, .columns, .rows, .side] {
        let panes = effectiveTileLimit(defaultTileLimit, kind: kind, vf: mac, gap: macGap)
        tileProtoCheck(panes > 1, "\(layoutFamilyName(kind)) is not one full-screen pane")
        let shape = familySignature(kind)
        tileProtoCheck(!familyShapes.contains(shape), "\(layoutFamilyName(kind)) geometry differs from the other families")
        familyShapes.insert(shape)
    }
    let macGrid3 = layoutFrames(count: 3, vf: mac, kind: .grid, share: 0.5, gap: macGap)
    let macSide3 = layoutFrames(count: 3, vf: mac, kind: .side, share: 0.5, gap: macGap)
    tileProtoCheck(macGrid3 != macSide3, "grid 3 differs from side 3")
    let macGrid4 = layoutFrames(count: 4, vf: mac, kind: .grid, share: 0.5, gap: macGap)
    tileProtoCheck(macGrid4 != macSide3, "grid 4 is not the side shape")
    var walkLimit = 3
    var walkShapes: [String] = []
    for kind in [LayoutKind.columns, .grid, .rows, .side] {
        walkLimit = tileLimitForFamilyChange(saved: walkLimit, kind: kind, vf: mac, gap: macGap)
        let panes = effectiveTileLimit(walkLimit, kind: kind, vf: mac, gap: macGap)
        let shape = layoutFrames(count: panes, vf: mac, kind: kind, share: 0.5, gap: macGap).map { frame in
            "\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())),\(Int(frame.width.rounded())),\(Int(frame.height.rounded()))"
        }.joined(separator: "|")
        walkShapes.append(shape)
    }
    tileProtoCheck(Set(walkShapes).count == 4, "columns, grid, rows, and side stay different after a saved limit of 3")

    let wideScreen = CGRect(x: 0, y: 0, width: 1728, height: 1015)
    tileProtoCheck(!layoutCountFits(4, kind: .columns, vf: wideScreen, gap: macGap), "1728-wide columns of about 422pt stay under the 440pt floor")
    let wider = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    tileProtoCheck(layoutCountFits(4, kind: .columns, vf: wider, gap: macGap), "a 1920-wide screen unlocks four columns")
    let justUnder = CGRect(x: 0, y: 0, width: 1680, height: 900)
    tileProtoCheck(!layoutCountFits(4, kind: .columns, vf: justUnder, gap: macGap), "four columns at about 410pt fail the 440pt floor")
    let portrait = CGRect(x: 0, y: 0, width: 800, height: 1400)
    tileProtoCheck(resolvedLayoutKind(.grid, vf: portrait) == .rows, "a tall screen forces rows")
    tileProtoCheck(resolvedLayoutKind(.columns, vf: mac) == .columns, "a landscape screen keeps the chosen family")
    tileProtoCheck(effectiveTileLimit(4, kind: .grid, vf: portrait, gap: macGap) <= 3, "a tall screen keeps at most three rows")
    let veryTall = CGRect(x: 0, y: 0, width: 1440, height: 1600)
    tileProtoCheck(effectiveTileLimit(4, kind: .rows, vf: veryTall, gap: macGap) == 3, "rows never exceed three even when four would fit")
    tileProtoCheck(effectiveLayoutGap(setGap: 8) == 8, "the set gap is used as is")
    tileProtoCheck(effectiveLayoutGap(setGap: -3) == 0, "a negative gap clamps to zero")
    tileProtoCheck(effectiveLayoutGap(setGap: 40) == 24, "a gap wider than 24 clamps to 24")
    let side60 = layoutFrames(count: 3, vf: mac, kind: .side, share: 0.6, gap: macGap)
    tileProtoCheck(abs(side60[0].width - 850) < 8 && abs(side60[1].width - 566) < 8, "60% side is about 850 by 566")
    let sideHalf = layoutFrames(count: 3, vf: mac, kind: .side, share: 0.5, gap: macGap)
    let narrowSide = CGSize(width: sideHalf[1].width + 40, height: 200)
    let shrunk = convergedMainShare(start: 0.5, count: 2, vf: mac, kind: .side, gap: macGap, claims: [CGSize(width: 400, height: 200), narrowSide])
    tileProtoCheck(shrunk < 0.5 - 0.01 && shrunk >= 0.4, "main share shrinks until the side pane can hold a wide window")
    let held = convergedMainShare(start: 0.5, count: 2, vf: mac, kind: .side, gap: macGap, claims: [CGSize(width: 400, height: 200), CGSize(width: 400, height: 200)])
    tileProtoCheck(abs(held - 0.5) < 0.001, "a share that already fits is left alone")

    let mapWork = CGRect(x: 0, y: 78, width: 1440, height: 798)
    let mapCanvas = CGRect(x: 0, y: 0, width: 288, height: 160)
    let mapCols = minimapLayout(work: mapWork, frames: layoutFrames(count: 2, vf: mapWork, kind: .columns, share: 0.5, gap: 8), canvas: mapCanvas)
    tileProtoCheck(mapCols.count == 2, "minimap keeps both columns")
    tileProtoCheck(abs(mapCols[0].width - mapCols[1].width) < 1.5, "minimap keeps equal columns equal")
    tileProtoCheck(mapCols[0].maxX <= mapCols[1].minX + 1, "minimap keeps the left column on the left")
    let mapSide = minimapLayout(work: mapWork, frames: layoutFrames(count: 3, vf: mapWork, kind: .side, share: 0.6, gap: 8), canvas: mapCanvas)
    tileProtoCheck(mapSide.count == 3 && mapSide[0].width > mapSide[1].width + 4, "minimap keeps a wider primary")
    tileProtoCheck(mapSide[1].minX >= mapSide[0].maxX - 1, "minimap keeps the side column to the right")
    tileProtoCheck(minimapLayout(work: .zero, frames: mapCols, canvas: mapCanvas).isEmpty, "minimap rejects an empty work area")
    let promotedOrder = windowOrderPromoting(["a", "b", "c", "d", "e"], owners: ["a", "b", "c"], promoted: "e")
    tileProtoCheck(promotedOrder == ["a", "b", "c", "e", "d"], "a wider limit gives the buried window the new pane")

    let cell = CGRect(x: 0, y: 0, width: 400, height: 300)
    let neighbor = CGRect(x: 408, y: 0, width: 400, height: 300)
    let inside = CGRect(x: 0, y: 0, width: 400, height: 300)
    let spilling = CGRect(x: 0, y: 0, width: 500, height: 300)
    tileProtoCheck(!frameCrossesPane(inside, cell: cell, neighbor: neighbor), "a window inside its pane does not cross the seam")
    tileProtoCheck(frameCrossesPane(spilling, cell: cell, neighbor: neighbor), "a window wider than its pane crosses into the neighbor")
    tileProtoCheck(!frameCrossesPane(CGRect(x: 0, y: 0, width: 404, height: 300), cell: cell, neighbor: neighbor), "four points of overhang stays inside the tolerance")
    tileProtoCheck(!frameCrossesPane(CGRect(x: 0, y: 0, width: 406, height: 300), cell: cell, neighbor: neighbor), "overhang that stops in the gap does not count as covering the next pane")
    tileProtoCheck(windowIsSeamOffender(cell: cell, actual: spilling), "an actual frame past the pane is an offender")
    tileProtoCheck(!windowIsSeamOffender(cell: cell, actual: inside), "a frame that stays in the pane is not an offender")
    tileProtoCheck(!windowIsSeamOffender(cell: cell, actual: inside), "a large minimum alone does not make a contained frame an offender")
    let busySlot = CGRect(x: 8, y: 8, width: 595, height: 435)
    let busyWork = CGRect(x: 0, y: 0, width: 1512, height: 893)
    tileProtoCheck(!shouldFloatBeforePlace(minSize: CGSize(width: 1114, height: 500), slot: busySlot, workCell: busyWork), "mail wider than one pane is not floated up front")
    tileProtoCheck(!shouldFloatBeforePlace(minSize: CGSize(width: 980, height: 600), slot: busySlot, workCell: busyWork), "music minimum is not floated up front")
    tileProtoCheck(!shouldFloatBeforePlace(minSize: CGSize(width: 200, height: 200), slot: busySlot, workCell: busyWork), "a window that fits its pane stays in the stack")
    tileProtoCheck(shouldFloatBeforePlace(minSize: CGSize(width: 1600, height: 400), slot: busySlot, workCell: busyWork), "a minimum wider than the screen floats instead of entering a pane")
    let halfPane = CGRect(x: 8, y: 80, width: 701, height: 434)
    let nextPane = CGRect(x: 717, y: 80, width: 701, height: 434)
    let forced = hardPaneFrame(halfPane)
    tileProtoCheck(frameIsInsidePane(forced, pane: halfPane), "the forced frame is exactly the pane")
    tileProtoCheck(!differentPanesIntersect(forced, nextPane), "a clamped pane does not meet the next pane")
    let mailFrame = CGRect(x: 8, y: 80, width: 1114, height: 500)
    tileProtoCheck(!frameIsInsidePane(mailFrame, pane: halfPane), "1114pt mail is outside a half pane")
    tileProtoCheck(differentPanesIntersect(mailFrame, nextPane), "1114pt mail crosses into the next pane")
    tileProtoCheck(windowIsSeamOffender(cell: halfPane, actual: mailFrame), "a frame that crosses the pane counts as an offender")
    tileProtoCheck(frameIsInsidePane(CGRect(x: 8, y: 80, width: 702, height: 435), pane: halfPane), "1pt of rounding stays inside the 1.5pt tolerance")
    tileProtoCheck(!frameIsInsidePane(CGRect(x: 8, y: 80, width: 703, height: 434), pane: halfPane), "2pt of overhang is outside the tolerance")
    tileProtoCheck(!seamMustRevert([]), "no offender does not revert the seam")
    tileProtoCheck(seamMustRevert([(offenderA: true, offenderB: false)]), "one offender reverts the seam")
    tileProtoCheck(seamMustRevert([(offenderA: true, offenderB: true)]), "two offenders revert the seam")
    tileProtoCheck(!seamMustRevert([(offenderA: false, offenderB: false)]), "two fitting windows do not revert the seam")
    tileProtoCheck(seamMustRevert([(offenderA: true, offenderB: false), (offenderA: false, offenderB: false)]), "a mixed overlap reverts the seam")
    let tall = CGRect(x: 0, y: 0, width: 1440, height: 1200)
    tileProtoCheck(layoutCountFits(3, kind: .rows, vf: tall, gap: macGap), "taller screen unlocks three rows")
    tileProtoCheck(layoutCountFits(4, kind: .side, vf: tall, gap: macGap), "taller screen unlocks side 4")

    let macGrid = layoutFrames(count: 3, vf: mac, kind: .grid, share: 0.5, gap: macGap)
    let macCols = layoutFrames(count: 3, vf: mac, kind: .columns, share: 0.5, gap: macGap)
    tileProtoCheck(macGrid.count == 3 && macCols.count == 3, "macbook count 3 frames")
    tileProtoCheck(abs(macGrid[0].width - macCols[0].width) > 20, "grid 3 is not three equal columns")
    tileProtoCheck(abs(macGrid[0].width - macGrid4[0].width) > 20, "grid 3 differs from grid 4 so switching counts visibly reflows")
    tileProtoCheck(macGrid[0].width > macGrid[1].width + 20, "grid 3 top row spans both bottom cells")
    let macSide = layoutFrames(count: 3, vf: mac, kind: .side, share: 2.0 / 3.0, gap: macGap)
    tileProtoCheck(macSide[0].width > macSide[1].width + 100, "two-thirds widens the side primary")

    tileProtoCheck(layoutCaption(kind: .side, count: 3) == "Side · One big, two beside", "side 3 caption")
    tileProtoCheck(layoutCaption(kind: .grid, count: 3) == "Grid · One on top, two below", "grid 3 caption")
    tileProtoCheck(layoutCaption(kind: .columns, count: 3) == "Columns · Three columns", "columns 3 caption")
    tileProtoCheck(layoutCaption(kind: .grid, count: 4) == "Grid · Grid of four", "grid 4 caption")
    tileProtoCheck(layoutCaption(kind: .side, count: 4) == "Side · One big, three beside", "side 4 caption")
    tileProtoCheck(layoutCaption(kind: .rows, count: 2) == "Rows · Two rows", "rows 2 caption")
    tileProtoCheck(layoutCaption(kind: .grid, count: 2) != layoutCaption(kind: .grid, count: 3), "caption follows the count")

    tileProtoCheck(capacityNote(kind: .columns, fitted: 3) == "This screen fits 3 columns. Pick Grid for four.", "columns fit note")
    tileProtoCheck(capacityNote(kind: .side, fitted: 3) == "This screen fits 3 windows in Side. Pick Grid for four.", "side fit note")
    tileProtoCheck(capacityNote(kind: .rows, fitted: 2) == "This screen fits 2 rows. Pick Grid for four.", "rows fit note")
    tileProtoCheck(capacityNote(kind: .grid, fitted: 4) == nil, "grid 4 has no fit note")

    tileProtoCheck(dragChord(command: true, option: true, control: false) == .stack, "option command stacks")
    tileProtoCheck(dragChord(command: true, option: true, control: true) == .stack, "extra control still stacks")
    tileProtoCheck(dragChord(command: true, option: false, control: true) == .swap, "control command swaps")
    tileProtoCheck(dragChord(command: true, option: false, control: false) == .swap, "command swaps")
    tileProtoCheck(dragChord(command: false, option: true, control: true) == .plain, "control option does not stack")
    tileProtoCheck(dragChord(command: false, option: false, control: false) == .plain, "plain drag is not a chord")

    tileProtoCheck(snappedGap(8) == 8 && snappedGap(9) == 8 && snappedGap(7) == 6, "gap snaps down to even steps")
    tileProtoCheck(snappedGap(0) == 0 && snappedGap(24) == 24 && snappedGap(25) == 24 && snappedGap(-4) == 0, "gap stays inside 0...24")

    var springPeak: CGFloat = 0
    var springStep = 0
    while springStep <= 2000 {
        springPeak = max(springPeak, tileSpringUnit(CGFloat(springStep) / 2000))
        springStep += 1
    }
    tileProtoCheck(abs(tileSpringUnit(0)) < 0.001 && abs(tileSpringUnit(1) - 1) < 0.001, "spring starts at 0 and ends at 1")
    tileProtoCheck(springPeak > 1.15 && springPeak < 1.17, "spring overshoots by about 0.16")
    tileProtoCheck(abs(tileSpringDuration - 0.62) < 0.001, "spring duration is 0.62s")
    tileProtoCheck(abs(hoverShowDelay - 0.15) < 0.001 && abs(hoverArmDelay - 0.40) < 0.001 && abs(hoverHideDelay - 0.35) < 0.001, "hover timings")

    // 退化分支也不得让格子重叠：剩余空间不足时均分贴边，哪怕格子小于最小尺寸。
    func framesDisjoint(_ frames: [CGRect]) -> Bool {
        for a in frames.indices {
            for b in frames.indices where b > a {
                if differentPanesIntersect(frames[a], frames[b]) { return false }
            }
        }
        return true
    }
    let tiny = CGRect(x: 0, y: 0, width: 20, height: 20)
    tileProtoCheck(framesDisjoint(layoutFrames(count: 3, vf: tiny, kind: .columns, share: 0.5, gap: gap)), "tiny columns stay disjoint")
    tileProtoCheck(framesDisjoint(layoutFrames(count: 3, vf: tiny, kind: .rows, share: 0.5, gap: gap)), "tiny rows stay disjoint")
    tileProtoCheck(framesDisjoint(layoutFrames(count: 3, vf: tiny, kind: .side, share: 0.5, gap: gap)), "tiny side stays disjoint")
    tileProtoCheck(framesDisjoint(layoutFrames(count: 3, vf: tiny, kind: .grid, share: 0.5, gap: gap)), "tiny grid 3 stays disjoint")
    tileProtoCheck(framesDisjoint(layoutFrames(count: 4, vf: tiny, kind: .grid, share: 0.5, gap: gap)), "tiny grid 4 stays disjoint")
    tileProtoCheck(layoutFrames(count: 3, vf: tiny, kind: .columns, share: 0.5, gap: gap).count == 3, "tiny columns still yield 3 cells")

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
