// StrokeModel.swift
// Drawing 层数据模型（纯值类型，无 UIKit，可单测）：
// StrokePoint（世界坐标+压力+倾斜）-> Stroke（原始输入点列+样式）-> SpinePoint/Mesh（几何输出）

import CoreGraphics
import Foundation
import simd

// MARK: - 颜色（Float RGBA，与 Metal float4 对齐）

nonisolated struct RGBA: Equatable, Sendable, Codable, Hashable {
    var r, g, b, a: Float

    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
    static let red = RGBA(r: 1, g: 0.23, b: 0.19, a: 1)
    static let orange = RGBA(r: 1, g: 0.58, b: 0, a: 1)
    static let blue = RGBA(r: 0, g: 0.48, b: 1, a: 1)
    static let green = RGBA(r: 0.2, g: 0.78, b: 0.35, a: 1)
    static let purple = RGBA(r: 0.69, g: 0.32, b: 0.87, a: 1)

    var simd: SIMD4<Float> { SIMD4<Float>(r, g, b, a) }
}

// MARK: - HSV 颜色（色轮用；h/s/v 均为 0...1）

/// HSV 颜色（色轮拾取用）。h=0 为正红，顺时针增大。
nonisolated struct HSV: Equatable, Sendable {
    var h, s, v: CGFloat

    init(h: CGFloat, s: CGFloat, v: CGFloat) {
        self.h = h
        self.s = s
        self.v = v
    }

    init(rgba: RGBA) {
        let r = CGFloat(rgba.r), g = CGFloat(rgba.g), b = CGFloat(rgba.b)
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        v = mx
        s = mx > 0 ? d / mx : 0
        if d == 0 {
            h = 0
        } else if mx == r {
            h = ((g - b) / d).truncatingRemainder(dividingBy: 6) / 6
            if h < 0 { h += 1 }
        } else if mx == g {
            h = ((b - r) / d + 2) / 6
        } else {
            h = ((r - g) / d + 4) / 6
        }
    }

    func rgba(alpha: Float = 1) -> RGBA {
        let h6 = (h - floor(h)) * 6
        let c = v * s
        let x = c * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(floor(h6)) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = v - c
        return RGBA(r: Float(r + m), g: Float(g + m), b: Float(b + m), a: alpha)
    }
}

/// 色轮几何：圆心为白（s=0），边缘为纯色（s=1），h=0 在正上方顺时针增大。
nonisolated enum ColorWheelMath {
    /// 触摸点 -> (h, s)。圆外钳制到边缘。
    static func hueSaturation(at point: CGPoint, center: CGPoint, radius: CGFloat) -> (h: CGFloat, s: CGFloat) {
        guard radius > 0 else { return (0, 0) }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = min(hypot(dx, dy), radius)
        // atan2 以 +x 轴为 0；+90° 把 0 点搬到正上方（h 顺时针增大）
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return (angle / (2 * .pi), dist / radius)
    }

    /// (h, s) -> 轮上点（指示器定位用，与上互逆）
    static func position(hue h: CGFloat, saturation s: CGFloat, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = h * 2 * .pi - .pi / 2
        let d = min(max(s, 0), 1) * radius
        return CGPoint(x: center.x + d * cos(angle), y: center.y + d * sin(angle))
    }
}

// MARK: - 笔样式

/// 笔刷种类：决定笔尖响应（压力/倾斜 -> 宽度/不透明度）与渲染层级（荧光笔在墨线下）。
nonisolated enum BrushKind: String, Equatable, Sendable, Codable, Hashable {
    case pen
    case highlighter
    case fountainPen
    case pencil
}

