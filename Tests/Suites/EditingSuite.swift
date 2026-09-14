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
    // 笔刷 kind 透传到渲染增量（渲染层级用；独立 store，不污染块内 undo 断言）
    var kstore = StrokeStore()
    _ = kstore.addSynthetic(points: linePoints(x0: 0, x1: 10, y: 0, n: 6), style: testStyle, tolerance: 0.35)!
    let (sHi, syncHi) = kstore.addSynthetic(
        points: linePoints(x0: 0, x1: 10, y: 5, n: 6),
        style: StrokeStyle.highlighter(), tolerance: 0.35)!
    check(sHi.style.kind == .highlighter, "style kind kept")
    check(syncHi.upserts.first?.kind == .highlighter, "sync carries kind")
    check(kstore.renderData().map(\.kind) == [.pen, .highlighter], "renderData carries kinds")

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
        check(lib.document(id: a.meta.id)?.strokes.count == 1, "strokes cached")
        lib.flushSaves() // 存档在后台队列，跨实例读盘前必须落盘

        let lib2 = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        check(lib2.documents.count == 2, "persisted count")
        check(lib2.document(id: a.meta.id)?.strokes == [strokeA], "persisted strokes")

        lib2.rename(id: b.meta.id, title: "  新标题  ")
        check(lib2.document(id: b.meta.id)?.meta.title == "新标题", "rename trims")
        lib2.rename(id: b.meta.id, title: "   ")
        check(lib2.document(id: b.meta.id)?.meta.title == "新标题", "blank rename ignored")

        lib2.delete(id: a.meta.id)
        check(lib2.documents.count == 1, "delete removes")
        lib2.flushSaves()
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
        lib.flushSaves()
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
        check(lib.document(id: lib.documents.first!.meta.id)?.strokes == [strokeL], "migrated strokes")
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

// ---------- 空间网格 ----------

do {
    // 基础：插入/查询/删除/负坐标
    var g = StrokeSpatialGrid()
    let a = UUID(), b = UUID()
    g.insert(id: a, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    g.insert(id: b, bounds: CGRect(x: -500, y: -500, width: 10, height: 10))
    check(g.count == 2, "grid count")
    let hit = g.strokes(near: CGPoint(x: 50, y: 50), radius: 5)
    check(hit == Candidates.some(Set([a])), "point query hits only a")
    let miss = g.strokes(near: CGPoint(x: 495, y: 495), radius: 5)
    check(miss == Candidates.some(Set<UUID>()), "point query miss")
    // 跨格矩形
    let wide = g.strokes(in: CGRect(x: -600, y: -600, width: 800, height: 800))
    check(wide == Candidates.some(Set([a, b])), "wide rect hits both")
    // 移动：旧格消失、新格出现
    g.move(id: a, from: CGRect(x: 0, y: 0, width: 100, height: 100),
           to: CGRect(x: 1000, y: 1000, width: 100, height: 100))
    check(g.strokes(near: CGPoint(x: 50, y: 50), radius: 5) == Candidates.some(Set<UUID>()), "moved away")
    check(g.strokes(near: CGPoint(x: 1050, y: 1050), radius: 5) == Candidates.some(Set([a])), "moved to")
    g.remove(id: a)
    check(g.strokes(near: CGPoint(x: 1050, y: 1050), radius: 5) == Candidates.some(Set<UUID>()), "removed gone")
    check(g.count == 1, "count after remove")
    // move 不在表里的 id：兜底插入，不静默丢失
    let fresh = UUID()
    g.move(id: fresh, from: CGRect(x: 0, y: 0, width: 10, height: 10),
           to: CGRect(x: 2000, y: 2000, width: 10, height: 10))
    check(g.strokes(near: CGPoint(x: 2005, y: 2005), radius: 1) == Candidates.some(Set([fresh])), "move unknown inserts")
    g.remove(id: fresh)
    // 非法 bounds 进 overflow：任何查询都带上
    let bad = UUID()
    g.insert(id: bad, bounds: .null)
    check(g.strokes(near: CGPoint(x: 9000, y: 9000), radius: 1) == Candidates.some(Set([bad])), "null bounds in overflow")
    // 超大笔画进 overflow
    let huge = UUID()
    g.insert(id: huge, bounds: CGRect(x: 0, y: 0, width: 100_000, height: 100_000))
    let far = g.strokes(near: CGPoint(x: 50_000, y: 50_000), radius: 1)
    check(far.contains(huge), "huge stroke always candidate")
    // 超大查询回退 .all
    check(g.strokes(in: CGRect(x: 0, y: 0, width: 10_000_000, height: 10_000_000)) == Candidates.all, "huge query falls back")
    g.removeAll()
    check(g.isEmpty && g.count == 0, "grid cleared")
}

do {
    // P0-1 回归：非法矩形永不 trap（NaN 原点的零尺寸矩形 isNull 为 false，必须显式设防）
    var g = StrokeSpatialGrid()
    let nan = UUID()
    g.insert(id: nan, bounds: CGRect(origin: CGPoint(x: CGFloat.nan, y: 0), size: .zero))
    check(g.count == 1, "nan bounds accepted into overflow")
    check(g.strokes(near: CGPoint(x: 0, y: 0), radius: 1).contains(nan), "nan bounds always candidate")
    // NaN 查询点：不崩，与暴力扫描一致（intersects 非法矩形恒 false → 空集）
    check(g.strokes(near: CGPoint(x: CGFloat.nan, y: CGFloat.nan), radius: 1) == Candidates.some(Set([nan])), "nan query only overflow")
    g.remove(id: nan)
    // 超大有限坐标（1e30 会让 Int(floor(x/256)) trap）
    let big = UUID()
    g.insert(id: big, bounds: CGRect(x: 1e30, y: 0, width: 10, height: 10))
    check(g.strokes(in: CGRect(x: 1e30, y: -100, width: 100, height: 200)).contains(big), "huge coords in overflow")
    g.remove(id: big)
    // 无限矩形与零尺寸矩形
    let inf = UUID()
    g.insert(id: inf, bounds: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10))
    check(g.strokes(near: CGPoint(x: 5, y: 5), radius: 1).contains(inf), "infinite bounds in overflow")
    let zero = UUID()
    g.insert(id: zero, bounds: CGRect(x: 40, y: 40, width: 0, height: 0))
    check(g.strokes(near: CGPoint(x: 40, y: 40), radius: 1) == Candidates.some(Set([inf, zero])), "zero-size indexed")
}

