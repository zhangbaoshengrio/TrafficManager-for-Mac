# 性能：从 6.3% 降到 1.4% CPU

> 全部数字为实测，测量方法与复现步骤见文末。
> English summary at the bottom.

## 结论

后台窗口、无用户交互、约 340 条活跃连接 / 40 个活跃进程的条件下：

| 指标 | 重构前 | 重构后 | 变化 |
|---|---:|---:|---|
| **稳态 CPU（单核占比）** | 6.3% | **1.4–1.7%** | ↓ ~4× |
| 主线程活跃采样数（20s @1ms） | 975 | 112 | ↓ 8.7× |
| 采集队列采样数 | 101 | 63 | ↓ 1.6× |
| `CA::Transaction::commit` 采样数 | 218 | 43 | ↓ 5× |
| RSS | ~92 MB | ~84 MB | ↓ 9% |
| SQLite 写入行数（同等负载） | ~173 万/天 | ~5.8 万/天 | ↓ 30× |
| 启动时 stderr 输出 | 1 条 AppKit 警告 | 0 | 清零 |

## 定位过程

### 第一步：拆分归因

不猜，直接做变量控制实验，每次只改一处再测 55 秒 CPU 时间增量：

| 变体 | 稳态 CPU |
|---|---:|
| 原样 | 6.3% |
| 屏蔽所有 `@Published` 写入（采集照跑，UI 不刷新） | 3.0% |
| UI 刷新周期 1.5s → 6.0s | 2.9% |
| 屏蔽 LaunchServices 查询 | 与未屏蔽持平 |

用后两点拟合 `cost = base + k / cadence`：

```
1.5s 档: base + k/1.5 = 6.3%
6.0s 档: base + k/6.0 = 2.9%
       → k ≈ 6.8%·s，base ≈ 1.8%
       → 每次 UI 刷新约 68ms 主线程 CPU
```

**结论：6.3% 里约 4.5 个百分点（72%）是 UI 刷新，1.8 个点是采集 + 聚合 + 落库。**

LaunchServices 那一项进程内看不到，是因为它阻塞在 `mach_msg` 等待 —— CPU 花在 `launchservicesd` 里，不计入本进程。仍然要修。

### 第二步：抓调用栈

`/usr/bin/sample <pid> 20 1`，主线程 16274 个采样中 15299 个空转在 `mach_msg`，其余几乎全在这一条路径：

```
CA::Transaction::commit → NSDisplayCycleFlush
  → -[NSView _layoutSubtreeWithOldSize:]  ×30+ 层递归
    → NSISEngine 约束求解 / NSStringDrawingEngine 文本测量
    → NSViewUpdateVibrancyForSubtree / _buildLayerTree / updateTrackingAreas
    → AG::Graph::UpdateStack::update  (AttributeGraph)
```

这不是「更新几个单元格的文字」，是**整棵窗口视图树被推倒重建并重新做自动布局**。

后台线程上则抓到：

```
TrafficStore.accumulate → ProcessIdentifier.displayName.getter
  → +[NSRunningApplication runningApplicationsWithBundleIdentifier:]
    → _LSCopyMatchingApplications → xpc_connection_send_message_with_reply_sync
      → mach_msg2_trap        （同步 XPC，阻塞等待）
```

### 第三步：微基准

独立可执行文件，直接打表：

| 操作 | 耗时 |
|---|---|
| `dict as? [String: Any]`（340 条连接，47 键） | 4.4–10 ms/帧 |
| `CFDictionaryGetValue` 直读 4 字段（同数据） | 0.25–0.58 ms/帧 |
| `NSRunningApplication.runningApplications(withBundleIdentifier:)` | 0.24 ms/次 |
| `NSRunningApplication(processIdentifier:)` | 0.046 ms/次 |

切换到直读前，用 823 条真实记录逐字段比对了两条路径的返回值，**零差异**。

## 五个根因与对应修改

### 1. UI 每 1.5s 全量重建整棵树 —— 约 4.5%

四个问题叠加：

- `CollectorService.listTick` 是 `@Published`，而主视图用 `@EnvironmentObject` 观察整个 `CollectorService`。`objectWillChange` 是对象级通知，一个计数器自增就让 `NavigationSplitView` + 侧栏 + 工具栏全部重新求值。**空表格状态下每次也要 ~18ms。**
- `rebuildList()` 连写 4 个 `@Published`，每个发一次通知。
- 主视图的 `rebuildItems()` 被 `processes.count` 和 `todayTraffic` **双触发**（后者几乎每 tick 都变），内部 `new` 出全部行对象、排序，再 `DispatchQueue.main.async` 赋值 `@State` —— **又触发第二轮完整 body 重算**。
- 行类型是 `NSObject` 子类且无 `Equatable`，SwiftUI `Table` 无法差分 → NSTableView 整表 reload。

