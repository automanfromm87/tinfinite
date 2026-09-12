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

// ---------- 7. 笔刷 nib 响应 ----------
do {
    // 硬笔/荧光笔：无视倾斜
    let pen = StrokeStyle.pen(width: 10)
    let a = pen.nib(pressure: 0.5, altitude: .pi / 2)
    let b = pen.nib(pressure: 0.5, altitude: 0)
    check(approx(a.width, b.width) && a.alpha == 1 && b.alpha == 1, "pen ignores tilt")
    let hi = StrokeStyle.highlighter()
    check(hi.kind == .highlighter && hi.nib(pressure: 1).alpha == 1, "highlighter kind + opaque nib")
    // 钢笔：倾斜收细（垂直全宽，放平约 45%），压力钳制
    let fp = StrokeStyle.fountainPen(width: 10)
    let v = fp.nib(pressure: 1, altitude: .pi / 2).width
    let f = fp.nib(pressure: 1, altitude: 0).width
    check(approx(v, 10) && approx(f, 4.5), "fountain tilt thins \(v) -> \(f)")
    check(fp.nib(pressure: -1).width < fp.nib(pressure: 1).width, "fountain pressure clamp")
    // 铅笔：放平变宽变淡，轻触淡
    let pc = StrokeStyle.pencil(width: 10)
    let pv = pc.nib(pressure: 1, altitude: .pi / 2)
    let pf = pc.nib(pressure: 1, altitude: 0)
    check(approx(pv.width, 10) && approx(pv.alpha, 1), "pencil vertical full")
    check(approx(pf.width, 28) && approx(pf.alpha, 0.5), "pencil flat wide+faint")
    check(pc.nib(pressure: 0, altitude: .pi / 2).alpha < 0.31, "pencil light touch faint")
    check(pc.grain > 0 && pen.grain == 0, "pencil grain on, pen off")
}

// ---------- 8. 样式/中线兼容解码 ----------
do {
    // 老样式 JSON（无 kind/grain）：不透明 -> pen，半透明 -> highlighter
    let oldPenJSON = "{\"color\":{\"r\":0,\"g\":0,\"b\":0,\"a\":1},\"baseWidth\":8,\"minWidthScale\":0.12,\"pressureExponent\":0.6}".data(using: .utf8)!
    let oldPen = try! JSONDecoder().decode(StrokeStyle.self, from: oldPenJSON)
    check(oldPen.kind == .pen && oldPen.grain == 0, "legacy opaque -> pen")
    let oldHiJSON = "{\"color\":{\"r\":1,\"g\":0.85,\"b\":0.2,\"a\":0.45},\"baseWidth\":24,\"minWidthScale\":0.85,\"pressureExponent\":1}".data(using: .utf8)!
    let oldHi = try! JSONDecoder().decode(StrokeStyle.self, from: oldHiJSON)
    check(oldHi.kind == .highlighter, "legacy translucent -> highlighter")
    // 新样式往返
    let rt = try! JSONDecoder().decode(StrokeStyle.self, from: try! JSONEncoder().encode(StrokeStyle.pencil()))
    check(rt == .pencil(), "style roundtrip")
    // 老 spine 点（无 alpha）-> 1
    let oldSpJSON = "{\"x\":1,\"y\":2,\"width\":5}".data(using: .utf8)!
    let oldSp = try! JSONDecoder().decode(SpinePoint.self, from: oldSpJSON)
    check(oldSp.alpha == 1, "legacy spine alpha defaults 1")
}

// ---------- 9. tessellate alpha + 颗粒 ----------
do {
    let spine = [
        SpinePoint(center: CGPoint(x: 0, y: 0), width: 10, alpha: 0.5),
        SpinePoint(center: CGPoint(x: 40, y: 0), width: 10, alpha: 1),
    ]
    // 透明度插值：首顶点 ~0.5a，尾顶点 ~1a
    let m = StrokeGeometry.tessellate(spine: spine, color: RGBA(r: 0, g: 0, b: 0, a: 0.8))
    check(!m.vertices.isEmpty, "alpha mesh built")
    check(abs(m.vertices[0].a - 0.4) < 0.01, "head alpha interpolated, got \(m.vertices[0].a)")
    // grain=0 时行为与旧版一致：全顶点同 alpha
    let flat = StrokeGeometry.tessellate(spine: spine.map { SpinePoint(center: $0.center, width: $0.width) }, color: .black)
    check(Set(flat.vertices.map(\.a)) == [1], "grain off uniform alpha")
    // grain：确定性（两次一致）+ 真实抖动（不全相等）+ 只降不增
    let g1 = StrokeGeometry.tessellate(spine: spine, color: .black, grain: 0.35)
    let g2 = StrokeGeometry.tessellate(spine: spine, color: .black, grain: 0.35)
    check(g1.vertices.map(\.a) == g2.vertices.map(\.a), "grain deterministic")
    check(Set(g1.vertices.map(\.a)).count > 1, "grain varies")
    check(g1.vertices.allSatisfy { $0.a <= 1 }, "grain only darkens")
    // 点按成点路径也带透明度
    let dot = StrokeGeometry.tessellate(
        spine: [SpinePoint(center: CGPoint(x: 5, y: 5), width: 8, alpha: 0.25)], color: .black)
    check(!dot.vertices.isEmpty && dot.vertices.allSatisfy { abs($0.a - 0.25) < 0.001 }, "dot alpha")
}