do {
    // Store 级：网格与数组在各种变更后保持同步，查询语义与暴力一致
    var store = StrokeStore()
    let s1 = addLine(&store, x0: 0, x1: 100, y: 0, n: 11)
    let s2 = addLine(&store, x0: 0, x1: 100, y: 500, n: 11)
    // 点选只命中近处笔画（远处 500 外的 s2 不被精确测试也能正确略过）
    check(store.selectTap(at: CGPoint(x: 50, y: 0), radius: 8) == [s1.id], "tap hits s1")
    check(store.selectTap(at: CGPoint(x: 50, y: 500), radius: 8) == [s2.id], "tap hits s2")
    check(store.selectTap(at: CGPoint(x: 50, y: 250), radius: 8).isEmpty, "tap miss")
    // 套索
    let loop = [CGPoint(x: -10, y: -10), CGPoint(x: 110, y: -10), CGPoint(x: 110, y: 10), CGPoint(x: -10, y: 10)]
    check(store.selectLoop(loop) == [s1.id], "loop selects s1 only")
    // 矩形查询（LOD 可见集路径）
    check(store.strokeIDs(in: CGRect(x: -50, y: 450, width: 200, height: 100)) == [s2.id], "strokeIDs rect")
    // 移动后索引跟随
    _ = store.selectTap(at: CGPoint(x: 50, y: 0), radius: 8)
    _ = store.commitMoveSelection(by: CGSize(width: 0, height: 500))
    check(store.selectTap(at: CGPoint(x: 50, y: 0), radius: 8).isEmpty, "moved away from tap")
    // 撤销恢复索引
    _ = store.undo()
    check(store.selectTap(at: CGPoint(x: 50, y: 0), radius: 8) == [s1.id], "undo restores index")
    // 删除/清空同步
    _ = store.selectTap(at: CGPoint(x: 50, y: 0), radius: 8)
    _ = store.deleteSelection()
    check(store.selectTap(at: CGPoint(x: 50, y: 0), radius: 8).isEmpty, "deleted not hittable")
    _ = store.clear()
    check(store.strokeIDs(in: CGRect(x: -10000, y: -10000, width: 20000, height: 20000)).isEmpty, "cleared empty")
}

