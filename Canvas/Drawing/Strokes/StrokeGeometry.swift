// StrokeGeometry.swift
// 笔画几何（纯数学）：spine 中线 -> Catmull-Rom 转三次 Bézier -> 自适应 flatten ->
// 逐点法线 ribbon（左右轮廓）+ 首尾圆头 -> 世界坐标 triangle mesh。
// 逐点法线 ribbon 天然无 miter 尖刺；圆头用扇形三角拼。

import CoreGraphics
import Foundation

nonisolated enum StrokeGeometry {

    /// 最小笔宽钳制（世界单位），防止压力 0 处退化
    static let minWidth: CGFloat = 0.05
    /// 展平安全上限（采样数），防病态输入爆内存
    static let maxSamples = 100_000

    // MARK: - 主入口

    /// spine -> mesh。全量重建（live 笔画每事件调一次，O(n)，n 通常 < 1 万，单次 < 1ms）。
    /// - Parameter grain: 颗粒强度 0...1（铅笔纹理）：逐顶点确定性 alpha 抖动，
    ///   同输入恒同输出（LOD/导出一致）；0 = 关闭，与旧输出逐字节一致。
    static func tessellate(
        spine: [SpinePoint],
        color: RGBA,
        flattenTolerance: CGFloat = 0.12,
        capSegments: Int = 10,
        grain: CGFloat = 0
    ) -> StrokeMesh {
        let clean = cleaned(spine)
        guard !clean.isEmpty else { return .empty }
        // 顶点色：样式色 × 采样点透明度（倾斜响应）× 颗粒抖动
        func vertexColor(alpha: CGFloat, vertexIndex: Int) -> RGBA {
            var c = color
            var a = color.a * Float(min(max(alpha, 0), 1))
            if grain > 0 {
                a *= Float(1 - min(max(grain, 0), 1) * grainHash(vertexIndex))
            }
            c.a = a
            return c
        }
        if clean.count == 1 || totalLength(clean) < 1e-9 {
            let w = clean.map(\.width).max() ?? minWidth
            let alpha = clean[0].alpha
            return disc(
                center: clean[0].center, radius: max(w, minWidth) * 0.5,
                segments: max(capSegments * 2, 16),
                tint: { vertexColor(alpha: alpha, vertexIndex: $0) }
            )
        }

        // 1. Catmull-Rom -> Bézier 分段 + 自适应展平（含宽度/透明度插值）
        var samples: [(point: CGPoint, width: CGFloat, alpha: CGFloat)] = []
        samples.reserveCapacity(clean.count * 4)
        samples.append((clean[0].center, clean[0].width, clean[0].alpha))
        for i in 0..<(clean.count - 1) {
            let p0 = clean[max(0, i - 1)].center
            let p1 = clean[i].center
            let p2 = clean[i + 1].center
            let p3 = clean[min(clean.count - 1, i + 2)].center
            flattenCubic(
                p0: p1,
                c1: p1 + (p2 - p0) / 6,
                c2: p2 - (p3 - p1) / 6,
                p3: p2,
                w0: clean[i].width, w1: clean[i + 1].width,
                a0: clean[i].alpha, a1: clean[i + 1].alpha,
                t0: 0, t1: 1,
                tolerance: flattenTolerance,
                depth: 0,
                into: &samples
            )
            if samples.count > maxSamples { break }
        }

        // 2. 逐点切线/法线 -> ribbon
        let n = samples.count
        var vertices: [StrokeVertex] = []
        vertices.reserveCapacity(n * 2 + capSegments * 2 + 2)
        var indices: [UInt32] = []
        indices.reserveCapacity((n - 1) * 6 + capSegments * 6)

        for i in 0..<n {
            let prev = samples[max(0, i - 1)].point
            let next = samples[min(n - 1, i + 1)].point
            var t = next - prev
            let len = hypot(t.x, t.y)
            if len > 1e-12 {
                t = t / len
            } else {
                t = CGPoint(x: 1, y: 0)
            }
            let normal = CGPoint(x: -t.y, y: t.x)
            let hw = max(samples[i].width, minWidth) * 0.5
            let c = vertexColor(alpha: samples[i].alpha, vertexIndex: vertices.count)
            vertices.append(StrokeVertex(position: samples[i].point + normal * hw, color: c))
            vertices.append(StrokeVertex(position: samples[i].point - normal * hw, color: c))
        }
        for i in 0..<(n - 1) {
            let b = UInt32(i * 2)
            indices.append(contentsOf: [b, b + 1, b + 2, b + 1, b + 3, b + 2])
        }

        // 3. 首尾圆头（半圆扇形，端点透明度）
        let t0 = tangentOf(samples, at: 0)
        let t1 = tangentOf(samples, at: n - 1)
        let headAlpha = samples[0].alpha
        appendCap(
            center: samples[0].point, radius: max(samples[0].width, minWidth) * 0.5,
            facing: -t0, segments: capSegments,
            tint: { vertexColor(alpha: headAlpha, vertexIndex: $0) },
            vertices: &vertices, indices: &indices
        )
        let tailAlpha = samples[n - 1].alpha
        appendCap(
            center: samples[n - 1].point, radius: max(samples[n - 1].width, minWidth) * 0.5,
            facing: t1, segments: capSegments,
            tint: { vertexColor(alpha: tailAlpha, vertexIndex: $0) },
            vertices: &vertices, indices: &indices
        )

        return StrokeMesh(vertices: vertices, indices: indices)
    }

    /// 确定性颗粒哈希（0..<1）：同顶点序号恒同值，与平台/随机源无关
    static func grainHash(_ index: Int) -> CGFloat {
        let x = sin(CGFloat(index) * 12.9898) * 43758.5453
        return x - floor(x)
    }

    /// mesh 平移（移动笔画用，顶点数/索引数不变，可原地写回 GPU 缓冲）
    static func translated(_ mesh: StrokeMesh, by delta: CGSize) -> StrokeMesh {
        guard delta.width != 0 || delta.height != 0 else { return mesh }
        let dx = Float(delta.width)
        let dy = Float(delta.height)
        var verts = mesh.vertices
        for i in verts.indices {
            verts[i].x += dx
            verts[i].y += dy
        }
        return StrokeMesh(vertices: verts, indices: mesh.indices)
    }

    // MARK: - LOD

    /// LOD 容差：屏幕目标误差（点）-> 世界展平容差。缩放越大容差越小，细节恒定。
    static func lodTolerance(forScale scale: CGFloat, screenError: CGFloat = 0.35) -> CGFloat {
        guard scale > 0 else { return screenError }
        return min(max(screenError / scale, 0.002), 4)
    }

    /// 缩放变化是否值得重 tessellate（比例超阈值，避免频繁重建）
    static func lodNeedsUpdate(from oldScale: CGFloat, to newScale: CGFloat, threshold: CGFloat = 1.5) -> Bool {
        guard oldScale > 0, newScale > 0, threshold > 1 else { return false }
        let ratio = newScale / oldScale
        return ratio >= threshold || ratio <= 1 / threshold
    }

    /// spine 的世界包围盒（外扩最大半宽），用于裁剪
    static func bounds(of spine: [SpinePoint]) -> CGRect {
        guard !spine.isEmpty else { return .null }
        var rect = CGRect(origin: spine[0].center, size: .zero)
        var maxHalf: CGFloat = 0
        for s in spine {
            rect = rect.union(CGRect(origin: s.center, size: .zero))
            maxHalf = max(maxHalf, s.width * 0.5)
        }
        return rect.insetBy(dx: -maxHalf, dy: -maxHalf)
    }

    // MARK: - 圆盘（点按成点）

    private static func disc(
        center: CGPoint, radius: CGFloat, segments: Int, tint: (Int) -> RGBA
    ) -> StrokeMesh {
        var vertices: [StrokeVertex] = [StrokeVertex(position: center, color: tint(0))]
        var indices: [UInt32] = []
        for i in 0...segments {
            let a = CGFloat(i) / CGFloat(segments) * 2 * .pi
            vertices.append(StrokeVertex(
                position: CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a)),
                color: tint(vertices.count)
            ))
        }
        for i in 0..<segments {
            indices.append(contentsOf: [0, UInt32(i + 1), UInt32(i + 2)])
        }
        return StrokeMesh(vertices: vertices, indices: indices)
    }

    // MARK: - 自适应展平（de Casteljau，带宽度插值）

    private static func flattenCubic(
        p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint,
        w0: CGFloat, w1: CGFloat, a0: CGFloat, a1: CGFloat, t0: CGFloat, t1: CGFloat,
        tolerance: CGFloat,
        depth: Int,
        into out: inout [(point: CGPoint, width: CGFloat, alpha: CGFloat)]
    ) {
        // 平直测试：控制点到弦的最大距离
        let d1 = distanceFromPointToLine(c1, lineA: p0, lineB: p3)
        let d2 = distanceFromPointToLine(c2, lineA: p0, lineB: p3)
        if max(d1, d2) <= tolerance || depth >= 12 {
            out.append((p3, w0 + (w1 - w0) * t1, a0 + (a1 - a0) * t1))
            return
        }
        // t=0.5 分割
        let m1 = (p0 + c1) / 2
        let m2 = (c1 + c2) / 2
        let m3 = (c2 + p3) / 2
        let n1 = (m1 + m2) / 2
        let n2 = (m2 + m3) / 2
        let mid = (n1 + n2) / 2
        let tm = (t0 + t1) / 2
        flattenCubic(p0: p0, c1: m1, c2: n1, p3: mid, w0: w0, w1: w1, a0: a0, a1: a1, t0: t0, t1: tm, tolerance: tolerance, depth: depth + 1, into: &out)
        flattenCubic(p0: mid, c1: n2, c2: m3, p3: p3, w0: w0, w1: w1, a0: a0, a1: a1, t0: tm, t1: t1, tolerance: tolerance, depth: depth + 1, into: &out)
    }

    // MARK: - 圆头

    private static func appendCap(
        center: CGPoint, radius: CGFloat, facing: CGPoint,
        segments: Int, tint: (Int) -> RGBA,
        vertices: inout [StrokeVertex], indices: inout [UInt32]
    ) {
        let base = hypot(facing.x, facing.y) > 1e-12 ? atan2(facing.y, facing.x) : 0
        let centerIndex = UInt32(vertices.count)
        vertices.append(StrokeVertex(position: center, color: tint(vertices.count)))
        // 半圆：base-90° ... base+90°（朝 facing 方向）
        for i in 0...segments {
            let a = base - .pi / 2 + CGFloat(i) / CGFloat(segments) * .pi
            vertices.append(StrokeVertex(
                position: CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a)),
                color: tint(vertices.count)
            ))
        }
        for i in 0..<segments {
            indices.append(contentsOf: [centerIndex, centerIndex + UInt32(i + 1), centerIndex + UInt32(i + 2)])
        }
    }

    // MARK: - 小工具

    private static func cleaned(_ spine: [SpinePoint]) -> [SpinePoint] {
        var out: [SpinePoint] = []
        out.reserveCapacity(spine.count)
        for s in spine {
            let w = max(s.width, minWidth)
            if let last = out.last {
                let dx = s.center.x - last.center.x
                let dy = s.center.y - last.center.y
                if dx * dx + dy * dy < 1e-18 { continue }
            }
            out.append(SpinePoint(center: s.center, width: w, alpha: s.alpha))
        }
        return out
    }

    private static func totalLength(_ spine: [SpinePoint]) -> CGFloat {
        var len: CGFloat = 0
        for i in 1..<spine.count {
            len += hypot(spine[i].center.x - spine[i - 1].center.x, spine[i].center.y - spine[i - 1].center.y)
        }
        return len
    }

    private static func tangentOf(_ samples: [(point: CGPoint, width: CGFloat, alpha: CGFloat)], at i: Int) -> CGPoint {
        let n = samples.count
        let prev = samples[max(0, i - 1)].point
        let next = samples[min(n - 1, i + 1)].point
        var t = next - prev
        let len = hypot(t.x, t.y)
        if len > 1e-12 { t = t / len } else { t = CGPoint(x: 1, y: 0) }
        return t
    }

    private static func distanceFromPointToLine(_ p: CGPoint, lineA a: CGPoint, lineB b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let denom = hypot(abx, aby)
        guard denom > 1e-12 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs((p.x - a.x) * aby - (p.y - a.y) * abx) / denom
    }
}

// MARK: - CGPoint 向量运算（文件内私有）

nonisolated private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

nonisolated private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}

nonisolated private func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
}

nonisolated private func / (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x / rhs, y: lhs.y / rhs)
}

nonisolated private prefix func - (p: CGPoint) -> CGPoint {
    CGPoint(x: -p.x, y: -p.y)
}
