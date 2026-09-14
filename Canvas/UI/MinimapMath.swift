// MinimapMath.swift
// 导览/适配缩放的纯数学：内容并集 + 世界->minimap 映射。无 UIKit 依赖，可进单测。

import CoreGraphics

nonisolated enum MinimapMath {
    /// 内容并集（笔画 bounds + 节点世界矩形），空内容返回 nil
    static func contentUnion(strokes: [CGRect], items: [CGRect]) -> CGRect? {
        var rect: CGRect?
        for r in strokes + items {
            guard r.width.isFinite, r.height.isFinite else { continue }
            rect = rect?.union(r) ?? r
        }
        return rect
    }

    /// 世界 rect -> minimap rect 的映射（letterbox 居中 + padding）。
    /// 退化矩形（点/线）先撑开到 minSpan 世界单位，保证可显示、可逆。
    static func transform(content: CGRect, minimapSize: CGSize, padding: CGFloat, minSpan: CGFloat = 200) -> CGAffineTransform? {
        guard minimapSize.width > padding * 2, minimapSize.height > padding * 2,
              content.width.isFinite, content.height.isFinite
        else { return nil }
        var span = content
        if span.width < minSpan {
            span = span.insetBy(dx: -(minSpan - span.width) / 2, dy: 0)
        }
        if span.height < minSpan {
            span = span.insetBy(dx: 0, dy: -(minSpan - span.height) / 2)
        }
        guard span.width > 0, span.height > 0 else { return nil }
        let scale = min(
            (minimapSize.width - padding * 2) / span.width,
            (minimapSize.height - padding * 2) / span.height
        )
        guard scale.isFinite, scale > 0 else { return nil }
        // 世界点 -> minimap 点：先缩放到原点，再搬到 minimap 中心对齐
        let tx = minimapSize.width / 2 - (span.midX * scale)
        let ty = minimapSize.height / 2 - (span.midY * scale)
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
    }
}