do {
    // 随机差分：网格加速版 vs 暴力版逐步一致，并守 gridCount == strokes.count。
    // 与 Store 共享 spine 级命中测试（测的是候选集一致性，不是命中算法本身）；
    // 种子固定，可复现。覆盖：整笔擦/局部擦/redo 的索引同步（此前零覆盖）。
    var rng: UInt64 = 0x1234_5678_ABCD_EF01
    func next(_ bound: UInt64) -> UInt64 {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return rng % bound
    }
    func fr(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo + CGFloat(next(10000)) / 10000 * (hi - lo)
    }
    var store = StrokeStore()
    var step = 0
    func syncOK(_ context: String) {
        check(store.gridCountForTest == store.strokes.count, "grid sync @\(context)")
    }
    // 暴力参考实现
    func bruteTap(_ strokes: [Stroke], _ p: CGPoint, _ r: CGFloat) -> Set<UUID> {
        for s in strokes.reversed() {
            if LassoHitTest.tapHit(spine: s.spine, point: p, radius: r) { return [s.id] }
        }
        return []
    }
    func bruteLoop(_ strokes: [Stroke], _ loop: [CGPoint]) -> Set<UUID> {
        Set(strokes.filter { LassoHitTest.strokeIntersectsLoop(spine: $0.spine, loop: loop) }.map(\.id))
    }
    func bruteErase(_ strokes: [Stroke], _ path: [CGPoint], _ r: CGFloat) -> Set<UUID> {
        Set(strokes.filter { EraserHitTest.strokeHit(spine: $0.spine, path: path, eraserRadius: r) }.map(\.id))
    }
    for _ in 0..<300 {
        step += 1
        switch next(store.strokes.isEmpty ? 1 : 10) {
        case 0: // 加笔（随机位置/长度，含跨格长线）
            _ = addLine(&store, x0: fr(-1500, 1500), x1: fr(-1500, 1500) + 300, y: fr(-1500, 1500), n: 8)
        case 1: // 整笔擦
            let p0 = CGPoint(x: fr(-1500, 1500), y: fr(-1500, 1500))
            let path = [p0, CGPoint(x: p0.x + fr(-600, 600), y: p0.y + fr(-600, 600))]
            let expect = bruteErase(store.strokes, path, 12)
            let sync = store.eraseStrokes(path: path, radius: 12)
            check(Set(sync.removedIDs) == expect, "erase ids @\(step)")
            check(!expect.isEmpty || sync.isEmpty, "erase empty sync @\(step)")
        case 2: // 局部擦：未命中笔逐字节不动，命中笔恰好被替换/删除
            let p0 = CGPoint(x: fr(-1500, 1500), y: fr(-1500, 1500))
            let path = [p0, CGPoint(x: p0.x + fr(-600, 600), y: p0.y + fr(-600, 600))]
            let before = store.strokes
            let sync = store.erasePartial(path: path, radius: 12, tolerance: 0.35)
            var expectRuns = 0
            var expectGone = Set<UUID>()
            for s in before {
                let runs = EraserHitTest.eraseRuns(spine: s.spine, path: path, eraserRadius: 12)
                if runs.count == 1 && runs[0].count == s.spine.count {
                    check(store.strokes.contains(s), "partial keeps untouched @\(step)")
                } else {
                    expectGone.insert(s.id)
                    expectRuns += runs.count
                }
            }
            check(Set(sync.removedIDs) == expectGone, "partial removed @\(step)")
            check(sync.upserts.count == expectRuns, "partial frag count @\(step)")
            check(!expectGone.isEmpty || sync.isEmpty, "partial empty sync @\(step)")
        case 3: // 点选
            let p = CGPoint(x: fr(-1500, 1500), y: fr(-1500, 1500))
            let expect = bruteTap(store.strokes, p, 8)
            check(store.selectTap(at: p, radius: 8) == expect, "tap @\(step)")
        case 4: // 套索
            let cx = fr(-1500, 1500), cy = fr(-1500, 1500), w = fr(20, 500), h = fr(20, 500)
            let loop = [CGPoint(x: cx, y: cy), CGPoint(x: cx + w, y: cy),
                        CGPoint(x: cx + w, y: cy + h), CGPoint(x: cx, y: cy + h)]
            let expect = bruteLoop(store.strokes, loop)
            check(store.selectLoop(loop) == expect, "loop @\(step)")
        case 5: // 矩形查询（顺序 = z 序，逐位比）
            let rect = CGRect(x: fr(-1500, 1500), y: fr(-1500, 1500), width: fr(1, 3000), height: fr(1, 3000))
            let expect = store.strokes.filter { $0.bounds.intersects(rect) }.map(\.id)
            check(store.strokeIDs(in: rect) == expect, "strokeIDs @\(step)")
        case 6: // 移动选中：bounds 精确平移
            let before = Dictionary(uniqueKeysWithValues: store.strokes.map { ($0.id, $0.bounds) })
            let delta = CGSize(width: fr(-200, 200), height: fr(-200, 200))
            _ = store.commitMoveSelection(by: delta)
            for s in store.strokes where store.selection.contains(s.id) {
                let exp = before[s.id]!.offsetBy(dx: delta.width, dy: delta.height)
                check(s.bounds.origin.x == exp.origin.x && s.bounds.origin.y == exp.origin.y
                    && s.bounds.size.width == exp.size.width && s.bounds.size.height == exp.size.height,
                    "move bounds @\(step)")
            }
        case 7:
            _ = store.undo()
        case 8:
            _ = store.redo()
        default: // 删除选中
            let ids = store.selection
            _ = store.deleteSelection()
            check(Set(store.strokes.map(\.id)).intersection(ids).isEmpty, "delete gone @\(step)")
        }
        syncOK("step\(step)")
    }
}

