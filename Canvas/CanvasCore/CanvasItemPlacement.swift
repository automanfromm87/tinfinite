// CanvasItemPlacement.swift
// 在世界任意位置放置内容：UIView / SwiftUI View 都可作为画布内容，以世界坐标布局。

import SwiftUI
import UIKit

/// 画布内容 ID
typealias CanvasItemID = UUID

extension InfiniteCanvasView {

    // MARK: - 放置 UIView

    /// 把视图放到世界矩形 `worldRect` 处（尺寸单位是世界单位，随缩放一起缩放）。
    /// - Returns: 内容 ID，可用于移动/删除。
    @discardableResult
    func place(_ view: UIView, in worldRect: CGRect) -> CanvasItemID {
        let id = CanvasItemID()
        view.frame = worldRect
        contentView.addSubview(view)
        itemFrames[id] = .rect(view)
        return id
    }

    /// 把视图中心放到世界点 `worldPoint` 处（保持视图自身尺寸，尺寸单位仍是世界单位）。
    @discardableResult
    func place(_ view: UIView, centeredAt worldPoint: CGPoint) -> CanvasItemID {
        let id = CanvasItemID()
        view.center = worldPoint
        contentView.addSubview(view)
        itemFrames[id] = .rect(view)
        return id
    }

    /// 把 SwiftUI 视图作为画布内容放到世界点处，尺寸为其自适应尺寸（世界单位）。
    /// - Note: 本画布强持有 hosting controller，随内容一起释放。
    @discardableResult
    func place<Content: View>(
        swiftUI content: Content,
        centeredAt worldPoint: CGPoint,
        fixedSize: CGSize? = nil
    ) -> CanvasItemID {
        let host = UIHostingController(rootView: AnyView(content))
        host.view.backgroundColor = .clear
        let size = fixedSize ?? host.sizeThatFits(in: CGSize(width: 300, height: 300))
        let safeSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        host.view.frame = CGRect(
            x: worldPoint.x - safeSize.width * 0.5,
            y: worldPoint.y - safeSize.height * 0.5,
            width: safeSize.width, height: safeSize.height
        )
        let id = place(host.view, in: host.view.frame)
        hostedControllers[id] = host
        return id
    }

    // MARK: - 移动 / 删除

    /// 移动内容到新的世界矩形
    func moveItem(_ id: CanvasItemID, to worldRect: CGRect) {
        guard case let .rect(view) = itemFrames[id] else { return }
        view.frame = worldRect
    }

    /// 移动内容中心到新的世界点（保持尺寸）
    func moveItem(_ id: CanvasItemID, centeredAt worldPoint: CGPoint) {
        guard case let .rect(view) = itemFrames[id] else { return }
        view.center = worldPoint
    }

    /// 删除内容（hosting controller 一并释放）
    func removeItem(_ id: CanvasItemID) {
        if case let .rect(view) = itemFrames[id] {
            view.removeFromSuperview()
        }
        itemFrames.removeValue(forKey: id)
        hostedControllers.removeValue(forKey: id)
    }

    /// 删除所有内容
    func removeAllItems() {
        for id in itemFrames.keys { removeItem(id) }
    }

    /// 所有内容当前世界矩形（适配缩放/minimap 用）。O(n)，只在需要时调用。
    func itemWorldRects() -> [CGRect] {
        itemFrames.values.compactMap {
            if case let .rect(view) = $0 { return view.frame }
            return nil
        }
    }

    /// 所有内容当前在屏幕上的 frame（key 为内容 ID），可用于命中测试/调试。
    /// O(n)，只在需要时调用，不要放在手势热路径里。
    func screenFramesOfItems() -> [CanvasItemID: CGRect] {
        var result: [CanvasItemID: CGRect] = [:]
        result.reserveCapacity(itemFrames.count)
        for (id, ref) in itemFrames {
            if case let .rect(view) = ref {
                result[id] = view.convert(view.bounds, to: self)
            }
        }
        return result
    }

    // MARK: - 可见性裁剪（虚拟化入口）

    /// 对当前不可见的内容自动设置 `isHidden`，减少 GPU 合成负载。
    /// 内容量 < 几百时可不调用（单 transform 下隐藏收益不大）；上千内容时建议在 transient=false 时调一次。
    func cullOffscreenItems(margin: CGFloat = 200) {
        let visible = viewport.visibleWorldRect
        let expanded = visible.insetBy(dx: -margin / viewport.scale, dy: -margin / viewport.scale)
        for (_, ref) in itemFrames {
            if case let .rect(view) = ref {
                // frame 是世界坐标（contentView 未变换前的布局空间即世界空间）
                view.isHidden = !expanded.intersects(view.frame)
            }
        }
    }

    // MARK: - 存储（关联对象，避免改主类定义）

    private enum ItemRef {
        case rect(UIView)
    }

    private static var itemFramesKey: UInt8 = 0
    private static var hostedControllersKey: UInt8 = 0

    private var itemFrames: [CanvasItemID: ItemRef] {
        get { objc_getAssociatedObject(self, &Self.itemFramesKey) as? [CanvasItemID: ItemRef] ?? [:] }
        set { objc_setAssociatedObject(self, &Self.itemFramesKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var hostedControllers: [CanvasItemID: UIHostingController<AnyView>] {
        get { objc_getAssociatedObject(self, &Self.hostedControllersKey) as? [CanvasItemID: UIHostingController<AnyView>] ?? [:] }
        set { objc_setAssociatedObject(self, &Self.hostedControllersKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
