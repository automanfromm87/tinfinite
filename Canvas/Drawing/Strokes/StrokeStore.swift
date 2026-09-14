// StrokeStore.swift
// 笔画状态中心（纯逻辑，无 UIKit，可单测）：提交/undo/redo/橡皮/套索/移动/LOD。
// 每个变更操作返回 RenderSync（渲染增量），由 DrawingController 应用到 Metal 视图。

import CoreGraphics
import Foundation

/// 原地更新的 mesh（顶点/索引数不变，移动笔画用）
nonisolated struct InPlaceMesh: Sendable {
    var id: UUID
    var mesh: StrokeMesh
    var bounds: CGRect
}

/// 渲染增量：upserts（新增/替换）+ removedIDs（删除）+ inPlace（等长原地改）
nonisolated struct RenderSync: Sendable {
    var upserts: [RenderedStroke] = []
    var removedIDs: [UUID] = []
    var inPlace: [InPlaceMesh] = []

    static let empty = RenderSync()

    var isEmpty: Bool { upserts.isEmpty && removedIDs.isEmpty && inPlace.isEmpty }
}

/// 撤销栈变更水位（跨域账本比对用）
nonisolated struct UndoMark: Equatable, Sendable {
    var seq: Int
    var discarded: Int
}

nonisolated struct IndexedStroke: Sendable {
    var index: Int
    var stroke: Stroke
}

nonisolated enum UndoEntry: Sendable {
    case added(stroke: Stroke)
    case removed(items: [IndexedStroke]) // index 升序
    case replaced(index: Int, original: Stroke, fragments: [Stroke])
    case moved(ids: [UUID], delta: CGSize)
    case batch([UndoEntry]) // 一次手势影响多笔时合并为一步 undo
}

