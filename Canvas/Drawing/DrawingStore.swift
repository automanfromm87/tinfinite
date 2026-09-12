// DrawingStore.swift
// 笔画持久化（纯 Foundation，可单测）：版本化 JSON 文档，原子写入。
// 两代布局：v1 整档单文件（仅做迁移源），v2 目录布局
// <uuid>/{manifest.json, manifest.bak.json, nodes.json, strokes/<sid>.json}。

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

    /// 目录里是否有文档（只看文件名，不解码；迁移判空用，避免整库读两遍）
    static func hasAnyDocument(in directory: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        for name in names {
            if name.hasPrefix(".") { continue }
            let stem: String
            if name.hasSuffix(".bak.json") {
                stem = String(name.dropLast(".bak.json".count))
            } else if name.hasSuffix(".json") {
                stem = String(name.dropLast(".json".count))
            } else {
                stem = name
            }
            if UUID(uuidString: stem) != nil { return true }
        }
        return false
    }

    /// 加载目录下所有文档（逐个容错）：
    /// - v2 子目录：按 manifest 加载
    /// - v1 单文件：解码后就地迁移到 v2（一次性），失败则保留 v1 下次重试
    /// 坏文件先试备份恢复，实在不行跳过并打印。
    /// v1/v2 并存（迁移后删 v1 失败）：v2 为准，v1 只删不读，绝不产出同 id 双文档。
    /// - Parameter loadStrokes: false = 只读 manifest/nodes（笔画懒加载，冷启动用）
    static func loadAllDocuments(from directory: URL, loadStrokes: Bool = true) -> [CanvasDocument] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var docs: [CanvasDocument] = []
        var seenIDs = Set<UUID>()
        // 先处理 v2 目录（v2 是真相）
        for url in files {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, let id = UUID(uuidString: url.lastPathComponent) else { continue }
            if let doc = loadDocumentV2(id: id, from: directory, loadStrokes: loadStrokes) {
                seenIDs.insert(id)
                docs.append(doc)
            }
        }
        // 再处理 v1 文件：同 id 已有 v2 只删不读
        for url in files {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            guard url.pathExtension == "json", !url.lastPathComponent.hasSuffix(".bak.json") else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: stem), seenIDs.contains(id) {
                try? FileManager.default.removeItem(at: url)
                continue
            }
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
    /// - manifest：布局版本 + 模型版本 + 元信息 + 相机 + 笔画 id 有序表（z 序），
    ///   每次存档重写（附 .bak 轮转，无全量 copy：新文件落盘后两次 rename 轮转）
    /// - strokes/：每笔独立文件，只写变更的笔；缺失/损坏的笔加载时跳过并打印，
    ///   但 id 保留在内存里，下次存档原样写回 manifest（瞬时 IO 失败不丢数据）
    /// - nodes.json：整体重写（节点数量级小，全量可接受）
    /// 崩溃一致性：manifest 是唯一真相。提交顺序 = 笔画 → 节点 → manifest → 删旧笔文件；
    /// 任何时刻中断，重载结果要么是旧状态要么是新状态（加载时 GC 不在 manifest 里的孤儿笔）。
    static let layoutVersion = 2

    nonisolated struct ManifestV2: Codable, Sendable, Equatable {
        /// 布局版本（= layoutVersion）
        var version: Int
        /// 模型版本（Stroke/ContentNode schema = currentVersion；老 manifest 无此键 -> 按 1 读）
        var modelVersion: Int
        var meta: CanvasDocumentMeta
        var camera: Camera?
        /// 笔画 id（数组顺序 = z 序）
        var strokeIDs: [UUID]

        enum CodingKeys: String, CodingKey {
            case version, modelVersion, meta, camera, strokeIDs
        }

        init(version: Int, modelVersion: Int, meta: CanvasDocumentMeta, camera: Camera?, strokeIDs: [UUID]) {
            self.version = version
            self.modelVersion = modelVersion
            self.meta = meta
            self.camera = camera
            self.strokeIDs = strokeIDs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            modelVersion = try c.decodeIfPresent(Int.self, forKey: .modelVersion) ?? DrawingStore.currentVersion
            meta = try c.decode(CanvasDocumentMeta.self, forKey: .meta)
            camera = try c.decodeIfPresent(Camera.self, forKey: .camera)
            strokeIDs = try c.decode([UUID].self, forKey: .strokeIDs)
        }
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
        try saveStrokes([stroke], docID: docID, in: directory)
    }

    /// 批量写笔：整个批次复用一个 JSONEncoder（同调用栈串行，无共享可变状态）
    static func saveStrokes(_ strokes: [Stroke], docID: UUID, in directory: URL) throws {
        guard !strokes.isEmpty else { return }
        let dir = strokesDirectory(docID: docID, in: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        for s in strokes {
            let data = try encoder.encode(s)
            try data.write(to: strokeURL(docID: docID, strokeID: s.id, in: directory), options: .atomic)
        }
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

    /// 写 manifest（附 .bak 轮转：manifest 是整档的索引，必须可恢复）。
    /// 无全量 copy：新内容先落临时文件，再把旧 manifest 改名成 .bak、新文件改名到位。
    /// 崩溃分析：中断在任何一步，已落盘的 manifest/.bak 至少其一是完整旧版或完整新版；
    /// 残留的临时文件（strokes/ 下 .pending- 前缀）由加载时 GC 顺手清理。
    static func saveManifest(meta: CanvasDocumentMeta, camera: Camera?, strokeIDs: [UUID], docID: UUID, in directory: URL) throws {
        let dir = docDirectory(id: docID, in: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = ManifestV2(
            version: layoutVersion, modelVersion: currentVersion,
            meta: meta, camera: camera, strokeIDs: strokeIDs
        )
        let data = try JSONEncoder().encode(manifest)
        try writeWithBackup(
            data, to: manifestURL(docID: docID, in: directory),
            backup: backupManifestURL(docID: docID, in: directory),
            scratchDirectory: strokesDirectory(docID: docID, in: directory)
        )
    }

    /// 带备份的原子写：data -> tmp（原子）-> 旧文件改名 .bak -> tmp 改名到位。
    /// 不做全量 copy，省一次大文件读 + 写；tmp 与目标同卷，保证 rename 原子。
    static func writeWithBackup(_ data: Data, to url: URL, backup bak: URL, scratchDirectory: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let tmp = scratchDirectory.appendingPathComponent(".pending-\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        try? FileManager.default.removeItem(at: bak)
        try FileManager.default.moveItem(at: url, to: bak)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// 全量写 v2（迁移/兜底用）：笔画 + 节点 + manifest（manifest 最后写）
    static func writeFullV2(doc: CanvasDocument, in directory: URL) throws {
        try saveStrokes(doc.strokes, docID: doc.meta.id, in: directory)
        try saveNodes(doc.nodes, docID: doc.meta.id, in: directory)
        var ids = doc.strokes.map(\.id)
        ids.append(contentsOf: doc.unreadableStrokeIDs.filter { !ids.contains($0) })
        try saveManifest(meta: doc.meta, camera: doc.camera, strokeIDs: ids, docID: doc.meta.id, in: directory)
    }

    /// 加载单个 v2 文档：manifest 缺失/损坏（连 .bak 都不行）或模型版本不匹配返回 nil；
    /// 缺失/损坏的单笔跳过并打印（id 记在 unreadableStrokeIDs 里，存档时原样保留），不影响整档。
    /// 主 manifest 正常时顺手 GC 孤儿笔文件（崩在“写完笔、未写 manifest”之间的残留）。
    /// - Parameter loadStrokes: false = 只读 manifest/nodes（笔画懒加载）
    static func loadDocumentV2(id: UUID, from directory: URL, loadStrokes: Bool = true) -> CanvasDocument? {
        guard let (manifest, fromBackup) = loadManifestV2(docID: id, in: directory) else { return nil }
        guard manifest.modelVersion == currentVersion else {
            print("[DrawingStore] skip \(id.uuidString): model version \(manifest.modelVersion) != \(currentVersion)")
            return nil
        }
        if !fromBackup {
            collectOrphanStrokeFiles(docID: id, strokeIDs: manifest.strokeIDs, in: directory)
        }
        let nodes = loadNodes(docID: id, in: directory)
        guard loadStrokes else {
            return CanvasDocument(
                meta: manifest.meta, strokes: [], nodes: nodes, camera: manifest.camera,
                version: manifest.modelVersion, strokesLoaded: false,
                manifestStrokeCount: manifest.strokeIDs.count
            )
        }
        let (strokes, unreadable) = loadStrokeFiles(docID: id, strokeIDs: manifest.strokeIDs, in: directory)
        return CanvasDocument(
            meta: manifest.meta, strokes: strokes, nodes: nodes, camera: manifest.camera,
            version: manifest.modelVersion, unreadableStrokeIDs: unreadable
        )
    }

    static func loadNodes(docID: UUID, in directory: URL) -> [ContentNode] {
        do {
            let data = try Data(contentsOf: nodesURL(docID: docID, in: directory))
            return try JSONDecoder().decode([ContentNode].self, from: data)
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                print("[DrawingStore] \(docID.uuidString): bad nodes.json (\(error)), use empty")
            }
            return []
        }
    }

    /// 按 manifest 顺序读笔（去重保序，防脏 manifest 产出同 id 双笔）；
    /// 返回（读到的笔，读失败的 id：调用方存档时原样保留进 manifest）。
    static func loadStrokeFiles(docID: UUID, strokeIDs: [UUID], in directory: URL) -> (strokes: [Stroke], unreadableIDs: [UUID]) {
        var seen = Set<UUID>()
        var strokes: [Stroke] = []
        var unreadable: [UUID] = []
        strokes.reserveCapacity(strokeIDs.count)
        for sid in strokeIDs {
            guard seen.insert(sid).inserted else { continue }
            do {
                let data = try Data(contentsOf: strokeURL(docID: docID, strokeID: sid, in: directory))
                strokes.append(try JSONDecoder().decode(Stroke.self, from: data))
            } catch {
                print("[DrawingStore] \(docID.uuidString): skip unreadable stroke \(sid) (\(error))")
                unreadable.append(sid)
            }
        }
        return (strokes, unreadable)
    }

    /// 删 strokes/ 下不在 manifest 里的文件（崩溃残留的孤儿笔 + manifest 写盘的临时文件）。
    /// 只在主 manifest 正常时调用：.bak 恢复时盘上文件可能比备份新，删了就是丢数据。
    static func collectOrphanStrokeFiles(docID: UUID, strokeIDs: [UUID], in directory: URL) {
        let keep = Set(strokeIDs.map(\.uuidString))
        let dir = strokesDirectory(docID: docID, in: directory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            if name.hasPrefix(".pending-") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                continue
            }
            guard name.hasSuffix(".json") else { continue }
            let stem = String(name.dropLast(".json".count))
            if UUID(uuidString: stem) != nil, !keep.contains(stem) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// 读 manifest（主坏回退 .bak）；返回 manifest + 是否来自备份（GC 只敢在主正常时做）
    static func loadManifestV2(docID: UUID, in directory: URL) -> (manifest: ManifestV2, fromBackup: Bool)? {
        let url = manifestURL(docID: docID, in: directory)
        do {
            return (try loadOneManifest(at: url), false)
        } catch let original {
            do {
                let m = try loadOneManifest(at: backupManifestURL(docID: docID, in: directory))
                print("[DrawingStore] recovered manifest for \(docID.uuidString) from backup")
                return (m, true)
            } catch {
                print("[DrawingStore] skip unreadable manifest for \(docID.uuidString): \(original)")
                return nil
            }
        }
    }

    static func loadOneManifest(at url: URL) throws -> ManifestV2 {
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
