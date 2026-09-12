// PalmRejection.swift
// 手掌防误触纯逻辑（可单测）：大面积 direct 触摸视为手掌 resting，不起笔。

import CoreGraphics
import Foundation

nonisolated enum PalmRejection {
    /// 手掌判定阈值（点）：手指 majorRadius 通常 8~15，手掌 resting 30+，
    /// 取 26 留余量；iOS 不保证所有设备上报精确值，只做"明显手掌"过滤
    static let palmMajorRadius: CGFloat = 26

    /// 是否疑似手掌（只看 direct 触摸：笔/鼠标/触控板永远不是手掌）
    static func isLikelyPalm(majorRadius: CGFloat, isDirectTouch: Bool) -> Bool {
        guard isDirectTouch else { return false }
        guard majorRadius > 0, majorRadius.isFinite else { return false }
        return majorRadius >= palmMajorRadius
    }
}
