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

let viewSize = CGSize(width: 390, height: 844)

// 1. round-trip（常规 + 远处 + 极端缩放）
for center in [CGPoint.zero, CGPoint(x: 100_000, y: -250_000), CGPoint(x: -1e12, y: 1e12)] {
    for scale in [0.02, 0.5, 1, 3, 32] {
        let cam = Camera(center: center, scale: scale)
        for world in [CGPoint.zero, CGPoint(x: 1234.5, y: -987.25), center] {
            let back = cam.screenToWorld(cam.worldToScreen(world, viewSize: viewSize), viewSize: viewSize)
            // 极端坐标下用相对误差（float64 有效数字 ~15-16 位，屏幕坐标量级可达 1e10）
            let magnitude = max(1, abs(center.x), abs(center.y), abs(world.x), abs(world.y))
            check(approx(back, world, eps: magnitude * 1e-12), "roundtrip center=\(center) scale=\(scale) world=\(world) got=\(back)")
        }
        // 中心必须落在视图中心
        check(approx(cam.worldToScreen(cam.center, viewSize: viewSize),
                     CGPoint(x: 195, y: 422)), "center maps to view center")
    }
}

// 2. contentTransform 与 worldToScreen 一致
// 容器 bounds.size == viewSize、center == 视图中心时，子视图世界点 w 的屏幕位置 =
// center + T * (w - viewSize/2)
do {
    let cam = Camera(center: CGPoint(x: 500, y: -200), scale: 2.5)
    let t = cam.contentTransform(viewSize: viewSize)
    for world in [CGPoint.zero, CGPoint(x: 500, y: -200), CGPoint(x: 12345, y: 6789)] {
        let p = CGPoint(x: world.x - viewSize.width * 0.5, y: world.y - viewSize.height * 0.5)
        let tp = p.applying(t)
        let viaTransform = CGPoint(x: tp.x + viewSize.width * 0.5, y: tp.y + viewSize.height * 0.5)
        let direct = cam.worldToScreen(world, viewSize: viewSize)
        check(approx(viaTransform, direct), "transform matches worldToScreen for \(world)")
    }
}

// 3. pan：手指右移 100pt（scale=2）=> 世界中心左移 50
do {
    let cam = Camera(center: .zero, scale: 2).panned(by: CGSize(width: 100, height: -40))
    check(approx(cam.center, CGPoint(x: -50, y: 20)), "pan math got=\(cam.center)")
}

// 4. anchored zoom：锚点下世界点不动
do {
    let cam = Camera(center: CGPoint(x: 100, y: 100), scale: 1)
    let anchor = CGPoint(x: 100, y: 700)
    let before = cam.screenToWorld(anchor, viewSize: viewSize)
    let after = cam.zoomed(by: 2.37, anchoredAtScreen: anchor, viewSize: viewSize)
    let still = after.screenToWorld(anchor, viewSize: viewSize)
    check(approx(before, still, eps: 1e-9), "anchor stable before=\(before) after=\(still)")
    check(approx(after.scale, 2.37), "zoom factor")
}

// 5. zoom clamp：超出范围被钳制，且锚点仍稳定
do {
    let cam = Camera(center: .zero, scale: 1)
    let anchor = CGPoint(x: 10, y: 20)
    let before = cam.screenToWorld(anchor, viewSize: viewSize)
    let big = cam.zoomed(by: 1000, anchoredAtScreen: anchor, viewSize: viewSize)
    check(big.scale == Camera.defaultZoomRange.upperBound, "clamp max")
    check(approx(big.screenToWorld(anchor, viewSize: viewSize), before, eps: 1e-9), "clamped anchor stable")
    let small = cam.zoomed(by: 0.0001, anchoredAtScreen: anchor, viewSize: viewSize)
    check(small.scale == Camera.defaultZoomRange.lowerBound, "clamp min")
}

// 6. visibleWorldRect：scale=2 时可见 195x422 世界单位，中心对齐
do {
    let cam = Camera(center: CGPoint(x: 10, y: 10), scale: 2)
    let r = cam.visibleWorldRect(viewSize: viewSize)
    check(approx(r.width, 195) && approx(r.height, 422), "visible size \(r)")
    check(approx(CGPoint(x: r.midX, y: r.midY), CGPoint(x: 10, y: 10)), "visible center")
    let vp = Viewport(camera: cam, size: viewSize)
    check(vp.isVisible(CGPoint(x: 10, y: 10)), "center visible")
    check(!vp.isVisible(CGPoint(x: 10000, y: 10)), "far point culled")
    check(vp.isVisible(CGRect(x: 0, y: 0, width: 50, height: 50)), "overlap rect visible")
    check(!vp.isVisible(CGRect(x: 5000, y: 5000, width: 10, height: 10)), "far rect culled")
    check(vp.isVisible(CGPoint(x: 10000, y: 10), margin: 20000), "margin expands")
}

// 7. Codable round-trip
do {
    let cam = Camera(center: CGPoint(x: 1.5, y: -2.5), scale: 3)
    let data = try JSONEncoder().encode(cam)
    let back = try JSONDecoder().decode(Camera.self, from: data)
    check(back == cam, "codable roundtrip")
} catch {
    check(false, "codable threw \(error)")
}

// ---------- minimap 映射 ----------

do {
    // 空内容
    check(MinimapMath.contentUnion(strokes: [], items: []) == nil, "union empty -> nil")
    // 并集
    let u = MinimapMath.contentUnion(
        strokes: [CGRect(x: 0, y: 0, width: 100, height: 50)],
        items: [CGRect(x: 200, y: 100, width: 40, height: 40)]
    )!
    check(u == CGRect(x: 0, y: 0, width: 240, height: 140), "union rect")
    // 非有限矩形跳过
    let u2 = MinimapMath.contentUnion(
        strokes: [CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)],
        items: [CGRect(x: 10, y: 10, width: 20, height: 20)]
    )!
    check(u2 == CGRect(x: 10, y: 10, width: 20, height: 20), "union skips nonfinite")
    // 映射：内容中心 -> minimap 中心，等比 letterbox
    let t = MinimapMath.transform(
        content: CGRect(x: 0, y: 0, width: 400, height: 200),
        minimapSize: CGSize(width: 170, height: 130), padding: 8
    )!
    check(approx(t.a, 0.385) && approx(t.d, 0.385), "minimap scale")
    let c = CGPoint(x: 200, y: 100).applying(t)
    check(approx(c, CGPoint(x: 85, y: 65)), "content center -> minimap center")
    // 退化点撑开后仍可逆
    let t2 = MinimapMath.transform(
        content: CGRect(x: 50, y: 50, width: 0, height: 0),
        minimapSize: CGSize(width: 170, height: 130), padding: 8
    )!
    let back = CGPoint(x: 85, y: 65).applying(t2.inverted())
    check(approx(back, CGPoint(x: 50, y: 50), eps: 1e-3), "degenerate invertible")
    // 非法输入
    check(MinimapMath.transform(
        content: CGRect(x: 0, y: 0, width: 10, height: 10),
        minimapSize: CGSize(width: 10, height: 10), padding: 8
    ) == nil, "tiny minimap -> nil")
}

if failures == 0 { print("ALL CAMERA/VIEWPORT TESTS PASSED") }
else { print("\(failures) FAILURES") }
exit(failures == 0 ? 0 : 1)
