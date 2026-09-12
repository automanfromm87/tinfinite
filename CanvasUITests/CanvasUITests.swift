// CanvasUITests.swift
// 手势回归（真触摸路径）：导航开闭、拖拽平移、双击/双指缩放、落笔画线、节点增删。
// 依赖 DEBUG 读数（cameraReadout/contentReadout）与 accessibilityIdentifier 锚点。

import XCTest

final class CanvasUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: -  helpers

    /// 新建一张画布并进入详情（每测隔离），返回详情根
    @discardableResult
    func openFreshCanvas() -> XCUIElement {
        let newDoc = app.buttons["新建画布"]
        XCTAssertTrue(newDoc.waitForExistence(timeout: 10), "missing new-doc button")
        newDoc.tap()
        let detail = app.descendants(matching: .any)["infiniteCanvas"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "detail did not push")
        return detail
    }

    /// 读 DEBUG 文本读数（SwiftUI Text -> label 即文本）
    func readout(_ id: String) -> String {
        let el = app.descendants(matching: .any)[id]
        XCTAssertTrue(el.waitForExistence(timeout: 5), "missing readout \(id)")
        return el.label
    }

    func expandToolbar() {
        let fab = app.buttons["fabToggle"]
        XCTAssertTrue(fab.waitForExistence(timeout: 5))
        fab.tap()
        sleep(1) // 等面板弹簧动画收敛，否则后续点按可能打在飞行中的按钮上
    }

    func collapseToolbar() {
        app.buttons["fabToggle"].tap()
        sleep(1)
    }

    /// 平台对照：系统 Slider 拖拽（验证合成触摸流本身可用）
    func testSliderDragChangesValue() {
        openFreshCanvas()
        expandToolbar()
        let pen = app.buttons["paintbrush.pointed.fill"]
        XCTAssertTrue(pen.waitForExistence(timeout: 5))
        pen.tap()
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let before = app.descendants(matching: .any)["widthValue"].label
        slider.adjust(toNormalizedSliderPosition: 0.9)
        sleep(1)
        let after = app.descendants(matching: .any)["widthValue"].label
        XCTAssertNotEqual(before, after, "slider drag had no effect")
    }

    // MARK: - 导航

    func testBackToList() {
        openFreshCanvas()
        let back = app.buttons["返回列表"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let row = app.buttons["documentRow"]
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 5), "did not pop to list")
    }

    // MARK: - 相机手势

    func testPanCanvasChangesCamera() {
        let detail = openFreshCanvas()
        let before = readout("cameraReadout")
        detail.swipeUp()
        sleep(2) // 惯性收敛 + 同步节流
        XCTAssertNotEqual(readout("cameraReadout"), before, "pan did not move camera")
    }

    func testDoubleTapZooms() {
        let detail = openFreshCanvas()
        let before = readout("cameraReadout")
        detail.doubleTap()
        sleep(2)
        XCTAssertNotEqual(readout("cameraReadout"), before, "double-tap did not zoom")
    }

    func testPinchZoomChangesScale() {
        let detail = openFreshCanvas()
        let before = readout("cameraReadout")
        detail.pinch(withScale: 2, velocity: 1)
        sleep(2)
        XCTAssertNotEqual(readout("cameraReadout"), before, "pinch did not zoom")
    }

    // MARK: - 相机持久化

    /// 视角存档全链路：返回列表重进（内存/ disappear 路径）视角一致；
    /// 按 Home（800ms 防抖窗口内，测后台 flush）-> 杀进程 -> 重进（磁盘路径）视角一致。
    /// 依赖：测试按字母序串行，本测新建的文档是最新首位（-CanvasOpenFirst 打开它）。
    func testCameraPersistsAcrossRelaunch() {
        let detail = openFreshCanvas()
        detail.doubleTap() // 独特视角：缩放 + 中心都变
        sleep(2) // 手势收敛 + 读数同步
        let zoomed = readout("cameraReadout")

        // 返回列表再重进：disappear 立存 + 打开恢复
        let back = app.buttons["返回列表"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let row = app.buttons["documentRow"]
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 5), "did not pop to list")
        row.firstMatch.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "detail did not reopen")
        sleep(1)
        XCTAssertEqual(readout("cameraReadout"), zoomed, "camera not restored on reopen")

        // 按 Home（防抖窗口内）-> 杀进程 -> 重进：后台 flush + 磁盘往返。
        // 小慢拖拽：无惯性，触摸结束即终态（读数稳定）；读完立即 Home，
        // 落在 800ms 防抖窗内，逼后台 flush 走 flushAutosave + 排干路径。
        // 即使模拟器慢导致 Home 落在窗外，测试依然通过（只是不够锋利）。
        let start = detail.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4))
        let end = detail.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: end)
        // 等读数稳定（两次一致即终态），耗时 < 800ms，仍在防抖窗内按 Home
        var panned = readout("cameraReadout")
        for _ in 0..<3 {
            usleep(200_000)
            let now = readout("cameraReadout")
            if now == panned { break }
            panned = now
        }
        XCTAssertNotEqual(panned, zoomed, "pan did not move camera")
        XCUIDevice.shared.press(.home)
        sleep(3) // 后台任务落盘
        app.terminate()
        app.launchArguments = ["-CanvasOpenFirst"]
        app.launch()
        XCTAssertTrue(detail.waitForExistence(timeout: 15), "detail did not reopen after relaunch")
        sleep(1)
        XCTAssertEqual(readout("cameraReadout"), panned, "camera not persisted across relaunch")
    }

    // MARK: - 绘画

    /// 落笔 -> 笔画计数 1、垃圾桶可用；撤销 -> 计数 0
    func testDrawStrokeAndUndo() {
        let detail = openFreshCanvas()
        expandToolbar()
        let pen = app.buttons["paintbrush.pointed.fill"]
        XCTAssertTrue(pen.waitForExistence(timeout: 5))
        pen.tap()
        // 确认进入绘画模式（读数含 mode，点偏立即失败而非误测）
        let content = app.descendants(matching: .any)["contentReadout"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label CONTAINS 'draw'"), evaluatedWith: content)
        waitForExpectations(timeout: 5)
        // 收起面板再落笔：面板覆盖右半屏，拖拽起点会打在面板上
        collapseToolbar()
        let start = detail.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.35))
        let end = detail.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45))
        start.press(forDuration: 0, thenDragTo: end)

        expectation(for: NSPredicate(format: "label CONTAINS 'strokes 1'"), evaluatedWith: content)
        waitForExpectations(timeout: 5)
        expandToolbar()
        XCTAssertTrue(app.buttons["trash"].isEnabled, "trash should enable after drawing")

        app.buttons["arrow.uturn.backward"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'strokes 0'"), evaluatedWith: content)
        waitForExpectations(timeout: 5)
    }

    // MARK: - 内容节点

    /// 加矩形节点 -> 出现；删除选中 -> 消失
    func testAddShapeNodeAndDelete() {
        openFreshCanvas()
        expandToolbar()
        let rect = app.buttons["square.fill"]
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        rect.tap()
        let node = app.descendants(matching: .any)["contentNode"]
        XCTAssertTrue(node.firstMatch.waitForExistence(timeout: 5), "node did not appear")
        let delete = app.buttons["删除节点"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "node selection row missing")
        delete.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: node.firstMatch)
        waitForExpectations(timeout: 5)
    }
}
