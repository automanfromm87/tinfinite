// InfiniteCanvasModel.swift
// SwiftUI 侧的画布状态：持有相机 + 视口尺寸 + 程序化导航请求。
// 关键性能点：手势进行中 UIKit 以 120Hz 回调 transient 更新，
// 本类只以 ~20Hz 向 SwiftUI 发布，避免 body 高频重算；手势结束必发布一次终态。

import Combine
import CoreGraphics
import SwiftUI

/// 程序化导航请求（Model -> View 单向）
nonisolated struct CanvasNavigationRequest: Equatable {
    var id = UUID()
    var camera: Camera
    var animated: Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class InfiniteCanvasModel: ObservableObject {

    /// 当前相机（节流发布：手势中 ~20Hz，结束/程序化设置立即发布）
    private(set) var camera: Camera = .default {
        willSet { objectWillChange.send() }
    }

    /// 当前视图尺寸（屏幕点）
    private(set) var viewportSize: CGSize = .zero {
        willSet { objectWillChange.send() }
    }

    /// 手势/惯性进行中。View 在 transient 期间跳过 Model->View 兜底回写，
    /// 否则 SwiftUI 更新会把进行中的相机拽回节流前的旧值（抖动/回弹）。
    private(set) var isTransient = false {
        willSet { objectWillChange.send() }
    }

    /// 程序化导航请求；View 消费后置 nil（Coordinator 回写）
    var navigationRequest: CanvasNavigationRequest?

    var zoomRange: ClosedRange<CGFloat> = Camera.defaultZoomRange

    /// 当前视口（派生，O(1)）
    var viewport: Viewport {
        Viewport(camera: camera, size: viewportSize)
    }

    // 节流状态
    private var lastTransientPublish: CFTimeInterval = 0
    private let transientPublishInterval: CFTimeInterval = 1.0 / 20.0

    init(camera: Camera = .default, zoomRange: ClosedRange<CGFloat> = Camera.defaultZoomRange) {
        self.camera = camera
        self.zoomRange = zoomRange
    }

    // MARK: - View -> Model（Coordinator 调用）

    /// 同步 UIKit 侧状态。
    /// - transient=true：手势/惯性进行中，高频调用，内部节流通告 SwiftUI。
    /// - transient=false：一次交互结束，立即通告。
    func sync(camera: Camera, viewportSize: CGSize, transient: Bool) {
        if transient {
            let now = CACurrentMediaTime()
            // 节流窗口内直接丢弃：UIKit 每次回调都携带全量最新 camera，
            // 下一次非丢弃的 sync 会把最新值发布出去，不会丢终态。
            if now - lastTransientPublish < transientPublishInterval { return }
            lastTransientPublish = now
        }
        if self.isTransient != transient { self.isTransient = transient }
        if self.camera != camera { self.camera = camera }
        if self.viewportSize != viewportSize { self.viewportSize = viewportSize }
    }

    // MARK: - Model -> View（程序化导航）

    /// 设置相机（经 Coordinator 转发给 UIKit View，可动画）
    func setCamera(_ camera: Camera, animated: Bool) {
        self.camera = camera.clamped(to: zoomRange)
        navigationRequest = CanvasNavigationRequest(camera: self.camera, animated: animated)
    }

    /// 把世界矩形完整显示
    func zoom(to worldRect: CGRect, viewSize: CGSize, padding: CGFloat = 40, animated: Bool = true) {
        guard worldRect.width > 0, worldRect.height > 0, viewSize.width > 0, viewSize.height > 0 else { return }
        let fitScale = min(
            (viewSize.width - padding * 2) / worldRect.width,
            (viewSize.height - padding * 2) / worldRect.height
        )
        setCamera(
            Camera(
                center: CGPoint(x: worldRect.midX, y: worldRect.midY),
                scale: fitScale
            ),
            animated: animated
        )
    }

    func center(on worldPoint: CGPoint, animated: Bool = true) {
        setCamera(Camera(center: worldPoint, scale: camera.scale), animated: animated)
    }

    func reset(animated: Bool = true) {
        setCamera(.default, animated: animated)
    }

    // MARK: - 坐标变换（读侧 API）

    func worldToScreen(_ world: CGPoint) -> CGPoint {
        camera.worldToScreen(world, viewSize: viewportSize)
    }

    func screenToWorld(_ screen: CGPoint) -> CGPoint {
        camera.screenToWorld(screen, viewSize: viewportSize)
    }
}
