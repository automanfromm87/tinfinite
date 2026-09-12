import CoreGraphics
import Foundation

// EditingSuite：橡皮/套索/移动/LOD/Store/持久化（纯逻辑，macOS swiftc 可跑）
// 运行见 Tests/run_tests.sh

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if !cond { failures += 1; print("FAIL: \(msg)") }
}
func approx(_ a: CGFloat, _ b: CGFloat, eps: CGFloat = 1e-6) -> Bool { abs(a - b) < eps }

// ---------- 构造器 ----------

let testStyle = StrokeStyle(color: .black, baseWidth: 4, minWidthScale: 0, pressureExponent: 1)

func linePoints(x0: CGFloat, x1: CGFloat, y: CGFloat, n: Int, p: CGFloat = 1) -> [StrokePoint] {
    (0..<n).map { i in
        let t = n == 1 ? 0 : CGFloat(i) / CGFloat(n - 1)
        return StrokePoint(position: CGPoint(x: x0 + (x1 - x0) * t, y: y), pressure: p, timestamp: Double(i) / 240.0)
    }
}

func addLine(_ store: inout StrokeStore, x0: CGFloat, x1: CGFloat, y: CGFloat, n: Int, tol: CGFloat = 0.35) -> Stroke {
    let (s, _) = store.addSynthetic(points: linePoints(x0: x0, x1: x1, y: y, n: n), style: testStyle, tolerance: tol)!
    return s
}

// ---------- 1. 提交/undo/redo ----------

do {
    var store = StrokeStore()
    let (s, sync) = store.addSynthetic(points: linePoints(x0: 0, x1: 10, y: 0, n: 11), style: testStyle, tolerance: 0.35)!
    check(store.strokes.count == 1, "commit count")
    check(sync.upserts.count == 1 && sync.removedIDs.isEmpty, "commit sync shape")
    check(!sync.upserts[0].mesh.isEmpty, "commit mesh built")
    check(s.spine.count == 11, "spine kept \(s.spine.count)")
    check(store.canUndo && !store.canRedo, "undo available")

    let u = store.undo()!
    check(store.strokes.isEmpty && u.removedIDs == [s.id], "undo removes")
    check(!store.canUndo && store.canRedo, "redo available")
    check(store.undo() == nil, "undo empty -> nil")

    let r = store.redo()!
    check(store.strokes.count == 1 && r.upserts.count == 1, "redo restores")
    check(!r.upserts[0].mesh.isEmpty, "redo mesh rebuilt")
    check(store.canUndo && !store.canRedo, "undo available again")
}

// ---------- 2. clear/undo 保序 ----------

do {
    var store = StrokeStore()
    let a = addLine(&store, x0: 0, x1: 10, y: 0, n: 5)
    let b = addLine(&store, x0: 0, x1: 10, y: 100, n: 5)
    let c = store.clear()
    check(c.removedIDs.count == 2 && store.strokes.isEmpty, "clear removes all")
    _ = store.undo()
    check(store.strokes.map(\.id) == [a.id, b.id], "clear-undo restores order")
}

// ---------- 3. 整笔擦 ----------

do {
    var store = StrokeStore()
    let a = addLine(&store, x0: 0, x1: 10, y: 0, n: 11)
    let b = addLine(&store, x0: 0, x1: 10, y: 100, n: 11)
    let path = [CGPoint(x: 5, y: -50), CGPoint(x: 5, y: 50)]
    let sync = store.eraseStrokes(path: path, radius: 5)
    check(sync.removedIDs == [a.id] && store.strokes.map(\.id) == [b.id], "whole erase hits one")
    _ = store.undo()
    check(store.strokes.map(\.id) == [a.id, b.id], "erase-undo restores order")
    // 未命中 -> 空
    let miss = store.eraseStrokes(path: [CGPoint(x: 500, y: 500), CGPoint(x: 600, y: 600)], radius: 5)
    check(miss.isEmpty && store.strokes.count == 2, "erase miss")
}

// ---------- 4. 局部擦 ----------

