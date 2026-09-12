// ContentNode.swift
// 内容节点模型（纯 Foundation，可单测）：形状/文本/图片/便签 + 世界矩形。
// 渲染见 ContentNodeViews.swift，撤销/选择见 ContentStore.swift。

import CoreGraphics
import Foundation

/// 形状种类
nonisolated enum ContentShape: String, Codable, Sendable, Equatable {
    case rectangle
    case ellipse
}

/// 节点种类
nonisolated enum ContentNodeKind: Codable, Sendable, Equatable {
    case shape(ContentShape)
    case text
    case note
    case image
}

/// 内容节点：世界坐标系下的一个富内容对象。
/// frame/text/fill/imageFile 共同决定外观；id 稳定，跨存档不变。
nonisolated struct ContentNode: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var kind: ContentNodeKind
    var frame: CGRect
    /// 文本/便签的文字内容（形状/图片忽略）
    var text: String
    /// 填充色（形状填充、便签底色；文本/图片忽略）
    var fill: RGBA
    /// 图片文件名（images 目录下；非图片节点为 nil）
    var imageFile: String?

    init(
        id: UUID = UUID(),
        kind: ContentNodeKind,
        frame: CGRect,
        text: String = "",
        fill: RGBA = .black,
        imageFile: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.text = text
        self.fill = fill
        self.imageFile = imageFile
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, text, fill, imageFile
        case frameX, frameY, frameW, frameH
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ContentNodeKind.self, forKey: .kind)
        frame = CGRect(
            x: try c.decode(CGFloat.self, forKey: .frameX),
            y: try c.decode(CGFloat.self, forKey: .frameY),
            width: try c.decode(CGFloat.self, forKey: .frameW),
            height: try c.decode(CGFloat.self, forKey: .frameH)
        )
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        fill = try c.decodeIfPresent(RGBA.self, forKey: .fill) ?? .black
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(frame.origin.x, forKey: .frameX)
        try c.encode(frame.origin.y, forKey: .frameY)
        try c.encode(frame.size.width, forKey: .frameW)
        try c.encode(frame.size.height, forKey: .frameH)
        try c.encode(text, forKey: .text)
        try c.encode(fill, forKey: .fill)
        try c.encodeIfPresent(imageFile, forKey: .imageFile)
    }
}
