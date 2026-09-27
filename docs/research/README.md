# Phase 0 预研报告（历史存档）

> ⚠️ **本文是选型阶段的记录，不代表当前实现。**
>
> 文中"用 `nettop` 子进程 + sudo"的结论只成立到 Phase 0 为止。后续发现
> `nettop` 的数据源 —— `NetworkStatistics.framework` —— 可以直接 `dlopen` 调用，
> 于是最终实现**去掉了子进程，也不再需要 sudo**。
> 当前架构见 [../architecture.md](../architecture.md)。
>
> 保留本文是因为其中对 libproc 各接口的排除性论证（为什么 `proc_pid_rusage`、
> `PROC_PIDFDSOCKETINFO` 都拿不到累计网络字节数）依然有效，能解释为什么最终
> 不得不走私有 API。
>
> 日期：2026-06-10
> 原始结论：**libproc 无法获取进程级网络字节数**，需使用 nettop 子进程方案。

---

## 1. libproc API 可行性

### 结论：❌ 不可行

经过对 XNU 内核源码（`proc_info.h` 和 `proc_info_private.h`）的完整审查，确认：

- `PROC_PIDTASKALLINFO` → 只有 CPU 时间和内存统计，无网络字节字段
- `proc_pid_rusage`（所有版本 V0-V5）→ 只有磁盘 IO（`ri_diskio_bytesread/written`）和 CPU 统计，**没有网络字节字段**
- `PROC_PIDLISTFDS` + `PROC_PIDFDSOCKETINFO` → 可以枚举 socket fd 并获取连接状态（TCP 状态、地址、端口），但 `socket_info.soi_rcv` / `soi_snd` 只是当前 socket buffer 的**当前占用字节数**（`sbi_cc`），而非**累计收发字节数**

### 源码证据

以下节选自 `xnu/bsd/sys/proc_info.h`：

```c
// 接收/发送缓冲区信息 —— 这是当前 buffer 状态，不是累计计数器
struct sockbuf_info {
    uint32_t sbi_cc;      // 当前 socket buffer 中的字节数
    uint32_t sbi_hiwat;   // 高水位线（SO_RCVBUF/SO_SNDBUF 上限）
    uint32_t sbi_mbcnt;   // mbuf 总字节数
    uint32_t sbi_mbmax;   // mbuf 最大限制
    ...
};

struct socket_info {
    struct vinfo_stat  soi_stat;    // 文件 stat（vst_size 等，无用）
    uint64_t           soi_so;      // socket 内核对象句柄
    ...
    struct sockbuf_info soi_rcv;    // 接收 buffer 当前状态（非累计）
    struct sockbuf_info soi_snd;    // 发送 buffer 当前状态（非累计）
    ...
};
```

`sockbuf_info` 的 `sbi_cc` 反映的是缓冲区中**当前**有多少字节等待处理，随着数据被应用读取或发送完成，这个值会变化——无法用来计算累计流量。

### 那 nettop 的数据从哪来？

nettop 读取的是内核 NKE（Network Kernel Extension）层的统计计数器，这些数据通过私有接口暴露。具体路径可能是：
- 内核 `ifnet` 结构的每个 socket 的流量统计
- 或通过 `sysctlbyname` 访问的全局网络统计

但这些接口不通过 libproc 的公开 API 暴露。在应用层，解析 nettop 输出是目前最可靠的途径。

---

## 2. nettop 子进程方案

### 结论：✅ 可行（推荐作为主要采集后端）

| 维度 | 结果 |
|------|------|
| 二进制位置 | `/usr/sbin/nettop`（系统内置，macOS 10.x - 15.x 都可用） |
| 权限要求 | 必须 root 权限（sudo） |
| 单次执行耗时 | 约 1-3 秒（`-l 1` 快照模式） |
| 输出稳定性 | 连续 5 次快照，格式一致 |
| 文本解析 | 单次解析耗时 < 0.05ms，可忽略不计 |
| 进程覆盖 | 能看到 Chrome/Edge/Safari 等所有网络活跃进程 |

