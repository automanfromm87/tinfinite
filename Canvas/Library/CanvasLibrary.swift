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
    /// 上次离开时的相机（nil = 默认视角；老文档无此键 -> nil）
    var camera: Camera?

    init(meta: CanvasDocumentMeta, strokes: [Stroke] = [], nodes: [ContentNode] = [], camera: Camera? = nil) {
        self.version = DrawingStore.currentVersion
        self.meta = meta
        self.strokes = strokes
        self.nodes = nodes
        self.camera = camera
    }

    enum CodingKeys: String, CodingKey {
        case version, meta, strokes, nodes, camera
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        meta = try c.decode(CanvasDocumentMeta.self, forKey: .meta)
        strokes = try c.decode([Stroke].self, forKey: .strokes)
        nodes = try c.decodeIfPresent([ContentNode].self, forKey: .nodes) ?? []
        camera = try c.decodeIfPresent(Camera.self, forKey: .camera)
    }
}

// MARK: - 文档库

@MainActor
final class CanvasLibrary: ObservableObject {
    /// 文档（按更新时间倒序）
    @Published private(set) var documents: [CanvasDocument] = []

    private let directory: URL
    private let legacyURL: URL?
    /// IO 串行队列：JSON 编码 + 文件写全部在这里；主线程只做 diff（字段比较，无编码）
    private let ioQueue = DispatchQueue(label: "canvas.library.io", qos: .utility)
    /// 上次存档快照（diff 基准；只在主线程读写）
    private var lastSaved: [UUID: SavedSnapshot] = [:]

    /// 上次存档的内容快照（diff 用；CoW 值语义，快照本身 O(1)）
    private struct SavedSnapshot {
        var strokes: [Stroke]
        var nodes: [ContentNode]
        var meta: CanvasDocumentMeta
        var camera: Camera?
    }

    /// 存档计划（主线程 diff 产物；Sendable，可安全跨线程执行）
    private struct SavePlan: Sendable {
        var docID: UUID
        var upsertStrokes: [Stroke]
        var removeStrokeIDs: [UUID]
        /// nil = 节点未变，跳过 nodes.json
        var nodes: [ContentNode]?
        var meta: CanvasDocumentMeta
        var camera: Camera?
        var strokeIDs: [UUID]
    }

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
        lastSaved.removeValue(forKey: id)
        // 目录递归删除可能很慢（几千笔文件），放后台队列
        let dir = directory
        let imageFiles = doc.nodes.compactMap(\.imageFile)
        ioQueue.async {
            DrawingStore.deleteDocument(id: id, in: dir)
            // 连带删除节点图片（孤儿文件不残留）
            for file in imageFiles {
                DrawingStore.deleteImageFile(file, beside: dir)
            }
        }
    }

    /// 相机存档（手势结束/离开文档时调）：只重写 manifest 小文件；
    /// 不碰 updatedAt、不重排（否则每次平移都会置顶文档）。
    func updateCamera(id: UUID, camera: Camera) {
        guard let index = documents.firstIndex(where: { $0.meta.id == id }),
              documents[index].camera != camera
        else { return }
        documents[index].camera = camera
        save(documents[index])
    }

    /// 等待后台存档全部落盘（单测 + 切后台时调）
    func flushSaves() {
        ioQueue.sync {}
    }

    func reload() {
        documents = DrawingStore.loadAllDocuments(from: directory)
            .sorted { $0.meta.updatedAt > $1.meta.updatedAt }
    }

    // MARK: - 内部

    /// 增量存档：主线程 diff（字段比较，无编码）算出计划，后台队列执行 IO。
    /// 串行队列保序；IO 失败则作废该文档的 diff 基准，下次全量重写（不静默丢数据）。
    private func save(_ doc: CanvasDocument) {
        let id = doc.meta.id
        let prev = lastSaved[id]
        var upserts: [Stroke] = []
        var removed: [UUID] = []
        if let prev {
            let oldByID = Dictionary(uniqueKeysWithValues: prev.strokes.map { ($0.id, $0) })
            var newIDs = Set<UUID>()
            newIDs.reserveCapacity(doc.strokes.count)
            for s in doc.strokes {
                newIDs.insert(s.id)
                if oldByID[s.id] != s {
                    upserts.append(s)
                }
            }
            removed = oldByID.keys.filter { !newIDs.contains($0) }
        } else {
            upserts = doc.strokes
        }
        let nodesChanged = prev?.nodes != doc.nodes
        lastSaved[id] = SavedSnapshot(strokes: doc.strokes, nodes: doc.nodes, meta: doc.meta, camera: doc.camera)
        let plan = SavePlan(
            docID: id, upsertStrokes: upserts, removeStrokeIDs: removed,
            nodes: nodesChanged ? doc.nodes : nil,
            meta: doc.meta, camera: doc.camera, strokeIDs: doc.strokes.map(\.id)
        )
        let dir = directory
        ioQueue.async { [weak self] in
            do {
                for s in plan.upsertStrokes {
                    try DrawingStore.saveStroke(s, docID: plan.docID, in: dir)
                }
                DrawingStore.removeStrokeFiles(docID: plan.docID, ids: plan.removeStrokeIDs, in: dir)
                if let nodes = plan.nodes {
                    try DrawingStore.saveNodes(nodes, docID: plan.docID, in: dir)
                }
                try DrawingStore.saveManifest(
                    meta: plan.meta, camera: plan.camera, strokeIDs: plan.strokeIDs,
                    docID: plan.docID, in: dir
                )
            } catch {
                print("[CanvasLibrary] save failed: \(error)")
                Task { @MainActor [weak self] in
                    self?.lastSaved.removeValue(forKey: plan.docID)
                }
            }
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
