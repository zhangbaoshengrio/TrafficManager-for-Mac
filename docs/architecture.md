# 架构 / Architecture

> 中文为准，英文摘要见文末。

## 数据流

```
┌─────────────────────────────────────────────────────────────────┐
│ NetworkStatistics.framework（内核 NStat 子系统，私有 API）        │
│   nettop / 活动监视器 用的是同一个后端                            │
└───────────────────────────┬─────────────────────────────────────┘
                            │ QueryAllSourcesUpdate，每 interval 秒（默认 2s）
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ NStatCollector          串行 DispatchQueue（.utility），非主线程  │
│  · counts 回调：CFDictionaryGetValue 直读 4 个字段（零桥接）      │
│  · SourceLedger：每条连接累计值就地相减 → 按 PID 聚合成增量       │
└───────────────────────────┬─────────────────────────────────────┘
                            │ AsyncStream<TrafficFrame>
                            │ .bufferingNewest(1) —— 消费端慢时丢旧帧而非堆积
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ CollectorService        @MainActor，只持有状态，不做逐帧计算      │
│  · detached 消费任务，把帧喂给管线                                │
│  · 监听窗口遮挡 / 应用隐藏，切换 UI 可见性                        │
└───────────────────────────┬─────────────────────────────────────┘
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ TrafficPipeline         actor，全部计算在这里                     │
│  ├ ProcessIdentityResolver  pid+execName → 标识（永久缓存）       │
│  ├ stats[processKey]        累计流量 + 瞬时速率                   │
│  ├ buckets[60s][key]        待落库的时间桶                        │
│  ├ 告警判定                 阈值 + 60s 节流                       │
│  └ 节流 + 可见性闸门 → DashboardSnapshot?                        │
└──────────┬──────────────────────────────────┬───────────────────┘
           │ 每 ≥1s 且窗口可见时才产出          │ 每 saveInterval（15s）
           ▼                                  ▼
┌────────────────────────┐        ┌───────────────────────────────┐
│ DashboardViewModel     │        │ DataStore   actor / GRDB      │
│ @Observable @MainActor │        │ SQLite WAL，多值 INSERT 分块   │
└──────────┬─────────────┘        └───────────────────────────────┘
           ▼ 属性级依赖追踪
┌─────────────────────────────────────────────────────────────────┐
│ SwiftUI  SummaryRow / ProcessTableView / GroupTableView …        │
└─────────────────────────────────────────────────────────────────┘
```

## 目录

| 路径 | 职责 |
|---|---|
| `Sources/App/` | 应用入口，注入环境对象 |
| `Sources/Core/Collector/` | `NStatCollector`（内核接口）、`SourceLedger`（纯函数差值）、`CollectorService`（生命周期） |
| `Sources/Core/` | `TrafficPipeline`（管线 actor）、`DataStore`（持久化）、`AlertStore` / `GroupStore`（偏好） |
| `Sources/Models/` | 值类型：`PIDDelta`、`TrafficFrame`、`ProcessIdentifier`、`ProcessRow`、`DashboardSnapshot`、`TrafficEvent` … |
| `Sources/Utilities/` | `Constants`（配置真源）、`ProcessIdentityResolver`、`ProcessIconCache`、`ByteFormatter`、`LogStore` |
| `Sources/ViewModels/` | `DashboardViewModel`、`MenuBarRowLedger`（菜单栏面板的行排名与驻留） |
| `Sources/Views/` | SwiftUI 视图，按窗口分子目录 |

## 关键设计决策

### 1. 为什么用 NetworkStatistics 私有框架，而不是 `nettop` 子进程

早期版本每个采样周期 `fork/exec` 一次 `nettop -l 1`。单次 fork/exec 约 5ms，加上 nettop 自己的内核查询 150–300ms，1s 间隔下 CPU 约 20%。

