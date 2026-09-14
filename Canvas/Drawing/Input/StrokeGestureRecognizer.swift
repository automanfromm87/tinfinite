// StrokeGestureRecognizer.swift
// 笔画触摸识别：单点连续手势，只跟踪第一根按下的手指/笔。
// 经 allowedTouchTypes 过滤触摸类型（笔/手指由 DrawingController 按模式配置）。
// 每次 .changed 携带 coalesced（补点，还原 240Hz 轨迹）+ predicted（降延迟预览）。
//
// 与 pan 的竞速规则（画笔模式单指画线、双指平移的关键）：
// - 笔：零 slop，接触即 began（落笔到出墨之间不留死区），并声明可与画布的
//   pan/pinch/点按并发，避免笔尖只是搁着就把整个手势竞技场独占掉；
// - 手指/指针：touch-down 不立即 began，等挪动超过 beginSlop 才开始，
//   给双指 pan 留出获胜窗口；
// - 一旦出现第 2 根允许类型的触摸且本手势还在 possible，直接自败（.failed），pan 接管；
// - 已经 began 后再落第二指则忽略（笔画继续，不中途打断）。
// 注意只数允许类型的触摸：笔模式下手指 rests 不会导致笔触自败。

import UIKit

/// 笔画触摸跟踪器。target-action 模式：state 变化时读 trackedTouch/pendingCoalesced/pendingPredicted。
final class StrokeGestureRecognizer: UIGestureRecognizer {

    /// 正在跟踪的触摸（仅一根）
    private(set) var trackedTouch: UITouch?
    /// 最近一次 move 的 coalesced 触摸（含主触摸，同 core 逻辑用 event.coalescedTouches）
    private(set) var pendingCoalesced: [UITouch] = []
    /// 最近一次 move 的 predicted 触摸
    private(set) var pendingPredicted: [UITouch] = []

    /// 延迟识别阈值（点）：down 后挪动超过它才 began（点按不足阈值则按点处理）。
    /// 只对手指/指针生效——笔在任何模式下都没有单指竞争者（画笔模式 pan 只收 .direct，
    /// 手指模式 pan 要两指，pinch/撤销点按更要 2~3 指），等 slop 纯粹是白白增加落笔延迟。
    private let beginSlop: CGFloat = 3
    private var downLocation: CGPoint = .zero
    private var hasDownLocation = false