/// 笔样式：颜色 + 基础笔宽（世界单位，压力=1 时）+ 压力曲线 + 笔刷行为。
/// width(p) = base * (minScale + (1-minScale) * p^exponent)，再叠笔刷的倾斜响应（见 nib）。
nonisolated struct StrokeStyle: Equatable, Sendable, Codable, Hashable {
    var color: RGBA
    /// 基础笔宽（世界单位）
    var baseWidth: CGFloat
    /// 零压力时的宽度比例 0...1
    var minWidthScale: CGFloat
    /// 压力指数：<1 更灵敏，>1 更迟钝
    var pressureExponent: CGFloat
    /// 笔刷种类（老存档无此键 -> 按透明度推断：半透明=荧光笔，否则=普通硬笔）
    var kind: BrushKind = .pen
    /// 颗粒强度 0...1（铅笔纹理用，tessellate 做确定性 alpha 抖动；0 = 关闭）
    var grain: CGFloat = 0

    enum CodingKeys: String, CodingKey {
        case color, baseWidth, minWidthScale, pressureExponent, kind, grain
    }

    init(
        color: RGBA, baseWidth: CGFloat, minWidthScale: CGFloat, pressureExponent: CGFloat,
        kind: BrushKind = .pen, grain: CGFloat = 0
    ) {
        self.color = color
        self.baseWidth = baseWidth
        self.minWidthScale = minWidthScale
        self.pressureExponent = pressureExponent
        self.kind = kind
        self.grain = grain
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decode(RGBA.self, forKey: .color)
        baseWidth = try c.decode(CGFloat.self, forKey: .baseWidth)
        minWidthScale = try c.decode(CGFloat.self, forKey: .minWidthScale)
        pressureExponent = try c.decode(CGFloat.self, forKey: .pressureExponent)
        if let kind = try c.decodeIfPresent(BrushKind.self, forKey: .kind) {
            self.kind = kind
        } else {
            // 老存档：当时只有“半透明色=荧光笔”的约定，按此恢复渲染层级
            self.kind = color.a < 0.99 ? .highlighter : .pen
        }
        grain = try c.decodeIfPresent(CGFloat.self, forKey: .grain) ?? 0
    }

    static let defaultPen = StrokeStyle(
        color: .black, baseWidth: 8, minWidthScale: 0.12, pressureExponent: 0.6
    )

    static func pen(color: RGBA = .black, width: CGFloat = 8) -> StrokeStyle {
        StrokeStyle(color: color, baseWidth: width, minWidthScale: 0.12, pressureExponent: 0.6, kind: .pen)
    }

    static func highlighter(color: RGBA = RGBA(r: 1, g: 0.85, b: 0.2, a: 0.45), width: CGFloat = 24) -> StrokeStyle {
        StrokeStyle(color: color, baseWidth: width, minWidthScale: 0.85, pressureExponent: 1, kind: .highlighter)
    }

    /// 钢笔：弱起步 + 强压感 + 倾斜变细（笔尖立起按压最粗，倾斜收细）
    static func fountainPen(color: RGBA = .black, width: CGFloat = 8) -> StrokeStyle {
        StrokeStyle(color: color, baseWidth: width, minWidthScale: 0.08, pressureExponent: 0.7, kind: .fountainPen)
    }

    /// 铅笔：侧锋涂抹（倾斜变宽变淡）+ 颗粒纹理
    static func pencil(color: RGBA = RGBA(r: 0.25, g: 0.25, b: 0.27, a: 1), width: CGFloat = 6) -> StrokeStyle {
        StrokeStyle(color: color, baseWidth: width, minWidthScale: 0.3, pressureExponent: 1, kind: .pencil, grain: 0.35)
    }

    /// 压力（0...1）-> 笔宽（世界单位，不含倾斜响应）
    func width(forPressure pressure: CGFloat) -> CGFloat {
        let p = min(max(pressure, 0), 1)
        return baseWidth * (minWidthScale + (1 - minWidthScale) * pow(p, pressureExponent))
    }

    /// 笔尖响应：压力 + 倾斜 -> （宽度，不透明度）。
    /// - Parameter altitude: 笔与屏幕法线夹角（π/2 = 垂直，0 = 放平）；手指恒为 π/2。
    func nib(pressure: CGFloat, altitude: CGFloat = .pi / 2) -> (width: CGFloat, alpha: CGFloat) {
        let p = min(max(pressure, 0), 1)
        let alt = min(max(altitude, 0), .pi / 2)
        switch kind {
        case .pen, .highlighter:
            return (width(forPressure: p), 1)
        case .fountainPen:
            // 倾斜收细：垂直=全宽，放平≈45%
            let tilt = 0.45 + 0.55 * sin(alt)
            return (width(forPressure: p) * tilt, 1)
        case .pencil:
            // 侧锋：放平变宽（最高 2.8x）变淡；轻触本就淡
            let t = 1 - alt / (.pi / 2)
            let alpha = (0.3 + 0.7 * p) * (1 - 0.5 * t)
            return (width(forPressure: p) * (1 + 1.8 * t), alpha)
        }
    }

    /// 笔宽反推压力（局部擦除后碎片重建 raw 点用；倾斜已烘焙进宽度，反推是近似值，
    /// 碎片 spine 自带宽度/透明度不受影响，仅 raw 点压力近似）
    func pressure(forWidth width: CGFloat) -> CGFloat {
        guard baseWidth > 0, pressureExponent != 0, minWidthScale < 1 else { return 1 }
        let t = min(max(width / baseWidth, minWidthScale), 1)
        if t <= minWidthScale { return 0 }
        return pow((t - minWidthScale) / (1 - minWidthScale), 1 / pressureExponent)
    }
}

