// DocumentExporter.swift
// 文档导出（纯 CoreGraphics/CoreText/ImageIO，可单测）：把 CanvasDocument 渲染为 PNG。
// 笔画按 tessellate 网格三角面片填充（与 Metal 渲染同源，视觉一致）；
// 节点按形状/文本/便签/图片绘制；整幅内容适配进 maxDimension。

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum DocumentExporter {
    nonisolated struct Options: Sendable {
        /// 长边上限（像素）
        var maxDimension: CGFloat = 2048
        var background: RGBA = .white
        var padding: CGFloat = 40
    }

    /// 渲染文档为 PNG 数据。空文档返回 nil。
    /// - Parameter imageData: 图片节点文件名 -> 文件数据（nil 表示缺图，画占位框）
    static func pngData(
        for doc: CanvasDocument,
        imageData: (String) -> Data? = { _ in nil },
        options: Options = Options()
    ) -> Data? {
        let strokeRects = doc.strokes.map(\.bounds)
        let nodeRects = doc.nodes.map(\.frame)
        guard let union = MinimapMath.contentUnion(strokes: strokeRects, items: nodeRects),
              union.width.isFinite, union.height.isFinite, union.width > 0, union.height > 0
        else { return nil }

        let pad = max(options.padding, 0)
        let scale = min(
            (options.maxDimension - pad * 2) / union.width,
            (options.maxDimension - pad * 2) / union.height
        )
        guard scale.isFinite, scale > 0 else { return nil }
        let width = Int(ceil(union.width * scale + pad * 2))
        let height = Int(ceil(union.height * scale + pad * 2))
        guard width > 0, height > 0, width <= 20000, height <= 20000 else { return nil }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 世界 -> 像素（y 朝下，与 UIKit 一致）
        func px(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - union.minX) * scale + pad, y: (p.y - union.minY) * scale + pad)
        }
        func pxRect(_ r: CGRect) -> CGRect {
            let o = px(r.origin)
            return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
        }

        ctx.setFillColor(cgColor(options.background))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 笔画：三角面片批量填充（同笔一色，整笔一个 path 一次 fill）。
        // 荧光笔先画（与屏幕渲染同层级）；透明度取 spine 平均（倾斜变淡在导出中保留）；
        // 颗粒纹理不导出（整笔单色 fill，无逐顶点抖动）。
        let tolerance = StrokeGeometry.lodTolerance(forScale: scale, screenError: 0.5)
        for stroke in doc.strokes.highlightersFirst(kindOf: { $0.style.kind }) {
            let mesh = StrokeGeometry.tessellate(
                spine: stroke.spine, color: stroke.style.color, flattenTolerance: tolerance
            )
            guard !mesh.indices.isEmpty else { continue }
            let path = CGMutablePath()
            var i = 0
            while i + 2 < mesh.indices.count {
                let a = mesh.vertices[Int(mesh.indices[i])]
                let b = mesh.vertices[Int(mesh.indices[i + 1])]
                let c = mesh.vertices[Int(mesh.indices[i + 2])]
                path.move(to: px(CGPoint(x: Double(a.x), y: Double(a.y))))
                path.addLine(to: px(CGPoint(x: Double(b.x), y: Double(b.y))))
                path.addLine(to: px(CGPoint(x: Double(c.x), y: Double(c.y))))
                path.closeSubpath()
                i += 3
            }
            var flat = stroke.style.color
            if !stroke.spine.isEmpty {
                let avg = stroke.spine.reduce(0 as CGFloat) { $0 + $1.alpha } / CGFloat(stroke.spine.count)
                flat.a *= Float(min(max(avg, 0), 1))
            }
            ctx.setFillColor(cgColor(flat))
            ctx.addPath(path)
            ctx.fillPath()
        }

        // 节点
        for node in doc.nodes {
            drawNode(node, in: ctx, rect: pxRect(node.frame), scale: scale, imageData: imageData)
        }

        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - 节点绘制

    private static func drawNode(
        _ node: ContentNode, in ctx: CGContext, rect: CGRect, scale: CGFloat,
        imageData: (String) -> Data?
    ) {
        switch node.kind {
        case .shape(let shape):
            ctx.setFillColor(cgColor(node.fill))
            switch shape {
            case .rectangle:
                ctx.fill(rect)
            case .ellipse:
                ctx.addPath(CGPath(ellipseIn: rect, transform: nil))
                ctx.fillPath()
            }
        case .text:
            drawText(node.text, in: rect, fontSize: 17 * scale, ctx: ctx)
        case .note:
            ctx.setFillColor(cgColor(node.fill))
            let round = CGPath(
                roundedRect: rect, cornerWidth: 10 * scale, cornerHeight: 10 * scale, transform: nil
            )
            ctx.addPath(round)
            ctx.fillPath()
            drawText(node.text, in: rect.insetBy(dx: 8 * scale, dy: 8 * scale), fontSize: 15 * scale, ctx: ctx)
        case .image:
            if let file = node.imageFile,
               let data = imageData(file) as CFData?,
               let src = CGImageSourceCreateWithData(data, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                ctx.draw(cg, in: aspectFit(
                    imageSize: CGSize(width: cg.width, height: cg.height), in: rect
                ))
            } else {
                // 缺图占位
                ctx.setFillColor(cgColor(RGBA(r: 0.8, g: 0.8, b: 0.8, a: 1)))
                ctx.fill(rect)
            }
        }
    }

    private static func aspectFit(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, rect.width > 0, rect.height > 0 else { return rect }
        let s = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// CoreText 绘制（y 朝下像素空间：翻转后画）
    private static func drawText(_ string: String, in rect: CGRect, fontSize: CGFloat, ctx: CGContext) {
        guard !string.isEmpty, rect.width > 0, rect.height > 0, fontSize >= 1 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: 0, y: 2 * rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attrs = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: cgColor(RGBA(r: 0, g: 0, b: 0, a: 1)),
        ] as CFDictionary
        guard let attrStr = CFAttributedStringCreate(nil, string as CFString, attrs) else { return }
        let setter = CTFramesetterCreateWithAttributedString(attrStr)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, nil)
        CTFrameDraw(frame, ctx)
    }

    private static func cgColor(_ rgba: RGBA) -> CGColor {
        CGColor(
            red: CGFloat(rgba.r), green: CGFloat(rgba.g),
            blue: CGFloat(rgba.b), alpha: CGFloat(rgba.a)
        )
    }
}
