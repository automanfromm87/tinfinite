// StrokeMetalView.swift
// 笔画 Metal 渲染视图（屏幕空间透明覆盖层）：
// - 所有已提交笔画共享一对 vertex/index buffer（append-only + 空洞整理），每笔画一次 drawIndexed
// - live 笔画独立动态 buffer，每输入事件全量重建上传
// - MSAA 4x 抗锯齿；isPaused + 按需 draw，不画时零 GPU 开销
// - viewport 变换在 shader 里，pan/zoom 只改 uniform
// 线程：只在主线程调用（UIKit 侧拥有）。

import MetalKit
import simd

/// 与 shader StrokeUniforms 布局一致（24 字节，见 .metal 注释）。
/// center 是相机中心相对 renderOrigin 的偏移（CPU 侧 double 相减），
/// 与顶点缓冲里的相对坐标配套，GPU 只接触小数，消除 float32 抖动。
private struct StrokeUniforms {
    var center: SIMD2<Float>
    var scale: Float
    var viewSize: SIMD2<Float>
}

/// RenderedStroke 定义已移至 StrokeModel.swift（纯逻辑层共用）

final class StrokeMetalView: MTKView, MTKViewDelegate {

    /// 当前视口（UIKit 直驱，不经过 SwiftUI）
    var viewport: Viewport = .zero {
        didSet {
            guard viewport != oldValue else { return }
            maybeRebase()
            setNeedsDisplay()
        }
    }

    // MARK: - 相机相对坐标（P1-8 精度修复）

    /// 渲染原点（世界坐标，量化到 originGrid 网格）。
    /// GPU 缓冲里存的是 `顶点 − renderOrigin`（CPU 侧 double 相减再转 float），
    /// uniform 传的是 `相机中心 − renderOrigin`；GPU 只接触视口尺度的小数，
    /// 远离原点 + 深度缩放时也不抖动。Metal iOS 不支持 double 顶点属性，
    /// 所以相对化只能在 CPU 侧做（float→double 精确，减法在 double 域）。
    private(set) var renderOrigin = CGPoint.zero
    private static let originGrid: Double = 1024
    private static let rebaseRadius: Double = 4096

    /// 相机远离原点则换新原点并全量重传顶点（顶点数不变，ranges/索引有效）。
    /// 量化原点 + 迟滞阈值保证：小幅 pan 零重传，跨阈值才一次 O(n) 重传。
    private func maybeRebase() {
        let c = viewport.camera.center
        let dx = abs(Double(c.x) - Double(renderOrigin.x))
        let dy = abs(Double(c.y) - Double(renderOrigin.y))
        guard dx > Self.rebaseRadius || dy > Self.rebaseRadius else { return }
        renderOrigin = CGPoint(
            x: (Double(c.x) / Self.originGrid).rounded(.toNearestOrEven) * Self.originGrid,
            y: (Double(c.y) / Self.originGrid).rounded(.toNearestOrEven) * Self.originGrid
        )
        reuploadAllVertices()
    }

    private func reuploadAllVertices() {
        for id in order {
            guard let mesh = meshes[id], !mesh.isEmpty,
                  let range = ranges[id]
            else { continue }
            copyVertices(mesh.vertices[...], into: vertexBuffer, atVertex: range.vertexOffset)
        }
        if liveIndexCount > 0 {
            liveNeedsFullUpload = true
            onLiveReuploadNeeded?()
        }
    }

    // MARK: - Metal 状态

    private var pipeline: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?

    // MARK: - 已提交笔画缓冲（共享，append-only）

    private var order: [UUID] = []
    /// order 的集合镜像：upsert 的存在性判断必须 O(1)。
    /// 原来的 `order.contains(id)` 在 LOD 批量重建时是 O(N²)（10k 笔实测 142ms）。
    private var orderSet: Set<UUID> = []
    private var meshes: [UUID: StrokeMesh] = [:]
    private var boundsMap: [UUID: CGRect] = [:]
    private var ranges: [UUID: IndexRange] = [:]
    /// 笔刷种类（渲染层级用：荧光笔先画，落在墨线下；缺省=普通笔）
    private var kindMap: [UUID: BrushKind] = [:]

