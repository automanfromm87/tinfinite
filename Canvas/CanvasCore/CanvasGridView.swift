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

    /// 深底时的线色（黑纸用；浅底走上面的默认色）
    var darkMinorLineColor: UIColor = UIColor(white: 1, alpha: 0.10)
    var darkMajorLineColor: UIColor = UIColor(white: 1, alpha: 0.20)

    /// 网格样式（线 / 点阵；off 时上层直接 hidden，本视图不处理）
    var style: GridStyle = .lines {
        didSet {
            guard style != oldValue else { return }
            setNeedsDisplay()
        }
    }

    /// 是否深底（黑纸/深色模式，线色翻转保证可见）
    var darkBackground: Bool = false {
        didSet {
            guard darkBackground != oldValue else { return }
            setNeedsDisplay()
        }
    }

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

    /// 纸张底色：本视图不透明时自己铺底（省掉一层全屏透明合成）
    var paperColor: UIColor = .systemBackground {
        didSet {
            guard paperColor != oldValue else { return }
            backgroundColor = paperColor
            setNeedsDisplay()
        }
    }

    private func commonInit() {
        // 不透明层：CoreGraphics 不必把 22MB 背板清成透明，渲染服务器也能
        // 直接跳过它下面的所有内容。网格自己铺纸张底色来维持视觉不变。
        isOpaque = true
        backgroundColor = paperColor
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let vp = viewport
        // 不透明层必须自己填满，否则会露出上一帧的残留
        ctx.setFillColor(paperColor.cgColor)
        ctx.fill(bounds)
        guard vp.size.width > 0, vp.size.height > 0, vp.scale > 0 else { return }

        let visible = vp.visibleWorldRect
        guard visible.width.isFinite, visible.height.isFinite else { return }

        // 自适应格距：从 minScreenSpacing/scale 出发，向上取整到 1-2-5 序列
        let rawStep = minScreenSpacing / vp.scale
        let step = niceStep(rawStep)
        let majorStep = step * CGFloat(majorEvery)

        let minor = darkBackground ? darkMinorLineColor : minorLineColor
        let major = darkBackground ? darkMajorLineColor : majorLineColor

        if style == .dots {
            // 点阵纸：只在格点画圆点（小点=次线格点，大点=主线格点）
            drawDots(
                ctx: ctx, viewport: vp, visible: visible, step: step,
                minorColor: minor, majorColor: major
            )
        } else {
            ctx.setLineWidth(1.0 / contentScaleFactor)
            // 格线坐标已经 snap 到物理像素（见 snap(_:)），抗锯齿只会把
            // 一条 1px 硬线摊成两行半透明像素：既更糊又贵。轴线之后单独开回来。
            ctx.setShouldAntialias(false)

            // 只遍历可见范围内的格线
            drawLines(
                ctx: ctx, viewport: vp, visible: visible, step: step,
                color: minor, skipMultipleOf: majorEvery
            )
            drawLines(
                ctx: ctx, viewport: vp, visible: visible, step: majorStep,
                color: major, skipMultipleOf: 0
            )
            ctx.setShouldAntialias(true)
        }
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

    /// 点阵：可见格点画圆点（主线格点更大；与 drawLines 同一遍历预算）
    private func drawDots(
        ctx: CGContext,
        viewport vp: Viewport,
        visible: CGRect,
        step: CGFloat,
        minorColor: UIColor,
        majorColor: UIColor
    ) {
        guard step > 0, step.isFinite else { return }
        var kMin = Int(floor(visible.minX / step))
        var kMax = Int(ceil(visible.maxX / step))
        var jMin = Int(floor(visible.minY / step))
        var jMax = Int(ceil(visible.maxY / step))
        // 点数是线数的平方级：预算收紧到 400x400（屏外本来也画不下）
        if kMax - kMin > 400 {
            let mid = (kMin + kMax) / 2
            kMin = mid - 200
            kMax = mid + 200
        }
        if jMax - jMin > 400 {
            let mid = (jMin + jMax) / 2
            jMin = mid - 200
            jMax = mid + 200
        }
        let minorR: CGFloat = 1.1
        let majorR: CGFloat = 1.8
        ctx.setFillColor(minorColor.cgColor)
        ctx.beginPath()
        for k in kMin...kMax {
            for j in jMin...jMax {
                if k % majorEvery == 0, j % majorEvery == 0 { continue }
                let p = vp.worldToScreen(CGPoint(x: CGFloat(k) * step, y: CGFloat(j) * step))
                ctx.addEllipse(in: CGRect(x: p.x - minorR, y: p.y - minorR, width: minorR * 2, height: minorR * 2))
            }
        }
        ctx.fillPath()
        ctx.setFillColor(majorColor.cgColor)
        ctx.beginPath()
        for k in stride(from: kMin - kMin % majorEvery, through: kMax, by: majorEvery) {
            for j in stride(from: jMin - jMin % majorEvery, through: jMax, by: majorEvery) {
                let p = vp.worldToScreen(CGPoint(x: CGFloat(k) * step, y: CGFloat(j) * step))
                ctx.addEllipse(in: CGRect(x: p.x - majorR, y: p.y - majorR, width: majorR * 2, height: majorR * 2))
            }
        }
        ctx.fillPath()
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
