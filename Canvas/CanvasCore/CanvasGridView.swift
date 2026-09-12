// CanvasGridView.swift
// 无限网格背景（屏幕空间绘制）：只画落在可见世界矩形内的格线，
// 格距随缩放自适应（1-2-5 序列），保证任意缩放下线条数量恒定、屏幕间距舒适。

import UIKit

/// 无限画布的网格背景。放在画布视图之下（屏幕空间），每帧最多重绘一次。
final class CanvasGridView: UIView {

    /// 当前视口，由画布回调驱动
    var viewport: Viewport = .zero {
        didSet {
            guard viewport != oldValue else { return }
            setNeedsDisplay()
        }
    }

    var minorLineColor: UIColor = .tertiarySystemFill
    var majorLineColor: UIColor = .secondarySystemFill
    var axisColor: UIColor = .systemBlue.withAlphaComponent(0.5)

    /// 每 N 格画一条主线
    var majorEvery: Int = 5

    /// 屏幕上最小格距（点）。小于此值就放大格距，保证线数恒定。
    var minScreenSpacing: CGFloat = 28

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let vp = viewport
        guard vp.size.width > 0, vp.size.height > 0, vp.scale > 0 else { return }

        let visible = vp.visibleWorldRect
        guard visible.width.isFinite, visible.height.isFinite else { return }

        // 自适应格距：从 minScreenSpacing/scale 出发，向上取整到 1-2-5 序列
        let rawStep = minScreenSpacing / vp.scale
        let step = niceStep(rawStep)
        let majorStep = step * CGFloat(majorEvery)

        ctx.setLineWidth(1.0 / contentScaleFactor)

        // 只遍历可见范围内的格线
        drawLines(
            ctx: ctx, viewport: vp, visible: visible, step: step,
            color: minorLineColor, skipMultipleOf: majorEvery
        )
        drawLines(
            ctx: ctx, viewport: vp, visible: visible, step: majorStep,
            color: majorLineColor, skipMultipleOf: 0
        )
        drawAxes(ctx: ctx, viewport: vp, visible: visible)
    }

    private func drawLines(
        ctx: CGContext,
        viewport vp: Viewport,
        visible: CGRect,
        step: CGFloat,
        color: UIColor,
        skipMultipleOf: Int
    ) {
        guard step > 0, step.isFinite else { return }
        ctx.setStrokeColor(color.cgColor)
        ctx.beginPath()

        // 竖线：世界 x = k*step 落在可见区间内的
        var kMin = Int(floor(visible.minX / step))
        var kMax = Int(ceil(visible.maxX / step))
        // 极端缩小时的保护：线数上限封顶
        if kMax - kMin > 2000 {
            let mid = (kMin + kMax) / 2
            kMin = mid - 1000
            kMax = mid + 1000
        }
        for k in kMin...kMax {
            if skipMultipleOf > 0 && k % skipMultipleOf == 0 { continue }
            let sx = snap(vp.worldToScreen(CGPoint(x: CGFloat(k) * step, y: 0)).x)
            ctx.move(to: CGPoint(x: sx, y: bounds.minY))
            ctx.addLine(to: CGPoint(x: sx, y: bounds.maxY))
        }

        var jMin = Int(floor(visible.minY / step))
        var jMax = Int(ceil(visible.maxY / step))
        if jMax - jMin > 2000 {
            let mid = (jMin + jMax) / 2
            jMin = mid - 1000
            jMax = mid + 1000
        }
        for j in jMin...jMax {
            if skipMultipleOf > 0 && j % skipMultipleOf == 0 { continue }
            let sy = snap(vp.worldToScreen(CGPoint(x: 0, y: CGFloat(j) * step)).y)
            ctx.move(to: CGPoint(x: bounds.minX, y: sy))
            ctx.addLine(to: CGPoint(x: bounds.maxX, y: sy))
        }
        ctx.strokePath()
    }

    private func drawAxes(ctx: CGContext, viewport vp: Viewport, visible: CGRect) {
        ctx.setStrokeColor(axisColor.cgColor)
        ctx.setLineWidth(1.5 / contentScaleFactor)
        ctx.beginPath()
        var drew = false
        if visible.minX <= 0, visible.maxX >= 0 {
            let sx = snap(vp.worldToScreen(CGPoint(x: 0, y: 0)).x)
            ctx.move(to: CGPoint(x: sx, y: bounds.minY))
            ctx.addLine(to: CGPoint(x: sx, y: bounds.maxY))
            drew = true
        }
        if visible.minY <= 0, visible.maxY >= 0 {
            let sy = snap(vp.worldToScreen(CGPoint(x: 0, y: 0)).y)
            ctx.move(to: CGPoint(x: bounds.minX, y: sy))
            ctx.addLine(to: CGPoint(x: bounds.maxX, y: sy))
            drew = true
        }
        if drew { ctx.strokePath() }
    }

    /// 对齐到物理像素，避免模糊
    private func snap(_ value: CGFloat) -> CGFloat {
        let s = contentScaleFactor
        return (value * s).rounded() / s
    }

    /// 向上取整到 1-2-5 * 10^n
    private func niceStep(_ raw: CGFloat) -> CGFloat {
        guard raw > 0, raw.isFinite else { return 100 }
        let exponent = floor(log10(raw))
        let base = pow(10, exponent)
        for m in [1.0, 2.0, 5.0, 10.0] as [CGFloat] {
            if m * base >= raw { return m * base }
        }
        return 10 * base
    }
}
