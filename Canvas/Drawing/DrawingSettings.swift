// DrawingSettings.swift
// SwiftUI 侧的绘画设置桥：工具/模式/计数，转发给 DrawingController。
// Controller 是真相源（UIKit 侧拥有），这里弱持有 + onChange 刷新。

import Combine
import SwiftUI
import UIKit

// MARK: - RGBA <-> UIKit 转换

extension RGBA {
    var uiColor: UIColor {
        UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    var swiftUIColor: Color {
        Color(red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
    }

    init(uiColor: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: Float(r), g: Float(g), b: Float(b), a: Float(a))
    }
}

@MainActor
final class DrawingSettings: ObservableObject {
    weak var controller: DrawingController? {
        didSet {
            controller?.onChange = { [weak self] in self?.refresh() }
            refresh()
        }
    }

    /// 当前模式（切换时转发给 controller）
    @Published var mode: DrawingController.Mode = .navigate {
        didSet { controller?.mode = mode }
    }

    /// 当前工具（绘画模式内）
    @Published var tool: DrawingController.Tool = .pen {
        didSet { controller?.tool = tool }
    }

    /// 当前笔刷（钢笔/荧光笔/墨水笔/铅笔；切换时重建样式）
    @Published var brush: BrushKind = .pen {
        didSet { pushStyle() }
    }

    /// 当前笔色
    @Published var color: RGBA = .black {
        didSet { pushStyle() }
    }

    /// 当前笔宽（世界单位）
    @Published var lineWidth: CGFloat = 8 {
        didSet { pushStyle() }
    }

    /// 橡皮直径（世界单位）
    @Published var eraserWidth: CGFloat = 24 {
        didSet { controller?.eraserWidth = eraserWidth }
    }

    /// 手指是否能画（Demo 默认开：模拟器鼠标拖拽即手指触摸，可直接画）
    @Published var allowFingerDrawing = true {
        didSet { controller?.allowFingerDrawing = allowFingerDrawing }
    }

    // 只读状态（controller 回写）
    @Published private(set) var strokeCount = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isDrawing = false
    @Published private(set) var hasSelection = false
    @Published private(set) var selectedCount = 0
    @Published private(set) var nodeCount = 0
    @Published private(set) var hasNodeSelection = false

    /// 快捷配色
    let palette: [RGBA] = [.black, .red, .orange, .green, .blue, .purple]

    func attach(_ controller: DrawingController) {
        self.controller = controller
        controller.mode = mode
        controller.tool = tool
        controller.allowFingerDrawing = allowFingerDrawing
        controller.eraserWidth = eraserWidth
        pushStyle()
        refresh()
    }

    /// 空格抓手暂存的模式（nil = 未处于空格抓手中）
    private var spaceSavedMode: DrawingController.Mode?

    /// 空格按下：临时切 navigate；松开见 endSpacePan
    func beginSpacePan() {
        if spaceSavedMode == nil { spaceSavedMode = mode }
        mode = .navigate
    }

    /// 空格松开：恢复之前的模式
    func endSpacePan() {
        if let m = spaceSavedMode { mode = m }
        spaceSavedMode = nil
    }

    func undo() { controller?.undo() }
    func redo() { controller?.redo() }
    func clear() { controller?.clear() }
    func deleteSelection() { controller?.deleteSelection() }
    func clearSelection() { controller?.clearSelection() }
    func selectTap(at screenPoint: CGPoint) { controller?.selectTap(atScreen: screenPoint) }
    func navigateTap(at screenPoint: CGPoint, hit: UIView?) { controller?.navigateTap(atScreen: screenPoint, hit: hit) }

    // MARK: - 内容节点

    func addShape(_ shape: ContentShape) { controller?.addShape(shape) }
    func addText() { controller?.addText() }
    func addNote() { controller?.addNote() }
    func addImage(data: Data) { controller?.addImage(data: data) }

    private func pushStyle() {
        let width = max(lineWidth, 0.5)
        switch brush {
        case .pen:
            controller?.style = .pen(color: color, width: width)
        case .highlighter:
            // 荧光笔用选取色但固定半透明（保证盖住字迹仍可读）
            var c = color
            c.a = 0.45
            controller?.style = .highlighter(color: c, width: width)
        case .fountainPen:
            controller?.style = .fountainPen(color: color, width: width)
        case .pencil:
            controller?.style = .pencil(color: color, width: width)
        }
    }

    /// 从 controller 拉取状态。所有赋值必须先判等再写：@Published 即使同值
    /// 赋值也会发射 objectWillChange，在 view updates 中途发射即触发未定义行为警告。
    /// 注意不能用 inout 小助手做守卫——inout copy-back 总会调一次 setter，
    /// 同样会发射；必须写成 plain if。
    private func refresh() {
        guard let controller else {
            if strokeCount != 0 { strokeCount = 0 }
            if canUndo != false { canUndo = false }
            if canRedo != false { canRedo = false }
            if isDrawing != false { isDrawing = false }
            if hasSelection != false { hasSelection = false }
            if selectedCount != 0 { selectedCount = 0 }
            if nodeCount != 0 { nodeCount = 0 }
            if hasNodeSelection != false { hasNodeSelection = false }
            return
        }
        if strokeCount != controller.strokeCount { strokeCount = controller.strokeCount }
        if canUndo != controller.canUndo { canUndo = controller.canUndo }
        if canRedo != controller.canRedo { canRedo = controller.canRedo }
        if isDrawing != controller.isLiveStrokeActive { isDrawing = controller.isLiveStrokeActive }
        if hasSelection != controller.hasSelection { hasSelection = controller.hasSelection }
        if selectedCount != controller.selectedCount { selectedCount = controller.selectedCount }
        if nodeCount != controller.nodeCount { nodeCount = controller.nodeCount }
        if hasNodeSelection != controller.hasNodeSelection { hasNodeSelection = controller.hasNodeSelection }
        if mode != controller.mode { mode = controller.mode }
        if tool != controller.tool { tool = controller.tool }
    }
}
