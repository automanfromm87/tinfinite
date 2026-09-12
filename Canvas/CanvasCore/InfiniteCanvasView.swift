// InfiniteCanvasView.swift
// 无限画布核心视图（UIKit）：
// - 内容容器单 CGAffineTransform 做 GPU 合成，与内容数量无关，O(1)
// - 单指/双指拖拽画布、双指捏合缩放（锚点稳定）、双击缩放、松手惯性
// - 手势全程只改本地 camera + 直接改 transform，不经过 SwiftUI，主线程 120Hz 无压力

import UIKit

/// 无限画布。世界坐标系无限大，内容按世界坐标放在 `contentView` 里。
final class InfiniteCanvasView: UIView {

    // MARK: - 内容容器

    /// 所有画布内容都加在这里，子视图 frame 按世界坐标布局。
    /// 本视图只对它施加一个 transform（GPU 合成），不触碰子视图。
    let contentView = UIView()

    // MARK: - 相机状态

    /// 当前相机。手势/惯性/程序化导航都走这里。
    /// 直接设值 = 立即生效（transient=false 回调）；手势过程中以 transient=true 高频回调。
    var camera: Camera {
        get { _camera }
        set { setCamera(newValue, transient: false) }
    }
    private var _camera: Camera = .default

    /// 缩放范围（世界单位->屏幕点的倍数上下限）
    var zoomRange: ClosedRange<CGFloat> = Camera.defaultZoomRange {
        didSet { camera = camera.clamped(to: zoomRange) }
    }

    /// 是否允许单指拖拽（默认 true；画笔模式下可关掉，由上层接管触摸）
    var isPanEnabled = true
    /// 是否允许捏合缩放（默认 true）
    var isZoomEnabled = true
    /// 是否允许松手惯性（默认 true）
    var isInertiaEnabled = true

    /// 相机变化回调。transient=true 表示手势/惯性进行中（高频），false 表示一次交互结束或程序化设置。
    /// 注意：回调频率可达 120Hz，回调里只做轻量工作（重算 transform 已在本类内部完成）。
    var onCameraChange: ((Camera, Viewport, Bool) -> Void)?

    /// 当前视口（派生值，O(1) 构造）
    var viewport: Viewport {
        Viewport(camera: _camera, size: bounds.size)
    }

    /// 点按回调（点选）：无拖动抬起时立即触发（不等待双击失败，保证选中即时反馈）。
    /// point 为画布坐标系位置，hit 为命中最深视图；上层据 hit 归属决定选中/取消选中。
    var onSingleTap: ((CGPoint, UIView?) -> Void)?

    /// 键盘动作（需 drawing/model 配合，经此闭包转给 SwiftUI 侧；按键永远在主线程到达）
    var onKeyAction: ((CanvasKeyAction) -> Void)?

    // MARK: - 手势

    private let panRecognizer = UIPanGestureRecognizer()
    private let pinchRecognizer = UIPinchGestureRecognizer()
    private let doubleTapRecognizer = UITapGestureRecognizer()
    private let undoTapRecognizer = UITapGestureRecognizer()
    private let redoTapRecognizer = UITapGestureRecognizer()

    /// 撤销/重做手势开关（落笔过程中由 DrawingController 关掉，
    /// 避免第二根手指点按在 live 笔画中途触发 undo）
    var isUndoGestureEnabled = true

    /// 点按跟踪（touch-up 即时确认点选，不经过 UITapGestureRecognizer 的双击等待）
    private var tapDownPoint: CGPoint?
    /// 点按位移容差（点）：超过则视为拖拽开始，不再算点按
    private let tapSlop: CGFloat = 10

    /// 手势访问口（供 DrawingController 等上层协调触摸策略）
    var panGesture: UIPanGestureRecognizer { panRecognizer }
    var pinchGesture: UIPinchGestureRecognizer { pinchRecognizer }
    var doubleTapGesture: UITapGestureRecognizer { doubleTapRecognizer }

