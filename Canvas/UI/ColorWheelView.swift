// ColorWheelView.swift
// HSV 色轮拾取器：色相环（角度）× 饱和度（半径）+ 明度条。
// 只改 RGB，不碰 alpha（荧光笔透明度由样式层固定）。

import SwiftUI
import UIKit

struct ColorWheelView: View {
    @Binding var color: RGBA
    /// 轮直径
    var diameter: CGFloat = 220

    @Environment(\.dismiss) private var dismiss

    private var hsv: HSV { HSV(rgba: color) }

    var body: some View {
        VStack(spacing: 16) {
            // 色轮：360 一度弧显式绘制（h=0 正红在正上方，顺时针增大，与 ColorWheelMath 一致）
            wheel
                .frame(width: diameter, height: diameter)
            // 明度条
            valueBar
                .frame(height: 22)
            // 预览 + 确认
            HStack {
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                Text(hexString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    /// 光栅化缓存：色轮内容静态，画一次存图（主线程唯一写）。
    /// 之前用 Canvas 每颜色变化重建 360 个 Path，真机持续拖拽下事件积压至假死。
    private static var cachedWheel: UIImage?

    private var wheel: some View {
        let radius = diameter / 2
        let center = CGPoint(x: radius, y: radius)
        return Image(uiImage: Self.wheelImage(diameter: diameter))
            .resizable()
            .frame(width: diameter, height: diameter)
            .overlay {
            // 拾取指示器
            let pos = ColorWheelMath.position(hue: hsv.h, saturation: hsv.s, center: center, radius: radius)
            Circle()
                .stroke(Color.white, lineWidth: 2.5)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .frame(width: 22, height: 22)
                .position(pos)
                .allowsHitTesting(false)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let local = value.location
                    let (h, s) = ColorWheelMath.hueSaturation(at: local, center: center, radius: radius)
                    color = HSV(h: h, s: s, v: hsv.v).rgba(alpha: color.a)
                }
        )
        .accessibilityIdentifier("colorWheel")
    }

    private var valueBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            RoundedRectangle(cornerRadius: 11)
                .fill(LinearGradient(
                    colors: [.black, HSV(h: hsv.h, s: hsv.s, v: 1).rgba().swiftUIColor],
                    startPoint: .leading, endPoint: .trailing
                ))
                .overlay {
                    Circle()
                        .stroke(Color.white, lineWidth: 2.5)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .frame(width: 20, height: 20)
                        .position(x: hsv.v * width, y: proxy.size.height / 2)
                        .allowsHitTesting(false)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let v = min(max(value.location.x / width, 0), 1)
                            color = HSV(h: hsv.h, s: hsv.s, v: v).rgba(alpha: color.a)
                        }
                )
                .accessibilityIdentifier("valueBar")
        }
    }

    private var hexString: String {
        String(format: "#%02X%02X%02X",
               Int(color.r * 255), Int(color.g * 255), Int(color.b * 255))
    }

    /// 画一次色轮位图并缓存。h=0 正红在正上方、顺时针增大，与 ColorWheelMath 一致。
    /// 注意 UIKit 坐标 y 朝下：CG arc 里 clockwise:false 在翻转上下文中视觉为顺时针。
    private static func wheelImage(diameter: CGFloat) -> UIImage {
        if let cached = cachedWheel, cached.size.width == diameter { return cached }
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter), format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            let c = CGPoint(x: diameter / 2, y: diameter / 2)
            let r = diameter / 2
            // 360 色相扇区（1.5° 宽、0.5° 重叠，防发丝缝）
            for degree in 0..<360 {
                let rgba = HSV(h: CGFloat(degree) / 360, s: 1, v: 1).rgba()
                cg.setFillColor(UIColor(red: CGFloat(rgba.r), green: CGFloat(rgba.g),
                                        blue: CGFloat(rgba.b), alpha: 1).cgColor)
                cg.move(to: c)
                cg.addArc(center: c, radius: r,
                          startAngle: (CGFloat(degree) - 90) * .pi / 180,
                          endAngle: (CGFloat(degree) - 88.5) * .pi / 180,
                          clockwise: false)
                cg.closePath()
                cg.fillPath()
            }
            // 饱和度：圆心白 -> 边缘透明
            let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 1]) {
                cg.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                                      endCenter: c, endRadius: r, options: [])
            }
        }
        cachedWheel = image
        return image
    }
}
