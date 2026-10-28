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
//     下层是 Primary / Focus / Float。界面不放键帽。
//     Option+Command 拖到某格子上时，即使刚好满格也并进去，空出的格子收掉。
//     Control+Command 仍是交换，不是进叠。
//  4. Command 拖到另一格子：被拖窗口抬起跟手，目标格子略向内收，松手后两边滑到最终帧。
//     普通拖动松手弹回，并提示按住 Command 才能交换。满格时新窗可堆叠或居中浮动。
//  5. Focus 铺满后再点悬停条上的 Focus，按进入前的帧还原。
//     No peek 默认关，打开后压暗其它格子。Clean Space 用石墨色帘子只留当前窗口。
//     Borders 默认关，打开后描边画在缝里。
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

/// 第 0 个窗口进第 0 格，前 tileCount 个窗口各开一格，其后的窗口按顺序轮流分进每一格。
/// 17 扇窗、3 格时是 6、6、5，不会 15 扇堆在一格里。
func overflowTileIndex(windowOrdinal: Int, tileCount: Int) -> Int {
    let n = tileCount > 0 ? tileCount : 1
    let ordinal = windowOrdinal > 0 ? windowOrdinal : 0
    if ordinal < n { return ordinal }
    return (ordinal - n) % n
}

/// 这一族要露出来才叫这个布局的格数。Grid 要 4，否则和 Side 的三格是同一张图。
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

