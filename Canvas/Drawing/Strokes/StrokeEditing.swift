// StrokeEditing.swift
// 笔画编辑纯数学：橡皮命中/擦除分段、套索命中/点选。全部世界坐标，无 UIKit。

import CoreGraphics
import Foundation

// MARK: - 线段基础（文件内共享）

/// 点到线段距离
nonisolated private func pointToSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let abx = b.x - a.x
    let aby = b.y - a.y
    let denom = abx * abx + aby * aby
    if denom < 1e-18 {
        return hypot(p.x - a.x, p.y - a.y)
    }
    var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / denom
    t = min(max(t, 0), 1)
    return hypot(p.x - (a.x + abx * t), p.y - (a.y + aby * t))
}

/// 点到折线距离（单点折线退化为点距，空折线返回无穷）
nonisolated private func pointToPolylineDistance(_ p: CGPoint, _ poly: [CGPoint]) -> CGFloat {
    guard !poly.isEmpty else { return .infinity }
    if poly.count == 1 { return hypot(p.x - poly[0].x, p.y - poly[0].y) }
    var best = CGFloat.infinity
    for i in 1..<poly.count {
        best = min(best, pointToSegmentDistance(p, poly[i - 1], poly[i]))
    }
    return best
}

/// 两线段是否相交（含端点接触）
nonisolated private func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
    let eps: CGFloat = 1e-9
    func orient(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    func onSegment(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        min(a.x, c.x) - eps <= b.x && b.x <= max(a.x, c.x) + eps &&
            min(a.y, c.y) - eps <= b.y && b.y <= max(a.y, c.y) + eps
    }
    let d1 = orient(p3, p4, p1)
    let d2 = orient(p3, p4, p2)
    let d3 = orient(p1, p2, p3)
    let d4 = orient(p1, p2, p4)
    if ((d1 > eps && d2 < -eps) || (d1 < -eps && d2 > eps)) &&
        ((d3 > eps && d4 < -eps) || (d3 < -eps && d4 > eps)) {
        return true
    }
    if abs(d1) <= eps && onSegment(p3, p1, p4) { return true }
    if abs(d2) <= eps && onSegment(p3, p2, p4) { return true }
    if abs(d3) <= eps && onSegment(p1, p3, p2) { return true }
    if abs(d4) <= eps && onSegment(p1, p4, p2) { return true }
    return false
}

/// 点是否在多边形内（射线法，多边形自动闭合；<3 点恒 false）
nonisolated private func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
    guard poly.count >= 3 else { return false }
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let a = poly[i]
        let b = poly[j]
        if (a.y > p.y) != (b.y > p.y) {
            let slope = (b.x - a.x) / (b.y - a.y)
            if p.x < a.x + slope * (p.y - a.y) {
                inside.toggle()
            }
        }
        j = i
    }
    return inside
}

// MARK: - 橡皮

nonisolated enum EraserHitTest {
    /// 整笔命中：任一 spine 点进入“笔宽/2 + 橡皮半径”
    static func strokeHit(spine: [SpinePoint], path: [CGPoint], eraserRadius: CGFloat) -> Bool {
        guard path.count >= 2, !spine.isEmpty else { return false }
        for s in spine {
            if pointToPolylineDistance(s.center, path) < s.width * 0.5 + eraserRadius {
                return true
            }
        }
        return false
    }

    /// 局部擦除：返回保留的 spine 连续段（runs）。
    /// - 未命中 -> [原 spine]；全擦光 -> []；擦中段 -> 多段
    static func eraseRuns(spine: [SpinePoint], path: [CGPoint], eraserRadius: CGFloat) -> [[SpinePoint]] {
        guard path.count >= 2, !spine.isEmpty else { return spine.isEmpty ? [] : [spine] }
        var runs: [[SpinePoint]] = []
        var current: [SpinePoint] = []
        for s in spine {
            let erased = pointToPolylineDistance(s.center, path) < s.width * 0.5 + eraserRadius
            if erased {
                if !current.isEmpty {
                    runs.append(current)
                    current = []
                }
            } else {
                current.append(s)
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

// MARK: - 套索

nonisolated enum LassoHitTest {
    /// 点是否在套索圈内
    static func pointInLoop(_ p: CGPoint, loop: [CGPoint]) -> Bool {
        pointInPolygon(p, loop)
    }

    /// 笔画是否与套索圈相交：任一 spine 点在圈内，或任一 spine 线段穿过圈边
    static func strokeIntersectsLoop(spine: [SpinePoint], loop: [CGPoint]) -> Bool {
        guard loop.count >= 3, !spine.isEmpty else { return false }
        for s in spine {
            if pointInPolygon(s.center, loop) { return true }
        }
        if spine.count >= 2 {
            for i in 1..<spine.count {
                let a = spine[i - 1].center
                let b = spine[i].center
                var prev = loop[loop.count - 1]
                for edge in loop {
                    if segmentsIntersect(a, b, prev, edge) { return true }
                    prev = edge
                }
            }
        }
        return false
    }

    /// 点选命中：spine 进入“笔宽/2 + 半径”
    static func tapHit(spine: [SpinePoint], point: CGPoint, radius: CGFloat) -> Bool {
        guard !spine.isEmpty else { return false }
        for s in spine {
            if hypot(s.center.x - point.x, s.center.y - point.y) < s.width * 0.5 + radius {
                return true
            }
        }
        return false
    }
}
