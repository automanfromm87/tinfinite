// StrokeSpatialGrid.swift
// 笔画空间哈希网格（纯逻辑，可单测）：点选/橡皮/套索/可见集的候选过滤。
// 只做候选集（精确判定仍由调用方的 spine 级测试完成），语义与暴力扫描完全一致。
// 查询返回 nil 表示范围过大不值得过滤，调用方回退全量扫描（正确性优先）。

import CoreGraphics
import Foundation

nonisolated struct StrokeSpatialGrid: Sendable {
    /// 格边长（世界单位）：笔画 bounds 典型几十~几百，256 让大多数笔画落 1~4 格
    static let cellSize: CGFloat = 256
    /// 单笔画最大占格数：超限进 overflow 表（每次查询都带上），防超长笔画炸表
    static let maxCellsPerStroke = 1024
    /// 单查询最大扫格数：超限返回 nil（调用方回退全量扫描）
    static let maxCellsPerQuery = 4096

    struct CellID: Hashable, Sendable {
        var x, y: Int
    }

    private var cells: [CellID: Set<UUID>] = [:]
    /// 反向表（O(占格) 删除用）
    private var home: [UUID: Set<CellID>] = [:]
    /// 超大笔画（任何查询都包含）
    private var overflow: Set<UUID> = []

    var isEmpty: Bool { home.isEmpty && overflow.isEmpty }
    var count: Int { home.count + overflow.count }

    mutating func insert(id: UUID, bounds: CGRect) {
        remove(id: id)
        guard let covered = Self.spanCells(for: bounds, limit: Self.maxCellsPerStroke) else {
            overflow.insert(id)
            return
        }
        // 合法矩形恒占 ≥1 格；空集只可能来自非法矩形（null/NaN/负尺寸），
        // 进 overflow 保证任何查询都带上，与暴力扫描行为一致
        guard !covered.isEmpty else {
            overflow.insert(id)
            return
        }
        home[id] = covered
        for c in covered {
            cells[c, default: []].insert(id)
        }
    }

    mutating func remove(id: UUID) {
        if let owned = home.removeValue(forKey: id) {
            for c in owned {
                cells[c]?.remove(id)
                if cells[c]?.isEmpty == true {
                    cells.removeValue(forKey: c)
                }
            }
        }
        overflow.remove(id)
    }

    /// 移动后的 bounds 更新（占格不变时零操作）
    mutating func move(id: UUID, from old: CGRect, to new: CGRect) {
        let a = Self.spanCells(for: old, limit: Self.maxCellsPerStroke)
        let b = Self.spanCells(for: new, limit: Self.maxCellsPerStroke)
        if a == b, a != nil { return }
        insert(id: id, bounds: new)
    }

    mutating func removeAll() {
        cells.removeAll()
        home.removeAll()
        overflow.removeAll()
    }

    mutating func rebuild(strokes: [(id: UUID, bounds: CGRect)]) {
        removeAll()
        cells.reserveCapacity(min(strokes.count * 2, 16384))
        for s in strokes {
            insert(id: s.id, bounds: s.bounds)
        }
    }

    /// 矩形相交的候选 id；nil = 范围过大，调用方回退全量扫描
    func strokes(in rect: CGRect) -> Set<UUID>? {
        guard let covered = Self.spanCells(for: rect, limit: Self.maxCellsPerQuery) else {
            return nil
        }
        var out = overflow
        for c in covered {
            if let ids = cells[c] {
                out.formUnion(ids)
            }
        }
        return out
    }

    /// 点邻域候选；nil = 回退全量扫描
    func strokes(near point: CGPoint, radius: CGFloat) -> Set<UUID>? {
        guard radius.isFinite, radius >= 0 else { return nil }
        return strokes(in: CGRect(
            x: point.x - radius, y: point.y - radius,
            width: radius * 2, height: radius * 2
        ))
    }

    // MARK: - 内部

    /// 矩形覆盖的格子；格数超限返回 nil（调用方决定 overflow/回退）。
    /// 非法矩形（null/NaN/无限）返回空集：与 CGRect.intersects 的行为一致
    /// （非法矩形 intersect 恒为 false，暴力扫描同样跳过）。
    static func spanCells(for rect: CGRect, limit: Int) -> Set<CellID>? {
        guard !rect.isNull, rect.width.isFinite, rect.height.isFinite,
              rect.width >= 0, rect.height >= 0
        else { return [] }
        let x0 = Int(floor(rect.minX / cellSize))
        let x1 = Int(floor(rect.maxX / cellSize))
        let y0 = Int(floor(rect.minY / cellSize))
        let y1 = Int(floor(rect.maxY / cellSize))
        let nx = x1 - x0 + 1
        let ny = y1 - y0 + 1
        guard nx > 0, ny > 0, nx <= limit, ny <= limit, nx * ny <= limit else { return nil }
        var out = Set<CellID>()
        out.reserveCapacity(nx * ny)
        for x in x0...x1 {
            for y in y0...y1 {
                out.insert(CellID(x: x, y: y))
            }
        }
        return out
    }
}
