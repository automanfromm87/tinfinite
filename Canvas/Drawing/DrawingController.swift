// DrawingController.swift
// Drawing 层总装：触摸路由 + 笔/橡皮/套索/移动 + LOD + 自动存档。
// 笔画真相在 StrokeStore（纯逻辑），这里只做输入、tolerance、渲染同步、存档。

import UIKit
import os

/// NSObject 基类：UITextViewDelegate（ObjC 协议）要求。
final class DrawingController: NSObject {

    enum Mode: Hashable {
        case navigate
        case draw
    }

    enum Tool: Hashable {
        case pen
        case eraserWhole
        case eraserPartial
        case lasso
    }

    // MARK: - 配置

    var mode: Mode = .navigate {
        didSet { guard mode != oldValue else { return }; applyTouchPolicy(); onChange?() }
    }

    var tool: Tool = .pen {
        didSet { guard tool != oldValue else { return }; cancelActiveEdit(); onChange?() }
    }

    var style: StrokeStyle = .defaultPen {
        didSet { guard style != oldValue else { return }; onChange?() }
    }

    /// 橡皮直径（世界单位）
    var eraserWidth: CGFloat = 24

    /// 手指是否也能画/擦/套索（默认 false：手指永远 pan，只有笔能画）
    var allowFingerDrawing = false {
        didSet { applyTouchPolicy() }
    }

    /// 手指落笔的默认压力（手指无压力硬件）
    var fingerPressure: CGFloat = 0.6

    /// LOD 屏幕目标误差（点）：笔画细节恒定，不管缩放到多少
    var lodScreenError: CGFloat = 0.35

    /// 状态变化回调（笔画/模式/工具/选择/可撤销性，离散事件，无需节流）
    var onChange: (() -> Void)?

    // MARK: - 状态（只读，透传 Store）

    var strokes: [Stroke] { store.strokes }
    var strokeCount: Int { store.strokes.count }
    /// 跨域账本判空（笔画/节点统一顺序，见 undoJournal）
    var canUndo: Bool { !undoJournal.isEmpty }
    var canRedo: Bool { !redoJournal.isEmpty }
    var hasSelection: Bool { store.hasSelection }
    var selectedCount: Int { store.selection.count }
    private(set) var isLiveStrokeActive = false

    // MARK: - 内部

    private weak var canvas: InfiniteCanvasView?
    private weak var strokeView: StrokeMetalView?
    private weak var overlay: SelectionOverlayView?
    private let strokeRecognizer = StrokeGestureRecognizer()
    private var store = StrokeStore()

    // MARK: - 跨域 Undo 账本

    /// 笔画与节点各有自己的撤销栈；账本记录每次模型变更来自哪个域，
    /// undo/redo 按账本顺序分发，保证交错编辑时顺序正确。
    private enum EditDomain {
        case strokes
        case nodes
    }

    private var undoJournal: [EditDomain] = []
    private var redoJournal: [EditDomain] = []

    /// 笔画变更记账（比较调用前后 undoDepth，有新条目才记；空操作不记）
    private func noteStrokeMutation(from depth: Int) {
        if store.undoDepth != depth {
            undoJournal.append(.strokes)
            redoJournal.removeAll()
        }
    }

    /// 节点变更记账（同上；连续输入合并后 depth 不变，只记一次）
    private func noteContentMutation(from depth: Int) {
        if content.undoDepth != depth {
            undoJournal.append(.nodes)
            redoJournal.removeAll()
        }
    }

    private func resetJournal() {
        undoJournal.removeAll()
        redoJournal.removeAll()
    }

    /// 笔 live 采样
    private var sampler = StrokeSampler()

    /// 当前编辑动作
    private enum EditKind {
        case penStroke
        case eraser
        case lasso
        case move
    }

    private var activeEdit: EditKind?

    /// 橡皮/套索路径（屏幕+世界双存：屏幕做重采样/点选判断，世界做命中）
    private var editPathScreen: [CGPoint] = []
    private var editPathWorld: [CGPoint] = []

    /// 移动状态
    private struct MoveState {
        var ids: [UUID]
        var lastScreen: CGPoint
        var totalDelta: CGSize
    }

    private var moveState: MoveState?

    /// LOD 基准
    private var lastLodScale: CGFloat?

    /// 自动存档防抖
    private var saveWork: DispatchWorkItem?

