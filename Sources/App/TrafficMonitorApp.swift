import SwiftUI
import UserNotifications
import AppKit

@main
@MainActor
struct TrafficMonitorApp: App {
    @State private var collectorService = CollectorService.shared
    @State private var dashboardVM = DashboardViewModel.shared

    init() {
        // 启动即有主窗口，按常规模式起（有 Dock 图标）。之后由
        // DockIconController 在窗口生灭时升降：关掉主窗口 → 只留菜单栏。
        NSApplication.shared.setActivationPolicy(.regular)
        DockIconController.shared.start()
        // 采集与订阅都属于应用生命周期，不能挂在主窗口上 ——
        // 否则关掉窗口菜单栏就停更。
        DashboardViewModel.shared.startObserving()
        DashboardViewModel.shared.loadGroups()
        CollectorService.shared.loadAlertRules()
        Task { await CollectorService.shared.start() }
    }

    var body: some Scene {
        WindowGroup(id: MainWindowID.value) {
            MainWindowView()
                .environment(collectorService)
                .environment(dashboardVM)
                .frame(minWidth: 940, idealWidth: 1080, minHeight: 520, idealHeight: 680)
                .id(collectorService.language)   // 切换语言时重建视图树
                .onAppear {
                    if Bundle.main.bundleIdentifier != nil {
                        UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    }
                }
        }
        .windowStyle(.titleBar)
        // 默认宽度要放得下侧栏 + 六列表格，否则「合计」列会被挤出可视区、
        // 出现横向滚动条
        .defaultSize(width: 1080, height: 680)

        // 这里**不能**直接用 Bindable(collectorService).menuBarEnabled。
        //
        // MenuBarExtra 在每次场景更新时都会把当前值回写进绑定，而 @Observable
        // 的合成 setter 无条件调用 withMutation —— 即便值没变也会通知观察者。
        // App.body 读了这个属性，于是「求值 → 回写 → 失效 → 再求值」形成死循环，
        // 主线程 100% 占用、界面无响应。
        // 过滤掉同值写入，循环就断了。
        MenuBarExtra(isInserted: Binding(
            get: { collectorService.menuBarEnabled },
            set: { if $0 != collectorService.menuBarEnabled { collectorService.menuBarEnabled = $0 } }
        )) {
            MenuBarPanel()
                .environment(collectorService)
                .environment(dashboardVM)
        } label: {
            // 两个环境对象都要注入：标签既读速率（dashboardVM），也读字号（collectorService）
            MenuBarLabel()
                .environment(dashboardVM)
                .environment(collectorService)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(collectorService)
                .environment(dashboardVM)
                .id(collectorService.language)
        }
    }
}
