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
            copyVertices(mesh.vertices, into: vertexBuffer, atVertex: range.vertexOffset)
        }
        if !liveVerticesCache.isEmpty {
            copyVertices(liveVerticesCache, into: liveVertexBuffer, atVertex: 0)
        }
    }

    // MARK: - Metal 状态

    private var pipeline: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?

    // MARK: - 已提交笔画缓冲（共享，append-only）

    private var order: [UUID] = []
    private var meshes: [UUID: StrokeMesh] = [:]
    private var boundsMap: [UUID: CGRect] = [:]
    private var ranges: [UUID: IndexRange] = [:]

    private struct IndexRange {
        var vertexOffset: Int  // 以顶点为单位（draw 用 baseVertex）
        var indexOffset: Int   // 以索引为单位
        var indexCount: Int
    }

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
    /// live 顶点 CPU 侧缓存（绝对坐标；rebase 时重传用）
    private var liveVerticesCache: [StrokeVertex] = []

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
        }
        if !removed.isEmpty {
            order.removeAll { removed.contains($0) }
        }

        // 新增：append 到 buffer 尾
        for s in strokes where !oldSet.contains(s.id) || ranges[s.id] == nil {
            guard appendMesh(s.mesh, id: s.id) else { continue }
            meshes[s.id] = s.mesh
            boundsMap[s.id] = s.bounds
        }
        order = newIDs
        maybeCompact()
        setNeedsDisplay()
    }

    /// 增量 upsert 一笔（新增 append、已存在替换为新区段）。LOD/碎片/撤销恢复用。
    func upsertMesh(id: UUID, mesh: StrokeMesh, bounds: CGRect) {
        if let range = ranges[id] {
            holeVertices += meshes[id]?.vertices.count ?? 0
            holeIndices += range.indexCount
        }
        meshes[id] = mesh
        boundsMap[id] = bounds
        if !mesh.isEmpty {
            appendMesh(mesh, id: id)
        } else {
            ranges.removeValue(forKey: id)
        }
        if !order.contains(id) {
            order.append(id)
        }
        maybeCompact()
        setNeedsDisplay()
    }

    /// 增量删除若干笔（记空洞，不搬移）
    func removeMeshes(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        var changed = false
        for id in set {
            guard ranges[id] != nil else { continue }
            if let range = ranges[id] {
                holeVertices += meshes[id]?.vertices.count ?? 0
                holeIndices += range.indexCount
            }
            meshes.removeValue(forKey: id)
            boundsMap.removeValue(forKey: id)
            ranges.removeValue(forKey: id)
            changed = true
        }
        if changed {
            order.removeAll { set.contains($0) }
            maybeCompact()
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
        copyVertices(mesh.vertices, into: vertexBuffer, atVertex: range.vertexOffset)
        copyIndices(mesh.indices, into: indexBuffer, atIndex: range.indexOffset)
        setNeedsDisplay()
    }

    private func maybeCompact() {
        if holeVertices > 65536 || (vertexCapacity > 0 && holeVertices * 3 > vertexCapacity) {
            compact()
        }
    }

    /// 更新 live 笔画 mesh（nil = 清除）。每输入事件调用。
    func setLiveMesh(_ mesh: StrokeMesh?) {
        guard let mesh, !mesh.isEmpty else {
            liveIndexCount = 0
            liveVerticesCache = []
            setNeedsDisplay()
            return
        }
        liveVerticesCache = mesh.vertices
        guard ensureLiveCapacity(vertices: mesh.vertices.count, indices: mesh.indices.count) else {
            return
        }
        copyVertices(mesh.vertices, into: liveVertexBuffer, atVertex: 0)
        copyIndices(mesh.indices, into: liveIndexBuffer, atIndex: 0)
        liveIndexCount = mesh.indices.count
        setNeedsDisplay()
    }

    // MARK: - Buffer 管理

    private func meshVertexCount(for id: UUID) -> Int {
        meshes[id]?.vertices.count ?? 0
    }

    @discardableResult
    private func appendMesh(_ mesh: StrokeMesh, id: UUID) -> Bool {
        guard !mesh.isEmpty else { return true }
        guard ensureCapacity(
            vertices: vertexCount + mesh.vertices.count,
            indices: indexCount + mesh.indices.count
        ) else {
            print("[StrokeMetalView] WARNING: stroke buffer full, stroke dropped")
            return false
        }
        copyVertices(mesh.vertices, into: vertexBuffer, atVertex: vertexCount)
        copyIndices(mesh.indices, into: indexBuffer, atIndex: indexCount)
        ranges[id] = IndexRange(
            vertexOffset: vertexCount,
            indexOffset: indexCount,
            indexCount: mesh.indices.count
        )
        vertexCount += mesh.vertices.count
        indexCount += mesh.indices.count
        return true
    }

    /// 空洞整理：按 order 重建 buffer
    private func compact() {
        var v = 0
        var idx = 0
        for id in order {
            guard let mesh = meshes[id], !mesh.isEmpty else { continue }
            copyVertices(mesh.vertices, into: vertexBuffer, atVertex: v)
            copyIndices(mesh.indices, into: indexBuffer, atIndex: idx)
            ranges[id] = IndexRange(vertexOffset: v, indexOffset: idx, indexCount: mesh.indices.count)
            v += mesh.vertices.count
            idx += mesh.indices.count
        }
        vertexCount = v
        indexCount = idx
        holeVertices = 0
        holeIndices = 0
    }

    private func ensureCapacity(vertices: Int, indices: Int) -> Bool {
        guard vertices <= Self.maxVertices, indices <= Self.maxIndices else { return false }
        if vertices > vertexCapacity {
            vertexCapacity = max(max(vertices, Self.initialVertexCapacity), vertexCapacity * 2)
            vertexBuffer = device?.makeBuffer(
                length: vertexCapacity * 24, options: .storageModeShared
            )
            if vertexBuffer == nil { return false }
            // 扩容后旧数据丢失 -> 重建（ranges 失效前先 compact，用 meshes 字典）
            compactIntoNewBuffers()
        }
        if indices > indexCapacity {
            indexCapacity = max(max(indices, Self.initialIndexCapacity), indexCapacity * 2)
            indexBuffer = device?.makeBuffer(
                length: indexCapacity * 4, options: .storageModeShared
            )
            if indexBuffer == nil { return false }
            compactIntoNewBuffers()
        }
        return vertexBuffer != nil && indexBuffer != nil
    }

    /// 扩容后用 CPU 侧 meshes 字典重建 buffer 内容
    private func compactIntoNewBuffers() {
        var v = 0
        var idx = 0
        for id in order {
            guard let mesh = meshes[id], !mesh.isEmpty else { continue }
            if v + mesh.vertices.count > vertexCapacity || idx + mesh.indices.count > indexCapacity {
                break // 极端情况：本次扩容仍不够（另一维先扩），留待下次
            }
            copyVertices(mesh.vertices, into: vertexBuffer, atVertex: v)
            copyIndices(mesh.indices, into: indexBuffer, atIndex: idx)
            ranges[id] = IndexRange(vertexOffset: v, indexOffset: idx, indexCount: mesh.indices.count)
            v += mesh.vertices.count
            idx += mesh.indices.count
        }
        vertexCount = v
        indexCount = idx
        holeVertices = 0
        holeIndices = 0
    }

    private func ensureLiveCapacity(vertices: Int, indices: Int) -> Bool {
        guard vertices <= Self.maxVertices, indices <= Self.maxIndices else { return false }
        if vertices > liveVertexCapacity {
            liveVertexCapacity = max(vertices, max(liveVertexCapacity * 2, 1024))
            liveVertexBuffer = device?.makeBuffer(length: liveVertexCapacity * 24, options: .storageModeShared)
        }
        if indices > liveIndexCapacity {
            liveIndexCapacity = max(indices, max(liveIndexCapacity * 2, 4096))
            liveIndexBuffer = device?.makeBuffer(length: liveIndexCapacity * 4, options: .storageModeShared)
        }
        return liveVertexBuffer != nil && liveIndexBuffer != nil
    }

    /// 上传顶点：绝对坐标 − renderOrigin（double 域相减）后存入 GPU 缓冲。
    /// 原点为零时走 memcpy 快路径（新画布默认行为不变）。
    private func copyVertices(_ vertices: [StrokeVertex], into buffer: MTLBuffer?, atVertex offset: Int) {
        guard let ptr = buffer?.contents() else { return }
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

    private func copyIndices(_ indices: [UInt32], into buffer: MTLBuffer?, atIndex offset: Int) {
        guard let ptr = buffer?.contents() else { return }
        indices.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            memcpy(ptr.advanced(by: offset * 4), base, src.count)
        }
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

        // 已提交笔画（逐笔画视锥裁剪）
        if let vb = vertexBuffer, let ib = indexBuffer, !order.isEmpty {
            let visible = viewport.visibleWorldRect
            encoder.setVertexBuffer(vb, offset: 0, index: 0)
            for id in order {
                guard let range = ranges[id] else { continue }
                if let b = boundsMap[id], !b.isNull, !b.intersects(visible) { continue }
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: range.indexCount,
                    indexType: .uint32,
                    indexBuffer: ib,
                    indexBufferOffset: range.indexOffset * 4,
                    instanceCount: 1,
                    baseVertex: range.vertexOffset,
                    baseInstance: 0
                )
            }
        }

        // Live 笔画（不裁剪，必在附近）
        if liveIndexCount > 0, let lvb = liveVertexBuffer, let lib = liveIndexBuffer {
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
