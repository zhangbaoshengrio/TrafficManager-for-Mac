# Bytetally 风格主窗口重设计

## 背景

TrafficMonitor（`mo2g/traffic-monitoring` 的本地 fork，位于 `~/Documents/traffic-monitoring`）
已经有 NStat 驱动的实时逐进程流量采集、SQLite 历史存储（`DataStore`）、告警规则
（`AlertStore`/`AlertRule`）、CSV 导出、per-process 详情图表（`DetailWindow`）。

目标是把主窗口重做成参考截图（Bytetally 的 hero 页面）那个样子：顶部时间范围 +
Curve/Heatmap 切换 + 网络过滤 + 导出，中间一张全局流量趋势图（带告警标记），
下面是按流量排序的 App 表格。这会替换现有的 `MainWindowView`
（`NavigationSplitView` 侧栏 + 表格），不新开窗口。`DetailWindow`（单 App 详情）
保留，双击表格行仍然打开它。

## 现状盘点（写这份 spec 前读过的代码）

- `DataStore.querySummary(since:until:limit:)`：按进程聚合的区间汇总，已按
  总流量降序排列 —— 表格数据源已经有了。
- `DataStore.queryTimeline(processKey:since:until:bucketSeconds:)`：单进程分桶
  时间线，处理了"没采集的桶"（灰带）—— `DetailWindow` 的图表用的就是这个。
  聚合图表需要一个新的、不按 `processKey` 过滤、按全部进程求和的版本。
- `AlertStore` **只存规则，不存触发历史**（`UserDefaults` 里一个 JSON 数组）。
  截图里图表上的 ▲ 标记需要知道"这个时间点触发过哪条规则"—— 现状完全没有
  这个数据，需要新增一张持久化表。
- `trafficEvent` 表没有网络/SSID 相关字段 —— "All networks" 过滤器需要新增列
  + 采集时打标签。
- CSV 导出已完整实现（`MainWindowView.swift` 里的 `CSVDocument` +
  `.fileExporter`）；JSON 格式缺失。
- `DashboardViewModel.TimeRange` 目前只有 `.today` / `.week` / `.month` 三档，
  截图要的是 `10 min / 1h / Today / 7d / 30d / Month` + 自定义日历。
- 表格（`ProcessTableView`）已有 Download/Upload/Total/实时速率/Sparkline 列，
  缺一列 Peak——但 `trafficEvent.peakIn`/`peakOut` 数据已经在采集时写入了，
  只是没在表格里展示，属于低成本追加。

## 架构与组件

### 1. 布局：`MainWindowView` 从三栏改单栏

去掉 `NavigationSplitView` 的侧栏（`SidebarView`），改成单列 `VStack`：
顶部工具条（时间范围按钮组 + 自定义日历 + Curve/Heatmap 切换 + 网络过滤下拉 +
导出下拉 + 告警铃铛 + 刷新 + 设置）→ `SummaryRow`（Download/Upload/Total 三卡，
已存在，复用）→ 新增的聚合趋势图 → 现有的 `ContentTable`（App 排行表格，追加
Peak 列）。

`SidebarView` 里现存的"Grouped view"开关挪到工具条或表格上方的小控件里，不
跟着侧栏一起删掉这个功能。

### 2. 聚合趋势图（新组件，复用 `DetailWindow.TrafficChart` 的渲染逻辑）

新增 `DataStore.queryAggregateTimeline(since:until:bucketSeconds:)`：和
`queryTimeline` 同样的分桶 + 灰带补洞逻辑，去掉 `WHERE processKey = ?`，
`SUM` 覆盖全部进程。渲染复用 `TrafficChart` 现有的折线/面积/柱状三种
`ChartStyle` 和拖拽缩放交互（截图顶部那三个图标对应的就是这三种样式，直接
挪到主窗口工具条）。

### 3. Curve / Heatmap 切换

