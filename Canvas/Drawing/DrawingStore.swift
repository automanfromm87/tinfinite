// DrawingStore.swift
// 笔画持久化（纯 Foundation，可单测）：版本化 JSON 文档，原子写入。

import Foundation

nonisolated enum DrawingStore {
    nonisolated struct Document: Codable, Sendable {
        var version: Int
        var strokes: [Stroke]
    }

    enum StoreError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    static let currentVersion = 1

    static func save(_ strokes: [Stroke], to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Document(version: currentVersion, strokes: strokes))
        try data.write(to: url, options: .atomic)
    }

    /// 加载存档。文件不存在/损坏抛错（调用方按空画布处理）；版本不匹配抛 unsupportedVersion。
    static func load(from url: URL) throws -> [Stroke] {
        let data = try Data(contentsOf: url)
        let doc = try JSONDecoder().decode(Document.self, from: data)
        guard doc.version == currentVersion else {
            throw StoreError.unsupportedVersion(doc.version)
        }
        return doc.strokes
    }

    static func clearPersisted(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 多文档

    /// 文档目录（Application Support/Canvas/documents/）
    static func documentsDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Canvas/documents", isDirectory: true)
    }

    /// 旧单文件路径（迁移用）
    static var legacyURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Canvas/strokes.json", isDirectory: false)
    }

    static func documentURL(id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    static func saveDocument(_ doc: CanvasDocument, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = documentURL(id: doc.meta.id, in: directory)
        // 安全保存：覆盖前把上一个版本轮转为 .bak（原子写仍可能跨崩溃损坏，
        // 坏主文件时 loadAllDocuments 会回退到 .bak 恢复）。
        if FileManager.default.fileExists(atPath: url.path) {
            let bak = backupURL(id: doc.meta.id, in: directory)
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: url, to: bak)
        }
        let data = try JSONEncoder().encode(doc)
        try data.write(to: url, options: .atomic)
    }

    static func backupURL(id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).bak.json", isDirectory: false)
    }

    /// 加载目录下所有文档（逐个容错）：
    /// - v2 子目录：按 manifest 加载
    /// - v1 单文件：解码后就地迁移到 v2（一次性），失败则保留 v1 下次重试
    /// 坏文件先试备份恢复，实在不行跳过并打印。
    static func loadAllDocuments(from directory: URL) -> [CanvasDocument] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var docs: [CanvasDocument] = []
        for url in files {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if let id = UUID(uuidString: url.lastPathComponent),
                   let doc = loadDocumentV2(id: id, from: directory) {
                    docs.append(doc)
                }
                continue
            }
            guard url.pathExtension == "json", !url.lastPathComponent.hasSuffix(".bak.json") else { continue }
            if let doc = loadDocumentWithBackup(at: url) {
                migrateV1toV2(doc: doc, v1URL: url, in: directory)
                docs.append(doc)
            }
        }
        return docs
    }

    /// 单文档加载：主文件坏则回退 .bak（恢复成功会打印，被跳过也会打印原因）
    static func loadDocumentWithBackup(at url: URL) -> CanvasDocument? {
        do {
            return try loadOne(at: url)
        } catch let original {
            let name = url.deletingPathExtension().lastPathComponent
            let bak = url.deletingLastPathComponent().appendingPathComponent("\(name).bak.json")
            do {
                let doc = try loadOne(at: bak)
                print("[DrawingStore] recovered \(url.lastPathComponent) from backup")
                return doc
            } catch {
                print("[DrawingStore] skip unreadable document \(url.lastPathComponent): \(original)")
                return nil
            }
        }
    }

    private static func loadOne(at url: URL) throws -> CanvasDocument {
        let data = try Data(contentsOf: url)
        let doc = try JSONDecoder().decode(CanvasDocument.self, from: data)
        guard doc.version == currentVersion else { throw StoreError.unsupportedVersion(doc.version) }
        return doc
    }

    static func deleteDocument(id: UUID, in directory: URL) {
        try? FileManager.default.removeItem(at: documentURL(id: id, in: directory))
        try? FileManager.default.removeItem(at: backupURL(id: id, in: directory))
        try? FileManager.default.removeItem(at: docDirectory(id: id, in: directory))
    }

    // MARK: - 增量存档（v2 目录布局）

    /// v2 布局：documents/<uuid>/{manifest.json, manifest.bak.json, nodes.json, strokes/<sid>.json}。
    /// 与 v1（整档单文件）正交：只改变文件组织，不改变模型语义。
    /// - manifest：版本 + 元信息 + 相机 + 笔画 id 有序表（z 序），每次存档重写（附 .bak 轮转）
    /// - strokes/：每笔独立文件，只写变更的笔；缺失/损坏的笔加载时跳过并打印
    /// - nodes.json：整体重写（节点数量级小，全量可接受）
    static let layoutVersion = 2

    nonisolated struct ManifestV2: Codable, Sendable, Equatable {
        var version: Int
        var meta: CanvasDocumentMeta
        var camera: Camera?
        /// 笔画 id（数组顺序 = z 序）
        var strokeIDs: [UUID]
    }

    static func docDirectory(id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func manifestURL(docID: UUID, in directory: URL) -> URL {
        docDirectory(id: docID, in: directory).appendingPathComponent("manifest.json", isDirectory: false)
    }

    static func backupManifestURL(docID: UUID, in directory: URL) -> URL {
        docDirectory(id: docID, in: directory).appendingPathComponent("manifest.bak.json", isDirectory: false)
    }

    static func nodesURL(docID: UUID, in directory: URL) -> URL {
        docDirectory(id: docID, in: directory).appendingPathComponent("nodes.json", isDirectory: false)
    }

    static func strokesDirectory(docID: UUID, in directory: URL) -> URL {
        docDirectory(id: docID, in: directory).appendingPathComponent("strokes", isDirectory: true)
    }

    static func strokeURL(docID: UUID, strokeID: UUID, in directory: URL) -> URL {
        strokesDirectory(docID: docID, in: directory).appendingPathComponent("\(strokeID.uuidString).json", isDirectory: false)
    }

    /// 写单笔（增量存档的基本单位；调用方保证 manifest 随后更新）
    static func saveStroke(_ stroke: Stroke, docID: UUID, in directory: URL) throws {
        let dir = strokesDirectory(docID: docID, in: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(stroke)
        try data.write(to: strokeURL(docID: docID, strokeID: stroke.id, in: directory), options: .atomic)
    }

    /// 删若干笔文件（逐个容错：有一个删不掉不影响其他）
    static func removeStrokeFiles(docID: UUID, ids: [UUID], in directory: URL) {
        for id in ids {
            try? FileManager.default.removeItem(at: strokeURL(docID: docID, strokeID: id, in: directory))
        }
    }

    static func saveNodes(_ nodes: [ContentNode], docID: UUID, in directory: URL) throws {
        let dir = docDirectory(id: docID, in: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(nodes)
        try data.write(to: nodesURL(docID: docID, in: directory), options: .atomic)
    }

    /// 写 manifest（附 .bak 轮转：manifest 是整档的索引，必须可恢复）
    static func saveManifest(meta: CanvasDocumentMeta, camera: Camera?, strokeIDs: [UUID], docID: UUID, in directory: URL) throws {
        let dir = docDirectory(id: docID, in: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = manifestURL(docID: docID, in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            let bak = backupManifestURL(docID: docID, in: directory)
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: url, to: bak)
        }
        let manifest = ManifestV2(version: layoutVersion, meta: meta, camera: camera, strokeIDs: strokeIDs)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    /// 全量写 v2（迁移/兜底用）：笔画 + 节点 + manifest（manifest 最后写）
    static func writeFullV2(doc: CanvasDocument, in directory: URL) throws {
        for s in doc.strokes {
            try saveStroke(s, docID: doc.meta.id, in: directory)
        }
        try saveNodes(doc.nodes, docID: doc.meta.id, in: directory)
        try saveManifest(meta: doc.meta, camera: doc.camera, strokeIDs: doc.strokes.map(\.id), docID: doc.meta.id, in: directory)
    }

    /// 加载单个 v2 文档：manifest 缺失/损坏（连 .bak 都不行）返回 nil；
    /// 缺失/损坏的单笔跳过并打印，不影响整档。
    static func loadDocumentV2(id: UUID, from directory: URL) -> CanvasDocument? {
        guard let manifest = loadManifestV2(docID: id, in: directory) else { return nil }
        let nodes: [ContentNode]
        do {
            let data = try Data(contentsOf: nodesURL(docID: id, in: directory))
            nodes = try JSONDecoder().decode([ContentNode].self, from: data)
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                print("[DrawingStore] \(id.uuidString): bad nodes.json (\(error)), use empty")
            }
            nodes = []
        }
        var strokes: [Stroke] = []
        strokes.reserveCapacity(manifest.strokeIDs.count)
        for sid in manifest.strokeIDs {
            do {
                let data = try Data(contentsOf: strokeURL(docID: id, strokeID: sid, in: directory))
                strokes.append(try JSONDecoder().decode(Stroke.self, from: data))
            } catch {
                print("[DrawingStore] \(id.uuidString): skip unreadable stroke \(sid) (\(error))")
            }
        }
        return CanvasDocument(meta: manifest.meta, strokes: strokes, nodes: nodes, camera: manifest.camera)
    }

    private static func loadManifestV2(docID: UUID, in directory: URL) -> ManifestV2? {
        let url = manifestURL(docID: docID, in: directory)
        do {
            return try loadOneManifest(at: url)
        } catch let original {
            do {
                let m = try loadOneManifest(at: backupManifestURL(docID: docID, in: directory))
                print("[DrawingStore] recovered manifest for \(docID.uuidString) from backup")
                return m
            } catch {
                print("[DrawingStore] skip unreadable manifest for \(docID.uuidString): \(original)")
                return nil
            }
        }
    }

    private static func loadOneManifest(at url: URL) throws -> ManifestV2 {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(ManifestV2.self, from: data)
        guard manifest.version == layoutVersion else {
            throw StoreError.unsupportedVersion(manifest.version)
        }
        return manifest
    }

    /// v1 单文件迁移到 v2（加载时触发，一次性）：写完 v2 后删除 v1 主文件 + 备份；
    /// 写失败则保留 v1，下次启动重试。
    static func migrateV1toV2(doc: CanvasDocument, v1URL: URL, in directory: URL) {
        do {
            try writeFullV2(doc: doc, in: directory)
            try? FileManager.default.removeItem(at: v1URL)
            let bak = v1URL.deletingLastPathComponent()
                .appendingPathComponent("\(v1URL.deletingPathExtension().lastPathComponent).bak.json")
            try? FileManager.default.removeItem(at: bak)
            print("[DrawingStore] migrated \(v1URL.lastPathComponent) to v2 layout")
        } catch {
            print("[DrawingStore] v1->v2 migration failed for \(v1URL.lastPathComponent): \(error)")
        }
    }

    // MARK: - 节点图片

    /// 图片目录（documents 同级 images/）
    static func imagesDirectory(beside documents: URL) -> URL {
        documents.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
    }

    /// 存图片数据（原样存放，扩展名固定 .img，解码靠内容嗅探），返回文件名
    static func saveImageData(_ data: Data, beside documents: URL) throws -> String {
        let dir = imagesDirectory(beside: documents)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).img"
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return name
    }

    static func loadImageData(file: String, beside documents: URL) -> Data? {
        try? Data(contentsOf: imagesDirectory(beside: documents).appendingPathComponent(file))
    }

    static func deleteImageFile(_ file: String, beside documents: URL) {
        try? FileManager.default.removeItem(at: imagesDirectory(beside: documents).appendingPathComponent(file))
    }
}