    /// 真实接触点（view 坐标）与时刻：slop 期间被吃掉的笔画头由调用方据此补回
    private(set) var downSampleLocation: CGPoint?
    private(set) var downSampleTime: TimeInterval = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        // 与画布自己的 pan/pinch/点按识别器共存。
        // 必须显式允许：笔是零 slop 的，接触即 .began，而一个已 began 的连续识别器
        // 会把共享同一触摸、又没声明可并发的识别器全部 prevent 掉 —— 笔尖只是搁在
        // 屏幕上时，捏合缩放/双指撤销就再也不会触发了。
        // 真正「不让画布动」的保护不在这里，而在 DrawingController：位移越过阈值
        // 确认在作画后，才关掉 pan/zoom（见 freezeCanvasIfDragging）。
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible else { return }
        // 第 2 根允许类型的触摸落下就自败——必须在 trackedTouch 判空**之前**，
        // 否则已经跟踪第一根手指后这条规则永远不会执行：双指点按时第一根若不动，
        // 抬手时会补发 .began/.ended 提交一个幽灵墨点，并吃掉双指撤销手势。
        if liveAllowedTouches(event).count > 1 {
            trackedTouch = nil
            state = .failed
            return
        }
        guard trackedTouch == nil,
              let touch = touches.first(where: { isTouchAllowed($0) && !isPalm($0) })
        else {
            // 没有允许类型的触摸：这次序列与我无关（保持 possible，让别人识别）
            return
        }
        trackedTouch = touch
        if let v = view {
            downLocation = touch.location(in: v)
            hasDownLocation = true
            if touch.type == .pencil {
                // 笔：零 slop，接触即 began。落笔到第一像素墨迹的死区由此消失。
                // 不设 downSampleLocation —— 这一批 coalesced 点本身就从接触点开始，
                // 而 `touch` 是其中最新的一个，补到队首会造一个「新->旧」的回钩。
                pendingCoalesced = coalesced(for: touch, event: event)
                pendingPredicted = event.predictedTouches(for: touch) ?? []
                state = .began
            } else {
                // 手指/指针仍要等 beginSlop 让位给双指平移；真实接触点先存下来，
                // began 时补回队首，否则笔画头会整体偏移 slop 距离。
                downSampleLocation = downLocation
                downSampleTime = touch.timestamp
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard state == .possible || state == .began || state == .changed else { return }
        guard let tracked = trackedTouch, touches.contains(tracked) else { return }
        if state == .possible {
            if liveAllowedTouches(event).count > 1 {
                state = .failed
                return
            }
            if hasDownLocation, let v = view {
                let loc = tracked.location(in: v)
                if hypot(loc.x - downLocation.x, loc.y - downLocation.y) < beginSlop { return }
            }
            pendingCoalesced = coalesced(for: tracked, event: event)
            pendingPredicted = event.predictedTouches(for: tracked) ?? []
            state = .began
            return
        }
        pendingCoalesced = coalesced(for: tracked, event: event)
        pendingPredicted = event.predictedTouches(for: tracked) ?? []
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard state == .possible || state == .began || state == .changed else { return }
        guard let tracked = trackedTouch, touches.contains(tracked) else { return }
        pendingCoalesced = coalesced(for: tracked, event: event)
        pendingPredicted = []
        if state == .possible {
            // 点按（挪动不足阈值）：补发 began 再结束，形成一个点
            state = .began
        }
        trackedTouch = nil
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard state == .possible || state == .began || state == .changed else { return }
        guard let tracked = trackedTouch, touches.contains(tracked) else { return }
        trackedTouch = nil
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        pendingCoalesced = []
        pendingPredicted = []
        hasDownLocation = false
        downSampleLocation = nil
        downSampleTime = 0
    }

    // MARK: - 内部

    private func isTouchAllowed(_ touch: UITouch) -> Bool {
        // 注意：系统基类同样用 allowedTouchTypes 过滤，且系统把空数组当作
        // “拒绝一切”（见 DrawingController.allTouchTypes 注释），所以调用方
        // 必须永远传非空数组；下面的空分支实际不可达，仅作防御。
        guard !allowedTouchTypes.isEmpty else { return true }
        return allowedTouchTypes.contains(NSNumber(value: touch.type.rawValue))
    }

    /// 当前序列中存活的允许类型触摸（began/moved/stationary，不含已结束的；
    /// 手掌不计入：笔模式下手指 rests 本来就不计数，这里连手指模式的手掌也不计数）
    private func liveAllowedTouches(_ event: UIEvent?) -> [UITouch] {
        (event?.allTouches ?? []).filter {
            isTouchAllowed($0) && !isPalm($0)
                && ($0.phase == .began || $0.phase == .moved || $0.phase == .stationary)
        }
    }

    /// 手掌 resting 判定（大面积 direct 触摸；判据见 PalmRejection 单测）
    private func isPalm(_ touch: UITouch) -> Bool {
        PalmRejection.isLikelyPalm(majorRadius: touch.majorRadius, isDirectTouch: touch.type == .direct)
    }

    private func coalesced(for touch: UITouch, event: UIEvent) -> [UITouch] {
        event.coalescedTouches(for: touch) ?? [touch]
    }
}

// MARK: - 并发识别

extension StrokeGestureRecognizer: UIGestureRecognizerDelegate {
    /// 允许与画布的任何识别器并发。落笔不再独占手势竞技场：
    /// 画布该不该动由 DrawingController 的冻结逻辑决定，而不是由「谁先 began」决定。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
