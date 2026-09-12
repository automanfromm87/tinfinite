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
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    /// 当前 tessellation 容差（提交/LOD 时更新；缓存缺失时重建用）
    private var currentTolerance: CGFloat = 0.35

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// 撤销栈深度（Controller 跨域 journal 用：比较调用前后判断是否产生了新条目）
    var undoDepth: Int { undoStack.count }

    // MARK: - 提交

    /// 提交 live 笔画（spine 已由采样器生成）
    mutating func commitStroke(
        rawPoints: [StrokePoint], spine: [SpinePoint],
        style: StrokeStyle, tolerance: CGFloat
    ) -> (Stroke, RenderSync) {
        currentTolerance = tolerance
        let mesh = StrokeGeometry.tessellate(spine: spine, color: style.color, flattenTolerance: tolerance)
        let stroke = Stroke(points: rawPoints, style: style, bounds: StrokeGeometry.bounds(of: spine), spine: spine)
        strokes.append(stroke)
        meshes[stroke.id] = mesh
        pushUndo(.added(stroke: stroke))
        return (stroke, RenderSync(upserts: [RenderedStroke(id: stroke.id, mesh: mesh, bounds: stroke.bounds)]))
    }

    /// 合成笔画（Demo/导入）：世界点列 -> 重采样 spine -> 提交
    mutating func addSynthetic(
        points: [StrokePoint], style: StrokeStyle, tolerance: CGFloat
    ) -> (Stroke, RenderSync)? {
        let spine = Self.resampleWorld(points: points, style: style)
        guard !spine.isEmpty else { return nil }
        return commitStroke(rawPoints: points, spine: spine, style: style, tolerance: tolerance)
    }

    /// 世界空间轻量重采样（合成点列用）
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
            spine.append(SpinePoint(center: p.position, width: style.width(forPressure: p.pressure)))
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
        pushUndo(.removed(items: items))
        sanitizeSelection()
        sweepMeshCache()
        return RenderSync(removedIDs: ids)
    }

    // MARK: - 橡皮

    /// 整笔擦：删除被路径命中的笔画（一步 undo）
    mutating func eraseStrokes(path: [CGPoint], radius: CGFloat) -> RenderSync {
        guard path.count >= 2 else { return .empty }
        var hitIndices: [Int] = []
        for (i, s) in strokes.enumerated() {
            if EraserHitTest.strokeHit(spine: s.spine, path: path, eraserRadius: radius) {
                hitIndices.append(i)
            }
        }
        guard !hitIndices.isEmpty else { return .empty }
        let items = hitIndices.map { IndexedStroke(index: $0, stroke: strokes[$0]) }
        let ids = Set(items.map { $0.stroke.id })
        strokes.removeAll { ids.contains($0.id) }
        pushUndo(.removed(items: items))
        sanitizeSelection()
        sweepMeshCache()
        return RenderSync(removedIDs: Array(ids))
    }

    /// 局部擦：spine 手术，被擦中的笔画分裂为碎片（一步 undo）
    mutating func erasePartial(path: [CGPoint], radius: CGFloat, tolerance: CGFloat) -> RenderSync {
        guard path.count >= 2 else { return .empty }
        currentTolerance = tolerance
        var entries: [UndoEntry] = []
        var removed: [UUID] = []
        var upserts: [RenderedStroke] = []
        // 从后往前，保证 index 有效；undo 时按原升序恢复
        for i in strokes.indices.reversed() {
            let s = strokes[i]
            let runs = EraserHitTest.eraseRuns(spine: s.spine, path: path, eraserRadius: radius)
            if runs.count == 1 && runs[0].count == s.spine.count { continue }
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
                    upserts.append(RenderedStroke(id: f.stroke.id, mesh: f.mesh, bounds: f.stroke.bounds))
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
            let m = StrokeGeometry.tessellate(spine: run, color: stroke.style.color, flattenTolerance: tolerance)
            return (s, m)
        }
    }

    // MARK: - 套索/选择

    /// 套索圈选，返回选中的 id
    mutating func selectLoop(_ loop: [CGPoint]) -> Set<UUID> {
        var result = Set<UUID>()
        if loop.count >= 3 {
            let loopBounds = Self.boundingBox(of: loop)
            for s in strokes {
                guard s.bounds.intersects(loopBounds) else { continue }
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
        for s in strokes.reversed() {
            if LassoHitTest.tapHit(spine: s.spine, point: worldPoint, radius: radius) {
                result = [s.id]
                break
            }
        }
        selection = result
        return result
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
            let mesh = StrokeGeometry.tessellate(spine: s.spine, color: s.style.color, flattenTolerance: tolerance)
            meshes[s.id] = mesh
            upserts.append(RenderedStroke(id: s.id, mesh: mesh, bounds: s.bounds))
        }
        return RenderSync(upserts: upserts)
    }

    // MARK: - 全量

    func renderData() -> [RenderedStroke] {
        strokes.map { s in RenderedStroke(id: s.id, mesh: meshFor(s), bounds: s.bounds) }
    }

    /// 全量替换（加载存档）：清空历史，从 spine 重建 mesh（spine 为空的旧数据从 points 回填）
    mutating func replaceAll(with newStrokes: [Stroke], tolerance: CGFloat) {
        currentTolerance = tolerance
        strokes = newStrokes
        selection.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        meshes.removeAll()
        for i in strokes.indices {
            if strokes[i].spine.isEmpty {
                strokes[i].spine = Self.resampleWorld(points: strokes[i].points, style: strokes[i].style)
            }
            meshes[strokes[i].id] = StrokeGeometry.tessellate(
                spine: strokes[i].spine, color: strokes[i].style.color, flattenTolerance: tolerance
            )
        }
    }

    // MARK: - Undo 引擎

    private mutating func pushUndo(_ entry: UndoEntry) {
        undoStack.append(entry)
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
            return RenderSync(removedIDs: [stroke.id])
        case .removed(let items):
            var upserts: [RenderedStroke] = []
            for item in items.sorted(by: { $0.index < $1.index }) {
                strokes.insert(item.stroke, at: min(item.index, strokes.count))
                let mesh = meshFor(item.stroke)
                meshes[item.stroke.id] = mesh
                upserts.append(RenderedStroke(id: item.stroke.id, mesh: mesh, bounds: item.stroke.bounds))
            }
            return RenderSync(upserts: upserts)
        case .replaced(let index, let original, let fragments):
            let fragIDs = Set(fragments.map(\.id))
            strokes.removeAll { fragIDs.contains($0.id) }
            strokes.insert(original, at: min(index, strokes.count))
            let mesh = meshFor(original)
            meshes[original.id] = mesh
            return RenderSync(
                upserts: [RenderedStroke(id: original.id, mesh: mesh, bounds: original.bounds)],
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
            let mesh = meshFor(stroke)
            meshes[stroke.id] = mesh
            return RenderSync(upserts: [RenderedStroke(id: stroke.id, mesh: mesh, bounds: stroke.bounds)])
        case .removed(let items):
            let ids = Set(items.map { $0.stroke.id })
            strokes.removeAll { ids.contains($0.id) }
            return RenderSync(removedIDs: Array(ids))
        case .replaced(let index, let original, let fragments):
            strokes.removeAll { $0.id == original.id }
            var upserts: [RenderedStroke] = []
            for (offset, frag) in fragments.enumerated() {
                strokes.insert(frag, at: min(index + offset, strokes.count))
                let mesh = meshFor(frag)
                meshes[frag.id] = mesh
                upserts.append(RenderedStroke(id: frag.id, mesh: mesh, bounds: frag.bounds))
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
            strokes[i] = Self.offsetStroke(strokes[i], by: delta)
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
                width: sp.width
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
            spine: stroke.spine, color: stroke.style.color, flattenTolerance: currentTolerance
        )
    }

    /// 清理无引用 mesh（不在 当前笔画/undo/redo 里）：undo/redo 需要时由 spine 重建
    private mutating func sweepMeshCache() {
        var keep = Set(strokes.map(\.id))
        for e in undoStack { keep.formUnion(Self.entryIDs(e)) }
        for e in redoStack { keep.formUnion(Self.entryIDs(e)) }
        meshes = meshes.filter { keep.contains($0.key) }
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
}
