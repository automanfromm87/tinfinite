// StrokeSampler.swift
// 笔画采样器（屏幕空间）：原始触摸点 -> OneEuro 去抖 -> 定距重采样 -> 世界 spine。
// 屏幕空间定距保证任意缩放下采样密度体感一致（~2px 一点）；
// 世界转换走注入闭包（读当前 camera，中途相机变化也正确）。

import CoreGraphics
import Foundation

/// 笔画采样器：一次触摸序列对应一个实例（begin/append/end），用完即弃。
nonisolated struct StrokeSampler {
    /// 屏幕重采样间距（点）。小于此距离的点并入，不进 spine。
    var spacingScreen: CGFloat = 2
    /// 屏幕 -> 世界转换（DrawingController 注入，读当前 camera）
    var worldConverter: (CGPoint) -> CGPoint = { $0 }
    /// 当前笔样式（决定 spine 宽度）
    var style: StrokeStyle = .defaultPen

    private var filter = OneEuroFilter2D()
    private var lastAcceptedScreen: CGPoint?
    private var lastPressure: CGFloat = 0.5
    private var lastAltitude: CGFloat = .pi / 2
    private var predictedScreen: [CGPoint] = []

    /// 原始输入点（世界，未滤波，用于 Stroke 存档/重建）
    private(set) var rawPoints: [StrokePoint] = []
    /// 确认 spine（世界，已滤波+重采样，用于几何）
    private(set) var spine: [SpinePoint] = []

    /// 展示用 spine = 确认 spine + 预测尾巴（预测点用最后压力/倾斜算笔尖）。
    /// 预测点每事件刷新，只影响 live 预览，不进存档。
    var displaySpine: [SpinePoint] {
        guard !predictedScreen.isEmpty else { return spine }
        let nib = style.nib(pressure: lastPressure, altitude: lastAltitude)
        return spine + predictedScreen.map {
            SpinePoint(center: worldConverter($0), width: nib.width, alpha: nib.alpha)
        }
    }

    // MARK: - 输入

    mutating func begin(screen: CGPoint, pressure: CGFloat, altitude: CGFloat, azimuth: CGFloat, time: TimeInterval) {
        reset()
        lastPressure = pressure
        lastAltitude = altitude
        let filtered = filter.filter(screen, at: time)
        pushRaw(screen: screen, pressure: pressure, altitude: altitude, azimuth: azimuth, time: time)
        accept(screen: filtered, pressure: pressure, altitude: altitude)
    }

    mutating func append(screen: CGPoint, pressure: CGFloat, altitude: CGFloat, azimuth: CGFloat, time: TimeInterval) {
        lastPressure = pressure
        lastAltitude = altitude
        pushRaw(screen: screen, pressure: pressure, altitude: altitude, azimuth: azimuth, time: time)
        let filtered = filter.filter(screen, at: time)
        guard let last = lastAcceptedScreen else {
            accept(screen: filtered, pressure: pressure, altitude: altitude)
            return
        }
        let dx = filtered.x - last.x
        let dy = filtered.y - last.y
        if dx * dx + dy * dy >= spacingScreen * spacingScreen {
            accept(screen: filtered, pressure: pressure, altitude: altitude)
        }
    }

    /// 刷新预测尾巴（每事件调用；空数组 = 清除）
    mutating func setPredicted(_ screens: [CGPoint]) {
        predictedScreen = screens
    }

    /// 结束：终点强制接受（保证落笔 exactly 到抬笔位置），清预测。
    mutating func end(screen: CGPoint, pressure: CGFloat, altitude: CGFloat, azimuth: CGFloat, time: TimeInterval) {
        lastPressure = pressure
        lastAltitude = altitude
        pushRaw(screen: screen, pressure: pressure, altitude: altitude, azimuth: azimuth, time: time)
        // 终点用原始位置（不滤波），落笔精确
        if let last = lastAcceptedScreen {
            let dx = screen.x - last.x
            let dy = screen.y - last.y
            if dx * dx + dy * dy >= (spacingScreen * 0.25) * (spacingScreen * 0.25) || spine.isEmpty {
                accept(screen: screen, pressure: pressure, altitude: altitude)
            }
        } else {
            accept(screen: screen, pressure: pressure, altitude: altitude)
        }
        predictedScreen = []
    }

    mutating func reset() {
        filter.reset()
        lastAcceptedScreen = nil
        lastPressure = 0.5
        lastAltitude = .pi / 2
        predictedScreen = []
        rawPoints = []
        spine = []
    }

    // MARK: - 内部

    private mutating func pushRaw(screen: CGPoint, pressure: CGFloat, altitude: CGFloat, azimuth: CGFloat, time: TimeInterval) {
        rawPoints.append(StrokePoint(
            position: worldConverter(screen),
            pressure: pressure, altitude: altitude, azimuth: azimuth, timestamp: time
        ))
    }

    private mutating func accept(screen: CGPoint, pressure: CGFloat, altitude: CGFloat) {
        lastAcceptedScreen = screen
        let nib = style.nib(pressure: pressure, altitude: altitude)
        spine.append(SpinePoint(
            center: worldConverter(screen),
            width: nib.width, alpha: nib.alpha
        ))
    }
}
