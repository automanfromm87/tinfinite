import CoreGraphics
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if !cond { failures += 1; print("FAIL: \(msg)") }
}
func approx(_ a: CGFloat, _ b: CGFloat, eps: CGFloat = 1e-6) -> Bool { abs(a - b) < eps }
func approx(_ a: CGPoint, _ b: CGPoint, eps: CGFloat = 1e-6) -> Bool {
    approx(a.x, b.x, eps: eps) && approx(a.y, b.y, eps: eps)
}

// ---------- 1. 压力->宽度 ----------
do {
    let s = StrokeStyle(color: .black, baseWidth: 10, minWidthScale: 0.2, pressureExponent: 1)
    check(approx(s.width(forPressure: 0), 2), "p=0 -> min")
    check(approx(s.width(forPressure: 1), 10), "p=1 -> base")
    check(approx(s.width(forPressure: 0.5), 6), "p=0.5 linear")
    check(approx(s.width(forPressure: -3), 2) && approx(s.width(forPressure: 99), 10), "clamp")
    let g = StrokeStyle(color: .black, baseWidth: 10, minWidthScale: 0, pressureExponent: 0.5)
    check(g.width(forPressure: 0.25) > g.width(forPressure: 0.24), "gamma monotonic")
    check(approx(g.width(forPressure: 0.25), 5), "sqrt curve")
}

// ---------- 2. OneEuro ----------
do {
    var f = OneEuroFilter2D()
    let first = f.filter(CGPoint(x: 7, y: -3), at: 0)
    check(approx(first, CGPoint(x: 7, y: -3)), "first sample passthrough")
    // 常量输入保持常量
    var ok = true
    for i in 1...100 {
        let o = f.filter(CGPoint(x: 7, y: -3), at: Double(i) / 240.0)
        if !approx(o, CGPoint(x: 7, y: -3), eps: 1e-9) { ok = false }
    }
    check(ok, "constant input stable")
    // 阶跃响应：单调趋近新值
    f.reset()
    _ = f.filter(CGPoint.zero, at: 0)
    var prev: CGFloat = 0
    var mono = true
    for i in 1...50 {
        let o = f.filter(CGPoint(x: 100, y: 0), at: Double(i) / 240.0)
        if o.x < prev - 1e-9 || o.x > 100 + 1e-9 { mono = false }
        prev = o.x
    }
    check(mono && prev > 50, "step response monotonic, converges (last=\(prev))")
}

// ---------- 3. Sampler ----------
do {
    var s = StrokeSampler()
    s.spacingScreen = 2
    s.style = .pen(color: .black, width: 10)
    var t = 0.0
    let dt = 1.0 / 240.0
    s.begin(screen: CGPoint(x: 0, y: 0), pressure: 1, altitude: .pi / 2, azimuth: 0, time: t)
    for i in 1...20 {
        t += dt
        s.append(screen: CGPoint(x: CGFloat(i), y: 0), pressure: 1, altitude: .pi / 2, azimuth: 0, time: t)
    }
    // 0..20 step1, spacing2 -> 约 9~11 个 spine 点（滤波滞后约 1px，接受略稀）
    check(s.spine.count >= 8 && s.spine.count <= 12, "resample count \(s.spine.count)")
    check(approx(s.spine[0].center, CGPoint.zero), "first accepted exact")
    check(s.rawPoints.count == 21, "raw keeps all \(s.rawPoints.count)")
    // 预测只进 display
    s.setPredicted([CGPoint(x: 21, y: 0), CGPoint(x: 22, y: 0)])
    check(s.displaySpine.count == s.spine.count + 2, "predicted in display")
    let spineBeforeEnd = s.spine.count
    check(spineBeforeEnd >= 8, "predicted not in spine")
    // end 强制落点
    t += dt
    s.end(screen: CGPoint(x: 20.5, y: 0.5), pressure: 0.2, altitude: .pi / 2, azimuth: 0, time: t)
    check(approx(s.spine.last!.center, CGPoint(x: 20.5, y: 0.5)), "end lands exact")
    check(s.displaySpine.count == s.spine.count, "predicted cleared on end")
    check(approx(s.spine.last!.width, s.style.width(forPressure: 0.2)), "end width from pressure")
}
do {
    // 世界转换注入
    var s = StrokeSampler()
    s.worldConverter = { CGPoint(x: $0.x * 0.5, y: $0.y * 0.5 + 100) }
    s.begin(screen: CGPoint(x: 10, y: 10), pressure: 1, altitude: .pi / 2, azimuth: 0, time: 0)
    check(approx(s.spine[0].center, CGPoint(x: 5, y: 105)), "world converter applied")
    check(approx(s.rawPoints[0].position, CGPoint(x: 5, y: 105)), "raw also world")
}