do {
    var store = StrokeStore()
    let s = addLine(&store, x0: 0, x1: 10, y: 0, n: 11)
    // 橡皮竖线 x=5，半径 1.5：杀伤 |x-5| < 2+1.5 -> x=2..8，剩 [0,1] [9,10]
    let sync = store.erasePartial(path: [CGPoint(x: 5, y: -5), CGPoint(x: 5, y: 5)], radius: 1.5, tolerance: 0.35)
    check(sync.removedIDs == [s.id] && sync.upserts.count == 2, "partial splits into 2")
    check(store.strokes.count == 2, "fragments stored")
    let fragSpines = store.strokes.map { $0.spine.count }.sorted()
    check(fragSpines == [2, 2], "fragment spine counts \(fragSpines)")
    check(!sync.upserts[0].mesh.isEmpty, "fragment mesh built")
    // 碎片 raw 点压力可反推（宽度 4 -> 压力 1）
    check(approx(store.strokes[0].points[0].pressure, 1), "fragment pressure inverted")

    _ = store.undo()
    check(store.strokes.count == 1 && store.strokes[0].spine.count == 11, "partial-undo restores")
    _ = store.redo()
    check(store.strokes.count == 2, "partial-redo re-applies")

    // 未命中（add 本身占一条 undo，miss 不应新增：一次 undo 应直接回到空）
    var store2 = StrokeStore()
    _ = addLine(&store2, x0: 0, x1: 10, y: 0, n: 11)
    let miss = store2.erasePartial(path: [CGPoint(x: 500, y: 500), CGPoint(x: 500, y: 600)], radius: 5, tolerance: 0.35)
    check(miss.isEmpty && store2.strokes.count == 1, "partial miss")
    _ = store2.undo()
    check(store2.strokes.isEmpty && !store2.canUndo, "miss pushed no entry")

    // 全擦光 -> 按删除
    var store3 = StrokeStore()
    _ = addLine(&store3, x0: 0, x1: 10, y: 0, n: 11)
    let full = store3.erasePartial(path: [CGPoint(x: 5, y: -50), CGPoint(x: 5, y: 50)], radius: 20, tolerance: 0.35)
    check(full.upserts.isEmpty && full.removedIDs.count == 1 && store3.strokes.isEmpty, "partial full-erase")
    _ = store3.undo()
    check(store3.strokes.count == 1, "full-erase undo")
}

// ---------- 5. eraseRuns / strokeHit 单元 ----------

do {
    let spine = (0...10).map { SpinePoint(center: CGPoint(x: CGFloat($0), y: 0), width: 4) }
    let path = [CGPoint(x: 5, y: -5), CGPoint(x: 5, y: 5)]
    let runs = EraserHitTest.eraseRuns(spine: spine, path: path, eraserRadius: 1.5)
    check(runs.count == 2 && runs[0].count == 2 && runs[1].count == 2, "runs split")
    check(EraserHitTest.strokeHit(spine: spine, path: path, eraserRadius: 1.5), "hit true")
    let far = [CGPoint(x: 500, y: 500), CGPoint(x: 600, y: 600)]
    check(!EraserHitTest.strokeHit(spine: spine, path: far, eraserRadius: 5), "hit false")
    // 半径边缘：距离恰好 = 作用半径 -> 不命中（严格小于）
    let edge = [CGPoint(x: 5, y: 3.5), CGPoint(x: 5, y: 100)] // 到 (5,0) 距离 3.5 = 2+1.5
    let single = [SpinePoint(center: CGPoint(x: 5, y: 0), width: 4)]
    check(!EraserHitTest.strokeHit(spine: single, path: edge, eraserRadius: 1.5), "edge exclusive")
    check(EraserHitTest.eraseRuns(spine: [], path: path, eraserRadius: 1).isEmpty, "empty spine")
    check(EraserHitTest.eraseRuns(spine: spine, path: [CGPoint(x: 5, y: 0)], eraserRadius: 99).count == 1, "short path noop")
}

// ---------- 6. 套索 ----------

do {
    var store = StrokeStore()
    let inside = addLine(&store, x0: 40, x1: 60, y: 50, n: 5)      // 圈内
    let crossing = addLine(&store, x0: -50, x1: 150, y: 50, n: 5)  // 穿过圈边
    let outside = addLine(&store, x0: 200, x1: 300, y: 200, n: 5)  // 圈外
    let loop = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
    let sel = store.selectLoop(loop)
    check(sel == Set([inside.id, crossing.id]), "loop selects inside+crossing")
    check(!sel.contains(outside.id), "loop excludes outside")
    check(store.selectionBounds() != nil, "selection bounds")

    // 退化 loop -> 空选
    check(store.selectLoop([CGPoint(x: 1, y: 1)]).isEmpty, "degenerate loop")

    // 点选取最上层（最后）
    let tap = store.selectTap(at: CGPoint(x: 50, y: 50), radius: 5)
    check(tap == Set([crossing.id]), "tap picks topmost")
    check(store.selectTap(at: CGPoint(x: 500, y: 500), radius: 5).isEmpty, "tap miss")
    check(LassoHitTest.pointInLoop(CGPoint(x: 50, y: 50), loop: loop), "point in loop")
    check(!LassoHitTest.pointInLoop(CGPoint(x: 150, y: 50), loop: loop), "point outside loop")
}

