// OneEuroFilter.swift
// 1€ 滤波器：低速时强平滑、高速时低延迟，适合触控/笔输入去抖。
// 参考：Casiez et al., "1€ Filter: A Simple Speed-based Low-pass Filter..."

import CoreGraphics
import Foundation

/// 一维 1€ 滤波器
nonisolated struct OneEuroFilter: Sendable {
    /// 零速截止频率（Hz）：越大越跟手、越小越平滑
    var minCutoff: CGFloat
    /// 速度斜率：越大高速时延迟越小
    var beta: CGFloat
    /// 速度估计截止频率
    var dcutoff: CGFloat

    private var xPrev: CGFloat?
    private var dxPrev: CGFloat = 0
    private var lastT: TimeInterval?

    init(minCutoff: CGFloat = 25, beta: CGFloat = 0.05, dcutoff: CGFloat = 1) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dcutoff = dcutoff
    }

    mutating func reset() {
        xPrev = nil
        dxPrev = 0
        lastT = nil
    }

    mutating func filter(_ x: CGFloat, at t: TimeInterval) -> CGFloat {
        guard let xp = xPrev, let lt = lastT else {
            xPrev = x
            lastT = t
            dxPrev = 0
            return x
        }
        let dt = max(t - lt, 1e-6)
        // 速度估计（先低通）
        let dx = (x - xp) / dt
        let edx = dxPrev + alpha(cutoff: dcutoff, dt: dt) * (dx - dxPrev)
        // 由速度自适应截止频率
        let cutoff = minCutoff + beta * abs(edx)
        let result = xp + alpha(cutoff: cutoff, dt: dt) * (x - xp)
        xPrev = result
        dxPrev = edx
        lastT = t
        return result
    }

    private func alpha(cutoff: CGFloat, dt: CGFloat) -> CGFloat {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// 二维封装（x/y 各一个滤波器，共用时间戳）
nonisolated struct OneEuroFilter2D: Sendable {
    private var fx: OneEuroFilter
    private var fy: OneEuroFilter

    init(minCutoff: CGFloat = 25, beta: CGFloat = 0.05, dcutoff: CGFloat = 1) {
        fx = OneEuroFilter(minCutoff: minCutoff, beta: beta, dcutoff: dcutoff)
        fy = OneEuroFilter(minCutoff: minCutoff, beta: beta, dcutoff: dcutoff)
    }

    mutating func reset() {
        fx.reset()
        fy.reset()
    }

    mutating func filter(_ p: CGPoint, at t: TimeInterval) -> CGPoint {
        CGPoint(x: fx.filter(p.x, at: t), y: fy.filter(p.y, at: t))
    }
}