do {
    // 压力：2000 笔分散布局，200 次点选必须毫秒级（网格剪枝；暴力则逐笔走 spine）
    var store = StrokeStore()
    for i in 0..<2000 {
        _ = addLine(&store, x0: CGFloat(i) * 50, x1: CGFloat(i) * 50 + 10, y: 0, n: 6)
    }
    let t0 = Date()
    var hits = 0
    for i in stride(from: 0, to: 2000, by: 10) {
        if !store.selectTap(at: CGPoint(x: CGFloat(i) * 50 + 5, y: 0), radius: 8).isEmpty { hits += 1 }
    }
    let ms = Date().timeIntervalSince(t0) * 1000
    print("[perf] grid 200 taps among 2000 strokes=\(Int(ms))ms hits=\(hits)")
    check(hits == 200 && ms < 5000, "grid tap queries fast and exact")
}

// ---------- v2 增量存档 ----------

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v2save_\(UUID().uuidString)")
    var store = StrokeStore()
    let s1 = addLine(&store, x0: 0, x1: 10, y: 0, n: 6)
    let s2 = addLine(&store, x0: 0, x1: 10, y: 20, n: 6)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    MainActor.assumeIsolated {
        let lib = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        let doc = lib.createDocument(title: "v2")
        lib.updateStrokes(id: doc.meta.id, strokes: [s1, s2])
        lib.flushSaves()
        // v2 目录结构落盘
        let docDir = DrawingStore.docDirectory(id: doc.meta.id, in: dir)
        check(FileManager.default.fileExists(atPath: docDir.path), "v2 dir exists")
        check(FileManager.default.fileExists(
            atPath: DrawingStore.strokeURL(docID: doc.meta.id, strokeID: s1.id, in: dir).path), "stroke file 1")
        // 快照未变更笔的文件字节
        let s2URL = DrawingStore.strokeURL(docID: doc.meta.id, strokeID: s2.id, in: dir)
        let s2Before = try? Data(contentsOf: s2URL)
        // 追加一笔：只有新笔 + manifest 落盘，旧笔文件逐字节不动
        let s3 = addLine(&store, x0: 0, x1: 10, y: 40, n: 6)
        lib.updateStrokes(id: doc.meta.id, strokes: [s1, s2, s3])
        lib.flushSaves()
        let s2After = try? Data(contentsOf: s2URL)
        check(s2Before == s2After && s2Before != nil, "untouched stroke file byte-identical")
        // 删除一笔：文件消失，manifest 顺序保持 z 序
        lib.updateStrokes(id: doc.meta.id, strokes: [s1, s3])
        lib.flushSaves()
        check(!FileManager.default.fileExists(atPath: s2URL.path), "removed stroke file deleted")
        let lib2 = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        check(lib2.document(id: doc.meta.id)?.strokes.map(\.id) == [s1.id, s3.id], "v2 reload order + content")
    }
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "v2 save threw \(error)")
}

do {
    // v1 单文件就地迁移到 v2（一次性），坏笔跳过不影响整档
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v2mig_\(UUID().uuidString)")
    var store = StrokeStore()
    let s1 = addLine(&store, x0: 0, x1: 10, y: 0, n: 6)
    let meta = CanvasDocumentMeta(id: UUID(), title: "v1doc", createdAt: Date(), updatedAt: Date())
    try DrawingStore.saveDocument(CanvasDocument(meta: meta, strokes: [s1]), to: dir)
    let v1URL = DrawingStore.documentURL(id: meta.id, in: dir)
    check(FileManager.default.fileExists(atPath: v1URL.path), "v1 file staged")
    var docs = DrawingStore.loadAllDocuments(from: dir)
    check(docs.count == 1 && docs[0].strokes == [s1], "v1 loads")
    check(!FileManager.default.fileExists(atPath: v1URL.path), "v1 file removed after migration")
    check(FileManager.default.fileExists(
        atPath: DrawingStore.manifestURL(docID: meta.id, in: dir).path), "v2 manifest written")
    // 幂等：再次加载结果一致
    docs = DrawingStore.loadAllDocuments(from: dir)
    check(docs.count == 1 && docs[0].strokes == [s1], "v2 reload stable")
    // 删一笔文件：加载跳过，其余正常
    try? FileManager.default.removeItem(
        at: DrawingStore.strokeURL(docID: meta.id, strokeID: s1.id, in: dir))
    docs = DrawingStore.loadAllDocuments(from: dir)
    check(docs.count == 1 && docs[0].strokes.isEmpty, "missing stroke skipped")
    // 坏 manifest 回退 .bak（先复写一次 manifest 以产生备份）
    try DrawingStore.saveManifest(
        meta: docs[0].meta, camera: nil, strokeIDs: [s1.id], docID: meta.id, in: dir)
    let mURL = DrawingStore.manifestURL(docID: meta.id, in: dir)
    check(FileManager.default.fileExists(
        atPath: DrawingStore.backupManifestURL(docID: meta.id, in: dir).path), "manifest backup exists")
    try? "garbage{{".write(to: mURL, atomically: true, encoding: .utf8)
    docs = DrawingStore.loadAllDocuments(from: dir)
    check(docs.count == 1, "manifest backup recovered")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "v2 migration threw \(error)")
}