// ---------- 7. 移动 ----------

do {
    var store = StrokeStore()
    let s = addLine(&store, x0: 0, x1: 10, y: 0, n: 5)
    _ = store.selectTap(at: CGPoint(x: 5, y: 0), radius: 5)
    // 预览不改模型
    let preview = store.previewMoveSelection(by: CGSize(width: 10, height: 5))
    check(store.strokes[0].spine[0].center.x == 0, "preview keeps model")
    check(preview.count == 1 && approx(preview[0].bounds.minX, 10 - 2), "preview bounds moved")
    // 提交改模型 + undo
    let sync = store.commitMoveSelection(by: CGSize(width: 10, height: 5))
    check(sync.inPlace.count == 1 && store.strokes[0].spine[0].center.x == 10, "commit moves model")
    check(store.strokes[0].points[0].position.x == 10, "raw points moved")
    _ = store.undo()
    check(store.strokes[0].spine[0].center.x == 0, "move-undo restores")
    _ = store.redo()
    check(store.strokes[0].spine[0].center.x == 10, "move-redo re-applies")
    // 零位移空操作
    check(store.commitMoveSelection(by: .zero).isEmpty, "zero move noop")
    _ = s
}

// ---------- 8. 删除选中 + 选择清理 ----------

do {
    var store = StrokeStore()
    let a = addLine(&store, x0: 0, x1: 10, y: 0, n: 5)
    let b = addLine(&store, x0: 0, x1: 10, y: 100, n: 5)
    _ = store.selectTap(at: CGPoint(x: 5, y: 0), radius: 5)
    let del = store.deleteSelection()
    check(del.removedIDs == [a.id] && store.strokes.map(\.id) == [b.id], "delete selection")
    check(!store.hasSelection, "selection cleared after delete")
    _ = store.undo()
    check(store.strokes.count == 2, "delete-undo restores")

    // 橡皮删掉选中笔画 -> 选择自动清理
    _ = store.selectTap(at: CGPoint(x: 5, y: 0), radius: 5)
    _ = store.eraseStrokes(path: [CGPoint(x: 5, y: -50), CGPoint(x: 5, y: 50)], radius: 5)
    check(!store.hasSelection, "selection sanitized after erase")
}

// ---------- 9. LOD ----------

do {
    check(approx(StrokeGeometry.lodTolerance(forScale: 1), 0.35), "lod tol @1x")
    check(approx(StrokeGeometry.lodTolerance(forScale: 32), 0.35 / 32), "lod tol @32x")
    check(approx(StrokeGeometry.lodTolerance(forScale: 0.02), 4), "lod tol clamped max")
    check(approx(StrokeGeometry.lodTolerance(forScale: 1000), 0.002), "lod tol clamped min")
    check(StrokeGeometry.lodNeedsUpdate(from: 1, to: 2), "lod up triggered")
    check(StrokeGeometry.lodNeedsUpdate(from: 2, to: 1), "lod down triggered")
    check(!StrokeGeometry.lodNeedsUpdate(from: 1, to: 1.2), "lod small change ignored")
    check(!StrokeGeometry.lodNeedsUpdate(from: 0, to: 2), "lod invalid scale")

    // retessellate：曲线在细容差下顶点更多
    var store = StrokeStore()
    let curvePts = (0...20).map { i -> StrokePoint in
        let t = Double(i) / 20.0 * .pi
        return StrokePoint(position: CGPoint(x: Double(i) * 5, y: sin(t) * 30), pressure: 1, timestamp: 0)
    }
    let (cs, _) = store.addSynthetic(points: curvePts, style: testStyle, tolerance: 4)!
    let coarseCount = store.renderData()[0].mesh.vertices.count
    let sync = store.retessellate(ids: [cs.id], tolerance: 0.01)
    let fineCount = store.renderData()[0].mesh.vertices.count
    check(sync.upserts.count == 1 && fineCount > coarseCount, "relod refines \(coarseCount)->\(fineCount)")
}