新增一个二态开关，`Heatmap` 选中时聚合趋势图区域切换成热力图：横轴星期几、
纵轴小时，格子深浅 = 该小时桶流量。新增
`DataStore.queryHeatmap(since:until:)`，按 `strftime('%w', ...)` /
`strftime('%H', ...)` 分组聚合（SQLite 内置，不需要额外建索引）。

### 4. 告警标记（新增持久化 + UI）

新建 `alertEvent` 表（`timestamp`, `ruleId`, `displayName`, `triggerValue`），
`CollectorService` 里规则触发时除了发通知，还写一行进这张表（走
`DataStore` 的批量写入模式）。聚合趋势图在对应时间桶上画 ▲，hover 显示是
哪条规则、什么值触发的。这是本次唯一"数据模型层面确实没有、必须新加"的
部分，其余项都是现有数据的新查询方式或新 UI。

### 5. "All networks" 网络过滤

`trafficEvent` 新增可空列 `ssid`，走 `DataStore.setup` 里已有的迁移模式
（参照 `peakIn`/`peakOut` 那次迁移的写法：`ALTER TABLE ... ADD COLUMN`，
旧行该列为空即可，不用回填）。采集时通过 `NEHotspotNetwork.fetchCurrent`
取当前 SSID 打标签——**需要在实现阶段先确认这个 API 在 App 的 entitlements
下能不能正常取到值**，取不到就退化成"未知网络"分组，不阻塞其它功能。
工具条的下拉框列出 `DataStore` 里出现过的所有 SSID + "All networks"。

### 6. 导出下拉

现有的导出按钮（`square.and.arrow.up` 图标）从单一 CSV 动作改成下拉菜单：
CSV（现状不变）+ JSON（新增 `JSONDocument`，字段跟 `CSVDocument.rows` 同源，
序列化成数组）。

### 7. 时间范围预设扩展

`DashboardViewModel.TimeRange` 从 3 个 case 扩到 6 个：
`tenMinutes / oneHour / today / sevenDays / thirtyDays / month`，UI 从侧栏
List 换成工具条里的横向分段按钮组，日历图标点开自定义范围选择器。

## 数据流

采集（`CollectorService`/`NStatCollector`）写入 `trafficEvent`（新增 `ssid` 列）
→ 规则触发时额外写 `alertEvent` → `MainWindowView` 通过
`DashboardViewModel` 读 `querySummary`（表格）+ `queryAggregateTimeline` 或
`queryHeatmap`（图表，按 Curve/Heatmap 开关切换）+ `alertEvent` 区间查询
（图表标记）+ 当前选中的 SSID 过滤条件。

## 错误处理

- SSID 取不到（`NEHotspotNetwork.fetchCurrent` 因权限或 API 限制失败）：该行
  `ssid` 写 `nil`，UI 归到"未知网络"，不影响其它列正常写入。
- 聚合查询在超大时间跨度（如 30d/Month）下的性能：先用现有索引
  （`idx_traffic_ts_process`）跑通，若明显变慢再补一个不含 `processKey` 的
  纯 `timestamp` 索引 —— 不预先优化，跟现有 `compactIfWasteful` 的"按需处理"
  风格一致。

## 测试

沿用项目现有测试风格（`Tests/` 下 196 个测试，图表类断言走位图渲染而不是
读像素猜测）：
- `DataStore` 新查询方法（`queryAggregateTimeline`/`queryHeatmap`/
  `alertEvent` 相关）：用内存 SQLite，构造已知数据，断言聚合结果。
- 迁移测试：旧库（无 `ssid` 列）打开后自动补列，参照现有 `peakIn` 迁移测试
  的写法。
- 图表：聚合图/热力图渲染成位图，断言告警标记位置、灰带位置，跟现有
  `TrafficChart` 位图测试同一套手法。
- CSV/JSON 导出：断言序列化结果字段完整、行数匹配 `dashboard.rows`。

## 范围说明

本次不包含：域名级流量归属、单 App 断网/限速、流量配额自动执行——这些需要
Network Extension（内容过滤/App Proxy），是另一个独立子系统，且需要付费
Apple 开发者账号，属于后续单独立项的范围，不在这份 spec 里。