do {
    // 规模：500 笔 v2 写 + 读计时（只记日志 + 宽上限，防离谱退化）
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v2perf_\(UUID().uuidString)")
    var store = StrokeStore()
    for i in 0..<500 {
        _ = addLine(&store, x0: CGFloat(i), x1: CGFloat(i) + 10, y: 0, n: 11)
    }
    let meta = CanvasDocumentMeta(id: UUID(), title: "perf", createdAt: Date(), updatedAt: Date())
    let t0 = Date()
    try DrawingStore.writeFullV2(doc: CanvasDocument(meta: meta, strokes: store.strokes), in: dir)
    let wMs = Date().timeIntervalSince(t0) * 1000
    let t1 = Date()
    let docs = DrawingStore.loadAllDocuments(from: dir)
    let rMs = Date().timeIntervalSince(t1) * 1000
    print("[perf] v2 500 strokes write=\(Int(wMs))ms read=\(Int(rMs))ms")
    check(docs.count == 1 && docs[0].strokes.count == 500, "v2 bulk roundtrip")
    check(wMs < 30_000 && rMs < 30_000, "v2 bulk sane")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "v2 perf threw \(error)")
}

do {
    // 相机持久化：updateCamera 只重写 manifest，不碰 updatedAt/排序/笔画文件；重载后视角恢复。
    // 用 mtime 钉住断言“文件未被重写”（JSONEncoder key 顺序跨实例不确定，比字节内容是 flaky 断言）。
    func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
    func pinMtime(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("campersist_\(UUID().uuidString)")
    var store = StrokeStore()
    let s1 = addLine(&store, x0: 0, x1: 10, y: 0, n: 6)
    let s1URL: URL = MainActor.assumeIsolated {
        let lib = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: true)
        let doc = lib.createDocument(title: "camdoc")
        lib.updateStrokes(id: doc.meta.id, strokes: [s1])
        lib.flushSaves()
        return DrawingStore.strokeURL(docID: doc.meta.id, strokeID: s1.id, in: dir)
    }
    pinMtime(s1URL)
    let pinnedStroke = mtime(s1URL)
    var beforeUpdated: Date?
    MainActor.assumeIsolated {
        let lib = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        let doc = lib.document(id: lib.documents.first!.meta.id) ?? lib.documents.first!
        beforeUpdated = doc.meta.updatedAt
        let cam = Camera(center: CGPoint(x: 123.5, y: -456.25), scale: 2.5)
        lib.updateCamera(id: doc.meta.id, camera: cam)
        lib.flushSaves()
        let after = lib.document(id: doc.meta.id)!
        check(after.camera == cam, "camera cached in memory")
        check(after.meta.updatedAt == beforeUpdated, "camera save keeps updatedAt")
        check(mtime(s1URL) == pinnedStroke, "camera save never rewrites stroke file")
        // 相同值重复存档：相等短路，连 manifest 都不写
        let mURL = DrawingStore.manifestURL(docID: doc.meta.id, in: dir)
        pinMtime(mURL)
        let pinnedManifest = mtime(mURL)
        lib.updateCamera(id: doc.meta.id, camera: cam)
        lib.flushSaves()
        check(mtime(mURL) == pinnedManifest, "identical camera skips write")
    }
    MainActor.assumeIsolated {
        let lib2 = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        let cam = Camera(center: CGPoint(x: 123.5, y: -456.25), scale: 2.5)
        check(lib2.documents.first?.camera == cam, "camera restored after reload")
        check(lib2.document(id: lib2.documents.first!.meta.id)?.strokes == [s1], "camera save keeps content")
    }
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "camera persist threw \(error)")
}

