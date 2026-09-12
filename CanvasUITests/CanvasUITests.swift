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

    /// 色轮：弹窗出现 -> 拉满明度 -> 轮上拾色 -> 关闭落入常用色
    func testColorWheelPresentsAndPicks() {
        // 干净启动（清常用色，保证断言确定）
        app.terminate()
        app.launchArguments = ["-CanvasResetRecents"]
        app.launch()
        openFreshCanvas()
        expandToolbar()
        let pen = app.buttons["paintbrush.pointed.fill"]
        XCTAssertTrue(pen.waitForExistence(timeout: 5))
        pen.tap()
        let wheelButton = app.buttons["colorWheelButton"]
        XCTAssertTrue(wheelButton.waitForExistence(timeout: 5))
        wheelButton.tap()
        let wheel = app.descendants(matching: .any)["colorWheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5), "color wheel did not present")
        // 先拉满明度（默认黑起手，v=0 时轮上任何位置都是黑）
        let valueBar = app.descendants(matching: .any)["valueBar"]
        XCTAssertTrue(valueBar.waitForExistence(timeout: 5))
        let vStart = valueBar.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let vEnd = valueBar.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        vStart.press(forDuration: 0.1, thenDragTo: vEnd)
        // 轮上沿从顶部（红）拖到右侧：拾色不断言具体值（坐标->色相映射由单测覆盖）
        let start = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        let end = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        sleep(1)
        app.buttons["完成"].tap()
        sleep(1)
        XCTAssertFalse(wheel.exists, "color wheel did not dismiss")
        // 自选彩色落入常用（黑/快捷色不记；此处必为高饱和彩色）
        let recents = app.buttons.matching(identifier: "recentSwatch")
        XCTAssertEqual(recents.count, 1, "custom color not committed to recents")
        recents.firstMatch.tap() // 应用常用色（冒烟，不断言）
        sleep(1)
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

    // MARK: - 速调条 / 撤销手势 / 纸张

    /// 收起态速调条：绘画模式可见可调，导航模式隐藏
    func testQuickWidthStrip() {
        let detail = openFreshCanvas()
        expandToolbar()
        let pen = app.buttons["paintbrush.pointed.fill"]
        XCTAssertTrue(pen.waitForExistence(timeout: 5))
        pen.tap()
        collapseToolbar()
        let quick = app.sliders["quickWidthSlider"]
        XCTAssertTrue(quick.waitForExistence(timeout: 5), "quick strip missing in draw mode")
        let value = app.descendants(matching: .any)["quickWidthValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        let before = value.label
        quick.adjust(toNormalizedSliderPosition: 0.9)
        sleep(1)
        XCTAssertNotEqual(value.label, before, "quick slider had no effect")
        // 切回导航模式：速调条消失
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        expandToolbar()
        app.buttons["hand.draw.fill"].tap()
        collapseToolbar()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: quick)
        waitForExpectations(timeout: 5)
    }

    /// 双指点按撤销：落笔一画 -> 双指点按 -> 笔画计数归零
    func testTwoFingerTapUndo() {
        let detail = openFreshCanvas()
        expandToolbar()
        let pen = app.buttons["paintbrush.pointed.fill"]
        XCTAssertTrue(pen.waitForExistence(timeout: 5))
        pen.tap()
        collapseToolbar()
        let start = detail.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.35))
        let end = detail.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45))
        start.press(forDuration: 0, thenDragTo: end)
        let content = app.descendants(matching: .any)["contentReadout"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label CONTAINS 'strokes 1'"), evaluatedWith: content)
        waitForExpectations(timeout: 5)
        sleep(2) // 落笔提交 + 速调条动画收敛后再双指点按
        // twoFingerTap 在全屏元素上算不出坐标（XCUITest 限制），用近似 1 的
        // pinch 做机械等价的两指按下-抬起（位移 ~1pt < 点按 10pt 容差，照样触发）
        detail.pinch(withScale: 1.02, velocity: 1)
        expectation(for: NSPredicate(format: "label CONTAINS 'strokes 0'"), evaluatedWith: content)
        waitForExpectations(timeout: 5)
    }

    /// 纸张/网格选项：按钮存在可点（视觉由截图验证）
    func testPaperAndGridOptions() {
        openFreshCanvas()
        expandToolbar()
        // 纸张/网格在面板底部：滚到底再点（小屏下面板滚动）
        let panel = app.scrollViews["toolPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "missing tool panel")
        panel.swipeUp()
        sleep(1)
        for id in ["paperSystem", "paperWhite", "paperBlack"] {
            let btn = app.buttons[id]
            XCTAssertTrue(btn.waitForExistence(timeout: 5), "missing \(id)")
            btn.tap()
        }
        let grid = app.segmentedControls["gridStylePicker"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "missing grid style picker")
        for label in ["线格", "点阵", "关"] {
            grid.buttons[label].tap()
            sleep(1)
        }
        // 回到默认：系统纸 + 线格（不污染后续测试截图）
        app.buttons["paperSystem"].tap()
        grid.buttons["线格"].tap()
        sleep(1)
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