    /// 惯性滚动驱动
    private var inertiaLink: CADisplayLink?
    private var inertiaVelocity: CGPoint = .zero // 屏幕点/秒
    private var inertiaLastTime: CFTimeInterval = 0

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .systemBackground

        contentView.backgroundColor = .clear
        // 内容可能在世界任意位置，容器本身不裁剪（由本视图 bounds 裁剪）
        contentView.clipsToBounds = false
        contentView.isUserInteractionEnabled = true
        addSubview(contentView)

        clipsToBounds = true

        panRecognizer.maximumNumberOfTouches = 2
        panRecognizer.delegate = self
        panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        addGestureRecognizer(panRecognizer)

        pinchRecognizer.delegate = self
        pinchRecognizer.addTarget(self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinchRecognizer)

        doubleTapRecognizer.numberOfTapsRequired = 2
        doubleTapRecognizer.delegate = self
        doubleTapRecognizer.addTarget(self, action: #selector(handleDoubleTap(_:)))
        addGestureRecognizer(doubleTapRecognizer)

        // 双指点按撤销 / 三指点按重做（Procreate 同款手势）。
        // 与 pan/pinch 天然互斥：点按无位移，pan/pinch 不会 began；手指一动 tap 即失败。
        undoTapRecognizer.numberOfTouchesRequired = 2
        undoTapRecognizer.delegate = self
        undoTapRecognizer.addTarget(self, action: #selector(handleUndoTap(_:)))
        addGestureRecognizer(undoTapRecognizer)

        redoTapRecognizer.numberOfTouchesRequired = 3
        redoTapRecognizer.delegate = self
        redoTapRecognizer.addTarget(self, action: #selector(handleRedoTap(_:)))
        addGestureRecognizer(redoTapRecognizer)

        // pinch 与点按的竞速见下方 shouldBeRequiredToFailBy（动态裁决）

        applyTransform()
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        // 容器几何恒等于本视图，世界->屏幕映射全部由 transform 承担
        contentView.bounds = CGRect(origin: .zero, size: bounds.size)
        contentView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        applyTransform()
        // 尺寸变化 => 视口变化，通知一次（非 transient）
        notify(transient: false)
    }

    // MARK: - 坐标变换 API

    func worldToScreen(_ world: CGPoint) -> CGPoint {
        _camera.worldToScreen(world, viewSize: bounds.size)
    }

    func screenToWorld(_ screen: CGPoint) -> CGPoint {
        _camera.screenToWorld(screen, viewSize: bounds.size)
    }

    // MARK: - 程序化导航

    /// 设置相机，可选动画。动画用 UIView 动画块插值 transform（GPU 侧插值，不阻塞主线程计算）。
    func setCamera(_ camera: Camera, animated: Bool, duration: TimeInterval = 0.3) {
        cancelInertia()
        let target = camera.clamped(to: zoomRange)
        guard animated else {
            setCamera(target, transient: false)
            return
        }
        // 动画期间分步更新 _camera，保证结束状态与回调一致
        _camera = target
        UIView.animate(
            withDuration: duration, delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
            animations: { self.applyTransform() },
            completion: { _ in
                self.applyTransform()
                self.notify(transient: false)
            }
        )
        // 动画开始即通知一次（transient=false），让 HUD/网格跟上终态
        notify(transient: false)
    }

    /// 把世界矩形完整显示在视野内
    func zoom(to worldRect: CGRect, padding: CGFloat = 40, animated: Bool = true) {
        guard worldRect.width > 0, worldRect.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let fitScale = min(
            (bounds.width - padding * 2) / worldRect.width,
            (bounds.height - padding * 2) / worldRect.height
        )
        setCamera(
            Camera(
                center: CGPoint(x: worldRect.midX, y: worldRect.midY),
                scale: fitScale
            ),
            animated: animated
        )
    }

    /// 把世界点移到视图中心（保持缩放）
    func center(on worldPoint: CGPoint, animated: Bool = true) {
        setCamera(Camera(center: worldPoint, scale: _camera.scale), animated: animated)
    }

    /// 回到原点 1x
    func reset(animated: Bool = true) {
        setCamera(.default, animated: animated)
    }

    // MARK: - 内部：状态应用

    private func setCamera(_ camera: Camera, transient: Bool) {
        let clamped = camera.clamped(to: zoomRange)
        guard clamped != _camera else { return }
        _camera = clamped
        applyTransform()
        notify(transient: transient)
    }

    /// 核心热路径：只改一个 transform。O(1)，与内容数量无关。
    private func applyTransform() {
        contentView.transform = _camera.contentTransform(viewSize: bounds.size)
    }

    private func notify(transient: Bool) {
        onCameraChange?(_camera, viewport, transient)
    }

    // MARK: - 手势处理

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard isPanEnabled else { return }
        cancelInertia()
        switch recognizer.state {
        case .began, .changed:
            let delta = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            // 双指 pan 时 translation 是质心位移，天然支持“双指拖动画布”
            setCamera(_camera.panned(by: CGSize(width: delta.x, height: delta.y)), transient: true)
        case .ended, .cancelled, .failed:
            if isInertiaEnabled {
                let v = recognizer.velocity(in: self)
                startInertia(velocity: CGPoint(x: v.x, y: v.y))
            } else {
                notify(transient: false)
            }
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard isZoomEnabled else { return }
        cancelInertia()
        switch recognizer.state {
        case .began, .changed:
            // 锚点取两指中点（location 是单指/质心位置，取触摸中点更稳）
            let anchor = pinchAnchorPoint(recognizer)
            setCamera(
                _camera.zoomed(
                    by: recognizer.scale,
                    anchoredAtScreen: anchor,
                    viewSize: bounds.size,
                    range: zoomRange
                ),
                transient: true
            )
            recognizer.scale = 1
        case .ended, .cancelled, .failed:
            notify(transient: false)
        default:
            break
        }
    }

    @objc private func handleUndoTap(_ recognizer: UITapGestureRecognizer) {
        guard isUndoGestureEnabled else { return }
        onKeyAction?(.undo)
    }

    @objc private func handleRedoTap(_ recognizer: UITapGestureRecognizer) {
        guard isUndoGestureEnabled else { return }
        onKeyAction?(.redo)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard isZoomEnabled else { return }
        let point = recognizer.location(in: self)
        if _camera.scale < zoomRange.upperBound * 0.4 {
            setCamera(
                _camera.zoomed(by: 2, anchoredAtScreen: point, viewSize: bounds.size, range: zoomRange),
                animated: true, duration: 0.25
            )
        } else {
            // 已放大较多时双击回到 1x（以点击处为中心）
            setCamera(Camera(center: screenToWorld(point), scale: 1), animated: true, duration: 0.25)
        }
    }

    /// 两指触摸中点；单指时退化为 location
    private func pinchAnchorPoint(_ recognizer: UIPinchGestureRecognizer) -> CGPoint {
        guard recognizer.numberOfTouches >= 2 else {
            return recognizer.location(in: self)
        }
        let a = recognizer.location(ofTouch: 0, in: self)
        let b = recognizer.location(ofTouch: 1, in: self)
        return CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
    }

    // MARK: - 惯性

    private func startInertia(velocity: CGPoint) {
        let speed = hypot(velocity.x, velocity.y)
        guard speed > 60 else {
            notify(transient: false)
            return
        }
        cancelInertia()
        inertiaVelocity = velocity
        inertiaLastTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepInertia(_:)))
        // 与屏幕同频即可，不指定 preferredFrameRateRange（省电由系统调度）
        link.add(to: .main, forMode: .common)
        inertiaLink = link
    }