// ---------- 4. Geometry ----------
do {
    // 直线：2 spine -> 2 samples（无细分）-> 精确计数
    let spine = [SpinePoint(center: CGPoint(x: 0, y: 0), width: 10),
                 SpinePoint(center: CGPoint(x: 100, y: 0), width: 10)]
    let mesh = StrokeGeometry.tessellate(spine: spine, color: .red, capSegments: 10)
    // body verts 4 + caps 2*(1+11) = 28；indices body 6 + caps 2*10*3 = 66
    check(mesh.vertices.count == 28, "straight vert count \(mesh.vertices.count)")
    check(mesh.indices.count == 66, "straight index count \(mesh.indices.count)")
    check(mesh.indices.count % 3 == 0, "index multiple of 3")
    // ribbon 对称：L=(0,5) R=(0,-5)
    check(approx(CGFloat(mesh.vertices[0].x), 0) && approx(CGFloat(mesh.vertices[0].y), 5), "ribbon L")
    check(approx(CGFloat(mesh.vertices[1].x), 0) && approx(CGFloat(mesh.vertices[1].y), -5), "ribbon R")
    // 颜色写入
    check(mesh.vertices[0].r == 1 && mesh.vertices[0].g < 0.3, "vertex color")
    // 圆头朝向：start cap 弧点 x<=0（向后），end cap 弧点 x>=100（向前）
    let startArcX = (4..<16).map { CGFloat(mesh.vertices[$0].x) }.max()!
    let endArcX = (16..<28).map { CGFloat(mesh.vertices[$0].x) }.min()!
    check(startArcX <= 0.001, "start cap backward \(startArcX)")
    check(endArcX >= 99.999, "end cap forward \(endArcX)")
}
do {
    // 单点 -> 圆盘：segments=20 -> verts 22, indices 60
    let mesh = StrokeGeometry.tessellate(spine: [SpinePoint(center: CGPoint(x: 5, y: 5), width: 8)], color: .blue)
    check(mesh.vertices.count == 22, "disc verts \(mesh.vertices.count)")
    check(mesh.indices.count == 60, "disc indices \(mesh.indices.count)")
    // 半径 = 4
    let rim = hypot(CGFloat(mesh.vertices[1].x) - 5, CGFloat(mesh.vertices[1].y) - 5)
    check(approx(rim, 4), "disc radius \(rim)")
}
do {
    // 曲线产生细分；确定性：两次结果完全一致
    let l: [SpinePoint] = [SpinePoint(center: CGPoint(x: 0, y: 0), width: 10),
                            SpinePoint(center: CGPoint(x: 50, y: 0), width: 6),
                            SpinePoint(center: CGPoint(x: 50, y: 50), width: 10)]
    let m1 = StrokeGeometry.tessellate(spine: l, color: .black)
    let m2 = StrokeGeometry.tessellate(spine: l, color: .black)
    check(m1.vertices.count > 28, "curve subdivides \(m1.vertices.count)")
    check(m1.vertices.count == m2.vertices.count && m1.indices == m2.indices, "deterministic counts")
    var same = true
    for i in 0..<m1.vertices.count {
        let a = m1.vertices[i], b = m2.vertices[i]
        if a.x != b.x || a.y != b.y { same = false; break }
    }
    check(same, "deterministic vertices")
    // 宽度插值：中间段宽度应在 6..10 之间变化（检查 ribbon 半宽）
    // 取中间顶点的 |L-R|/2
    let mid = m1.vertices.count / 2 / 2 * 2
    let hw = hypot(CGFloat(m1.vertices[mid].x - m1.vertices[mid + 1].x),
                   CGFloat(m1.vertices[mid].y - m1.vertices[mid + 1].y)) / 2
    check(hw > 2.9 && hw < 5.1, "width interpolated \(hw)")
}
do {
    // bounds
    let b = StrokeGeometry.bounds(of: [SpinePoint(center: CGPoint(x: 0, y: 0), width: 10),
                                       SpinePoint(center: CGPoint(x: 100, y: 0), width: 20)])
    check(approx(b.minX, -10) && approx(b.maxX, 110) && approx(b.minY, -10) && approx(b.maxY, 10), "bounds \(b)")
    check(StrokeGeometry.bounds(of: []).isNull, "empty bounds null")
}
do {
    // 空 spine -> 空 mesh；重复点 spine -> 不崩
    let e = StrokeGeometry.tessellate(spine: [], color: .black)
    check(e.isEmpty, "empty spine")
    let dup = StrokeGeometry.tessellate(spine: [SpinePoint(center: .zero, width: 5),
                                                SpinePoint(center: .zero, width: 5)], color: .black)
    check(!dup.isEmpty && dup.indices.count % 3 == 0, "dup points -> disc")
}

