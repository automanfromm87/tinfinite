// DocumentThumbnailView.swift
// 文档缩略图（侧边栏行内）：笔画折线 + 节点色块，纯文档函数，无存储、永远新鲜。
// 映射复用 MinimapMath（letterbox + 退化撑开）。

import SwiftUI

/// 异步缩略图：笔画后台懒加载（.task + @State），行内只渲染节点/占位，加载完刷新。
/// 避免在 List 行 body 里同步解码几千笔（主线程 jank）或在构建中途发布。
///
/// 重栅格化节流：自动存档每次都会发布 `library.documents`（updatedAt 变了），
/// 但缩略图数据只跟 `thumbnailRevision` 走（最多 5s 一次），且 DocumentThumbnailView
/// 用 `.equatable()` 按 (id, revision, 计数, 尺寸) 短路，避免每次发布都重画 300 条折线。
struct AsyncThumbnailView: View {
    @ObservedObject var library: CanvasLibrary
    var doc: CanvasDocument
    var size = CGSize(width: 64, height: 48)

    @State private var strokes: [Stroke]?
    /// 笔画实际到位的次数。必须参与相等比较：代号变化会先用**旧**数据重画一次，
    /// 异步取回新笔画后代号没变，只比代号的话这一帧会被跳过，缩略图永远慢一拍。
    @State private var dataStamp = 0

    /// 重载键：文档 id 或缩略图代号变化才重新取笔画
    private struct ThumbKey: Equatable {
        var id: UUID
        var revision: Int
    }

    var body: some View {
        DocumentThumbnailView(
            doc: resolvedDoc, size: size,
            revision: library.thumbnailRevision &* 2_000_003 &+ dataStamp
        )
        .equatable()
        .task(id: ThumbKey(id: doc.meta.id, revision: library.thumbnailRevision)) {
            strokes = await library.strokes(for: doc.meta.id)
            dataStamp &+= 1
        }
    }

    private var resolvedDoc: CanvasDocument {
        var d = doc
        // 已加载文档直接用内存笔画（刚画完的行不等后台读）
        d.strokes = doc.strokesLoaded ? doc.strokes : (strokes ?? [])
        return d
    }
}

struct DocumentThumbnailView: View, Equatable {
    var doc: CanvasDocument
    var size = CGSize(width: 64, height: 48)
    /// 内容代号：只有它（或身份/计数/尺寸）变化才值得重画
    var revision = 0

    /// 深比较 [Stroke] 是 O(总点数)，比重画还贵；只比廉价的身份 + 代号 + 计数。
    static func == (a: DocumentThumbnailView, b: DocumentThumbnailView) -> Bool {
        a.doc.meta.id == b.doc.meta.id
            && a.revision == b.revision
            && a.size == b.size
            && a.doc.strokes.count == b.doc.strokes.count
            && a.doc.nodes.count == b.doc.nodes.count
    }

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
            let n = stroke.spine.count
            var color = stroke.style.color
            guard n > 0 else {
                // 无 spine（老数据）：退化为 bounds 对角线示意
                let b = stroke.bounds
                return ([CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY)], color)
            }
            // 一次遍历同时抽稀点列与累计透明度：不物化 spine.map(\.center) 全量数组
            let step = max(1, (n + 63) / 64)
            var points: [CGPoint] = []
            points.reserveCapacity((n + step - 1) / step)
            var alphaSum: CGFloat = 0
            for i in stride(from: 0, to: n, by: step) {
                points.append(stroke.spine[i].center)
                alphaSum += stroke.spine[i].alpha
            }
            // 透明度取抽样点平均（倾斜变淡在缩略图中保留；64px 下与全量平均无肉眼差别）
            if !points.isEmpty {
                color.a *= Float(min(max(alphaSum / CGFloat(points.count), 0), 1))
            }
            return (points, color)
        }
    }
}
