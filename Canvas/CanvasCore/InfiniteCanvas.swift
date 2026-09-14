// InfiniteCanvas.swift
// SwiftUI 封装：InfiniteCanvasView + CanvasGridView 的组合，网格在下、内容在上。
// - 网格直接由 UIKit 回调驱动重绘，不经过 SwiftUI
// - Model 只收节流后的状态 + 下发程序化导航

import SwiftUI
import UIKit

/// 无限画布（SwiftUI 入口）。
///
/// ```swift
/// struct MyView: View {
///     @StateObject private var model = InfiniteCanvasModel()
///     var body: some View {
///         InfiniteCanvas(model: model) { canvas in
///             let box = UIView(frame: .zero)
///             box.backgroundColor = .systemRed
///             canvas.place(box, in: CGRect(x: -50, y: -50, width: 100, height: 100))
///         }
///     }
/// }
/// ```
struct InfiniteCanvas: UIViewRepresentable {
    @ObservedObject var model: InfiniteCanvasModel
    var paper: PaperTheme = .system
    var gridStyle: GridStyle = .lines
    /// 画布创建时回调一次：在这里放置初始内容、配置画布
    var onCreate: ((InfiniteCanvasView) -> Void)?
    /// 绘画控制器就绪回调一次：在这里配置工具/添加初始墨迹
    var onDrawingCreate: ((DrawingController) -> Void)?

    func makeUIView(context: Context) -> CanvasContainerView {
        let container = CanvasContainerView()
        container.canvas.camera = model.camera
        container.canvas.zoomRange = model.zoomRange
        applyPaper(to: container)
        container.canvas.onCameraChange = { [weak model, weak container] camera, viewport, transient in
            guard let container else { return }
            // 网格/墨迹/选择框走 UIKit 直驱，不经过 SwiftUI
            container.grid.viewport = viewport
            container.strokes.viewport = viewport
            container.selection.viewport = viewport
            // 相机静止 -> LOD 检查（只读 viewport，不回写状态）
            if !transient {
                container.drawing.viewportSettled(viewport)
            }
            // 状态同步回 Model（节流在 Model 内）
            model?.sync(camera: camera, viewportSize: viewport.size, transient: transient)
        }
        onCreate?(container.canvas)
        onDrawingCreate?(container.drawing)
        return container
    }

    /// makeUIView 时容器还没进窗口（trait 不准），先按当前 trait 应用一次；
    /// 进窗口/trait 变化后容器自己在 traitCollectionDidChange 里重算
    private func applyPaper(to container: CanvasContainerView) {
        container.applyPaper(paper, gridStyle: gridStyle)
    }

    func updateUIView(_ container: CanvasContainerView, context: Context) {
        container.applyPaper(paper, gridStyle: gridStyle)
        if container.canvas.zoomRange != model.zoomRange {
            container.canvas.zoomRange = model.zoomRange
        }
        // 消费程序化导航请求（Model -> View 单向通道）。
        // 注意：这里绝不能同步回写 canvas.camera——setCamera 会经 onCameraChange
        // 同步发布 Model 状态，即“在 view updates 中途发布”，触发未定义行为。
        if let request = model.navigationRequest {
            model.navigationRequest = nil
            container.canvas.setCamera(request.camera, animated: request.animated)
        } else {
            // 不变量：非 transient 时两侧相机必须一致（sync 即时收敛）。
            assert(model.isTransient || container.canvas.camera == model.camera)
        }
    }

    static func dismantleUIView(_ container: CanvasContainerView, coordinator: ()) {
        container.canvas.onCameraChange = nil
    }
}

/// 容器：网格层 + 内容画布 + 墨迹层（Metal 透明覆盖）+ 选择框（最上）
final class CanvasContainerView: UIView {
    let grid = CanvasGridView()
    let canvas = InfiniteCanvasView()
    let strokes = StrokeMetalView()
    let selection = SelectionOverlayView()
    private(set) lazy var drawing = DrawingController(canvas: canvas, strokeView: strokes, overlay: selection)

    override init(frame: CGRect) {
        super.init(frame: frame)
        canvas.backgroundColor = .clear
        for v: UIView in [grid, canvas, strokes, selection] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 纸张

    private var paper: PaperTheme = .system
    private var gridStyle: GridStyle = .lines

    func applyPaper(_ paper: PaperTheme, gridStyle: GridStyle) {
        self.paper = paper
        self.gridStyle = gridStyle
        let background = paper.backgroundColor(for: traitCollection)
        backgroundColor = background
        // 网格层不透明并自己铺底：网格开着时它就是纸面，
        // 底下的容器背景完全不参与合成（少一层全屏 blend）
        grid.paperColor = background
        grid.isHidden = !gridStyle.showsGrid
        grid.style = gridStyle
        grid.darkBackground = paper.isDark(for: traitCollection)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle else { return }
        applyPaper(paper, gridStyle: gridStyle)
    }
}