### 关键命令

```bash
sudo nettop -l 1 -n -P -J bytes_in,bytes_out,state
```

参数说明：
- `-l 1`：采集 1 次后退出
- `-n`：不解析主机名（加速）
- `-P`：按进程聚合
- `-J bytes_in,bytes_out,state`：显示指定字段

### nettop 输出格式

```
nettop -l1 -P -n, polling every 1.0 seconds
                                                     bytes_in    bytes_out    state
Google Chrome.1234           tcp4 192.168.1.1:443      1.0MiB     500KiB   Established
Google Chrome Helper.1235    tcp4 10.0.0.1:80          100KiB     50.0KiB  Established
com.apple.WebKit.5678        tcp4 *:*                   0B         0B       Listen
```

解析策略：
1. 跳过表头行（含 "nettop"、"bytes_in"）
2. 第一列 = `进程名.PID`（用最后一个 `.` 分割）
3. 字节值在倒数几列中，格式为数字+单位（`1.0MiB`, `500KiB`, `0B`）
4. 取倒数第 2 个字节值为 bytes_in，倒数第 1 个为 bytes_out

### Swift 实现要点

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/sbin/nettop")
process.arguments = ["-l", "1", "-n", "-P", "-J", "bytes_in,bytes_out,state"]
process.standardOutput = stdoutPipe
process.standardError = stderrPipe
try process.run()
process.waitUntilExit()
```

---

## 3. Bundle ID 获取

### 结论：✅ Bundle ID 优先策略可行

| 维度 | 结果 |
|------|------|
| NSRunningApplication 枚举 | < 15ms，可高频调用 |
| Bundle ID 覆盖率 | ~60-70% 进程有 Bundle ID（剩余是 daemon/CLI 工具） |
| 备选路径 | `proc_pidpath` → 解析 `.app` 路径 → `Bundle(path:)` |
| Chrome 多进程 | 所有 Chrome 子进程都能通过 `NSRunningApplication` 映射到 `com.google.Chrome` |

### 推荐聚合策略

```
优先级1: pid → NSRunningApplication.bundleIdentifier → 使用 Bundle ID 作为聚合键
优先级2: proc_pidpath → 路径含 .app → Bundle(path:) 查找 → 使用 Bundle ID
优先级3: 都失败 → fallback 到 proc_name() 的进程名
```

### 典型映射示例

| 进程名 | PID | Bundle ID |
|--------|-----|-----------|
| Google Chrome | 1234 | `com.google.Chrome` |
| Google Chrome Helper (GPU) | 1235 | `com.google.Chrome` |
| Google Chrome Helper (Renderer) | 1236 | `com.google.Chrome` |
| Microsoft Edge | 5678 | `com.microsoft.edgemac` |
| Microsoft Edge Helper | 5679 | `com.microsoft.edgemac` |
| Code | 9012 | `com.microsoft.VSCode` |
| Code Helper (Plugin) | 9013 | `com.microsoft.VSCode` |
| WeChat | 3456 | `com.tencent.xinWeChat` |
| Shadowrocket | 7890 | `com.qiuyuzhou.Shadowrocket` |

---

## 4. 提权方案

### 结论：✅ AppleScript 弹窗方案可行

### 四种方案对比

| 方案 | API | 体验 | 安全性 | 复杂度 | 推荐 |
|------|-----|------|--------|--------|------|
| A. AuthorizationExecuteWithPrivileges | Security.framework | 标准系统对话框 | 中 | 高（C API） | ❌ deprecated |
| B. SMJobBless + HelperTool | ServiceManagement | 一次授权 | 高 | 很高（双 target） | ❌ 过于复杂 |
| **C. AppleScript** | NSAppleScript | 标准密码对话框 | 中 | **低** | **✅ 推荐** |
| D. sudo + stdin | Process | 需另行获取密码 | 低 | 低 | ❌ 不够优雅 |

### 推荐方案：AppleScript

```swift
let scriptSource = """
do shell script "nettop -l 1 -n -P -J bytes_in,bytes_out,state" 
    with administrator privileges
"""

