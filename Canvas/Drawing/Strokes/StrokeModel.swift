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

// MARK: - 笔样式

/// 笔样式：颜色 + 基础笔宽（世界单位，压力=1 时）+ 压力曲线。
/// width(p) = base * (minScale + (1-minScale) * p^exponent)
nonisolated struct StrokeStyle: Equatable, Sendable, Codable, Hashable {
    var color: RGBA
    /// 基础笔宽（世界单位）
    var baseWidth: CGFloat
    /// 零压力时的宽度比例 0...1
    var minWidthScale: CGFloat
    /// 压力指数：<1 更灵敏，>1 更迟钝
    var pressureExponent: CGFloat

    static let defaultPen = StrokeStyle(
        color: .black, baseWidth: 8, minWidthScale: 0.12, pressureExponent: 0.6
    )

    static func pen(color: RGBA = .black, width: CGFloat = 8) -> StrokeStyle {
        StrokeStyle(color: color, baseWidth: width, minWidthScale: 0.12, pressureExponent: 0.6)
    }

    static func highlighter(color: RGBA = RGBA(r: 1, g: 0.85, b: 0.2, a: 0.45), width: CGFloat = 24) -> StrokeStyle {
        StrokeStyle(color: color, baseWidth: width, minWidthScale: 0.85, pressureExponent: 1)
    }

    /// 压力（0...1）-> 笔宽（世界单位）
    func width(forPressure pressure: CGFloat) -> CGFloat {
        let p = min(max(pressure, 0), 1)
        return baseWidth * (minWidthScale + (1 - minWidthScale) * pow(p, pressureExponent))
    }

    /// 笔宽反推压力（局部擦除后碎片重建 raw 点用）
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

/// 中线采样点（世界坐标 + 该处笔宽）
nonisolated struct SpinePoint: Equatable, Sendable, Codable {
    var center: CGPoint
    var width: CGFloat

    enum CodingKeys: String, CodingKey {
        case x, y, width
    }

    init(center: CGPoint, width: CGFloat) {
        self.center = center
        self.width = width
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        center = CGPoint(
            x: try c.decode(CGFloat.self, forKey: .x),
            y: try c.decode(CGFloat.self, forKey: .y)
        )
        width = try c.decode(CGFloat.self, forKey: .width)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(center.x, forKey: .x)
        try c.encode(center.y, forKey: .y)
        try c.encode(width, forKey: .width)
    }
}

/// 已提交笔画的渲染数据（Store -> Metal 视图，不含 UIKit）
nonisolated struct RenderedStroke: Sendable {
    var id: UUID
    var mesh: StrokeMesh
    var bounds: CGRect
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
