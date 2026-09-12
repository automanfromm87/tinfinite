// CanvasLibrary.swift
// 画布文档库（多画布管理）：文档列表缓存 + 增删改 + 逐文档持久化 + 旧单文件迁移。
// 只依赖 Foundation/Combine（无 UIKit/SwiftUI），可进单测。

import Combine
import Foundation

// MARK: - 文档模型

nonisolated struct CanvasDocumentMeta: Codable, Sendable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
}

nonisolated struct CanvasDocument: Codable, Sendable, Equatable {
    var version: Int
    var meta: CanvasDocumentMeta
    var strokes: [Stroke]
    /// 内容节点（老文档无此键 -> 空数组，向后兼容，不升版本）
    var nodes: [ContentNode]

    init(meta: CanvasDocumentMeta, strokes: [Stroke] = [], nodes: [ContentNode] = []) {
        self.version = DrawingStore.currentVersion
        self.meta = meta
        self.strokes = strokes
        self.nodes = nodes
    }

    enum CodingKeys: String, CodingKey {
        case version, meta, strokes, nodes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        meta = try c.decode(CanvasDocumentMeta.self, forKey: .meta)
        strokes = try c.decode([Stroke].self, forKey: .strokes)
        nodes = try c.decodeIfPresent([ContentNode].self, forKey: .nodes) ?? []
    }
}

// MARK: - 文档库

@MainActor
final class CanvasLibrary: ObservableObject {
    /// 文档（按更新时间倒序）
    @Published private(set) var documents: [CanvasDocument] = []

    private let directory: URL
    private let legacyURL: URL?

    /// - Parameters:
    ///   - directory: 文档目录（nil = 默认 App Support 目录；单测传临时目录）
    ///   - legacyURL: 旧单文件路径（默认用旧路径；传 nil 禁用迁移；单测可传临时路径）
    init(directory: URL? = nil, legacyURL: URL? = DrawingStore.legacyURL, autoCreateFirst: Bool = true) {
        let dir = directory ?? DrawingStore.documentsDirectory() ?? FileManager.default.temporaryDirectory
        self.directory = dir
        self.legacyURL = legacyURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        migrateLegacyIfNeeded()
        reload()
        if documents.isEmpty, autoCreateFirst {
            createDocument(title: "我的第一张画布")
        }
    }

    // MARK: - 查询

    func document(id: UUID) -> CanvasDocument? {
        documents.first { $0.meta.id == id }
    }

    /// 读节点图片数据（导出用）
    func imageData(file: String) -> Data? {
        DrawingStore.loadImageData(file: file, beside: directory)
    }

    // MARK: - 变更

    @discardableResult
    func createDocument(title: String? = nil) -> CanvasDocument {
        let now = Date()
        let doc = CanvasDocument(
            meta: CanvasDocumentMeta(
                id: UUID(),
                title: title ?? untitledName(),
                createdAt: now,
                updatedAt: now
            )
        )
        documents.insert(doc, at: 0)
        save(doc)
        return doc
    }

    /// 更新某文档的笔画（自动存档入口）：刷新缓存 + 写盘 + 置顶
    func updateStrokes(id: UUID, strokes: [Stroke]) {
        updateContent(id: id, strokes: strokes, nodes: document(id: id)?.nodes ?? [])
    }

    /// 更新某文档的笔画 + 节点（自动存档入口）：刷新缓存 + 写盘 + 置顶
    func updateContent(id: UUID, strokes: [Stroke], nodes: [ContentNode]) {
        guard let index = documents.firstIndex(where: { $0.meta.id == id }) else { return }
        documents[index].strokes = strokes
        documents[index].nodes = nodes
        documents[index].meta.updatedAt = Date()
        let doc = documents[index]
        save(doc)
        // 移到最前（最近更新优先）
        documents.remove(at: index)
        documents.insert(doc, at: 0)
    }

    func rename(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = documents.firstIndex(where: { $0.meta.id == id }) else { return }
        documents[index].meta.title = trimmed
        documents[index].meta.updatedAt = Date()
        save(documents[index])
    }

    func delete(id: UUID) {
        guard let index = documents.firstIndex(where: { $0.meta.id == id }) else { return }
        let doc = documents.remove(at: index)
        DrawingStore.deleteDocument(id: id, in: directory)
        // 连带删除节点图片（孤儿文件不残留）
        for file in doc.nodes.compactMap(\.imageFile) {
            DrawingStore.deleteImageFile(file, beside: directory)
        }
    }

    func reload() {
        documents = DrawingStore.loadAllDocuments(from: directory)
            .sorted { $0.meta.updatedAt > $1.meta.updatedAt }
    }

    // MARK: - 内部

    private func save(_ doc: CanvasDocument) {
        do {
            try DrawingStore.saveDocument(doc, to: directory)
        } catch {
            print("[CanvasLibrary] save failed: \(error)")
        }
    }

    private func untitledName() -> String {
        let base = "无标题画布"
        let taken = Set(documents.map(\.meta.title))
        if !taken.contains(base) { return base }
        var i = 2
        while taken.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// 旧单文件迁移：documents 为空且旧文件存在 -> 导入为一张画布并删除旧文件
    private func migrateLegacyIfNeeded() {
        guard let legacyURL,
              DrawingStore.loadAllDocuments(from: directory).isEmpty,
              FileManager.default.fileExists(atPath: legacyURL.path)
        else { return }
        do {
            let strokes = try DrawingStore.load(from: legacyURL)
            guard !strokes.isEmpty else {
                DrawingStore.clearPersisted(at: legacyURL)
                return
            }
            let now = Date()
            let doc = CanvasDocument(
                meta: CanvasDocumentMeta(
                    id: UUID(), title: "我的画布", createdAt: now, updatedAt: now
                ),
                strokes: strokes
            )
            try DrawingStore.saveDocument(doc, to: directory)
            DrawingStore.clearPersisted(at: legacyURL)
            print("[CanvasLibrary] migrated \(strokes.count) legacy strokes")
        } catch {
            print("[CanvasLibrary] legacy migration failed: \(error)")
        }
    }
}