if let script = NSAppleScript(source: scriptSource) {
    var errorDict: NSDictionary?
    let result = script.executeAndReturnError(&errorDict)
    
    if let error = errorDict {
        let code = error[NSAppleScript.errorNumber] as? Int ?? -1
        if code == -128 {
            // 用户取消了密码对话框
        } else {
            // 其他错误
        }
    } else {
        let output = result.stringValue ?? ""
        // 解析 nettop 输出...
    }
}
```

### 授权频率优化

每次 nettop 调用都弹窗会导致体验很差（每 5 秒一次密码对话框）。优化策略：

1. **首次授权 + sudo timestamp**：第一次弹窗获取权限后，通过 AppleScript 执行 `sudo -v` 刷新 timestamp（默认 5 分钟有效期），后续 nettop 调用不再需要密码
2. **定时刷新**：每 4 分钟执行一次 `sudo -v` 保持授权活跃
3. **授权失效处理**：检测到授权过期后，弹窗提示用户重新输入密码

### 错误码参考

| 错误码 | 含义 |
|--------|------|
| -128 | 用户取消了授权对话框 |
| -600 | 应用没有必要的签名 |
| 1 | 密码错误 |
| 其他 | 系统/权限错误 |

---

## 5. 架构影响

### 原计划变更

预研结果对 MVP 计划有以下影响：

| 原计划 | 变更 |
|--------|------|
| libproc 为主后端 | **nettop 子进程为主后端**（libproc 不适用） |
| 无需 sudo | **必须 sudo**（通过 AppleScript 弹窗获取） |
| `CollectionBackend` Protocol 双后端 | **简化为单后端**（nettop），保留 Protocol 以备未来扩展 |
| 无菜单栏 | 不变（窗口应用） |

### 采集体检调整

- libproc 后端标记为"不可用"
- nettop 后端成为唯一活跃后端
- 保留 `CollectionBackend` Protocol 作为架构边界和测试接口
- 重点优化 sudo session 管理（避免每次采集都弹窗）

### 风险更新

| 风险 | 原评估 | 现评估 | 缓解 |
|------|--------|--------|------|
| libproc 不可用 | 中 | ~~已确认~~ → 采用 nettop | 验证过的回退方案 |
| sudo 弹窗体验 | — | **新增**：高频弹窗影响体验 | sudo timestamp 续期机制 |
| AppleScript 未来兼容性 | — | **低**：Apple 可能移除 | 保留 Process+sudo 作为终极回退 |

---

## 6. 验证脚本

在 `research/` 目录下提供了四个 Swift 脚本，可在 macOS 上直接编译运行：

```bash
# 1. libproc API 可行性（已通过源码确认结论，脚本仍可）
swiftc research_libproc.swift -o research_libproc
./research_libproc $(pgrep Chrome | head -1)

# 2. nettop 子进程方案
swiftc research_nettop.swift -o research_nettop
sudo ./research_nettop

# 3. Bundle ID 映射
swiftc research_bundleid.swift -o research_bundleid
./research_bundleid

# 4. 提权方案
swiftc research_privilege.swift -o research_privilege
./research_privilege
```

> **注意**：第 4 个脚本会弹出系统授权对话框，需要输入管理员密码。测试完成后授权自动释放。

---

## 7. Rust 语言引入分析

### 用户问题

是否可以引入 Rust 提升性能、降低系统负载、保证稳定性？

### 结论：❌ 不推荐（对当前架构收益极低）

### 详细分析

**这个应用的性能瓶颈在哪里？**

```
采集循环耗时分解（单次快照，5s 间隔）:

  nettop 子进程执行:  1,000 - 3,000 ms  ← 瓶颈在此（外部进程，不受语言影响）
  文本解析:              0.03 - 0.05 ms  ← 可忽略
  差值计算:              0.01 - 0.02 ms  ← 可忽略
  Bundle ID 查询:        5 - 15 ms       ← NSRunningApplication 调用，非计算密集
  SQLite 写入:           1 - 5 ms        ← GRDB（C 实现），已是最优
  ─────────────────────────────────────
  总耗时:             ~1,000 - 3,020 ms

  我们的代码占比:       ~6 - 20 ms       ← 不到总耗时的 2%
  nettop 等待:        ~1,000 - 3,000 ms  ← 占 98%+