→ `@Observable` 属性级追踪；视图按数据依赖拆成 `SummaryRow` / `ProcessTableView` / `GroupTableView`；行改成 `Equatable` 值类型 `ProcessRow`；删掉双触发与二次赋值。

### 2. 47 键 CFDictionary 全量桥接 —— 占整帧 55%

→ `CFDictionaryGetValue` + 静态 CFString 键直读 4 个字段；进程名每 PID 只桥接一次。

重构后再采样，采集队列剩下的开销已经全在框架自己的 `-[NWSTCPSnapshot traditionalDictionary]` 里（它无论如何都要构造那个字典），我们的 `NStatCollector.consume` 只占 3/20000 个采样。

### 3. 热路径上的同步 XPC

`ProcessIdentifier.displayName` 是**无缓存的 computed property**，每次读取都同步 XPC 查 LaunchServices，而它在每进程每帧被读 2 次。

→ 改成存储属性；`ProcessIdentityResolver` 按 `(pid, execName)` 缓存，PID 复用靠内核每帧提供的进程名变化检测，不需要额外 syscall。稳态下热路径零 XPC。

### 4. 落库写放大

每进程每 tick 一行，逐行 `insert`。

→ 内存里按 60s 桶聚合，单条多值 `INSERT` 分块提交，启动时按保留期清理。

### 5. 架构层面的隐患

| 问题 | 处理 |
|---|---|
| 同一个 `AsyncStream` 被迭代两次（官方不支持，属未定义行为） | 单次迭代，首帧由管线自己识别为 baseline |
| `AsyncStream` 默认 unbounded 缓冲，消费端慢则无限堆积 | `.bufferingNewest(1)` |
| `processSnapshot` 在 `@MainActor` 上做 libproc / LaunchServices 调用 | 整条管线移进 `TrafficPipeline` actor |
| `Unmanaged.passUnretained(queue)` 交给 C 框架，悬垂风险 | `passRetained` + 显式 release |
| `ProcessHelper.pidCache` 是无隔离的 `static var`（数据竞争） | 值类型，收进 actor |
| `stop()` 的异步 reset 可能落在 `start()` 的 `initialize` 之后 | `teardownTask` + `restart()` |
| 详情窗多余的 1s `Timer.publish` 强制重绘 | 直接读快照 |

## 附带修掉的 AppKit 警告

启动时的 `Application performed a reentrant operation in its NSTableView delegate`
来自侧栏 `List` 的 `Section`（落到 NSOutlineView，`expandItem:` 时 AppKit 行高缓存自我重入）。
用 `lldb` 在 `NSLog` 断点抓到完整栈后定位，改成扁平 `List` 后清零。详见
[architecture.md 第 8 条](architecture.md#8-侧栏为什么是扁平-list-而不是带-section)。

## 复现方法

```bash
# 1. 编译
swift build -c release

# 2. 采 CPU 时间序列（cputime 增量除以墙钟时间 = 单核占比）
./.build/release/TrafficMonitor & APP=$!
for i in $(seq 1 12); do sleep 5; ps -p $APP -o cputime=; done
kill $APP

# 3. 抓调用栈
/usr/bin/sample <pid> 20 1 -file /tmp/sample.txt
grep -E "^    [0-9]+ Thread" /tmp/sample.txt      # 各线程采样分布
```

注意 `ps -o %cpu` 是生命周期均值，不适合看稳态；用 `cputime` 的增量除以间隔。

测量条件：macOS 14.4 / Apple Silicon / release 构建 / 窗口在后台且无交互。
环境网络活跃度会影响结果，重构后的 1.4–1.7% 区间就来自不同时段的两次测量。

---

## English summary

Steady-state CPU dropped from **6.3% to 1.4–1.7%** of one core (background window,
no interaction, ~340 live connections).

Attribution came from controlled experiments rather than guesswork: disabling all
`@Published` writes took it to 3.0%, and slowing the UI refresh from 1.5s to 6.0s
took it to 2.9%. Fitting `cost = base + k/cadence` across those two points gives a
~1.8% fixed base and roughly **68 ms of main-thread CPU per UI refresh** — meaning
**72% of the total was UI work**.

`/usr/bin/sample` confirmed it: the main thread's active samples were almost
entirely `CA::Transaction::commit → -[NSView _layoutSubtreeWithOldSize:]` recursing
30+ levels, i.e. the whole window view tree being torn down and re-laid-out on every
refresh — caused by object-level `ObservableObject` invalidation, four separate
`@Published` writes per refresh, a double-triggered rebuild with a
`DispatchQueue.main.async` second pass, and non-`Equatable` `NSObject` row items
that defeated `Table` diffing.

Microbenchmarks drove the collector changes: bridging the 47-key `CFDictionary`
cost 4.4–10 ms per frame versus 0.25–0.58 ms reading four fields directly
(verified field-by-field against 823 real records, zero mismatches), and
`runningApplications(withBundleIdentifier:)` cost 0.24 ms per call while being
invoked twice per process per frame from a computed property with no cache.
