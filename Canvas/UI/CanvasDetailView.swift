// CanvasDetailView.swift
// 画布详情：全屏画布 + 顶部迷你栏（返回/侧边栏 + 标题）+ 右下角悬浮工具栏。

import SwiftUI

struct CanvasDetailView: View {
    @ObservedObject var library: CanvasLibrary
    var documentID: UUID
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var selection: UUID?

    @Environment(\.horizontalSizeClass) private var sizeClass

    @StateObject private var model = InfiniteCanvasModel()
    @StateObject private var drawing = DrawingSettings()
    @StateObject private var refs = CanvasRefs()
    @State private var showGrid = true
    @State private var showMinimap = false
    @State private var renaming = false
    @State private var renameText = ""

    private var title: String {
        library.document(id: documentID)?.meta.title ?? ""
    }

    /// 适合内容：笔画 + 节点并集完整显示。空画布不做任何事。
    @MainActor
    private func fitContent() {
        let strokes = refs.controller?.strokeBounds() ?? []
        let items = refs.canvas?.itemWorldRects() ?? []
        guard let union = MinimapMath.contentUnion(strokes: strokes, items: items) else { return }
        let size = model.viewportSize
        guard size.width > 0, size.height > 0 else { return }
        model.zoom(to: union, viewSize: size, padding: 60)
    }

    var body: some View {
        ZStack {
            InfiniteCanvas(
                    model: model,
                    showGrid: showGrid,
                    onCreate: { [drawing, model, refs, gridBinding = $showGrid] canvas in
                    refs.canvas = canvas
                    // 点选：只在 navigate 模式响应（绘画模式点按=落笔，由笔触管线处理）。
                    // 命中节点选节点，否则走笔画点选 + 取消节点选中。
                    canvas.onSingleTap = { point, hit in
                        MainActor.assumeIsolated {
                            guard drawing.mode == .navigate else { return }
                            drawing.navigateTap(at: point, hit: hit)
                        }
                    }
                    // 键盘动作执行（按键永远在主线程到达，直接 assume 主执行者）
                    canvas.onKeyAction = { action in
                        MainActor.assumeIsolated {
                            @MainActor func zoom(by factor: CGFloat) {
                                let size = model.viewportSize
                                guard size.width > 0, size.height > 0 else { return }
                                let anchor = CGPoint(x: size.width / 2, y: size.height / 2)
                                model.setCamera(
                                    model.camera.zoomed(
                                        by: factor, anchoredAtScreen: anchor,
                                        viewSize: size, range: model.zoomRange
                                    ),
                                    animated: true
                                )
                            }
                            switch action {
                            case .undo: drawing.undo()
                            case .redo: drawing.redo()
                            case .deleteSelection: drawing.deleteSelection()
                            case .clearSelection: drawing.clearSelection()
                            case .toolNavigate: drawing.mode = .navigate
                            case .toolPen:
                                drawing.mode = .draw
                                drawing.tool = .pen
                            case .toolEraser:
                                drawing.mode = .draw
                                if drawing.tool == .eraserWhole {
                                    drawing.tool = .eraserPartial
                                } else {
                                    drawing.tool = .eraserWhole
                                }
                            case .toolLasso:
                                drawing.mode = .draw
                                drawing.tool = .lasso
                            case .toggleGrid: gridBinding.wrappedValue.toggle()
                            case .zoomIn: zoom(by: 1.25)
                            case .zoomOut: zoom(by: 0.8)
                            case .resetCamera: model.reset()
                            case .fitContent: fitContent()
                            case .panBy(let shift):
                                model.setCamera(model.camera.panned(by: shift), animated: false)
                            case .spacePan(let active):
                                if active { drawing.beginSpacePan() } else { drawing.endSpacePan() }
                            }
                        }
                    }
                },
                    onDrawingCreate: { [refs] controller in
                    refs.controller = controller
                    drawing.attach(controller)
                    if let doc = library.document(id: documentID) {
                        controller.saveHandler = { [weak library] id, strokes, nodes in
                            library?.updateContent(id: id, strokes: strokes, nodes: nodes)
                        }
                        controller.openDocument(id: doc.meta.id, strokes: doc.strokes, nodes: doc.nodes)
                    }
                }
            )
            .ignoresSafeArea()
            // 手势锚点：挂在 Representable（单 UIView）上，不会像容器 identifier 那样
            // 覆盖 SwiftUI 子孙的 identifier（XCUITest 查询用）
            .accessibilityIdentifier("infiniteCanvas")

            // 顶部迷你栏
            VStack {
                HStack(spacing: 10) {
                    Button {
                        if sizeClass == .compact {
                            selection = nil
                        } else {
                            columnVisibility = columnVisibility == .all ? .detailOnly : .all
                        }
                    } label: {
                        Image(systemName: sizeClass == .compact ? "chevron.left" : "sidebar.left")
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(sizeClass == .compact ? "返回列表" : "切换侧边栏")

                    Button {
                        renameText = title
                        renaming = true
                    } label: {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("重命名画布")

                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.trailing, 16)
                .padding(.top, 12)
                Spacer()
            }

            // 左下角导览图
            if showMinimap {
                VStack {
                    Spacer()
                    HStack {
                        MinimapView(model: model, drawing: drawing, refs: refs)
                        Spacer()
                    }
                }
                .padding(.leading, 20)
                .padding(.bottom, 24)
            }

            // 右下角悬浮工具
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    FloatingToolbar(
                        drawing: drawing,
                        showGrid: $showGrid,
                        showMinimap: $showMinimap,
                        onResetCamera: { model.reset() },
                        onFitContent: { fitContent() },
                        startExpanded: FloatingToolbar.debugStartExpanded
                    )
                }
            }
            .padding(.trailing, 20)
            .padding(.bottom, 24)

            #if DEBUG
            // XCUITest 读数（1px 近透明，不影响视觉；Release 无此代码）
            VStack(spacing: 0) {
                Text(String(format: "scale %.5f center %.1f %.1f",
                             model.camera.scale, model.camera.center.x, model.camera.center.y))
                    .accessibilityIdentifier("cameraReadout")
                Text("strokes \(drawing.strokeCount) nodes \(drawing.nodeCount) \(drawing.mode == .navigate ? "nav" : "draw")")
                    .accessibilityIdentifier("contentReadout")
            }
            .font(.system(size: 1))
            .opacity(0.01)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #endif
        }
        .toolbar(.hidden, for: .navigationBar)
        .alert("重命名画布", isPresented: $renaming) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("确定") { library.rename(id: documentID, title: renameText) }
        }
        .onAppear {
            #if DEBUG
            if CommandLine.arguments.contains("-CanvasSelfTest") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    CanvasSelfTest.run(model: model, drawing: drawing)
                }
            }
            if CommandLine.arguments.contains("-CanvasStressTest") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    CanvasSelfTest.runStress(model: model, drawing: drawing)
                }
            }
            // 留几个节点在屏幕上供截图验证（不清理，可撤销/删除）
            if CommandLine.arguments.contains("-CanvasDemoNodes") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    drawing.addShape(.rectangle)
                    drawing.addText()
                    // 收起文本带来的键盘（选中态保留，边框可见）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        refs.canvas?.endEditing(true)
                    }
                }
            }
            #endif
        }
    }
}