// MARK: - 输入点 / 笔画

/// 原始输入点（世界坐标）。spine 可由 points 确定性重建，故 Stroke 只存 raw。
nonisolated struct StrokePoint: Equatable, Sendable, Codable {
    /// 世界坐标
    var x, y: CGFloat
    /// 压力 0...1
    var pressure: CGFloat
    /// 笔倾斜：与屏幕法线夹角（π/2 = 垂直），弧度
    var altitude: CGFloat
    /// 笔方位角，弧度
    var azimuth: CGFloat
    var timestamp: TimeInterval

    var position: CGPoint {
        get { CGPoint(x: x, y: y) }
        set { x = newValue.x; y = newValue.y }
    }

    init(position: CGPoint, pressure: CGFloat, altitude: CGFloat = .pi / 2, azimuth: CGFloat = 0, timestamp: TimeInterval = 0) {
        self.x = position.x
        self.y = position.y
        self.pressure = pressure
        self.altitude = altitude
        self.azimuth = azimuth
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case x, y, pressure, altitude, azimuth, timestamp
    }
}

/// 一笔：原始输入点列 + 世界 spine（滤波重采样后）+ 样式 + 世界包围盒。
/// spine 随笔画存档：LOD 重 tessellate、碎片重建都从它出发，无需重跑采样器。
nonisolated struct Stroke: Equatable, Sendable, Codable, Identifiable {
    var id: UUID
    var points: [StrokePoint]
    var style: StrokeStyle
    /// 世界包围盒（含笔宽），提交时由几何层算出
    var bounds: CGRect
    /// 世界 spine（中线+宽度），提交时确定
    var spine: [SpinePoint]

    init(id: UUID = UUID(), points: [StrokePoint], style: StrokeStyle, bounds: CGRect = .null, spine: [SpinePoint] = []) {
        self.id = id
        self.points = points
        self.style = style
        self.bounds = bounds
        self.spine = spine
    }

    enum CodingKeys: String, CodingKey {
        case id, points, style, boundsX, boundsY, boundsW, boundsH, spine
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        points = try c.decode([StrokePoint].self, forKey: .points)
        style = try c.decode(StrokeStyle.self, forKey: .style)
        bounds = CGRect(
            x: try c.decode(CGFloat.self, forKey: .boundsX),
            y: try c.decode(CGFloat.self, forKey: .boundsY),
            width: try c.decode(CGFloat.self, forKey: .boundsW),
            height: try c.decode(CGFloat.self, forKey: .boundsH)
        )
        // spine 缺失时回空（旧存档兼容，加载时从 points 重建）
        spine = try c.decodeIfPresent([SpinePoint].self, forKey: .spine) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(points, forKey: .points)
        try c.encode(style, forKey: .style)
        try c.encode(bounds.origin.x, forKey: .boundsX)
        try c.encode(bounds.origin.y, forKey: .boundsY)
        try c.encode(bounds.size.width, forKey: .boundsW)
        try c.encode(bounds.size.height, forKey: .boundsH)
        try c.encode(spine, forKey: .spine)
    }
}

