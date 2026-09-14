// SelectionOverlayView.swift
// 套索选择框（屏幕空间虚线框）：world 矩形 + viewport 直驱，不经 SwiftUI。

import UIKit

final class SelectionOverlayView: UIView {

    /// 橡皮光标（世界圆）
    struct EraserCursor: Equatable {
        var center: CGPoint
        var radius: CGFloat
    }

    /// 套索首尾点（世界坐标）
    struct LassoEnds: Equatable {
        var start: CGPoint
        var current: CGPoint
    }

    /// 选中范围（世界坐标），nil = 无选择
    var worldRect: CGRect? {
        didSet {
            guard worldRect != oldValue else { return }
            invalidate()
        }
    }

    /// 橡皮光标（世界圆），nil = 不显示。
    /// 相等守卫不是可有可无的：画笔每个输入事件都会把它和 lassoEnds 置 nil
    /// （clearDragHints），没有守卫就等于每帧把一个全屏（12.9" 下 22MB）
    /// 非透明底的 CoreGraphics backing store 作废重画一遍，而 draw(_:) 其实什么都没画。
    var eraserCursor: EraserCursor? {
        didSet {
            guard eraserCursor != oldValue else { return }
            invalidate()
        }
    }

    /// 套索首尾点（世界坐标）：两点屏幕距离近时画闭合提示虚线
    var lassoEnds: LassoEnds? {
        didSet {
            guard lassoEnds != oldValue else { return }
            invalidate()
        }
    }

    /// 当前视口（UIKit 直驱）
    var viewport: Viewport = .zero {
        didSet {
            guard viewport != oldValue, !isHidden else { return }
            setNeedsDisplay()
        }
    }

    /// 三个内容源都空时整层隐藏：隐藏图层不分配 backing store，也不参与合成。
    /// 画笔期间（最常见的情形）这一层因此完全从渲染树里消失。
    private func invalidate() {
        let empty = worldRect == nil && eraserCursor == nil && lassoEnds == nil
        if isHidden != empty { isHidden = empty }
        if !empty { setNeedsDisplay() }
    }

    var accentColor: UIColor = .systemBlue

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
        isHidden = true   // 无选择/无提示时不存在于渲染树
    }

    override func draw(_ rect: CGRect) {
        guard viewport.size.width > 0, viewport.size.height > 0,
              let ctx = UIGraphicsGetCurrentContext()
        else { return }
        drawSelectionBox(ctx)
        drawEraserCursor(ctx)
        drawLassoHint(ctx)
    }

    private func drawSelectionBox(_ ctx: CGContext) {
        guard let world = worldRect, !world.isNull else { return }
        let screen = viewport.worldToScreen(world)
        guard screen.width.isFinite, screen.height.isFinite,
              screen.width > 0, screen.height > 0
        else { return }
        let path = UIBezierPath(roundedRect: screen, cornerRadius: 8)

        // 淡填充
        ctx.setFillColor(accentColor.withAlphaComponent(0.08).cgColor)
        ctx.addPath(path.cgPath)
        ctx.fillPath()

        // 虚线边框
        ctx.setStrokeColor(accentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.addPath(path.cgPath)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    /// 橡皮覆盖圈：跟着指尖走，直径即橡皮直径
    private func drawEraserCursor(_ ctx: CGContext) {
        guard let cursor = eraserCursor, cursor.radius > 0 else { return }
        let c = viewport.worldToScreen(cursor.center)
        let r = cursor.radius * viewport.scale
        guard r.isFinite, r > 1 else { return }
        let path = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.25).cgColor)
        ctx.addPath(path.cgPath)
        ctx.fillPath()
        ctx.setStrokeColor(UIColor.systemGray.cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(path.cgPath)
        ctx.strokePath()
    }

    /// 套索提示：起点圆点 + 近距离闭合虚线
    private func drawLassoHint(_ ctx: CGContext) {
        guard let ends = lassoEnds else { return }
        let s = viewport.worldToScreen(ends.start)
        let dot = UIBezierPath(ovalIn: CGRect(x: s.x - 3, y: s.y - 3, width: 6, height: 6))
        ctx.setFillColor(accentColor.cgColor)
        ctx.addPath(dot.cgPath)
        ctx.fillPath()
        let e = viewport.worldToScreen(ends.current)
        guard hypot(e.x - s.x, e.y - s.y) < 28 else { return }
        ctx.setStrokeColor(accentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.move(to: CGPoint(x: e.x, y: e.y))
        ctx.addLine(to: CGPoint(x: s.x, y: s.y))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }
}