    private struct IndexRange {
        var vertexOffset: Int  // 以顶点为单位（draw 用 baseVertex）
        var indexOffset: Int   // 以索引为单位
        var indexCount: Int
    }

    // MARK: - 绘制列表（按笔刷层级预分区的稠密数组）

    /// 一条 draw 记录。draw(in:) 每帧遍历它，**不碰任何 Dictionary**：
    /// 原来每笔每帧要做 4 次 UUID 哈希（16 字节 SipHash + 大概率 L2 miss），
    /// 10k 笔时 ~1.5ms/帧只花在查表上。换成稠密数组后同样规模 ~0.024ms。
    private struct DrawItem {
        var vertexOffset: Int
        var indexOffset: Int
        var indexCount: Int
        /// 世界包围盒（预拆成标量，避免每帧 CGRect 的 C 调用）；minX > maxX 表示「无 bounds，恒绘制」
        var minX: CGFloat
        var minY: CGFloat
        var maxX: CGFloat
        var maxY: CGFloat
    }

    /// 荧光笔在前（画在墨线下），各自保持 z 序
    private var highlighterItems: [DrawItem] = []
    private var inkItems: [DrawItem] = []
    /// id -> 它在哪张表的第几位（只在 drawList 有效时可用），用于原地改包围盒
    private var drawSlot: [UUID: (highlighter: Bool, index: Int)] = [:]
    private var drawListDirty = true

    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var vertexCapacity = 0
    private var indexCapacity = 0
    private var vertexCount = 0
    private var indexCount = 0

    /// 缓冲统计（压力测试观测用）
    var bufferStats: (meshes: Int, vertices: Int, indices: Int) {
        (order.count, vertexCount, indexCount)
    }
    /// 删除留下的空洞；超过阈值整理
    private var holeVertices = 0
    private var holeIndices = 0

    private static let initialVertexCapacity = 4096
    private static let initialIndexCapacity = 16384
    private static let maxVertices = 1_000_000
    private static let maxIndices = 4_000_000

    // MARK: - Live 笔画缓冲（独立，动态重建）

    private var liveVertexBuffer: MTLBuffer?
    private var liveIndexBuffer: MTLBuffer?
    private var liveVertexCapacity = 0
    private var liveIndexCapacity = 0
    private var liveIndexCount = 0
    /// live 笔刷种类（荧光笔 live 先画，避免提交时从上层“掉”到底层造成闪烁）
    private var liveKind: BrushKind = .pen
    /// 下次 live 更新必须整段重传（renderOrigin 变了）。
    ///
    /// 这里刻意 **不缓存** live 顶点数组：那会让 LiveStrokeMesh 内部数组的引用计数
    /// 变成 2，它下一次 append/removeLast 就触发整数组 CoW 深拷贝 —— 正好把增量
    /// 镶嵌省下来的 O(n) 又原样加回去。改为置位 + 回调上层重推一次。
    private var liveNeedsFullUpload = false
    /// renderOrigin 变化后请求上层重推 live 网格
    var onLiveReuploadNeeded: (() -> Void)?