// ---------- 10. 采样器倾斜 ----------
do {
    var s = StrokeSampler()
    s.spacingScreen = 2
    s.style = .fountainPen(width: 10)
    s.begin(screen: CGPoint(x: 0, y: 0), pressure: 1, altitude: .pi / 2, azimuth: 0, time: 0)
    s.append(screen: CGPoint(x: 10, y: 0), pressure: 1, altitude: 0, azimuth: 0, time: 0.01)
    s.end(screen: CGPoint(x: 20, y: 0), pressure: 1, altitude: 0, azimuth: 0, time: 0.02)
    let widths = s.spine.map(\.width)
    check(widths.count >= 2 && widths.first! > widths.last!, "sampler tilt thins fountain")
    check(s.spine.allSatisfy { $0.alpha == 1 }, "fountain alpha stays 1")
    check(s.rawPoints.count == 3 && s.rawPoints[1].altitude == 0, "raw keeps tilt")

    var p = StrokeSampler()
    p.style = .pencil(width: 10)
    p.begin(screen: CGPoint(x: 0, y: 0), pressure: 1, altitude: 0, azimuth: 0, time: 0)
    p.end(screen: CGPoint(x: 10, y: 0), pressure: 1, altitude: 0, azimuth: 0, time: 0.01)
    check(p.spine.allSatisfy { $0.alpha < 1 && $0.width > 10 }, "sampler tilt fades+widens pencil")
}

// ---------- 11. 渲染分层 ----------
do {
    // 荧光笔稳定分区：荧光笔在前保序，其余在后保序
    let mk: (BrushKind) -> Stroke = { kind in
        var st = StrokeStyle.pen()
        st.kind = kind
        return Stroke(points: [], style: st)
    }
    let ordered = [mk(.pen), mk(.highlighter), mk(.pencil), mk(.highlighter)]
        .highlightersFirst(kindOf: { $0.style.kind })
        .map(\.style.kind)
    check(ordered == [.highlighter, .highlighter, .pen, .pencil], "highlighters first stable: \(ordered)")
}

// ---------- 12. 点按坍缩 ----------
do {
    // 相机在落笔/抬笔间挪动（惯性/双击缩放）：手指只抖 2px，
    // 无坍缩会接受一个 500 世界单位外的终点，点按变直线
    var s = StrokeSampler()
    s.style = .pen(width: 8)
    var camOffset: CGFloat = 0
    s.worldConverter = { p in CGPoint(x: p.x + camOffset, y: p.y) }
    s.begin(screen: CGPoint(x: 100, y: 100), pressure: 1, altitude: .pi / 2, azimuth: 0, time: 0)
    camOffset = 500
    s.end(screen: CGPoint(x: 102, y: 100), pressure: 1, altitude: .pi / 2, azimuth: 0, time: 0.1)
    check(s.spine.count == 1, "tap collapses despite camera motion, got \(s.spine.count) points")
    check(approx(s.spine.first!.center, CGPoint(x: 100, y: 100)), "tap keeps down point")
    check(s.isTap, "isTap true")
    // live 预览同样坍缩并压住预测尾巴
    var live = StrokeSampler()
    live.style = .pen(width: 8)
    live.begin(screen: CGPoint(x: 50, y: 50), pressure: 1, altitude: .pi / 2, azimuth: 0, time: 0)
    live.setPredicted([CGPoint(x: 900, y: 900)])
    check(live.displaySpine.count == 1, "live tap suppresses predicted tail")
    // 真线（超 slop）不受影响
    var line = StrokeSampler()
    line.style = .pen(width: 8)
    line.begin(screen: CGPoint(x: 0, y: 0), pressure: 1, altitude: .pi / 2, azimuth: 0, time: 0)
    line.append(screen: CGPoint(x: 30, y: 0), pressure: 1, altitude: .pi / 2, azimuth: 0, time: 0.01)
    line.end(screen: CGPoint(x: 30, y: 0), pressure: 1, altitude: .pi / 2, azimuth: 0, time: 0.02)
    check(!line.isTap && line.spine.count >= 2, "real line kept")
}