// ---------- 10. 持久化 ----------

do {
    var store = StrokeStore()
    _ = addLine(&store, x0: 0, x1: 10, y: 0, n: 11)
    _ = addLine(&store, x0: 0, x1: 5, y: 50, n: 6)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("drawing_test_\(UUID().uuidString).json")
    try DrawingStore.save(store.strokes, to: url)
    let loaded = try DrawingStore.load(from: url)
    check(loaded == store.strokes, "persistence roundtrip")
    check(loaded[0].spine.count == 11, "spine persisted")
    try? FileManager.default.removeItem(at: url)

    // 缺失文件抛错
    var threwMissing = false
    do { _ = try DrawingStore.load(from: url) } catch { threwMissing = true }
    check(threwMissing, "missing file throws")

    // 版本不匹配抛错
    let badURL = FileManager.default.temporaryDirectory.appendingPathComponent("drawing_bad_\(UUID().uuidString).json")
    try "{\"version\":99,\"strokes\":[]}".write(to: badURL, atomically: true, encoding: .utf8)
    var threwVersion = false
    do { _ = try DrawingStore.load(from: badURL) } catch let e as DrawingStore.StoreError {
        threwVersion = (e == .unsupportedVersion(99))
    } catch {}
    check(threwVersion, "version mismatch throws")
    try? FileManager.default.removeItem(at: badURL)
}

// ---------- 11. 压力反推 / mesh 平移 / 全量替换 ----------

do {
    let style = StrokeStyle(color: .black, baseWidth: 10, minWidthScale: 0.2, pressureExponent: 0.6)
    for p in [0.0, 0.1, 0.5, 0.9, 1.0] as [CGFloat] {
        let back = style.pressure(forWidth: style.width(forPressure: p))
        check(approx(back, p, eps: 1e-4), "pressure roundtrip p=\(p) got=\(back)")
    }

    var store = StrokeStore()
    _ = addLine(&store, x0: 0, x1: 10, y: 0, n: 5)
    let mesh = store.renderData()[0].mesh
    let moved = StrokeGeometry.translated(mesh, by: CGSize(width: 3, height: -2))
    check(moved.indices == mesh.indices, "translate keeps indices")
    check(approx(CGFloat(moved.vertices[0].x), CGFloat(mesh.vertices[0].x) + 3), "translate offsets verts")

    // replaceAll：旧数据（无 spine）回填 + 历史清空
    let legacy = Stroke(points: linePoints(x0: 0, x1: 10, y: 0, n: 11), style: testStyle, bounds: CGRect(x: 0, y: 0, width: 10, height: 1))
    check(legacy.spine.isEmpty, "legacy has no spine")
    store.replaceAll(with: [legacy], tolerance: 0.35)
    check(!store.renderData()[0].mesh.isEmpty, "replaceAll builds meshes")
    check(!store.canUndo && !store.canRedo, "replaceAll clears history")
}

// ---------- 12. batch undo（一次擦除多笔，一步撤销） ----------

do {
    var store = StrokeStore()
    _ = addLine(&store, x0: 0, x1: 10, y: 0, n: 11)
    _ = addLine(&store, x0: 0, x1: 10, y: 10, n: 11)
    // 竖线橡皮同时擦中两笔中段
    let sync = store.erasePartial(path: [CGPoint(x: 5, y: -20), CGPoint(x: 5, y: 30)], radius: 2, tolerance: 0.35)
    check(store.strokes.count == 4, "two strokes fragmented")
    check(sync.upserts.count == 4 && sync.removedIDs.count == 2, "batch sync shape")
    _ = store.undo()
    check(store.strokes.count == 2, "batch undo restores both in one step")
    // batch 只占一步：再 undo 一次才轮到 add 条目（删掉第二笔）
    _ = store.undo()
    check(store.strokes.count == 1, "batch was single entry")
}

