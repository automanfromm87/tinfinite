// Camera.swift
// 无限画布核心：相机状态 + 世界/屏幕坐标变换（纯数学，不依赖 UIKit，可单测）

import CoreGraphics

/// 相机：定义“世界坐标系中哪一点落在视图中心，以及放大倍数”。
///
/// 世界坐标系是无限的（CGFloat 范围内任意位置都可放置内容），
/// screen = (world - center) * scale + viewSize / 2
/// nonisolated：纯数学层，任意线程可用（工程默认 MainActor 隔离，这里显式退出）
nonisolated struct Camera: Equatable, Sendable {
    /// 落在视图中心的那个世界坐标点
    var center: CGPoint
    /// 缩放：1 世界单位 = scale 屏幕点
    var scale: CGFloat

    static let `default` = Camera(center: .zero, scale: 1)

    /// 默认缩放范围：0.02x ~ 32x，足够“无限无极缩放”的体感
    static let defaultZoomRange: ClosedRange<CGFloat> = 0.02...32

    init(center: CGPoint = .zero, scale: CGFloat = 1) {
        self.center = center
        self.scale = scale
    }

    // MARK: - 坐标变换

    /// 世界坐标 -> 屏幕坐标
    func worldToScreen(_ world: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(
            x: (world.x - center.x) * scale + viewSize.width * 0.5,
            y: (world.y - center.y) * scale + viewSize.height * 0.5
        )
    }

    /// 屏幕坐标 -> 世界坐标
    func screenToWorld(_ screen: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(
            x: (screen.x - viewSize.width * 0.5) / scale + center.x,
            y: (screen.y - viewSize.height * 0.5) / scale + center.y
        )
    }

    /// 世界矩形 -> 屏幕矩形
    func worldToScreen(_ rect: CGRect, viewSize: CGSize) -> CGRect {
        let origin = worldToScreen(rect.origin, viewSize: viewSize)
        return CGRect(
            x: origin.x, y: origin.y,
            width: rect.width * scale, height: rect.height * scale
        )
    }

    /// 当前可见的世界矩形
    func visibleWorldRect(viewSize: CGSize) -> CGRect {
        guard scale > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let size = CGSize(width: viewSize.width / scale, height: viewSize.height / scale)
        return CGRect(
            x: center.x - size.width * 0.5,
            y: center.y - size.height * 0.5,
            width: size.width, height: size.height
        )
    }

    /// 直接用于内容容器 UIView.transform 的变换。
    /// 要求：容器 bounds.size == viewSize，容器 center == 视图中心。
    /// 子视图按世界坐标布局（frame 原点即世界坐标），经此变换一次 GPU 合成到位。
    func contentTransform(viewSize: CGSize) -> CGAffineTransform {
        CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: scale * (viewSize.width * 0.5 - center.x),
            ty: scale * (viewSize.height * 0.5 - center.y)
        )
    }

    // MARK: - 手势增量

    /// 平移：手指在屏幕上移动 screenDelta，世界反向移动
    func panned(by screenDelta: CGSize) -> Camera {
        var next = self
        next.center.x -= screenDelta.width / scale
        next.center.y -= screenDelta.height / scale
        return next
    }

    /// 以屏幕上 anchor 点为锚点缩放（锚点下的世界点保持不动）
    func zoomed(
        by factor: CGFloat,
        anchoredAtScreen anchor: CGPoint,
        viewSize: CGSize,
        range: ClosedRange<CGFloat> = Camera.defaultZoomRange
    ) -> Camera {
        guard factor > 0, factor.isFinite else { return self }
        let clampedScale = (scale * factor).clamped(to: range)
        let actualFactor = clampedScale / scale
        guard actualFactor != 1 else {
            var next = self
            next.scale = clampedScale
            return next
        }
        // anchorWorld 不动：center' = anchorWorld - (anchor - viewCenter) / newScale
        let anchorWorld = screenToWorld(anchor, viewSize: viewSize)
        var next = self
        next.scale = clampedScale
        next.center = CGPoint(
            x: anchorWorld.x - (anchor.x - viewSize.width * 0.5) / clampedScale,
            y: anchorWorld.y - (anchor.y - viewSize.height * 0.5) / clampedScale
        )
        return next
    }

    /// 以视图中心为锚点缩放
    func zoomed(
        by factor: CGFloat,
        viewSize: CGSize,
        range: ClosedRange<CGFloat> = Camera.defaultZoomRange
    ) -> Camera {
        zoomed(
            by: factor,
            anchoredAtScreen: CGPoint(x: viewSize.width * 0.5, y: viewSize.height * 0.5),
            viewSize: viewSize, range: range
        )
    }

    func clamped(to range: ClosedRange<CGFloat> = Camera.defaultZoomRange) -> Camera {
        var next = self
        next.scale = scale.clamped(to: range)
        return next
    }
}

// MARK: - Codable（CGPoint 手工编解码，保证跨版本稳定）

extension Camera: Codable {
    enum CodingKeys: String, CodingKey {
        case x, y, scale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(CGFloat.self, forKey: .x)
        let y = try container.decode(CGFloat.self, forKey: .y)
        let scale = try container.decode(CGFloat.self, forKey: .scale)
        self.init(center: CGPoint(x: x, y: y), scale: scale)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(center.x, forKey: .x)
        try container.encode(center.y, forKey: .y)
        try container.encode(scale, forKey: .scale)
    }
}

extension Comparable {
    nonisolated fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
