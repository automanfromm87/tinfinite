// CanvasSelfTest.swift
// DEBUG 自检：用 -CanvasSelfTest 启动参数触发。备份用户笔画 -> 清空 -> 种子圆环 ->
// 选择/删除/撤销/LOD -> 恢复备份。结果进 unified log + 停在 8x 缩放供截图。
// Release 无此代码（#if DEBUG），生产零影响。

#if DEBUG
import os
import SwiftUI

/// 自检共享日志（DEBUG）
enum SelfTestLog {
    static let log = Logger(subsystem: "com.tinfinite.canvas", category: "SelfTest")
}

enum CanvasSelfTest {
    private static let log = SelfTestLog.log

    static func run(model: InfiniteCanvasModel, drawing: DrawingSettings) {
        log.log("args=\(CommandLine.arguments)")
        guard let controller = drawing.controller else {
            log.error("FAIL: no controller")
            return
        }
        // 备份 + 确定性起点（不污染用户数据）
        let backup = controller.snapshotStrokes()
        controller.restoreStrokes([])
        controller.addStroke(points: ringPoints(), style: .pen(color: .black, width: 10))
        log.log("initial strokes=\(controller.strokeCount) (expect 1)")

        // 1. 圈选圆环（世界 -150..150，应选中 1 笔）
        controller.selectLoopForTest(loop: [
            CGPoint(x: -150, y: -150), CGPoint(x: 150, y: -150),
            CGPoint(x: 150, y: 150), CGPoint(x: -150, y: 150),
        ])
        log.log("selected=\(controller.selectedCount) (expect 1)")

        // 2. 删除选中 -> 0 笔；撤销 -> 1 笔（exercises removeMeshes/upsertMesh）
        controller.deleteSelection()
        let afterDelete = controller.strokeCount
        controller.undo()
        log.log("afterDelete=\(afterDelete) (expect 0) afterUndo=\(controller.strokeCount) (expect 1)")

        // 2b. 节点：加形状+文本 -> 删选中 -> 3 次 undo 清空（账本平衡，不污染用户数据）
        controller.addShape(.rectangle)
        controller.addText()
        log.log("nodes=\(controller.nodeCount) (expect 2) views=\(controller.nodeViewsCountForTest) (expect 2) nodeSel=\(controller.hasNodeSelection) (expect true)")
        controller.deleteSelection()
        log.log("afterNodeDelete=\(controller.nodeCount) (expect 1)")
        controller.undo()
        controller.undo()
        controller.undo()
        log.log("afterNodeUndo=\(controller.nodeCount) (expect 0) views=\(controller.nodeViewsCountForTest) (expect 0)")

        // 3. LOD：缩放到 8x，静止后触发重 tessellate（exercises upsertMesh 替换路径）
        model.setCamera(Camera(center: .zero, scale: 8), animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            log.log("camera scale=\(controller.canvasScaleForTest) (expect 8)")
            controller.restoreStrokes(backup)
            log.log("restored=\(controller.strokeCount) (expect \(backup.count))")
            log.log("DONE")
        }
    }

    private static func ringPoints(center: CGPoint = .zero, radius: CGFloat = 130) -> [StrokePoint] {
        (0...72).map { i in
            let a = Double(i) / 72.0 * 2 * .pi
            return StrokePoint(
                position: CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a)),
                pressure: 0.7,
                timestamp: Double(i) / 240.0
            )
        }
    }

    // MARK: - 压力测试（-CanvasStressTest）

    /// 播种 2000 笔 + 200 节点（spread ±5000 世界单位），测提交耗时、
    /// 缓冲占用与屏外裁剪；留 8 秒给截图，然后恢复用户数据。
    static func runStress(model: InfiniteCanvasModel, drawing: DrawingSettings) {
        guard let controller = drawing.controller else {
            log.error("FAIL: no controller")
            return
        }
        let backupStrokes = controller.snapshotStrokes()
        let backupNodes = controller.nodes
        controller.restoreStrokes([])
        controller.restoreNodes([])
        model.setCamera(Camera(center: .zero, scale: 1), animated: false)

        // 1. 2000 笔（45 列网格，220 间距，覆盖约 ±5000）
        let strokeCount = 2000
        let t0 = Date()
        for i in 0..<strokeCount {
            let center = CGPoint(
                x: CGFloat(i % 45) * 220 - 4840,
                y: CGFloat((i / 45) % 45) * 220 - 4840
            )
            controller.addStroke(
                points: ringPoints(center: center, radius: 60),
                style: .pen(color: .black, width: 8)
            )
        }
        let strokeMs = Date().timeIntervalSince(t0) * 1000

        // 2. 200 节点（同网格抽稀）
        let nodeCount = 200
        let t1 = Date()
        for j in 0..<nodeCount {
            let kind: ContentNodeKind = j % 2 == 0 ? .shape(.rectangle) : .shape(.ellipse)
            controller.seedNodeForTest(
                kind: kind,
                frame: CGRect(
                    x: CGFloat(j % 20) * 480 - 4560,
                    y: CGFloat((j / 20) % 10) * 480 - 2160,
                    width: 160, height: 120
                )
            )
        }
        let nodeMs = Date().timeIntervalSince(t1) * 1000

        // 3. 静止结算（LOD + 节点裁剪），读统计
        controller.viewportSettled(model.viewport)
        let stats = controller.bufferStatsForTest
        log.log("stress strokes=\(controller.strokeCount) (expect \(strokeCount)) in \(Int(strokeMs))ms")
        log.log("stress nodes=\(controller.nodeCount) (expect \(nodeCount)) in \(Int(nodeMs))ms")
        log.log("stress buffers meshes=\(stats.meshes) verts=\(stats.vertices) indices=\(stats.indices)")
        log.log("stress culledNodes=\(controller.culledNodeCountForTest) (expect > 150)")

        // 4. 留 8 秒截图，然后恢复
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            controller.restoreStrokes(backupStrokes)
            controller.restoreNodes(backupNodes)
            log.log("stress restored strokes=\(controller.strokeCount) nodes=\(controller.nodeCount)")
            log.log("DONE")
        }
    }
}
#endif