// ---------- 13. 文档库 ----------

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("canvaslib_\(UUID().uuidString)")
    var store = StrokeStore()
    let (strokeA, _) = store.addSynthetic(points: linePoints(x0: 0, x1: 10, y: 0, n: 11), style: testStyle, tolerance: 0.35)!
    MainActor.assumeIsolated {
        let lib = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        check(lib.documents.isEmpty, "empty library")
        let a = lib.createDocument()
        check(a.meta.title == "无标题画布", "untitled name")
        let b = lib.createDocument()
        check(b.meta.title == "无标题画布 2", "untitled numbered")
        check(lib.documents.map(\.meta.id) == [b.meta.id, a.meta.id], "newest first")

        lib.updateStrokes(id: a.meta.id, strokes: [strokeA])
        check(lib.documents.first?.meta.id == a.meta.id, "updated moves first")
        check(lib.documents.first?.strokes.count == 1, "strokes cached")

        let lib2 = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        check(lib2.documents.count == 2, "persisted count")
        check(lib2.document(id: a.meta.id)?.strokes == [strokeA], "persisted strokes")

        lib2.rename(id: b.meta.id, title: "  新标题  ")
        check(lib2.document(id: b.meta.id)?.meta.title == "新标题", "rename trims")
        lib2.rename(id: b.meta.id, title: "   ")
        check(lib2.document(id: b.meta.id)?.meta.title == "新标题", "blank rename ignored")

        lib2.delete(id: a.meta.id)
        check(lib2.documents.count == 1, "delete removes")
        let lib3 = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        check(lib3.documents.count == 1, "delete persisted")

        // 坏文件跳过不影响好文件
        try? "garbage{{".write(to: dir.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        let lib4 = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        check(lib4.documents.count == 1, "bad file skipped")
    }
    try? FileManager.default.removeItem(at: dir)
}

do {
    // 首次启动自动建一张
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("canvaslib_\(UUID().uuidString)")
    MainActor.assumeIsolated {
        let lib = CanvasLibrary(directory: dir, legacyURL: nil)
        check(lib.documents.count == 1 && lib.documents[0].meta.title == "我的第一张画布", "auto first doc")
        let lib2 = CanvasLibrary(directory: dir, legacyURL: nil)
        check(lib2.documents.count == 1, "no duplicate on reopen")
    }
    try? FileManager.default.removeItem(at: dir)
}