do {
    // 存档失败路径：只读目录 -> 保存失败（内存态 intact，盘上保持旧态）->
    // 恢复可写 -> 下次存档自动补全（基准未被污染，自愈；nodes 同理，无需脏标记）。
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("savefail_\(UUID().uuidString)")
    var store = StrokeStore()
    let s1 = addLine(&store, x0: 0, x1: 10, y: 0, n: 6)
    let n1 = ContentNode(kind: .shape(.rectangle), frame: CGRect(x: 0, y: 0, width: 100, height: 50))
    var docID = UUID()
    MainActor.assumeIsolated {
        let lib = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: true)
        let doc = lib.createDocument(title: "faildoc")
        docID = doc.meta.id
        lib.updateContent(id: docID, strokes: [s1], nodes: [n1])
        lib.flushSaves()
    }
    let docDir = DrawingStore.docDirectory(id: docID, in: dir)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: docDir.path)
    let s2 = addLine(&store, x0: 0, x1: 10, y: 99, n: 6)
    let n2 = ContentNode(kind: .text, frame: CGRect(x: 0, y: 0, width: 60, height: 20), text: "new")
    MainActor.assumeIsolated {
        let lib = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        lib.updateContent(id: docID, strokes: [s1, s2], nodes: [n1, n2])
        lib.flushSaves() // 写失败（只读），但不抛、不崩
        check(lib.document(id: docID)?.strokes == [s1, s2], "memory intact after save failure")
        check(lib.document(id: docID)?.nodes == [n1, n2], "memory nodes intact after failure")
    }
    MainActor.assumeIsolated {
        // 失败期间盘上仍是旧态（manifest 未被破坏）
        let lib = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        check(lib.document(id: docID)?.strokes == [s1], "disk keeps old strokes during failure")
        check(lib.document(id: docID)?.nodes == [n1], "disk keeps old nodes during failure")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docDir.path)
    MainActor.assumeIsolated {
        // 恢复后：同样内容再存一次，diff 对未污染的基准算出增量，全量自愈
        let lib = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        lib.updateContent(id: docID, strokes: [s1, s2], nodes: [n1, n2])
        lib.flushSaves()
        let lib2 = CanvasLibrary(directory: dir, legacyURL: nil, autoCreateFirst: false)
        check(lib2.document(id: docID)?.strokes == [s1, s2], "strokes healed after failure")
        check(lib2.document(id: docID)?.nodes == [n1, n2], "nodes healed after failure")
    }
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "save failure threw \(error)")
}

do {
    // 崩溃一致性：SavePlan 中断在任意步骤，重载 = 旧态或新态，绝无第三状态；
    // 孤儿文件（崩在 upsert 后）由加载时 GC 清理。
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crashinj_\(UUID().uuidString)")
    var store = StrokeStore()
    let s1 = addLine(&store, x0: 0, x1: 10, y: 0, n: 6)
    let s2 = addLine(&store, x0: 0, x1: 10, y: 20, n: 6)
    let s3 = addLine(&store, x0: 0, x1: 10, y: 40, n: 6)
    var s1mod = s1
    s1mod.style = StrokeStyle(color: .red, baseWidth: 6, minWidthScale: 0, pressureExponent: 1)
    let meta = CanvasDocumentMeta(id: UUID(), title: "crash", createdAt: Date(), updatedAt: Date())
    func reset() throws {
        try? FileManager.default.removeItem(at: DrawingStore.docDirectory(id: meta.id, in: dir))
        try DrawingStore.writeFullV2(doc: CanvasDocument(meta: meta, strokes: [s1, s2]), in: dir)
    }
    // 新态：s1 改、s2 删、s3 增
    var newMeta = meta
    newMeta.updatedAt = Date(timeIntervalSince1970: 2_000_000)
    let plan = CanvasLibrary.SavePlan(
        docID: meta.id, isRetry: false,
        strokes: [s1mod, s3], upsertStrokes: [s1mod, s3], removeStrokeIDs: [s2.id],
        nodes: [], writeNodes: true,
        meta: newMeta, camera: nil, strokeIDs: [s1mod.id, s3.id]
    )
    func reloadedIDs() -> [UUID] {
        DrawingStore.loadAllDocuments(from: dir).first?.strokes.map(\.id) ?? []
    }
    func strokeFile(_ id: UUID) -> String {
        DrawingStore.strokeURL(docID: meta.id, strokeID: id, in: dir).path
    }
    // 中断在 upserts / nodes：manifest 未提交 -> 旧 id 集
    for step in [CanvasLibrary.SaveStep.upserts, .nodes] {
        try reset()
        try CanvasLibrary.runSavePlan(plan, in: dir, through: step)
        check(FileManager.default.fileExists(atPath: strokeFile(s3.id)), "upsert landed (\(step))")
        check(reloadedIDs() == [s1.id, s2.id], "crash before manifest keeps old state (\(step))")
        // 旧 manifest 下 s3 文件是孤儿：加载时已被 GC
        check(!FileManager.default.fileExists(atPath: strokeFile(s3.id)), "orphan stroke GC'd (\(step))")
    }
    // 中断在 manifest：已提交新态，但 removals 未跑 -> s2 文件还在，加载时由 GC 收走
    try reset()
    try CanvasLibrary.runSavePlan(plan, in: dir, through: .manifest)
    check(FileManager.default.fileExists(atPath: strokeFile(s2.id)), "removals run after manifest")
    check(reloadedIDs() == [s1mod.id, s3.id], "crash after manifest keeps new state")
    check(!FileManager.default.fileExists(atPath: strokeFile(s2.id)), "stale file GC'd on load")
    // 完整执行：新态 + s2 文件在加载前就已被 removals 删掉
    try reset()
    try CanvasLibrary.runSavePlan(plan, in: dir)
    check(!FileManager.default.fileExists(atPath: strokeFile(s2.id)), "removals delete after commit")
    check(reloadedIDs() == [s1mod.id, s3.id], "full run commits new state")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "crash injection threw \(error)")
}

