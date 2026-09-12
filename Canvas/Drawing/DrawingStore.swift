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

    /// 加载目录下所有文档（逐个容错：坏文件先试 .bak 恢复，实在不行跳过并打印）
    static func loadAllDocuments(from directory: URL) -> [CanvasDocument] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var docs: [CanvasDocument] = []
        for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".bak.json") {
            if let doc = loadDocumentWithBackup(at: url) {
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
