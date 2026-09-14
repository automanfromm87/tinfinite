// ContentStore.swift
// 内容节点真相源（纯逻辑，可单测）：增删改 + 单选 + 撤销/重做。
// 与 StrokeStore 对等的极简设计；跨域 undo 顺序由 DrawingController 的 journal 协调。

import CoreGraphics
import Foundation

/// 节点撤销条目
nonisolated enum ContentUndoEntry: Sendable {
    case added(node: ContentNode)
    case removed(items: [IndexedContentNode]) // index 升序
    case moved(id: UUID, delta: CGSize)
    case texted(id: UUID, before: String, after: String)
}

/// 带原下标的节点（删除恢复位置用）
nonisolated struct IndexedContentNode: Sendable {
    var index: Int
    var node: ContentNode
}

/// 节点变更（Controller 同步视图用）
nonisolated struct ContentSync: Sendable {
    var upserts: [ContentNode] = []
    var removedIDs: [UUID] = []
    var isEmpty: Bool { upserts.isEmpty && removedIDs.isEmpty }
}

nonisolated struct ContentStore: Sendable {
    private(set) var nodes: [ContentNode] = []
    /// 当前选中（单选；nil = 无选中）
    private(set) var selectedID: UUID?

    private var undoStack: [ContentUndoEntry] = []
    private var redoStack: [ContentUndoEntry] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// 撤销栈深度（Controller 跨域 journal 用：比较调用前后判断是否产生了新条目）
    var undoDepth: Int { undoStack.count }

    /// 同 StrokeStore：栈满后 undoDepth 不再变化，必须用单调序号记账
    private(set) var mutationSeq = 0
    private(set) var discardSeq = 0
    var undoMark: UndoMark { UndoMark(seq: mutationSeq, discarded: discardSeq) }

    func node(id: UUID) -> ContentNode? {
        nodes.first { $0.id == id }
    }

    // MARK: - 增删改

    mutating func add(_ node: ContentNode) {
        nodes.append(node)
        pushUndo(.added(node: node))
    }

    /// 删除若干节点，返回被删节点（含原下标，视图/文件清理用）
    @discardableResult
    mutating func remove(ids: Set<UUID>) -> [IndexedContentNode] {
        guard !ids.isEmpty else { return [] }
        var removed: [IndexedContentNode] = []
        var kept: [ContentNode] = []
        kept.reserveCapacity(nodes.count)
        for (i, n) in nodes.enumerated() {
            if ids.contains(n.id) {
                removed.append(IndexedContentNode(index: i, node: n))
            } else {
                kept.append(n)
            }
        }
        guard !removed.isEmpty else { return [] }
        nodes = kept
        if let sel = selectedID, ids.contains(sel) { selectedID = nil }
        pushUndo(.removed(items: removed))
        return removed
    }

    /// 平移节点（拖拽提交时调用一次；拖拽预览直接改 UIView，不经过这里）
    mutating func move(id: UUID, by delta: CGSize) -> ContentSync {
        guard delta.width != 0 || delta.height != 0,
              let i = indexOf(id: id)
        else { return ContentSync() }
        nodes[i].frame = nodes[i].frame.offsetBy(dx: delta.width, dy: delta.height)
        pushUndo(.moved(id: id, delta: delta))
        return ContentSync(upserts: [nodes[i]])
    }

    /// 整框设置（程序化布局用，记一次 undo）
    mutating func setFrame(id: UUID, frame: CGRect) -> ContentSync {
        guard let i = indexOf(id: id), nodes[i].frame != frame else { return ContentSync() }
        let from = nodes[i].frame
        nodes[i].frame = frame
        // 以“移动 + 缩放”记 undo 太细，这里只记移动部分过于复杂——
        // 简化：记 moved(位移)，尺寸变化不可单独撤销（拖拽只产生位移，够用）
        pushUndo(.moved(id: id, delta: CGSize(width: frame.minX - from.minX, height: frame.minY - from.minY)))
        return ContentSync(upserts: [nodes[i]])
    }

    /// 改文本：连续输入合并为一步 undo（栈顶是同节点的 texted 则只更新 before 保持首次值）。
    mutating func setText(id: UUID, text: String) {
        guard let i = indexOf(id: id), nodes[i].text != text else { return }
        if case .texted(let tid, let before, _) = undoStack.last, tid == id {
            // 已在一次输入中：before 保持首次值，after 跟进最新值
            undoStack[undoStack.count - 1] = .texted(id: tid, before: before, after: text)
        } else {
            pushUndo(.texted(id: id, before: nodes[i].text, after: text))
        }
        nodes[i].text = text
    }

    mutating func clear() -> ContentSync {
        guard !nodes.isEmpty else { return ContentSync() }
        let removed = nodes.enumerated().map { IndexedContentNode(index: $0.offset, node: $0.element) }
        let ids = nodes.map(\.id)
        nodes.removeAll()
        selectedID = nil
        pushUndo(.removed(items: removed))
        return ContentSync(removedIDs: ids)
    }

    mutating func replaceAll(with newNodes: [ContentNode]) {
        nodes = newNodes
        selectedID = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: - 选择（不记 undo，与笔画选择一致）

    mutating func select(id: UUID?) {
        selectedID = id
    }

    // MARK: - Undo/Redo

    mutating func undo() -> ContentSync? {
        guard let entry = undoStack.popLast() else { return nil }
        let sync = applyInverse(entry)
        redoStack.append(entry)
        sanitizeSelection()
        return sync
    }

    mutating func redo() -> ContentSync? {
        guard let entry = redoStack.popLast() else { return nil }
        let sync = applyForward(entry)
        undoStack.append(entry)
        sanitizeSelection()
        return sync
    }

    // MARK: - 内部

    /// 撤销栈上限（与 StrokeStore 对齐，超限丢弃最旧的一步）
    static let maxUndoDepth = 100

    private mutating func pushUndo(_ entry: ContentUndoEntry) {
        undoStack.append(entry)
        mutationSeq += 1
        if undoStack.count > Self.maxUndoDepth {
            let drop = undoStack.count - Self.maxUndoDepth
            undoStack.removeFirst(drop)
            discardSeq += drop
        }
        redoStack.removeAll()
    }

    private func indexOf(id: UUID) -> Int? {
        nodes.firstIndex { $0.id == id }
    }

    private mutating func applyInverse(_ entry: ContentUndoEntry) -> ContentSync {
        switch entry {
        case .added(let node):
            nodes.removeAll { $0.id == node.id }
            return ContentSync(removedIDs: [node.id])
        case .removed(let items):
            // 按原下标插回（index 升序逐个插入）
            for item in items.sorted(by: { $0.index < $1.index }) {
                nodes.insert(item.node, at: min(item.index, nodes.count))
            }
            return ContentSync(upserts: items.map(\.node))
        case .moved(let id, let delta):
            guard let i = indexOf(id: id) else { return ContentSync() }
            nodes[i].frame = nodes[i].frame.offsetBy(dx: -delta.width, dy: -delta.height)
            return ContentSync(upserts: [nodes[i]])
        case .texted(let id, let before, _):
            guard let i = indexOf(id: id) else { return ContentSync() }
            nodes[i].text = before
            return ContentSync(upserts: [nodes[i]])
        }
    }

    private mutating func applyForward(_ entry: ContentUndoEntry) -> ContentSync {
        switch entry {
        case .added(let node):
            if indexOf(id: node.id) == nil { nodes.append(node) }
            return ContentSync(upserts: [node])
        case .removed(let items):
            let ids = Set(items.map(\.node.id))
            nodes.removeAll { ids.contains($0.id) }
            return ContentSync(removedIDs: Array(ids))
        case .moved(let id, let delta):
            guard let i = indexOf(id: id) else { return ContentSync() }
            nodes[i].frame = nodes[i].frame.offsetBy(dx: delta.width, dy: delta.height)
            return ContentSync(upserts: [nodes[i]])
        case .texted(let id, _, let after):
            guard let i = indexOf(id: id) else { return ContentSync() }
            nodes[i].text = after
            return ContentSync(upserts: [nodes[i]])
        }
    }

    private mutating func sanitizeSelection() {
        if let sel = selectedID, indexOf(id: sel) == nil {
            selectedID = nil
        }
    }
}
