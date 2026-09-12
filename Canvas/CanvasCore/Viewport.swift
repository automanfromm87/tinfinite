// Viewport.swift
// 无限画布核心：可视区域抽象。由 Camera + 视图尺寸导出，负责可见性查询与裁剪。

import CoreGraphics

/// 可视区域：某一时刻“屏幕上能看到哪一块世界”。
/// 值类型，每次相机/尺寸变化时重新构造，O(1)。
/// nonisolated：纯值类型，任意线程可用（工程默认 MainActor 隔离，这里显式退出）
nonisolated struct Viewport: Equatable, Sendable {
    var camera: Camera
    /// 视图尺寸（屏幕点）
    var size: CGSize

    static let zero = Viewport(camera: .default, size: .zero)

    /// 当前可见的世界矩形
    var visibleWorldRect: CGRect {
        camera.visibleWorldRect(viewSize: size)
    }

    /// 当前缩放
    var scale: CGFloat { camera.scale }

    /// 带 margin（世界单位）扩大的可见矩形，用于预加载/裁剪
    func visibleWorldRect(insetByWorld margin: CGFloat) -> CGRect {
        visibleWorldRect.insetBy(dx: -margin, dy: -margin)
    }

    /// 世界点是否可见（margin 为世界单位容差）
    func isVisible(_ worldPoint: CGPoint, margin: CGFloat = 0) -> Bool {
        visibleWorldRect.insetBy(dx: -margin, dy: -margin).contains(worldPoint)
    }

    /// 世界矩形是否与可见区域相交（margin 为世界单位容差）
    func isVisible(_ worldRect: CGRect, margin: CGFloat = 0) -> Bool {
        visibleWorldRect.insetBy(dx: -margin, dy: -margin).intersects(worldRect)
    }

    // MARK: - 坐标变换（透传 Camera，调用方无需关心 viewSize）

    func worldToScreen(_ world: CGPoint) -> CGPoint {
        camera.worldToScreen(world, viewSize: size)
    }

    func screenToWorld(_ screen: CGPoint) -> CGPoint {
        camera.screenToWorld(screen, viewSize: size)
    }

    func worldToScreen(_ rect: CGRect) -> CGRect {
        camera.worldToScreen(rect, viewSize: size)
    }
}
