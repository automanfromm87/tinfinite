// PaperTheme.swift
// 纸张主题 + 网格样式（纯逻辑，可单测；UIColor 映射只在有 UIKit 时编译）

import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 纸张底色：跟随系统 / 白纸 / 黑纸
nonisolated enum PaperTheme: String, CaseIterable, Sendable {
    case system
    case white
    case black

    /// UserDefaults 持久化键（全局偏好，不跟文档走）
    static let defaultsKey = "canvas.paperTheme"

    /// 是否深底（system 由调用方按 traitCollection 解析后传入）
    var isDark: Bool { self == .black }
}

/// 网格样式：线网格 / 点阵 / 关闭
nonisolated enum GridStyle: String, CaseIterable, Sendable {
    case lines
    case dots
    case off

    /// UserDefaults 持久化键（全局偏好）
    static let defaultsKey = "canvas.gridStyle"

    var showsGrid: Bool { self != .off }
}

#if canImport(UIKit)
extension PaperTheme {
    /// 纸张底色；system 跟随当前 traitCollection
    func backgroundColor(for traits: UITraitCollection) -> UIColor {
        switch self {
        case .system:
            return .systemBackground
        case .white:
            return .white
        case .black:
            return .black
        }
    }

    /// 给定 trait 下是否深底（网格线色适配用）
    func isDark(for traits: UITraitCollection) -> Bool {
        switch self {
        case .system:
            return traits.userInterfaceStyle == .dark
        case .white:
            return false
        case .black:
            return true
        }
    }
}
#endif