```

应用程序 98% 以上的耗时在等待 nettop 的外部进程完成——这是操作系统的 I/O 等待，与语言无关。即使我们用汇编手写解析器，对于总耗时的影响也是零。

**Rust 在什么场景有意义？**

| 场景 | 适用性 |
|------|--------|
| 网络数据包实时解析（如 pcap 处理） | ✅ Rust 很适合 |
| 内核扩展 / 系统扩展 | ✅ Rust 安全优势明显 |
| 高性能代理/转发 | ✅ Rust async 生态成熟 |
| **本应用：调用外部命令 + 文本解析 + SQLite 存储** | ❌ 收益为零 |

**如果坚持引入 Rust，能做什么？**

如果一定要用 Rust，最合理的切入点是未来实现 **PrivilegedHelperTool**（SMJobBless 方案的 root 权限守护进程）。Rust 对内存安全的保证在特权代码中很有价值。但这只是一个小型的 helper 工具，一个 Swift CLI target 同样胜任。

**Rust 引入的成本**

| 成本项 | 详情 |
|--------|------|
| FFI 桥接 | Swift ↔ Rust 需要 C ABI 层或 `uniffi`，增加复杂度 |
| 双构建系统 | Xcode + SPM + Cargo，CI/CD 复杂化 |
| 团队技能 | 需要同时维护 Swift 和 Rust 代码 |
| 包体积 | Rust 静态链接后增加 ~2-10MB（取决于依赖） |
| 调试 | 跨 Swift/Rust 边界的崩溃定位困难 |

### 推荐

保持纯 Swift 技术栈。应用的计算负载极小（6-20ms per 5s），即便在 10 年前的 Mac 上也完全不会成为瓶颈。稳定性方面，Swift 的内存安全性（ARC + 值类型）足够，不需要引入 Rust 的 borrow checker。

---

## 8. 一次性授权方案分析

### 用户需求

MVP 阶段要求：首次打开应用时授权一次，应用关闭前无需再次授权。重新打开应用需要再次授权——这个可以接受。不需要 SMJobBless 级别的持久化。

### 方案总览

| 方案 | 首次 | 运行中 | 重启App | 复杂度 | 稳定性 |
|------|------|--------|---------|--------|--------|
| A. sudo timestamp 续期 | 弹窗输密码 | 静默（sudo -v 自动续期） | 重新弹窗 | 低 | 高 |
| B. 持久 root 子进程 | 弹窗输密码 | 静默（子进程保持 root） | 重新弹窗 | 中 | 高 |
| C. AppleScript 一次性脚本 | 弹窗输密码 | 静默（script 缓存权限） | 重新弹窗 | 低 | 中 |
| D. 密码内存缓存 + stdin | 自建弹窗 | 静默（内存中密码送 sudo -S） | 重新输入 | 中 | 中 |

---

### 方案 A：AppleScript + sudo timestamp 续期（推荐）

**原理**：第一次通过 AppleScript 弹窗执行 `nettop`，系统自动创建 sudo timestamp。之后每次采集循环中定期执行 `sudo -v`（每 4 分钟）刷新 timestamp，5 分钟内无需重新输入密码。

```
首次启动:
  ┌─────────────────────────────────────┐
  │  AppleScript 弹窗:                  │
  │  "TrafficMonitor 想要进行更改"       │
  │  [用户名] [密码输入框]               │
  │         [取消]  [好]                │
  └─────────────────────────────────────┘
          │ 用户输入密码
          ▼
  sudo timestamp 创建（有效期 5 分钟）
          │
          ▼
  ┌─── 采集循环 ───────────────────────┐
  │                                     │
  │  每 5s: sudo nettop ... (无需密码)   │
  │  每 4min: sudo -v (刷新 timestamp)  │
  │                                     │
  └─────────────────────────────────────┘
          │
          │ 应用退出（timestamp 最多再活 5min）
          ▼
  下次启动 → 重新弹窗
