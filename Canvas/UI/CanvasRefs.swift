// CanvasRefs.swift
// 画布 UIKit 侧弱引用桥：工具栏按钮/minimap 需要直达 canvas/controller（读 bounds、
// 内容矩形），但 SwiftUI 只持有 Model。onCreate/onDrawingCreate 回填。

import Combine
import UIKit

final class CanvasRefs: ObservableObject {
    weak var canvas: InfiniteCanvasView?
    weak var controller: DrawingController?
}