nonisolated struct StrokeStore: Sendable {
    private(set) var strokes: [Stroke] = []
    private(set) var selection: Set<UUID> = []
    private var meshes: [UUID: StrokeMesh] = [:]
    /// 每个 mesh 是用哪个容差生成的。LOD 扫描时容差相同就整笔跳过：
    /// lodTolerance 在 scale<=0.0875 / >=175x 两端会钳到常量，
    /// 那些缩放档位重新镶嵌出来的网格逐位相同，纯属白烧 CPU。
    private var meshTolerance: [UUID: CGFloat] = [:]
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    /// 当前 tessellation 容差（提交/LOD 时更新；缓存缺失时重建用）
    private var currentTolerance: CGFloat = 0.35
    /// 空间网格：所有增删改（正向 + undo/redo）都必须同步维护；
    /// 只做候选过滤，精确判定仍由 spine 级测试完成，语义与暴力扫描一致
    private var grid = StrokeSpatialGrid()

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// 撤销栈深度（Controller 跨域 journal 用：比较调用前后判断是否产生了新条目）
    var undoDepth: Int { undoStack.count }

    /// 单调递增的变更序号 + 被上限挤掉的条目数。
    /// 为什么不能只看 undoDepth：栈满 100 之后每次 push 都会同时挤掉最旧的一条，
    /// 深度不再变化，跨域账本就以为「什么都没发生」，从第 101 笔起彻底错位
    /// （撤销键会去撤销节点而不是刚写的字）。
    private(set) var mutationSeq = 0
    private(set) var discardSeq = 0
    var undoMark: UndoMark { UndoMark(seq: mutationSeq, discarded: discardSeq) }

    // MARK: - 提交

    /// 提交 live 笔画（spine 已由采样器生成）
    mutating func commitStroke(
        rawPoints: [StrokePoint], spine: [SpinePoint],
        style: StrokeStyle, tolerance: CGFloat
    ) -> (Stroke, RenderSync) {
        currentTolerance = tolerance
        let mesh = StrokeGeometry.tessellate(spine: spine, color: style.color, flattenTolerance: tolerance, grain: style.grain)
        let stroke = Stroke(points: rawPoints, style: style, bounds: StrokeGeometry.bounds(of: spine), spine: spine)
        strokes.append(stroke)
        meshes[stroke.id] = mesh
        meshTolerance[stroke.id] = tolerance
        grid.insert(id: stroke.id, bounds: stroke.bounds)
        pushUndo(.added(stroke: stroke))
        return (stroke, RenderSync(upserts: [RenderedStroke(id: stroke.id, mesh: mesh, bounds: stroke.bounds, kind: stroke.style.kind)]))
    }

    /// 合成笔画（Demo/导入）：世界点列 -> 重采样 spine -> 提交
    mutating func addSynthetic(
        points: [StrokePoint], style: StrokeStyle, tolerance: CGFloat
    ) -> (Stroke, RenderSync)? {
        let spine = Self.resampleWorld(points: points, style: style)
        guard !spine.isEmpty else { return nil }
        return commitStroke(rawPoints: points, spine: spine, style: style, tolerance: tolerance)
    }

    /// 世界空间轻量重采样（合成点列/旧 spine 缺失回填用；倾斜按存档值参与笔尖响应）
    static func resampleWorld(points: [StrokePoint], style: StrokeStyle) -> [SpinePoint] {
        let minSpacing = max(0.25, style.baseWidth * 0.05)
        var spine: [SpinePoint] = []
        spine.reserveCapacity(points.count)
        for (i, p) in points.enumerated() {
            let isLast = i == points.count - 1
            if let last = spine.last, !isLast {
                let dx = p.position.x - last.center.x
                let dy = p.position.y - last.center.y
                if dx * dx + dy * dy < minSpacing * minSpacing { continue }
            }
            let nib = style.nib(pressure: p.pressure, altitude: p.altitude)
            spine.append(SpinePoint(center: p.position, width: nib.width, alpha: nib.alpha))
        }
        return spine
    }

    // MARK: - Undo/Redo/Clear

    mutating func undo() -> RenderSync? {
        guard let entry = undoStack.popLast() else { return nil }
        let sync = applyInverse(entry)
        redoStack.append(entry)
        sanitizeSelection()
        sweepMeshCache()
        return sync
    }

    mutating func redo() -> RenderSync? {
        guard let entry = redoStack.popLast() else { return nil }
        let sync = applyForward(entry)
        undoStack.append(entry)
        sanitizeSelection()
        sweepMeshCache()
        return sync
    }

    mutating func clear() -> RenderSync {
        guard !strokes.isEmpty else { return .empty }
        let items = strokes.enumerated().map { IndexedStroke(index: $0.offset, stroke: $0.element) }
        let ids = strokes.map(\.id)
        strokes.removeAll()
        grid.removeAll()
        pushUndo(.removed(items: items))
        sanitizeSelection()
        sweepMeshCache()
        return RenderSync(removedIDs: ids)
    }

    // MARK: - 橡皮

    /// 整笔擦：删除被路径命中的笔画（一步 undo）
    mutating func eraseStrokes(path: [CGPoint], radius: CGFloat) -> RenderSync {
        guard path.count >= 2 else { return .empty }
        let candidates = eraseCandidates(path: path, radius: radius)
        let reach = Self.boundingBox(of: path)
        var hitIndices: [Int] = []
        for (i, s) in strokes.enumerated() {
            guard candidates.contains(s.id) else { continue }
            guard Self.overlaps(s.bounds, reach, slack: radius) else { continue }
            if EraserHitTest.strokeHit(spine: s.spine, path: path, eraserRadius: radius) {
                hitIndices.append(i)
            }
        }
        guard !hitIndices.isEmpty else { return .empty }
        let items = hitIndices.map { IndexedStroke(index: $0, stroke: strokes[$0]) }
        let ids = Set(items.map { $0.stroke.id })
        strokes.removeAll { ids.contains($0.id) }
        for id in ids { grid.remove(id: id) }
        pushUndo(.removed(items: items))
        sanitizeSelection()
        sweepMeshCache()
        return RenderSync(removedIDs: Array(ids))
    }

    /// 局部擦：spine 手术，被擦中的笔画分裂为碎片（一步 undo）
    mutating func erasePartial(path: [CGPoint], radius: CGFloat, tolerance: CGFloat) -> RenderSync {
        guard path.count >= 2 else { return .empty }
        currentTolerance = tolerance
        let candidates = eraseCandidates(path: path, radius: radius)
        let reach = Self.boundingBox(of: path)
        var entries: [UndoEntry] = []
        var removed: [UUID] = []
        var upserts: [RenderedStroke] = []
        // 从后往前，保证 index 有效；undo 时按原升序恢复
        for i in strokes.indices.reversed() {
            let s = strokes[i]
            guard candidates.contains(s.id) else { continue }
            guard Self.overlaps(s.bounds, reach, slack: radius) else { continue }
            let runs = EraserHitTest.eraseRuns(spine: s.spine, path: path, eraserRadius: radius)
            if runs.count == 1 && runs[0].count == s.spine.count { continue }
            grid.remove(id: s.id)
            if runs.isEmpty {
                strokes.remove(at: i)
                entries.append(.removed(items: [IndexedStroke(index: i, stroke: s)]))
                removed.append(s.id)
            } else {
                let frags = fragments(for: s, runs: runs, tolerance: tolerance)
                strokes.remove(at: i)
                strokes.insert(contentsOf: frags.map(\.stroke), at: i)
                entries.append(.replaced(index: i, original: s, fragments: frags.map(\.stroke)))
                removed.append(s.id)
                for f in frags {
                    meshes[f.stroke.id] = f.mesh
                    meshTolerance[f.stroke.id] = tolerance
                    grid.insert(id: f.stroke.id, bounds: f.stroke.bounds)
                    upserts.append(RenderedStroke(id: f.stroke.id, mesh: f.mesh, bounds: f.stroke.bounds, kind: f.stroke.style.kind))
                }
            }
        }
        guard !entries.isEmpty else { return .empty }
        // entries 是按 index 降序收集的，反转为升序后打包（undo 恢复顺序正确）
        let ordered = entries.reversed()
        pushUndo(ordered.count == 1 ? ordered.first! : .batch(Array(ordered)))
        sanitizeSelection()
        sweepMeshCache()
        return RenderSync(upserts: upserts, removedIDs: removed)
    }

    private func fragments(
        for stroke: Stroke, runs: [[SpinePoint]], tolerance: CGFloat
    ) -> [(stroke: Stroke, mesh: StrokeMesh)] {
        runs.map { run in
            let raw = run.map { sp in
                StrokePoint(
                    position: sp.center,
                    pressure: stroke.style.pressure(forWidth: sp.width),
                    timestamp: 0
                )
            }
            let s = Stroke(
                points: raw, style: stroke.style,
                bounds: StrokeGeometry.bounds(of: run), spine: run
            )
            let m = StrokeGeometry.tessellate(spine: run, color: stroke.style.color, flattenTolerance: tolerance, grain: stroke.style.grain)
            return (s, m)
        }
    }

    // MARK: - 套索/选择

    /// 套索圈选，返回选中的 id
    mutating func selectLoop(_ loop: [CGPoint]) -> Set<UUID> {
        var result = Set<UUID>()
        if loop.count >= 3 {
            let loopBounds = Self.boundingBox(of: loop)
            let candidates = grid.strokes(in: loopBounds)
            for s in strokes {
                // 便宜的 bbox 复核在前，Set 查找在后
                guard s.bounds.intersects(loopBounds), candidates.contains(s.id) else { continue }
                if LassoHitTest.strokeIntersectsLoop(spine: s.spine, loop: loop) {
                    result.insert(s.id)
                }
            }
        }
        selection = result
        return result
    }

    /// 点选：返回选中的 id（最多一个，最上层）
    mutating func selectTap(at worldPoint: CGPoint, radius: CGFloat) -> Set<UUID> {
        var result = Set<UUID>()
        let candidates = grid.strokes(near: worldPoint, radius: radius)
        for s in strokes.reversed() {
            guard candidates.contains(s.id) else { continue }
            if LassoHitTest.tapHit(spine: s.spine, point: worldPoint, radius: radius) {
                result = [s.id]
                break
            }
        }
        selection = result
        return result
    }

    /// 矩形相交的笔画 id（数组顺序 = z 序；网格候选 + 精确 bbox 复核）。
    /// LOD 可见集等调用方用；.all 回退时与暴力扫描结果一致。
    /// 注意：仍是 O(n) 全数组扫描（缺 id->下标索引），网格只省掉 bbox 比较，
    /// 判据把便宜的 intersects 放前面；真收益在 tap/erase（省 spine 级测试）。
    func strokeIDs(in rect: CGRect) -> [UUID] {
        switch grid.strokes(in: rect) {
        case .all:
            return strokes.filter { $0.bounds.intersects(rect) }.map(\.id)
        case .some(let candidates):
            return strokes.filter { $0.bounds.intersects(rect) && candidates.contains($0.id) }.map(\.id)
        }
    }

    mutating func clearSelection() {
        selection.removeAll()
    }

    func selectionBounds() -> CGRect? {
        var rect: CGRect?
        for s in strokes where selection.contains(s.id) {
            rect = rect?.union(s.bounds) ?? s.bounds
        }
        return rect
    }

    /// 全部笔画的外包矩形（nil = 空画布）。适配缩放/minimap 用。
    func contentBounds() -> CGRect? {
        strokes.reduce(nil as CGRect?) { $0?.union($1.bounds) ?? $1.bounds }
    }

    var hasSelection: Bool { !selection.isEmpty }

    /// 删除选中（一步 undo）
    mutating func deleteSelection() -> RenderSync {
        guard !selection.isEmpty else { return .empty }
        let items = strokes.enumerated().compactMap {
            selection.contains($0.element.id) ? IndexedStroke(index: $0.offset, stroke: $0.element) : nil
        }
        guard !items.isEmpty else {
            selection.removeAll()
            return .empty
        }
        let ids = Set(items.map { $0.stroke.id })
        strokes.removeAll { ids.contains($0.id) }
        for id in ids { grid.remove(id: id) }
        pushUndo(.removed(items: items))
        selection.removeAll()
        sweepMeshCache()
        return RenderSync(removedIDs: Array(ids))
    }

    // MARK: - 移动选中

    /// 移动预览（不改模型/undo）：返回平移后的 mesh 供原地更新
    func previewMoveSelection(by delta: CGSize) -> [InPlaceMesh] {
        strokes.filter { selection.contains($0.id) }.map { s in
            InPlaceMesh(
                id: s.id,
                mesh: StrokeGeometry.translated(meshFor(s), by: delta),
                bounds: s.bounds.offsetBy(dx: delta.width, dy: delta.height)
            )
        }
    }

    /// 提交移动（改模型 + undo）
    mutating func commitMoveSelection(by delta: CGSize) -> RenderSync {
        guard hasSelection, delta.width != 0 || delta.height != 0 else { return .empty }
        let ids = strokes.filter { selection.contains($0.id) }.map(\.id)
        let sync = translateStrokes(ids: ids, by: delta)
        pushUndo(.moved(ids: ids, delta: delta))
        return sync
    }

    /// 取指定笔画当前 mesh（移动取消恢复用）
    func meshesFor(ids: [UUID]) -> [InPlaceMesh] {
        let set = Set(ids)
        return strokes.filter { set.contains($0.id) }.map { s in
            InPlaceMesh(id: s.id, mesh: meshFor(s), bounds: s.bounds)
        }
    }

    // MARK: - LOD

    /// 对指定笔画按新容差重 tessellate（调用方决定时机与可见集）
    mutating func retessellate(ids: [UUID], tolerance: CGFloat) -> RenderSync {
        currentTolerance = tolerance
        let set = Set(ids)
        var upserts: [RenderedStroke] = []
        for s in strokes where set.contains(s.id) {
            // 同容差 + 网格还在 -> 结果逐位相同，跳过
            if meshTolerance[s.id] == tolerance, meshes[s.id] != nil { continue }
            let mesh = StrokeGeometry.tessellate(spine: s.spine, color: s.style.color, flattenTolerance: tolerance, grain: s.style.grain)
            meshes[s.id] = mesh
            meshTolerance[s.id] = tolerance
            upserts.append(RenderedStroke(id: s.id, mesh: mesh, bounds: s.bounds, kind: s.style.kind))
        }
        return RenderSync(upserts: upserts)
    }

    // MARK: - 全量

    func renderData() -> [RenderedStroke] {
        strokes.map { s in RenderedStroke(id: s.id, mesh: meshFor(s), bounds: s.bounds, kind: s.style.kind) }
    }

    /// 全量替换（加载存档）：清空历史，从 spine 重建 mesh（spine 为空的旧数据从 points 回填）
    mutating func replaceAll(with newStrokes: [Stroke], tolerance: CGFloat) {
        currentTolerance = tolerance
        strokes = newStrokes
        selection.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        meshes.removeAll()
        meshTolerance.removeAll()
        for i in strokes.indices {
            if strokes[i].spine.isEmpty {
                strokes[i].spine = Self.resampleWorld(points: strokes[i].points, style: strokes[i].style)
            }
            meshes[strokes[i].id] = StrokeGeometry.tessellate(
                spine: strokes[i].spine, color: strokes[i].style.color, flattenTolerance: tolerance,
                grain: strokes[i].style.grain
            )
            meshTolerance[strokes[i].id] = tolerance
        }
        grid.rebuild(strokes: strokes.map { (id: $0.id, bounds: $0.bounds) })
    }

    // MARK: - Undo 引擎

    /// 撤销栈上限（无界增长会吃掉长会话内存；超限丢弃最旧的一步）
    static let maxUndoDepth = 100

    private mutating func pushUndo(_ entry: UndoEntry) {
        undoStack.append(entry)
        mutationSeq += 1
        if undoStack.count > Self.maxUndoDepth {
            let drop = undoStack.count - Self.maxUndoDepth
            undoStack.removeFirst(drop)
            discardSeq += drop
        }
        redoStack.removeAll()
    }

    private func indexOf(id: UUID) -> Int? {
        strokes.firstIndex { $0.id == id }
    }

    private mutating func applyInverse(_ entry: UndoEntry) -> RenderSync {
        switch entry {
        case .added(let stroke):
            guard let idx = indexOf(id: stroke.id) else { return .empty }
            strokes.remove(at: idx)
            grid.remove(id: stroke.id)
            return RenderSync(removedIDs: [stroke.id])
        case .removed(let items):
            var upserts: [RenderedStroke] = []
            for item in items.sorted(by: { $0.index < $1.index }) {
                strokes.insert(item.stroke, at: min(item.index, strokes.count))
                grid.insert(id: item.stroke.id, bounds: item.stroke.bounds)
                let mesh = meshFor(item.stroke)
                meshes[item.stroke.id] = mesh
                upserts.append(RenderedStroke(id: item.stroke.id, mesh: mesh, bounds: item.stroke.bounds, kind: item.stroke.style.kind))
            }
            return RenderSync(upserts: upserts)
        case .replaced(let index, let original, let fragments):
            let fragIDs = Set(fragments.map(\.id))
            strokes.removeAll { fragIDs.contains($0.id) }
            for id in fragIDs { grid.remove(id: id) }
            strokes.insert(original, at: min(index, strokes.count))
            grid.insert(id: original.id, bounds: original.bounds)
            let mesh = meshFor(original)
            meshes[original.id] = mesh
            return RenderSync(
                upserts: [RenderedStroke(id: original.id, mesh: mesh, bounds: original.bounds, kind: original.style.kind)],
                removedIDs: Array(fragIDs)
            )
        case .moved(let ids, let delta):
            return translateStrokes(ids: ids, by: CGSize(width: -delta.width, height: -delta.height))
        case .batch(let entries):
            // 逆序撤销
            var merged = RenderSync()
            for e in entries.reversed() {
                let s = applyInverse(e)
                merged.upserts.append(contentsOf: s.upserts)
                merged.removedIDs.append(contentsOf: s.removedIDs)
                merged.inPlace.append(contentsOf: s.inPlace)
            }
            return merged
        }
    }

    private mutating func applyForward(_ entry: UndoEntry) -> RenderSync {
        switch entry {
        case .added(let stroke):
            strokes.append(stroke)
            grid.insert(id: stroke.id, bounds: stroke.bounds)
            let mesh = meshFor(stroke)
            meshes[stroke.id] = mesh
            return RenderSync(upserts: [RenderedStroke(id: stroke.id, mesh: mesh, bounds: stroke.bounds, kind: stroke.style.kind)])
        case .removed(let items):
            let ids = Set(items.map { $0.stroke.id })
            strokes.removeAll { ids.contains($0.id) }
            for id in ids { grid.remove(id: id) }
            return RenderSync(removedIDs: Array(ids))
        case .replaced(let index, let original, let fragments):
            strokes.removeAll { $0.id == original.id }
            grid.remove(id: original.id)
            var upserts: [RenderedStroke] = []
            for (offset, frag) in fragments.enumerated() {
                strokes.insert(frag, at: min(index + offset, strokes.count))
                grid.insert(id: frag.id, bounds: frag.bounds)
                let mesh = meshFor(frag)
                meshes[frag.id] = mesh
                upserts.append(RenderedStroke(id: frag.id, mesh: mesh, bounds: frag.bounds, kind: frag.style.kind))
            }
            return RenderSync(upserts: upserts, removedIDs: [original.id])
        case .moved(let ids, let delta):
            return translateStrokes(ids: ids, by: delta)
        case .batch(let entries):
            var merged = RenderSync()
            for e in entries {
                let s = applyForward(e)
                merged.upserts.append(contentsOf: s.upserts)
                merged.removedIDs.append(contentsOf: s.removedIDs)
                merged.inPlace.append(contentsOf: s.inPlace)
            }
            return merged
        }
    }

    private mutating func translateStrokes(ids: [UUID], by delta: CGSize) -> RenderSync {
        let set = Set(ids)
        var result: [InPlaceMesh] = []
        for i in strokes.indices where set.contains(strokes[i].id) {
            let oldBounds = strokes[i].bounds
            strokes[i] = Self.offsetStroke(strokes[i], by: delta)
            grid.move(id: strokes[i].id, from: oldBounds, to: strokes[i].bounds)
            let mesh = StrokeGeometry.translated(meshFor(strokes[i]), by: delta)
            meshes[strokes[i].id] = mesh
            result.append(InPlaceMesh(id: strokes[i].id, mesh: mesh, bounds: strokes[i].bounds))
        }
        return RenderSync(inPlace: result)
    }

    private static func offsetStroke(_ s: Stroke, by d: CGSize) -> Stroke {
        var out = s
        out.points = s.points.map { p in
            var q = p
            q.x += d.width
            q.y += d.height
            return q
        }
        out.spine = s.spine.map { sp in
            SpinePoint(
                center: CGPoint(x: sp.center.x + d.width, y: sp.center.y + d.height),
                width: sp.width,
                alpha: sp.alpha   // 漏掉它会让移动过的铅笔/钢笔笔画变成全不透明
            )
        }
        out.bounds = s.bounds.offsetBy(dx: d.width, dy: d.height)
        return out
    }

    // MARK: - Mesh 缓存

    /// 取 mesh（缺失时按当前容差重建，不写缓存也正确；调用方在需要时自行缓存）
    private func meshFor(_ stroke: Stroke) -> StrokeMesh {
        if let m = meshes[stroke.id] { return m }
        return StrokeGeometry.tessellate(
            spine: stroke.spine, color: stroke.style.color, flattenTolerance: currentTolerance,
            grain: stroke.style.grain
        )
    }

    /// 清理无引用 mesh（不在 当前笔画/undo/redo 里）：undo/redo 需要时由 spine 重建
    private mutating func sweepMeshCache() {
        var keep = Set(strokes.map(\.id))
        for e in undoStack { keep.formUnion(Self.entryIDs(e)) }
        for e in redoStack { keep.formUnion(Self.entryIDs(e)) }
        meshes = meshes.filter { keep.contains($0.key) }
        meshTolerance = meshTolerance.filter { keep.contains($0.key) }
    }

    private static func entryIDs(_ entry: UndoEntry) -> Set<UUID> {
        switch entry {
        case .added(let s): return [s.id]
        case .removed(let items): return Set(items.map { $0.stroke.id })
        case .replaced(_, let orig, let frags): return Set([orig.id] + frags.map(\.id))
        case .moved(let ids, _): return Set(ids)
        case .batch(let entries): return entries.reduce(into: Set<UUID>()) { $0.formUnion(entryIDs($1)) }
        }
    }

    private mutating func sanitizeSelection() {
        let ids = Set(strokes.map(\.id))
        selection = selection.intersection(ids)
    }

    private static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var rect = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() {
            rect = rect.union(CGRect(origin: p, size: .zero))
        }
        return rect
    }

    /// 闭区间重叠判定（含松弛量）。橡皮的精确判定是
    /// O(候选数 × spine 点数 × 路径点数)——实测 2000 笔一次划擦 31ms；
    /// 网格候选是按 256 单位的格子给的，比橡皮走廊粗约 9 倍，所以这层
    /// 廉价的包围盒复核能砍掉绝大多数候选（实测 31ms -> 2.3ms）。
    ///
    /// 它是**纯前置过滤**，不会漏判：StrokeGeometry.bounds 已把 spine 外扩了
    /// 最大半宽，命中要求某路径点 q 满足 |center-q| < w/2 + radius，
    /// 从 center 朝 q 走 min(d, w/2) 的那个点必在 s.bounds 内，
    /// 故 q 必落在 s.bounds 外扩 radius 的范围里。
    private static func overlaps(_ a: CGRect, _ b: CGRect, slack: CGFloat) -> Bool {
        guard !a.isNull, !b.isNull else { return false }
        return a.minX - slack <= b.maxX && b.minX <= a.maxX + slack
            && a.minY - slack <= b.maxY && b.minY <= a.maxY + slack
    }

    /// 橡皮路径候选集（路径 bbox 外扩半径；.all = 回退全量扫描）
    private func eraseCandidates(path: [CGPoint], radius: CGFloat) -> Candidates {
        let box = Self.boundingBox(of: path)
        guard !box.isNull, radius.isFinite, radius >= 0 else { return .all }
        return grid.strokes(in: box.insetBy(dx: -radius, dy: -radius))
    }

    #if DEBUG
    /// 自检用：网格内笔画数（与 strokes.count 对照，验证索引同步）
    var gridCountForTest: Int { grid.count }
    #endif
}