    init(canvas: InfiniteCanvasView, strokeView: StrokeMetalView, overlay: SelectionOverlayView) {
        self.canvas = canvas
        self.strokeView = strokeView
        self.overlay = overlay
        super.init()
        strokeRecognizer.addTarget(self, action: #selector(handleStroke(_:)))
        canvas.addGestureRecognizer(strokeRecognizer)
        applyTouchPolicy()
    }

    // MARK: - 触摸策略

    /// 全部触摸类型（系统识别器的 allowedTouchTypes 为 nonnull，空数组会被拒收一切，
    /// 必须显式列出；只有自研 StrokeGestureRecognizer 才把空当全部）
    private static let allTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue),
        NSNumber(value: UITouch.TouchType.indirect.rawValue),
        NSNumber(value: UITouch.TouchType.pencil.rawValue),
        NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
    ]

    private func applyTouchPolicy() {
        // 节点只在 navigate 模式可交互
        updateNodeInteraction()
        switch mode {
        case .navigate:
            strokeRecognizer.isEnabled = false
            guard let canvas else { return }
            canvas.panGesture.isEnabled = true
            canvas.panGesture.minimumNumberOfTouches = 1
            canvas.panGesture.allowedTouchTypes = Self.allTouchTypes
        case .draw:
            strokeRecognizer.isEnabled = true
            guard let canvas else { return }
            if allowFingerDrawing {
                // 手指模式同时接受鼠标/触控板（模拟器鼠标、iPad 触控板以 indirectPointer 到达；
                // 语义上它们就是“手指”，拒绝会导致模拟器/XCUITest 画不出线）
                strokeRecognizer.allowedTouchTypes = [
                    NSNumber(value: UITouch.TouchType.direct.rawValue),
                    NSNumber(value: UITouch.TouchType.pencil.rawValue),
                    NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
                ]
                // 单指画线、双指平移（笔触识别器见到双指自败，把竞技场让给 pan）
                canvas.panGesture.isEnabled = true
                canvas.panGesture.minimumNumberOfTouches = 2
                canvas.panGesture.allowedTouchTypes = Self.allTouchTypes
            } else {
                strokeRecognizer.allowedTouchTypes = [
                    NSNumber(value: UITouch.TouchType.pencil.rawValue),
                ]
                canvas.panGesture.isEnabled = true
                canvas.panGesture.minimumNumberOfTouches = 1
                canvas.panGesture.allowedTouchTypes = [
                    NSNumber(value: UITouch.TouchType.direct.rawValue),
                ]
            }
        }
    }

    // MARK: - 触摸路由

    @objc private func handleStroke(_ recognizer: StrokeGestureRecognizer) {
        guard let canvas else { return }
        switch recognizer.state {
        case .began:
            guard let touch = recognizer.trackedTouch else { return }
            beginEdit(with: touch, canvas: canvas)
            for t in recognizer.pendingCoalesced.dropFirst() {
                appendEditTouch(t, canvas: canvas)
            }
            if activeEdit == .penStroke {
                updatePredicted(recognizer.pendingPredicted, canvas: canvas)
            }
            refreshEditPreview()
        case .changed:
            for t in recognizer.pendingCoalesced {
                appendEditTouch(t, canvas: canvas)
            }
            if activeEdit == .penStroke {
                updatePredicted(recognizer.pendingPredicted, canvas: canvas)
            }
            refreshEditPreview()
        case .ended:
            endEdit(canvas: canvas)
        case .cancelled, .failed:
            cancelActiveEdit()
        default:
            break
        }
    }

    private func beginEdit(with touch: UITouch, canvas: InfiniteCanvasView) {
        let loc = touch.location(in: canvas)
        switch tool {
        case .pen:
            activeEdit = .penStroke
            beginLiveStroke(with: touch, canvas: canvas)
        case .eraserWhole, .eraserPartial:
            activeEdit = .eraser
            editPathScreen = [loc]
            editPathWorld = [canvas.screenToWorld(loc)]
        case .lasso:
            if hasSelection, isInsideSelection(screenPoint: loc, canvas: canvas) {
                activeEdit = .move
                moveState = MoveState(
                    ids: strokes.filter { store.selection.contains($0.id) }.map(\.id),
                    lastScreen: loc,
                    totalDelta: .zero
                )
            } else {
                activeEdit = .lasso
                editPathScreen = [loc]
                editPathWorld = [canvas.screenToWorld(loc)]
            }
        }
        isLiveStrokeActive = true
        onChange?()
    }

    private func appendEditTouch(_ touch: UITouch, canvas: InfiniteCanvasView) {
        let loc = touch.location(in: canvas)
        switch activeEdit {
        case .penStroke:
            appendLiveTouch(touch, canvas: canvas)
        case .eraser:
            appendPathPoint(screen: loc, canvas: canvas, spacing: 4)
        case .lasso:
            appendPathPoint(screen: loc, canvas: canvas, spacing: 3)
        case .move:
            appendMovePoint(screen: loc)
        case nil:
            break
        }
    }

    private func endEdit(canvas: InfiniteCanvasView) {
        switch activeEdit {
        case .penStroke:
            if let touch = strokeRecognizer.pendingCoalesced.last {
                endLiveStroke(with: touch, canvas: canvas)
            } else {
                cancelActiveEdit()
            }
        case .eraser:
            commitErase()
        case .lasso:
            commitLasso(canvas: canvas)
        case .move:
            commitMove()
        case nil:
            break
        }
        activeEdit = nil
        moveState = nil
        editPathScreen = []
        editPathWorld = []
        isLiveStrokeActive = false
        strokeView?.setLiveMesh(nil)
        clearDragHints()
        onChange?()
    }

    func cancelActiveEdit() {
        // 移动取消：恢复原 mesh
        if activeEdit == .move, let ids = moveState?.ids {
            for m in store.meshesFor(ids: ids) {
                strokeView?.updateMeshInPlace(id: m.id, mesh: m.mesh, bounds: m.bounds)
            }
            refreshSelectionOverlay()
        }
        activeEdit = nil
        moveState = nil
        editPathScreen = []
        editPathWorld = []
        isLiveStrokeActive = false
        strokeView?.setLiveMesh(nil)
        clearDragHints()
        onChange?()
    }

    // MARK: - 笔管线

    private func beginLiveStroke(with touch: UITouch, canvas: InfiniteCanvasView) {
        sampler = StrokeSampler()
        sampler.style = style
        sampler.worldConverter = { [weak canvas] screen in
            canvas?.screenToWorld(screen) ?? screen
        }
        let loc = touch.location(in: canvas)
        sampler.begin(
            screen: loc,
            pressure: pressure(for: touch),
            altitude: altitude(for: touch),
            azimuth: azimuth(for: touch, in: canvas),
            time: touch.timestamp
        )
    }

    private func appendLiveTouch(_ touch: UITouch, canvas: InfiniteCanvasView) {
        let loc = touch.location(in: canvas)
        sampler.append(
            screen: loc,
            pressure: pressure(for: touch),
            altitude: altitude(for: touch),
            azimuth: azimuth(for: touch, in: canvas),
            time: touch.timestamp
        )
    }

    private func updatePredicted(_ predicted: [UITouch], canvas: InfiniteCanvasView) {
        sampler.setPredicted(predicted.map { $0.location(in: canvas) })
    }

    private func endLiveStroke(with touch: UITouch, canvas: InfiniteCanvasView) {
        let loc = touch.location(in: canvas)
        sampler.end(
            screen: loc,
            pressure: pressure(for: touch),
            altitude: altitude(for: touch),
            azimuth: azimuth(for: touch, in: canvas),
            time: touch.timestamp
        )
        let strokeDepth = store.undoDepth
        let (stroke, sync) = store.commitStroke(
            rawPoints: sampler.rawPoints,
            spine: sampler.spine,
            style: style,
            tolerance: currentTolerance()
        )
        _ = stroke
        noteStrokeMutation(from: strokeDepth)
        apply(sync)
        scheduleAutosave()
    }

    // MARK: - 橡皮/套索路径

    private func appendPathPoint(screen: CGPoint, canvas: InfiniteCanvasView, spacing: CGFloat) {
        guard let last = editPathScreen.last else {
            editPathScreen = [screen]
            editPathWorld = [canvas.screenToWorld(screen)]
            return
        }
        let dx = screen.x - last.x
        let dy = screen.y - last.y
        if dx * dx + dy * dy >= spacing * spacing {
            editPathScreen.append(screen)
            editPathWorld.append(canvas.screenToWorld(screen))
        }
    }

    /// 路径预览：ribbon 走 live mesh 通道 + overlay 光标/提示
    private func refreshEditPreview() {
        guard let strokeView else { return }
        switch activeEdit {
        case .penStroke:
            clearDragHints()
            let spine = sampler.displaySpine
            guard !spine.isEmpty else {
                strokeView.setLiveMesh(nil)
                return
            }
            strokeView.setLiveMesh(StrokeGeometry.tessellate(
                spine: spine, color: style.color, flattenTolerance: currentTolerance()
            ))
        case .eraser:
            overlay?.lassoEnds = nil
            strokeView.setLiveMesh(trailMesh(width: eraserWidth))
            if let last = editPathWorld.last {
                overlay?.eraserCursor = (center: last, radius: eraserWidth * 0.5)
            } else {
                overlay?.eraserCursor = nil
            }
        case .lasso:
            overlay?.eraserCursor = nil
            let scale = canvas?.camera.scale ?? 1
            strokeView.setLiveMesh(trailMesh(
                width: 2.5 / max(scale, 0.01),
                color: RGBA(r: 0.1, g: 0.45, b: 1.0, a: 0.85)
            ))
            if let first = editPathWorld.first, let last = editPathWorld.last {
                overlay?.lassoEnds = (start: first, current: last)
            } else {
                overlay?.lassoEnds = nil
            }
        case .move, nil:
            clearDragHints()
            break
        }
    }

    private func trailMesh(width: CGFloat, color: RGBA = RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.8)) -> StrokeMesh? {
        guard editPathWorld.count >= 2 else { return nil }
        let spine = editPathWorld.map { SpinePoint(center: $0, width: width) }
        return StrokeGeometry.tessellate(
            spine: spine,
            color: color,
            flattenTolerance: currentTolerance()
        )
    }

    /// 清拖拽提示（overlay 光标/套索线；live mesh 由调用方处理）
    private func clearDragHints() {
        overlay?.eraserCursor = nil
        overlay?.lassoEnds = nil
    }

    private func commitErase() {
        guard editPathWorld.count >= 2 else { return }
        let radius = eraserWidth * 0.5
        let sync: RenderSync
        let strokeDepth = store.undoDepth
        if tool == .eraserPartial {
            sync = store.erasePartial(path: editPathWorld, radius: radius, tolerance: currentTolerance())
        } else {
            sync = store.eraseStrokes(path: editPathWorld, radius: radius)
        }
        noteStrokeMutation(from: strokeDepth)
        if !sync.isEmpty {
            apply(sync)
            refreshSelectionOverlay()
            scheduleAutosave()
        }
    }

    private func commitLasso(canvas: InfiniteCanvasView) {
        guard !editPathScreen.isEmpty else { return }
        // 小范围视为点选，否则圈选
        let screenBounds = editPathScreen.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        if max(screenBounds.width, screenBounds.height) < 14, let first = editPathWorld.first {
            let scale = canvas.camera.scale
            _ = store.selectTap(at: first, radius: 8 / max(scale, 0.01))
        } else if editPathWorld.count >= 3 {
            _ = store.selectLoop(editPathWorld)
        } else {
            store.clearSelection()
        }
        refreshSelectionOverlay()
    }

    // MARK: - 移动选中

    private func isInsideSelection(screenPoint: CGPoint, canvas: InfiniteCanvasView) -> Bool {
        guard let world = store.selectionBounds() else { return false }
        let screen = canvas.camera.worldToScreen(world, viewSize: canvas.bounds.size)
        return screen.insetBy(dx: -12, dy: -12).contains(screenPoint)
    }

    private func appendMovePoint(screen: CGPoint) {
        guard var state = moveState, let canvas, canvas.camera.scale > 0 else { return }
        let scale = canvas.camera.scale
        let delta = CGSize(
            width: (screen.x - state.lastScreen.x) / scale,
            height: (screen.y - state.lastScreen.y) / scale
        )
        state.lastScreen = screen
        state.totalDelta.width += delta.width
        state.totalDelta.height += delta.height
        moveState = state
        // 预览：原地平移 mesh + 偏移选择框（模型不动，取消可恢复）
        for m in store.previewMoveSelection(by: state.totalDelta) {
            strokeView?.updateMeshInPlace(id: m.id, mesh: m.mesh, bounds: m.bounds)
        }
        if let base = store.selectionBounds() {
            overlay?.worldRect = base.offsetBy(dx: state.totalDelta.width, dy: state.totalDelta.height)
        }
    }

    private func commitMove() {
        guard let state = moveState else { return }
        let strokeDepth = store.undoDepth
        let sync = store.commitMoveSelection(by: state.totalDelta)
        noteStrokeMutation(from: strokeDepth)
        if !sync.isEmpty {
            apply(sync)
            scheduleAutosave()
        }
        refreshSelectionOverlay()
    }

    // MARK: - 选择操作

    func deleteSelection() {
        // 笔画与节点互斥选中，同时只可能一边非空
        if let nodeID = content.selectedID {
            let contentDepth = content.undoDepth
            content.remove(ids: [nodeID])
            noteContentMutation(from: contentDepth)
            removeNodeViews(ids: [nodeID])
            scheduleAutosave()
        }
        let strokeDepth = store.undoDepth
        let sync = store.deleteSelection()
        noteStrokeMutation(from: strokeDepth)
        if !sync.isEmpty {
            apply(sync)
            scheduleAutosave()
        }
        refreshSelectionOverlay()
        onChange?()
    }

    func clearSelection() {
        if content.selectedID != nil {
            content.select(id: nil)
            refreshNodeSelection()
        }
        store.clearSelection()
        refreshSelectionOverlay()
        onChange?()
    }

    /// 点选：命中笔画则单选，未命中则取消选中。返回是否命中。
    /// 半径 8pt（屏幕）/ scale，和套索点选回退一致。
    @discardableResult
    func selectTap(atScreen screenPoint: CGPoint) -> Bool {
        guard let canvas else { return false }
        let world = canvas.screenToWorld(screenPoint)
        let radius = 8 / max(canvas.camera.scale, 0.01)
        let ids = store.selectTap(at: world, radius: radius)
        refreshSelectionOverlay()
        onChange?()
        return !ids.isEmpty
    }

    private func refreshSelectionOverlay() {
        overlay?.worldRect = store.selectionBounds()
    }

    // MARK: - Undo/Redo/Clear/合成

    func undo() {
        guard let domain = undoJournal.popLast() else {
            refreshSelectionOverlay()
            onChange?()
            return
        }
        switch domain {
        case .strokes:
            if let sync = store.undo() {
                apply(sync)
                scheduleAutosave()
                redoJournal.append(.strokes)
            }
        case .nodes:
            if let sync = content.undo() {
                applyContent(sync)
                scheduleAutosave()
                redoJournal.append(.nodes)
            }
        }
        refreshSelectionOverlay()
        onChange?()
    }

    func redo() {
        guard let domain = redoJournal.popLast() else {
            refreshSelectionOverlay()
            onChange?()
            return
        }
        switch domain {
        case .strokes:
            if let sync = store.redo() {
                apply(sync)
                scheduleAutosave()
                undoJournal.append(.strokes)
            }
        case .nodes:
            if let sync = content.redo() {
                applyContent(sync)
                scheduleAutosave()
                undoJournal.append(.nodes)
            }
        }
        refreshSelectionOverlay()
        onChange?()
    }

    func clear() {
        let strokeDepth = store.undoDepth
        let sync = store.clear()
        noteStrokeMutation(from: strokeDepth)
        if !sync.isEmpty {
            apply(sync)
            scheduleAutosave()
        }
        let contentDepth = content.undoDepth
        let contentSync = content.clear()
        noteContentMutation(from: contentDepth)
        if !contentSync.isEmpty {
            applyContent(contentSync)
            scheduleAutosave()
        }
        refreshSelectionOverlay()
        onChange?()
    }

    /// 直接提交一笔（点列已是世界坐标+压力）。返回提交的 Stroke。
    @discardableResult
    func addStroke(points: [StrokePoint], style: StrokeStyle) -> Stroke? {
        let strokeDepth = store.undoDepth
        guard let (stroke, sync) = store.addSynthetic(
            points: points, style: style, tolerance: currentTolerance()
        ) else { return nil }
        noteStrokeMutation(from: strokeDepth)
        apply(sync)
        scheduleAutosave()
        onChange?()
        return stroke
    }

    // MARK: - LOD

    /// 相机静止时调用（transient=false）：缩放变化超阈值则对可见笔画重 tessellate
    func viewportSettled(_ viewport: Viewport) {
        // 节点虚拟化：静止时隐藏屏外节点（手势中不调，避免滚动时闪烁）
        canvas?.cullOffscreenItems()
        let scale = viewport.scale
        guard scale > 0 else { return }
        guard let last = lastLodScale else {
            lastLodScale = scale
            return
        }
        guard StrokeGeometry.lodNeedsUpdate(from: last, to: scale) else { return }
        lastLodScale = scale
        // 可见集：可见矩形外扩 20%（转弯/惯性余量）
        let visible = viewport.visibleWorldRect
        let expanded = visible.insetBy(
            dx: -visible.width * 0.1, dy: -visible.height * 0.1
        )
        let ids = strokes.filter { $0.bounds.intersects(expanded) }.map(\.id)
        guard !ids.isEmpty else { return }
        let sync = store.retessellate(ids: ids, tolerance: StrokeGeometry.lodTolerance(
            forScale: scale, screenError: lodScreenError
        ))
        apply(sync)
        // LOD 只换 mesh 不改模型，不存档
        #if DEBUG
        SelfTestLog.log.log("LOD relod \(ids.count) strokes @scale=\(scale)")
        #endif
    }

    private func currentTolerance() -> CGFloat {
        let scale = canvas?.camera.scale ?? lastLodScale ?? 1
        return StrokeGeometry.lodTolerance(forScale: scale, screenError: lodScreenError)
    }

    // MARK: - 文档

    /// 当前打开的文档 id（nil = 未绑定，不存档）
    var documentID: UUID?

    /// 存档回调（由文档库注入）：自动存档时回写笔画 + 节点
    var saveHandler: ((UUID, [Stroke], [ContentNode]) -> Void)?

    /// 打开文档：全量替换笔画 + 全量同步渲染 + 重置 LOD 基准。
    /// 尾随 onChange 异步投递：openDocument 跑在 makeUIView 里（view updates 中途），
    /// 同步发布会触发“Publishing changes from within view updates”未定义行为。
    func openDocument(id: UUID, strokes: [Stroke], nodes: [ContentNode] = []) {
        documentID = id
        resetJournal()
        store.replaceAll(with: strokes, tolerance: currentTolerance())
        strokeView?.setCommittedStrokes(store.renderData())
        lastLodScale = canvas?.camera.scale ?? 1
        refreshSelectionOverlay()
        rebuildNodeViews(from: nodes)
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    /// 恢复节点快照（清空历史，重建视图，并存档；与 restoreStrokes 配对）
    func restoreNodes(_ nodes: [ContentNode]) {
        resetJournal()
        rebuildNodeViews(from: nodes)
        scheduleAutosave()
        onChange?()
    }

    private func rebuildNodeViews(from nodes: [ContentNode]) {
        if let canvas {
            for itemID in nodeItems.values { canvas.removeItem(itemID) }
        }
        nodeItems.removeAll()
        nodeViews.removeAll()
        content.replaceAll(with: nodes)
        for node in content.nodes { placeNodeView(node) }
        updateNodeInteraction()
        canvas?.cullOffscreenItems()
    }

    /// 笔画快照（自检备份用）
    func snapshotStrokes() -> [Stroke] {
        store.strokes
    }

    /// 全部笔画 bounds（minimap 用）
    func strokeBounds() -> [CGRect] {
        store.strokes.map(\.bounds)
    }

    /// 全部笔画外包矩形（适配缩放用，nil = 无笔画）
    func contentBounds() -> CGRect? {
        store.contentBounds()
    }

    /// 恢复快照（清空历史，全量同步，并存档）
    func restoreStrokes(_ strokes: [Stroke]) {
        resetJournal()
        store.replaceAll(with: strokes, tolerance: currentTolerance())
        strokeView?.setCommittedStrokes(store.renderData())
        refreshSelectionOverlay()
        scheduleAutosave()
        onChange?()
    }

    private func scheduleAutosave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let id = self.documentID else { return }
            self.saveHandler?(id, self.store.strokes, self.content.nodes)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - 触摸属性

    private func pressure(for touch: UITouch) -> CGFloat {
        if touch.type == .pencil, touch.maximumPossibleForce > 0 {
            return min(max(touch.force / touch.maximumPossibleForce, 0), 1)
        }
        return fingerPressure
    }

    private func altitude(for touch: UITouch) -> CGFloat {
        touch.type == .pencil ? touch.altitudeAngle : .pi / 2
    }

    private func azimuth(for touch: UITouch, in view: UIView) -> CGFloat {
        touch.type == .pencil ? touch.azimuthAngle(in: view) : 0
    }

    #if DEBUG
    /// 自检用：程序化圈选（与触摸圈选同一 Store 路径）
    func selectLoopForTest(loop: [CGPoint]) {
        _ = store.selectLoop(loop)
        refreshSelectionOverlay()
        onChange?()
    }

    /// 自检用：当前缩放
    var canvasScaleForTest: CGFloat { canvas?.camera.scale ?? -1 }
    /// 自检用：节点视图数（与模型数对照，验证视图同步）
    var nodeViewsCountForTest: Int { nodeViews.count }
    /// 自检用：被裁剪隐藏的节点数（虚拟化验证）
    var culledNodeCountForTest: Int { nodeViews.values.filter(\.isHidden).count }
    /// 自检用：Metal 缓冲统计（笔画 mesh 数，顶点数，索引数）
    var bufferStatsForTest: (meshes: Int, vertices: Int, indices: Int) {
        strokeView?.bufferStats ?? (0, 0, 0)
    }

    /// 自检用：在指定框播种节点（无级联/选中/键盘，压力测试用）
    func seedNodeForTest(kind: ContentNodeKind, frame: CGRect, fill: RGBA = .blue) {
        guard content.nodes.count < Self.maxNodes, canvas != nil else { return }
        let node = ContentNode(kind: kind, frame: frame, fill: fill)
        let contentDepth = content.undoDepth
        content.add(node)
        noteContentMutation(from: contentDepth)
        placeNodeView(node)
    }
    #endif

    // MARK: - 渲染同步

    private func apply(_ sync: RenderSync) {
        guard let strokeView, !sync.isEmpty else { return }
        if !sync.removedIDs.isEmpty {
            strokeView.removeMeshes(ids: sync.removedIDs)
        }
        for u in sync.upserts {
            strokeView.upsertMesh(id: u.id, mesh: u.mesh, bounds: u.bounds)
        }
        for m in sync.inPlace {
            strokeView.updateMeshInPlace(id: m.id, mesh: m.mesh, bounds: m.bounds)
        }
    }

    // MARK: - 内容节点

    private var content = ContentStore()

    var nodes: [ContentNode] { content.nodes }
    var nodeCount: Int { content.nodes.count }
    var hasNodeSelection: Bool { content.selectedID != nil }
    var selectedNodeID: UUID? { content.selectedID }

    /// nodeID -> 画布内容 ID / 视图
    private var nodeItems: [UUID: CanvasItemID] = [:]
    private var nodeViews: [UUID: ContentNodeView] = [:]
    /// 图片解码缓存（文件名 -> 图）
    private var imageCache: [String: UIImage] = [:]
    /// 节点拖拽状态（预览直接改 view.frame，松手才提交模型）
    private var nodeDrag: (id: UUID, startOrigin: CGPoint, totalDelta: CGSize)?

    /// 便签默认底色
    private static let stickyFill = RGBA(r: 1, g: 0.96, b: 0.65, a: 1)
    /// 节点软上限（每节点一个 UIView，超限拒绝并警告；笔画侧由 Metal 缓冲上限保护）
    private static let maxNodes = 2000

    // MARK: - 节点创建（FAB 调用）

    func addShape(_ shape: ContentShape) {
        insertNode(kind: .shape(shape), text: "", fill: .blue, frameSize: CGSize(width: 180, height: 140))
    }

    func addText() {
        insertNode(kind: .text, text: "文本", fill: .black, frameSize: CGSize(width: 260, height: 90), beginEditing: true)
    }

    func addNote() {
        insertNode(kind: .note, text: "", fill: Self.stickyFill, frameSize: CGSize(width: 200, height: 200), beginEditing: true)
    }

    /// 从图片数据创建节点（PhotosPicker 回调）
    func addImage(data: Data) {
        guard let dir = DrawingStore.documentsDirectory() else { return }
        let image = UIImage(data: data)
        let size = fittedImageSize(image?.size ?? CGSize(width: 400, height: 300))
        do {
            let file = try DrawingStore.saveImageData(data, beside: dir)
            if let image { imageCache[file] = image }
            insertNode(kind: .image, text: "", fill: .white, frameSize: size, imageFile: file)
        } catch {
            print("[DrawingController] save image failed: \(error)")
        }
    }

    /// 图片框：等比，长边不超过 420 世界单位
    private func fittedImageSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 400, height: 300) }
        let s = min(1, 420 / max(size.width, size.height))
        return CGSize(width: max(size.width * s, 40), height: max(size.height * s, 40))
    }

    /// 在视口中心插入节点（级联偏移防重叠），新建即选中
    private func insertNode(
        kind: ContentNodeKind, text: String, fill: RGBA,
        frameSize: CGSize, imageFile: String? = nil, beginEditing: Bool = false
    ) {
        guard let canvas else { return }
        guard content.nodes.count < Self.maxNodes else {
            print("[DrawingController] WARNING: node limit (\(Self.maxNodes)) reached, node dropped")
            return
        }
        let center = canvas.camera.center
        let cascade = CGFloat(content.nodes.count % 8) * 28
        let frame = CGRect(
            x: center.x - frameSize.width * 0.5 + cascade,
            y: center.y - frameSize.height * 0.5 + cascade,
            width: frameSize.width, height: frameSize.height
        )
        let node = ContentNode(kind: kind, frame: frame, text: text, fill: fill, imageFile: imageFile)
        let contentDepth = content.undoDepth
        content.add(node)
        noteContentMutation(from: contentDepth)
        placeNodeView(node)
        content.select(id: node.id)
        store.clearSelection()
        refreshNodeSelection()
        refreshSelectionOverlay()
        scheduleAutosave()
        onChange?()
        if beginEditing {
            nodeViews[node.id]?.textView?.becomeFirstResponder()
        }
    }

    // MARK: - 节点选中（navigate 点按入口）

    /// 导航模式点按：命中节点则选中节点，否则走笔画点选 + 取消节点选中。
    /// 节点 tap 手势与画布 onSingleTap 都会调到这里（幂等）。
    func navigateTap(atScreen screenPoint: CGPoint, hit: UIView?) {
        guard mode == .navigate else { return }
        if let nodeView = hit?.ancestorContentNode() {
            handleNodeTap(nodeView)
            return
        }
        if content.selectedID != nil {
            content.select(id: nil)
            refreshNodeSelection()
        }
        selectTap(atScreen: screenPoint)
    }

    private func handleNodeTap(_ view: ContentNodeView) {
        let already = content.selectedID == view.nodeID
        content.select(id: view.nodeID)
        store.clearSelection()
        refreshNodeSelection()
        refreshSelectionOverlay()
        if already, let tv = view.textView {
            tv.becomeFirstResponder()
        }
        onChange?()
    }

    /// 刷新选中边框 + 文本可编辑态（仅选中节点可编辑）
    private func refreshNodeSelection() {
        let selected = content.selectedID
        for (id, view) in nodeViews {
            let isSel = (id == selected)
            view.isSelected = isSel
            if let tv = view.textView {
                tv.isEditable = isSel
                if !isSel, tv.isFirstResponder {
                    tv.resignFirstResponder()
                }
            }
        }
    }

    // MARK: - 节点拖拽

    private func handleNodePan(_ view: ContentNodeView, _ gesture: UIPanGestureRecognizer) {
        guard let canvas else { return }
        switch gesture.state {
        case .began:
            if content.selectedID != view.nodeID {
                content.select(id: view.nodeID)
                store.clearSelection()
                refreshNodeSelection()
                refreshSelectionOverlay()
                onChange?()
            }
            view.textView?.resignFirstResponder()
            nodeDrag = (view.nodeID, view.frame.origin, .zero)
            gesture.setTranslation(.zero, in: canvas)
        case .changed:
            guard let drag = nodeDrag, drag.id == view.nodeID else { return }
            let t = gesture.translation(in: canvas)
            let scale = max(canvas.camera.scale, 0.01)
            let world = CGSize(width: t.x / scale, height: t.y / scale)
            var frame = view.frame
            frame.origin = CGPoint(x: drag.startOrigin.x + world.width, y: drag.startOrigin.y + world.height)
            view.frame = frame
            nodeDrag = (drag.id, drag.startOrigin, world)
        case .ended:
            guard let drag = nodeDrag else { return }
            nodeDrag = nil
            let contentDepth = content.undoDepth
            let sync = content.move(id: drag.id, by: drag.totalDelta)
            noteContentMutation(from: contentDepth)
            // 模型从旧框 + 同量位移，结果与预览 view.frame 一致，无需回写视图
            if !sync.isEmpty { scheduleAutosave() }
            onChange?()
        case .cancelled, .failed:
            if let drag = nodeDrag, let node = content.node(id: drag.id),
               let item = nodeItems[drag.id] {
                canvas.moveItem(item, to: node.frame)
            }
            nodeDrag = nil
        default:
            break
        }
    }

    // MARK: - 节点视图同步

    private func applyContent(_ sync: ContentSync) {
        guard !sync.isEmpty else { return }
        if !sync.removedIDs.isEmpty {
            removeNodeViews(ids: Set(sync.removedIDs))
        }
        for node in sync.upserts {
            if let item = nodeItems[node.id], let view = nodeViews[node.id] {
                view.sync(with: node, image: cachedImage(for: node))
                canvas?.moveItem(item, to: node.frame)
            } else {
                placeNodeView(node)
            }
        }
        refreshNodeSelection()
    }

    private func placeNodeView(_ node: ContentNode) {
        guard let canvas, nodeViews[node.id] == nil else { return }
        let view = ContentNodeView(node: node, image: cachedImage(for: node))
        view.onTap = { [weak self] v in self?.handleNodeTap(v) }
        view.onPan = { [weak self] v, g in self?.handleNodePan(v, g) }
        view.textView?.delegate = self
        view.isUserInteractionEnabled = (mode == .navigate)
        let item = canvas.place(view, in: node.frame)
        nodeItems[node.id] = item
        nodeViews[node.id] = view
        view.isSelected = (node.id == content.selectedID)
        view.textView?.isEditable = (node.id == content.selectedID)
    }

    private func removeNodeViews(ids: Set<UUID>) {
        guard let canvas else { return }
        for id in ids {
            nodeViews[id]?.textView?.resignFirstResponder()
            if let item = nodeItems[id] { canvas.removeItem(item) }
            nodeItems.removeValue(forKey: id)
            nodeViews.removeValue(forKey: id)
        }
    }

    /// 节点只在 navigate 模式可交互（draw 模式触摸穿透，照常绘画/pan）
    private func updateNodeInteraction() {
        let interactive = (mode == .navigate)
        for view in nodeViews.values {
            view.isUserInteractionEnabled = interactive
            if !interactive {
                view.textView?.resignFirstResponder()
            }
        }
    }

    private func cachedImage(for node: ContentNode) -> UIImage? {
        guard let file = node.imageFile else { return nil }
        if let hit = imageCache[file] { return hit }
        guard let dir = DrawingStore.documentsDirectory(),
              let data = DrawingStore.loadImageData(file: file, beside: dir),
              let image = UIImage(data: data)
        else { return nil }
        imageCache[file] = image
        return image
    }
}

// MARK: - 节点文本编辑

extension DrawingController: UITextViewDelegate {
    func textViewDidBeginEditing(_ textView: UITextView) {
        guard let nodeView = textView.ancestorContentNode() else { return }
        if content.selectedID != nodeView.nodeID {
            content.select(id: nodeView.nodeID)
            store.clearSelection()
            refreshNodeSelection()
            refreshSelectionOverlay()
            onChange?()
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let nodeView = textView.ancestorContentNode() else { return }
        let text = textView.text ?? ""
        nodeView.accessibilityValue = text.isEmpty ? nil : text
        let contentDepth = content.undoDepth
        content.setText(id: nodeView.nodeID, text: text)
        noteContentMutation(from: contentDepth)
        scheduleAutosave()
        onChange?()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        scheduleAutosave()
    }
}

// MARK: - 命中回溯

private extension UIView {
    /// 自己或最近的 ContentNodeView 祖先（节点命中判定用）
    func ancestorContentNode() -> ContentNodeView? {
        var view: UIView? = self
        while let current = view {
            if let node = current as? ContentNodeView { return node }
            view = current.superview
        }
        return nil
    }
}
