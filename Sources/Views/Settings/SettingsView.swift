import SwiftUI

/// 完整的设置窗口 (F5)
@MainActor
struct SettingsView: View {
    @Environment(CollectorService.self) private var collectorService
    @Environment(DashboardViewModel.self) private var dashboardVM

    @State private var selectedInterval: TimeInterval = Preferences.interval
    @State private var selectedSaveInterval: TimeInterval = Preferences.saveInterval
    @State private var dbSize: String = L("settings.calculating")
    @State private var retentionDays: Double = Preferences.retentionDays
    @State private var retentionEnabled: Bool = Preferences.retentionEnabled
    @State private var excludedProcesses: String = Preferences.excludedProcessesText
    // 注意：这些 @State 的初值表达式在**每次**构造 SettingsView 时都会执行，
    // 而 SwiftUI 每次求值 App.body 都会重新构造一遍 Scene 的内容视图。
    // 所以初值必须廉价 —— LaunchAtLogin 要走 SMAppService 的 XPC，
    // 放在这里会让主线程在场景更新时反复阻塞。真实状态在 .task 里读。
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var launchAtLoginHint: String?

    var body: some View {
        TabView {
            // 采集设置
            Form {
                Section {
                    LabeledContent(L("settings.interval")) {
                        Picker("", selection: $selectedInterval) {
                            Text(L("settings.seconds", 1)).tag(1.0)
                            Text(L("settings.seconds", 2)).tag(2.0)
                            Text(L("settings.seconds", 5)).tag(5.0)
                            Text(L("settings.seconds", 10)).tag(10.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        .onChange(of: selectedInterval) { _, newValue in
                            collectorService.interval = newValue
                            if collectorService.status == .running {
                                Task { await collectorService.restart() }
                            }
                        }
                    }

                    LabeledContent(L("settings.saveInterval")) {
                        Picker("", selection: $selectedSaveInterval) {
                            Text(L("settings.seconds", 10)).tag(10.0)
                            Text(L("settings.seconds", 15)).tag(15.0)
                            Text(L("settings.seconds", 30)).tag(30.0)
                            Text(L("settings.seconds", 60)).tag(60.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        .onChange(of: selectedSaveInterval) { _, newValue in
                            collectorService.saveInterval = newValue
                            if collectorService.status == .running {
                                Task { await collectorService.restart() }
                            }
                        }
                    }

                    LabeledContent(L("settings.language")) {
                        Picker("", selection: Bindable(collectorService).language) {
                            ForEach(AppLanguage.allCases) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                        .labelsHidden().frame(width: 220)
                    }

                    LabeledContent(L("settings.menuBar")) {
                        Toggle("", isOn: Bindable(collectorService).menuBarEnabled)
                            .help(L("settings.menuBar.help"))
                    }

                    LabeledContent(L("settings.menuBarFontSize")) {
                        Picker("", selection: Bindable(collectorService).menuBarFontSize) {
                            ForEach([7.0, 8.0, 9.0, 10.0, 11.0], id: \.self) { size in
                                Text("\(Int(size))").tag(size)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                        .disabled(!collectorService.menuBarEnabled)
                        .help(L("settings.menuBarFontSize.help"))
                    }

                    LabeledContent(L("settings.sparkline")) {
                        Toggle("", isOn: Bindable(collectorService).sparklineEnabled)
                            .help(L("settings.sparkline.help"))
                    }

                    LabeledContent(L("settings.launchAtLogin")) {
                        Toggle("", isOn: $launchAtLogin)
                            .disabled(!LaunchAtLogin.isSupported)
                            .onChange(of: launchAtLogin) { _, want in
                                launchAtLoginError = LaunchAtLogin.setEnabled(want)
                                // 注册失败就把开关拨回去，别让 UI 和实际状态不一致
                                if launchAtLoginError != nil { refreshLaunchAtLoginState() }
                            }
                    }

                    if let hint = launchAtLoginError ?? launchAtLoginHint {
                        HStack(spacing: 6) {
                            Text(hint).font(.caption).foregroundStyle(.secondary)
                            if LaunchAtLogin.requiresApproval {
                                Button(L("settings.openLoginItems")) { LaunchAtLogin.openLoginItemsSettings() }
                                    .buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                } header: {
                    Text(L("settings.section.collection"))
                }

                Section {
                    LabeledContent(L("settings.dbSize")) {
                        Text(dbSize)
                    }
                    .onAppear { updateDBSize() }

                    LabeledContent(L("settings.autoCleanup")) {
                        Toggle("", isOn: $retentionEnabled)
                            .onChange(of: retentionEnabled) { _, on in
                                Preferences.retentionEnabled = on
                            }
                            .help(L("settings.autoCleanup.help"))
                    }

                    if retentionEnabled {
                        LabeledContent(L("settings.retentionDays")) {
                            HStack {
                                Text(L("settings.days", Int(retentionDays)))
                                    .monospacedDigit()
                                Stepper("", value: $retentionDays, in: 7...90, step: 1)
                                    .labelsHidden()
                                    .onChange(of: retentionDays) { _, days in
                                        Preferences.retentionDays = days
                                    }
                            }
                        }

                        Button(L("settings.cleanNow")) {
                            deleteOldData()
                            updateDBSize()
                        }
                    }

                } header: {
                    Text(L("settings.section.data"))
                }

                Section {
                    LabeledContent(L("settings.excluded")) {
                        TextField(L("settings.excluded.placeholder"), text: $excludedProcesses)
                            .onSubmit { collectorService.applyExcludedProcesses(excludedProcesses) }
                    }
                    Text(L("settings.excluded.hint"))
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text(L("settings.section.advanced"))
                }
            }
            .tabItem { Label(L("settings.tab.general"), systemImage: "gear") }
            .formStyle(.grouped)
            .padding()

            // 分组管理
            groupTabView
                .tabItem { Label(L("settings.tab.groups"), systemImage: "square.grid.2x2") }
                .formStyle(.grouped)
                .padding()

            // 告警设置
            alertTabView
                .tabItem { Label(L("settings.tab.alerts"), systemImage: "bell.badge") }
                .formStyle(.grouped)
                .padding()

            // 调试日志
            logTabView
                .tabItem { Label(L("settings.tab.logs"), systemImage: "text.alignleft") }
                .padding()

            Form {
                Section {
                    LabeledContent(L("about.version"), value: Constants.appVersion)
                    LabeledContent(L("about.stack"), value: "SwiftUI + GRDB + NetworkStatistics")
                    LabeledContent(L("about.minSystem"), value: "macOS 14.0 (Sonoma)")
                } header: {
                    Text(L("about.section.about"))
                }

                Section {
                    LabeledContent(L("about.collection"), value: L("about.collection.value"))
                    LabeledContent(L("about.privilege"), value: L("about.privilege.value"))
                    LabeledContent(L("about.database"), value: "SQLite (WAL mode, GRDB)")
                } header: {
                    Text(L("about.section.details"))
                }
            }
            .tabItem { Label(L("settings.tab.about"), systemImage: "info.circle") }
            .formStyle(.grouped)
            .padding()
        }
        .frame(width: 500, height: 400)
        .task { refreshLaunchAtLoginState() }
    }

    private func refreshLaunchAtLoginState() {
        launchAtLogin = LaunchAtLogin.isEnabled
        launchAtLoginHint = LaunchAtLogin.statusDescription
    }

    // MARK: - Alert Tab

    @State private var alertRules: [AlertRule] = []
    @State private var newAlertProcess: String = ""
    @State private var newAlertBytes: String = ""
    @State private var newAlertRate: String = ""

    private var alertTabView: some View {
        Form {
            Section {
                if alertRules.isEmpty {
                    HStack { Spacer(); Text(L("alerts.none")).foregroundColor(.secondary); Spacer() }
                } else {
                    ForEach($alertRules) { $rule in
                        HStack {
                            Toggle("", isOn: $rule.enabled).labelsHidden().frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.displayName).lineLimit(1)
                                Text(rule.processKey ?? L("alerts.global"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .contextMenu { Button(L("common.delete"), role: .destructive) { alertRules.removeAll { $0.id == rule.id }; saveAlertRules() } }
                    }
                }
            } header: {
                Text(L("alerts.existing"))
            }

            Section {
                TextField(L("alerts.processPlaceholder"), text: $newAlertProcess)
                TextField(L("alerts.bytesPlaceholder"), text: $newAlertBytes)
                TextField(L("alerts.ratePlaceholder"), text: $newAlertRate)
                Button(L("alerts.add")) {
                    guard !newAlertBytes.isEmpty || !newAlertRate.isEmpty else { return }
                    let key = newAlertProcess.trimmingCharacters(in: .whitespaces)
                    let name = key.isEmpty ? L("alerts.global") : key
                    let rule = AlertRule(
                        processKey: key.isEmpty ? nil : key,
                        displayName: L("alerts.name", name),
                        thresholdBytes: Int64(newAlertBytes),
                        thresholdRate: Double(newAlertRate)
                    )
                    alertRules.append(rule)
                    saveAlertRules()
                    newAlertProcess = ""
                    newAlertBytes = ""
                    newAlertRate = ""
                }
                .disabled(newAlertBytes.isEmpty && newAlertRate.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            } header: {
                Text(L("alerts.new"))
            }
        }
        .onAppear { alertRules = collectorService.alertRules }
    }

    private func saveAlertRules() {
        collectorService.applyAlertRules(alertRules)
        AlertStore.shared.save(alertRules)
    }

    // MARK: - Group Tab

    @State private var processGroups: [ProcessGroup] = []
    @State private var newGroupName: String = ""
    @State private var newGroupKeys: String = ""

    private var groupTabView: some View {
        Form {
            Section {
                if processGroups.isEmpty {
                    HStack { Spacer(); Text(L("groups.none")).foregroundColor(.secondary); Spacer() }
                } else {
                    ForEach(processGroups) { group in
                        HStack {
                            Image(systemName: "folder")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name).lineLimit(1)
                                Text(group.processKeys.sorted().joined(separator: ", "))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(group.processKeys.count)").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }
                        .contextMenu { Button(L("common.delete"), role: .destructive) { processGroups.removeAll { $0.id == group.id }; saveGroups() } }
                    }
                }
            } header: {
                Text(L("groups.existing"))
            }

            Section {
                TextField(L("groups.namePlaceholder"), text: $newGroupName)
                TextField(L("groups.keysPlaceholder"), text: $newGroupKeys)
                Button(L("groups.create")) {
                    let name = newGroupName.trimmingCharacters(in: .whitespaces)
                    let keys = Set(newGroupKeys.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                    guard !name.isEmpty, !keys.isEmpty else { return }
                    processGroups.append(ProcessGroup(name: name, processKeys: keys))
                    saveGroups()
                    newGroupName = ""
                    newGroupKeys = ""
                }
                .disabled(newGroupName.isEmpty || newGroupKeys.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            } header: {
                Text(L("groups.new"))
            }
        }
        .onAppear { processGroups = dashboardVM.processGroups }
    }

    private func saveGroups() {
        dashboardVM.processGroups = processGroups
        GroupStore.shared.save(processGroups)
    }

    // MARK: - Log Tab

    @State private var logEntries: [LogEntry] = []
    @State private var logFilter: LogEntry.Level? = nil

    private var logTabView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(L("logs.filter"), selection: $logFilter) {
                    Text(L("logs.all")).tag(nil as LogEntry.Level?)
                    ForEach(LogEntry.Level.allCases, id: \.self) { lvl in
                        Text(lvl.rawValue).tag(lvl as LogEntry.Level?)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Button(L("logs.refresh")) { Task { await loadLogs() } }

                Spacer()

                Text(L("logs.recent")).font(.caption).foregroundColor(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredLogs) { entry in
                        HStack(spacing: 4) {
                            Text(formatLogTime(entry.timestamp))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(entry.level.rawValue)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(logLevelColor(entry.level))
                            Text("[\(entry.tag)]")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(entry.message)
                                .font(.system(size: 11))
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onAppear { Task { await loadLogs() } }
    }

    private var filteredLogs: [LogEntry] {
        let all = logEntries
        guard let filter = logFilter else { return all }
        return all.filter { $0.level == filter }
    }

    private func loadLogs() async {
        logEntries = await LogStore.shared.recentEntries(count: 50)
    }

    private func formatLogTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private func logLevelColor(_ level: LogEntry.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
        }
    }

    // MARK: - Actions

    private func updateDBSize() {
        Task {
            let size = await DataStore.shared.databaseSize()
            dbSize = ByteFormatter.string(bytes: size)
        }
    }

    private func deleteOldData() {
        Task {
            try? await DataStore.shared.pruneExpired(retentionDays: retentionDays)
            // 手动清理后也整理文件，否则「清理了但数据库大小没变」看着像没生效
            _ = try? await DataStore.shared.compactIfWasteful()
            updateDBSize()
        }
    }
}