do {
    // v1/v2 并存（迁移后删 v1 失败）：v2 为准，只产出一条文档，顺手删掉过期 v1
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coexist_\(UUID().uuidString)")
    var store = StrokeStore()
    let s1 = addLine(&store, x0: 0, x1: 10, y: 0, n: 6)
    let s2 = addLine(&store, x0: 0, x1: 10, y: 20, n: 6)
    let meta = CanvasDocumentMeta(id: UUID(), title: "co", createdAt: Date(), updatedAt: Date())
    try DrawingStore.saveDocument(CanvasDocument(meta: meta, strokes: [s1]), to: dir)
    try DrawingStore.writeFullV2(doc: CanvasDocument(meta: meta, strokes: [s2]), in: dir)
    let docs = DrawingStore.loadAllDocuments(from: dir)
    check(docs.count == 1, "coexist yields single doc")
    check(docs.first?.strokes == [s2], "v2 wins over v1")
    check(!FileManager.default.fileExists(
        atPath: DrawingStore.documentURL(id: meta.id, in: dir).path), "stale v1 removed")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "coexist threw \(error)")
}

do {
    // 版本门：布局版本 / 模型版本不匹配的文档被跳过（不崩、不污染其他文档）；
    // 缺 modelVersion 键的老 manifest 按模型 v1 读（向后兼容）。
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("versions_\(UUID().uuidString)")
    var store = StrokeStore()
    let s1 = addLine(&store, x0: 0, x1: 10, y: 0, n: 6)
    let goodMeta = CanvasDocumentMeta(id: UUID(), title: "good", createdAt: Date(), updatedAt: Date())
    try DrawingStore.writeFullV2(doc: CanvasDocument(meta: goodMeta, strokes: [s1]), in: dir)
    // 布局版本 99
    let badLayout = CanvasDocumentMeta(id: UUID(), title: "badlayout", createdAt: Date(), updatedAt: Date())
    try DrawingStore.writeFullV2(doc: CanvasDocument(meta: badLayout, strokes: [s1]), in: dir)
    let badLayoutURL = DrawingStore.manifestURL(docID: badLayout.id, in: dir)
    var m = try JSONDecoder().decode(DrawingStore.ManifestV2.self, from: Data(contentsOf: badLayoutURL))
    m.version = 99
    try JSONEncoder().encode(m).write(to: badLayoutURL, options: .atomic)
    // 模型版本 99
    let badModel = CanvasDocumentMeta(id: UUID(), title: "badmodel", createdAt: Date(), updatedAt: Date())
    try DrawingStore.writeFullV2(doc: CanvasDocument(meta: badModel, strokes: [s1]), in: dir)
    let badModelURL = DrawingStore.manifestURL(docID: badModel.id, in: dir)
    var m2 = try JSONDecoder().decode(DrawingStore.ManifestV2.self, from: Data(contentsOf: badModelURL))
    m2.modelVersion = 99
    try JSONEncoder().encode(m2).write(to: badModelURL, options: .atomic)
    // 缺 modelVersion 键的老 manifest
    let legacyMeta = CanvasDocumentMeta(id: UUID(), title: "legacy", createdAt: Date(), updatedAt: Date())
    try DrawingStore.writeFullV2(doc: CanvasDocument(meta: legacyMeta, strokes: [s1]), in: dir)
    let legacyURL = DrawingStore.manifestURL(docID: legacyMeta.id, in: dir)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as! [String: Any]
    var stripped = raw
    stripped.removeValue(forKey: "modelVersion")
    try JSONSerialization.data(withJSONObject: stripped).write(to: legacyURL, options: .atomic)
    let docs = DrawingStore.loadAllDocuments(from: dir)
    let titles = Set(docs.map(\.meta.title))
    check(titles == ["good", "legacy"], "version gate keeps good + legacy, skips bad: \(titles)")
    check(docs.first { $0.meta.title == "legacy" }?.strokes == [s1], "legacy manifest loads")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "versions threw \(error)")
}

// ---------- 撤销栈上限（笔画/节点各 100 步，超限丢最旧） ----------

do {
    var store = StrokeStore()
    for i in 0..<(StrokeStore.maxUndoDepth + 5) {
        addLine(&store, x0: 0, x1: 10, y: CGFloat(i), n: 3)
    }
    check(store.undoDepth == StrokeStore.maxUndoDepth, "stroke undo capped at \(StrokeStore.maxUndoDepth)")
    var undos = 0
    while store.undo() != nil { undos += 1 }
    check(undos == StrokeStore.maxUndoDepth, "exactly cap undos available, got \(undos)")
    check(store.strokes.count == 5, "oldest 5 dropped beyond undo, kept \(store.strokes.count)")
}