// MARK: - 几何中间/输出类型

/// 中线采样点（世界坐标 + 该处笔宽 + 不透明度；透明度来自笔刷倾斜响应）
nonisolated struct SpinePoint: Equatable, Sendable, Codable {
    var center: CGPoint
    var width: CGFloat
    /// 不透明度 0...1（老存档无此键 -> 1，渲染不变）
    var alpha: CGFloat = 1

    enum CodingKeys: String, CodingKey {
        case x, y, width, alpha
    }

    init(center: CGPoint, width: CGFloat, alpha: CGFloat = 1) {
        self.center = center
        self.width = width
        self.alpha = alpha
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        center = CGPoint(
            x: try c.decode(CGFloat.self, forKey: .x),
            y: try c.decode(CGFloat.self, forKey: .y)
        )
        width = try c.decode(CGFloat.self, forKey: .width)
        alpha = try c.decodeIfPresent(CGFloat.self, forKey: .alpha) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(center.x, forKey: .x)
        try c.encode(center.y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(alpha, forKey: .alpha)
    }
}

/// 已提交笔画的渲染数据（Store -> Metal 视图，不含 UIKit）
nonisolated struct RenderedStroke: Sendable {
    var id: UUID
    var mesh: StrokeMesh
    var bounds: CGRect
    /// 笔刷种类（渲染层级用：荧光笔画在墨线下）
    var kind: BrushKind
}

extension Array {
    /// 稳定分区：荧光笔在前、其余在后（各自分区内保序），导出/渲染层级用
    func highlightersFirst(kindOf: (Element) -> BrushKind) -> [Element] {
        let (hi, rest) = (filter { kindOf($0) == .highlighter }, filter { kindOf($0) != .highlighter })
        return hi + rest
    }
}

/// 顶点布局必须与 shader 一致：float2 position + float4 color = 24 字节。
/// 位置是相机相对坐标（point − renderOrigin，先 double 相减再转 float，
/// 见 StrokeMetalView.renderOrigin）：无限画布的世界坐标 + 深度缩放下，
/// float32 直接存绝对坐标会有肉眼可见的抖动（~1e5 世界单位即现形），
/// Metal 在 iOS 上不支持 double 顶点属性，所以相对化必须在 CPU 侧做。
nonisolated struct StrokeVertex: Sendable {
    var x, y: Float
    var r, g, b, a: Float

    init(position: CGPoint, color: RGBA) {
        self.x = Float(position.x)
        self.y = Float(position.y)
        self.r = color.r
        self.g = color.g
        self.b = color.b
        self.a = color.a
    }

    /// 相机相对顶点：double 精度相减后再转 float，避免 float32 灾难相消。
    init(position: CGPoint, relativeTo origin: CGPoint, color: RGBA) {
        self.x = Float(Double(position.x) - Double(origin.x))
        self.y = Float(Double(position.y) - Double(origin.y))
        self.r = color.r
        self.g = color.g
        self.b = color.b
        self.a = color.a
    }
}

/// 三角形网格（世界坐标）
nonisolated struct StrokeMesh: Sendable {
    var vertices: [StrokeVertex]
    var indices: [UInt32]

    static let empty = StrokeMesh(vertices: [], indices: [])

    var isEmpty: Bool { vertices.isEmpty || indices.isEmpty }
}