do {
    // 旧单文件迁移
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("canvaslib_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let legacy = FileManager.default.temporaryDirectory.appendingPathComponent("legacy_\(UUID().uuidString).json")
    var store = StrokeStore()
    let (strokeL, _) = store.addSynthetic(points: linePoints(x0: 0, x1: 5, y: 5, n: 6), style: testStyle, tolerance: 0.35)!
    try DrawingStore.save([strokeL], to: legacy)
    MainActor.assumeIsolated {
        let lib = CanvasLibrary(directory: dir, legacyURL: legacy, autoCreateFirst: false)
        check(lib.documents.count == 1, "migrated one doc")
        check(lib.documents.first?.strokes == [strokeL], "migrated strokes")
        check(!FileManager.default.fileExists(atPath: legacy.path), "legacy removed")
    }
    try? FileManager.default.removeItem(at: dir)

    // 空旧文件：删除不导入
    let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent("canvaslib_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
    let legacy2 = FileManager.default.temporaryDirectory.appendingPathComponent("legacy_\(UUID().uuidString).json")
    try DrawingStore.save([], to: legacy2)
    MainActor.assumeIsolated {
        let lib = CanvasLibrary(directory: dir2, legacyURL: legacy2, autoCreateFirst: false)
        check(lib.documents.isEmpty, "empty legacy not imported")
        check(!FileManager.default.fileExists(atPath: legacy2.path), "empty legacy cleared")
    }
    try? FileManager.default.removeItem(at: dir2)
}

// ---------- 内容外包矩形 ----------

do {
    var store = StrokeStore()
    check(store.contentBounds() == nil, "empty content -> nil")
    _ = addLine(&store, x0: 0, x1: 10, y: 0, n: 5)
    _ = addLine(&store, x0: 20, x1: 30, y: 40, n: 5)
    let b = store.contentBounds()!
    // 笔宽会向外膨胀 bounds，只断言覆盖两笔
    check(b.minX <= 0 && b.maxX >= 30 && b.minY <= 0 && b.maxY >= 40, "content covers strokes")
}

// ---------- 内容节点 Store ----------

do {
    var store = ContentStore()
    let a = ContentNode(kind: .shape(.rectangle), frame: CGRect(x: 0, y: 0, width: 100, height: 50))
    let b = ContentNode(kind: .text, frame: CGRect(x: 200, y: 200, width: 60, height: 20), text: "hi")
    store.add(a)
    store.add(b)
    check(store.nodes.count == 2, "add 2 nodes")
    check(store.undoDepth == 2, "depth 2")

    // 移动 + 撤销恢复
    let sync = store.move(id: a.id, by: CGSize(width: 10, height: 5))
    check(!sync.isEmpty && store.node(id: a.id)?.frame.origin == CGPoint(x: 10, y: 5), "move applies")
    _ = store.undo()
    check(store.node(id: a.id)?.frame.origin == .zero, "undo move restores")
    _ = store.redo()
    check(store.node(id: a.id)?.frame.origin == CGPoint(x: 10, y: 5), "redo move reapplies")

    // 连续输入合并为一步 undo
    store.setText(id: b.id, text: "hi!")
    store.setText(id: b.id, text: "hi!!")
    let depthAfterTyping = store.undoDepth
    _ = store.undo()
    check(store.node(id: b.id)?.text == "hi", "coalesced typing undoes to original")
    _ = store.redo()
    check(store.node(id: b.id)?.text == "hi!!", "redo typing restores latest")
    check(store.undoDepth == depthAfterTyping, "redo restores depth")

    // 删除选中 + 撤销恢复原位
    store.select(id: a.id)
    let removed = store.remove(ids: [a.id])
    check(removed.count == 1 && store.nodes.count == 1, "remove 1")
    check(store.node(id: a.id) == nil, "removed gone")
    _ = store.undo()
    check(store.nodes.count == 2 && store.nodes[0].id == a.id, "undo remove restores order")

    // 空操作不记账
    let d0 = store.undoDepth
    _ = store.move(id: a.id, by: .zero)
    _ = store.remove(ids: [])
    check(store.undoDepth == d0, "no-op moves don't push undo")
}

// ---------- 内容节点 Codable + 老文档兼容 ----------

do {
    let node = ContentNode(
        kind: .note, frame: CGRect(x: 1.5, y: -2.5, width: 200, height: 200),
        text: "便签", fill: RGBA(r: 1, g: 0.96, b: 0.65, a: 1)
    )
    let data = try JSONEncoder().encode(node)
    let back = try JSONDecoder().decode(ContentNode.self, from: data)
    check(back == node, "node codable roundtrip")

    // 老文档 JSON（无 nodes 键）解码 -> 空节点
    let legacyJSON = """
    {"version":1,"meta":{"id":"\(UUID().uuidString)","title":"old","createdAt":0,"updatedAt":0},"strokes":[]}
    """.data(using: .utf8)!
    let legacyDoc = try JSONDecoder().decode(CanvasDocument.self, from: legacyJSON)
    check(legacyDoc.nodes.isEmpty, "legacy doc decodes with empty nodes")

    // 新文档往返
    let meta = CanvasDocumentMeta(id: UUID(), title: "n", createdAt: Date(), updatedAt: Date())
    let doc = CanvasDocument(meta: meta, strokes: [], nodes: [node])
    let docData = try JSONEncoder().encode(doc)
    let docBack = try JSONDecoder().decode(CanvasDocument.self, from: docData)
    check(docBack == doc, "document with nodes roundtrip")
} catch {
    check(false, "node codable threw \(error)")
}

// ---------- PNG 导出 ----------

do {
    var store = StrokeStore()
    _ = addLine(&store, x0: 0, x1: 100, y: 0, n: 11)
    let meta = CanvasDocumentMeta(id: UUID(), title: "export", createdAt: Date(), updatedAt: Date())
    let doc = CanvasDocument(
        meta: meta, strokes: store.strokes,
        nodes: [
            ContentNode(kind: .shape(.ellipse), frame: CGRect(x: 120, y: 0, width: 60, height: 40), fill: .red),
            ContentNode(kind: .text, frame: CGRect(x: 0, y: 50, width: 120, height: 30), text: "hi"),
            ContentNode(kind: .note, frame: CGRect(x: 0, y: 100, width: 80, height: 80), text: "n"),
            ContentNode(kind: .image, frame: CGRect(x: 200, y: 200, width: 50, height: 50), imageFile: "missing.img"),
        ]
    )
    let png = DocumentExporter.pngData(for: doc, options: .init(maxDimension: 512))
    check(png != nil && png!.count > 100, "export png non-empty")
    let sig: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    check(png != nil && png!.prefix(8).elementsEqual(sig), "png signature")
    // 空文档 -> nil（UI 侧据此隐藏导出入口）
    check(DocumentExporter.pngData(for: CanvasDocument(meta: meta)) == nil, "empty export nil")
}

// ---------- 安全保存（.bak 轮转 + 恢复） ----------

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("safesave_\(UUID().uuidString)")
    let id = UUID()
    let meta = CanvasDocumentMeta(id: id, title: "first", createdAt: Date(), updatedAt: Date())
    try DrawingStore.saveDocument(CanvasDocument(meta: meta), to: dir)
    let mainURL = DrawingStore.documentURL(id: id, in: dir)
    let bakURL = DrawingStore.backupURL(id: id, in: dir)
    check(!FileManager.default.fileExists(atPath: bakURL.path), "no backup on first save")
    // 覆盖保存 -> 旧版本进 .bak
    var meta2 = meta
    meta2.title = "second"
    try DrawingStore.saveDocument(CanvasDocument(meta: meta2), to: dir)
    check(FileManager.default.fileExists(atPath: bakURL.path), "backup created on overwrite")
    // 损坏主文件 -> 从 .bak 恢复旧标题，且 .bak 不被当成独立文档
    try "garbage{{{".write(to: mainURL, atomically: true, encoding: .utf8)
    let docs = DrawingStore.loadAllDocuments(from: dir)
    check(docs.count == 1 && docs[0].meta.title == "first", "backup recovery, got \(docs.map(\.meta.title))")
    // 删除连 .bak 一起清
    DrawingStore.deleteDocument(id: id, in: dir)
    check(!FileManager.default.fileExists(atPath: bakURL.path), "delete removes backup")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "safesave threw \(error)")
}

