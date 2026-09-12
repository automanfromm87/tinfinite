// DocumentThumbnailView.swift
// 文档缩略图（侧边栏行内）：笔画折线 + 节点色块，纯文档函数，无存储、永远新鲜。
// 映射复用 MinimapMath（letterbox + 退化撑开）。

import SwiftUI

struct DocumentThumbnailView: View {
    var doc: CanvasDocument
    var size = CGSize(width: 64, height: 48)

    /// 超量抽样上限（缩略图只示意）
    private static let maxStrokes = 300

    var body: some View {
        Canvas { ctx, sz in
            let strokes = sampledSpines()
            let union = MinimapMath.contentUnion(
                strokes: doc.strokes.map(\.bounds),
                items: doc.nodes.map(\.frame)
            )
            guard let union,
                  let t = MinimapMath.transform(content: union, minimapSize: sz, padding: 3, minSpan: 50)
            else { return }
            // 笔画：中线折线（宽度固定示意）
            for (points, color) in strokes {
                var path = Path()
                path.addLines(points.map { $0.applying(t) })
                ctx.stroke(path, with: .color(color.swiftUIColor), lineWidth: 1.5)
            }
            // 节点：色块
            for node in doc.nodes {
                let rect = node.frame.applying(t)
                switch node.kind {
                case .shape:
                    ctx.fill(Path(rect), with: .color(node.fill.swiftUIColor.opacity(0.85)))
                case .text:
                    ctx.fill(Path(rect), with: .color(.gray.opacity(0.35)))
                case .note:
                    ctx.fill(Path(rect), with: .color(node.fill.swiftUIColor))
                case .image:
                    ctx.fill(Path(rect), with: .color(.gray.opacity(0.6)))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.primary.opacity(0.1), lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// 抽样笔画中线（点列也抽稀：缩略图 64px 不需要全精度）
    private func sampledSpines() -> [([CGPoint], RGBA)] {
        var list = doc.strokes
        if list.count > Self.maxStrokes {
            let step = (list.count + Self.maxStrokes - 1) / Self.maxStrokes
            list = stride(from: 0, to: list.count, by: step).map { list[$0] }
        }
        return list.map { stroke in
            let centers = stroke.spine.map(\.center)
            let points: [CGPoint]
            if centers.count > 64 {
                let step = (centers.count + 63) / 64
                points = stride(from: 0, to: centers.count, by: step).map { centers[$0] }
            } else if centers.isEmpty {
                // 无 spine（老数据）：退化为 bounds 对角线示意
                let b = stroke.bounds
                points = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY)]
            } else {
                points = centers
            }
            return (points, stroke.style.color)
        }
    }
}