// ---------- 5. Stroke Codable ----------
do {
    let stroke = Stroke(
        points: [StrokePoint(position: CGPoint(x: 1, y: 2), pressure: 0.5, altitude: 1, azimuth: 2, timestamp: 3),
                 StrokePoint(position: CGPoint(x: 4, y: 5), pressure: 1, timestamp: 4)],
        style: .pen(color: .red, width: 7),
        bounds: CGRect(x: 0, y: 0, width: 10, height: 10)
    )
    let data = try JSONEncoder().encode(stroke)
    let back = try JSONDecoder().decode(Stroke.self, from: data)
    check(back == stroke, "stroke codable roundtrip")
} catch {
    check(false, "codable threw \(error)")
}

// ---------- 6. 相机相对顶点（P1-8 精度回归） ----------
do {
    // 远离原点的世界坐标：相对顶点必须精确到 float 小数精度，
    // 且“相对顶点 + 相对中心”能还原屏幕位置（GPU 只接触小数）
    let origin = CGPoint(x: 100_352, y: -50_176) // 1024 网格量化点
    let p = CGPoint(x: 100_352.75, y: -50_175.25)
    let v = StrokeVertex(position: p, relativeTo: origin, color: .black)
    check(v.x == 0.75 && v.y == 0.75, "relative vertex exact, got (\(v.x), \(v.y))")
    // 绝对 float 路径在 1e5 量级会丢低位（对照：ulp(1e5)≈0.0078，0.1 非二进制精确）
    let absV = StrokeVertex(position: CGPoint(x: 100_352.1, y: 0), color: .black)
    check(abs(Double(absV.x) - 100_352.1) > 0, "abs float loses bits at 1e5 (sanity)")
    // double 域的中心偏移同样精确
    let cam = CGPoint(x: 100_360.5, y: -50_170.0)
    let dx = Float(Double(cam.x) - Double(origin.x))
    let dy = Float(Double(cam.y) - Double(origin.y))
    check(dx == 8.5 && dy == 6.0, "uniform delta exact, got (\(dx), \(dy))")
}

if failures == 0 { print("ALL DRAWING-MATH TESTS PASSED") }
else { print("\(failures) FAILURES") }
exit(failures == 0 ? 0 : 1)