`NStatManagerCreate` + `QueryAllSourcesUpdate` 直接接同一个内核后端，无子进程、无解析、**无需 root**。代价是依赖私有 API（见 [限制](#限制)）。

### 2. 为什么按「连接」而不是按「进程」做差值

`SourceLedger` 保存的是每条 NStat source（一条 TCP/UDP 连接）的累计值，相减后才按 PID 汇总。

连接的累计值从建立时开始单调递增，关闭即被内核移除，因此：

- 不存在计数器回退 → 不需要 `knownPIDs`、上限钳制之类的启发式
- PID 复用、进程退出被连接生命周期自然覆盖
- 中途新建的连接，其累计值恰好就是这段间隔内的真实流量，可直接计入

首帧是例外：此时每条连接的累计值是它自建立以来的总量，不代表这一秒的流量。所以首帧标记 `isBaseline`，只用于建立基线和登记活跃进程，不计入统计。

### 3. 为什么不用 `dict as? [String: Any]`

counts 回调给的 CFDictionary 有 **47 个键**（rtt、拥塞窗口、收发缓冲区、地址……），我们只要 4 个。整体桥接要把 47 个 CFString 逐个转成 Swift String、数值全部装箱。

实测 340 条连接一帧：桥接 4.4–10ms，`CFDictionaryGetValue` 直读 0.25–0.58ms，**17–20 倍**差距。进程名对同一条连接恒定，只在该 PID 首次出现时桥接一次。

### 4. 为什么管线是 actor 且不在 MainActor 上

身份解析要调 `NSRunningApplication`（LaunchServices 同步 XPC，实测 0.24ms/次）。放在 `@MainActor` 上等于让主线程做 XPC 阻塞。

现在 `ingest()` 返回 `DashboardSnapshot?`：不到刷新节拍、或窗口被完全遮挡时返回 nil，**主线程整帧不被唤醒**。

### 5. 为什么用 `@Observable` 而不是 `ObservableObject`

`ObservableObject` 的 `objectWillChange` 是**对象级**通知：一个内部计数器自增，就会让所有观察它的视图重新求值 —— 在 `NavigationSplitView` 里表现为整棵 AppKit 视图树重新布局（30+ 层 `-[NSView _layoutSubtreeWithOldSize:]` 递归、约束求解、文本测量）。

`@Observable`（Observation 框架，macOS 14+）按**属性**追踪依赖。速率每秒变化只让 3 张汇总卡片失效，表格行变化只让表格失效。这一项贡献了性能重构中最大的一块收益，详见 [performance.md](performance.md)。

配套要求：表格行必须是 `Equatable` 值类型（`ProcessRow`），SwiftUI `Table` 才能做行级差分。旧实现用 `NSObject` 子类且无 `Equatable`，每次刷新都是 NSTableView 全量 reload。

### 6. 为什么落库要先分桶

旧实现每进程每 tick 写一行：40 个活跃进程 @2s = 20 行/秒 ≈ **173 万行/天**。

现在先在内存里按 60 秒时间桶聚合，一个桶一个进程只写一行 → 同样负载下约 5.8 万行/天，**降低 30 倍**（比值就是 `storageBucketSeconds / interval`）。写入用单条多值 `INSERT ... VALUES (?,…),(?,…)` 分块提交。

代价是**分辨率**：桶里的 `bytes` 是一分钟的求和，10 秒跑满 22 Gbps 的测速
在图上只剩「26.5 GB ÷ 60s ≈ 3.8 Gbps」。所以每个桶额外记一列峰值：

```
peakIn / peakOut = 桶内出现过的最高瞬时速率（逐帧取 max，B/s）
```

它是「真实发生过的速率」，而 `bytes / interval` 只是桶均值。查询展示桶时对
峰值取 `MAX`；迁移前的老行没有这两列（补 `DEFAULT 0`），退回该行自己的
`bytes / interval` —— 退回时也必须用**行自己的** `interval`，否则将来把落库
粒度改成 5s/10s，老行会被展示桶长度除出一个虚高的「峰值」。

查时间线时返回**整窗网格**，并区分两种「没有字节」：

- 采集器在跑、该进程没流量（同一分钟里别的进程有行）→ **0**，图上贴地；
- 整分钟谁都没有数据（应用关了 / 机器睡了）→ 同样补 **0** 让折线连续
  （睡着时不可能有流量，0 是事实），但标 `isCovered = false`，
  图上铺一层浅灰带 —— 应用没在跑时 0 只是推测，不能和「测到 0」混为一谈。

画线时按「段 × 方向」分组，段号在相邻数据点跨度超过一个桶时递增 ——
否则 07:58 和 14:08 两次突发会被连成一条斜线，看起来像这六小时一直在传。

图表把两个方向**镜像**排布：下载在零轴上方、上传在轴下方。这不是审美选择 ——
同侧排布时两个面积填充必然重叠（混出来的紫既不像蓝也不像红），柱状还会被默认
堆叠成一根（高度变成两者之和）。镜像之后各填各的一侧，配合 `.monotone`
（平滑但不过冲，避免尖峰两侧冲出负值）与 `.unstacked`（不堆叠）即可。

### 7. 图标为什么只在管线里存路径

`NSImage` 不是 `Sendable`，不能跟着 `ProcessIdentifier` 穿过 actor 边界。
所以身份解析时只记录一个 `String` 路径（`.app` 包优先，否则可执行文件本身），
真正的图像由主线程侧的 `ProcessIconCache` 按需加载。

缓存对**未命中也记录**：否则每次重绘都会对同一个失败路径重试一遍 LaunchServices 查询。
历史行只有 `bundleId` 没有路径，缓存会退回 `urlForApplication(withBundleIdentifier:)`，
同样每个标识最多一次。

### 8. 侧栏为什么是扁平 `List` 而不是带 `Section`

macOS 上带 `Section` 的 `List` 由 NSOutlineView 承载，构建时要 `expandItem:` 展开 section，而 AppKit 在这条路径上会自我重入：

```
expandItem: → NSTableRowData.endUpdates → _keepTopRowStableAtLeastOnce
  → rowAtPoint: → _cacheRowSpansInRange:                 ← 第一次进入
    → _adjustRowSpansStartingAtRow: → _updateTableViewSize
      → _minimumFrameSize → _totalHeightOfTableView
        → _cacheRowSpansInRange:                         ← 重入
```

每次启动都会打印 `Application performed a reentrant operation in its NSTableView delegate`，且 AppKit 声明将来会升级成 assert。扁平 `List` 走 NSTableView，没有 `expandItem:` 这一步，警告消失且完整保留原生侧栏材质。

### 9. 菜单栏面板为什么要在快照之上再加一层「行台账」

面板一次只放得下六行，选谁进去看似显然：取速率最高的六个。实际做出来是这样的
（真机 40 秒、每 2 秒一帧，记录每帧「速率 > 0」的进程数）：

```
rows=6 → 5 → 5 → 4 → 6 → 4 → 5 → 5 → 3 → 5 → 4 → 4 → 5 → 6 → 6 → 4 …
```

行数在 3~6 之间来回跳。菜单栏面板是**顶边固定、底边浮动**的，高度一变窗口原点
跟着动 —— 探针实测窗口在 `(…, 921, 280, 203)` 与 `(…, 939, 280, 185)` 之间反复
resize。成员和顺序也几乎每帧重排。整体观感就是「面板一直在闪」。

症结不在渲染层，而在于**瞬时速率天然是抖的**：一个进程空一帧再回来是常态，
不是异常。所以稳定必须在展示层做，`MenuBarRowLedger` 承担这件事：

| 环节 | 规则 |
|---|---|
| 候选 | 最近 `lingerWindow`（30 秒）内**曾经**有过流量的进程 |
| 排名 | 按平滑速率（EMA，`smoothing` = 0.35，约三帧记忆）降序；并列按进程 key 升序 |
| 截断 | 取前 `capacity`（6）个 |
| 淡化 | 此刻 `rx + tx == 0` 的行标记 `isIdle`，界面降到 45% 不透明度 |

几个容易误解的点：

- **不是「此刻有流量的进程」**。此刻有流量的一定在候选池里，但排名按平滑速率算，
  偶尔会有此刻刚起速的进程排不进前六。
- **从来没有过流量的进程永远不上榜**，哪怕今日累计流量很大 —— 候选看的是
  `lastActive`，只有某一帧 `rx + tx > 0` 才会写入。
- **显示的数字仍是瞬时速率**，平滑只用于排名。否则用户看到的速率会比实际慢半拍。
- **「稳定六行」是结果不是规则**。候选不足六个就显示几行，不补空行。一般机器
  30 秒内有流量的进程远多于六个，所以总是满的；机器真闲下来行数会少于六，
  但那时同样是稳的 —— 高度只在活跃进程数跨过 6 这条线时变一次。

复测：同一台机器连续 60 秒，**每一帧都是 6 行，窗口 frame 一次都没变过**。

三个参数是直接对立的取舍：`lingerWindow` 调短（10~15 秒）列表更贴近「此刻」，
代价是行数开始波动；调长则更稳，代价是淡化的历史行占位更多。

### 10. 统计窗口为什么要盯着日历边界

侧栏的「今日 / 本周 / 本月」是**左闭右开的日历区间**，两端都由
`Calendar.dateInterval(of:for:)` 给出。终点不是「起点 + 86400」——
夏令时切换那天只有 23 小时（或 25 小时），加固定秒数会落到隔天 01:00。

窗口一旦装载就固定下来，管线里的账目是：

```
historical  该窗口内已落库的字节     ← 数据库汇总，换窗口时整体替换
live        该窗口内尚未落库的字节   ← 内存桶的镜像，窗口外的不算
total = historical + live
```

跨过终点后得有人把窗口挪到新的周期。这件事由**采集循环**做，而不是定时器：

- 帧的 `timestamp` 越过窗口终点 → 管线打一个「窗口过期」标记；
- 采集循环取走标记 → 按当前范围重查一次数据库。

这么安排的理由：判定在管线侧完成，**主线程只在真的过期时被唤醒**（采集链路上
不做磁盘 IO，也不按帧惊动主线程）；菜单栏模式、窗口被遮挡时同样生效，因为驱动
它的是采样帧而不是界面刷新。系统休眠跨零点也没问题 —— 唤醒后的第一帧就带着
过期标记。

`live` 也必须受窗口约束。它不是「最近一段时间的量」，而是内存桶的镜像：
00:00 换窗口时 23:59 那个桶还没落库（桶要等封口，flush 每 15 秒一次），
如果它被留在窗口里，之后 flush 还会把它搬进 `historical` —— 昨天最后一分钟的
流量就会在「今日」里挂一整天，手动切换范围也清不掉。所以换窗口时按桶重算
`live`，`ingest` 只累计窗口内的数据，`flush` 只把窗口内的桶转成窗口内历史；
窗口外的桶照常落库，以后切到更大的窗口还能查到。

## 并发模型

| 执行域 | 承载内容 |
|---|---|
| `com.trafficmonitor.nstat`（串行队列） | NStat 回调、`SourceLedger`、帧组装 |
| `TrafficPipeline`（actor） | 身份解析、聚合、累计、分桶、告警、快照生成 |
| `DataStore`（actor） | 所有 SQLite 读写 |
| `@MainActor` | `CollectorService` 状态、`DashboardViewModel`、全部 SwiftUI |

跨域只通过值类型传递（`TrafficFrame`、`DashboardSnapshot`），没有共享可变状态。

## 限制

| 限制 | 说明 |
|---|---|
| 依赖私有 API | `NetworkStatistics.framework` 未公开，**无法上架 App Store**，且 macOS 大版本升级可能改变符号或行为 |
| loopback 自连双记 | 进程通过 127.0.0.1 连自己时是同一 PID 的两条连接，内核分别记收和发。实测传输 10 MiB → rx=10 MiB 且 tx=10 MiB，"下载+上传"合计是实际载荷的 2 倍。真实外网流量不受影响 |
| 采样间隔内的短连接 | 两次采样之间建立又关闭的连接，其流量会在关闭时随 source 移除而丢失 |
| 换窗口跟着采样帧 | 跨过日历边界后由下一帧触发重查（默认 2 秒采一帧，最多晚 2 秒）；采集停止期间不换窗口，重新开始采集时会按当前范围重查 |

---

## English summary

`NStatCollector` polls the kernel Network Statistics subsystem (the same backend
`nettop` and Activity Monitor use) on a serial dispatch queue, reading only four
fields per connection through `CFDictionaryGetValue` — bridging the full 47-key
`CFDictionary` cost 17–20× more. `SourceLedger` turns per-connection cumulative
counters into per-PID deltas; because a connection's counter is monotonic and the
kernel removes it on close, no counter-rollback heuristics are needed.

Frames flow through an `AsyncStream` (`.bufferingNewest(1)`) into `TrafficPipeline`,
an actor that does *all* the work off the main thread: identity resolution
(cached, so LaunchServices XPC happens once per process lifetime), aggregation by
bundle identifier, 60-second bucketing for persistence, alert evaluation, and
snapshot generation. `ingest()` returns an optional snapshot — `nil` when the
refresh interval hasn't elapsed or the window is occluded — so the main thread is
never woken for a frame it cannot use.

The UI uses `@Observable` (property-level dependency tracking) rather than
`ObservableObject` (object-level invalidation), and `Equatable` value-type rows so
SwiftUI `Table` can diff individual rows. See [performance.md](performance.md) for
the measurements behind these choices.
