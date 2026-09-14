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

    /// 笔画是否已加载（懒加载标记；false 时 strokes 为空，须经文档库 resolve）。
    /// transient：不参与 Codable（CodingKeys 未列出，编解码自动忽略）。
    var strokesLoaded: Bool = true
    /// 未加载时的笔画总数（manifest 笔画 id 数，侧边栏计数用；加载后为 nil）
    var manifestStrokeCount: Int?
    /// 加载时读失败的笔画 id（瞬时 IO 失败/坏文件）：内存无数据，
    /// 但存档时原样保留进 manifest，防止下一次存档把它们永久抹掉。transient。
    var unreadableStrokeIDs: [UUID] = []

    init(
        meta: CanvasDocumentMeta, strokes: [Stroke] = [], nodes: [ContentNode] = [],
        camera: Camera? = nil, version: Int = DrawingStore.currentVersion,
        strokesLoaded: Bool = true, manifestStrokeCount: Int? = nil,
        unreadableStrokeIDs: [UUID] = []
    ) {
        self.version = version
        self.meta = meta
        self.strokes = strokes
        self.nodes = nodes
        self.camera = camera
        self.strokesLoaded = strokesLoaded
        self.manifestStrokeCount = manifestStrokeCount
        self.unreadableStrokeIDs = unreadableStrokeIDs
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
    /// 文档（按更新时间倒序；冷启动时只含 manifest 壳，笔画按需加载）
    @Published private(set) var documents: [CanvasDocument] = []

    /// 缩略图刷新代号：内容变化时最多每 `thumbnailThrottle` 秒 +1。
    /// 侧边栏缩略图以它为 task id，避免每次自动存档（写字时 ~1/s）都重栅格化。
    @Published private(set) var thumbnailRevision = 0
    private var lastThumbnailBump = Date.distantPast
    private var thumbnailBumpPending = false
    private var thumbnailTrailingWork: DispatchWorkItem?
    private static let thumbnailThrottle: TimeInterval = 5

    /// 节点图片所在的文档目录（导出等后台任务用；URL 是 Sendable，可跨线程）
    var imagesSourceDirectory: URL { directory }

    private let directory: URL
    private let legacyURL: URL?
    /// IO 串行队列：diff + JSON 编码 + 文件写 + 基准提交全部在这里。
    /// 串行即全序：diff 看到的基准恒为“此前已确认落盘态”，无需代际计数器防乱序；
    /// flushSaves 的屏障返回后，基准已提交（确定性，单测友好）。
    private let ioQueue = DispatchQueue(label: "canvas.library.io", qos: .utility)

    /// IO 队列限定的存档状态（只在 ioQueue 闭包里读写；串行队列即互斥）。
    /// lastSaved 不变量：描述的一定是已完全写盘的状态——成功后才提交，
    /// 失败不碰（下次 diff 自动算出全量补写，自愈）。
    nonisolated private final class IOConfinedState: @unchecked Sendable {
        /// diff 基准：上次确认落盘的完整状态
        var lastSaved: [UUID: SavedSnapshot] = [:]
    }
    private let ioState = IOConfinedState()

    /// 已加载的笔画（非 Published：sync/async 加载只写这里，绝不在 SwiftUI body 里发布）。
    /// 不变量：uncached => 本会话内未碰过该文档 => 无在 flight 的存档 =>
    /// 加载时的孤儿 GC 不会误删在途文件。
    private var strokesCache: [UUID: [Stroke]] = [:]
    private var unreadableCache: [UUID: [UUID]] = [:]
    private var strokeCounts: [UUID: Int] = [:]

    /// 上次存档的内容快照（diff 用；CoW 值语义，快照本身 O(1)）
    nonisolated private struct SavedSnapshot: Sendable {
        var strokes: [Stroke]
        var nodes: [ContentNode]
        var meta: CanvasDocumentMeta
        var camera: Camera?
    }

    /// 存档计划（ioQueue 上 diff 产物；Sendable，可安全跨线程执行）。
    nonisolated struct SavePlan: Sendable {
        var docID: UUID
        /// 是否失败重试（重试再失败不再重试，防止坏盘上无限循环）
        var isRetry: Bool
        /// 需落盘的完整 z 序笔画
        var strokes: [Stroke]
        /// 需重写文件的笔（diff 增量；基准缺失时 = 全部）
        var upsertStrokes: [Stroke]
        /// 需删文件的笔 id（manifest 提交后才删，见 runSavePlan 顺序）
        var removeStrokeIDs: [UUID]
        /// 完整节点状态（writeNodes 为 false 时跳过写盘）
        var nodes: [ContentNode]
        var writeNodes: Bool
        var meta: CanvasDocumentMeta
        var camera: Camera?
        /// manifest 笔画 id 表（z 序 + 不可读 id 去重追加）
        var strokeIDs: [UUID]
    }

    /// 存档执行步骤（崩溃一致性测试可指定中断点）
    nonisolated enum SaveStep: CaseIterable, Sendable {
        case upserts, nodes, manifest, removals
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

    /// 取文档（笔画自动 resolve：缓存命中零 IO，未加载则同步读盘一次并预热 diff 基准）。
    /// 只写非 Published 缓存，可在 makeUIView 等视图构建上下文中安全调用。
    /// 读盘失败（目录被外部删除）返回 manifest 壳并打印；save() 对此会跳过（不破坏 manifest）。
    func document(id: UUID) -> CanvasDocument? {
        guard let index = documents.firstIndex(where: { $0.meta.id == id }) else { return nil }
        var doc = documents[index]
        if let cached = strokesCache[id] {
            doc.strokes = cached
            doc.unreadableStrokeIDs = unreadableCache[id] ?? []
            doc.strokesLoaded = true
            doc.manifestStrokeCount = nil
            return doc
        }
        if doc.strokesLoaded {
            strokesCache[id] = doc.strokes
            unreadableCache[id] = doc.unreadableStrokeIDs
            strokeCounts[id] = doc.strokes.count + doc.unreadableStrokeIDs.count
            return doc
        }
        guard let loaded = DrawingStore.loadDocumentV2(id: id, from: directory, loadStrokes: true) else {
            print("[CanvasLibrary] \(id.uuidString): strokes unreadable, return shell")
            return doc
        }
        strokesCache[id] = loaded.strokes
        unreadableCache[id] = loaded.unreadableStrokeIDs
        strokeCounts[id] = loaded.strokes.count + loaded.unreadableStrokeIDs.count
        preheatBaseline(id: id, loaded: loaded)
        doc.strokes = loaded.strokes
        doc.unreadableStrokeIDs = loaded.unreadableStrokeIDs
        doc.strokesLoaded = true
        doc.manifestStrokeCount = nil
        return doc
    }

    /// 文档是否存在（只看 manifest 壳，不触发笔画加载；视图 body 里用这个）
    func hasDocument(id: UUID) -> Bool {
        documents.contains { $0.meta.id == id }
    }

    /// 上次存档的相机（壳字段，不触发笔画加载；打开恢复视角用）
    func camera(id: UUID) -> Camera? {
        documents.first { $0.meta.id == id }?.camera
    }

    /// 文档元信息（壳字段，不触发笔画加载；标题栏用）
    func meta(id: UUID) -> CanvasDocumentMeta? {
        documents.first { $0.meta.id == id }?.meta
    }

    /// 笔画总数（已加载用实数，未加载用 manifest 数；不触发加载）
    func strokeCount(id: UUID) -> Int {
        if let n = strokeCounts[id] { return n }
        return documents.first { $0.meta.id == id }?.strokes.count ?? 0
    }

    /// 异步取笔画（侧边栏缩略图用）：缓存命中直接返回，否则后台解码。
    /// 完成后只写非 Published 缓存 + 返回值（调用方存 @State），不发布。
    func strokes(for id: UUID) async -> [Stroke] {
        if let cached = strokesCache[id] { return cached }
        guard documents.contains(where: { $0.meta.id == id }) else { return [] }
        let dir = directory
        let loaded = await Task.detached(priority: .utility) {
            DrawingStore.loadDocumentV2(id: id, from: dir, loadStrokes: true)
        }.value
        // 期间文档被删 / 已有更新者写入缓存（数据更新）-> 不覆盖
        guard documents.contains(where: { $0.meta.id == id }),
              strokesCache[id] == nil,
              let loaded
        else { return strokesCache[id] ?? [] }
        strokesCache[id] = loaded.strokes
        unreadableCache[id] = loaded.unreadableStrokeIDs
        strokeCounts[id] = loaded.strokes.count + loaded.unreadableStrokeIDs.count
        preheatBaseline(id: id, loaded: loaded)
        return loaded.strokes
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
        strokesCache[doc.meta.id] = []
        unreadableCache[doc.meta.id] = []
        strokeCounts[doc.meta.id] = 0
        save(id: doc.meta.id)
        return doc
    }

    /// 更新某文档的笔画（自动存档入口）：刷新缓存 + 写盘 + 置顶
    func updateStrokes(id: UUID, strokes: [Stroke]) {
        updateContent(id: id, strokes: strokes, nodes: document(id: id)?.nodes ?? [])
    }

    /// 更新某文档的笔画 + 节点（自动存档入口）：刷新缓存 + 写盘 + 置顶。
    ///
    /// 性能约束（写字热路径）：本方法在每次自动存档时被调用，而 `documents` 是
    /// @Published —— 每次赋值都会让整个侧边栏 + 详情页 body 重算。所以：
    /// - 只发布 **一次**（先在局部数组上改完，最后整体赋值），而不是逐字段 7 次；
    /// - 绝不把 live 笔画数组塞进已发布的壳里（笔画真相在非发布的 strokesCache），
    ///   否则每次发布都会让缩略图拿到新数据并重栅格化全部笔画中线。
    func updateContent(id: UUID, strokes: [Stroke], nodes: [ContentNode]) {
        guard let index = documents.firstIndex(where: { $0.meta.id == id }) else { return }
        // 缓存先行：save(id:) -> document(id:) 走缓存分支，零 IO
        strokesCache[id] = strokes
        strokeCounts[id] = strokes.count + (unreadableCache[id]?.count ?? 0)

        var doc = documents[index]
        doc.strokes = []                              // 壳不带笔画，strokesCache 才是真相
        doc.strokesLoaded = false
        doc.manifestStrokeCount = strokeCounts[id]
        doc.nodes = nodes                             // delete(id:) 仍需节点的 imageFile
        doc.meta.updatedAt = Date()                   // reload() 按它倒序，必须保留

        var next = documents
        next.remove(at: index)
        next.insert(doc, at: 0)                       // 最近更新优先
        documents = next                              // 唯一一次 objectWillChange

        save(id: id)
        bumpThumbnailRevisionThrottled()
    }

    /// 缩略图代号节流推进（写字期间最多每 5 秒一次重栅格化）。
    /// 带 trailing 补发：被节流吃掉的那一次会在空闲后补上，否则「最后一笔」
    /// 的缩略图在用户不离开画布时永远不会刷新（iPad 上侧边栏是常驻的）。
    private func bumpThumbnailRevisionThrottled() {
        let now = Date()
        guard now.timeIntervalSince(lastThumbnailBump) > Self.thumbnailThrottle else {
            thumbnailBumpPending = true
            scheduleTrailingThumbnailBump()
            return
        }
        lastThumbnailBump = now
        thumbnailBumpPending = false
        thumbnailRevision &+= 1
    }

    private func scheduleTrailingThumbnailBump() {
        thumbnailTrailingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshThumbnails() }
        thumbnailTrailingWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.thumbnailThrottle, execute: work
        )
    }

    /// 兑现被节流吃掉的缩略图刷新（离开画布 / 切后台时调）。
    /// 没有欠账就什么都不做——不做无谓的发布。
    func refreshThumbnails() {
        thumbnailTrailingWork?.cancel()
        thumbnailTrailingWork = nil
        guard thumbnailBumpPending else { return }
        lastThumbnailBump = Date()
        thumbnailBumpPending = false
        thumbnailRevision &+= 1
    }

    func rename(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = documents.firstIndex(where: { $0.meta.id == id }) else { return }
        documents[index].meta.title = trimmed
        documents[index].meta.updatedAt = Date()
        save(id: id)
    }

    func delete(id: UUID) {
        guard let index = documents.firstIndex(where: { $0.meta.id == id }) else { return }
        let doc = documents.remove(at: index)
        strokesCache.removeValue(forKey: id)
        unreadableCache.removeValue(forKey: id)
        strokeCounts.removeValue(forKey: id)
        // 目录递归删除可能很慢（几千笔文件），放后台队列。
        // 串行保序：在在途存档之后执行，顺手清掉在途存档提交的基准（文档已删，基准无用）。
        let dir = directory
        let imageFiles = doc.nodes.compactMap(\.imageFile)
        let state = ioState
        ioQueue.async {
            state.lastSaved.removeValue(forKey: id)
            DrawingStore.deleteDocument(id: id, in: dir)
            // 连带删除节点图片（孤儿文件不残留）
            for file in imageFiles {
                DrawingStore.deleteImageFile(file, beside: dir)
            }
        }
    }

    /// 相机存档（手势静止防抖/离开文档时调）：内容未变时只重写 manifest 小文件；
    /// 不碰 updatedAt、不重排（否则每次平移都会置顶文档）。
    func updateCamera(id: UUID, camera: Camera) {
        guard let index = documents.firstIndex(where: { $0.meta.id == id }),
              documents[index].camera != camera
        else { return }
        documents[index].camera = camera
        save(id: id)
    }

    /// 等待后台存档全部落盘（单测用；App 切后台用 async 版，避免阻塞主线程看门狗）
    func flushSaves() {
        ioQueue.sync {}
    }

    /// 异步等待后台存档全部落盘（切后台时调；挂起而非阻塞，不触发看门狗）。
    /// 注意：只保证队列排干；成功/失败回执跳回主线程是尾随的（单测断言回执效果需让出主线程）。
    func flushSaves() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ioQueue.async { cont.resume() }
        }
    }

    func reload() {
        documents = DrawingStore.loadAllDocuments(from: directory, loadStrokes: false)
            .sorted { $0.meta.updatedAt > $1.meta.updatedAt }
        strokesCache.removeAll()
        unreadableCache.removeAll()
        strokeCounts.removeAll()
        for doc in documents {
            strokeCounts[doc.meta.id] = doc.manifestStrokeCount ?? doc.strokes.count
        }
        // ioState（基准/脏位）描述的是盘上状态，reload 不改盘，原样保留依然有效。
    }

    // MARK: - 内部

    /// 从盘上加载即预热 diff 基准（加载态 = 已落盘态；调用时该文档必未缓存，
    /// 未缓存 => 本会话未碰过 => 无在途存档；按程序顺序入队，不会覆盖更新的基准）。
    private func preheatBaseline(id: UUID, loaded: CanvasDocument) {
        let state = ioState
        let snapshot = SavedSnapshot(
            strokes: loaded.strokes, nodes: loaded.nodes,
            meta: loaded.meta, camera: loaded.camera
        )
        ioQueue.async {
            state.lastSaved[id] = snapshot
        }
    }

    /// 增量存档：主线程 resolve 出完整内存态（缓存命中 O(1)，CoW 传值），
    /// diff + 执行 + 基准提交全部在 ioQueue 上串行完成。
    /// - 基准只在成功后提交（失败不碰 + 最多重试一次，永不静默丢数据）
    /// - resolve 失败（笔画读不上来）直接跳过，绝不用空笔画表破坏 manifest
    private func save(id: UUID, isRetry: Bool = false) {
        guard let doc = document(id: id) else { return }
        guard doc.strokesLoaded else {
            print("[CanvasLibrary] \(id.uuidString): skip save, strokes unresolved")
            return
        }
        let dir = directory
        let state = ioState
        ioQueue.async { [weak self] in
            let prev = state.lastSaved[id]
            var upserts: [Stroke] = []
            var removed: [UUID] = []
            if let prev {
                // uniquing 防脏数据（同 id 双笔）trap：坏数据降级，不崩溃
                let oldByID = Dictionary(prev.strokes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
            var strokeIDs = doc.strokes.map(\.id)
            let known = Set(strokeIDs)
            strokeIDs.append(contentsOf: doc.unreadableStrokeIDs.filter { !known.contains($0) })
            // nodes 跳过条件：与基准一致即可跳过，无需脏标记——
            // 原子写保证失败不破坏旧文件，基准只描述成功态，
            // 故“与基准一致”恒蕴含“盘上已是该版本”，跳过恒正确。
            let plan = SavePlan(
                docID: id, isRetry: isRetry,
                strokes: doc.strokes, upsertStrokes: upserts, removeStrokeIDs: removed,
                nodes: doc.nodes, writeNodes: prev?.nodes != doc.nodes,
                meta: doc.meta, camera: doc.camera, strokeIDs: strokeIDs
            )
            do {
                try Self.runSavePlan(plan, in: dir)
                state.lastSaved[id] = SavedSnapshot(
                    strokes: plan.strokes, nodes: plan.nodes,
                    meta: plan.meta, camera: plan.camera
                )
            } catch {
                print("[CanvasLibrary] save failed: \(error)")
                // 基准不动（仍描述最后一次成功落盘态，下次 diff 自动补写自愈）；
                // 用内存最新态重试一次（重试不再递归）。
                if !isRetry {
                    Task { @MainActor [weak self] in
                        self?.save(id: id, isRetry: true)
                    }
                }
            }
        }
    }

    /// 执行存档计划。固定顺序：笔画 upsert → 节点 → manifest 提交 → 删旧笔文件。
    /// manifest 是唯一真相：崩在 manifest 之前 = 旧状态（新文件变孤儿，加载时 GC）；
    /// 崩在 manifest 之后 = 新状态（旧文件残留，加载时 GC）。绝无第三状态。
    /// - Parameter through: 只执行到某步（崩溃一致性测试注入用；nil = 全部）
    nonisolated static func runSavePlan(_ plan: SavePlan, in directory: URL, through end: SaveStep? = nil) throws {
        try DrawingStore.saveStrokes(plan.upsertStrokes, docID: plan.docID, in: directory)
        if end == .upserts { return }
        if plan.writeNodes {
            try DrawingStore.saveNodes(plan.nodes, docID: plan.docID, in: directory)
        }
        if end == .nodes { return }
        try DrawingStore.saveManifest(
            meta: plan.meta, camera: plan.camera, strokeIDs: plan.strokeIDs,
            docID: plan.docID, in: directory
        )
        if end == .manifest { return }
        DrawingStore.removeStrokeFiles(docID: plan.docID, ids: plan.removeStrokeIDs, in: directory)
    }

    private func untitledName() -> String {
        let base = "无标题画布"
        let taken = Set(documents.map(\.meta.title))
        if !taken.contains(base) { return base }
        var i = 2
        while taken.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// 旧单文件迁移：documents 为空且旧文件存在 -> 直接写 v2 并删除旧文件
    private func migrateLegacyIfNeeded() {
        guard let legacyURL,
              !DrawingStore.hasAnyDocument(in: directory),
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
            try DrawingStore.writeFullV2(doc: doc, in: directory)
            DrawingStore.clearPersisted(at: legacyURL)
            print("[CanvasLibrary] migrated \(strokes.count) legacy strokes")
        } catch {
            print("[CanvasLibrary] legacy migration failed: \(error)")
        }
    }
}
