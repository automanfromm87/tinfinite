// MinimapView.swift
// 左下角导览图：笔画/节点分布 + 当前视口框，点击跳转。读 Model/refs 实时值，
// 相机（节流 20Hz）与笔画变化都会触发重算；内容超 600 笔时抽样绘制。

import SwiftUI

struct MinimapView: View {
    @ObservedObject var model: InfiniteCanvasModel
    // 订阅笔画变化以刷新（读 strokeCount 触发依赖跟踪）
    @ObservedObject var drawing: DrawingSettings
    var refs: CanvasRefs
    var size = CGSize(width: 170, height: 130)

    var body: some View {
        let _ = drawing.strokeCount
        Canvas { ctx, sz in
            draw(in: ctx, size: sz)
        }
        .frame(width: size.width, height: size.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.15), lineWidth: 1))
        .onTapGesture(coordinateSpace: .local) { jump(to: $0) }
        .accessibilityLabel("导览图")
    }

    private func snapshot() -> (strokes: [CGRect], items: [CGRect]) {
        var strokes = refs.controller?.strokeBounds() ?? []
        // 超量抽样：导览只示意分布
        if strokes.count > 600 {
            let step = (strokes.count + 599) / 600
            strokes = stride(from: 0, to: strokes.count, by: step).map { strokes[$0] }
        }
        return (strokes, refs.canvas?.itemWorldRects() ?? [])
    }

    private func mapping(for strokes: [CGRect], items: [CGRect], size: CGSize) -> CGAffineTransform? {
        let content = MinimapMath.contentUnion(strokes: strokes, items: items)
            ?? CGRect(x: -800, y: -800, width: 1600, height: 1600)
        return MinimapMath.transform(content: content, minimapSize: size, padding: 8)
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let snap = snapshot()
        guard let t = mapping(for: snap.strokes, items: snap.items, size: size) else { return }
        for r in snap.strokes {
            ctx.fill(Path(r.applying(t)), with: .color(.blue.opacity(0.45)))
        }
        for r in snap.items {
            ctx.fill(Path(r.applying(t)), with: .color(.green.opacity(0.5)))
        }
        let vp = Path(model.viewport.visibleWorldRect.applying(t))
        ctx.stroke(vp, with: .color(.accentColor), lineWidth: 1.5)
    }

    private func jump(to point: CGPoint) {
        let snap = snapshot()
        guard let t = mapping(for: snap.strokes, items: snap.items, size: size) else { return }
        let inv = t.inverted()
        guard inv.a.isFinite, inv.a != 0 else { return }
        let world = point.applying(inv)
        guard world.x.isFinite, world.y.isFinite else { return }
        model.center(on: world, animated: true)
    }
}