do {
    var content = ContentStore()
    for i in 0..<(ContentStore.maxUndoDepth + 5) {
        content.add(ContentNode(kind: .shape(.rectangle), frame: CGRect(x: CGFloat(i), y: 0, width: 10, height: 10)))
    }
    check(content.undoDepth == ContentStore.maxUndoDepth, "content undo capped at \(ContentStore.maxUndoDepth)")
    var undos = 0
    while content.undo() != nil { undos += 1 }
    check(undos == ContentStore.maxUndoDepth, "exactly cap content undos, got \(undos)")
    check(content.nodes.count == 5, "oldest 5 content nodes dropped, kept \(content.nodes.count)")
}

// ---------- 撤销水位（跨域账本的记账基元） ----------

// 回归：栈满之后 undoDepth 不再变化，只看深度会漏记每一次变更，
// 于是跨域撤销账本从第 101 笔起把「撤销」派发到错误的域。
do {
    var store = StrokeStore()
    var missedByDepth = 0
    var missedBySeq = 0
    var evictedTotal = 0
    for i in 0..<(StrokeStore.maxUndoDepth + 40) {
        let depthBefore = store.undoDepth
        let markBefore = store.undoMark
        addLine(&store, x0: 0, x1: 10, y: CGFloat(i), n: 3)
        if store.undoDepth == depthBefore { missedByDepth += 1 }
        if store.undoMark.seq == markBefore.seq { missedBySeq += 1 }
        evictedTotal += store.undoMark.discarded - markBefore.discarded
    }
    check(missedByDepth == 40, "depth-based accounting misses \(missedByDepth) mutations after saturation")
    check(missedBySeq == 0, "seq-based accounting never misses a mutation")
    check(evictedTotal == 40, "eviction count reported exactly, got \(evictedTotal)")
    check(store.undoMark.seq == StrokeStore.maxUndoDepth + 40, "seq counts every push")

    // 空操作不得推进序号（否则账本会记一条撤不动的条目）
    let before = store.undoMark
    _ = store.commitMoveSelection(by: CGSize(width: 0, height: 0))
    check(store.undoMark == before, "no-op move does not advance mark")
}

do {
    var content = ContentStore()
    var missedBySeq = 0
    for i in 0..<(ContentStore.maxUndoDepth + 10) {
        let markBefore = content.undoMark
        content.add(ContentNode(kind: .shape(.rectangle), frame: CGRect(x: CGFloat(i), y: 0, width: 10, height: 10)))
        if content.undoMark.seq == markBefore.seq { missedBySeq += 1 }
    }
    check(missedBySeq == 0, "content seq accounting never misses")
    check(content.undoMark.discarded == 10, "content eviction counted, got \(content.undoMark.discarded)")
    // 连续输入合并成一步：序号只能前进一次
    let node = ContentNode(kind: .text, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    content.add(node)
    let typingStart = content.undoMark
    content.setText(id: node.id, text: "a")
    content.setText(id: node.id, text: "ab")
    content.setText(id: node.id, text: "abc")
    check(content.undoMark.seq == typingStart.seq + 1, "merged typing advances mark once")
}

// ---------- 手掌判定 ----------

do {
    check(!PalmRejection.isLikelyPalm(majorRadius: 10, isDirectTouch: true), "finger not palm")
    check(!PalmRejection.isLikelyPalm(majorRadius: 25.9, isDirectTouch: true), "just under threshold")
    check(PalmRejection.isLikelyPalm(majorRadius: 26, isDirectTouch: true), "at threshold is palm")
    check(PalmRejection.isLikelyPalm(majorRadius: 40, isDirectTouch: true), "palm resting")
    check(!PalmRejection.isLikelyPalm(majorRadius: 40, isDirectTouch: false), "pencil/mouse never palm")
    check(!PalmRejection.isLikelyPalm(majorRadius: 0, isDirectTouch: true), "unknown radius not palm")
    check(!PalmRejection.isLikelyPalm(majorRadius: .infinity, isDirectTouch: true), "inf radius not palm")
}

// ---------- 纸张/网格 ----------

do {
    check(PaperTheme.black.isDark && !PaperTheme.white.isDark && !PaperTheme.system.isDark, "paper dark flags")
    check(GridStyle.lines.showsGrid && GridStyle.dots.showsGrid && !GridStyle.off.showsGrid, "grid visibility")
    check(PaperTheme(rawValue: "black") == .black && GridStyle(rawValue: "dots") == .dots, "rawvalue roundtrip")
}

if failures == 0 { print("ALL EDITING TESTS PASSED") }
else { print("\(failures) FAILURES") }
exit(failures == 0 ? 0 : 1)
