import AppKit
import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - Dock 图标策略
// ============================================================

/// 关掉主窗口后应用要退成菜单栏应用：Dock 图标与 ⌘-Tab 条目一起消失。
///
/// 分两层测：
/// - `DockIconPolicy`：纯决策 —— 什么算「窗口还活着」、此刻该不该留在 Dock；
/// - `DockIconController`：接线 —— 注入假的窗口事实与策略出口，
///   核对它真的把结论交给了 `setActivationPolicy`。
@MainActor
final class DockIconPolicyTests: XCTestCase {

    private func facts(canBecomeMain: Bool = true,
                       hasContent: Bool = true,
                       isVisible: Bool = true,
                       isMiniaturized: Bool = false) -> DockIconPolicy.WindowFacts {
        DockIconPolicy.WindowFacts(canBecomeMain: canBecomeMain, hasContent: hasContent,
                                   isVisible: isVisible, isMiniaturized: isMiniaturized)
    }

    // MARK: - 什么时候留在 Dock

    /// 本次需求的正面用例：主窗口关掉、菜单栏还开着 → 只留菜单栏。
    func testLeavesDockWhenLastWindowClosesInMenuBarMode() {
        XCTAssertEqual(DockIconPolicy.activationPolicy(hasOpenWindow: false, menuBarEnabled: true),
                       .accessory)
    }

    /// 菜单栏模式没开时 Dock 图标是唯一入口：窗口关了也得留着，
    /// 否则应用彻底够不着（进程还活着，采集还在跑）。
    func testStaysInDockWithoutWindowWhenMenuBarModeIsOff() {
        XCTAssertEqual(DockIconPolicy.activationPolicy(hasOpenWindow: false, menuBarEnabled: false),
                       .regular)
    }

    func testStaysInDockWhileWindowIsOpen() {
        XCTAssertEqual(DockIconPolicy.activationPolicy(hasOpenWindow: true, menuBarEnabled: true),
                       .regular)
        XCTAssertEqual(DockIconPolicy.activationPolicy(hasOpenWindow: true, menuBarEnabled: false),
                       .regular)
    }

    // MARK: - 什么算「窗口还活着」

    func testVisibleMainWindowCountsAsOpen() {
        XCTAssertTrue(DockIconPolicy.hasOpenWindow(in: [facts()]))
    }

    /// 最小化只是把窗口收进 Dock，点一下还要能回来 —— 不算关窗。
    func testMinimizedWindowCountsAsOpen() {
        XCTAssertTrue(DockIconPolicy.hasOpenWindow(in: [facts(isVisible: false, isMiniaturized: true)]))
    }

    func testClosedWindowDoesNotCount() {
        XCTAssertFalse(DockIconPolicy.hasOpenWindow(in: [facts(isVisible: false, isMiniaturized: false)]))
    }

    /// 菜单栏面板、状态栏窗口、sheet 都成不了主窗口：它们开着不算「有窗口」，
    /// 否则点一下菜单栏图标 Dock 图标就会蹦出来。
    func testPanelDoesNotCount() {
        XCTAssertFalse(DockIconPolicy.hasOpenWindow(in: [facts(canBecomeMain: false)]))
    }

    func testWindowWithoutContentDoesNotCount() {
        XCTAssertFalse(DockIconPolicy.hasOpenWindow(in: [facts(hasContent: false)]))
    }

    // MARK: - 接线

    private func controller(facts: [DockIconPolicy.WindowFacts],
                            menuBarEnabled: Bool,
                            log: @escaping (NSApplication.ActivationPolicy) -> Void) -> DockIconController {
        DockIconController(windowFacts: { facts },
                           isMenuBarEnabled: { menuBarEnabled },
                           applyPolicy: { log($0) })
    }

    /// 窗口关了 → 真的调用了 `setActivationPolicy(.accessory)`。
    func testSyncDropsToAccessoryAfterWindowCloses() {
        var applied: [NSApplication.ActivationPolicy] = []
        controller(facts: [], menuBarEnabled: true) { applied.append($0) }.sync()

        XCTAssertEqual(applied, [.accessory])
    }

    /// 窗口回来 → 升回 `.regular`。
    func testSyncReturnsToRegularWhenWindowIsBack() {
        var applied: [NSApplication.ActivationPolicy] = []
        controller(facts: [facts()], menuBarEnabled: true) { applied.append($0) }.sync()

        XCTAssertEqual(applied, [.regular])
    }

    /// 结论没变时不重复打扰 AppKit —— 窗口每次成为 key 都会走一遍 sync。
    func testRepeatedSyncAppliesPolicyOnce() {
        var applied: [NSApplication.ActivationPolicy] = []
        let controller = controller(facts: [], menuBarEnabled: true) { applied.append($0) }

        controller.sync()
        controller.sync()

        XCTAssertEqual(applied, [.accessory])
    }

    /// 菜单栏面板里点「打开主窗口」：不等窗口出现，Dock 图标立刻回来。
    func testRestoreDockIconAppliesRegularImmediately() {
        var applied: [NSApplication.ActivationPolicy] = []
        let controller = controller(facts: [], menuBarEnabled: true) { applied.append($0) }

        controller.sync()                 // 窗口关着 → accessory
        controller.restoreDockIcon()      // 点「打开主窗口」→ regular

        XCTAssertEqual(applied, [.accessory, .regular])
    }
}
