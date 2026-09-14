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
            tint(color: color, grain: grain, alpha: alpha, vertexIndex: vertexIndex)
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

    /// 顶点着色：样式色 × 采样点透明度（倾斜响应）× 颗粒抖动。
    /// tessellate 与 LiveStrokeMesh 共用，保证 live 预览与提交后的网格逐位一致。
    fileprivate static func tint(
        color: RGBA, grain: CGFloat, alpha: CGFloat, vertexIndex: Int
    ) -> RGBA {
        var c = color
        var a = color.a * Float(min(max(alpha, 0), 1))
        if grain > 0 {
            a *= Float(1 - min(max(grain, 0), 1) * grainHash(vertexIndex))
        }
        c.a = a
        return c
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

    fileprivate static func disc(
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

    fileprivate static func flattenCubic(
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

    fileprivate static func appendCap(
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

    fileprivate static func cleaned(_ spine: [SpinePoint]) -> [SpinePoint] {
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

    fileprivate static func totalLength(_ spine: [SpinePoint]) -> CGFloat {
        var len: CGFloat = 0
        for i in 1..<spine.count {
            len += hypot(spine[i].center.x - spine[i - 1].center.x, spine[i].center.y - spine[i - 1].center.y)
        }
        return len
    }

    fileprivate static func tangentOf(_ samples: [(point: CGPoint, width: CGFloat, alpha: CGFloat)], at i: Int) -> CGPoint {
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

// MARK: - 增量 live 网格

/// Live 笔画的增量网格构建器。
///
/// 为什么需要它：`tessellate` 是全量的，而 live 预览每个输入事件都要刷新一次
/// （ProMotion 上 ~120 次/秒）。全量重建是 O(n) / 事件、O(n²) / 笔，一笔 3 秒的字
/// 要把同一段中线重复镶嵌约 180 遍、往 GPU 重传约 23 MB —— 越写越卡，且长度无上限。
///
/// 关键不变量：采样器的确认 spine 是 **只追加** 的（OneEuro 是因果 IIR，从不回改
/// 历史输出），只有「预测尾巴」每次事件会被整段替换。Catmull-Rom 的第 i 段读
/// `F[i-1 ... i+2]`，所以 `i <= nc - 3` 的段在下次事件里逐位不变（nc = 确认点数）。
/// 于是每事件只需重算最后两段 + 预测尾 + 两个圆头，其余原样保留，并且只把
/// 变动的那一小段字节重传给 GPU。
///
/// 输出与 `StrokeGeometry.tessellate(spine: confirmed + predicted, ...)` 逐顶点相同
/// （含 grain 抖动序号），由 Tests/Suites/DrawingSuite.swift 的差分测试守住。
nonisolated struct LiveStrokeMesh {

    // 样式（begin 时固定）
    private var color: RGBA = .black
    private var grain: CGFloat = 0
    private var tolerance: CGFloat = 0.12
    private var capSegments: Int = 10

    // 增量状态
    private var cleanConfirmed: [SpinePoint] = []
    private var confirmedLength: CGFloat = 0
    private var consumed = 0
    private var samples: [(point: CGPoint, width: CGFloat, alpha: CGFloat)] = []
    /// segSampleEnd[i] = 处理完第 i 段后的 samples 数量（截断锚点）
    private var segSampleEnd: [Int] = []
    /// 上一次构建时的确认点数。稳定性判据必须用它而不是当前值：
    /// 上次第 i 段读的是 F_prev[i+2]，只有 i+2 落在**当时**的确认前缀里，
    /// 那一段才没沾到已被替换的预测尾（或末端 clamp）。
    private var builtConfirmedCount = 0
    /// 上一次走的是退化（圆盘）分支：布局完全不同，下次必须全量重建
    private var wasDegenerate = true

    // 输出
    private(set) var vertices: [StrokeVertex] = []
    private(set) var indices: [UInt32] = []
    /// 本次相对上次真正变动的起点（按顶点 / 索引计数）；上传只需从这里开始
    private(set) var dirtyVertexStart = 0
    private(set) var dirtyIndexStart = 0

    var isEmpty: Bool { vertices.isEmpty || indices.isEmpty }
    var mesh: StrokeMesh { StrokeMesh(vertices: vertices, indices: indices) }

    /// 起笔：固定样式与容差，清空增量状态
    mutating func begin(style: StrokeStyle, tolerance: CGFloat, capSegments: Int = 10) {
        self.color = style.color
        self.grain = style.grain
        self.tolerance = tolerance
        self.capSegments = capSegments
        reset()
    }

    mutating func reset() {
        cleanConfirmed.removeAll(keepingCapacity: true)
        confirmedLength = 0
        consumed = 0
        samples.removeAll(keepingCapacity: true)
        segSampleEnd.removeAll(keepingCapacity: true)
        builtConfirmedCount = 0
        vertices.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
        dirtyVertexStart = 0
        dirtyIndexStart = 0
        wasDegenerate = true
    }

    /// 刷新网格。`confirmed` 必须是只追加的；`predicted` 每次整段替换。
    mutating func update(confirmed: [SpinePoint], predicted: [SpinePoint]) {
        // 采样器回退（点按坍缩等）：增量前提不成立，从头来
        if confirmed.count < consumed {
            let keptStyle = (color, grain, tolerance, capSegments)
            reset()
            (color, grain, tolerance, capSegments) = keptStyle
        }
        while consumed < confirmed.count {
            appendConfirmed(confirmed[consumed])
            consumed += 1
        }

        // 预测尾：延续同一条清洗折叠（与 cleaned(confirmed + predicted) 等价）
        var tail: [SpinePoint] = []
        var tailLength: CGFloat = 0
        if !predicted.isEmpty {
            tail.reserveCapacity(predicted.count)
            var last = cleanConfirmed.last
            for s in predicted {
                if let l = last {
                    let dx = s.center.x - l.center.x
                    let dy = s.center.y - l.center.y
                    if dx * dx + dy * dy < 1e-18 { continue }
                    tailLength += hypot(dx, dy)
                }
                let p = SpinePoint(
                    center: s.center, width: max(s.width, StrokeGeometry.minWidth), alpha: s.alpha
                )
                tail.append(p)
                last = p
            }
        }

        let nc = cleanConfirmed.count
        let total = nc + tail.count
        guard total > 0 else {
            vertices.removeAll(keepingCapacity: true)
            indices.removeAll(keepingCapacity: true)
            dirtyVertexStart = 0
            dirtyIndexStart = 0
            wasDegenerate = true
            builtConfirmedCount = nc
            return
        }

        // 退化：单点（或总长为零）-> 圆盘。与 tessellate 同判据、同输出。
        if total == 1 || confirmedLength + tailLength < 1e-9 {
            let head = nc > 0 ? cleanConfirmed[0] : tail[0]
            var maxW = head.width
            for p in cleanConfirmed where p.width > maxW { maxW = p.width }
            for p in tail where p.width > maxW { maxW = p.width }
            let alpha = head.alpha
            let c = color, g = grain
            let disc = StrokeGeometry.disc(
                center: head.center, radius: max(maxW, StrokeGeometry.minWidth) * 0.5,
                segments: max(capSegments * 2, 16),
                tint: { StrokeGeometry.tint(color: c, grain: g, alpha: alpha, vertexIndex: $0) }
            )
            vertices = disc.vertices
            indices = disc.indices
            dirtyVertexStart = 0
            dirtyIndexStart = 0
            wasDegenerate = true
            builtConfirmedCount = nc
            return
        }

        // 上次第 i 段只要 i <= builtConfirmedCount-3 就与本次逐位相同；其余
        // （沾到旧预测尾或末端 clamp 的，以及新增的）全部重算。
        // 退化分支之后布局不同，必须整段重来。
        let stableSegs = wasDegenerate
            ? 0
            : min(max(0, builtConfirmedCount - 2), segSampleEnd.count)
        let keepSamples = stableSegs == 0 ? 1 : segSampleEnd[stableSegs - 1]
        wasDegenerate = false
        builtConfirmedCount = nc

        if samples.count > keepSamples {
            samples.removeLast(samples.count - keepSamples)
        }
        if samples.isEmpty {
            let head = nc > 0 ? cleanConfirmed[0] : tail[0]
            samples.append((head.center, head.width, head.alpha))
        }
        if segSampleEnd.count > stableSegs {
            segSampleEnd.removeLast(segSampleEnd.count - stableSegs)
        }

        // 展平剩余段（point(at:) 把「确认段 + 预测尾」当作一条连续中线看）
        var i = stableSegs
        while i < total - 1 {
            let p0 = point(at: max(0, i - 1), tail: tail, nc: nc).center
            let a = point(at: i, tail: tail, nc: nc)
            let b = point(at: i + 1, tail: tail, nc: nc)
            let p3 = point(at: min(total - 1, i + 2), tail: tail, nc: nc).center
            StrokeGeometry.flattenCubic(
                p0: a.center,
                c1: a.center + (b.center - p0) / 6,
                c2: b.center - (p3 - a.center) / 6,
                p3: b.center,
                w0: a.width, w1: b.width,
                a0: a.alpha, a1: b.alpha,
                t0: 0, t1: 1,
                tolerance: tolerance,
                depth: 0,
                into: &samples
            )
            segSampleEnd.append(samples.count)
            if samples.count > StrokeGeometry.maxSamples { break }
            i += 1
        }

        rebuildRibbon(keepSamples: keepSamples)
    }

    // MARK: - 内部

    private mutating func appendConfirmed(_ s: SpinePoint) {
        let w = max(s.width, StrokeGeometry.minWidth)
        if let last = cleanConfirmed.last {
            let dx = s.center.x - last.center.x
            let dy = s.center.y - last.center.y
            if dx * dx + dy * dy < 1e-18 { return }
            confirmedLength += hypot(dx, dy)
        }
        cleanConfirmed.append(SpinePoint(center: s.center, width: w, alpha: s.alpha))
    }

    private func point(at index: Int, tail: [SpinePoint], nc: Int) -> SpinePoint {
        index < nc ? cleanConfirmed[index] : tail[index - nc]
    }

    /// 顶点 j 的法线读 samples[j±1]，所以只有 j <= keepSamples-2 的顶点对是稳定的；
    /// 四边形 q 用顶点 2q..2q+3，跟着少保一个。圆头永远重建（共 24 顶点，免费）。
    private mutating func rebuildRibbon(keepSamples: Int) {
        let n = samples.count
        let stableVertexPairs = min(max(0, keepSamples - 1), min(vertices.count / 2, n))
        let stableQuads = max(0, stableVertexPairs - 1)

        if vertices.count > stableVertexPairs * 2 {
            vertices.removeLast(vertices.count - stableVertexPairs * 2)
        }
        if indices.count > stableQuads * 6 {
            indices.removeLast(indices.count - stableQuads * 6)
        }
        dirtyVertexStart = vertices.count
        dirtyIndexStart = indices.count
        vertices.reserveCapacity(n * 2 + capSegments * 2 + 2)
        indices.reserveCapacity((n - 1) * 6 + capSegments * 6)

        let c = color, g = grain
        for j in stableVertexPairs..<n {
            let prev = samples[max(0, j - 1)].point
            let next = samples[min(n - 1, j + 1)].point
            var t = next - prev
            let len = hypot(t.x, t.y)
            if len > 1e-12 { t = t / len } else { t = CGPoint(x: 1, y: 0) }
            let normal = CGPoint(x: -t.y, y: t.x)
            let hw = max(samples[j].width, StrokeGeometry.minWidth) * 0.5
            let tintColor = StrokeGeometry.tint(
                color: c, grain: g, alpha: samples[j].alpha, vertexIndex: vertices.count
            )
            vertices.append(StrokeVertex(position: samples[j].point + normal * hw, color: tintColor))
            vertices.append(StrokeVertex(position: samples[j].point - normal * hw, color: tintColor))
        }
        if n >= 2 {
            for q in stableQuads..<(n - 1) {
                let b = UInt32(q * 2)
                indices.append(contentsOf: [b, b + 1, b + 2, b + 1, b + 3, b + 2])
            }
        }

        let t0 = StrokeGeometry.tangentOf(samples, at: 0)
        let t1 = StrokeGeometry.tangentOf(samples, at: n - 1)
        let headAlpha = samples[0].alpha
        StrokeGeometry.appendCap(
            center: samples[0].point, radius: max(samples[0].width, StrokeGeometry.minWidth) * 0.5,
            facing: CGPoint(x: -t0.x, y: -t0.y), segments: capSegments,
            tint: { StrokeGeometry.tint(color: c, grain: g, alpha: headAlpha, vertexIndex: $0) },
            vertices: &vertices, indices: &indices
        )
        let tailAlpha = samples[n - 1].alpha
        StrokeGeometry.appendCap(
            center: samples[n - 1].point,
            radius: max(samples[n - 1].width, StrokeGeometry.minWidth) * 0.5,
            facing: t1, segments: capSegments,
            tint: { StrokeGeometry.tint(color: c, grain: g, alpha: tailAlpha, vertexIndex: $0) },
            vertices: &vertices, indices: &indices
        )
    }
}