    @objc private func stepInertia(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        var dt = now - inertiaLastTime
        inertiaLastTime = now
        // 后台回来等极端情况钳住 dt，避免一次跳太远
        dt = min(max(dt, 0), 1.0 / 20.0)

        // 指数衰减：~0.94/frame @60Hz，换算到 dt
        let decay = pow(0.94, dt * 60.0)
        inertiaVelocity.x *= decay
        inertiaVelocity.y *= decay

        let speed = hypot(inertiaVelocity.x, inertiaVelocity.y)
        guard speed > 20 else {
            cancelInertia()
            notify(transient: false)
            return
        }

        let delta = CGSize(
            width: inertiaVelocity.x * dt,
            height: inertiaVelocity.y * dt
        )
        setCamera(_camera.panned(by: delta), transient: true)
    }

    private func cancelInertia() {
        inertiaLink?.invalidate()
        inertiaLink = nil
        inertiaVelocity = .zero
    }

    // MARK: - 键盘

    override var canBecomeFirstResponder: Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 首次触摸即抢焦点，保证快捷键可用（文本编辑时会由输入框接管）
        if window != nil, !isFirstResponder {
            _ = becomeFirstResponder()
        }
        // 点按跟踪：严格单指序列才候选，多指/已有候选则作废
        if tapDownPoint == nil, touches.count == 1, (event?.allTouches?.count ?? 1) == 1,
           let point = touches.first?.location(in: self) {
            tapDownPoint = point
        } else {
            tapDownPoint = nil
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let down = tapDownPoint, let loc = touches.first?.location(in: self),
           hypot(loc.x - down.x, loc.y - down.y) > tapSlop {
            tapDownPoint = nil
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 无拖动抬起 = 点按：touch-up 立即确认（不等双击识别器）
        if let down = tapDownPoint, touches.count == 1 {
            tapDownPoint = nil
            onSingleTap?(down, hitTest(down, with: nil))
        }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        tapDownPoint = nil
        super.touchesCancelled(touches, with: event)
    }

    override var keyCommands: [UIKeyCommand]? {
        func key(_ input: String, flags: UIKeyModifierFlags = [], title: String, tag: Int) -> UIKeyCommand {
            UIKeyCommand(
                title: title, image: nil, action: #selector(handleKey(_:)),
                input: input, modifierFlags: flags, propertyList: tag,
                alternates: [], discoverabilityTitle: title
            )
        }
        return [
            key("z", flags: .command, title: "撤销", tag: 1),
            key("z", flags: [.command, .shift], title: "重做", tag: 2),
            key(UIKeyCommand.inputDelete, title: "删除选中", tag: 3),
            key(UIKeyCommand.inputEscape, title: "取消选择", tag: 4),
            key("v", title: "抓手", tag: 5),
            key("p", title: "画笔", tag: 6),
            key("b", title: "画笔", tag: 6),
            key("e", title: "橡皮", tag: 7),
            key("l", title: "套索", tag: 8),
            key("g", title: "网格开关", tag: 9),
            key("+", title: "放大", tag: 10),
            key("=", title: "放大", tag: 10),
            key("-", title: "缩小", tag: 11),
            key("0", title: "复位视角", tag: 12),
            key("f", title: "适合内容", tag: 17),
            key(UIKeyCommand.inputUpArrow, title: "平移", tag: 13),
            key(UIKeyCommand.inputUpArrow, flags: .shift, title: "平移", tag: 13),
            key(UIKeyCommand.inputDownArrow, title: "平移", tag: 14),
            key(UIKeyCommand.inputDownArrow, flags: .shift, title: "平移", tag: 14),
            key(UIKeyCommand.inputLeftArrow, title: "平移", tag: 15),
            key(UIKeyCommand.inputLeftArrow, flags: .shift, title: "平移", tag: 15),
            key(UIKeyCommand.inputRightArrow, title: "平移", tag: 16),
            key(UIKeyCommand.inputRightArrow, flags: .shift, title: "平移", tag: 16),
        ]
    }

    @objc private func handleKey(_ command: UIKeyCommand) {
        guard let tag = command.propertyList as? Int else { return }
        let step: CGFloat = command.modifierFlags.contains(.shift) ? 200 : 40
        let action: CanvasKeyAction?
        switch tag {
        case 1: action = .undo
        case 2: action = .redo
        case 3: action = .deleteSelection
        case 4: action = .clearSelection
        case 5: action = .toolNavigate
        case 6: action = .toolPen
        case 7: action = .toolEraser
        case 8: action = .toolLasso
        case 9: action = .toggleGrid
        case 10: action = .zoomIn
        case 11: action = .zoomOut
        case 12: action = .resetCamera
        case 17: action = .fitContent
        case 13: action = .panBy(CGSize(width: 0, height: -step))
        case 14: action = .panBy(CGSize(width: 0, height: step))
        case 15: action = .panBy(CGSize(width: -step, height: 0))
        case 16: action = .panBy(CGSize(width: step, height: 0))
        default: action = nil
        }
        if let action { onKeyAction?(action) }
    }

    // 空格抓手：按住临时切 navigate，松开恢复（UIKeyCommand 收不到抬起，用 presses）
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isSpacePress(presses) {
            onKeyAction?(.spacePan(active: true))
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isSpacePress(presses) {
            onKeyAction?(.spacePan(active: false))
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isSpacePress(presses) {
            onKeyAction?(.spacePan(active: false))
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    private func isSpacePress(_ presses: Set<UIPress>) -> Bool {
        presses.contains(where: { $0.key?.keyCode == UIKeyboardHIDUsage.keyboardSpacebar })
    }
}

/// 画布键盘动作（SwiftUI 侧执行）
enum CanvasKeyAction {
    case undo, redo
    case deleteSelection, clearSelection
    case toolNavigate, toolPen, toolEraser, toolLasso
    case toggleGrid
    case zoomIn, zoomOut, resetCamera, fitContent
    /// 内容期望的屏幕位移（与手指拖拽同向）
    case panBy(CGSize)
    /// 空格抓手按下/松开
    case spacePan(active: Bool)
}

// MARK: - UIGestureRecognizerDelegate

extension InfiniteCanvasView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // pan 与 pinch 必须同时识别：双指“边拖边缩”是无限画布的核心手感
        let ours: [UIGestureRecognizer] = [panRecognizer, pinchRecognizer]
        return ours.contains(gestureRecognizer) && ours.contains(otherGestureRecognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // pinch 在第二指落下即 began，会抢先置 fail 掉点按手势，所以 pinch
        // 必须等点按先判。但不能静态 require（双指 pinch 时三指点按永远
        // Possible，会把 pinch 卡到抬手），按当前触摸数动态裁决：
        // - 2 指：等双指撤销点按（手指一动它即失败，pinch 几乎无延迟）
        // - 3 指：等三指重做点按（双指点按在第三指落下时已因超数自败）
        // pan 靠位移 began，不抢点按，无需排序。
        guard gestureRecognizer === pinchRecognizer else { return false }
        let touches = pinchRecognizer.numberOfTouches
        if otherGestureRecognizer === undoTapRecognizer { return touches == 2 }
        if otherGestureRecognizer === redoTapRecognizer { return touches >= 3 }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 落在内容节点上的触摸：pan/双击/撤销点按让路（节点自己的 tap/pan 接管选中与拖拽，
        // 文本框走系统键盘撤销，不抢）。
        // 节点只在 navigate 模式可交互（draw 模式 isUserInteractionEnabled=false，
        // 命中测试直接跳过，触摸照常落到画布上）。
        if gestureRecognizer === panRecognizer || gestureRecognizer === doubleTapRecognizer
            || gestureRecognizer === undoTapRecognizer || gestureRecognizer === redoTapRecognizer
        {
            var view: UIView? = touch.view
            while let current = view {
                if current is ContentNodeView { return false }
                view = current.superview
            }
        }
        return true
    }
}
