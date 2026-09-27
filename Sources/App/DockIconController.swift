import AppKit

// MARK: - 策略

/// 应用该不该在 Dock 里占一个图标。
///
/// 没有窗口时应用的「身份」由 activation policy 决定：`.regular` 有 Dock 图标
/// 和 ⌘-Tab 条目，`.accessory` 两者都没有 —— 菜单栏图标两者都在。
/// 所以主窗口一关就降为 `.accessory`，只留菜单栏；窗口再出现时升回 `.regular`。
///
/// 唯一的例外是菜单栏模式没开：此时菜单栏图标也不在，Dock 图标是仅剩的入口，
/// 收起来应用就完全够不着了（进程还活着、采集还在跑）。
enum DockIconPolicy {
    /// 判定要用到的窗口事实。
    ///
    /// 不直接拿 `NSWindow` 做判断：判定本身与 AppKit 状态无关，凑齐这四个事实
    /// 就能对着真值表测；「已最小化」这类状态在测试里也没法凭空造出来。
    struct WindowFacts: Equatable {
        var canBecomeMain: Bool
        var hasContent: Bool
        var isVisible: Bool
        var isMiniaturized: Bool

        init(canBecomeMain: Bool, hasContent: Bool, isVisible: Bool, isMiniaturized: Bool) {
            self.canBecomeMain = canBecomeMain
            self.hasContent = hasContent
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
        }

        init(_ window: NSWindow) {
            self.init(canBecomeMain: window.canBecomeMain,
                      hasContent: window.contentView != nil,
                      isVisible: window.isVisible,
                      isMiniaturized: window.isMiniaturized)
        }
    }

    /// 有没有「还活着」的普通窗口。
    ///
    /// 最小化也算：窗口只是收进了 Dock，点一下还要能回来，不算关窗。
    /// 菜单栏面板、状态栏窗口、sheet 的 `canBecomeMain` 都是 false，
    /// 天然被排除 —— 否则点一下菜单栏图标 Dock 图标就会蹦出来。
    static func hasOpenWindow(in windows: [WindowFacts]) -> Bool {
        windows.contains {
            $0.canBecomeMain && $0.hasContent && ($0.isVisible || $0.isMiniaturized)
        }
    }

    static func shouldStayInDock(hasOpenWindow: Bool, menuBarEnabled: Bool) -> Bool {
        hasOpenWindow || !menuBarEnabled
    }

    static func activationPolicy(hasOpenWindow: Bool,
                                 menuBarEnabled: Bool) -> NSApplication.ActivationPolicy {
        shouldStayInDock(hasOpenWindow: hasOpenWindow, menuBarEnabled: menuBarEnabled)
            ? .regular : .accessory
    }
}

// MARK: - 控制器

/// 监听窗口生灭，把激活策略同步到 `DockIconPolicy` 的结论。
///
/// 与 `CollectorService.syncVisibility` 同样的前提：判定要**延后一个 runloop** ——
/// `willClose` 触发时窗口还是 `isVisible`，当场判定会得出「窗口还开着」的错误结论。
///
/// 三个依赖都从初始化器注入，测试里不用真的开关窗口就能核对决策。
@MainActor
final class DockIconController {
    static let shared = DockIconController()

    private let windowFacts: @MainActor () -> [DockIconPolicy.WindowFacts]
    private let isMenuBarEnabled: @MainActor () -> Bool
    private let applyPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void

    private var observers: [NSObjectProtocol] = []
    private var lastApplied: NSApplication.ActivationPolicy?

    init(windowFacts: @escaping @MainActor () -> [DockIconPolicy.WindowFacts] = {
             NSApp.windows.map { DockIconPolicy.WindowFacts($0) }
         },
         isMenuBarEnabled: @escaping @MainActor () -> Bool = {
             CollectorService.shared.menuBarEnabled
         },
         applyPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = {
             _ = NSApplication.shared.setActivationPolicy($0)
         }) {
        self.windowFacts = windowFacts
        self.isMenuBarEnabled = isMenuBarEnabled
        self.applyPolicy = applyPolicy
    }

    /// 由 `App.init` 调用：开始听窗口的生灭。
    ///
    /// 启动时的初始策略由 App 层写死为 `.regular`（主窗口马上就出现），
    /// 这里不按「此刻还没有窗口」去降级 —— 那会让 Dock 图标先掉再回来。
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            // 关窗：等关完再判定
            NSWindow.willCloseNotification,
            // 窗口出现：新建、从菜单栏叫回、从 Dock 恢复，都会先成为 key
            NSWindow.didBecomeKeyNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.sync() }
                }
            }
        }
    }

    /// 菜单栏面板里点「打开主窗口」时先调用：Dock 图标立刻回来，
    /// 不用等窗口出现后的通知转一圈。
    func restoreDockIcon() {
        apply(.regular)
    }

    /// 按当前的窗口与菜单栏状态重算策略。
    func sync() {
        let hasOpenWindow = DockIconPolicy.hasOpenWindow(in: windowFacts())
        apply(DockIconPolicy.activationPolicy(hasOpenWindow: hasOpenWindow,
                                              menuBarEnabled: isMenuBarEnabled()))
    }

    /// 结论没变就不打扰 AppKit。
    private func apply(_ policy: NSApplication.ActivationPolicy) {
        guard policy != lastApplied else { return }
        lastApplied = policy
        applyPolicy(policy)
    }
}
