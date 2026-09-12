// StrokeGestureRecognizer.swift
// 笔画触摸识别：单点连续手势，只跟踪第一根按下的手指/笔。
// 经 allowedTouchTypes 过滤触摸类型（笔/手指由 DrawingController 按模式配置）。
// 每次 .changed 携带 coalesced（补点，还原 240Hz 轨迹）+ predicted（降延迟预览）。
//
// 与 pan 的竞速规则（画笔模式单指画线、双指平移的关键）：
// - touch-down 不立即 began：等挪动超过 beginSlop 才开始，给双指 pan 留出获胜窗口；
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

    /// 延迟识别阈值（点）：down 后挪动超过它才 began（点按不足阈值则按点处理）
    private let beginSlop: CGFloat = 3
    private var downLocation: CGPoint = .zero
    private var hasDownLocation = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible, trackedTouch == nil else { return }
        if liveAllowedTouches(event).count > 1 {
            state = .failed
            return
        }
        guard let touch = touches.first(where: { isTouchAllowed($0) && !isPalm($0) }) else {
            // 没有允许类型的触摸：这次序列与我无关（保持 possible，让别人识别）
            return
        }
        trackedTouch = touch
        if let v = view {
            downLocation = touch.location(in: v)
            hasDownLocation = true
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