    // MARK: - Init

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MTLCreateSystemDefaultDevice()
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat = .bgra8Unorm
        sampleCount = 4
        // 按需绘制：静止时零 GPU 开销
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        commandQueue = device?.makeCommandQueue()
        pipeline = makePipeline()
        if pipeline == nil {
            print("[StrokeMetalView] WARNING: render pipeline unavailable, strokes will not draw")
        }
    }

    private func makePipeline() -> MTLRenderPipelineState? {
        guard let device,
              let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "stroke_vertex"),
              let fragmentFn = library.makeFunction(name: "stroke_fragment")
        else { return nil }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float4
        vertexDescriptor.attributes[1].offset = 8
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = 24
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.rasterSampleCount = sampleCount

        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - 数据下发（DrawingController 调用）

    /// 全量同步已提交笔画（内部 diff：新增 append、删除记空洞、必要时整理）。
    func setCommittedStrokes(_ strokes: [RenderedStroke]) {
        let newIDs = strokes.map(\.id)
        if newIDs == order {
            // 顺序/集合一致：已提交 mesh 不可变，无事可做
            return
        }
        let newSet = Set(newIDs)
        let oldSet = Set(order)

        // 删除：记空洞（不搬移 buffer）
        let removed = oldSet.subtracting(newSet)
        for id in removed {
            if let range = ranges[id] {
                holeVertices += meshVertexCount(for: id)
                holeIndices += range.indexCount
            }
            meshes.removeValue(forKey: id)
            boundsMap.removeValue(forKey: id)
            ranges.removeValue(forKey: id)
            kindMap.removeValue(forKey: id)
        }

        // 空洞先整理再 append：重开文档时能复用删除释放出的空间，
        // 否则上次因缓冲满被丢掉的笔这次仍然进不来。
        order = newIDs
        orderSet = newSet
        maybeCompact()

        // 新增：append 到 buffer 尾
        var dropped = 0
        for s in strokes {
            kindMap[s.id] = s.kind
            guard !oldSet.contains(s.id) || ranges[s.id] == nil else { continue }
            meshes[s.id] = s.mesh
            boundsMap[s.id] = s.bounds
            if !appendMesh(s.mesh, id: s.id) { dropped += 1 }
        }
        if dropped > 0 { onBufferFull?(dropped) }
        maybeCompact()
        drawListDirty = true
        setNeedsDisplay()
    }

    /// 缓冲写满、笔画无法上屏时的通知（调用方决定怎么告诉用户；默认只有 console 警告）
    var onBufferFull: ((Int) -> Void)?

    /// 增量 upsert 一笔（新增 append、已存在替换为新区段）。LOD/碎片/撤销恢复用。
    func upsertMesh(id: UUID, mesh: StrokeMesh, bounds: CGRect, kind: BrushKind = .pen) {
        upsertMeshes([RenderedStroke(id: id, mesh: mesh, bounds: bounds, kind: kind)])
    }

    /// 批量 upsert（LOD 扫描/局部擦除用）：一次容量核算 + 至多一次全量重排，
    /// 而不是逐笔 append-记空洞-可能触发 compact 的 k 次循环。
    func upsertMeshes(_ rawItems: [RenderedStroke]) {
        guard !rawItems.isEmpty else { return }
        // 同一批里出现同一个 id 时只保留最后一份：append 路径靠 ranges[id] 判重，
        // 重复 id 的第二份几何会被判成「重排已放好」而静默丢弃。
        var items = rawItems
        if items.count > 1 {
            var lastIndex: [UUID: Int] = [:]
            lastIndex.reserveCapacity(items.count)
            for (i, it) in items.enumerated() { lastIndex[it.id] = i }
            if lastIndex.count != items.count {
                items = items.enumerated().compactMap { lastIndex[$1.id] == $0 ? $1 : nil }
            }
        }
        var replacedAny = false
        for it in items {
            if let range = ranges[it.id] {
                holeVertices += meshes[it.id]?.vertices.count ?? 0
                holeIndices += range.indexCount
                ranges.removeValue(forKey: it.id)
                replacedAny = true
            }
            meshes[it.id] = it.mesh
            boundsMap[it.id] = it.bounds
            kindMap[it.id] = it.kind
            if orderSet.insert(it.id).inserted {
                order.append(it.id)
            }
        }
        if items.count > 1 && replacedAny {
            // 批量替换：所有被替换的区段都成了空洞，直接一次线性重排最省
            rebuildBuffers()
            drawListDirty = true
        } else {
            let wasClean = !drawListDirty
            var dropped = 0
            for it in items where !it.mesh.isEmpty {
                if !appendMesh(it.mesh, id: it.id) { dropped += 1 }
            }
            if dropped > 0 { onBufferFull?(dropped) }
            maybeCompact()   // 可能整体重排，会自行置脏
            // 提交一笔是最高频的路径：没有发生重排/扩容时直接往绘制表尾部追加一条，
            // 避免每落一笔都 O(已提交笔画数) 地重建整张表。
            if wasClean, !drawListDirty, dropped == 0, items.count == 1,
               let range = ranges[items[0].id], range.indexCount > 0, drawSlot[items[0].id] == nil {
                appendDrawItem(id: items[0].id, range: range)
            } else {
                drawListDirty = true
            }
        }
        setNeedsDisplay()
    }

    /// 增量删除若干笔（记空洞，不搬移）
    func removeMeshes(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        var changed = false
        for id in set {
            // 没有 range 也要清干净（缓冲曾写满、或 mesh 为空的笔画）：
            // 只 continue 会把 meshes/order 里的残留留下，之后一次 compact()
            // 就会把这条「已删除」的笔画重新写回缓冲，死而复生。
            if let range = ranges[id] {
                holeVertices += meshes[id]?.vertices.count ?? 0
                holeIndices += range.indexCount
            } else if !orderSet.contains(id) && meshes[id] == nil {
                continue
            }
            meshes.removeValue(forKey: id)
            boundsMap.removeValue(forKey: id)
            ranges.removeValue(forKey: id)
            kindMap.removeValue(forKey: id)
            changed = true
        }
        if changed {
            order.removeAll { set.contains($0) }
            orderSet.subtract(set)
            maybeCompact()
            drawListDirty = true
            setNeedsDisplay()
        }
    }

    /// 原地更新 mesh（顶点/索引数必须一致，移动笔画用，无空洞零扩容）
    func updateMeshInPlace(id: UUID, mesh: StrokeMesh, bounds: CGRect) {
        guard let range = ranges[id],
              let old = meshes[id],
              old.vertices.count == mesh.vertices.count,
              old.indices.count == mesh.indices.count
        else { return }
        meshes[id] = mesh
        boundsMap[id] = bounds
        copyVertices(mesh.vertices[...], into: vertexBuffer, atVertex: range.vertexOffset)
        copyIndices(mesh.indices[...], into: indexBuffer, atIndex: range.indexOffset)
        // bounds 变了，绘制列表里的裁剪盒要跟着更新——但只改一个格子就够，
        // 整表重建会让「拖动选中笔画」每帧都付一次 O(已提交笔画数)。
        if !patchDrawItemBounds(id: id, bounds: bounds) {
            drawListDirty = true
        }
        setNeedsDisplay()
    }

    private func maybeCompact() {
        if holeVertices > 65536 || (vertexCapacity > 0 && holeVertices * 3 > vertexCapacity)
            || holeIndices > 262_144 || (indexCapacity > 0 && holeIndices * 3 > indexCapacity) {
            compact()
        }
    }

    /// 按 order 从 CPU 侧 meshes 一次线性重排整个缓冲（批量替换/LOD 用）
    private func rebuildBuffers() {
        var totalV = 0, totalI = 0
        for id in order {
            guard let m = meshes[id], !m.isEmpty else { continue }
            totalV += m.vertices.count
            totalI += m.indices.count
        }
        // ensureCapacity 扩容时内部已经用 meshes 重建过一遍，别再重排第二次
        let grew = totalV > vertexCapacity || totalI > indexCapacity
        let ok = ensureCapacity(vertices: totalV, indices: totalI)
        if !ok {
            print("[StrokeMetalView] WARNING: batch upsert exceeds buffer cap")
            onBufferFull?(order.count)
        }
        if !grew || !ok {
            compact()   // compact 自带容量守卫，写不下的笔只是不画，不会越界
        }
    }

    /// 更新 live 笔画 mesh（nil = 清除）。橡皮/套索轨迹等全量路径用。
    func setLiveMesh(_ mesh: StrokeMesh?, kind: BrushKind = .pen) {
        guard let mesh, !mesh.isEmpty else {
            liveKind = kind
            liveIndexCount = 0
            liveNeedsFullUpload = false
            setNeedsDisplay()
            return
        }
        updateLiveMesh(
            vertices: mesh.vertices, indices: mesh.indices,
            dirtyVertexStart: 0, dirtyIndexStart: 0, kind: kind
        )
        // 这条全量路径（橡皮/套索轨迹）与增量构建器不共享状态，缓冲里现在是别的几何。
        // 万一之后有人接着做增量更新，前缀就是陈的 —— 强制下一次整段重传。
        liveNeedsFullUpload = true
    }

    /// 增量更新 live 笔画：只把 [dirtyVertexStart...] / [dirtyIndexStart...] 重传给 GPU。
    /// 笔画已确认的前缀在整笔期间逐字节不变（见 LiveStrokeMesh），
    /// 每事件重传全量是 O(n) 的纯浪费——一笔 3 秒的字会白传约 23 MB。
    func updateLiveMesh(
        vertices: [StrokeVertex], indices: [UInt32],
        dirtyVertexStart: Int, dirtyIndexStart: Int, kind: BrushKind
    ) {
        liveKind = kind
        guard !vertices.isEmpty, !indices.isEmpty else {
            liveIndexCount = 0
            liveNeedsFullUpload = false
            setNeedsDisplay()
            return
        }
        let grow = ensureLiveCapacity(vertices: vertices.count, indices: indices.count)
        guard grow.ok else {
            // 分配失败：缓冲内容不可信，下次必须整段重传
            liveNeedsFullUpload = true
            return
        }
        // 换了新 MTLBuffer（旧内容丢失）或 renderOrigin 变了，都必须整段重传，
        // 否则「稳定前缀」里留着垃圾或旧原点的坐标。
        let full = grow.reallocated || liveNeedsFullUpload
        liveNeedsFullUpload = false
        let vStart = full ? 0 : min(max(dirtyVertexStart, 0), vertices.count)
        let iStart = full ? 0 : min(max(dirtyIndexStart, 0), indices.count)
        if vStart < vertices.count {
            copyVertices(vertices[vStart...], into: liveVertexBuffer, atVertex: vStart)
        }
        if iStart < indices.count {
            copyIndices(indices[iStart...], into: liveIndexBuffer, atIndex: iStart)
        }
        liveIndexCount = indices.count
        setNeedsDisplay()
    }

    // MARK: - Buffer 管理

    private func meshVertexCount(for id: UUID) -> Int {
        meshes[id]?.vertices.count ?? 0
    }

    @discardableResult
    private func appendMesh(_ mesh: StrokeMesh, id: UUID) -> Bool {
        guard !mesh.isEmpty else {
            ranges.removeValue(forKey: id)
            return true
        }
        if !ensureCapacity(
            vertices: vertexCount + mesh.vertices.count,
            indices: indexCount + mesh.indices.count
        ) {
            // 先回收删除留下的空洞再试一次：缓冲「满」往往只是碎了，不是真的用光
            if holeVertices > 0 || holeIndices > 0 {
                compact()
            }
            guard ensureCapacity(
                vertices: vertexCount + mesh.vertices.count,
                indices: indexCount + mesh.indices.count
            ) else {
                print("[StrokeMetalView] WARNING: stroke buffer full, stroke dropped")
                ranges.removeValue(forKey: id)
                return false
            }
        }
        // ensureCapacity / compact 会按 (order, meshes) 整体重排缓冲。本笔的
        // mesh 在调用前就已经写进 meshes、id 也已在 order 里，所以重排时它
        // **已经被放好了**——这时再 append 一次就是把同一份几何写两遍：
        // vertexCount 翻倍，且第二份很可能落到 MTLBuffer 末尾之外。
        if ranges[id] != nil { return true }
        copyVertices(mesh.vertices[...], into: vertexBuffer, atVertex: vertexCount)
        copyIndices(mesh.indices[...], into: indexBuffer, atIndex: indexCount)
        ranges[id] = IndexRange(
            vertexOffset: vertexCount,
            indexOffset: indexCount,
            indexCount: mesh.indices.count
        )
        vertexCount += mesh.vertices.count
        indexCount += mesh.indices.count
        return true
    }

    /// 空洞整理：按 order 重建 buffer。
    /// 容量守卫必不可少：缓冲写满后若还有 LOD 重建进来，无守卫的 memcpy 会写到
    /// 25MB MTLBuffer 之外（越界写 + 之后 vertexCount > vertexCapacity 全线失效）。
    private func compact() {
        var v = 0
        var idx = 0
        var overflow = 0
        for id in order {
            guard let mesh = meshes[id], !mesh.isEmpty else { continue }
            guard v + mesh.vertices.count <= vertexCapacity,
                  idx + mesh.indices.count <= indexCapacity
            else {
                ranges.removeValue(forKey: id)
                overflow += 1
                continue
            }
            copyVertices(mesh.vertices[...], into: vertexBuffer, atVertex: v)
            copyIndices(mesh.indices[...], into: indexBuffer, atIndex: idx)
            ranges[id] = IndexRange(vertexOffset: v, indexOffset: idx, indexCount: mesh.indices.count)
            v += mesh.vertices.count
            idx += mesh.indices.count
        }
        vertexCount = v
        indexCount = idx
        holeVertices = 0
        holeIndices = 0
        drawListDirty = true
        if overflow > 0 {
            print("[StrokeMetalView] WARNING: \(overflow) strokes exceed buffer capacity, not drawn")
        }
    }

    /// 两个维度各自扩容后只重建一次（原来两边都扩时整库 memcpy 会白做两遍）
    private func ensureCapacity(vertices: Int, indices: Int) -> Bool {
        guard vertices <= Self.maxVertices, indices <= Self.maxIndices else { return false }
        var grew = false
        if vertices > vertexCapacity {
            let want = max(max(vertices, Self.initialVertexCapacity), vertexCapacity * 2)
            guard let buf = device?.makeBuffer(length: want * 24, options: .storageModeShared) else {
                // 分配失败必须回滚容量，否则后续写入会以为有空间（buffer 为 nil，
                // copyVertices 静默不写），笔画从此再也画不出来且无法恢复。
                return false
            }
            vertexCapacity = want
            vertexBuffer = buf
            grew = true
        }
        if indices > indexCapacity {
            let want = max(max(indices, Self.initialIndexCapacity), indexCapacity * 2)
            guard let buf = device?.makeBuffer(length: want * 4, options: .storageModeShared) else {
                if grew { compactIntoNewBuffers() }   // 顶点缓冲已经换新，必须重填
                return false
            }
            indexCapacity = want
            indexBuffer = buf
            grew = true
        }
        // 扩容后旧 buffer 的数据丢失 -> 用 CPU 侧 meshes 字典重建一次
        if grew { compactIntoNewBuffers() }
        return vertexBuffer != nil && indexBuffer != nil
    }

    /// 扩容后用 CPU 侧 meshes 字典重建 buffer 内容
    private func compactIntoNewBuffers() {
        var v = 0
        var idx = 0
        for id in order {
            guard let mesh = meshes[id], !mesh.isEmpty else { continue }
            if v + mesh.vertices.count > vertexCapacity || idx + mesh.indices.count > indexCapacity {
                ranges.removeValue(forKey: id)
                continue // 极端情况：本次扩容仍不够（另一维先扩），留待下次
            }
            copyVertices(mesh.vertices[...], into: vertexBuffer, atVertex: v)
            copyIndices(mesh.indices[...], into: indexBuffer, atIndex: idx)
            ranges[id] = IndexRange(vertexOffset: v, indexOffset: idx, indexCount: mesh.indices.count)
            v += mesh.vertices.count
            idx += mesh.indices.count
        }
        vertexCount = v
        indexCount = idx
        holeVertices = 0
        holeIndices = 0
        drawListDirty = true
    }

    /// - Returns: ok = 缓冲可用；reallocated = 换了新 MTLBuffer（旧内容已丢，必须全量重传）
    private func ensureLiveCapacity(vertices: Int, indices: Int) -> (ok: Bool, reallocated: Bool) {
        guard vertices <= Self.maxVertices, indices <= Self.maxIndices else { return (false, false) }
        var reallocated = false
        if vertices > liveVertexCapacity || liveVertexBuffer == nil {
            let want = max(vertices, max(liveVertexCapacity * 2, 1024))
            // 容量只在分配成功后才提升：先提后判会让每个输入事件都再翻一倍，
            // 几十次之后 want * 24 整数溢出直接 trap。
            guard let buf = device?.makeBuffer(length: want * 24, options: .storageModeShared) else {
                return (false, reallocated)
            }
            liveVertexCapacity = want
            liveVertexBuffer = buf
            reallocated = true
        }
        if indices > liveIndexCapacity || liveIndexBuffer == nil {
            let want = max(indices, max(liveIndexCapacity * 2, 4096))
            guard let buf = device?.makeBuffer(length: want * 4, options: .storageModeShared) else {
                return (false, reallocated)
            }
            liveIndexCapacity = want
            liveIndexBuffer = buf
            reallocated = true
        }
        return (true, reallocated)
    }

    /// 上传顶点：绝对坐标 − renderOrigin（double 域相减）后存入 GPU 缓冲。
    /// 原点为零时走 memcpy 快路径（新画布默认行为不变）。
    private func copyVertices(
        _ vertices: ArraySlice<StrokeVertex>, into buffer: MTLBuffer?, atVertex offset: Int
    ) {
        guard let ptr = buffer?.contents(), !vertices.isEmpty else { return }
        let ox = Double(renderOrigin.x), oy = Double(renderOrigin.y)
        if ox == 0 && oy == 0 {
            vertices.withUnsafeBytes { src in
                guard let base = src.baseAddress else { return }
                memcpy(ptr.advanced(by: offset * 24), base, src.count)
            }
            return
        }
        var dst = ptr.advanced(by: offset * 24).assumingMemoryBound(to: StrokeVertex.self)
        for v in vertices {
            var shifted = v
            // float→double 精确提升，减法在 double 域，结果是视口尺度小数
            shifted.x = Float(Double(v.x) - ox)
            shifted.y = Float(Double(v.y) - oy)
            dst.pointee = shifted
            dst = dst.advanced(by: 1)
        }
    }

    private func copyIndices(
        _ indices: ArraySlice<UInt32>, into buffer: MTLBuffer?, atIndex offset: Int
    ) {
        guard let ptr = buffer?.contents(), !indices.isEmpty else { return }
        indices.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            memcpy(ptr.advanced(by: offset * 4), base, src.count)
        }
    }

    // MARK: - 绘制列表重建

    /// 按 order 走一遍，拆成荧光笔/墨线两条稠密列表。
    /// 只在内容变更时跑（提交/擦除/撤销/加载），不在每帧跑。
    private func rebuildDrawLists() {
        drawListDirty = false
        highlighterItems.removeAll(keepingCapacity: true)
        inkItems.removeAll(keepingCapacity: true)
        drawSlot.removeAll(keepingCapacity: true)
        highlighterItems.reserveCapacity(order.count / 8 + 1)
        inkItems.reserveCapacity(order.count)
        drawSlot.reserveCapacity(order.count)
        for id in order {
            guard let range = ranges[id], range.indexCount > 0 else { continue }
            appendDrawItem(id: id, range: range)
        }
    }

    private func appendDrawItem(id: UUID, range: IndexRange) {
        var item = DrawItem(
            vertexOffset: range.vertexOffset,
            indexOffset: range.indexOffset,
            indexCount: range.indexCount,
            minX: 1, minY: 0, maxX: 0, maxY: 0   // 默认哨兵：无 bounds -> 恒绘制
        )
        if let b = boundsMap[id], !b.isNull {
            item.minX = b.minX
            item.minY = b.minY
            item.maxX = b.maxX
            item.maxY = b.maxY
        }
        if kindMap[id] == .highlighter {
            drawSlot[id] = (true, highlighterItems.count)
            highlighterItems.append(item)
        } else {
            drawSlot[id] = (false, inkItems.count)
            inkItems.append(item)
        }
    }

    /// 只有包围盒变了（顶点/索引数与偏移都没动）：原地改，别整表重建。
    /// 拖动选中笔画时这条路径每帧每笔都会走一次。
    /// - Returns: 是否成功原地更新
    private func patchDrawItemBounds(id: UUID, bounds: CGRect) -> Bool {
        guard !drawListDirty, let slot = drawSlot[id] else { return false }
        let null = bounds.isNull
        let minX = null ? 1 : bounds.minX, maxX = null ? 0 : bounds.maxX
        let minY = null ? 0 : bounds.minY, maxY = null ? 0 : bounds.maxY
        if slot.highlighter {
            guard slot.index < highlighterItems.count else { return false }
            highlighterItems[slot.index].minX = minX
            highlighterItems[slot.index].minY = minY
            highlighterItems[slot.index].maxX = maxX
            highlighterItems[slot.index].maxY = maxY
        } else {
            guard slot.index < inkItems.count else { return false }
            inkItems[slot.index].minX = minX
            inkItems[slot.index].minY = minY
            inkItems[slot.index].maxX = maxX
            inkItems[slot.index].maxY = maxY
        }
        return true
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard let device,
              let pipeline,
              let commandQueue,
              let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              viewport.size.width > 0, viewport.size.height > 0, viewport.scale > 0
        else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
        else { return }

        // center 传相机相对原点的偏移（double 相减），与顶点缓冲的相对坐标配套
        let cam = viewport.camera.center
        var uniforms = StrokeUniforms(
            center: SIMD2<Float>(
                Float(Double(cam.x) - Double(renderOrigin.x)),
                Float(Double(cam.y) - Double(renderOrigin.y))
            ),
            scale: Float(viewport.scale),
            viewSize: SIMD2<Float>(Float(viewport.size.width), Float(viewport.size.height))
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<StrokeUniforms>.stride, index: 1)
        encoder.setCullMode(.none)

        // 已提交笔画（逐笔画视锥裁剪；荧光笔先画，落在墨线下，各层内保 z 序）
        if let vb = vertexBuffer, let ib = indexBuffer, !order.isEmpty {
            if drawListDirty { rebuildDrawLists() }
            let visible = viewport.visibleWorldRect
            let vx0 = visible.minX, vx1 = visible.maxX
            let vy0 = visible.minY, vy1 = visible.maxY
            encoder.setVertexBuffer(vb, offset: 0, index: 0)
            func drawCommitted(_ items: [DrawItem]) {
                for it in items {
                    // minX > maxX 是「无 bounds」哨兵：与旧的 `if let b = boundsMap[id]` 语义一致（恒绘制）
                    if it.minX <= it.maxX,
                       it.maxX < vx0 || it.minX > vx1 || it.maxY < vy0 || it.minY > vy1 {
                        continue
                    }
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: it.indexCount,
                        indexType: .uint32,
                        indexBuffer: ib,
                        indexBufferOffset: it.indexOffset * 4,
                        instanceCount: 1,
                        baseVertex: it.vertexOffset,
                        baseInstance: 0
                    )
                }
            }
            func drawLive() {
                if liveIndexCount > 0, let lvb = liveVertexBuffer, let lib = liveIndexBuffer {
                    encoder.setVertexBuffer(lvb, offset: 0, index: 0)
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: liveIndexCount,
                        indexType: .uint32,
                        indexBuffer: lib,
                        indexBufferOffset: 0
                    )
                    encoder.setVertexBuffer(vb, offset: 0, index: 0)
                }
            }
            // Live 笔画（不裁剪，必在附近）：荧光笔 live 与提交荧光笔同层先画
            if liveKind == .highlighter { drawLive() }
            drawCommitted(highlighterItems)
            drawCommitted(inkItems)
            if liveKind != .highlighter { drawLive() }
        } else if liveIndexCount > 0, let lvb = liveVertexBuffer, let lib = liveIndexBuffer {
            // 无已提交笔画时 live 独画
            encoder.setVertexBuffer(lvb, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: liveIndexCount,
                indexType: .uint32,
                indexBuffer: lib,
                indexBufferOffset: 0
            )
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