// ---------- 性能缩放（P2-11：跨机器稳健的比例断言） ----------

do {
    // 提交 500 笔 vs 2000 笔：线性 4x、二次 16x；< 12x 证明亚二次
    func timeCommit(_ n: Int) -> Double {
        var s = StrokeStore()
        let t0 = Date()
        for i in 0..<n {
            _ = addLine(&s, x0: CGFloat(i), x1: CGFloat(i) + 10, y: 0, n: 11)
        }
        return Date().timeIntervalSince(t0)
    }
    let t500 = timeCommit(500)
    let t2000 = timeCommit(2000)
    let ratio = t2000 / max(t500, 0.001)
    print("[perf] commit 500=\(Int(t500 * 1000))ms 2000=\(Int(t2000 * 1000))ms ratio=\(String(format: "%.1f", ratio))")
    check(ratio < 12, "commit scales sub-quadratically (ratio \(ratio))")

    // 全量重 tessellate 同样不断言绝对时间，只断言比例
    var s = StrokeStore()
    for i in 0..<2000 {
        _ = addLine(&s, x0: CGFloat(i), x1: CGFloat(i) + 10, y: 0, n: 11)
    }
    let ids = s.strokes.map(\.id)
    let r0 = Date()
    _ = s.retessellate(ids: Array(ids.prefix(500)), tolerance: 0.2)
    let r500 = Date().timeIntervalSince(r0)
    let r1 = Date()
    _ = s.retessellate(ids: ids, tolerance: 0.2)
    let r2000 = Date().timeIntervalSince(r1)
    let rratio = r2000 / max(r500, 0.001)
    print("[perf] retessellate 500=\(Int(r500 * 1000))ms 2000=\(Int(r2000 * 1000))ms ratio=\(String(format: "%.1f", rratio))")
    check(rratio < 12, "retessellate scales sub-quadratically (ratio \(rratio))")

    // 节点批量：2000 加/删/撤销必须秒级完成（宽上限，只防离谱退化）
    var c = ContentStore()
    let c0 = Date()
    var ids2: [UUID] = []
    for i in 0..<2000 {
        let n = ContentNode(kind: .shape(.rectangle), frame: CGRect(x: i, y: 0, width: 10, height: 10))
        ids2.append(n.id)
        c.add(n)
    }
    _ = c.remove(ids: Set(ids2))
    _ = c.undo()
    let cMs = Date().timeIntervalSince(c0) * 1000
    print("[perf] content 2000 add/remove/undo=\(Int(cMs))ms")
    check(c.nodes.count == 2000 && cMs < 10_000, "content bulk ops sane")
}

if failures == 0 { print("ALL EDITING TESTS PASSED") }
else { print("\(failures) FAILURES") }
exit(failures == 0 ? 0 : 1)