// ---------- 13. HSV 与色轮几何 ----------
do {
    // 已知色：红/绿/蓝/黑/白
    let red = HSV(rgba: RGBA(r: 1, g: 0, b: 0, a: 1))
    check(approx(red.h, 0) && approx(red.s, 1) && approx(red.v, 1), "red hsv")
    let green = HSV(rgba: RGBA(r: 0, g: 1, b: 0, a: 1))
    check(approx(green.h, 1.0 / 3), "green hue \(green.h)")
    let blue = HSV(rgba: RGBA(r: 0, g: 0, b: 1, a: 1))
    check(approx(blue.h, 2.0 / 3), "blue hue \(blue.h)")
    let black = HSV(rgba: .black)
    check(black.s == 0 && black.v == 0, "black")
    let white = HSV(rgba: .white)
    check(white.s == 0 && approx(white.v, 1), "white")
    // 往返：HSV -> RGB -> HSV 一致（Float 量化误差内）
    for h in stride(from: 0.0, to: 1.0, by: 0.07) {
        for s in stride(from: 0.0, through: 1.0, by: 0.25) {
            for v in stride(from: 0.0, through: 1.0, by: 0.25) {
                let rt = HSV(rgba: HSV(h: h, s: s, v: v).rgba())
                // v=0 全体坍缩成黑（h/s 丢失是定义使然）；s=0 时 h 无意义
                let hueOK = s == 0 || v == 0 || approx(rt.h, h, eps: 0.01) || approx(rt.h, h + 1, eps: 0.01) || approx(rt.h, h - 1, eps: 0.01)
                let satOK = v == 0 || approx(rt.s, s, eps: 0.01)
                check(hueOK && satOK && approx(rt.v, v, eps: 0.01),
                      "hsv roundtrip h=\(h) s=\(s) v=\(v) got \(rt)")
            }
        }
    }
    // 色轮几何：上=红(h=0)，右=0.25，下=0.5，左=0.75；圆心 s=0；圆外钳制
    let c = CGPoint(x: 100, y: 100)
    let top = ColorWheelMath.hueSaturation(at: CGPoint(x: 100, y: 0), center: c, radius: 100)
    check(approx(top.h, 0) && approx(top.s, 1), "wheel top red")
    let right = ColorWheelMath.hueSaturation(at: CGPoint(x: 200, y: 100), center: c, radius: 100)
    check(approx(right.h, 0.25) && approx(right.s, 1), "wheel right")
    let bottom = ColorWheelMath.hueSaturation(at: CGPoint(x: 100, y: 200), center: c, radius: 100)
    check(approx(bottom.h, 0.5), "wheel bottom")
    let left = ColorWheelMath.hueSaturation(at: CGPoint(x: 0, y: 100), center: c, radius: 100)
    check(approx(left.h, 0.75), "wheel left")
    let middle = ColorWheelMath.hueSaturation(at: c, center: c, radius: 100)
    check(approx(middle.s, 0), "wheel center desaturated")
    let outside = ColorWheelMath.hueSaturation(at: CGPoint(x: 100, y: -200), center: c, radius: 100)
    check(approx(outside.h, 0) && approx(outside.s, 1), "wheel outside clamps")
    // 指示器定位与拾取互逆
    for h in stride(from: 0.0, to: 1.0, by: 0.11) {
        for s in stride(from: 0.0, through: 1.0, by: 0.2) {
            let p = ColorWheelMath.position(hue: h, saturation: s, center: c, radius: 100)
            let back = ColorWheelMath.hueSaturation(at: p, center: c, radius: 100)
            let hueOK = s < 0.01 || approx(back.h, h, eps: 0.01) || approx(back.h, h + 1, eps: 0.01)
            check(hueOK && approx(back.s, s, eps: 0.01), "wheel inverse h=\(h) s=\(s)")
        }
    }
}

if failures == 0 { print("ALL DRAWING-MATH TESTS PASSED") }
else { print("\(failures) FAILURES") }
exit(failures == 0 ? 0 : 1)
