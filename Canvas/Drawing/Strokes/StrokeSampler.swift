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
    /// 点按判据（屏幕点）：落笔到抬笔位移不足此值视为点按，spine 坍缩为落笔单点。
    /// 防止抬笔前相机挪动（惯性/双击缩放）把静止手指映射成世界直线。
    var tapSlop: CGFloat = 10
    /// 屏幕 -> 世界转换（DrawingController 注入，读当前 camera）
    var worldConverter: (CGPoint) -> CGPoint = { $0 }
    /// 当前笔样式（决定 spine 宽度）
    var style: StrokeStyle = .defaultPen

    private var filter = OneEuroFilter2D()
    private var lastAcceptedScreen: CGPoint?
    private var lastPressure: CGFloat = 0.5
    private var lastAltitude: CGFloat = .pi / 2
    private var downScreen: CGPoint?
    private var maxScreenTravel: CGFloat = 0
    private var predictedScreen: [CGPoint] = []

    /// 原始输入点（世界，未滤波，用于 Stroke 存档/重建）
    private(set) var rawPoints: [StrokePoint] = []
    /// 确认 spine（世界，已滤波+重采样，用于几何）
    private(set) var spine: [SpinePoint] = []

    /// 展示用 spine = 确认 spine + 预测尾巴（预测点用最后压力/倾斜算笔尖）。
    /// 预测点每事件刷新，只影响 live 预览，不进存档。
    ///
    /// 点按窗口内（位移 < tapSlop）只压住**预测尾巴**，不压真实 spine：
    /// 预测点是外推的，相机若在点按中途移动会被映射到很远的世界点，画出假线；
    /// 而真实 spine 必须立刻可见——否则从落笔到走完 tapSlop(10pt) 的这段时间
    /// （实测 42~129ms，慢写时更久）墨迹会冻成一个点，然后整段「弹」出来，
    /// 这正是「书写很卡」最直观的来源。
    var displaySpine: [SpinePoint] {
        let tail = predictedTail
        return tail.isEmpty ? spine : spine + tail
    }

    /// 只取预测尾巴（增量网格构建器用：确认段只追加，尾巴每事件整段替换）
    var predictedTail: [SpinePoint] {
        if isTap || predictedScreen.isEmpty { return [] }
        let nib = style.nib(pressure: lastPressure, altitude: lastAltitude)
        return predictedScreen.map {
            SpinePoint(center: worldConverter($0), width: nib.width, alpha: nib.alpha)
        }
    }

    // MARK: - 输入

    /// 手指在屏幕上是否基本没动过（点按判据）
    var isTap: Bool { maxScreenTravel < tapSlop }

    mutating func begin(screen: CGPoint, pressure: CGFloat, altitude: CGFloat, azimuth: CGFloat, time: TimeInterval) {
        reset()
        lastPressure = pressure
        lastAltitude = altitude
        downScreen = screen
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
        // 点按坍缩：手指基本没动（< tapSlop）**且相机在落笔期间真的移动过**
        // -> 世界 spine 里的位移全部来自相机，不是笔迹，坍缩为落笔单点。
        //
        // 为什么要加「相机动过」这一条：无条件坍缩会把所有短于 tapSlop(10pt) 的
        // 真实笔画（CJK 的点/顿/短撇经常只有 5~9pt）静默压成一个圆点并落盘 ——
        // 那是数据丢失，不是防抖。相机静止时 worldConverter(downScreen) 与
        // spine[0].center 逐位相等（OneEuro 首样本原样返回），判据精确无歧义。
        if isTap, let first = spine.first, let down = downScreen {
            let downNow = worldConverter(down)
            let cameraDrift = hypot(downNow.x - first.center.x, downNow.y - first.center.y)
            if cameraDrift > 1e-9 {
                spine = [first]
            }
        }
        predictedScreen = []
    }

    mutating func reset() {
        filter.reset()
        lastAcceptedScreen = nil
        lastPressure = 0.5
        lastAltitude = .pi / 2
        downScreen = nil
        maxScreenTravel = 0
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
        if let down = downScreen {
            maxScreenTravel = max(maxScreenTravel, hypot(screen.x - down.x, screen.y - down.y))
        }
        let nib = style.nib(pressure: pressure, altitude: altitude)
        spine.append(SpinePoint(
            center: worldConverter(screen),
            width: nib.width, alpha: nib.alpha
        ))
    }
}