```

**实现**：

```swift
class PrivilegeHelper {
    private var refreshTimer: Timer?
    
    /// 首次授权：弹出密码框
    func authorize() async -> Bool {
        let script = """
        do shell script "nettop -l 1 -n -P -J bytes_in,bytes_out > /dev/null" 
            with administrator privileges
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil
    }
    
    /// 启动后台续期定时器
    func startRefreshLoop() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { _ in
            // 静默刷新（不会弹窗，因为 timestamp 还在有效期内）
            let _ = self.runSilent("sudo -v")
        }
    }
    
    /// 静默执行命令（timestamp 有效期内无需密码）
    func runSilent(_ cmd: String) -> String {
        // Process 调用 sudo cmd
    }
}
```

**优点**：
- 实现最简单，预研已验证
- 系统原生密码对话框，用户信任
- 无需管理子进程生命周期

**缺点**：
- 依赖 sudo timestamp 机制（系统默认 5 分钟）
- AppleScript 未来可能被限制（但目前 macOS 15 仍可用）
- 用户如果手动执行 `sudo -k` 会清除 timestamp

---

### 方案 B：持久 root 子进程（管道通信）

**原理**：首次授权后启动一个以 root 运行的子进程，通过 stdin/stdout 管道持续通信。子进程在后台循环执行 nettop，主进程读取结果。应用退出时 terminate 子进程。

```
首次启动:
  ┌─────────────────────────────────────┐
  │  AppleScript 弹窗 → 启动 root 子进程  │
  └─────────────────────────────────────┘
          │
          ▼
  ┌─── root 子进程（常驻）──────────────┐
  │  while true:                       │
  │    read stdin (等待主进程指令)       │
  │    nettop -l 1 ...                 │
  │    write stdout (输出结果)          │
  │  end                               │
  └─────────────────────────────────────┘
          ▲  │
    stdin  │  │  stdout
          │  ▼
  ┌─── 主进程 ─────────────────────────┐
  │  每 5s: write "go\n" to stdin      │
  │  读取 stdout → 解析输出            │
  └─────────────────────────────────────┘
          │
          │ 应用退出
          ▼
  terminate 子进程（root 权限随之消失）
```

**实现**：

```swift
class RootCollector {
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    
    func start() async -> Bool {
        // 1. 通过 AppleScript 获取一次性授权
        let authorized = await PrivilegeHelper().authorize()
        guard authorized else { return false }
        
        // 2. 启动持久 root 子进程
        process = Process()
        process?.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process?.arguments = ["/path/to/collector_helper.sh"]
        
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process?.standardInput = stdinPipe
        process?.standardOutput = stdoutPipe
        
        stdin = stdinPipe.fileHandleForWriting
        stdout = stdoutPipe.fileHandleForReading
        
        try? process?.run()
        return true
    }
    
    func takeSnapshot() -> String {
        stdin?.write("go\n".data(using: .utf8)!)
        // 读取子进程输出直到遇到分隔符
        return readUntilDelimiter()
    }
    
    func stop() {
        process?.terminate()
    }
}
```

**优点**：
- 一次授权后 zero 额外开销（无需反复 sudo -v）
- 比方案 A 更干净——不依赖 timestamp 机制
- 应用退出即失效，安全性好
- 子进程崩溃可自动重启（再次弹窗授权）

**缺点**：
- 需要维护子进程生命周期（崩溃检测和恢复）
- 管道通信协议需要设计（数据分帧）
- 比方案 A 多一些代码量

---

### 方案 C：AppleScript 缓存（简化版方案 A）

**原理**：第一次用户授权后，AppleScript 内部在一定时间内不需要再弹窗。实际上这是方案 A 的简化版本——依赖 AppleScript 自身的权限缓存（约 5 分钟），不做主动续期。如果缓存过期就自动重新弹窗。

**实现**：

```swift
func executeNettop() -> String {
    let script = """
    do shell script "nettop -l 1 -n -P -J bytes_in,bytes_out,state" 
        with administrator privileges
    """
    var error: NSDictionary?
    let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
    
    if error != nil {
        // 用户取消了弹窗或权限过期 → 通知 UI
        return ""
    }
    return result?.stringValue ?? ""
}
```

**优点**：代码量最小（~10 行）

**缺点**：
- 不主动续期的话，5 分钟后再次弹窗（用户体验比方案 A 差）
- 加上续期逻辑就是方案 A

---

### 方案 D：自定义密码弹窗 + 内存缓存 + sudo -S

**原理**：完全放弃系统弹窗，自己画一个密码输入框。密码存在内存变量中（不落盘），每次调 nettop 时通过 `sudo -S` 从 stdin 传入。

```
首次启动:
  ┌─────────────────────────────────────┐
  │  [自定义 SwiftUI 密码窗口]           │
  │  "请输入管理员密码以启用流量监控"     │
  │  [密码输入框]                        │
  │         [取消]  [授权]               │
  └─────────────────────────────────────┘
          │ 用户输入密码
          ▼
  password 存于内存变量（不落盘，不打印）
          │
          ▼
  Process("sudo", "-S", "nettop", ...)
    stdin ← password + "\n"
    stdout → 解析输出
```

**优点**：
- 完全不依赖 AppleScript（最未来兼容）
- 密码不落盘，安全可控
- UI 可控——可以自定义弹窗样式

**缺点**：
- 自建密码窗口的安全敏感性（需要确保不会意外泄露到日志）
- 用户对自定义密码框信任度低于系统原生弹窗
- 需要处理密码错误、取消等状态

---

### 推荐

| 推荐度 | 方案 | 原因 |
|--------|------|------|
| **⭐⭐⭐** | **B. 持久 root 子进程** | 一次授权、运行中完全静默、不依赖 timestamp 机制、干净可控 |
| ⭐⭐ | A. sudo timestamp 续期 | 实现简单但依赖系统 timestamp 机制 |
| ⭐ | D. 自定义弹窗 | 未来兼容性最好但需要更多 UI 工作 |
| — | C. AppleScript 简单版 | 过于简化，5 分钟后会再弹窗 |

**方案 B 是最佳折中**：它既不需要 SMJobBless 的复杂度（不需要独立 target、代码签名配置、launchd plist），又能保证"一次授权、应用生命周期内静默"。首次弹窗获取权限后，启动一个 root 子进程专门跑 nettop，应用退出时子进程随之销毁。进程间通信通过 stdin/stdout 管道，协议简单——主进程写 `"go\n"`，子进程返回 nettop 输出后跟一个分隔符。

和 SMJobBless 的对比：方案 B 的子进程挂靠在应用进程下（应用退出 = 子进程终止），SMJobBless 的 helper 由 launchd 管理（独立于应用生命周期）。MVP 场景下方案 B 足够了，Post-MVP 再升级到 SMJobBless 也很自然——两者都是"子进程 + XPC/管道通信"的架构。

---

## 9. 下一步行动

预研结论已明确，可以进行 Phase 0 脚手架搭建：

1. 创建 Xcode 项目
2. 实现 `NettopBackend`（基于本报告的 nettop 解析方案）
3. 实现 `PrivilegeHelper`（基于 AppleScript 提权方案 + sudo timestamp 管理）
4. 实现 `ProcessAggregator`（基于 Bundle ID 优先策略）

技术栈确认：**纯 Swift**（SwiftUI + GRDB + Swift Charts），不引入 Rust。
授权方案确认：**MVP 用 AppleScript sudo timestamp，Post-MVP 迁移到 SMJobBless**。