func columnFrames(count n: Int, vf: CGRect, gap g: CGFloat, share: CGFloat) -> [CGRect] {
    guard n > 1 else { return [vf] }
    let inner = vf.width - g * CGFloat(n + 1)
    guard inner > CGFloat(n) else { return Array(repeating: vf, count: n) }
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
    guard inner > CGFloat(n) else { return Array(repeating: vf, count: n) }
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

/// Grid 四格：先做成左大右二，再把左侧竖直对半。主格份额只拉宽左列，左右列内部高度各一半。
func gridFold4Frames(vf: CGRect, gap g: CGFloat, share: CGFloat) -> [CGRect] {
    let tri = sideFrames(count: 3, vf: vf, gap: g, share: share)
    guard tri.count == 3 else { return Array(repeating: vf, count: 4) }
    let left = tri[0]
    let innerH = left.height - g
    guard innerH > 2 else { return Array(repeating: vf, count: 4) }
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
    if vf.width < 2 || vf.height < 2 { return [vf] }
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
        // 三格是「一块大、两块小」，不是三条等分。四格是左列对半 + 右列两格。
        if n == 3 { return sideFrames(count: 3, vf: vf, gap: g, share: share) }
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

/// 实际帧探出自己的格子，并且探到了另一格的矩形里。同一格里的堆叠不算。
func frameCrossesPane(_ actual: CGRect, cell: CGRect, neighbor: CGRect, tolerance: CGFloat = tileFitTolerance) -> Bool {
    let over = max(cell.minX - actual.minX, cell.minY - actual.minY,
                   actual.maxX - cell.maxX, actual.maxY - cell.maxY)
    guard over > tolerance else { return false }
    let inter = actual.intersection(neighbor)
    if inter.isNull { return false }
    return inter.width > 1 && inter.height > 1
}

/// 这扇窗装不进分给它的格子：已知最小尺寸过大，或者实际帧已经探出格子。
func windowIsSeamOffender(minSize: CGSize, cell: CGRect, actual: CGRect, tolerance: CGFloat = tileFitTolerance) -> Bool {
    if slotShortfall(minSize, cell, tolerance: tolerance) > 0 { return true }
    let over = max(cell.minX - actual.minX, cell.minY - actual.minY,
                   actual.maxX - cell.maxX, actual.maxY - cell.maxY)
    return over > tolerance
}

/// 两格的窗口叠在一起时，只有两边都装得下自己的格子才收回整条缝。
/// 任何一边是装不下的窗口，缝的份额留下，只把那一扇挪走。
func seamMustRevert(_ pairs: [(offenderA: Bool, offenderB: Bool)]) -> Bool {
    for pair in pairs where !pair.offenderA && !pair.offenderB {
        return true
    }
    return false
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

enum HighlightMode: Int {
    case none = 0
    case activeBorder = 1
    case allBorders = 2
    case glow = 3
}

enum HighlightColor: Int {
    case accent = 0
    case purple = 1
    case pink = 2
    case orange = 3
    case green = 4
    case graphite = 5
}

enum CleanSpaceColor: Int {
    case graphite = 0
    case stone = 1
    case mist = 2
}

/// 排版用的间距。边框模式至少留出边框厚度；光晕模式至少 4。用户设的更大间距保持不变。
func effectiveLayoutGap(setGap: CGFloat, mode: HighlightMode, border: CGFloat) -> CGFloat {
    let g = min(24, max(0, setGap))
    let line = min(6, max(2, border))
    switch mode {
    case .none:
        return g
    case .activeBorder, .allBorders:
        return max(g, line)
    case .glow:
        return max(g, 4)
    }
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
        case 3: phrase = "One big, two small"
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

// v9：高亮颜色板（面板里一排小圆点）与高亮框视图（画边框或光晕）

final class HighlightBorderView: NSView {
    var strokeColor: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.95)
    var lineWidth: CGFloat = 2
    /// 面板比格子每边大出的量。描边画在格子外侧、缝隙里，不压住窗口内容。
    var pad: CGFloat = 2
    var outset: CGFloat = 1
    /// 光晕是活动格上沿一条 80% 宽的线，不是四边框。
    var glow = false
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if glow {
            let rect = bounds.insetBy(dx: 0, dy: max(0, (bounds.height - lineWidth) / 2))
            guard rect.width > 2, rect.height > 0.5 else { return }
            strokeColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            return
        }
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
    var tileLimit = defaultTileLimit
    var noPeek = false
    var dimStrength: CGFloat = 0.50
    var highlightMode: HighlightMode = .none
    var borderThickness: CGFloat = 2
    var highlightColor: HighlightColor = .accent
    var cleanTone: CleanSpaceColor = .graphite
    var hoverBarEnabled = true
    var statPlaced = 0
    var statMoves = 0
    /// 面板上的 Borders 开关：关掉是无高亮，打开是全部格子描边。
    var showBorders: Bool {
        get { highlightMode != .none }
        set { highlightMode = newValue ? .allBorders : .none }
    }
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
    var dimSlider: NSSlider!
    var dimValueLabel: NSTextField!
    var fitWarningLabel: NSTextField!
    var layoutCaptionLabel: NSTextField!
    var tidyButton: NSButton!
    var resetSizesRow: NSStackView!
    var didShowStackToast = false
    var noPeekSwitch: NSSwitch!
    var bordersSwitch: NSSwitch!
    var hoverFocusSwitch: NSSwitch!
    var cleanSpaceSwitch: NSSwitch!
    var panelButtonSymbols: [ObjectIdentifier: String] = [:]
    let tileBorderPad: CGFloat = 4
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
    var minimapView: MinimapView!
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
    var dividerRevertLogged = false // 同一拖动会话里“divider drag reverted”只记一次
    // 缝拖动事件合并：mouseDragged 只记最新位置并调度一次主队列异步处理，
    // 多个事件到达时只覆盖 pending，不排队跑重活；异步块用最新位置跑一步。
    // 否则每事件同步跑完 100+ 次 AX（130–400ms），远跟不上 8–16ms 的事件间隔，
    // 主线程被拖住，缝只能滞后、跳跃地跟鼠标。
    var dividerDragPending: CGFloat? = nil
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

    // 活动格子细描边由 Borders 控制，其余格子的暗色由 No peek 和 Dim 控制。
    var lastActiveTile = 0

    // D 批状态：⌘拖交换 / ⌥⌘拖进堆叠
    enum DragMode { case swap, stack }
    /// spring：日常重排，约 5% 过冲。settle：交换/抬起，精确落到终点，不过冲、不互相穿透。
    enum MotionEase { case spring, settle }
    struct DragState {
        var mode: DragMode  // 拖动中可随 ⌥ 在 swap↔stack 间切换
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
    /// 高屏把族收成 Rows。边框和光晕会把排版间距抬到能放下高亮的宽度。
    func layoutSettings(for screen: NSScreen) -> ScreenSettings {
        var st = settingsFor(screen)
        let vf = screen.visibleFrame
        st.kind = resolvedLayoutKind(st.kind, vf: vf)
        st.gap = gapForLayout()
        st.tileLimit = effectiveTileLimit(st.tileLimit, kind: st.kind, vf: vf, gap: st.gap)
        return st
    }

    func gapForLayout() -> CGFloat {
        effectiveLayoutGap(setGap: globalSettings.gap, mode: highlightMode, border: borderThickness)
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

        // 磁贴预览：按这一屏真实格子的比例画，不按个数等分。
        minimapView = MinimapView(frame: NSRect(x: 0, y: 0, width: 288, height: 168))
        minimapView.heightAnchor.constraint(equalToConstant: 168).isActive = true
        tilesPlaceholder = NSTextField(labelWithString: "No windows to tile on this screen")
        tilesPlaceholder.font = .systemFont(ofSize: 12)
        tilesPlaceholder.textColor = .secondaryLabelColor
        tilesPlaceholder.isHidden = true
        stack.addArrangedSubview(w288(minimapView))
        stack.addArrangedSubview(w288(tilesPlaceholder))

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

        noPeekSwitch = NSSwitch()
        noPeekSwitch.target = self
        noPeekSwitch.action = #selector(panelToggleNoPeek(_:))
        stack.addArrangedSubview(w288(settingCard(icon: tintedSymbol("eye.slash", point: 14, color: .labelColor), label: NSTextField(labelWithString: "No peek mode"), control: noPeekSwitch)))
        let dimRow = hRow(spacing: 8)
        dimRow.addArrangedSubview(sectionLabel("Dim strength"))
        dimSlider = NSSlider(value: 50, minValue: 10, maxValue: 90, target: self, action: #selector(panelDim(_:)))
        dimSlider.isContinuous = false
        dimValueLabel = NSTextField(labelWithString: "50")
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
        // 面板控件反映全局设置。装不下的数量变灰；高亮的是屏幕上实际在用的那一档。
        let panelSt = globalSettings
        let fitScreen = NSScreen.main ?? NSScreen.screens.first
        let fitCap = fitScreen.map { maxFitCount(on: $0) } ?? 4
        let shownLimit = min(max(panelSt.tileLimit, 1), fitCap)
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
            b.isDisabled = b.indexTag > fitCap
            b.isSelected = (b.indexTag == shownLimit)
            if b.indexTag == 1 {
                b.toolTip = "1 window"
            } else if b.isDisabled, let note = capacityNote(kind: panelSt.kind, fitted: fitCap) {
                b.toolTip = note
            } else {
                b.toolTip = "Up to \(b.indexTag) windows"
            }
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
            let dimPct = Int((dimStrength * 100).rounded())
            dimSlider?.doubleValue = Double(dimPct)
            dimValueLabel?.stringValue = "\(dimPct)%"
        }
        noPeekSwitch?.state = noPeek ? .on : .off
        bordersSwitch?.state = showBorders ? .on : .off
        hoverFocusSwitch?.state = hoverFocus ? .on : .off
        cleanSpaceSwitch?.state = cleanSpaceOn ? .on : .off
        loginSwitch?.state = loginItemEnabled() ? .on : .off
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
            let note = capacityNote(kind: st.kind, fitted: maxFitCount(on: screen)) ?? "This screen fits fewer cells."
            log("tileLimit \(v) rejected; \(note)")
            showToast(layoutFamilyName(st.kind), detail: note, on: screen)
            refreshPanel()
            return
        }
        if v > st.tileLimit {
            promoteBuriedWindowForNewPane(on: screen)
        }
        st.tileLimit = v
        setSettingsFor(st, screen: activeScreen())
        log("tileLimit -> \(v)")
        showToast(v == 1 ? "1 window" : "Up to \(v) windows", detail: "On this screen.", on: activeScreen())
        forceTile()
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
            return "1 window is larger than its cell. It stays stacked in the layout."
        }
        return "\(overflow) windows are larger than their cells. They stay stacked in the layout."
    }

    func applyLayoutKind(_ kind: LayoutKind) {
        var st = globalSettings
        let screen = activeScreen()
        st.kind = kind
        // 只升不降。Grid 从 3 升到 4 之后，Side 仍按这块屏能装下的 3 格画，两族才分开。
        let raised = tileLimitForFamilyChange(saved: st.tileLimit, kind: kind, vf: screen.visibleFrame, gap: gapForLayout())
        if raised > st.tileLimit {
            promoteBuriedWindowForNewPane(on: screen)
        }
        st.tileLimit = raised
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
        forceTile()
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
        showToast(mode == .stack ? "Stack across tiles" : "Float in the middle",
                  detail: mode == .stack
                    ? "Extra windows spread across the tiles of this layout."
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

    @objc func panelDim(_ sender: NSSlider) {
        let snapped = min(90, max(10, Int((sender.doubleValue / 5).rounded()) * 5))
        dimStrength = CGFloat(snapped) / 100
        sender.doubleValue = Double(snapped)
        dimValueLabel?.stringValue = "\(snapped)%"
        saveLayoutSettings()
        log("dim -> \(snapped)")
        removeDimLayers()
        if noPeek { refreshDimLayers() }
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

    @objc func panelToggleBorders(_ sender: NSSwitch) {
        highlightMode = sender.state == .on ? .allBorders : .none
        saveLayoutSettings()
        log(highlightMode == .none ? "borders off" : "borders on")
        forceTile()
        refreshHighlights()
        refreshSettingsIfOpen()
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

    let settingsPageNames = ["General", "Layout", "Highlight", "Mouse", "Keyboard", "Apps", "Activity", "About"]

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
        case 2: return settingsHighlightPage()
        case 3: return settingsMousePage()
        case 4: return settingsKeyboardPage()
        case 5: return settingsAppsPage()
        case 6: return settingsActivityPage()
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
        for (title, mode) in [("Stack across tiles", WhenFull.stack), ("Float in the middle", WhenFull.float)] {
            let b = settingsChoice(title, tag: mode.rawValue, action: #selector(panelWhenFull(_:)), on: globalSettings.whenFull == mode)
            whenFullButtons.append(b)
            full.addArrangedSubview(b)
        }
        stack.addArrangedSubview(NSTextField(labelWithString: "When a screen is full"))
        stack.addArrangedSubview(full)
        stack.addArrangedSubview(settingsNote("Stack spreads extra windows across the tiles of this layout. Float keeps a new window in the middle until there is room."))
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
        return stack
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

    func settingsHighlightPage() -> NSView {
        let stack = settingsColumn("Highlight")
        let modes = NSStackView()
        modes.orientation = .horizontal
        modes.spacing = 8
        let names = ["None", "Border on active", "Border on all", "Glow on active"]
        for (i, name) in names.enumerated() {
            modes.addArrangedSubview(settingsChoice(name, tag: i, action: #selector(settingsHighlightMode(_:)), on: highlightMode.rawValue == i))
        }
        stack.addArrangedSubview(modes)
        stack.addArrangedSubview(settingsNote("The highlight is drawn in the gap. It never covers what is inside a window."))
        let thick = hRow(spacing: 8)
        thick.addArrangedSubview(sectionLabel("Border thickness"))
        let slider = NSSlider(value: Double(borderThickness), minValue: 2, maxValue: 6, target: self, action: #selector(settingsThickness(_:)))
        slider.isContinuous = false
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = true
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        slider.isEnabled = highlightMode == .activeBorder || highlightMode == .allBorders
        thick.addArrangedSubview(slider)
        thick.addArrangedSubview(NSTextField(labelWithString: "\(Int(borderThickness.rounded()))"))
        stack.addArrangedSubview(thick)
        if highlightMode == .activeBorder || highlightMode == .allBorders {
            stack.addArrangedSubview(settingsNote("The gap grows to \(Int(borderThickness.rounded())) pt when that is wider than the space you set, so the line fits."))
        }
        let colors = NSStackView()
        colors.orientation = .horizontal
        colors.spacing = 8
        for (i, name) in ["Accent", "Purple", "Pink", "Orange", "Green", "Graphite"].enumerated() {
            let b = settingsChoice(name, tag: i, action: #selector(settingsHighlightColor(_:)), on: highlightColor.rawValue == i)
            b.isEnabled = highlightMode != .none
            colors.addArrangedSubview(b)
        }
        stack.addArrangedSubview(NSTextField(labelWithString: "Color"))
        stack.addArrangedSubview(colors)
        stack.addArrangedSubview(settingsNote("Accent follows the Mac accent color."))
        return stack
    }

    @objc func settingsHighlightMode(_ sender: NSButton) {
        highlightMode = HighlightMode(rawValue: sender.tag) ?? .none
        saveLayoutSettings()
        forceTile()
        refreshHighlights()
        refreshPanel()
        refreshSettingsIfOpen()
    }

    @objc func settingsThickness(_ sender: NSSlider) {
        let v = min(6, max(2, sender.integerValue))
        borderThickness = CGFloat(v)
        sender.doubleValue = Double(v)
        saveLayoutSettings()
        forceTile()
        refreshHighlights()
        refreshSettingsIfOpen()
    }

    @objc func settingsHighlightColor(_ sender: NSButton) {
        guard highlightMode != .none else { return }
        highlightColor = HighlightColor(rawValue: sender.tag) ?? .accent
        saveLayoutSettings()
        refreshHighlights()
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
            ("Need another window too?", "When the screen is full, extra windows spread across the panes. The orange grip and the chips switch which one is in front."),
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
        column.addArrangedSubview(settingsNote(step.1))
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
            let raw = min(24, max(0, CGFloat(d.double(forKey: "tileproto.gap"))))
            st.gap = CGFloat((Int(raw.rounded()) / 2) * 2)
        }
        if d.object(forKey: "tileproto.whenFull") != nil {
            st.whenFull = WhenFull(rawValue: d.integer(forKey: "tileproto.whenFull")) ?? .stack
        }
        // 旧默认上限是 3。Grid 在 3 格时和 Side 是同一张图，所以只在第一次启动、
        // 并且当时存的就是 3 时，升到这一族要露出来的格数。用户之后再调回 3 会留下。
        var saveRaisedLimit = false
        if !d.bool(forKey: "tileproto.familyPaneRaised"),
           let screen = NSScreen.main ?? NSScreen.screens.first {
            if st.tileLimit == 3 {
                let raised = tileLimitForFamilyChange(saved: st.tileLimit, kind: st.kind, vf: screen.visibleFrame, gap: st.gap)
                if raised != st.tileLimit {
                    log("tileLimit \(st.tileLimit) -> \(raised) so \(layoutFamilyName(st.kind)) can show its panes")
                    st.tileLimit = raised
                    saveRaisedLimit = true
                }
            }
            d.set(true, forKey: "tileproto.familyPaneRaised")
        }
        globalSettings = st
        tileLimit = st.tileLimit
        if d.object(forKey: "tileproto.noPeek") != nil { noPeek = d.bool(forKey: "tileproto.noPeek") }
        if d.object(forKey: "tileproto.dimStrength") != nil {
            let v = CGFloat(d.double(forKey: "tileproto.dimStrength"))
            if v >= 0.10, v <= 0.90 { dimStrength = v }
        }
        if d.object(forKey: "tileproto.highlightMode") != nil {
            highlightMode = HighlightMode(rawValue: d.integer(forKey: "tileproto.highlightMode")) ?? .none
        } else if d.bool(forKey: "tileproto.borders") {
            highlightMode = .allBorders
        }
        if d.object(forKey: "tileproto.borderThickness") != nil {
            let t = CGFloat(d.double(forKey: "tileproto.borderThickness"))
            if t >= 2, t <= 6 { borderThickness = t }
        }
        if d.object(forKey: "tileproto.highlightColor") != nil {
            highlightColor = HighlightColor(rawValue: d.integer(forKey: "tileproto.highlightColor")) ?? .accent
        }
        if d.object(forKey: "tileproto.cleanTone") != nil {
            cleanTone = CleanSpaceColor(rawValue: d.integer(forKey: "tileproto.cleanTone")) ?? .graphite
        }
        if d.object(forKey: "tileproto.hoverBar") != nil {
            hoverBarEnabled = d.bool(forKey: "tileproto.hoverBar")
        }
        statPlaced = max(0, d.integer(forKey: "tileproto.statPlaced"))
        statMoves = max(0, d.integer(forKey: "tileproto.statMoves"))
        hoverFocus = d.bool(forKey: "tileproto.hoverFocus")
        if saveRaisedLimit { saveLayoutSettings() }
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
        d.set(highlightMode.rawValue, forKey: "tileproto.highlightMode")
        d.set(highlightMode != .none, forKey: "tileproto.borders")
        d.set(Double(borderThickness), forKey: "tileproto.borderThickness")
        d.set(highlightColor.rawValue, forKey: "tileproto.highlightColor")
        d.set(cleanTone.rawValue, forKey: "tileproto.cleanTone")
        d.set(hoverBarEnabled, forKey: "tileproto.hoverBar")
        d.set(statPlaced, forKey: "tileproto.statPlaced")
        d.set(statMoves, forKey: "tileproto.statMoves")
        d.set(hoverFocus, forKey: "tileproto.hoverFocus")
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
            refreshHighlights()
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
            var floatedCover = false
            for (sid, tiles) in lastTilesByScreen {
                let live = tickWindows.filter { screenID(screenForFrame($0.frame)) == sid }
                for (tileIndex, t) in tiles.enumerated() {
                    let key = winKey(t.top)
                    guard key != focusKey else { continue }
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
                                guard mk != key, mk != focusKey, frameMotions[mk] == nil else { continue }
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
                    // 格子和份额留下，只把这扇窗浮出平铺。飞行中的弹簧不判。
                    if t.stack.count > 1 {
                        for m in t.stack {
                            let mk = winKey(m)
                            guard mk != key, mk != focusKey, !floatedKeys.contains(mk),
                                  frameMotions[mk] == nil,
                                  let mw = live.first(where: { winKey($0) == mk }) else { continue }
                            guard coversAnyOtherPane(mw.frame, cellIndex: tileIndex, tiles: tiles) else {
                                overflowSnapStuck.removeValue(forKey: mk)
                                continue
                            }
                            floatOversized(mw, on: NSScreen.screens.first(where: { screenID($0) == sid }) ?? screenForFrame(mw.frame))
                            overflowSnapStuck.removeValue(forKey: mk)
                            floatedCover = true
                            log("cross-pane float: \(mw.appName) was covering another pane")
                            if !toasted {
                                showToast("Floated out of the grid", detail: "It was covering another pane.", on: NSScreen.screens.first(where: { screenID($0) == sid }))
                                toasted = true
                            }
                        }
                    }
                    guard frameMotions[key] == nil else { continue }
                    guard coversAnyOtherPane(w.frame, cellIndex: tileIndex, tiles: tiles) else {
                        overflowSnapStuck.removeValue(forKey: key)
                        continue
                    }
                    floatOversized(w, on: NSScreen.screens.first(where: { screenID($0) == sid }) ?? screenForFrame(w.frame))
                    overflowSnapStuck.removeValue(forKey: key)
                    floatedCover = true
                    log("cross-pane float: \(w.appName) was covering another pane")
                    if !toasted {
                        showToast("Floated out of the grid", detail: "It was covering another pane.", on: NSScreen.screens.first(where: { screenID($0) == sid }))
                        toasted = true
                    }
                }
            }
            if floatedCover, dragState == nil, draggingDividerID == nil {
                forceTile()
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

    // 把窗口分到各磁贴：前 t 个窗口每磁贴一个，其余按窗口顺序轮流分进这 t 格。
    // 活动磁贴只决定高亮，不决定多余窗口堆进哪一格，避免焦点一变就把整屏重分。
    // 窗口顺序（⌘ 交换会改这张表）：先按 windowOrder 排，再把 Primary 移到首位；
    // 新窗口追加到末尾（未满时自成一格，满时按顺序进入下一格），消失的窗口剔除。
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
        let roots = windows.filter { stackedOnto[winKey($0)] == nil }
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
                for (ordinal, w) in rootPool.enumerated() where ordinal >= t {
                    stacks[overflowTileIndex(windowOrdinal: ordinal, tileCount: t)].append(w)
                }
            }
        }
        if !roots.isEmpty {
            // 手动堆叠的 host 不在本屏格子里时，按 host 分组后继续轮流分格。
            // 同一个 host 的成员进同一格。host 键排序，分法不随字典遍历顺序变。
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
            var ordinal = rootPool.count
            for host in orphans.keys.sorted() {
                let tile = overflowTileIndex(windowOrdinal: ordinal, tileCount: t)
                for w in orphans[host] ?? [] {
                    stacks[tile].append(w)
                }
                ordinal += 1
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
        refreshDimLayers()
        refreshHighlights()
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
            frames = applyGiveWay(frames: frames, stacks: stacks, sid: sid)
        }
        return frames
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
        guard floatedKeys.insert(key).inserted else { return }
        let box = insetWorkArea(on: screen)
        let cur = getSize(w.element) ?? w.frame.size
        let width = min(max(cur.width > 1 ? cur.width : 480, 80), box.width)
        let height = min(max(cur.height > 1 ? cur.height : 320, 60), box.height)
        let frame = CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
        placeFrame(w.element, frame, key: key, animated: draggingDividerID == nil, learnName: w.appName)
        lastPlacedFrames[key] = frame
        log("when-full float -> \(w.appName)")
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
        let st = layoutSettings(for: screen)
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
                let full = focusFrame(on: screen)
                AXUIElementPerformAction(fw.element, kAXRaiseAction as CFString)
                placeFrame(fw.element, full, key: fk, animated: draggingDividerID == nil)
                lastPlacedFrames[fk] = full
                showFocusCaption(on: screen, frame: full)
                if refreshOverlays { hideGrips(); hideStackMarkers(); hideHighlights(); removeDimLayers() }
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
            let fresh = windows.reduce(0) { $0 + (previousKeys.contains(winKey($1)) ? 0 : 1) }
            notePlaced(fresh)
            for tile in previousTiles where !tile.stack.isEmpty {
                // 三元组自带显示顶，置换下也正确；不再按格下标反查 stackTops。
                preservedTopKeys.append(winKey(tile.top))
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
        var (stacks, origActive, whenFullOverflow) = computeTiles(windows: windows, st: st, sid: sid)
        // 满格且选了居中浮动：多出来的根窗口立刻浮动，不进任何叠。
        for w in whenFullOverflow where !floatedKeys.contains(winKey(w)) {
            floatWhenFull(w, on: screen)
        }
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
        // 整叠交换置换：frames 按未置换的叠算（每格几何固定、缝记忆按格），只换每格里装哪一叠。
        // 整屏装不下、或者装不进分到的这一格，都浮走。留在小格里会探过缝盖住邻居。
        // 栈顶下标按计算格存，随叠走。
        let swapPerm = sanitizedSwapPerm(tileSwapPermByScreen[sid], count: fitStacks.count)
        if swapPerm == Array(0..<fitStacks.count) { tileSwapPermByScreen.removeValue(forKey: sid) } else { tileSwapPermByScreen[sid] = swapPerm }
        let displayStacks = swapPerm.map { fitStacks[$0] }
        let displayActive = displayStacks.firstIndex(where: { $0.contains(where: { winKey($0) == activeTopKey }) }) ?? active
        let animateMoves = draggingDividerID == nil
        // 整屏那一格。装不进它的窗口才浮动。装不进当前小格的窗口仍然写入小格的矩形。
        let workCell = layoutFrames(count: 1, vf: vf, kind: st.kind, share: st.share, gap: st.gap).first ?? vf
        var placedStacks: [[WinInfo]] = Array(repeating: [], count: displayStacks.count)
        for (i, stack) in displayStacks.enumerated() {
            let slot = frames.indices.contains(i) ? frames[i] : vf
            for w in stack {
                let key = winKey(w)
                let minSize = effectiveMin(for: w)
                if frameContained(in: workCell, proposed: workCell, minSize: minSize) == nil
                    || frameContained(in: slot, proposed: slot, minSize: minSize) == nil {
                    floatOversized(w, on: screen)
                    log("cross-pane float: \(w.appName) does not fit pane \(i)")
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
        let shownActive = shownStacks.firstIndex(where: { displayStacks.indices.contains($0.offset) && displayActive == $0.offset }) ?? 0
        lastActiveTileByScreen[sid] = shownStacks.isEmpty ? 0 : shownActive
        lastTilesByScreen[sid] = shownStacks.map { pair in
            let s = pair.element
            let topIndex = min(stackTops[stackTopKey(sid, permSrcSlot(pair.offset, sid: sid))] ?? 0, s.count - 1)
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
        let tileDesc = displayStacks.enumerated().map { (i, s) in
            let names = Dictionary(grouping: s, by: { $0.appName })
                .map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: "+")
            return "tile\(i)[\(s.count)]:\(names)"
        }.joined(separator: " ")
        if !dragQuiet {
            log("tiled screen=\(screenName(screen)) \(windows.count) windows limit=\(st.tileLimit) tiles=\(displayStacks.count) active=\(displayActive) \(tileDesc)")
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
                let aOff = windowIsSeamOffender(minSize: effectiveMin(for: samples[a].window), cell: samples[a].cell, actual: samples[a].actual)
                let bOff = windowIsSeamOffender(minSize: effectiveMin(for: samples[b].window), cell: samples[b].cell, actual: samples[b].actual)
                pairs.append((offenderA: aOff, offenderB: bOff))
                if aOff { offenders[winKey(samples[a].window)] = samples[a].window }
                if bOff { offenders[winKey(samples[b].window)] = samples[b].window }
            }
        }
        return (seamMustRevert(pairs), Array(offenders.values))
    }

    /// 把装不下新格子的窗口浮走，并从这一次拖缝的格子和快照里拿掉。缝的份额不动。
    func ejectSeamOffender(_ w: WinInfo, tileIndex: Int, screen: NSScreen, sid: CGDirectDisplayID, tiles: inout [(stack: [WinInfo], frame: CGRect, top: WinInfo)]) {
        let key = winKey(w)
        floatOversized(w, on: screen)
        if tiles.indices.contains(tileIndex) {
            tiles[tileIndex].stack.removeAll { winKey($0) == key }
            if winKey(tiles[tileIndex].top) == key, let next = tiles[tileIndex].stack.first {
                tiles[tileIndex].top = next
            }
        }
        stackedOnto.removeValue(forKey: key)
        let fallback = tiles.indices.contains(tileIndex) ? tiles[tileIndex].stack.first.map { winKey($0) } : nil
        let children = stackedOnto.filter { $0.value == key }.map { $0.key }
        for child in children {
            if let fallback, child != fallback {
                stackedOnto[child] = fallback
            } else {
                stackedOnto.removeValue(forKey: child)
            }
        }
        if let snap = dividerDragSnapshot, snap.sid == sid {
            var keys = snap.memberKeys
            keys.remove(key)
            var frames = snap.memberFrames
            frames.removeValue(forKey: key)
            let snapTiles = snap.tiles.map { item -> (keys: Set<String>, frame: CGRect) in
                var next = item.keys
                next.remove(key)
                return (keys: next, frame: item.frame)
            }
            dividerDragSnapshot = DividerDragSnapshot(
                sid: snap.sid, dividerID: snap.dividerID, vertical: snap.vertical, seamCenter: snap.seamCenter,
                tiles: snapTiles, memberKeys: keys, memberFrames: frames,
                splitOverrideKey: snap.splitOverrideKey, splitOverrideValue: snap.splitOverrideValue,
                snapLo: snap.snapLo, snapHi: snap.snapHi)
        }
        lastTilesByScreen[sid] = tiles
        log("seam float: \(w.appName) does not fit the resized pane")
    }

    // 松手结算：两侧两格全部成员按最终帧摆一次，再读实际帧复核。
    // 返回 true 表示落定（调用方记 split dragged），false 表示整步撤销或取消。
    // 装不下新格子的窗口浮走，不把用户拖过的份额收回。
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
        }
        var jobs: [SettleJob] = []
        for i in adj {
            let newF = tiles[i].frame
            for w in tiles[i].stack { frameMotions.removeValue(forKey: winKey(w)) }
            for w in tiles[i].stack {
                let key = winKey(w)
                let old = lastPlacedFrames[key] ?? tiles[i].frame
                let shrinking = newF.width <= old.width + 0.5 && newF.height <= old.height + 0.5
                jobs.append(SettleJob(el: w.element, old: old, new: newF, key: key, shrinking: shrinking))
            }
        }
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
        // 复核：跨格真重叠时，装不下的窗口浮走，份额留下。
        // 只有两边都装得下自己的格子却仍重叠，才整步撤销。
        var samples: [(tile: Int, window: WinInfo, actual: CGRect, cell: CGRect)] = []
        for i in adj {
            for w in tiles[i].stack {
                if let actual = getFrame(w.element, screenHeight: mh) {
                    samples.append((tile: i, window: w, actual: actual, cell: tiles[i].frame))
                }
            }
        }
        let decision = classifySeamOverlap(samples)
        if decision.revert {
            // 整步撤销：顶部 + 成员都送回 phase 0 快照的拖前帧，格子记录、手柄、
            // splitOverrides 一并复位（沿用每拖节流的撤销日志）。
            for j in jobs {
                let target = snap.memberFrames[j.key] ?? j.old
                let shrinkingBack = target.width <= j.new.width + 0.5 && target.height <= j.new.height + 0.5
                if shrinkingBack {
                    setSize(j.el, target.size)
                    setPosition(j.el, CGPoint(x: target.minX, y: mh - target.maxY))
                } else {
                    let step = CGSize(width: min(j.new.width, target.width), height: min(j.new.height, target.height))
                    setSize(j.el, step)
                    setPosition(j.el, CGPoint(x: target.minX, y: mh - target.maxY))
                    setSize(j.el, target.size)
                }
                lastPlacedFrames[j.key] = target
            }
            var restored = tiles
            for i in tiles.indices {
                let keys = Set(tiles[i].stack.map { winKey($0) })
                if let s = snap.tiles.first(where: { $0.keys == keys }) { restored[i].frame = s.frame }
            }
            lastTilesByScreen[sid] = restored
            if screenID(activeScreen()) == sid { lastTiles = restored }
            if let v = snap.splitOverrideValue {
                splitOverrides[snap.splitOverrideKey] = v
            } else {
                splitOverrides.removeValue(forKey: snap.splitOverrideKey)
            }
            if let panel = gripPanels["\(sid)-\(dividerID)"] {
                if vertical {
                    panel.setFrameOrigin(NSPoint(x: snap.seamCenter - panel.frame.width / 2, y: panel.frame.minY))
                } else {
                    panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: snap.seamCenter - panel.frame.height / 2))
                }
            }
            for (i, f) in restored.map({ $0.frame }).enumerated() {
                let dk = "\(sid):\(i)"
                dimPanels[dk]?.setFrame(f, display: true)
                if let hp = highlightPanels[dk] {
                    hp.setFrame(f.insetBy(dx: -self.borderInk().pad, dy: -self.borderInk().pad), display: true)
                }
            }
            raiseGrips()
            if !dividerRevertLogged {
                log("divider drag reverted: panes that both fit still overlapped, seam stays")
                dividerRevertLogged = true
            }
            return false
        }
        let ejected = Set(decision.offenders.map { winKey($0) })
        for w in decision.offenders {
            let owner = samples.first { winKey($0.window) == winKey(w) }?.tile ?? adj.first ?? 0
            ejectSeamOffender(w, tileIndex: owner, screen: screen, sid: sid, tiles: &tiles)
        }
        lastTilesByScreen[sid] = tiles
        // 落定：写还在格子里的成员落点。浮走的窗口落点由 floatOversized 记下。
        for j in jobs where !ejected.contains(j.key) { lastPlacedFrames[j.key] = j.new }
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
        // 顶部实际帧跨格重叠时：装不下的浮走，份额照记。
        // 两边都装得下却仍重叠，才把这一步退回，不把坏的重叠存下来。
        var samples: [(tile: Int, window: WinInfo, actual: CGRect, cell: CGRect)] = []
        for i in adj where !tiles[i].stack.isEmpty {
            if let actual = getFrame(tiles[i].top.element, screenHeight: mh) {
                samples.append((tile: i, window: tiles[i].top, actual: actual, cell: newFrames[i]))
            }
        }
        let decision = classifySeamOverlap(samples)
        if decision.revert {
            for j in jobs {
                let shrinkingBack = j.old.width <= j.new.width + 0.5 && j.old.height <= j.new.height + 0.5
                if shrinkingBack {
                    setSize(j.el, j.old.size)
                    setPosition(j.el, CGPoint(x: j.old.minX, y: mh - j.old.maxY))
                } else {
                    let step = CGSize(width: min(j.old.width, j.new.width), height: min(j.old.height, j.new.height))
                    setSize(j.el, step)
                    setPosition(j.el, CGPoint(x: j.old.minX, y: mh - j.old.maxY))
                    setSize(j.el, j.old.size)
                }
            }
            for i in oldFrames.indices { tiles[i].frame = oldFrames[i] }
            lastTilesByScreen[sid] = tiles
            if screenID(activeScreen()) == sid { lastTiles = tiles }
            if let panel = gripPanels["\(sid)-\(dividerID)"] {
                if vertical {
                    panel.setFrameOrigin(NSPoint(x: d.center - panel.frame.width / 2, y: panel.frame.minY))
                } else {
                    panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: d.center - panel.frame.height / 2))
                }
            }
            for (i, f) in oldFrames.enumerated() {
                let dk = "\(sid):\(i)"
                dimPanels[dk]?.setFrame(f, display: true)
                if let hp = highlightPanels[dk] {
                    hp.setFrame(f.insetBy(dx: -self.borderInk().pad, dy: -self.borderInk().pad), display: true)
                }
            }
            raiseGrips()
            // 同一拖动会话里只记一次，避免两边都装得下却仍重叠时每步刷屏。
            if !dividerRevertLogged {
                log("divider drag reverted: panes that both fit still overlapped, seam stays")
                dividerRevertLogged = true
            }
            return
        }
        let ejected = Set(decision.offenders.map { winKey($0) })
        for w in decision.offenders {
            let owner = samples.first { winKey($0.window) == winKey(w) }?.tile ?? 0
            ejectSeamOffender(w, tileIndex: owner, screen: screen, sid: sid, tiles: &tiles)
        }
        // 成功一步只写还在格子里的顶部；装不下的已经浮走。成员留到松手结算。
        for j in jobs where !ejected.contains(j.key) { lastPlacedFrames[j.key] = j.new }
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
                hp.setFrame(f.insetBy(dx: -self.borderInk().pad, dy: -self.borderInk().pad), display: true)
            }
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
            stackTops[stackTopKey(stackPanelSid, permSrcSlot(stackPanelTile, sid: stackPanelSid))] = idx
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
    func hoverColumn(_ title: String, symbol: String, action: Selector, enabled: Bool) -> NSButton {
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
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(enabled ? 0.12 : 0.06).cgColor
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
        let primaryOn = !floated && !focus && tileIndex > 0
        let focusOn = !floated
        let thirdTitle = floated ? "Tile" : "Float"
        let thirdSymbol = floated ? "square.grid.2x2" : "square.on.square"
        let thirdAction: Selector = floated ? #selector(hoverTileBack(_:)) : #selector(hoverFloat(_:))
        actions.addArrangedSubview(hoverColumn("Primary", symbol: "sidebar.left", action: #selector(hoverPrimary(_:)), enabled: primaryOn))
        actions.addArrangedSubview(hoverColumn(focus ? "Exit focus" : "Focus", symbol: "arrow.up.left.and.arrow.down.right", action: #selector(hoverFocus(_:)), enabled: focusOn))
        actions.addArrangedSubview(hoverColumn(thirdTitle, symbol: thirdSymbol, action: thirdAction, enabled: true))
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
    func floatWindow(_ w: WinInfo, source: String) {
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
        let frame = manualFloatFrame(on: screen, need: effectiveMin(for: w))
        placeFrame(w.element, frame, key: key, animated: true)
        lastPlacedFrames[key] = frame
        log("\(source) float -> \(w.appName) centered")
        forceTile()
        refreshPanel()
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
    func gripZone(of frame: CGRect) -> CGRect {
        CGRect(x: frame.midX - 24, y: frame.maxY - 9, width: 48, height: 18)
    }

    func tileUnderPointer(_ m: CGPoint) -> (sid: CGDirectDisplayID, index: Int, tile: (stack: [WinInfo], frame: CGRect, top: WinInfo), screen: NSScreen)? {
        // 只认活动窗口自己的握把，不认指针下面的其它格子。
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        for (sid, tiles) in lastTilesByScreen {
            guard let screen = NSScreen.screens.first(where: { screenID($0) == sid }) else { continue }
            for (i, t) in tiles.enumerated() where t.top.pid == app.processIdentifier {
                if gripZone(of: t.frame).contains(m) {
                    return (sid, i, t, screen)
                }
            }
        }
        return nil
    }

    /// Hover focus：指针在某扇窗上停留约 0.15 秒就把它提到前面。和悬停条是两件事。
    func activateHoveredWindow(_ m: CGPoint) {
        guard hoverFocus, focusKey == nil, !cleanSpaceOn else { return }
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
        hoverFocusDoneFor = found.id
        AXUIElementPerformAction(found.win.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: found.win.pid)?.activate()
        log("hover focus -> \(found.win.appName)")
    }

    func updateHover() {
        let m = NSEvent.mouseLocation
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
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if !floatedKeys.isEmpty,
               let fw = collectWindows(includeFloated: true).first(where: {
                   floatedKeys.contains(winKey($0)) && fwMatchesFront($0, front) && gripZone(of: $0.frame).contains(m)
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
        stackTops[stackTopKey(sid, permSrcSlot(tile, sid: sid))] = index
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: w.pid)?.activate()
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
        stackTops[stackTopKey(hoverSid, permSrcSlot(hoverTile, sid: hoverSid))] = idx
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
        guard hoverActionArmed() else { return }
        // Primary 交换：被点窗口与 tile0 顶部互换格子（被点窗口进 tile0 并成为其顶部，
        // 被换出的 tile0 顶部进被点窗口原格子、接替其栈位，尺寸随格子变）。
        // 已是 tile0 顶部时按钮 disabled（守卫）；悬浮窗口不可 Primary（守卫）。
        guard let w = resolveHoverTarget() else { return }
        guard hoverTile > 0 else { return }
        let key = winKey(w)
        guard !floatedKeys.contains(key) else { return }
        guard let tiles = lastTilesByScreen[hoverSid], hoverTile < tiles.count, !tiles[0].stack.isEmpty else { return }
        // 先 raise 被换出的 tile0 顶部，forceTile 后再 raise 被点窗口并激活，使其视觉置顶。
        let top0 = tiles[0].top
        AXUIElementPerformAction(top0.element, kAXRaiseAction as CFString)
        primaryKeysByScreen[hoverSid] = key
        // 新 Primary 指定胜过旧的整叠置换：否则新 Primary 会被置换带到别的格，看起来像没生效。
        tileSwapPermByScreen.removeValue(forKey: hoverSid)
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
        guard hoverActionArmed() else { return }
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
        guard hoverActionArmed() else { return }
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

    /// 描边画在格子外侧的缝里。线宽是用户选的 2–6。有效间距至少等于线宽，所以线不会盖住窗口。
    func borderInk() -> (pad: CGFloat, line: CGFloat, outset: CGFloat) {
        let line = min(6, max(2, borderThickness))
        let pad = line
        let outset = line / 2
        return (pad, line, outset)
    }

    func highlightNSColor() -> NSColor {
        switch highlightColor {
        case .accent:
            return .controlAccentColor
        case .purple:
            return NSColor(srgbRed: 0.62, green: 0.36, blue: 0.95, alpha: 1)
        case .pink:
            return NSColor(srgbRed: 0.96, green: 0.42, blue: 0.64, alpha: 1)
        case .orange:
            return NSColor(srgbRed: 0.98, green: 0.55, blue: 0.22, alpha: 1)
        case .green:
            return NSColor(srgbRed: 0.30, green: 0.75, blue: 0.45, alpha: 1)
        case .graphite:
            return NSColor(srgbRed: 0.55, green: 0.55, blue: 0.58, alpha: 1)
        }
    }

    func refreshHighlights() {
        guard highlightMode != .none, AXIsProcessTrusted(), autoTile, focusKey == nil, !cleanSpaceOn else {
            hideHighlights()
            return
        }
        let ink = highlightNSColor().withAlphaComponent(0.95)
        let metrics = borderInk()
        var wanted: [String: (CGRect, Bool)] = [:]
        for (sid, tiles) in lastTilesByScreen where !tiles.isEmpty {
            let active = min(lastActiveTileByScreen[sid] ?? 0, tiles.count - 1)
            if highlightMode == .glow {
                let t = tiles[active].frame
                let w = max(8, t.width * 0.8)
                let lift = max(gapForLayout(), 4) / 2 + 1.5
                let rect = CGRect(x: t.midX - w / 2, y: t.maxY + lift - 1.5, width: w, height: 3)
                wanted["\(sid):glow"] = (rect, true)
            } else {
                let indices: [Int] = highlightMode == .allBorders ? Array(tiles.indices) : [active]
                for i in indices {
                    let rect = tiles[i].frame.insetBy(dx: -metrics.pad, dy: -metrics.pad)
                    wanted["\(sid):\(i)"] = (rect, false)
                }
            }
        }
        for (i, item) in wanted {
            let frame = item.0
            let glow = item.1
            if let p = highlightPanels[i] {
                if p.frame != frame { p.setFrame(frame, display: true) }
                if let v = p.contentView as? HighlightBorderView {
                    v.strokeColor = ink
                    v.lineWidth = glow ? 3 : metrics.line
                    v.pad = metrics.pad
                    v.outset = metrics.outset
                    v.glow = glow
                    v.needsDisplay = true
                }
                if !p.isVisible { p.orderFront(nil) }
            } else {
                let view = HighlightBorderView(frame: NSRect(origin: .zero, size: frame.size))
                view.strokeColor = ink
                view.lineWidth = glow ? 3 : metrics.line
                view.pad = metrics.pad
                view.outset = metrics.outset
                view.glow = glow
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
        // 其它窗口留在原位。帘子盖住它们，不最小化，也不把它们挪出屏幕。
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
        let full = focusFrame(on: screen)
        placeFrame(w.element, full, key: targetKey, animated: true)
        lastPlacedFrames[targetKey] = full
        hideGrips()
        hideHoverBar()
        hideDotHandles()
        hideStackMarkers()
        hideHighlights()
        removeDimLayers()
        closeStackPanel()
        showFocusCaption(on: screen, frame: full)
        log("focus on: \(w.appName)")
    }

    var focusCaptionPanel: NSPanel?

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
            return
        }
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        prepareOverlay(p, level: .popUpMenu, ignoresMouse: false)
        p.contentView = v
        p.orderFrontRegardless()
        focusCaptionPanel = p
    }

    @objc func focusCaptionClick(_ sender: NSButton) {
        exitFocus()
        hideHoverBar()
        refreshPanel()
    }

    func hideFocusCaption() {
        focusCaptionPanel?.orderOut(nil)
        focusCaptionPanel = nil
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

    func dragMouseDown(_ event: CGEvent) -> Bool {
        guard AXIsProcessTrusted(), autoTile else { return false }
        plainDragTrack = nil
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
        // C 批：拖动只在鼠标所在屏的磁贴上进行
        let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let sid = screenID(screen)
        guard let tiles = lastTilesByScreen[sid], tiles.count > 1 else { return false }
        let frames = tiles.map { $0.frame }
        guard let src = frames.firstIndex(where: { $0.contains(p) }) else { return false }
        // ⌘ 交换；再按住 ⌥ 则加入堆叠。只认 option 与 command。
        let mode = dragMode(from: flags)
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
                if let src = frames.firstIndex(where: { $0.contains(dp) }) {
                    let mode = dragMode(from: event.flags)
                    var d = DragState(mode: mode, sourceTile: src, draggedKey: winKey(tiles[src].top), frames: frames, screenID: dsid)
                    d.tileTopKeys = tiles.map { winKey($0.top) }
                    d.ownsDrag = false
                    d.originFrame = lastPlacedFrames[d.draggedKey] ?? frames[src]
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

    // 松手：落到另一磁贴就交换或进堆叠，两边从当前帧落定到最终格子。
    // 否则把抬起的窗口放回原格。按下时已按 ⌘ 的拖动吞掉这次松手；系统已经在拖的不吞。
    // 交换还是进叠看松手时的修饰键，拖到一半也可以改。
    func dragMouseUp(_ event: CGEvent) -> Bool {
        guard var d = dragState else {
            pendingDrag = nil
            plainDownPoint = nil; plainDownScreenID = nil
            plainDragTrack = nil
            return false
        }
        applyDragMode(&d, flags: event.flags)
        dragState = nil
        plainDragTrack = nil
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
        plainDragTrack = nil
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

    var spreadCounts = [0, 0, 0]
    for ordinal in 0..<17 {
        spreadCounts[overflowTileIndex(windowOrdinal: ordinal, tileCount: 3)] += 1
    }
    tileProtoCheck(spreadCounts == [6, 6, 5], "17 windows spread across 3 panes")
    tileProtoCheck(overflowTileIndex(windowOrdinal: 0, tileCount: 3) == 0, "the first window opens pane 0")
    tileProtoCheck(overflowTileIndex(windowOrdinal: -4, tileCount: 3) == 0, "a negative ordinal stays in pane 0")
    tileProtoCheck(overflowTileIndex(windowOrdinal: 4, tileCount: 0) == 0, "zero panes does not divide by zero")

    func spread(_ total: Int, panes: Int) -> [[Int]] {
        var grouped = Array(repeating: [Int](), count: panes)
        for ordinal in 0..<total {
            grouped[overflowTileIndex(windowOrdinal: ordinal, tileCount: panes)].append(ordinal)
        }
        return grouped
    }
    let busyNeeds = (0..<17).map { _ in CGSize(width: 280, height: 180) }
    for kind in [LayoutKind.grid, .columns, .rows, .side] {
        let panes = effectiveTileLimit(defaultTileLimit, kind: kind, vf: mac, gap: macGap)
        let plan = planTileFit(needs: busyNeeds, groups: spread(17, panes: panes), bound: [:]) { groups in
            layoutFrames(count: groups.count, vf: mac, kind: kind, share: 0.5, gap: macGap)
        }
        let name = layoutFamilyName(kind)
        tileProtoCheck(plan.groups.count == panes, "busy \(name) keeps \(panes) panes")
        tileProtoCheck(plan.floated.isEmpty, "busy \(name) keeps normal windows tiled")
        let counts = plan.groups.map { $0.count }
        let low = counts.min() ?? 0
        let high = counts.max() ?? 0
        tileProtoCheck(high - low <= 1, "busy \(name) stacks differ by at most one window")
    }
    let wideNeeds = (0..<9).map { _ in CGSize(width: 800, height: 220) }
    let wideColumns = planTileFit(needs: wideNeeds, groups: spread(9, panes: 3), bound: [:]) { groups in
        layoutFrames(count: groups.count, vf: mac, kind: .columns, share: 0.5, gap: macGap)
    }
    tileProtoCheck(wideColumns.groups.count == 3 && wideColumns.floated.isEmpty, "800pt windows stay in three columns")
    let wideGrid = planTileFit(needs: wideNeeds, groups: spread(9, panes: 4), bound: [:]) { groups in
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
    tileProtoCheck(macGrid3 == macSide3, "grid 3 and side 3 share one shape")
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
    tileProtoCheck(effectiveLayoutGap(setGap: 8, mode: .none, border: 4) == 8, "no highlight keeps the set gap")
    tileProtoCheck(effectiveLayoutGap(setGap: 0, mode: .allBorders, border: 4) == 4, "borders grow the gap to the border")
    tileProtoCheck(effectiveLayoutGap(setGap: 8, mode: .allBorders, border: 3) == 8, "a wider gap stays wider than the border")
    tileProtoCheck(effectiveLayoutGap(setGap: 0, mode: .glow, border: 2) == 4, "glow keeps at least 4pt")
    tileProtoCheck(effectiveLayoutGap(setGap: 10, mode: .glow, border: 2) == 10, "glow does not shrink a larger gap")
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
    tileProtoCheck(windowIsSeamOffender(minSize: CGSize(width: 900, height: 200), cell: cell, actual: inside), "a minimum wider than the pane is an offender")
    tileProtoCheck(windowIsSeamOffender(minSize: .zero, cell: cell, actual: spilling), "an actual frame past the pane is an offender")
    tileProtoCheck(!windowIsSeamOffender(minSize: CGSize(width: 200, height: 200), cell: cell, actual: inside), "a window that fits is not an offender")
    tileProtoCheck(!seamMustRevert([]), "no overlap does not revert the seam")
    tileProtoCheck(!seamMustRevert([(offenderA: true, offenderB: false)]), "one offender does not revert the seam")
    tileProtoCheck(!seamMustRevert([(offenderA: true, offenderB: true)]), "two offenders do not revert the seam")
    tileProtoCheck(seamMustRevert([(offenderA: false, offenderB: false)]), "two windows that both fit still revert the seam")
    tileProtoCheck(seamMustRevert([(offenderA: true, offenderB: false), (offenderA: false, offenderB: false)]), "one clean pair is enough to revert the seam")
    let tall = CGRect(x: 0, y: 0, width: 1440, height: 1200)
    tileProtoCheck(layoutCountFits(3, kind: .rows, vf: tall, gap: macGap), "taller screen unlocks three rows")
    tileProtoCheck(layoutCountFits(4, kind: .side, vf: tall, gap: macGap), "taller screen unlocks side 4")

    let macGrid = layoutFrames(count: 3, vf: mac, kind: .grid, share: 0.5, gap: macGap)
    let macCols = layoutFrames(count: 3, vf: mac, kind: .columns, share: 0.5, gap: macGap)
    tileProtoCheck(macGrid.count == 3 && macCols.count == 3, "macbook count 3 frames")
    tileProtoCheck(abs(macGrid[0].width - macCols[0].width) > 20, "grid 3 is not three equal columns")
    tileProtoCheck(macGrid[0].height > macGrid[1].height + 1, "grid 3 keeps one tall pane")
    let macSide = layoutFrames(count: 3, vf: mac, kind: .side, share: 2.0 / 3.0, gap: macGap)
    tileProtoCheck(macSide[0].width > macSide[1].width + 100, "two-thirds widens the side primary")

    tileProtoCheck(layoutCaption(kind: .side, count: 3) == "Side · One big, two beside", "side 3 caption")
    tileProtoCheck(layoutCaption(kind: .grid, count: 3) == "Grid · One big, two small", "grid 3 caption")
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
